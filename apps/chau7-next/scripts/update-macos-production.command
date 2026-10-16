#!/bin/bash
# Repeat-Rust production updater. Run from Terminal after reviewing --dry-run.
set -euo pipefail
umask 077

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required" >&2
  exit 2
fi

exec python3 - "$@" <<'PYTHON_CORE'
# PYTHON_CORE_BEGIN
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import plistlib
import platform
import pwd
import shutil
import re
import stat
import subprocess
import sys
import time
import uuid
from pathlib import Path, PurePosixPath

APP_DESTINATION = Path("/Applications/Chau7.app")
EXPECTED_BUNDLE_ID = "com.chau7.app"
EXPECTED_EXECUTABLE = "Chau7"
EXPECTED_CHANNEL = "production"
STATE_RELATIVES = (
    Path("Library/Application Support/Chau7/RustV1"),
    Path(".chau7/rust-v1"),
)
KNOWN_RUNTIME_SOCKETS = {
    Path("Library/Application Support/Chau7/RustV1"): {
        Path("Proxy/proxy.sock"),
        Path("remote.sock"),
        Path("scripting.sock"),
    },
    Path(".chau7/rust-v1"): {Path("mcp.sock")},
}
ARTIFACTS = {
    "Chau7": "Contents/MacOS/Chau7",
    "chau7-next-mcp-bridge": "Contents/MacOS/chau7-next-mcp-bridge",
    "chau7-next-cli": "Contents/MacOS/chau7-next-cli",
    "chau7-optim": "Contents/MacOS/chau7-optim",
    "chau7-md": "Contents/MacOS/chau7-md",
    "chau7-remote": "Contents/MacOS/chau7-remote",
    "chau7-proxy": "Contents/MacOS/chau7-proxy",
}
SHA_RE = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")


class UpdateError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise UpdateError(message)


def plain_path(path, label, must_exist=True):
    """Return an absolute path after rejecting symlink path components."""
    raw = Path(path).expanduser()
    require(raw.is_absolute(), f"{label} must be an absolute path: {raw}")
    normalized = Path(os.path.abspath(str(raw)))
    cursor = Path(normalized.anchor)
    for part in normalized.parts[1:]:
        cursor = cursor / part
        try:
            mode = cursor.lstat().st_mode
        except FileNotFoundError:
            if must_exist:
                raise UpdateError(f"{label} does not exist: {normalized}")
            break
        except OSError as error:
            raise UpdateError(f"cannot inspect {label}: {error}") from error
        require(not stat.S_ISLNK(mode), f"{label} uses a symlink: {cursor}")
    if must_exist:
        require(normalized.exists(), f"{label} does not exist: {normalized}")
    return normalized


def assert_bundle_tree_has_no_symlinks(bundle):
    require(bundle.is_dir(), f"app bundle is not a directory: {bundle}")
    for root, directories, files in os.walk(bundle, followlinks=False):
        for name in directories + files:
            item = Path(root) / name
            try:
                mode = item.lstat().st_mode
            except OSError as error:
                raise UpdateError(f"cannot inspect app bundle entry {item}: {error}") from error
            require(not stat.S_ISLNK(mode), f"app bundle contains a symlink: {item}")
            require(stat.S_ISDIR(mode) or stat.S_ISREG(mode),
                    f"app bundle contains an unsupported file: {item}")


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_manifest(root, allowed_sockets=()):
    """Hash a tree, permitting only explicitly named runtime socket nodes."""
    root = Path(root)
    result = {}

    def visit(path):
        info = path.lstat()
        key = "." if path == root else path.relative_to(root).as_posix()
        mode = stat.S_IMODE(info.st_mode)
        if stat.S_ISLNK(info.st_mode):
            result[key] = ("symlink", os.readlink(path), mode)
        elif stat.S_ISDIR(info.st_mode):
            result[key] = ("directory", mode)
            for child in sorted(path.iterdir(), key=lambda value: value.name):
                visit(child)
        elif stat.S_ISREG(info.st_mode):
            result[key] = ("file", sha256_file(path), mode)
        elif stat.S_ISSOCK(info.st_mode) and path.relative_to(root) in allowed_sockets:
            result[key] = ("known-runtime-socket", info.st_dev, info.st_ino, mode)
        else:
            raise UpdateError(f"unsupported filesystem object in snapshot: {path}")

    visit(root)
    return result


def read_info_plist(bundle):
    path = bundle / "Contents/Info.plist"
    try:
        with path.open("rb") as source:
            info = plistlib.load(source)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise UpdateError(f"cannot read bundle Info.plist: {error}") from error
    require(isinstance(info, dict), "bundle Info.plist is not a dictionary")
    return info


def verify_code_signature(bundle):
    result = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle)],
        text=True, capture_output=True, check=False,
    )
    require(result.returncode == 0,
            f"codesign verification failed for {bundle}: {result.stderr.strip()}")


def read_receipt(path):
    try:
        require(path.is_file(), f"build receipt is not a regular file: {path}")
        require(path.stat().st_size <= 2 * 1024 * 1024, "build receipt is unexpectedly large")
        with path.open("r", encoding="utf-8") as source:
            receipt = json.load(source)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise UpdateError(f"cannot read build receipt: {error}") from error
    require(isinstance(receipt, dict), "build receipt must be a JSON object")
    return receipt


def host_rust_target(machine=None):
    machine = platform.machine() if machine is None else machine
    targets = {
        "arm64": "aarch64-apple-darwin",
        "x86_64": "x86_64-apple-darwin",
    }
    require(machine in targets, f"unsupported macOS host architecture: {machine!r}")
    return targets[machine]


def validate_candidate(bundle, receipt, expected_sha, verify_signature=True):
    require(SHA_RE.fullmatch(expected_sha) is not None,
            "--expected-sha must be a full lowercase 40- or 64-character SHA")
    expected_target = host_rust_target()
    require(receipt.get("target") == expected_target,
            f"receipt target does not match this Mac ({expected_target})")
    assert_bundle_tree_has_no_symlinks(bundle)
    info = read_info_plist(bundle)

    require(receipt.get("channel") == EXPECTED_CHANNEL, "receipt is not a production build")
    require(receipt.get("bundleIdentifier") == EXPECTED_BUNDLE_ID,
            "receipt bundle identifier is not com.chau7.app")
    require(receipt.get("sourceRevision") == expected_sha and receipt.get("sourceDirty") is False,
            "receipt does not bind this exact clean source revision")
    require(receipt.get("appSignatureVerified") is True,
            "receipt does not record a verified app signature")
    features = receipt.get("cargoFeatures")
    require(isinstance(features, list) and "chau7_next_core/production" in features,
            "receipt does not enable the production Rust feature")
    require(receipt.get("appExecutable") == EXPECTED_EXECUTABLE,
            "receipt does not name the Rust production executable")
    artifact_records = receipt.get("artifacts")
    require(isinstance(artifact_records, dict) and set(artifact_records) == set(ARTIFACTS),
            "receipt must contain exactly the seven production executables")
    require(info.get("CFBundleIdentifier") == EXPECTED_BUNDLE_ID,
            "candidate bundle identifier is not com.chau7.app")
    require(info.get("CFBundlePackageType") == "APPL", "candidate is not an app bundle")
    require(info.get("CFBundleExecutable") == EXPECTED_EXECUTABLE,
            "candidate is not the Rust production app")
    require(info.get("Chau7BuildChannel") == EXPECTED_CHANNEL,
            "candidate is not marked as the production channel")
    require(info.get("Chau7SourceRevision") == expected_sha,
            "candidate Info.plist source SHA differs from --expected-sha")
    require(info.get("CFBundleVersion") == str(receipt.get("buildNumber", "")),
            "candidate build number differs from its receipt")

    artifact_paths = set()
    for name, expected_relative in ARTIFACTS.items():
        record = artifact_records.get(name)
        require(isinstance(record, dict), f"receipt artifact record is invalid: {name}")
        relative = record.get("path")
        digest = record.get("sha256")
        parsed = PurePosixPath(relative) if isinstance(relative, str) else None
        require(parsed is not None and not parsed.is_absolute()
                and ".." not in parsed.parts and relative == expected_relative,
                f"receipt artifact path is invalid: {name}")
        require(isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest) is not None,
                f"receipt artifact hash is invalid: {name}")
        path = bundle.joinpath(*parsed.parts)
        try:
            mode = path.lstat().st_mode
        except OSError as error:
            raise UpdateError(f"receipt executable is absent: {name}") from error
        require(stat.S_ISREG(mode) and bool(mode & 0o111),
                f"receipt artifact is not an executable regular file: {name}")
        require(sha256_file(path) == digest, f"receipt executable hash differs: {name}")
        artifact_paths.add(relative)

    contents = bundle / "Contents"
    actual_executables = set()
    for root, _, files in os.walk(contents, followlinks=False):
        for name in files:
            path = Path(root) / name
            mode = path.lstat().st_mode
            if stat.S_ISREG(mode) and mode & 0o111:
                actual_executables.add(path.relative_to(bundle).as_posix())
    require(actual_executables == artifact_paths,
            "candidate executable inventory differs from the seven receipt artifacts")

    if verify_signature:
        verify_code_signature(bundle)
    return {
        "sourceRevision": expected_sha,
        "buildNumber": str(receipt["buildNumber"]),
        "version": str(receipt.get("releaseVersion", receipt.get("version", "unknown"))),
        "bundleIdentifier": EXPECTED_BUNDLE_ID,
    }


def validate_installed_production(bundle, verify_signature=True):
    assert_bundle_tree_has_no_symlinks(bundle)
    info = read_info_plist(bundle)
    require(info.get("CFBundleIdentifier") == EXPECTED_BUNDLE_ID,
            "installed app is not the com.chau7.app production target")
    require(info.get("CFBundlePackageType") == "APPL", "installed target is not an app bundle")
    require(info.get("CFBundleExecutable") == EXPECTED_EXECUTABLE,
            "installed target is not the Rust app executable")
    require(info.get("Chau7BuildChannel") == EXPECTED_CHANNEL,
            "installed target is not marked production; refusing Swift or Next app")
    require("Chau7NextSourceRevision" not in info,
            "installed target carries the Next source marker")
    revision = info.get("Chau7SourceRevision")
    require(isinstance(revision, str) and SHA_RE.fullmatch(revision) is not None,
            "installed target lacks a valid Rust source revision")
    if verify_signature:
        verify_code_signature(bundle)
    return {
        "sourceRevision": revision,
        "buildNumber": str(info.get("CFBundleVersion", "unknown")),
        "version": str(info.get("CFBundleShortVersionString", "unknown")),
        "bundleIdentifier": EXPECTED_BUNDLE_ID,
    }


def state_roots(home):
    existing = []
    for relative in STATE_RELATIVES:
        path = plain_path(home / relative, f"RustV1 state root {relative}", must_exist=False)
        if path.exists():
            require(path.is_dir(), f"RustV1 state root is not a directory: {path}")
            existing.append(path)
    require(existing, "no RustV1 state or config directory exists; refusing an untracked install")
    return existing


def acquire_instance_lock(home):
    """Hold Rust's existing flock without creating or modifying its lockfile."""
    lock_path = plain_path(
        home / STATE_RELATIVES[0] / "app-instance.lock",
        "RustV1 app lifetime lock",
    )
    try:
        path_info = lock_path.lstat()
    except OSError as error:
        raise UpdateError(f"cannot inspect RustV1 app lifetime lock: {error}") from error
    require(stat.S_ISREG(path_info.st_mode),
            f"RustV1 app lifetime lock is not a regular file: {lock_path}")
    descriptor = -1
    try:
        flags = os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(lock_path, flags)
        opened_info = os.fstat(descriptor)
        require(stat.S_ISREG(opened_info.st_mode)
                and (opened_info.st_dev, opened_info.st_ino)
                == (path_info.st_dev, path_info.st_ino),
                "RustV1 app lifetime lock changed during open")
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return os.fdopen(descriptor, "r+b", closefd=True)
    except BlockingIOError as error:
        if descriptor >= 0:
            os.close(descriptor)
        raise UpdateError(
            "Rust still holds the app lifetime lock; no backup or app change was made."
        ) from error
    except UpdateError:
        if descriptor >= 0:
            os.close(descriptor)
        raise
    except OSError as error:
        if descriptor >= 0:
            os.close(descriptor)
        raise UpdateError(f"cannot acquire RustV1 app lifetime lock: {error}") from error


def active_application_pids():
    script = r"""
ObjC.import('AppKit');
var found = [];
var apps = $.NSWorkspace.sharedWorkspace.runningApplications;
for (var i = 0; i < apps.count; i++) {
  var app = apps.objectAtIndex(i);
  if (ObjC.unwrap(app.bundleIdentifier) === 'com.chau7.app') found.push(Number(app.processIdentifier));
}
JSON.stringify(found);
"""
    result = subprocess.run(
        ["/usr/bin/osascript", "-l", "JavaScript"],
        input=script, text=True, capture_output=True, check=False,
    )
    require(result.returncode == 0, f"cannot inspect running Chau7 apps: {result.stderr.strip()}")
    try:
        pids = json.loads(result.stdout.strip())
    except json.JSONDecodeError as error:
        raise UpdateError("macOS returned an invalid running-app list") from error
    require(isinstance(pids, list) and all(isinstance(pid, int) and pid > 0 for pid in pids),
            "macOS returned an invalid running-app list")
    return pids


def copy_with_ditto(source, destination, needs_sudo=False):
    require(not destination.exists() and not destination.is_symlink(),
            f"backup or staging path already exists: {destination}")
    command = ["/usr/bin/ditto", str(source), str(destination)]
    if needs_sudo:
        command.insert(0, "/usr/bin/sudo")
    result = subprocess.run(command, text=True, capture_output=True, check=False)
    require(result.returncode == 0,
            f"ditto failed from {source} to {destination}: {result.stderr.strip()}")


def move_with_sudo(source, destination):
    require(source.exists() and not source.is_symlink(), f"move source is absent or linked: {source}")
    require(not destination.exists() and not destination.is_symlink(),
            f"move destination already exists: {destination}")
    result = subprocess.run(
        ["/usr/bin/sudo", "/bin/mv", str(source), str(destination)],
        text=True, capture_output=True, check=False,
    )
    require(result.returncode == 0,
            f"move failed from {source} to {destination}: {result.stderr.strip()}")


def create_backup_directory(home, run_id):
    parent = plain_path(home / "Library/Application Support/Chau7 Production Update Backups",
                        "backup parent", must_exist=False)
    if not parent.exists():
        parent.mkdir(parents=True, mode=0o700)
    require(parent.is_dir(), f"backup parent is not a directory: {parent}")
    backup = parent / run_id
    backup.mkdir(mode=0o700)
    os.chmod(backup, 0o700)
    return backup


def state_socket_paths(source, home):
    relative_root = source.relative_to(home)
    return KNOWN_RUNTIME_SOCKETS.get(relative_root, set())


def copy_state_tree(source, destination, allowed_sockets):
    def omit_known_socket_nodes(directory, names):
        ignored = []
        directory_path = Path(directory)
        for name in names:
            item = directory_path / name
            mode = item.lstat().st_mode
            if stat.S_ISSOCK(mode):
                relative = item.relative_to(source)
                require(relative in allowed_sockets,
                        f"unknown socket prevents a complete state backup: {item}")
                ignored.append(name)
            elif not (stat.S_ISDIR(mode) or stat.S_ISREG(mode) or stat.S_ISLNK(mode)):
                raise UpdateError(f"unsupported filesystem object in state: {item}")
        return ignored

    shutil.copytree(source, destination, symlinks=True, copy_function=shutil.copy2,
                    ignore=omit_known_socket_nodes)


def snapshot_state(roots, backup, home):
    allowed_by_root = {path: state_socket_paths(path, home) for path in roots}
    before = {
        path: tree_manifest(path, allowed_by_root[path])
        for path in roots
    }
    for source in roots:
        relative = source.relative_to(home)
        destination = backup / "state" / relative
        destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        copy_state_tree(source, destination, allowed_by_root[source])
        require(tree_manifest(source, allowed_by_root[source]) == before[source],
                f"RustV1 state changed while being backed up: {source}")
        expected_backup = {
            key: value for key, value in before[source].items()
            if value[0] != "known-runtime-socket"
        }
        require(tree_manifest(destination) == expected_backup,
                f"RustV1 state backup differs from source: {source}")
    return before


def ensure_profiles_unchanged(before, home):
    for source, manifest in before.items():
        allowed = state_socket_paths(source, home)
        require(tree_manifest(source, allowed) == manifest,
                f"RustV1 profile changed during the update: {source}")


def ask_for_normal_quit(wait_seconds):
    print(
        f"Quit Chau7 normally with Cmd+Q. This updater will wait up to {wait_seconds} "
        "seconds and will never send a quit or process signal.",
        flush=True,
    )
    deadline = time.monotonic() + wait_seconds
    while True:
        pids = active_application_pids()
        if not pids:
            return
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise UpdateError(
                f"Chau7 is still running (PID {', '.join(map(str, pids))}); "
                "no backup or app change was made."
            )
        print(f"Waiting for normal quit; active Chau7 PID(s): {', '.join(map(str, pids))}", flush=True)
        time.sleep(min(2.0, remaining))


def unique_app_path(prefix, run_id):
    path = Path("/Applications") / f".Chau7-production-{prefix}-{run_id}.app"
    require(not path.exists() and not path.is_symlink(), f"reserved app path already exists: {path}")
    return path


def restore_rollback(rollback, destination, verify_old, move):
    try:
        move(rollback, destination)
        verify_old(destination)
        return True
    except BaseException as error:
        print(f"ROLLBACK NOT CONFIRMED: {error}", file=sys.stderr, flush=True)
        return False


def install_staged_bundle(stage, destination, rollback, failed,
                          verify_new, verify_old, move=move_with_sudo):
    try:
        move(destination, rollback)
        move(stage, destination)
    except BaseException as error:
        if rollback.exists() and not destination.exists():
            if restore_rollback(rollback, destination, verify_old, move):
                raise UpdateError(
                    f"candidate install failed; the previous app was restored. ({error})"
                ) from error
        if rollback.exists() and destination.exists() and not stage.exists():
            try:
                verify_new(destination)
            except BaseException as verify_error:
                print(f"Candidate verification failed during interrupted swap: {verify_error}",
                      file=sys.stderr, flush=True)
            try:
                move(destination, failed)
                if restore_rollback(rollback, destination, verify_old, move):
                    raise UpdateError(
                        f"replacement was interrupted after the candidate reached its "
                        f"path; previous app restored and candidate retained at {failed}. "
                        f"({error})"
                    ) from error
            except UpdateError:
                raise
            except BaseException as rollback_error:
                print(f"ROLLBACK INTERRUPTED: {rollback_error}",
                      file=sys.stderr, flush=True)
                if not destination.exists() and rollback.exists():
                    if restore_rollback(rollback, destination, verify_old, move):
                        raise UpdateError(
                            f"replacement was interrupted after retaining the candidate; "
                            f"previous app restored and candidate retained at {failed}."
                        ) from rollback_error
        if destination.exists() and not rollback.exists():
            try:
                verify_old(destination)
            except BaseException:
                pass
            else:
                raise UpdateError(
                    f"replacement failed before the previous app moved; "
                    f"the original app remains installed. ({error})"
                ) from error
        raise UpdateError(
            f"bundle replacement failed and rollback could not be confirmed. "
            f"Keep all app bundles in place. Rollback: {rollback}; stage: {stage}. ({error})"
        ) from error

    try:
        result = verify_new(destination)
    except BaseException as error:
        try:
            move(destination, failed)
            restored = restore_rollback(rollback, destination, verify_old, move)
        except BaseException as rollback_error:
            restored = False
            print(f"ROLLBACK INTERRUPTED: {rollback_error}", file=sys.stderr, flush=True)
            if not destination.exists() and rollback.exists():
                restored = restore_rollback(rollback, destination, verify_old, move)
        if restored:
            raise UpdateError(
                f"new bundle verification failed; previous app restored. "
                f"Failed bundle retained at {failed}. ({error})"
            ) from error
        raise UpdateError(
            f"new bundle verification failed and rollback is unconfirmed. "
            f"Keep all bundles in place. Failed path: {failed}; rollback: {rollback}. "
            f"({error})"
        ) from error
    return result


def require_terminal():
    require(sys.stdout.isatty(), "--apply must be run from an interactive Terminal")
    try:
        terminal = open("/dev/tty", "r", encoding="utf-8")
    except OSError as error:
        raise UpdateError("--apply needs a controlling Terminal; no files were changed") from error
    try:
        require(terminal.isatty(), "--apply needs a controlling Terminal")
    finally:
        terminal.close()


def apply_update(candidate, receipt_path, expected_sha, wait_seconds, info, home):
    require_terminal()
    ask_for_normal_quit(wait_seconds)
    lock_file = acquire_instance_lock(home)
    try:
        require(not active_application_pids(),
                "Chau7 reopened after quit; no backup or app change was made.")
        perform_update_locked(candidate, receipt_path, expected_sha, info, home)
    finally:
        lock_file.close()


def perform_update_locked(candidate, receipt_path, expected_sha, info, home):
    # The Rust lifetime flock stays held through verification and replacement.
    # Revalidate every source and target after the wait, before creating backups.
    candidate = plain_path(candidate, "candidate app")
    receipt_path = plain_path(receipt_path, "build receipt")
    receipt = read_receipt(receipt_path)
    candidate_info = validate_candidate(candidate, receipt, expected_sha)
    installed_info = validate_installed_production(APP_DESTINATION)
    roots = state_roots(home)
    require(not active_application_pids(),
            "Chau7 reopened after quit; no backup or app change was made.")

    run_id = time.strftime("%Y%m%d-%H%M%S") + "-" + str(os.getpid()) + "-" + uuid.uuid4().hex[:8]
    backup = create_backup_directory(home, run_id)
    state_before = snapshot_state(roots, backup, home)

    previous_copy = backup / "previous" / "Chau7.app"
    previous_copy.parent.mkdir(mode=0o700)
    installed_manifest = tree_manifest(APP_DESTINATION)
    copy_with_ditto(APP_DESTINATION, previous_copy)
    require(tree_manifest(APP_DESTINATION) == installed_manifest,
            "installed bundle changed while being backed up")
    require(tree_manifest(previous_copy) == installed_manifest,
            "installed app backup differs from the current app")
    validate_installed_production(previous_copy)

    candidate_manifest = tree_manifest(candidate)
    stage = unique_app_path("stage", run_id)
    rollback = unique_app_path("rollback", run_id)
    failed = unique_app_path("failed", run_id)
    copy_with_ditto(candidate, stage, needs_sudo=True)
    require(tree_manifest(candidate) == candidate_manifest,
            "candidate changed while it was being staged")
    require(tree_manifest(stage) == candidate_manifest,
            "staged bundle differs from the validated candidate")
    validate_candidate(stage, receipt, expected_sha)
    ensure_profiles_unchanged(state_before, home)

    require(not active_application_pids(),
            "Chau7 reopened before replacement; original app remains installed.")
    require(tree_manifest(APP_DESTINATION) == installed_manifest,
            "installed bundle changed before replacement; original app remains installed.")
    def verify_new_bundle(bundle):
        result = validate_candidate(bundle, receipt, expected_sha)
        ensure_profiles_unchanged(state_before, home)
        return result

    installed_result = install_staged_bundle(
        stage, APP_DESTINATION, rollback, failed,
        verify_new_bundle, validate_installed_production,
    )

    print(f"Installed production Rust build {installed_result['buildNumber']} "
          f"from {installed_result['sourceRevision']}.")
    print(f"Previous app backup: {previous_copy}")
    print(f"Rollback app retained: {rollback}")
    print(f"RustV1 profile snapshots: {backup / 'state'}")
    for source_path, manifest in state_before.items():
        for relative in state_socket_paths(source_path, home):
            entry = manifest.get(relative.as_posix())
            if entry and entry[0] == "known-runtime-socket":
                print(f"Runtime socket node omitted from backup: {source_path / relative}")
    print("Chau7 was not launched. RustV1 state and config were not imported or rewritten.")


def account_home():
    try:
        account_path = Path(pwd.getpwuid(os.getuid()).pw_dir)
    except (KeyError, OSError) as error:
        raise UpdateError(f"cannot resolve the current account home: {error}") from error
    home = plain_path(account_path, "current account home")
    environment_home = plain_path(
        Path(os.environ.get("HOME", str(account_path))).expanduser(), "HOME environment"
    )
    try:
        same_home = os.path.samefile(home, environment_home)
    except OSError:
        same_home = False
    require(same_home, "HOME does not resolve to the current account home")
    return home


def ensure_default_profile_environment():
    require(not os.environ.get("CHAU7_NEXT_HOME_ROOT"),
            "CHAU7_NEXT_HOME_ROOT is set; refusing an update against another profile")
    launchctl = Path("/bin/launchctl")
    require(launchctl.is_file(), "cannot inspect the macOS launch environment")
    result = subprocess.run(
        [str(launchctl), "getenv", "CHAU7_NEXT_HOME_ROOT"],
        text=True, capture_output=True, check=False,
    )
    launch_root = result.stdout.rstrip("\r\n")
    require(not launch_root,
            "launchctl CHAU7_NEXT_HOME_ROOT is set; refusing an update against another profile")
    if result.returncode != 0 and result.stderr.strip():
        diagnostic = result.stderr.strip().lower()
        require("could not find environment variable" in diagnostic,
                f"cannot verify the launch environment: {result.stderr.strip()}")


def make_parser():
    parser = argparse.ArgumentParser(
        description="Safely update the installed Chau7 Rust production app from a verified bundle."
    )
    parser.add_argument("--app", required=True, help="prepared production Chau7.app")
    parser.add_argument("--receipt", required=True, help="build receipt produced with the bundle")
    parser.add_argument("--expected-sha", required=True, help="full clean source commit SHA")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true", help="validate and report without writing")
    mode.add_argument("--apply", action="store_true", help="wait for normal quit, back up, and install")
    parser.add_argument("--wait-seconds", type=int, default=600,
                        help="maximum normal-quit wait (1-3600, default 600)")
    return parser


def main(argv=None):
    args = make_parser().parse_args(argv)
    try:
        require(os.geteuid() != 0, "run from your normal user account, never with sudo")
        require(1 <= args.wait_seconds <= 3600, "--wait-seconds must be between 1 and 3600")
        home = account_home()
        ensure_default_profile_environment()
        candidate = plain_path(args.app, "candidate app")
        receipt_path = plain_path(args.receipt, "build receipt")
        destination = plain_path(APP_DESTINATION, "installed production app")
        require(candidate.suffix == ".app", "--app must name an .app bundle")
        try:
            same_bundle = os.path.samefile(candidate, destination)
        except OSError:
            same_bundle = False
        require(not same_bundle and candidate.resolve() != destination.resolve(),
                "candidate source and installed destination are the same path")
        receipt = read_receipt(receipt_path)
        candidate_info = validate_candidate(candidate, receipt, args.expected_sha)
        installed_info = validate_installed_production(destination)
        roots = state_roots(home)
        active_pids = active_application_pids()

        print("Candidate verified:")
        print(f"  build {candidate_info['buildNumber']} ({candidate_info['version']})")
        print(f"  source {candidate_info['sourceRevision']}")
        print(f"Installed production Rust app:")
        print(f"  build {installed_info['buildNumber']}, source {installed_info['sourceRevision']}")
        print("RustV1 roots present:")
        for root in roots:
            print(f"  {root}")
        print("Active Chau7 PID(s): " + (", ".join(map(str, active_pids)) if active_pids else "none"))
        if args.dry_run:
            print("Dry run only: no files or app state were changed.")
            print("For installation, run this command in Terminal with --apply.")
            return 0
        apply_update(candidate, receipt_path, args.expected_sha, args.wait_seconds,
                     candidate_info, home)
        return 0
    except UpdateError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except Exception as error:
        print(f"error: updater stopped safely: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
# PYTHON_CORE_END
PYTHON_CORE
