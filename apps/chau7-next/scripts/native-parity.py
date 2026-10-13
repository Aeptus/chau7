#!/usr/bin/env python3
"""Run owned macOS parity fixtures and retain exact source/binary evidence."""

import argparse
import ctypes
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


ACTIVATION_HANDSHAKE_PREFIX = "native_activation_handshake="
ACTIVATION_ACK_FILENAME = "native-parity-activation.ack"
ACTIVATION_GUARD_ENV = (
    "CHAU7_NEXT_NATIVE_PARITY_FIXTURE",
    "CHAU7_NEXT_ISOLATED_TEST_MODE",
    "CHAU7_NEXT_HOME_ROOT",
    "HISTFILE",
)
ACTIVATION_DEADLINE_SECONDS = 3


def parse_activation_handshake(stderr_text):
    lines = []
    incomplete = False
    for line in stderr_text.splitlines(keepends=True):
        if not line.startswith(ACTIVATION_HANDSHAKE_PREFIX):
            continue
        if not line.endswith("\n"):
            incomplete = True
            continue
        lines.append(line[len(ACTIVATION_HANDSHAKE_PREFIX) :].rstrip("\r\n"))
    # A reader may observe the flushed JSON while its final newline is still
    # being written; wait for the complete record before making a request.
    if incomplete or not lines:
        return None
    if len(lines) != 1:
        raise ValueError("native fixture emitted more than one activation handshake")
    try:
        value = json.loads(lines[0])
    except json.JSONDecodeError as error:
        raise ValueError("native fixture activation handshake is invalid JSON") from error
    if not isinstance(value, dict):
        raise ValueError("native fixture activation handshake must be an object")
    if value.get("stage") != "deminiaturized_surface_reveal":
        raise ValueError("native fixture activation handshake has an unexpected stage")
    if not valid_pid(value.get("pid")):
        raise ValueError("native fixture activation handshake has an invalid PID")
    if not isinstance(value.get("bundle_identifier"), str) or not value["bundle_identifier"]:
        raise ValueError("native fixture activation handshake has no bundle identifier")
    if not isinstance(value.get("bundle_path"), str) or not value["bundle_path"]:
        raise ValueError("native fixture activation handshake has no bundle path")
    if not isinstance(value.get("activation_ack_path"), str) or not value["activation_ack_path"]:
        raise ValueError("native fixture activation handshake has no activation acknowledgement path")
    return value


def _activation_remaining(deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("owned fixture activation exceeded its 3-second total deadline")
    return remaining


def owned_executable_pids(expected_executable, deadline):
    result = subprocess.run(
        ["/bin/ps", "-axo", "pid="],
        check=True,
        capture_output=True,
        text=True,
        timeout=_activation_remaining(deadline),
    )
    _activation_remaining(deadline)
    expected = Path(expected_executable).resolve(strict=True)
    _activation_remaining(deadline)
    matches = []
    for value in result.stdout.split():
        _activation_remaining(deadline)
        if not value.isdigit() or int(value) <= 0:
            continue
        pid = int(value)
        try:
            actual = Path(os.fsdecode(_pid_executable_path(pid))).resolve(strict=True)
        except OSError:
            continue
        _activation_remaining(deadline)
        if actual == expected:
            matches.append(pid)
    return sorted(matches)


def activation_request_command(bundle, environment, window_renderer):
    if environment.get("CHAU7_NEXT_NATIVE_PARITY_FIXTURE") != "1":
        raise ValueError("activation reopen requires the native fixture opt-in guard")
    if environment.get("CHAU7_NEXT_ISOLATED_TEST_MODE") != "1":
        raise ValueError("activation reopen requires the isolated test mode guard")
    if not environment.get("CHAU7_NEXT_HOME_ROOT"):
        raise ValueError("activation reopen requires the owned fixture home guard")
    if environment.get("HISTFILE") != "":
        raise ValueError("activation reopen requires the empty history guard")
    command = ["/usr/bin/open"]
    for name in ACTIVATION_GUARD_ENV:
        command.extend(["--env", name + "=" + environment[name]])
    command.extend(
        [
            "-a",
            str(bundle),
            "--args",
            "--native-parity-fixture",
            "restore",
            "--window-renderer",
            window_renderer,
        ]
    )
    return command


def request_owned_activation(
    bundle,
    bundle_identifier,
    handshake,
    evidence,
    environment,
    window_renderer,
):
    deadline = time.monotonic() + ACTIVATION_DEADLINE_SECONDS
    bundle = Path(bundle).resolve(strict=True)
    executable = bundle / "Contents" / "MacOS" / "chau7-next"
    expected_executable = executable.resolve(strict=True)
    if handshake["bundle_path"] != str(bundle):
        raise ValueError("activation handshake names a different bundle path")
    if handshake["bundle_identifier"] != bundle_identifier:
        raise ValueError("activation handshake names a different bundle identifier")
    try:
        with (bundle / "Contents" / "Info.plist").open("rb") as info_file:
            bundle_info = plistlib.load(info_file)
    except (OSError, plistlib.InvalidFileException) as error:
        raise ValueError("owned bundle path has no readable identifier") from error
    if not isinstance(bundle_info, dict) or bundle_info.get("CFBundleIdentifier") != bundle_identifier:
        raise ValueError("owned bundle path does not have the exact handshake identifier")
    _activation_remaining(deadline)
    home = Path(environment["CHAU7_NEXT_HOME_ROOT"]).resolve(strict=True)
    activation_ack_path = home / ACTIVATION_ACK_FILENAME
    if handshake["activation_ack_path"] != str(activation_ack_path):
        raise ValueError("activation handshake names a different acknowledgement path")
    _activation_remaining(deadline)
    pid = handshake["pid"]
    actual_executable = Path(os.fsdecode(_pid_executable_path(pid))).resolve(strict=True)
    _activation_remaining(deadline)
    if actual_executable != expected_executable:
        raise ValueError("activation handshake PID is not the exact owned executable")
    before = owned_executable_pids(expected_executable, deadline)
    if before != [pid]:
        raise ValueError("expected exactly the handshake PID before LaunchServices reopen")
    command = activation_request_command(bundle, environment, window_renderer)
    _activation_remaining(deadline)
    with (
        (evidence / "restore.activation.stdout").open("x") as stdout,
        (evidence / "restore.activation.stderr").open("x") as stderr,
    ):
        result = subprocess.run(
            command,
            cwd=Path(tempfile.gettempdir()).resolve(),
            env=environment,
            stdout=stdout,
            stderr=stderr,
            check=False,
            timeout=_activation_remaining(deadline),
        )
    _activation_remaining(deadline)
    if result.returncode != 0:
        raise RuntimeError(f"targeted LaunchServices reopen exited {result.returncode}")
    after = owned_executable_pids(expected_executable, deadline)
    if after != [pid]:
        raise RuntimeError("LaunchServices reopen changed the exact owned application PID set")
    _activation_remaining(deadline)
    acknowledgement_payload = b"owned activation request completed\n"
    with activation_ack_path.open("xb") as acknowledgement:
        acknowledgement.write(acknowledgement_payload)
    _activation_remaining(deadline)
    return {
        "command": command,
        "pid_before": before,
        "pid_after": after,
        "exit_code": result.returncode,
        "activation_ack_path": str(activation_ack_path),
        "activation_ack_bytes": len(acknowledgement_payload),
        "activation_ack_sha256": hashlib.sha256(acknowledgement_payload).hexdigest(),
    }


def wait_owned_fixture(
    process,
    record,
    bundle,
    stderr_path,
    evidence,
    child_environment,
    window_renderer,
):
    """Wait for an already-launched owned restore fixture and request activation once."""
    deadline = time.monotonic() + 75
    record.setdefault("activation_request_attempted", False)
    record.setdefault("activation_request_passed", False)
    while True:
        if not record["activation_request_attempted"]:
            try:
                handshake = parse_activation_handshake(stderr_path.read_text(errors="replace"))
            except (OSError, ValueError) as error:
                record["activation_request_attempted"] = True
                record["activation_request_error"] = str(error)
            else:
                if handshake is not None:
                    record["activation_request_attempted"] = True
                    record["activation_handshake"] = handshake
                    if process.poll() is not None:
                        record["activation_request_error"] = "owned fixture exited before its activation request"
                    else:
                        try:
                            record["activation_request"] = request_owned_activation(
                                bundle,
                                record["bundle_identifier"],
                                handshake,
                                evidence,
                                child_environment,
                                window_renderer,
                            )
                            record["activation_request_passed"] = True
                        except (
                            OSError,
                            RuntimeError,
                            ValueError,
                            subprocess.SubprocessError,
                        ) as error:
                            record["activation_request_error"] = str(error)
        exit_code = process.poll()
        if exit_code is not None:
            record["exit_code"] = exit_code
            if not record["activation_request_attempted"]:
                record["activation_request_attempted"] = True
                record["activation_request_error"] = "owned fixture exited before emitting an activation handshake"
            return exit_code
        if time.monotonic() >= deadline:
            # Leave the fixture, owned bundle and profile intact for diagnosis.
            # Never send termination signals on an acceptance timeout.
            record["timed_out"] = True
            record["exit_code"] = None
            if not record["activation_request_attempted"]:
                record["activation_request_attempted"] = True
                record["activation_request_error"] = "owned fixture did not emit an activation handshake before timeout"
            return None
        time.sleep(0.05)


def _pid_executable_path(pid):
    library = ctypes.CDLL("/usr/lib/libproc.dylib")
    proc_pidpath = library.proc_pidpath
    proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    length = proc_pidpath(pid, buffer, len(buffer))
    if length <= 0:
        raise OSError(f"could not resolve exact executable path for PID {pid}")
    return buffer.value


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
        and (not record.get("launch_services") or record.get("activation_request_passed") is True)
    )


def cases_for(case):
    return ("restore", "settings", "editor", "cache") if case == "all" else (case,)


def fixture_locale_for(case, locales):
    if len(locales) > 1:
        raise ValueError("--fixture-locale may be supplied only once")
    if locales and case != "accessibility":
        raise ValueError("--fixture-locale is only supported with --case accessibility")
    return locales[0] if locales else "system"


def argument_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--case",
        choices=(
            "all",
            "restore",
            "settings",
            "editor",
            "cache",
            "accessibility",
            "keyboard",
        ),
        default="all",
    )
    parser.add_argument(
        "--fixture-locale",
        choices=("system", "en", "fr", "es", "ar", "he"),
        action="append",
        default=[],
        help="Process-local accessibility fixture locale; only used with --case accessibility",
    )
    parser.add_argument(
        "--window-renderer",
        choices=("auto", "metal", "software", "auto-device-failure"),
        default="auto",
        help="Optional fixture-only complete window backend; injection occurs before Metal calls",
    )
    parser.add_argument(
        "--toolchain",
        default="1.99.0",
        help="Exact already installed Rust release; never installed or upgraded by this script",
    )
    return parser


def main():
    parser = argument_parser()
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("native parity fixtures require macOS")
    try:
        fixture_locale = fixture_locale_for(args.case, args.fixture_locale)
    except ValueError as error:
        parser.error(str(error))
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
        "window_renderer": args.window_renderer,
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
    cases = cases_for(args.case)
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
            "fixture_locale": fixture_locale if case == "accessibility" else None,
            "passed": False,
            "timed_out": False,
            "owned_home": str(home),
            "launch_services": launch_services,
            "exit_code_basis": ("launch_services_waiter" if launch_services else "application_process"),
            # open -W has no application exit-code contract.
            "application_exit_code": None,
            "original_binary_sha256": manifest["binary_sha256"],
            "activation_request_attempted": False if launch_services else None,
            "activation_request_passed": False if launch_services else None,
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
                command.extend(
                    [
                        str(bundle),
                        "--args",
                        "--native-parity-fixture",
                        case,
                        "--window-renderer",
                        args.window_renderer,
                    ]
                )
                process_stdout = evidence / "restore.launcher.stdout"
                process_stderr = evidence / "restore.launcher.stderr"
            else:
                command = [
                    str(binary),
                    "--native-parity-fixture",
                    case,
                    "--window-renderer",
                    args.window_renderer,
                ]
                if case == "accessibility":
                    command.extend(["--fixture-locale", fixture_locale])
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
                if launch_services:
                    wait_owned_fixture(
                        process,
                        record,
                        bundle,
                        stderr_path,
                        evidence,
                        child_environment,
                        args.window_renderer,
                    )
                else:
                    try:
                        record["exit_code"] = process.wait(timeout=75)
                    except subprocess.TimeoutExpired:
                        # Leave process and owned profile intact for diagnosis.
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
