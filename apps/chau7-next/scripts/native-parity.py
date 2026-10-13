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
ORDERED_FRONT_ACTIVATION_HANDSHAKE_PREFIX = "native_ordered_front_activation="
ACTIVATION_ACK_FILENAME = "native-parity-activation.ack"
ORDERED_FRONT_ACTIVATION_ACK_FILENAME = "native-parity-ordered-front-activation.ack"
ACTIVATION_ACK_FILENAME_BY_STAGE = {
    "ordered_front_surface_reveal": ORDERED_FRONT_ACTIVATION_ACK_FILENAME,
    "deminiaturized_surface_reveal": ACTIVATION_ACK_FILENAME,
}
ACTIVATION_EVIDENCE_PREFIX_BY_STAGE = {
    "ordered_front_surface_reveal": "restore.ordered_front_activation",
    "deminiaturized_surface_reveal": "restore.activation",
}
ACTIVATION_GUARD_ENV = (
    "CHAU7_NEXT_NATIVE_PARITY_FIXTURE",
    "CHAU7_NEXT_ISOLATED_TEST_MODE",
    "CHAU7_NEXT_HOME_ROOT",
    "HISTFILE",
)
ACTIVATION_DEADLINE_SECONDS = 3


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
    stage = handshake.get("stage")
    if not isinstance(stage, str) or stage not in ACTIVATION_ACK_FILENAME_BY_STAGE:
        raise ValueError("activation handshake has an unsupported stage")
    home = Path(environment["CHAU7_NEXT_HOME_ROOT"]).resolve(strict=True)
    activation_ack_path = home / ACTIVATION_ACK_FILENAME_BY_STAGE[stage]
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
    """Wait for an owned restore fixture and request each activation stage once."""
    deadline = time.monotonic() + 75
    record.setdefault("ordered_front_activation_request_attempted", False)
    record.setdefault("ordered_front_activation_request_passed", False)
    record.setdefault("activation_request_attempted", False)
    record.setdefault("activation_request_passed", False)
    while True:
        try:
            stderr_text = stderr_path.read_text(errors="replace")
        except OSError as error:
            stderr_text = ""
            if not record["ordered_front_activation_request_attempted"]:
                record["ordered_front_activation_request_attempted"] = True
                record["ordered_front_activation_request_error"] = str(error)
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
            record["exit_code"] = exit_code
            if not record["ordered_front_activation_request_attempted"]:
                record["ordered_front_activation_request_attempted"] = True
                record["ordered_front_activation_request_error"] = (
                    "owned fixture exited before emitting an ordered-front activation handshake"
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
            if not record["ordered_front_activation_request_attempted"]:
                record["ordered_front_activation_request_attempted"] = True
                record["ordered_front_activation_request_error"] = (
                    "owned fixture did not emit an ordered-front activation handshake before timeout"
                )
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
        and (
            not record.get("launch_services")
            or (
                record.get("ordered_front_activation_request_passed") is True
                and record.get("activation_request_passed") is True
            )
        )
    )


def cases_for(case):
    return ("restore", "settings", "editor", "cache") if case == "all" else (case,)


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
        stdout_path = evidence / f"{case}.stdout"
        stderr_path = evidence / f"{case}.stderr"
        launch_services = case == "restore"
        record = {
            "case": case,
            "fixture_locale": fixture_locale if case == "accessibility" else None,
            "settings_locale": args.settings_locale if case == "settings" else None,
            "passed": False,
            "timed_out": False,
            "owned_home": str(home),
            "launch_services": launch_services,
            "exit_code_basis": ("launch_services_waiter" if launch_services else "application_process"),
            "application_exit_code": None,
            "original_binary_sha256": manifest["binary_sha256"],
            "ordered_front_activation_request_attempted": False if launch_services else None,
            "ordered_front_activation_request_passed": False if launch_services else None,
            "activation_request_attempted": False if launch_services else None,
            "activation_request_passed": False if launch_services else None,
        }
        manifest["results"].append(record)
        bundle_root = None
        try:
            if launch_services:
                bundle_root, bundle = prepare_restore_bundle(binary, record, evidence)
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
                        # Preserve uncertain fixture state; never terminate on an acceptance timeout.
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
            if bundle_root is not None and gone and not record["timed_out"]:
                shutil.rmtree(bundle_root)
                record["owned_bundle_removed"] = not bundle_root.exists()
        except (OSError, subprocess.CalledProcessError) as error:
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
