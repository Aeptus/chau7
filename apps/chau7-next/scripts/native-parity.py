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
import stat
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


def prepare_restore_bundle(binary, record, evidence, case="restore"):
    if case not in LAUNCH_SERVICES_CASES:
        raise ValueError("unsupported owned LaunchServices fixture case")
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
    with (evidence / f"{case}.codesign.log").open("x") as log:
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


RESTORE_CAPTURE_NAMES = {"stdout": "restore.stdout", "stderr": "restore.stderr"}
LAUNCH_SERVICES_CASES = frozenset(("restore", "keyboard"))


def owned_restore_bundle_root(record, bundle_root):
    if record.get("case") not in LAUNCH_SERVICES_CASES:
        raise ValueError("owned LaunchServices bundle is not bound to an allowed fixture case")
    root = Path(bundle_root)
    if root.is_symlink():
        raise ValueError("owned fixture bundle root must not be a symlink")
    try:
        resolved_root = root.resolve(strict=True)
        recorded_root = Path(record["owned_bundle_root"])
        recorded_bundle = Path(record["owned_bundle"])
    except (KeyError, OSError) as error:
        raise ValueError("owned fixture bundle root is not available") from error
    if recorded_root.is_symlink() or recorded_root.resolve(strict=True) != resolved_root:
        raise ValueError("owned fixture bundle root does not match its recorded path")
    if recorded_bundle.is_symlink() or recorded_bundle != resolved_root / "Chau7 Next Native Fixture.app":
        raise ValueError("owned fixture bundle path does not match its recorded root")
    try:
        root_info = resolved_root.lstat()
        bundle_info = recorded_bundle.lstat()
    except OSError as error:
        raise ValueError("owned fixture bundle path is not available") from error
    if not stat.S_ISDIR(root_info.st_mode) or not stat.S_ISDIR(bundle_info.st_mode):
        raise ValueError("owned fixture bundle path must contain real directories")
    return resolved_root


def create_owned_restore_capture(record, bundle_root, name):
    if name not in RESTORE_CAPTURE_NAMES.values():
        raise ValueError("unsupported owned fixture capture name")
    root = owned_restore_bundle_root(record, bundle_root)
    capture = root / name
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(capture, flags, 0o600)
    try:
        capture_info = os.fstat(descriptor)
        if not stat.S_ISREG(capture_info.st_mode) or capture_info.st_nlink != 1:
            raise OSError("owned fixture capture is not a new regular file")
        os.fchmod(descriptor, 0o600)
    finally:
        os.close(descriptor)
    return capture


def _archive_owned_restore_capture(record, bundle_root, evidence, name):
    if name not in RESTORE_CAPTURE_NAMES.values():
        raise ValueError("unsupported owned fixture capture name")
    root = owned_restore_bundle_root(record, bundle_root)
    capture = root / name
    capture_key = next(key for key, value in RESTORE_CAPTURE_NAMES.items() if value == name)
    capture_paths = record.get("launch_services_capture_paths")
    if not isinstance(capture_paths, dict) or capture_paths.get(capture_key) != str(capture):
        raise ValueError("owned fixture capture does not match its recorded path")
    if capture.is_symlink():
        raise ValueError("owned fixture capture must not be a symlink")
    source_descriptor = os.open(
        capture,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0),
    )
    try:
        source_stream = os.fdopen(source_descriptor, "rb")
        source_descriptor = -1
        with source_stream as source:
            capture_info = os.fstat(source.fileno())
            if not stat.S_ISREG(capture_info.st_mode) or capture_info.st_nlink != 1:
                raise ValueError("owned fixture capture is not a single-link regular file")
            evidence_root = Path(evidence)
            if evidence_root.is_symlink():
                raise ValueError("fixture evidence directory must not be a symlink")
            evidence_root = evidence_root.resolve(strict=True)
            if not evidence_root.is_dir():
                raise ValueError("fixture evidence path must be a directory")
            destination = evidence_root / name
            destination_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
            destination_descriptor = os.open(destination, destination_flags, 0o600)
            with os.fdopen(destination_descriptor, "wb") as archived:
                archived_info = os.fstat(archived.fileno())
                if not stat.S_ISREG(archived_info.st_mode) or archived_info.st_nlink != 1:
                    raise OSError("fixture evidence capture is not a new regular file")
                os.fchmod(archived.fileno(), 0o600)
                shutil.copyfileobj(source, archived)
    finally:
        if source_descriptor >= 0:
            os.close(source_descriptor)
    return evidence_root / name


def archive_and_remove_owned_restore_bundle(record, bundle_root, evidence):
    if (
        record.get("application_pid_verified") is not True
        or record.get("application_process_gone") is not True
        or record.get("timed_out") is not False
    ):
        raise ValueError("owned fixture captures require verified application retirement")
    root = owned_restore_bundle_root(record, bundle_root)
    capture_paths = record.get("launch_services_capture_paths")
    expected_paths = {key: str(root / name) for key, name in RESTORE_CAPTURE_NAMES.items()}
    if capture_paths != expected_paths:
        raise ValueError("owned fixture capture paths do not match the exact bundle root")
    evidence_path = Path(evidence)
    if evidence_path.is_symlink():
        raise ValueError("fixture evidence directory must not be a symlink")
    evidence_root = evidence_path.resolve(strict=True)
    if evidence_path != evidence_root:
        raise ValueError("fixture evidence directory must use its exact canonical path")
    archive_paths = record.get("launch_services_capture_archive_paths")
    expected_archive_paths = {key: str(evidence_root / name) for key, name in RESTORE_CAPTURE_NAMES.items()}
    if archive_paths != expected_archive_paths:
        raise ValueError("owned fixture archive paths do not match the exact evidence directory")
    for name in RESTORE_CAPTURE_NAMES.values():
        _archive_owned_restore_capture(record, root, evidence_root, name)
    record["launch_services_captures_archived"] = True
    shutil.rmtree(root)
    record["owned_bundle_removed"] = not root.exists()


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
ORDERED_FRONT_ACTIVATION_HANDSHAKE_PREFIX = "native_ordered_front_activation="
FULLSCREEN_REACTIVATION_HANDSHAKE_PREFIX = "native_fullscreen_reactivation="
FULLSCREEN_FOCUS_YIELD_HANDSHAKE_PREFIX = "native_fullscreen_focus_yield="
ACTIVATION_ACK_FILENAME = "native-parity-activation.ack"
ORDERED_FRONT_ACTIVATION_ACK_FILENAME = "native-parity-ordered-front-activation.ack"
FULLSCREEN_REACTIVATION_ACK_FILENAME = "native-parity-fullscreen-reactivation.ack"
FULLSCREEN_FOCUS_YIELD_ACK_FILENAME = "native-parity-fullscreen-focus-yield.ack"
FOCUS_COMPANION_READY_FILENAME = "native-parity-focus-companion.ready"
FOCUS_COMPANION_STOP_FILENAME = "native-parity-focus-companion.stop"
FOCUS_COMPANION_BUNDLE_IDENTIFIER_PREFIX = "com.chau7.next.native-parity-focus-companion."
FOCUS_COMPANION_BUNDLE_NAME = "Chau7 Next Native Focus Companion.app"
ACTIVATION_ACK_FILENAME_BY_STAGE = {
    "ordered_front_surface_reveal": ORDERED_FRONT_ACTIVATION_ACK_FILENAME,
    "deminiaturized_surface_reveal": ACTIVATION_ACK_FILENAME,
    "fullscreen_application_reactivation": FULLSCREEN_REACTIVATION_ACK_FILENAME,
}
ACTIVATION_EVIDENCE_PREFIX_BY_STAGE = {
    "ordered_front_surface_reveal": "restore.ordered_front_activation",
    "deminiaturized_surface_reveal": "restore.activation",
    "fullscreen_application_reactivation": "restore.fullscreen_reactivation",
}
ACTIVATION_GUARD_ENV = (
    "CHAU7_NEXT_NATIVE_PARITY_FIXTURE",
    "CHAU7_NEXT_ISOLATED_TEST_MODE",
    "CHAU7_NEXT_HOME_ROOT",
    "HISTFILE",
)
ACTIVATION_DEADLINE_SECONDS = 6
FULLSCREEN_REACTIVATION_DEADLINE_SECONDS = 8
FOCUS_COMPANION_READY_DEADLINE_SECONDS = 10
FOCUS_COMPANION_STOP_DEADLINE_SECONDS = 5


def _parse_activation_handshake(stderr_text, prefix, expected_stage, label):
    lines = []
    incomplete = False
    for line in stderr_text.splitlines(keepends=True):
        if not line.startswith(prefix):
            continue
        if not line.endswith("\n"):
            incomplete = True
            continue
        lines.append(line[len(prefix) :].rstrip("\r\n"))
    # A reader may observe the flushed JSON while its final newline is still
    # being written; wait for the complete record before making a request.
    if incomplete or not lines:
        return None
    if len(lines) != 1:
        raise ValueError(f"native fixture emitted more than one {label} handshake")
    try:
        value = json.loads(lines[0])
    except json.JSONDecodeError as error:
        raise ValueError(f"native fixture {label} handshake is invalid JSON") from error
    if not isinstance(value, dict):
        raise ValueError(f"native fixture {label} handshake must be an object")
    if value.get("stage") != expected_stage:
        raise ValueError(f"native fixture {label} handshake has an unexpected stage")
    if not valid_pid(value.get("pid")):
        raise ValueError(f"native fixture {label} handshake has an invalid PID")
    if not isinstance(value.get("bundle_identifier"), str) or not value["bundle_identifier"]:
        raise ValueError(f"native fixture {label} handshake has no bundle identifier")
    if not isinstance(value.get("bundle_path"), str) or not value["bundle_path"]:
        raise ValueError(f"native fixture {label} handshake has no bundle path")
    if not isinstance(value.get("activation_ack_path"), str) or not value["activation_ack_path"]:
        raise ValueError(f"native fixture {label} handshake has no activation acknowledgement path")
    return value


def parse_activation_handshake(stderr_text):
    return _parse_activation_handshake(
        stderr_text,
        ACTIVATION_HANDSHAKE_PREFIX,
        "deminiaturized_surface_reveal",
        "activation",
    )


def parse_ordered_front_activation_handshake(stderr_text):
    return _parse_activation_handshake(
        stderr_text,
        ORDERED_FRONT_ACTIVATION_HANDSHAKE_PREFIX,
        "ordered_front_surface_reveal",
        "ordered-front activation",
    )


def parse_fullscreen_reactivation_handshake(stderr_text):
    return _parse_activation_handshake(
        stderr_text,
        FULLSCREEN_REACTIVATION_HANDSHAKE_PREFIX,
        "fullscreen_application_reactivation",
        "fullscreen reactivation",
    )


def parse_fullscreen_focus_yield_handshake(stderr_text):
    return _parse_activation_handshake(
        stderr_text,
        FULLSCREEN_FOCUS_YIELD_HANDSHAKE_PREFIX,
        "fullscreen_application_focus_yield",
        "fullscreen focus-yield",
    )


def _activation_remaining(deadline, deadline_seconds=ACTIVATION_DEADLINE_SECONDS):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError(f"owned fixture activation exceeded its {deadline_seconds:g}-second total deadline")
    return remaining


def _owned_handshake_executable(bundle, bundle_identifier, handshake):
    bundle = Path(bundle).resolve(strict=True)
    expected_executable = (bundle / "Contents" / "MacOS" / "chau7-next").resolve(strict=True)
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
    return bundle, expected_executable, handshake["pid"]


def _pump_appkit_run_loop():
    """Deliver queued AppKit/Workspace notifications on this process's main run loop."""
    ctypes.CDLL("/System/Library/Frameworks/AppKit.framework/AppKit")
    core_foundation = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    run_in_mode = core_foundation.CFRunLoopRunInMode
    run_in_mode.argtypes = [ctypes.c_void_p, ctypes.c_double, ctypes.c_ubyte]
    run_in_mode.restype = ctypes.c_int32
    default_mode = ctypes.c_void_p.in_dll(core_foundation, "kCFRunLoopDefaultMode").value
    if not default_mode:
        raise RuntimeError("Core Foundation default run-loop mode is unavailable")
    run_in_mode(default_mode, 0.01, True)


def _read_frontmost_application_pid():
    runtime = ctypes.CDLL("/usr/lib/libobjc.A.dylib")
    get_class = runtime.objc_getClass
    get_class.argtypes = [ctypes.c_char_p]
    get_class.restype = ctypes.c_void_p
    register_selector = runtime.sel_registerName
    register_selector.argtypes = [ctypes.c_char_p]
    register_selector.restype = ctypes.c_void_p
    send_address = ctypes.cast(runtime.objc_msgSend, ctypes.c_void_p).value
    send_object = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)(send_address)
    send_int = ctypes.CFUNCTYPE(ctypes.c_int32, ctypes.c_void_p, ctypes.c_void_p)(send_address)
    workspace = send_object(get_class(b"NSWorkspace"), register_selector(b"sharedWorkspace"))
    application = send_object(workspace, register_selector(b"frontmostApplication"))
    if not application:
        return None
    pid = send_int(application, register_selector(b"processIdentifier"))
    return pid if pid > 0 else None


def frontmost_application_pid():
    """Read a fresh frontmost PID after dispatching pending Workspace updates."""
    _pump_appkit_run_loop()
    return _read_frontmost_application_pid()


def wait_for_frontmost_application(pid, deadline):
    while time.monotonic() < deadline:
        if frontmost_application_pid() == pid:
            return pid
        time.sleep(min(0.05, max(0, deadline - time.monotonic())))
    raise TimeoutError(f"owned fixture PID {pid} did not become the frontmost application")


def prepare_focus_companion_bundle(binary, evidence):
    root = Path(tempfile.mkdtemp(prefix="chau7-native-focus-companion-")).resolve()
    bundle = root / FOCUS_COMPANION_BUNDLE_NAME
    executable = bundle / "Contents" / "MacOS" / "chau7-next"
    executable.parent.mkdir(parents=True)
    shutil.copy2(binary, executable)
    bundle_identifier = FOCUS_COMPANION_BUNDLE_IDENTIFIER_PREFIX + uuid.uuid4().hex
    with (bundle / "Contents" / "Info.plist").open("xb") as plist:
        plistlib.dump(
            {
                "CFBundleExecutable": "chau7-next",
                "CFBundleIdentifier": bundle_identifier,
                "CFBundleName": "Chau7 Next Native Focus Companion",
                "CFBundleDisplayName": "Chau7 Next Native Focus Companion",
                "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1",
                "CFBundleShortVersionString": "1",
                "NSPrincipalClass": "NSApplication",
                "LSUIElement": False,
                "LSBackgroundOnly": False,
                "NSHighResolutionCapable": True,
            },
            plist,
        )
    with (evidence / "restore.focus_companion.codesign.log").open("x") as log:
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
    return root, bundle, executable.resolve(strict=True), bundle_identifier


def focus_companion_command(bundle, stdout_path, stderr_path, environment):
    command = ["/usr/bin/open", "-n", "-W", "--stdout", str(stdout_path), "--stderr", str(stderr_path)]
    for name in ("HOME", "ZDOTDIR") + ACTIVATION_GUARD_ENV:
        command.extend(["--env", name + "=" + environment[name]])
    command.extend(
        [
            str(bundle),
            "--args",
            "--native-parity-fixture",
            "focus-companion",
            "--window-renderer",
            "software",
        ]
    )
    return command


def _focus_companion_summary(state):
    fields = (
        "bundle_root",
        "bundle_path",
        "bundle_identifier",
        "executable_path",
        "home",
        "ready_path",
        "stop_path",
        "launch_command",
        "launcher_process_id",
        "application_process_id",
        "ready",
        "stop_requested",
        "process_exit_code",
        "process_gone",
        "bundle_removed",
        "home_removed",
        "outcome",
    )
    return {name: state[name] for name in fields if name in state}


def launch_focus_companion(binary, evidence, parent_environment, state):
    root, bundle, executable, bundle_identifier = prepare_focus_companion_bundle(binary, evidence)
    home = Path(tempfile.gettempdir()).resolve() / f"chau7-native-fixture-{uuid.uuid4()}"
    environment = dict(parent_environment)
    environment.update(
        {
            "HOME": str(home),
            "ZDOTDIR": str(home),
            "CHAU7_NEXT_HOME_ROOT": str(home),
            "CHAU7_NEXT_ISOLATED_TEST_MODE": "1",
            "CHAU7_NEXT_NATIVE_PARITY_FIXTURE": "1",
            "HISTFILE": "",
        }
    )
    stdout_path = root / "focus-companion.stdout"
    stderr_path = root / "focus-companion.stderr"
    command = focus_companion_command(bundle, stdout_path, stderr_path, environment)
    state.update(
        {
            "bundle_root": str(root),
            "bundle_path": str(bundle.resolve(strict=True)),
            "bundle_identifier": bundle_identifier,
            "executable_path": str(executable),
            "home": str(home),
            "ready_path": str(home / FOCUS_COMPANION_READY_FILENAME),
            "stop_path": str(home / FOCUS_COMPANION_STOP_FILENAME),
            "launch_command": command,
            "launcher_process_id": None,
            "application_process_id": None,
            "stop_requested": False,
            "process_exit_code": None,
            "process_gone": False,
            "bundle_removed": False,
            "home_removed": False,
            "stdout_path": str(stdout_path),
            "stderr_path": str(stderr_path),
            "stdout_archive_path": str(evidence / "restore.focus_companion.stdout"),
            "stderr_archive_path": str(evidence / "restore.focus_companion.stderr"),
        }
    )
    with stdout_path.open("x") as stdout, stderr_path.open("x") as stderr:
        process = subprocess.Popen(
            command,
            cwd=Path(tempfile.gettempdir()).resolve(),
            env=environment,
            stdout=stdout,
            stderr=stderr,
        )
    state["process"] = process
    state["launcher_process_id"] = process.pid
    deadline = time.monotonic() + FOCUS_COMPANION_READY_DEADLINE_SECONDS
    while time.monotonic() < deadline:
        if process.poll() is not None:
            state["process_exit_code"] = process.returncode
            raise RuntimeError("focus companion launcher exited before its ready marker")
        ready_path = Path(state["ready_path"])
        if ready_path.exists() or ready_path.is_symlink():
            if ready_path.is_symlink():
                raise ValueError("focus companion ready marker must not be a symlink")
            ready = json.loads(ready_path.read_text())
            if not isinstance(ready, dict):
                raise ValueError("focus companion ready marker must contain an object")
            expected = {
                "bundle_identifier": state["bundle_identifier"],
                "bundle_path": state["bundle_path"],
                "executable_path": state["executable_path"],
                "renderer": "software",
            }
            for name, value in expected.items():
                if ready.get(name) != value:
                    raise ValueError(f"focus companion ready marker has an unexpected {name}")
            if any(ready.get(name) is not True for name in ("app_active", "window_visible", "window_key")):
                raise ValueError("focus companion is not active, visible, and key")
            pid = ready.get("pid")
            if not valid_pid(pid):
                raise ValueError("focus companion ready marker has an invalid PID")
            actual = Path(os.fsdecode(_pid_executable_path(pid))).resolve(strict=True)
            if actual != executable:
                raise ValueError("focus companion PID is not the exact owned executable")
            if owned_executable_pids(executable, deadline) != [pid]:
                raise ValueError("expected exactly the ready focus companion PID")
            if frontmost_application_pid() == pid:
                state["application_process_id"] = pid
                state["ready"] = ready
                return
        time.sleep(0.05)
    raise TimeoutError("focus companion did not become the exact foreground application before timeout")


def stop_focus_companion(state, deadline=None):
    process = state.get("process")
    if process is None:
        return _focus_companion_summary(state)
    if state.get("process_gone") is not True:
        home = Path(state["home"])
        expected_home_parent = Path(tempfile.gettempdir()).resolve()
        if (
            home.parent != expected_home_parent
            or not home.name.startswith("chau7-native-fixture-")
            or (home.exists() and home.is_symlink())
        ):
            raise ValueError("focus companion home is outside its owned temporary profile")
        pid = state.get("application_process_id")
        if not valid_pid(pid):
            executable = Path(state["executable_path"]).resolve(strict=True)
            pids = owned_executable_pids(
                executable,
                time.monotonic() + FOCUS_COMPANION_STOP_DEADLINE_SECONDS,
            )
            if len(pids) > 1:
                raise RuntimeError("focus companion bundle resolved to multiple application PIDs")
            if pids:
                pid = pids[0]
                state["application_process_id"] = pid
        if not state.get("stop_requested") and (
            (valid_pid(pid) and not application_gone(pid)) or process.poll() is None
        ):
            stop_path = Path(state["stop_path"])
            if stop_path != home / FOCUS_COMPANION_STOP_FILENAME:
                raise ValueError("focus companion stop path does not match its owned profile")
            if not home.is_dir():
                raise ValueError("focus companion profile disappeared before its stop request")
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
            descriptor = os.open(stop_path, flags, 0o600)
            try:
                with os.fdopen(descriptor, "wb") as stop_file:
                    descriptor = -1
                    stop_file.write(b"stop owned fullscreen focus companion\n")
            finally:
                if descriptor >= 0:
                    os.close(descriptor)
            state["stop_requested"] = True
        limit = time.monotonic() + FOCUS_COMPANION_STOP_DEADLINE_SECONDS
        if deadline is not None:
            limit = min(limit, deadline)
        try:
            state["process_exit_code"] = process.wait(timeout=max(0.01, limit - time.monotonic()))
        except subprocess.TimeoutExpired as error:
            raise TimeoutError("focus companion did not exit after its owned stop request") from error
        if state["process_exit_code"] != 0:
            raise RuntimeError(f"focus companion launcher exited {state['process_exit_code']}")
        if valid_pid(pid) and not application_gone(pid):
            raise TimeoutError("focus companion PID remained after its launcher exited")
        executable = Path(state["executable_path"]).resolve(strict=True)
        if owned_executable_pids(executable, limit):
            raise RuntimeError("focus companion executable still has a running application PID")
        state["process_gone"] = True
    for source_name, archive_name in (
        ("stdout_path", "stdout_archive_path"),
        ("stderr_path", "stderr_archive_path"),
    ):
        source = Path(state[source_name])
        archive = Path(state[archive_name])
        if source.exists() and not archive.exists():
            shutil.copy2(source, archive)
    if state.get("outcome") is None:
        outcome = fixture_outcome(Path(state["stdout_path"]), "focus-companion")
        state["outcome"] = outcome
        details = (outcome or {}).get("details") or {}
        if not isinstance(details, dict):
            details = {}
        if (
            outcome is None
            or outcome.get("passed") is not True
            or outcome.get("pid") != state.get("application_process_id")
            or outcome.get("owned_resources_closed") is not True
            or outcome.get("owned_profile_removed") is not True
            or details.get("stopped_by") != "owned_stop_file"
        ):
            raise RuntimeError("focus companion did not report a clean owned stop-file exit")
    bundle_root = Path(state["bundle_root"])
    if bundle_root.parent != Path(tempfile.gettempdir()).resolve() or not bundle_root.name.startswith(
        "chau7-native-focus-companion-"
    ):
        raise ValueError("focus companion bundle is outside its owned temporary directory")
    if bundle_root.exists():
        if bundle_root.is_symlink():
            raise ValueError("focus companion bundle root became a symlink")
        shutil.rmtree(bundle_root)
    state["bundle_removed"] = not bundle_root.exists()
    home = Path(state["home"])
    if home.parent != Path(tempfile.gettempdir()).resolve() or not home.name.startswith("chau7-native-fixture-"):
        raise ValueError("focus companion home is outside its owned temporary profile")
    if home.exists():
        if home.is_symlink():
            raise ValueError("focus companion home became a symlink")
        shutil.rmtree(home)
    state["home_removed"] = not home.exists()
    return _focus_companion_summary(state)


def request_owned_focus_yield(bundle, bundle_identifier, handshake, evidence, environment, primary_pid, state):
    bundle, executable, pid = _owned_handshake_executable(bundle, bundle_identifier, handshake)
    if pid != primary_pid or Path(os.fsdecode(_pid_executable_path(pid))).resolve(strict=True) != executable:
        raise ValueError("focus-yield handshake PID is not the exact owned primary application")
    home = Path(environment["CHAU7_NEXT_HOME_ROOT"]).resolve(strict=True)
    acknowledgement_path = home / FULLSCREEN_FOCUS_YIELD_ACK_FILENAME
    if handshake["activation_ack_path"] != str(acknowledgement_path):
        raise ValueError("focus-yield handshake names a different acknowledgement path")
    launch_focus_companion(executable, evidence, environment, state)
    with acknowledgement_path.open("xb") as acknowledgement:
        acknowledgement.write(b"owned fullscreen focus companion is foreground and key\n")
    return {
        "primary_pid": pid,
        "companion_pid": state["application_process_id"],
        "frontmost_pid": state["application_process_id"],
        "activation_ack_path": str(acknowledgement_path),
    }


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
    before_acknowledgement=None,
    deadline_seconds=ACTIVATION_DEADLINE_SECONDS,
):
    deadline = time.monotonic() + deadline_seconds
    bundle, expected_executable, pid = _owned_handshake_executable(bundle, bundle_identifier, handshake)
    _activation_remaining(deadline, deadline_seconds)
    stage = handshake.get("stage")
    if not isinstance(stage, str) or stage not in ACTIVATION_ACK_FILENAME_BY_STAGE:
        raise ValueError("activation handshake has an unsupported stage")
    home = Path(environment["CHAU7_NEXT_HOME_ROOT"]).resolve(strict=True)
    activation_ack_path = home / ACTIVATION_ACK_FILENAME_BY_STAGE[stage]
    if handshake["activation_ack_path"] != str(activation_ack_path):
        raise ValueError("activation handshake names a different acknowledgement path")
    _activation_remaining(deadline, deadline_seconds)
    actual_executable = Path(os.fsdecode(_pid_executable_path(pid))).resolve(strict=True)
    _activation_remaining(deadline, deadline_seconds)
    if actual_executable != expected_executable:
        raise ValueError("activation handshake PID is not the exact owned executable")
    before = owned_executable_pids(expected_executable, deadline)
    if before != [pid]:
        raise ValueError("expected exactly the handshake PID before LaunchServices reopen")
    command = activation_request_command(bundle, environment, window_renderer)
    _activation_remaining(deadline, deadline_seconds)
    evidence_prefix = ACTIVATION_EVIDENCE_PREFIX_BY_STAGE[stage]
    with (
        (evidence / f"{evidence_prefix}.stdout").open("x") as stdout,
        (evidence / f"{evidence_prefix}.stderr").open("x") as stderr,
    ):
        result = subprocess.run(
            command,
            cwd=Path(tempfile.gettempdir()).resolve(),
            env=environment,
            stdout=stdout,
            stderr=stderr,
            check=False,
            timeout=_activation_remaining(deadline, deadline_seconds),
        )
    _activation_remaining(deadline, deadline_seconds)
    if result.returncode != 0:
        raise RuntimeError(f"targeted LaunchServices reopen exited {result.returncode}")
    after = owned_executable_pids(expected_executable, deadline)
    if after != [pid]:
        raise RuntimeError("LaunchServices reopen changed the exact owned application PID set")
    _activation_remaining(deadline, deadline_seconds)
    before_ack_result = None
    if before_acknowledgement is not None:
        before_ack_result = before_acknowledgement(deadline)
    _activation_remaining(deadline, deadline_seconds)
    acknowledgement_payload = b"owned activation request completed\n"
    with activation_ack_path.open("xb") as acknowledgement:
        acknowledgement.write(acknowledgement_payload)
    _activation_remaining(deadline, deadline_seconds)
    return {
        "command": command,
        "pid_before": before,
        "pid_after": after,
        "exit_code": result.returncode,
        "activation_ack_path": str(activation_ack_path),
        "activation_ack_bytes": len(acknowledgement_payload),
        "activation_ack_sha256": hashlib.sha256(acknowledgement_payload).hexdigest(),
        "before_acknowledgement": before_ack_result,
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
    """Wait for an owned restore fixture and request each activation stage once."""
    deadline = time.monotonic() + 75
    record.setdefault("ordered_front_activation_request_attempted", False)
    record.setdefault("ordered_front_activation_request_passed", False)
    record.setdefault("fullscreen_focus_yield_request_attempted", False)
    record.setdefault("fullscreen_focus_yield_request_passed", False)
    record.setdefault("fullscreen_reactivation_request_attempted", False)
    record.setdefault("fullscreen_reactivation_request_passed", False)
    record.setdefault("activation_request_attempted", False)
    record.setdefault("activation_request_passed", False)
    focus_companion = {}
    while True:
        try:
            stderr_text = stderr_path.read_text(errors="replace")
        except OSError as error:
            stderr_text = ""
            if not record["ordered_front_activation_request_attempted"]:
                record["ordered_front_activation_request_attempted"] = True
                record["ordered_front_activation_request_error"] = str(error)
            if not record["fullscreen_focus_yield_request_attempted"]:
                record["fullscreen_focus_yield_request_attempted"] = True
                record["fullscreen_focus_yield_request_error"] = str(error)
            if not record["fullscreen_reactivation_request_attempted"]:
                record["fullscreen_reactivation_request_attempted"] = True
                record["fullscreen_reactivation_request_error"] = str(error)
            if not record["activation_request_attempted"]:
                record["activation_request_attempted"] = True
                record["activation_request_error"] = str(error)

        if not record["ordered_front_activation_request_attempted"]:
            try:
                handshake = parse_ordered_front_activation_handshake(stderr_text)
            except ValueError as error:
                record["ordered_front_activation_request_attempted"] = True
                record["ordered_front_activation_request_error"] = str(error)
            else:
                if handshake is not None:
                    record["ordered_front_activation_request_attempted"] = True
                    record["ordered_front_activation_handshake"] = handshake
                    if process.poll() is not None:
                        record["ordered_front_activation_request_error"] = (
                            "owned fixture exited before its ordered-front activation request"
                        )
                    else:
                        try:
                            record["ordered_front_activation_request"] = request_owned_activation(
                                bundle,
                                record["bundle_identifier"],
                                handshake,
                                evidence,
                                child_environment,
                                window_renderer,
                            )
                            record["ordered_front_activation_request_passed"] = True
                        except (
                            OSError,
                            RuntimeError,
                            ValueError,
                            subprocess.SubprocessError,
                        ) as error:
                            record["ordered_front_activation_request_error"] = str(error)

        if not record["fullscreen_focus_yield_request_attempted"]:
            try:
                handshake = parse_fullscreen_focus_yield_handshake(stderr_text)
            except ValueError as error:
                record["fullscreen_focus_yield_request_attempted"] = True
                record["fullscreen_focus_yield_request_error"] = str(error)
            else:
                if handshake is not None:
                    record["fullscreen_focus_yield_request_attempted"] = True
                    record["fullscreen_focus_yield_handshake"] = handshake
                    if not record["ordered_front_activation_request_passed"]:
                        record["fullscreen_focus_yield_request_error"] = (
                            "fullscreen focus-yield handshake appeared before the ordered-front activation request passed"
                        )
                    elif process.poll() is not None:
                        record["fullscreen_focus_yield_request_error"] = (
                            "owned fixture exited before its fullscreen focus-yield request"
                        )
                    elif handshake["pid"] != (record.get("ordered_front_activation_handshake") or {}).get("pid"):
                        record["fullscreen_focus_yield_request_error"] = (
                            "fullscreen focus-yield handshake names a different primary application PID"
                        )
                    else:
                        try:
                            record["fullscreen_focus_yield_request"] = request_owned_focus_yield(
                                bundle,
                                record["bundle_identifier"],
                                handshake,
                                evidence,
                                child_environment,
                                record["ordered_front_activation_handshake"]["pid"],
                                focus_companion,
                            )
                            record["fullscreen_focus_yield_request_passed"] = True
                        except (
                            OSError,
                            RuntimeError,
                            ValueError,
                            subprocess.SubprocessError,
                        ) as error:
                            record["fullscreen_focus_yield_request_error"] = str(error)
                        finally:
                            record["focus_companion"] = _focus_companion_summary(focus_companion)

        # The fullscreen fixture runs before it minimizes the window and emits
        # the later deminiaturized-surface handshake. It follows an actual
        # application focus loss driven by the owned companion process.
        if not record["fullscreen_reactivation_request_attempted"]:
            try:
                handshake = parse_fullscreen_reactivation_handshake(stderr_text)
            except ValueError as error:
                record["fullscreen_reactivation_request_attempted"] = True
                record["fullscreen_reactivation_request_error"] = str(error)
            else:
                if handshake is not None:
                    record["fullscreen_reactivation_request_attempted"] = True
                    record["fullscreen_reactivation_handshake"] = handshake
                    if not record["ordered_front_activation_request_passed"]:
                        record["fullscreen_reactivation_request_error"] = (
                            "fullscreen reactivation handshake appeared before the ordered-front activation request passed"
                        )
                    elif not record["fullscreen_focus_yield_request_passed"]:
                        record["fullscreen_reactivation_request_error"] = (
                            "fullscreen reactivation handshake appeared before the fullscreen focus-yield request passed"
                        )
                    elif handshake["pid"] != (record.get("ordered_front_activation_handshake") or {}).get("pid"):
                        record["fullscreen_reactivation_request_error"] = (
                            "fullscreen reactivation handshake names a different primary application PID"
                        )
                    elif process.poll() is not None:
                        record["fullscreen_reactivation_request_error"] = (
                            "owned fixture exited before its fullscreen reactivation request"
                        )
                    else:
                        try:

                            def prepare_reactivation_ack(deadline, primary_pid=handshake["pid"]):
                                wait_for_frontmost_application(primary_pid, deadline)
                                companion = stop_focus_companion(focus_companion, deadline)
                                wait_for_frontmost_application(primary_pid, deadline)
                                record["focus_companion"] = companion
                                return {
                                    "primary_frontmost_pid": primary_pid,
                                    "companion": companion,
                                }

                            record["fullscreen_reactivation_request"] = request_owned_activation(
                                bundle,
                                record["bundle_identifier"],
                                handshake,
                                evidence,
                                child_environment,
                                window_renderer,
                                before_acknowledgement=prepare_reactivation_ack,
                                deadline_seconds=FULLSCREEN_REACTIVATION_DEADLINE_SECONDS,
                            )
                            record["fullscreen_reactivation_request_passed"] = True
                        except (
                            OSError,
                            RuntimeError,
                            ValueError,
                            subprocess.SubprocessError,
                        ) as error:
                            record["fullscreen_reactivation_request_error"] = str(error)
                        finally:
                            record["focus_companion"] = _focus_companion_summary(focus_companion)

        if not record["activation_request_attempted"]:
            try:
                handshake = parse_activation_handshake(stderr_text)
            except ValueError as error:
                record["activation_request_attempted"] = True
                record["activation_request_error"] = str(error)
            else:
                if handshake is not None:
                    record["activation_request_attempted"] = True
                    record["activation_handshake"] = handshake
                    if not record["ordered_front_activation_request_passed"]:
                        record["activation_request_error"] = (
                            "late activation handshake appeared before the ordered-front activation request passed"
                        )
                    elif not record["fullscreen_reactivation_request_passed"]:
                        record["activation_request_error"] = (
                            "activation handshake appeared before fullscreen reactivation passed"
                        )
                    elif process.poll() is not None:
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
            if focus_companion.get("process") is not None:
                try:
                    stop_focus_companion(focus_companion)
                except (OSError, RuntimeError, TimeoutError, ValueError, subprocess.SubprocessError) as error:
                    record["focus_companion_cleanup_error"] = str(error)
                record["focus_companion"] = _focus_companion_summary(focus_companion)
            record["exit_code"] = exit_code
            if not record["ordered_front_activation_request_attempted"]:
                record["ordered_front_activation_request_attempted"] = True
                record["ordered_front_activation_request_error"] = (
                    "owned fixture exited before emitting an ordered-front activation handshake"
                )
            if not record["fullscreen_reactivation_request_attempted"]:
                record["fullscreen_reactivation_request_attempted"] = True
                record["fullscreen_reactivation_request_error"] = (
                    "owned fixture exited before emitting a fullscreen reactivation handshake"
                )
            if not record["fullscreen_focus_yield_request_attempted"]:
                record["fullscreen_focus_yield_request_attempted"] = True
                record["fullscreen_focus_yield_request_error"] = (
                    "owned fixture exited before emitting a fullscreen focus-yield handshake"
                )
            if not record["activation_request_attempted"]:
                record["activation_request_attempted"] = True
                record["activation_request_error"] = "owned fixture exited before emitting an activation handshake"
            return exit_code
        if time.monotonic() >= deadline:
            # Leave the fixture, owned bundle and profile intact for diagnosis.
            # Never send termination signals on an acceptance timeout.
            record["timed_out"] = True
            record["exit_code"] = None
            if focus_companion.get("process") is not None:
                try:
                    stop_focus_companion(focus_companion)
                except (OSError, RuntimeError, TimeoutError, ValueError, subprocess.SubprocessError) as error:
                    record["focus_companion_cleanup_error"] = str(error)
                record["focus_companion"] = _focus_companion_summary(focus_companion)
            if not record["ordered_front_activation_request_attempted"]:
                record["ordered_front_activation_request_attempted"] = True
                record["ordered_front_activation_request_error"] = (
                    "owned fixture did not emit an ordered-front activation handshake before timeout"
                )
            if not record["fullscreen_reactivation_request_attempted"]:
                record["fullscreen_reactivation_request_attempted"] = True
                record["fullscreen_reactivation_request_error"] = (
                    "owned fixture did not emit a fullscreen reactivation handshake before timeout"
                )
            if not record["fullscreen_focus_yield_request_attempted"]:
                record["fullscreen_focus_yield_request_attempted"] = True
                record["fullscreen_focus_yield_request_error"] = (
                    "owned fixture did not emit a fullscreen focus-yield handshake before timeout"
                )
            if not record["activation_request_attempted"]:
                record["activation_request_attempted"] = True
                record["activation_request_error"] = "owned fixture did not emit an activation handshake before timeout"
            return None
        time.sleep(0.05)


def wait_owned_keyboard_fixture(process, record, bundle):
    """Wait for one initial LaunchServices open; keyboard emits no activation ACKs."""
    deadline = time.monotonic() + 75
    executable = (Path(bundle).resolve(strict=True) / "Contents" / "MacOS" / "chau7-next").resolve(strict=True)
    record["application_executable_path"] = str(executable)
    observed_pid = None
    scan_timeouts = 0
    while True:
        exit_code = process.poll()
        if exit_code is not None:
            if time.monotonic() >= deadline:
                record["timed_out"] = True
                record["exit_code"] = None
                return None
            record["exit_code"] = exit_code
            return exit_code
        if time.monotonic() >= deadline:
            # Preserve uncertain fixture state; never terminate on an acceptance timeout.
            record["timed_out"] = True
            record["exit_code"] = None
            return None
        scan_deadline = min(deadline, time.monotonic() + 5)
        try:
            exact_pids = owned_executable_pids(executable, scan_deadline)
        except (TimeoutError, subprocess.TimeoutExpired):
            scan_timeouts += 1
            record["application_pid_scan_timeouts"] = scan_timeouts
            if time.monotonic() >= deadline:
                record["timed_out"] = True
                record["exit_code"] = None
                return None
            time.sleep(0.05)
            continue
        if len(exact_pids) > 1:
            raise RuntimeError("keyboard LaunchServices bundle resolved to multiple application PIDs")
        if exact_pids:
            if observed_pid is not None and exact_pids != [observed_pid]:
                raise RuntimeError("keyboard LaunchServices application PID changed during initial open")
            observed_pid = exact_pids[0]
            record["application_process_id_observed"] = observed_pid
            record["application_pid_observed_exact_executable"] = True
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
    base = (
        not record.get("timed_out", False)
        and record.get("exit_code") == 0
        and outcome.get("passed") is True
        and outcome.get("owned_resources_closed") is True
        and outcome.get("owned_profile_removed") is True
        and record.get("owned_home_removed") is True
        and record.get("application_pid_verified") is True
        and record.get("application_process_gone") is True
    )
    if not base or not record.get("launch_services"):
        return base
    if (
        record.get("launcher_process_id") == record.get("process_id")
        or not valid_pid(record.get("launcher_process_id"))
        or not valid_pid(record.get("application_process_id"))
        or record.get("application_process_id") != record.get("process_id")
        or record.get("launch_services_captures_archived") is not True
        or record.get("owned_bundle_removed") is not True
    ):
        return False
    if record.get("case") == "restore":
        companion = record.get("focus_companion") or {}
        companion_outcome = companion.get("outcome") or {}
        companion_details = companion_outcome.get("details") or {}
        return (
            record.get("ordered_front_activation_request_passed") is True
            and record.get("fullscreen_focus_yield_request_passed") is True
            and record.get("activation_request_passed") is True
            and record.get("fullscreen_reactivation_request_passed") is True
            and companion.get("process_gone") is True
            and companion.get("bundle_removed") is True
            and companion.get("home_removed") is True
            and companion_outcome.get("passed") is True
            and companion_outcome.get("pid") == companion.get("application_process_id")
            and companion_outcome.get("owned_resources_closed") is True
            and companion_outcome.get("owned_profile_removed") is True
            and companion_details.get("stopped_by") == "owned_stop_file"
        )
    if record.get("case") == "keyboard":
        return record.get("launch_services_initial_open_passed") is True
    return False


def cases_for(case):
    return ("restore", "settings", "editor", "cache") if case == "all" else (case,)


def launch_services_for(case):
    return case in LAUNCH_SERVICES_CASES


def fixture_locale_for(case, locales):
    if len(locales) > 1:
        raise ValueError("--fixture-locale may be supplied only once")
    if locales and case != "accessibility":
        raise ValueError("--fixture-locale is only supported with --case accessibility")
    return locales[0] if locales else "system"


RECEIPT_SCHEMA_VERSION = 1
NATIVE_FEATURE = "native-parity-fixture"


def source_snapshot(repo):
    return {
        "revision": output(["git", "rev-parse", "HEAD"], cwd=repo),
        "tree": output(["git", "rev-parse", "HEAD^{tree}"], cwd=repo),
        "status": output(["git", "status", "--porcelain=v1", "--untracked-files=all"], cwd=repo),
    }


def create_evidence_directory(path):
    requested = Path(path).expanduser().absolute()
    if requested.exists() or requested.is_symlink():
        raise FileExistsError(f"evidence directory already exists: {requested}")
    if not requested.parent.is_dir():
        raise FileNotFoundError(f"evidence parent directory does not exist: {requested.parent}")
    requested.mkdir(mode=0o700)
    return requested.resolve(strict=True)


def file_identity(path, version=None):
    resolved = Path(path).resolve(strict=True)
    if not resolved.is_file():
        raise ValueError(f"toolchain executable is not a file: {resolved}")
    result = {"path": str(resolved), "sha256": sha256(resolved)}
    if version is not None:
        result["version"] = version
    return result


def release_profile_from_environment(environment):
    profile_names = {
        "build_mode": "BUILD_MODE",
        "debug": "CARGO_PROFILE_RELEASE_DEBUG",
        "strip": "CARGO_PROFILE_RELEASE_STRIP",
        "build_override_debug": "CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG",
        "opt_level": "CARGO_PROFILE_RELEASE_OPT_LEVEL",
        "codegen_units": "CARGO_PROFILE_RELEASE_CODEGEN_UNITS",
        "lto": "CARGO_PROFILE_RELEASE_LTO",
        "incremental": "CARGO_PROFILE_RELEASE_INCREMENTAL",
        "build_override_strip": "CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP",
    }
    profile = {key: environment.get(name) for key, name in profile_names.items()}
    profile["global_incremental_override"] = environment.get("CARGO_INCREMENTAL")
    profile["effective_incremental"] = environment.get(
        "CARGO_INCREMENTAL", environment.get("CARGO_PROFILE_RELEASE_INCREMENTAL")
    )
    profile["rustflags"] = environment.get("RUSTFLAGS", "")
    profile["cargo_encoded_rustflags"] = environment.get("CARGO_ENCODED_RUSTFLAGS", "")
    profile["rustc_wrapper"] = environment.get("RUSTC_WRAPPER", "")
    profile["rustc_workspace_wrapper"] = environment.get("RUSTC_WORKSPACE_WRAPPER", "")
    return profile


def validate_fast_release_profile(profile):
    if not isinstance(profile, dict):
        return False
    expected = {
        "build_mode": "fast",
        "debug": "0",
        "strip": "symbols",
        "build_override_debug": "0",
        "opt_level": "3",
        "codegen_units": "64",
        "lto": "off",
        "incremental": "true",
        "build_override_strip": "none",
        "rustflags": "",
        "cargo_encoded_rustflags": "",
        "rustc_wrapper": "",
        "rustc_workspace_wrapper": "",
    }
    if any(profile.get(key) != value for key, value in expected.items()):
        return False
    global_incremental = profile.get("global_incremental_override")
    if global_incremental not in (None, "0", "1", "true", "false"):
        return False
    return profile.get("effective_incremental") == (global_incremental or "true")


def feature_fingerprint(features):
    encoded = json.dumps(sorted(features), separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def cargo_binary_artifact(build_log, expected_binary, target_triple):
    artifacts = []
    for line in build_log.read_text(errors="replace").splitlines():
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(message, dict):
            continue
        target = message.get("target")
        if (
            message.get("reason") == "compiler-artifact"
            and isinstance(target, dict)
            and target.get("name") == "chau7-next"
            and "bin" in target.get("kind", [])
        ):
            artifacts.append(message)
    if len(artifacts) != 1:
        raise ValueError(f"expected one Cargo binary artifact record, found {len(artifacts)}")
    artifact = artifacts[0]
    executable = artifact.get("executable")
    if not isinstance(executable, str) or Path(executable).resolve(strict=True) != expected_binary.resolve(strict=True):
        raise ValueError("Cargo binary artifact path differs from the expected target output")
    features = artifact.get("features")
    if not isinstance(features, list) or sorted(features) != [NATIVE_FEATURE]:
        raise ValueError("Cargo binary artifact feature list differs from the exact native fixture feature")
    if artifact.get("target", {}).get("kind") != ["bin"]:
        raise ValueError("Cargo artifact target kind is not the exact application binary")
    profile = artifact.get("profile")
    if not isinstance(profile, dict):
        raise ValueError("Cargo artifact has no release profile metadata")
    debuginfo = profile.get("debuginfo")
    opt_level = profile.get("opt_level")
    if (
        profile.get("debug_assertions") is not False
        or isinstance(debuginfo, bool)
        or debuginfo not in (0, "0", "none")
        or isinstance(opt_level, bool)
        or opt_level not in (3, "3")
    ):
        raise ValueError("Cargo artifact profile must have release assertions off, no debug info, and opt-level 3")
    return {
        "package_id": artifact.get("package_id"),
        "target_name": artifact["target"]["name"],
        "target_kind": artifact["target"]["kind"],
        "target_triple": target_triple,
        "executable": str(Path(executable).resolve(strict=True)),
        "features": sorted(features),
        "features_sha256": feature_fingerprint(features),
        "profile": artifact.get("profile"),
    }


def build_receipt(
    repo,
    workspace,
    target,
    target_triple,
    toolchain_id,
    toolchain,
    revision,
    tree,
    status_before,
    binary,
    build_log,
    release_profile,
):
    source_after = source_snapshot(repo)
    status_after = source_after["status"]
    if source_after["revision"] != revision or source_after["tree"] != tree or status_after:
        raise ValueError("source revision, tree, or clean status changed during the native fixture build")
    expected_binary = target / "release" / "chau7-next"
    if binary.resolve(strict=True) != expected_binary.resolve(strict=True):
        raise ValueError("native fixture binary is outside the exact target output path")
    artifact = cargo_binary_artifact(build_log, expected_binary, target_triple)
    requested_features = [NATIVE_FEATURE]
    return {
        "schema_version": RECEIPT_SCHEMA_VERSION,
        "source": {
            "revision": revision,
            "tree": tree,
            "clean_before": status_before == "",
            "status_before": status_before,
            "clean_after": status_after == "",
            "status_after": status_after,
        },
        "artifact": {
            "path": str(binary.resolve(strict=True)),
            "sha256": sha256(binary),
            "package": "chau7_next",
            "requested_features": requested_features,
            "requested_features_sha256": feature_fingerprint(requested_features),
            "cargo_build_args": [
                "build",
                "--release",
                "--locked",
                "-p",
                "chau7_next",
                "--features",
                NATIVE_FEATURE,
                "--message-format=json-render-diagnostics",
            ],
            "cargo_artifact": artifact,
            "target_triple": target_triple,
            "release_profile": release_profile,
        },
        "toolchain": {
            "release": toolchain_id,
            "host_triple": target_triple,
            "cargo": file_identity(toolchain / "cargo", output([str(toolchain / "cargo"), "--version"])),
            "rustc": file_identity(toolchain / "rustc", output([str(toolchain / "rustc"), "--version"])),
            "rustdoc": file_identity(toolchain / "rustdoc", output([str(toolchain / "rustdoc"), "--version"])),
        },
        "workspace": str(workspace.resolve(strict=True)),
        "target_directory": str(target.resolve()),
    }


def validate_build_receipt(receipt_path, repo, workspace, target_triple, toolchain_id, toolchain):
    with Path(receipt_path).expanduser().resolve(strict=True).open() as source:
        receipt = json.load(source)
    if not isinstance(receipt, dict) or receipt.get("schema_version") != RECEIPT_SCHEMA_VERSION:
        raise ValueError("unsupported native fixture build receipt schema")
    source_record = receipt.get("source")
    current = source_snapshot(repo)
    if (
        not isinstance(source_record, dict)
        or source_record.get("clean_before") is not True
        or source_record.get("clean_after") is not True
        or source_record.get("status_before") != ""
        or source_record.get("status_after") != ""
        or source_record.get("revision") != current["revision"]
        or source_record.get("tree") != current["tree"]
        or current["status"]
    ):
        raise ValueError("build receipt does not match the exact clean source revision and tree")
    if receipt.get("workspace") != str(workspace.resolve(strict=True)):
        raise ValueError("build receipt names a different workspace")
    if receipt.get("target_directory") != str(Path(receipt.get("target_directory", "")).resolve()):
        raise ValueError("build receipt target directory is not canonical")
    if not receipt.get("target_directory"):
        raise ValueError("build receipt has no target directory")
    artifact = receipt.get("artifact")
    if not isinstance(artifact, dict):
        raise ValueError("build receipt has no artifact identity")
    requested_features = [NATIVE_FEATURE]
    if (
        artifact.get("package") != "chau7_next"
        or artifact.get("requested_features") != requested_features
        or artifact.get("requested_features_sha256") != feature_fingerprint(requested_features)
        or artifact.get("target_triple") != target_triple
        or not validate_fast_release_profile(artifact.get("release_profile"))
    ):
        raise ValueError("build receipt does not bind the expected native release feature and target")
    expected_args = [
        "build",
        "--release",
        "--locked",
        "-p",
        "chau7_next",
        "--features",
        NATIVE_FEATURE,
        "--message-format=json-render-diagnostics",
    ]
    if artifact.get("cargo_build_args") != expected_args:
        raise ValueError("build receipt Cargo invocation differs from the expected locked fixture build")
    cargo_artifact = artifact.get("cargo_artifact")
    if not isinstance(cargo_artifact, dict):
        raise ValueError("build receipt lacks the Cargo binary artifact record")
    cargo_features = cargo_artifact.get("features")
    cargo_profile = cargo_artifact.get("profile")
    if (
        cargo_artifact.get("target_name") != "chau7-next"
        or cargo_artifact.get("target_triple") != target_triple
        or cargo_artifact.get("target_kind") != ["bin"]
        or not isinstance(cargo_features, list)
        or cargo_features != [NATIVE_FEATURE]
        or cargo_artifact.get("features_sha256") != feature_fingerprint(cargo_features)
        or not isinstance(cargo_profile, dict)
        or cargo_profile.get("debug_assertions") is not False
        or isinstance(cargo_profile.get("debuginfo"), bool)
        or cargo_profile.get("debuginfo") not in (0, "0", "none")
        or isinstance(cargo_profile.get("opt_level"), bool)
        or cargo_profile.get("opt_level") not in (3, "3")
    ):
        raise ValueError("build receipt lacks the exact Cargo binary feature and release profile record")
    expected_binary = (Path(receipt["target_directory"]) / "release" / "chau7-next").resolve(strict=True)
    binary_candidate = Path(artifact.get("path", ""))
    if binary_candidate.is_symlink():
        raise ValueError("build receipt binary path is a symlink")
    binary = binary_candidate.resolve(strict=True)
    if binary != expected_binary or not binary.is_file():
        raise ValueError("build receipt binary is not the exact release output for its target directory")
    if cargo_artifact.get("executable") != str(binary):
        raise ValueError("build receipt Cargo artifact and binary paths differ")
    if sha256(binary) != artifact.get("sha256"):
        raise ValueError("native fixture binary hash differs from its build receipt")
    toolchain_record = receipt.get("toolchain")
    if (
        not isinstance(toolchain_record, dict)
        or toolchain_record.get("release") != toolchain_id
        or toolchain_record.get("host_triple") != target_triple
    ):
        raise ValueError("build receipt Rust toolchain host target differs")
    for name in ("cargo", "rustc", "rustdoc"):
        expected = file_identity(toolchain / name)
        recorded = toolchain_record.get(name)
        if (
            not isinstance(recorded, dict)
            or recorded.get("path") != expected["path"]
            or recorded.get("sha256") != expected["sha256"]
        ):
            raise ValueError(f"build receipt {name} identity differs from the installed toolchain")
    return receipt, binary


def native_build_command(args, cargo, target_triple):
    """Return the only permitted Cargo build command; receipt rows return None."""
    if args.from_build_receipt:
        return None
    return [
        str(cargo),
        "build",
        "--release",
        "--locked",
        "-p",
        "chau7_next",
        "--features",
        NATIVE_FEATURE,
        "--message-format=json-render-diagnostics",
    ]


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
        "--settings-locale",
        choices=("system", "en", "fr", "es", "ar", "he"),
        help="Process-local Settings fixture language selected through its existing environment hook",
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
    parser.add_argument(
        "--target-directory",
        help="Exact Cargo target cache directory; defaults to CARGO_TARGET_DIR or target/native-parity",
    )
    parser.add_argument(
        "--evidence-directory",
        help="Create this exact new directory for durable outputs; it must not already exist",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--build-only",
        action="store_true",
        help="Build the optional native fixture once and write build-receipt.json; do not launch an app",
    )
    mode.add_argument(
        "--from-build-receipt",
        help="Run one fixture case from a previously validated exact native build receipt; never invoke Cargo",
    )
    return parser


def validate_arguments(args):
    if args.build_only:
        if not args.evidence_directory:
            raise ValueError("--build-only requires --evidence-directory")
        if args.case != "all" or args.fixture_locale or args.settings_locale is not None:
            raise ValueError("--build-only does not accept fixture case or locale selectors")
    if args.from_build_receipt:
        if not args.evidence_directory:
            raise ValueError("--from-build-receipt requires --evidence-directory")
        if args.case == "all":
            raise ValueError("--from-build-receipt requires exactly one --case")
    fixture_locale = fixture_locale_for(args.case, args.fixture_locale)
    if args.settings_locale is not None and args.case != "settings":
        raise ValueError("--settings-locale is only supported with --case settings")
    return fixture_locale


def main():
    parser = argument_parser()
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("native parity fixtures require macOS")
    try:
        fixture_locale = validate_arguments(args)
    except ValueError as error:
        parser.error(str(error))
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.toolchain):
        parser.error("use an exact Rust version, not a mutable toolchain alias")
    workspace = Path(__file__).resolve().parents[1]
    repo = workspace.parents[1]
    before = source_snapshot(repo)
    if before["status"]:
        parser.error("commit or preserve all source changes before collecting exact-revision evidence")
    revision = before["revision"]
    tree = before["tree"]
    architecture = {"arm64": "aarch64", "x86_64": "x86_64"}.get(platform.machine())
    if architecture is None:
        parser.error("unsupported macOS architecture")
    target_triple = f"{architecture}-apple-darwin"
    toolchain_id = f"{args.toolchain}-{target_triple}"
    toolchain = Path(os.environ.get("RUSTUP_HOME", str(Path.home() / ".rustup"))) / "toolchains" / toolchain_id / "bin"
    for name in ("cargo", "rustc", "rustdoc"):
        if not (toolchain / name).is_file():
            parser.error(f"required already installed executable is missing: {toolchain / name}")
    if args.from_build_receipt:
        try:
            with Path(args.from_build_receipt).expanduser().resolve(strict=True).open() as receipt_file:
                unvalidated_receipt = json.load(receipt_file)
            receipt_target = Path(unvalidated_receipt["target_directory"]).resolve(strict=True)
        except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
            parser.error(f"cannot read native fixture build receipt target: {error}")
        if args.target_directory and Path(args.target_directory).expanduser().resolve() != receipt_target:
            parser.error("--target-directory conflicts with the target directory in the build receipt")
        target = receipt_target
    else:
        requested_target = args.target_directory or os.environ.get("CARGO_TARGET_DIR")
        target = (
            Path(requested_target).expanduser().resolve()
            if requested_target
            else workspace / "target" / "native-parity"
        )
    try:
        evidence = (
            create_evidence_directory(args.evidence_directory)
            if args.evidence_directory
            else Path(tempfile.mkdtemp(prefix="chau7-native-results-")).resolve()
        )
    except (OSError, ValueError) as error:
        parser.error(str(error))
    environment = dict(os.environ)
    for key in tuple(environment):
        if key.startswith("CARGO_PROFILE_RELEASE_"):
            environment.pop(key)
    environment.update(
        {
            "RUSTUP_TOOLCHAIN": toolchain_id,
            "RUSTC": str(toolchain / "rustc"),
            "RUSTDOC": str(toolchain / "rustdoc"),
            "CARGO_TARGET_DIR": str(target),
            # Keep this fixture build separate from debug packaging and forbid release debug info.
            "BUILD_MODE": "fast",
            "CARGO_BUILD_VERBOSE": "0",
            "CARGO_PROFILE_RELEASE_DEBUG": "0",
            "CARGO_PROFILE_RELEASE_STRIP": "symbols",
            "CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG": "0",
            "CARGO_PROFILE_RELEASE_OPT_LEVEL": "3",
            "CARGO_PROFILE_RELEASE_CODEGEN_UNITS": "64",
            "CARGO_PROFILE_RELEASE_LTO": "off",
            "CARGO_PROFILE_RELEASE_INCREMENTAL": "true",
            "CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP": "none",
            "RUSTFLAGS": "",
            "CARGO_ENCODED_RUSTFLAGS": "",
            "RUSTC_WRAPPER": "",
            "RUSTC_WORKSPACE_WRAPPER": "",
        }
    )
    environment.pop("CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS", None)
    manifest = {
        "source_revision": revision,
        "source_tree": tree,
        "source_clean_before": before["status"] == "",
        "compiler": None,
        "cargo": None,
        "fixture_feature": NATIVE_FEATURE,
        "window_renderer": args.window_renderer,
        "release_profile": release_profile_from_environment(environment),
        "target_triple": target_triple,
        "target_directory": str(target.resolve()),
        "build_receipt_path": None,
        "binary_sha256": None,
        "results": [],
    }
    binary = None
    if args.from_build_receipt:
        try:
            receipt, binary = validate_build_receipt(
                args.from_build_receipt, repo, workspace, target_triple, toolchain_id, toolchain
            )
        except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
            parser.error(f"build receipt validation failed: {error}")
        manifest["build_receipt_path"] = str(Path(args.from_build_receipt).expanduser().resolve(strict=True))
        manifest["build_receipt"] = receipt
        manifest["toolchain_binary_hashes_verified"] = True
        manifest["binary_sha256"] = receipt["artifact"]["sha256"]
    else:
        manifest["compiler"] = output([str(toolchain / "rustc"), "--version"])
        manifest["cargo"] = output([str(toolchain / "cargo"), "--version"])
        build_log = evidence / "build.log"
        rustc_verbose = output([str(toolchain / "rustc"), "-vV"])
        host_triple = next(
            (line.partition(":")[2].strip() for line in rustc_verbose.splitlines() if line.startswith("host:")),
            None,
        )
        if host_triple != target_triple:
            parser.error(f"installed Rust host {host_triple!r} differs from native target {target_triple}")
        build_args = native_build_command(args, toolchain / "cargo", target_triple)
        if build_args is None:
            raise AssertionError("receipt mode must never invoke Cargo")
        with build_log.open("x") as log:
            build = subprocess.run(
                build_args,
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
        expected_binary = target / "release" / "chau7-next"
        try:
            binary = expected_binary.resolve(strict=True)
            if not binary.is_file() or expected_binary.is_symlink():
                raise ValueError("native fixture output is not the exact regular target binary")
            manifest["binary_sha256"] = sha256(binary)
            if args.build_only:
                receipt = build_receipt(
                    repo,
                    workspace,
                    target,
                    target_triple,
                    toolchain_id,
                    toolchain,
                    revision,
                    tree,
                    before["status"],
                    binary,
                    build_log,
                    release_profile_from_environment(environment),
                )
                receipt_path = evidence / "build-receipt.json"
                receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
                manifest["build_receipt_path"] = str(receipt_path)
                manifest["build_receipt"] = receipt
                manifest["source_clean_after"] = True
                manifest["passed"] = True
                (evidence / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
                print(f"Build receipt: {receipt_path}")
                print(f"Evidence: {evidence}")
                return 0
        except (OSError, ValueError, KeyError) as error:
            manifest["build_receipt_error"] = str(error)
            manifest["passed"] = False
            (evidence / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
            print(f"Native fixture build evidence failed validation; evidence: {evidence}")
            return 1
    if binary is None:
        print(f"Native fixture binary unavailable; evidence: {evidence}")
        return 1
    manifest["original_binary_sha256"] = manifest["binary_sha256"]
    cases = cases_for(args.case)
    success = True
    for case in cases:
        row_before = source_snapshot(repo)
        if row_before["revision"] != revision or row_before["tree"] != tree or row_before["status"]:
            manifest["source_changed_before_case"] = case
            success = False
            break
        if sha256(binary) != manifest["binary_sha256"]:
            manifest["binary_changed_before_case"] = case
            success = False
            break
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
        if case == "settings" and args.settings_locale:
            child_environment["CHAU7_NEXT_NATIVE_SETTINGS_LANGUAGE"] = args.settings_locale
        if case == "keyboard":
            child_environment["HOME"] = str(home)
            child_environment["ZDOTDIR"] = str(home)
        stdout_path = evidence / f"{case}.stdout"
        stderr_path = evidence / f"{case}.stderr"
        launch_services = launch_services_for(case)
        record = {
            "case": case,
            "fixture_locale": fixture_locale if case == "accessibility" else None,
            "settings_locale": args.settings_locale if case == "settings" else None,
            "passed": False,
            "timed_out": False,
            "owned_home": str(home),
            "launch_services": launch_services,
            "launch_strategy": (
                "unique_signed_fixture_bundle_initial_open"
                if case == "keyboard"
                else "unique_signed_fixture_bundle_restoration"
                if case == "restore"
                else None
            ),
            "launch_services_initial_open_passed": False if case == "keyboard" else None,
            "application_pid_observed_exact_executable": False if case == "keyboard" else None,
            "exit_code_basis": ("launch_services_waiter" if launch_services else "application_process"),
            "application_exit_code": None,
            "original_binary_sha256": manifest["binary_sha256"],
            "ordered_front_activation_request_attempted": False if launch_services else None,
            "ordered_front_activation_request_passed": False if launch_services else None,
            "fullscreen_focus_yield_request_attempted": False if launch_services else None,
            "fullscreen_focus_yield_request_passed": False if launch_services else None,
            "fullscreen_reactivation_request_attempted": False if launch_services else None,
            "fullscreen_reactivation_request_passed": False if launch_services else None,
            "activation_request_attempted": False if launch_services else None,
            "activation_request_passed": False if launch_services else None,
        }
        manifest["results"].append(record)
        bundle_root = None
        fixture_stdout_path = stdout_path
        fixture_stderr_path = stderr_path
        try:
            if launch_services:
                bundle_root, bundle = prepare_restore_bundle(binary, record, evidence, case)
                fixture_stdout_path = create_owned_restore_capture(record, bundle_root, RESTORE_CAPTURE_NAMES["stdout"])
                fixture_stderr_path = create_owned_restore_capture(record, bundle_root, RESTORE_CAPTURE_NAMES["stderr"])
                record["launch_services_capture_paths"] = {
                    "stdout": str(fixture_stdout_path),
                    "stderr": str(fixture_stderr_path),
                }
                record["launch_services_capture_archive_paths"] = {
                    "stdout": str(evidence / RESTORE_CAPTURE_NAMES["stdout"]),
                    "stderr": str(evidence / RESTORE_CAPTURE_NAMES["stderr"]),
                }
                record["launch_services_captures_archived"] = False
                command = [
                    "/usr/bin/open",
                    "-n",
                    "-W",
                    "--stdout",
                    str(fixture_stdout_path),
                    "--stderr",
                    str(fixture_stderr_path),
                ]
                environment_names = (("HOME", "ZDOTDIR") if case == "keyboard" else ()) + (
                    "CHAU7_NEXT_NATIVE_PARITY_FIXTURE",
                    "CHAU7_NEXT_ISOLATED_TEST_MODE",
                    "CHAU7_NEXT_HOME_ROOT",
                    "HISTFILE",
                )
                for name in environment_names:
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
                process_stdout = evidence / f"{case}.launcher.stdout"
                process_stderr = evidence / f"{case}.launcher.stderr"
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
                (evidence / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
                if case == "restore":
                    wait_owned_fixture(
                        process,
                        record,
                        bundle,
                        fixture_stderr_path,
                        evidence,
                        child_environment,
                        args.window_renderer,
                    )
                elif case == "keyboard":
                    wait_owned_keyboard_fixture(process, record, bundle)
                else:
                    try:
                        record["exit_code"] = process.wait(timeout=75)
                    except subprocess.TimeoutExpired:
                        # Preserve uncertain fixture state; never terminate on an acceptance timeout.
                        record["timed_out"] = True
                        record["exit_code"] = None
            if not launch_services:
                record["application_exit_code"] = record["exit_code"]
            record["outcome"] = fixture_outcome(fixture_stdout_path, case)
            outcome_pid = (record["outcome"] or {}).get("pid")
            record["application_process_id"] = outcome_pid
            record["process_id"] = outcome_pid if launch_services else process.pid
            expected_executable = (
                (Path(record["owned_bundle"]) / "Contents" / "MacOS" / "chau7-next") if launch_services else None
            )
            if case == "keyboard" and launch_services:
                record["application_pid_verified"] = (
                    valid_pid(outcome_pid)
                    and outcome_pid == record.get("application_process_id_observed")
                    and record.get("application_pid_observed_exact_executable") is True
                    and record.get("application_executable_path") == str(expected_executable)
                )
                record["launch_services_initial_open_passed"] = (
                    record.get("exit_code") == 0 and record["application_pid_verified"]
                )
            elif case == "restore" and launch_services:
                ordered = record.get("ordered_front_activation_handshake") or {}
                focus_yield = record.get("fullscreen_focus_yield_handshake") or {}
                fullscreen = record.get("fullscreen_reactivation_handshake") or {}
                activation = record.get("activation_handshake") or {}
                record["application_pid_verified"] = (
                    valid_pid(outcome_pid)
                    and ordered.get("pid") == outcome_pid
                    and focus_yield.get("pid") == outcome_pid
                    and fullscreen.get("pid") == outcome_pid
                    and activation.get("pid") == outcome_pid
                    and ordered.get("bundle_path") == record.get("owned_bundle")
                    and focus_yield.get("bundle_path") == record.get("owned_bundle")
                    and fullscreen.get("bundle_path") == record.get("owned_bundle")
                    and activation.get("bundle_path") == record.get("owned_bundle")
                    and record.get("ordered_front_activation_request_passed") is True
                    and record.get("fullscreen_focus_yield_request_passed") is True
                    and record.get("activation_request_passed") is True
                )
                record["application_executable_path"] = str(expected_executable)
            else:
                record["application_pid_verified"] = valid_pid(outcome_pid) and outcome_pid == process.pid
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
            if bundle_root is not None and gone and not record["timed_out"]:
                archive_and_remove_owned_restore_bundle(record, bundle_root, evidence)
            record["passed"] = case_passed(record)
        except (OSError, subprocess.CalledProcessError, RuntimeError, ValueError) as error:
            record["passed"] = False
            record["error"] = str(error)
            record["owned_home_removed"] = not home.exists()
        row_after = source_snapshot(repo)
        record["source_clean_after"] = not row_after["status"]
        record["source_revision_after"] = row_after["revision"]
        record["source_tree_after"] = row_after["tree"]
        record["source_unchanged"] = (
            row_after["revision"] == revision and row_after["tree"] == tree and not row_after["status"]
        )
        record["binary_unchanged"] = sha256(binary) == manifest["binary_sha256"]
        record["passed"] = record["passed"] and record["source_unchanged"] and record["binary_unchanged"]
        success = success and record["passed"]
        print(f"{case}: {'PASS' if record['passed'] else 'FAIL'}")
        (evidence / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        if record["timed_out"]:
            break
    after = source_snapshot(repo)
    manifest["source_clean_after"] = not after["status"]
    manifest["source_unchanged"] = after["revision"] == revision and after["tree"] == tree and not after["status"]
    manifest["binary_unchanged"] = sha256(binary) == manifest["binary_sha256"]
    success = success and manifest["source_unchanged"] and manifest["binary_unchanged"]
    manifest["passed"] = bool(success)
    (evidence / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Evidence: {evidence}")
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
