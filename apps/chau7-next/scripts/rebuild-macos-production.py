#!/usr/bin/env python3
"""Build and safely update the installed Rust production Chau7 app."""

from __future__ import annotations

import argparse
import fcntl
import os
import platform
import re
import shlex
import stat
import subprocess
import sys
import time
import types
import uuid
from collections.abc import Callable, Mapping, Sequence
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any

APP_PATH = Path("/Applications/Chau7.app")
BUILD_SCRIPT = Path("apps/chau7-next/scripts/bundle-macos.sh")
UPDATER_SCRIPT = Path("apps/chau7-next/scripts/update-macos-production.command")
APP_WORKSPACE = Path("apps/chau7-next")
SHA_RE = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
SEMVER_RE = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)
SESSION_MARKERS = (
    "CHAU7_SESSION_ID",
    "CHAU7_TAB_ID",
    "CHAU7_NEXT_SESSION_ID",
    "CHAU7_NEXT_TAB_ID",
)


class RebuildError(RuntimeError):
    pass


def repository_root(environ: Mapping[str, str]) -> Path:
    override = environ.get("CHAU7_REBUILD_REPO")
    if override:
        path = Path(override).expanduser()
        if not path.is_absolute():
            raise RebuildError("CHAU7_REBUILD_REPO must be an absolute repository path")
        return path.resolve()
    return Path(__file__).resolve().parents[3]


@dataclass
class Services:
    """Injectable operating-system boundary for the coordinator and its tests."""

    root: Path = field(default_factory=lambda: repository_root(os.environ))
    installed_app: Path = APP_PATH
    runner: Callable[..., Any] = subprocess.run
    environ: Mapping[str, str] = field(default_factory=lambda: dict(os.environ))
    platform_name: str = sys.platform
    machine_name: str = field(default_factory=platform.machine)
    clock: Callable[[], float] = time.time
    pid: Callable[[], int] = os.getpid
    euid: Callable[[], int] = field(default_factory=lambda: getattr(os, "geteuid", lambda: 1))
    parent_pid: Callable[[], int] = os.getppid
    open_path: Path = Path("/usr/bin/open")
    ps_path: Path = Path("/bin/ps")
    updater_core: Any | None = None


@dataclass(frozen=True)
class InstalledBuild:
    version: str
    build_number: str
    source_revision: str


@dataclass(frozen=True)
class Preflight:
    installed: InstalledBuild
    source_revision: str
    source_clean: bool
    target: str
    build_mode: str
    release_version: str
    cache_dir: Path


def command(
    services: Services,
    argv: Sequence[object],
    *,
    cwd: Path | None = None,
    env: Mapping[str, str] | None = None,
    capture_output: bool = False,
) -> Any:
    try:
        return services.runner(
            [str(item) for item in argv],
            cwd=str(cwd) if cwd is not None else None,
            env=dict(env) if env is not None else None,
            text=True,
            capture_output=capture_output,
            check=False,
        )
    except OSError as error:
        raise RebuildError(f"could not run {Path(str(argv[0])).name}: {error}") from error


def require_success(result: Any, label: str) -> None:
    if getattr(result, "returncode", 0) == 0:
        return
    detail = getattr(result, "stderr", None)
    detail = detail.strip() if isinstance(detail, str) else ""
    if detail:
        raise RebuildError(f"{label} failed: {detail[-1200:]}")
    raise RebuildError(f"{label} failed with exit status {getattr(result, 'returncode', '?')}")


def output_text(result: Any, key: str) -> str:
    value = getattr(result, key, "")
    return value if isinstance(value, str) else ""


def updater_core(services: Services) -> Any:
    if services.updater_core is not None:
        return services.updater_core
    source_path = Path(services.root) / UPDATER_SCRIPT
    try:
        source = source_path.read_text(encoding="utf-8")
    except OSError as error:
        raise RebuildError(f"cannot read guarded updater core: {error}") from error
    match = re.search(r"(?ms)^# PYTHON_CORE_BEGIN\n(.*?)^# PYTHON_CORE_END$", source)
    if match is None:
        raise RebuildError("guarded updater Python core markers are missing")
    module = types.ModuleType("chau7_production_updater_core")
    try:
        exec(compile(match.group(1), str(source_path), "exec"), module.__dict__)
    except Exception as error:
        raise RebuildError(f"cannot load guarded updater validation core: {error}") from error
    services.updater_core = module
    return module


def core_call(services: Services, function: Callable[..., Any], *args: Any, **kwargs: Any) -> Any:
    try:
        return function(*args, **kwargs)
    except Exception as error:
        raise RebuildError(str(error)) from error


def no_symlink_components(path: Path, label: str, *, must_exist: bool = True) -> Path:
    raw = Path(path).expanduser()
    if not raw.is_absolute():
        raise RebuildError(f"{label} must be an absolute path: {raw}")
    normalized = Path(os.path.abspath(str(raw)))
    cursor = Path(normalized.anchor)
    for part in normalized.parts[1:]:
        cursor = cursor / part
        try:
            mode = cursor.lstat().st_mode
        except FileNotFoundError:
            if must_exist:
                raise RebuildError(f"{label} does not exist: {normalized}") from None
            break
        except OSError as error:
            raise RebuildError(f"cannot inspect {label}: {error}") from error
        if stat.S_ISLNK(mode):
            raise RebuildError(f"{label} uses a symlink: {cursor}")
    if must_exist and not normalized.exists():
        raise RebuildError(f"{label} does not exist: {normalized}")
    return normalized


def git_environment(services: Services) -> dict[str, str]:
    env = dict(services.environ)
    for key in tuple(env):
        if key.startswith("GIT_"):
            env.pop(key, None)
    env["GIT_OPTIONAL_LOCKS"] = "0"
    return env


def source_state(services: Services) -> tuple[str, bool]:
    root = Path(services.root)
    if not (root / BUILD_SCRIPT).is_file() or not (root / UPDATER_SCRIPT).is_file():
        raise RebuildError(f"repository is missing the production build/update scripts: {root}")
    env = git_environment(services)
    revision_result = command(services, ["git", "-C", root, "rev-parse", "HEAD"], env=env, capture_output=True)
    require_success(revision_result, "source revision check")
    revision = output_text(revision_result, "stdout").strip().lower()
    if not SHA_RE.fullmatch(revision):
        raise RebuildError("git returned an invalid source revision")
    status_result = command(
        services,
        ["git", "-C", root, "status", "--porcelain", "--untracked-files=all"],
        env=env,
        capture_output=True,
    )
    require_success(status_result, "source cleanliness check")
    return revision, not output_text(status_result, "stdout").strip()


def assert_source_unchanged(services: Services, expected_revision: str) -> None:
    revision, clean = source_state(services)
    if revision != expected_revision:
        raise RebuildError(
            "source revision changed during the build/update preflight "
            f"({expected_revision[:12]} -> {revision[:12]}); no update was started"
        )
    if not clean:
        raise RebuildError("source tree became dirty; no update was started")


def normalized_version(value: str) -> str:
    if not isinstance(value, str) or SEMVER_RE.fullmatch(value) is None:
        raise RebuildError(f"release version must be semantic version syntax: {value!r}")
    return value


def version_core(value: str) -> str:
    match = SEMVER_RE.fullmatch(value)
    if match is None:
        raise RebuildError(f"release version must be semantic version syntax: {value!r}")
    return ".".join(match.group(index) for index in (1, 2, 3))


def next_build_number(installed_number: str, now: float) -> str:
    if not str(installed_number).isdigit():
        raise RebuildError("installed Rust production bundle has no numeric build number")
    minute = int(datetime.fromtimestamp(now).strftime("%Y%m%d%H%M"))
    return str(max(minute, int(installed_number) + 1))


def host_target(machine: str) -> str:
    targets = {
        "arm64": "aarch64-apple-darwin",
        "aarch64": "aarch64-apple-darwin",
        "x86_64": "x86_64-apple-darwin",
    }
    if machine not in targets:
        raise RebuildError(f"unsupported macOS host architecture: {machine!r}")
    return targets[machine]


def cache_directory(services: Services, build_mode: str) -> Path:
    raw = services.environ.get("CARGO_TARGET_DIR", "").strip()
    if raw:
        base = Path(raw).expanduser()
        if not base.is_absolute():
            base = Path(services.root) / APP_WORKSPACE / base
    else:
        base = Path(services.root) / APP_WORKSPACE / "target"
    base = no_symlink_components(base, "Cargo cache directory", must_exist=False)
    if base == Path(base.anchor) or "Applications" in base.parts:
        raise RebuildError(f"unsafe Cargo cache path: {base}")
    if any(part.endswith(".app") for part in base.parts):
        raise RebuildError(f"Cargo cache cannot be inside an app bundle: {base}")
    return base / "diagnostic" if build_mode == "diagnostic" else base


def process_parent(services: Services, pid: int) -> tuple[int, str] | None:
    result = command(
        services,
        [services.ps_path, "-o", "ppid=", "-o", "command=", "-p", str(pid)],
        capture_output=True,
    )
    if getattr(result, "returncode", 0) != 0:
        return None
    row = output_text(result, "stdout").strip()
    if not row:
        return None
    fields = row.split(None, 1)
    if len(fields) != 2:
        return None
    try:
        return int(fields[0]), fields[1]
    except ValueError:
        return None


def process_is_chau7(command_line: str) -> bool:
    lowered = command_line.lower()
    if ".app/contents/macos/chau7" in lowered:
        return True
    try:
        executable = shlex.split(command_line)[0]
    except (IndexError, ValueError):
        return False
    return Path(executable).name in {"Chau7", "Chau7 Next"}


def chau7_context(services: Services) -> tuple[bool | None, str]:
    env = services.environ
    term_program = env.get("TERM_PROGRAM", "").strip().lower()
    if term_program in {"chau7", "chau7 next"}:
        return True, f"TERM_PROGRAM={env.get('TERM_PROGRAM')}"
    for key in SESSION_MARKERS:
        if env.get(key, "").strip():
            return True, f"session marker {key}"
    if env.get("__CFBundleIdentifier", "") in {"com.chau7.app", "com.chau7.next"}:
        return True, "Chau7 application environment"

    pid = services.parent_pid()
    seen: set[int] = set()
    for _ in range(32):
        if pid <= 1 or pid in seen:
            return False, "no Chau7 app ancestor detected"
        seen.add(pid)
        parent = process_parent(services, pid)
        if parent is None:
            return None, "could not verify process ancestry"
        pid, command_line = parent
        if process_is_chau7(command_line):
            return True, "Chau7 app ancestor"
    return None, "process ancestry exceeded the inspection limit"


def build_environment(
    services: Services,
    *,
    build_mode: str,
    target: str,
    release_version: str,
    build_number: str,
    output_dir: Path,
    cache_dir: Path,
) -> dict[str, str]:
    env = dict(services.environ)
    for key in tuple(env):
        if key.startswith("CHAU7_") or key.startswith("GIT_") or key.startswith("CARGO_PROFILE_"):
            env.pop(key, None)
    for key in (
        "CHANNEL",
        "OUT_DIR",
        "TARGET",
        "RELEASE_VERSION",
        "BUILD_NUMBER",
        "BUILD_MODE",
        "BUILD_METADATA_DIR",
        "OPTIM_TARGET_DIR",
        "CARGO_BUILD_VERBOSE",
        "REQUIRE_REMOTE_AGENT",
        "REQUIRE_PROXY",
        "RUSTUP_TOOLCHAIN",
        "RUSTC",
        "RUSTDOC",
        "RUSTC_WORKSPACE_WRAPPER",
        "RUSTFLAGS",
        "CARGO_ENCODED_RUSTFLAGS",
        "CARGO_INCREMENTAL",
        "BUILD_LOG",
        "CARGO_TARGET_DIR",
        "CARGO_HOME",
        "RUSTUP_HOME",
        "CARGO_BUILD_JOBS",
        "GOMAXPROCS",
        "GOFLAGS",
        "GOENV",
        "GOOS",
        "GOARCH",
    ):
        env.pop(key, None)
    home = Path(env.get("HOME", str(Path.home()))).expanduser()
    env["PATH"] = os.pathsep.join(
        str(path)
        for path in (
            home / ".cargo/bin",
            Path("/opt/homebrew/bin"),
            Path("/usr/local/bin"),
            Path("/usr/bin"),
            Path("/bin"),
            Path("/usr/sbin"),
            Path("/sbin"),
        )
    )
    env["CARGO_HOME"] = str(home / ".cargo")
    env["RUSTUP_HOME"] = str(home / ".rustup")
    env["CARGO_TARGET_DIR"] = str(cache_dir)
    env["OPTIM_TARGET_DIR"] = str(cache_dir)
    env["CHANNEL"] = "production"
    env["TARGET"] = target
    env["RELEASE_VERSION"] = release_version
    env["BUILD_NUMBER"] = build_number
    env["BUILD_MODE"] = build_mode
    env["OUT_DIR"] = str(output_dir)
    env["BUILD_METADATA_DIR"] = str(output_dir)
    env["BUILD_LOG"] = str(output_dir / "build.log")
    env["CARGO_BUILD_VERBOSE"] = "0"
    env["REQUIRE_REMOTE_AGENT"] = "1"
    env["REQUIRE_PROXY"] = "1"
    env["RUSTC_WRAPPER"] = ""
    env["CHAU7_CTO_OPTIM_ACTIVE"] = "1"
    env["CARGO_BUILD_JOBS"] = "2"
    env["GOMAXPROCS"] = "2"
    env["GOFLAGS"] = "-p=2"
    env["GOENV"] = "off"
    env["GOOS"] = "darwin"
    env["GOARCH"] = "arm64" if target == "aarch64-apple-darwin" else "amd64"
    return env


def updater_environment(services: Services) -> dict[str, str]:
    env = dict(services.environ)
    # Keep CHAU7_NEXT_HOME_ROOT so the updater's own profile gate can reject it.
    for key in (
        "CHAU7_NEXT_ISOLATED_TEST_MODE",
        "CHAU7_HOME_ROOT",
        "CHAU7_ISOLATED_TEST_MODE",
        "CFFIXED_USER_HOME",
        "RUSTC_WRAPPER",
        "RUSTUP_TOOLCHAIN",
        "RUSTC",
        "RUSTDOC",
    ):
        env.pop(key, None)
    home = Path(env.get("HOME", str(Path.home()))).expanduser()
    env["PATH"] = os.pathsep.join(
        str(path)
        for path in (
            home / ".cargo/bin",
            Path("/opt/homebrew/bin"),
            Path("/usr/local/bin"),
            Path("/usr/bin"),
            Path("/bin"),
            Path("/usr/sbin"),
            Path("/sbin"),
        )
    )
    return env


def validate_candidate_metadata(
    receipt: Mapping[str, Any],
    *,
    plan: Preflight,
    build_number: str,
) -> None:
    expected = {
        "channel": "production",
        "buildMode": plan.build_mode,
        "sourceRevision": plan.source_revision,
        "sourceDirty": False,
        "releaseVersion": plan.release_version,
        "buildNumber": build_number,
        "bundleIdentifier": "com.chau7.app",
        "appExecutable": "Chau7",
        "appSignatureVerified": True,
    }
    for key, value in expected.items():
        if receipt.get(key) != value:
            raise RebuildError(f"production receipt does not match expected {key}")


def validate_candidate(
    app_path: Path,
    receipt_path: Path,
    *,
    plan: Preflight,
    build_number: str,
    services: Services,
) -> Mapping[str, Any]:
    app_path = no_symlink_components(app_path, "prepared production app")
    receipt_path = no_symlink_components(receipt_path, "production build receipt")
    core = updater_core(services)
    receipt = core_call(services, core.read_receipt, receipt_path)
    validate_candidate_metadata(receipt, plan=plan, build_number=build_number)
    core_call(
        services,
        core.validate_candidate,
        app_path,
        receipt,
        plan.source_revision,
        verify_signature=True,
    )
    info = core_call(services, core.read_info_plist, app_path)
    if info.get("CFBundleShortVersionString") != version_core(plan.release_version):
        raise RebuildError("candidate Info.plist version does not match the requested release version")
    return receipt


@contextmanager
def cache_lock(cache_dir: Path):
    try:
        cache_dir.mkdir(parents=True, exist_ok=True)
        cache_dir = no_symlink_components(cache_dir, "Cargo cache directory")
        lock_path = cache_dir / ".chau7-production-rebuild.lock"
        descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    except OSError as error:
        raise RebuildError(f"cannot prepare build cache lock: {error}") from error
    except RebuildError:
        raise
    lock = os.fdopen(descriptor, "r+b", closefd=True)
    try:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        yield
    finally:
        lock.close()


def make_output_dir(root: Path, build_number: str, pid: int) -> Path:
    target_root = root / APP_WORKSPACE / "target"
    try:
        target_mode = target_root.lstat().st_mode
    except FileNotFoundError:
        target_mode = None
    except OSError as error:
        raise RebuildError(f"cannot inspect worktree target directory: {error}") from error
    if target_mode is not None and stat.S_ISLNK(target_mode):
        raise RebuildError(f"worktree target directory is a symlink: {target_root}")
    output_root = target_root / "production-local"
    try:
        output_root.mkdir(parents=True, exist_ok=True)
        output_root = no_symlink_components(output_root, "production output directory")
        if not output_root.is_dir():
            raise RebuildError("production output path is not a directory")
        output_dir = output_root / f"{build_number}-{pid}-{uuid.uuid4().hex[:8]}"
        output_dir.mkdir(mode=0o700)
        return output_dir
    except FileExistsError as error:
        raise RebuildError("could not allocate a fresh production output directory") from error
    except OSError as error:
        raise RebuildError(f"cannot create a fresh production output directory: {error}") from error


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Rebuild Rust production Chau7 and update it through the guarded updater."
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="inspect the plan without writing")
    mode.add_argument(
        "--no-install", action="store_true", help="build and validate a candidate without quitting or installing"
    )
    parser.add_argument("--no-launch", action="store_true", help="install successfully, then leave Chau7 closed")
    parser.add_argument("--debug", action="store_true", help="build diagnostic symbols in a separate Cargo cache")
    parser.add_argument("--release-version", help="override the installed Rust production version")
    return parser.parse_args(argv)


def preflight(args: argparse.Namespace, services: Services) -> Preflight:
    if services.platform_name != "darwin":
        raise RebuildError("the Rust production rebuild command runs on macOS only")
    root = Path(services.root).resolve()
    for relative in (BUILD_SCRIPT, UPDATER_SCRIPT, APP_WORKSPACE / "Cargo.toml"):
        if not (root / relative).is_file():
            raise RebuildError(f"repository is missing {relative}: {root}")

    core = updater_core(services)
    installed_info = core_call(
        services,
        core.validate_installed_production,
        Path(services.installed_app),
        verify_signature=False,
    )
    installed = InstalledBuild(
        version=str(installed_info["version"]),
        build_number=str(installed_info["buildNumber"]),
        source_revision=str(installed_info["sourceRevision"]),
    )
    normalized_version(installed.version)
    if not installed.build_number.isdigit():
        raise RebuildError("installed Rust production bundle has no numeric build number")

    source_revision, source_clean = source_state(services)
    target = host_target(services.machine_name)
    build_mode = "diagnostic" if args.debug else "fast"
    release_version = normalized_version(args.release_version or installed.version)
    cache_dir = cache_directory(services, build_mode)
    return Preflight(
        installed=installed,
        source_revision=source_revision,
        source_clean=source_clean,
        target=target,
        build_mode=build_mode,
        release_version=release_version,
        cache_dir=cache_dir,
    )


def report_dry_run(args: argparse.Namespace, services: Services, plan: Preflight) -> int:
    context, reason = chau7_context(services)
    context_text = "detected" if context else "not detected" if context is False else "unknown"
    print("Read-only rebuild plan:")
    print(f"  installed Rust production version: {plan.installed.version}")
    print(f"  release version: {plan.release_version}")
    print(f"  source checkout: {services.root}")
    print(f"  source revision: {plan.source_revision}")
    print(f"  source tree: {'clean' if plan.source_clean else 'dirty (build would be blocked)'}")
    print(f"  build: {plan.build_mode} production for {plan.target}")
    print(f"  persistent Cargo cache: {plan.cache_dir}")
    print(f"  Chau7 terminal context: {context_text}")
    if context is True:
        print(f"  install would be blocked: {reason}; run from macOS Terminal")
    elif context is None:
        print(f"  install would be blocked until ancestry can be checked: {reason}")
    print("  no files, build cache, app state, or production app were changed")
    return 0


def build_candidate(
    plan: Preflight,
    services: Services,
    *,
    for_install: bool,
) -> tuple[Path, Path, str]:
    if not plan.source_clean:
        raise RebuildError("source tree is dirty; review and commit changes before building")
    if services.euid() == 0:
        raise RebuildError("run from your normal user account, never with sudo")
    if for_install:
        context, reason = chau7_context(services)
        if context is True:
            raise RebuildError(
                f"install mode cannot run from a Chau7 terminal ({reason}); "
                "open macOS Terminal and run chau7-rebuild there"
            )
        if context is None:
            raise RebuildError(
                f"cannot verify that this is an external macOS Terminal ({reason}); "
                "open macOS Terminal and run chau7-rebuild there"
            )

    root = Path(services.root).resolve()
    build_number = next_build_number(plan.installed.build_number, services.clock())
    output_dir = make_output_dir(root, build_number, services.pid())
    env = build_environment(
        services,
        build_mode=plan.build_mode,
        target=plan.target,
        release_version=plan.release_version,
        build_number=build_number,
        output_dir=output_dir,
        cache_dir=plan.cache_dir,
    )
    print(f"Building Rust production Chau7 ({plan.build_mode})...")
    print(f"  source: {plan.source_revision}")
    print(f"  cache: {plan.cache_dir}")
    print(f"  fresh output: {output_dir}")
    with cache_lock(plan.cache_dir):
        result = command(
            services,
            ["/bin/bash", root / BUILD_SCRIPT],
            cwd=root / APP_WORKSPACE,
            env=env,
        )
    if getattr(result, "returncode", 0) != 0:
        raise RebuildError(
            f"production package build failed with exit status "
            f"{getattr(result, 'returncode', '?')}; output retained at {output_dir}"
        )
    assert_source_unchanged(services, plan.source_revision)
    receipt_path = output_dir / f"Chau7-Production-{plan.target}-{plan.build_mode}.json"
    app_path = output_dir / "Chau7.app"
    validate_candidate(app_path, receipt_path, plan=plan, build_number=build_number, services=services)
    return app_path, receipt_path, build_number


def print_result(result: Any) -> None:
    stdout = output_text(result, "stdout")
    stderr = output_text(result, "stderr")
    if stdout:
        print(stdout, end="" if stdout.endswith("\n") else "\n")
    if stderr:
        print(stderr, file=sys.stderr, end="" if stderr.endswith("\n") else "\n")


def verify_installed_candidate(
    services: Services,
    receipt_path: Path,
    plan: Preflight,
    build_number: str,
) -> None:
    validate_candidate(
        Path(services.installed_app),
        receipt_path,
        plan=plan,
        build_number=build_number,
        services=services,
    )


def run_workflow(args: argparse.Namespace, services: Services) -> int:
    plan = preflight(args, services)
    if args.dry_run:
        return report_dry_run(args, services, plan)

    app_path, receipt_path, build_number = build_candidate(plan, services, for_install=not args.no_install)
    print("Candidate verified:")
    print(f"  build {build_number} ({plan.release_version})")
    print(f"  source {plan.source_revision}")
    print(f"  app {app_path}")
    print(f"  receipt {receipt_path}")

    if args.no_install:
        print("Build-only mode: Chau7 was not quit, installed, or launched.")
        return 0

    root = Path(services.root).resolve()
    updater_args = [
        "/bin/bash",
        root / UPDATER_SCRIPT,
        "--app",
        app_path,
        "--receipt",
        receipt_path,
        "--expected-sha",
        plan.source_revision,
        "--dry-run",
    ]
    print("Running the guarded updater dry-run...")
    dry_result = command(
        services,
        updater_args,
        cwd=root,
        env=updater_environment(services),
        capture_output=True,
    )
    print_result(dry_result)
    require_success(dry_result, "guarded updater dry-run")

    # The updater can spend time inspecting restore state. Preserve the exact
    # source identity and recheck it directly before the mutating apply call.
    assert_source_unchanged(services, plan.source_revision)
    apply_args = updater_args[:-1] + ["--apply"]
    print("Guarded updater dry-run passed. Starting the guarded update...")
    apply_result = command(services, apply_args, cwd=root, env=updater_environment(services))
    if getattr(apply_result, "returncode", 0) != 0:
        raise RebuildError(
            "guarded updater apply failed with exit status "
            f"{getattr(apply_result, 'returncode', '?')}; its recovery and rollback gates remain authoritative"
        )

    verify_installed_candidate(services, receipt_path, plan, build_number)
    print(f"Installed Rust production build {build_number} from {plan.source_revision}.")
    if args.no_launch:
        print("Launch skipped (--no-launch).")
        return 0

    launch_result = command(
        services,
        [services.open_path, services.installed_app],
        env=updater_environment(services),
    )
    require_success(launch_result, "launching installed Chau7")
    print(f"Launched {services.installed_app}.")
    return 0


def main(
    argv: Sequence[str] | None = None,
    services: Services | None = None,
) -> int:
    try:
        args = parse_args(argv)
        return run_workflow(args, services or Services())
    except RebuildError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except OSError as error:
        print(f"error: rebuild stopped safely: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
