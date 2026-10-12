#!/usr/bin/env python3
"""Run owned macOS parity fixtures and retain exact source/binary evidence."""

import argparse
import hashlib
import json
import os
import platform
import plistlib
import re
import shutil
import subprocess
import tempfile
import time
import uuid
from pathlib import Path


def output(argv, cwd=None, env=None):
    return subprocess.check_output(argv, cwd=cwd, env=env, text=True).strip()


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as artifact:
        for block in iter(lambda: artifact.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def prepare_restore_bundle(binary, record, evidence):
    # A fresh identity gives this owned acceptance process normal AppKit
    # LaunchServices activation without changing production packaging.
    nonce = uuid.uuid4().hex
    root = Path(tempfile.mkdtemp(prefix="chau7-native-fixture-bundle-")).resolve()
    bundle = root / "Chau7 Next Native Fixture.app"
    executable = bundle / "Contents" / "MacOS" / "chau7-next"
    executable.parent.mkdir(parents=True)
    identifier = "com.chau7.next.native.fixture." + nonce
    record.update(
        owned_bundle_root=str(root),
        owned_bundle=str(bundle),
        bundle_identifier=identifier,
        owned_bundle_removed=False,
    )
    shutil.copy2(binary, executable)
    info = {
        "CFBundleExecutable": "chau7-next",
        "CFBundleIdentifier": identifier,
        "CFBundleName": "Chau7 Next Native Fixture",
        "CFBundleDisplayName": "Chau7 Next Native Fixture",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1",
        "CFBundleShortVersionString": "1",
        "NSPrincipalClass": "NSApplication",
        "LSUIElement": False,
        "LSBackgroundOnly": False,
        "NSHighResolutionCapable": True,
    }
    with (bundle / "Contents" / "Info.plist").open("xb") as plist:
        plistlib.dump(info, plist)
    with (evidence / "restore.codesign.log").open("x") as log:
        subprocess.run(
            ["/usr/bin/codesign", "--force", "--sign", "-", str(bundle)],
            stdout=log,
            stderr=subprocess.STDOUT,
            check=True,
        )
        subprocess.run(
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle)],
            stdout=log,
            stderr=subprocess.STDOUT,
            check=True,
        )
    record["signed_bundle_binary_sha256"] = sha256(executable)
    return root, bundle


def fixture_outcome(path, case):
    outcomes = []
    for line in path.read_text().splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and value.get("case") == case and isinstance(value.get("passed"), bool):
            outcomes.append(value)
    return outcomes[0] if len(outcomes) == 1 else None


def valid_pid(pid):
    return isinstance(pid, int) and not isinstance(pid, bool) and pid > 0


def application_gone(pid):
    if not valid_pid(pid):
        return False
    # This is an existence probe only, never a termination signal. Treat
    # permissions and PID reuse conservatively as a still-present process.
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


def case_passed(record):
    outcome = record.get("outcome") or {}
    return (
        not record.get("timed_out", False)
        and record.get("exit_code") == 0
        and outcome.get("passed") is True
        and outcome.get("owned_resources_closed") is True
        and outcome.get("owned_profile_removed") is True
        and record.get("owned_home_removed") is True
        and record.get("application_pid_verified") is True
        and record.get("application_process_gone") is True
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=("all", "restore", "settings", "editor"), default="all")
    parser.add_argument(
        "--toolchain",
        default="1.96.0",
        help="Exact already installed Rust release; never installed or upgraded by this script",
    )
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("native parity fixtures require macOS")
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.toolchain):
        parser.error("use an exact Rust version, not a mutable toolchain alias")
    workspace = Path(__file__).resolve().parents[1]
    repo = workspace.parents[1]
    revision = output(["git", "rev-parse", "HEAD"], cwd=repo)
    if output(["git", "status", "--porcelain"], cwd=repo):
        parser.error("commit or preserve source changes before collecting exact-revision evidence")
    architecture = {"arm64": "aarch64", "x86_64": "x86_64"}.get(platform.machine())
    if architecture is None:
        parser.error("unsupported macOS architecture")
    target_triple = f"{architecture}-apple-darwin"
    toolchain_id = f"{args.toolchain}-{target_triple}"
    toolchain = Path(os.environ.get("RUSTUP_HOME", str(Path.home() / ".rustup"))) / "toolchains" / toolchain_id / "bin"
    for name in ("cargo", "rustc", "rustdoc"):
        if not (toolchain / name).is_file():
            parser.error(f"required already installed executable is missing: {toolchain / name}")
    evidence = Path(tempfile.mkdtemp(prefix="chau7-native-results-")).resolve()
    target = workspace / "target" / "native-parity"
    environment = dict(os.environ)
    environment.update(
        {
            "RUSTUP_TOOLCHAIN": toolchain_id,
            "RUSTC": str(toolchain / "rustc"),
            "RUSTDOC": str(toolchain / "rustdoc"),
            "RUSTC_WRAPPER": "",
            "CARGO_TARGET_DIR": str(target),
            # Dedicated fixture artifacts; normal packaging keeps its release profile.
            "CARGO_PROFILE_RELEASE_LTO": "off",
        }
    )
    manifest = {
        "source_revision": revision,
        "compiler": output([str(toolchain / "rustc"), "--version"]),
        "cargo": output([str(toolchain / "cargo"), "--version"]),
        "fixture_feature": "native-parity-fixture",
        "release_lto": "off",
        "target_triple": target_triple,
        "target_directory": str(target),
        "bundle_build_sha": None,
        "results": [],
    }
    build_log = evidence / "build.log"
    with build_log.open("x") as log:
        build = subprocess.run(
            [
                str(toolchain / "cargo"),
                "build",
                "--release",
                "--locked",
                "--target",
                target_triple,
                "-p",
                "chau7_next",
                "--features",
                "native-parity-fixture",
            ],
            cwd=workspace,
            env=environment,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=False,
        )
    if build.returncode:
        manifest["build_exit_code"] = build.returncode
        (evidence / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(f"Build failed; evidence: {evidence}")
        return 1
    if output(["git", "rev-parse", "HEAD"], cwd=repo) != revision or output(["git", "status", "--porcelain"], cwd=repo):
        print(f"Source changed during build; evidence: {evidence}")
        return 1
    binary = target / target_triple / "release" / "chau7-next"
    manifest["binary_sha256"] = sha256(binary)
    manifest["original_binary_sha256"] = manifest["binary_sha256"]
    cases = ("restore", "settings", "editor") if args.case == "all" else (args.case,)
    success = True
    for case in cases:
        # Do not create this directory: the runner validates and creates it.
        home = Path(tempfile.gettempdir()).resolve() / f"chau7-native-fixture-{uuid.uuid4()}"
        child_environment = dict(environment)
        child_environment.update(
            {
                "CHAU7_NEXT_HOME_ROOT": str(home),
                "CHAU7_NEXT_ISOLATED_TEST_MODE": "1",
                "CHAU7_NEXT_NATIVE_PARITY_FIXTURE": "1",
                "HISTFILE": "",
            }
        )
        stdout_path = evidence / f"{case}.stdout"
        stderr_path = evidence / f"{case}.stderr"
        launch_services = case == "restore"
        record = {
            "case": case,
            "passed": False,
            "timed_out": False,
            "owned_home": str(home),
            "launch_services": launch_services,
            "exit_code_basis": ("launch_services_waiter" if launch_services else "application_process"),
            # open -W has no application exit-code contract.
            "application_exit_code": None,
            "original_binary_sha256": manifest["binary_sha256"],
        }
        manifest["results"].append(record)
        bundle_root = None
        try:
            if launch_services:
                bundle_root, bundle = prepare_restore_bundle(binary, record, evidence)
                # The app receives explicit isolation variables via LaunchServices;
                # its stdout/stderr are separate from the launcher's own output.
                stdout_path.touch(exist_ok=False)
                stderr_path.touch(exist_ok=False)
                command = [
                    "/usr/bin/open",
                    "-n",
                    "-W",
                    "--stdout",
                    str(stdout_path),
                    "--stderr",
                    str(stderr_path),
                ]
                for name in (
                    "CHAU7_NEXT_NATIVE_PARITY_FIXTURE",
                    "CHAU7_NEXT_ISOLATED_TEST_MODE",
                    "CHAU7_NEXT_HOME_ROOT",
                    "HISTFILE",
                ):
                    command.extend(["--env", name + "=" + child_environment[name]])
                command.extend([str(bundle), "--args", "--native-parity-fixture", case])
                process_stdout = evidence / "restore.launcher.stdout"
                process_stderr = evidence / "restore.launcher.stderr"
            else:
                command = [str(binary), "--native-parity-fixture", case]
                process_stdout = stdout_path
                process_stderr = stderr_path
            record["command"] = command
            with process_stdout.open("x") as stdout, process_stderr.open("x") as stderr:
                process = subprocess.Popen(
                    command,
                    cwd=Path(tempfile.gettempdir()).resolve(),
                    env=child_environment,
                    stdout=stdout,
                    stderr=stderr,
                )
                record["launcher_process_id"] = process.pid if launch_services else None
                record["direct_process_id"] = None if launch_services else process.pid
                # Persist ownership before waiting, including when the app stalls.
                (evidence / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
                try:
                    record["exit_code"] = process.wait(timeout=75)
                except subprocess.TimeoutExpired:
                    # Leave process, owned bundle and profile intact for diagnosis.
                    # Never send termination signals on an acceptance timeout.
                    record["timed_out"] = True
                    record["exit_code"] = None
            if not launch_services:
                record["application_exit_code"] = record["exit_code"]
            record["outcome"] = fixture_outcome(stdout_path, case)
            outcome_pid = (record["outcome"] or {}).get("pid")
            record["application_process_id"] = outcome_pid
            record["process_id"] = outcome_pid if launch_services else process.pid
            record["application_pid_verified"] = valid_pid(outcome_pid) and (
                launch_services or outcome_pid == process.pid
            )
            gone = False
            if record["application_pid_verified"] and not record["timed_out"]:
                deadline = time.monotonic() + 5
                while True:
                    gone = application_gone(outcome_pid)
                    if gone or time.monotonic() >= deadline:
                        break
                    time.sleep(0.05)
            record["application_process_gone"] = gone
            record["owned_home_removed"] = not home.exists()
            record["passed"] = case_passed(record)
            # Clean only this driver's exact mkdtemp bundle after the observed app
            # is gone. Negative outcomes still retain logs and the manifest.
            if bundle_root is not None and gone and not record["timed_out"]:
                shutil.rmtree(bundle_root)
                record["owned_bundle_removed"] = not bundle_root.exists()
        except (OSError, subprocess.CalledProcessError) as error:
            record["passed"] = False
            record["error"] = str(error)
            # An uncertain launch or missing outcome never authorizes cleanup.
            record["owned_home_removed"] = not home.exists()
        success = success and record["passed"]
        print(f"{case}: {'PASS' if record['passed'] else 'FAIL'}")
        (evidence / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        if record["timed_out"]:
            break
    manifest["source_unchanged"] = output(["git", "rev-parse", "HEAD"], cwd=repo) == revision and not output(
        ["git", "status", "--porcelain"], cwd=repo
    )
    success = success and manifest["source_unchanged"]
    manifest["passed"] = bool(success)
    (evidence / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Evidence: {evidence}")
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
