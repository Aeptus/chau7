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
import math
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
RESTORE_SHA_RE = re.compile(r"^[0-9a-f]{64}$")
MAX_RESTORE_MANIFEST_BYTES = 16 * 1024 * 1024
MAX_RESTORE_CONTEXT_BYTES = 500_000
MAX_RESTORE_ARCHIVE_FILES = 120
RESTORE_INDEX_RELATIVE = Path("session.json")
RESTORE_CURRENT_RELATIVE = Path("TabRestoreBundles/current.json")
RESTORE_CONTEXTS_RELATIVE = Path("TabRestoreBundles/contexts")
RESTORE_LATEST_RELATIVE = Path("TabStateBackups/latest.json")
RESTORE_ARCHIVE_RELATIVE = Path("TabStateBackups/archive")


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


def _read_restore_file(path, maximum, label):
    """Read one regular restore file without following a replaced symlink."""
    path = plain_path(path, label)
    try:
        path_info = path.lstat()
        require(stat.S_ISREG(path_info.st_mode), f"{label} is not a regular file: {path}")
        require(path_info.st_size <= maximum, f"{label} exceeds its byte bound: {path}")
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        opened_info = os.fstat(descriptor)
        require(stat.S_ISREG(opened_info.st_mode)
                and (opened_info.st_dev, opened_info.st_ino)
                == (path_info.st_dev, path_info.st_ino),
                f"{label} changed while being opened: {path}")
        with os.fdopen(descriptor, "rb", closefd=True) as source:
            descriptor = -1
            payload = source.read(maximum + 1)
            final_info = os.fstat(source.fileno())
        require(len(payload) <= maximum and len(payload) == opened_info.st_size,
                f"{label} changed or exceeds its byte bound: {path}")
        require((final_info.st_dev, final_info.st_ino, final_info.st_size)
                == (opened_info.st_dev, opened_info.st_ino, opened_info.st_size),
                f"{label} changed while being read: {path}")
        return payload
    except UpdateError:
        raise
    except OSError as error:
        raise UpdateError(f"cannot safely read {label} at {path}: {error}") from error
    finally:
        if "descriptor" in locals() and descriptor >= 0:
            os.close(descriptor)


def _read_optional_restore_file(root, relative, maximum, label):
    path = root / relative
    try:
        path.lstat()
    except FileNotFoundError:
        return None
    except OSError as error:
        raise UpdateError(f"cannot inspect {label} at {path}: {error}") from error
    return _read_restore_file(path, maximum, label)


def _decode_restore_object(payload, label):
    def unique_keys(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise UpdateError(f"{label} contains duplicate JSON keys; restore state is ambiguous")
            value[key] = item
        return value

    def reject_constant(value):
        raise UpdateError(f"{label} contains unsupported JSON number {value!r}")

    try:
        value = json.loads(payload, object_pairs_hook=unique_keys, parse_constant=reject_constant)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise UpdateError(f"{label} is not valid JSON; restore state is ambiguous") from error
    require(isinstance(value, dict), f"{label} must be a JSON object; restore state is ambiguous")
    return value


def _valid_restore_token(value, label):
    require(isinstance(value, str), f"{label} is missing; restore state is ambiguous")
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError) as error:
        raise UpdateError(f"{label} is invalid; restore state is ambiguous") from error
    require(str(parsed) == value.lower(), f"{label} is invalid; restore state is ambiguous")
    return value


def _has_saved_identity(value):
    if value is None:
        return False
    if isinstance(value, str):
        return bool(value)
    if isinstance(value, (dict, list)):
        return bool(value)
    return True


def _preserves_saved_identity(previous, current):
    """Require every previously populated resume field to remain verbatim."""
    if not _has_saved_identity(previous):
        return True
    if isinstance(previous, dict):
        if not isinstance(current, dict):
            return False
        return all(key in current and _preserves_saved_identity(value, current[key])
                   for key, value in previous.items())
    if isinstance(previous, list):
        if not isinstance(current, list) or len(current) < len(previous):
            return False
        return all(_preserves_saved_identity(value, current[index])
                   for index, value in enumerate(previous))
    return previous == current


def _saved_layout_leaf_ids(layout, label):
    """Return saved pane leaf identities as PaneTree will restore them; None means legacy fallback."""
    if layout is None:
        return None

    leaf_ids = set()
    leaves = []

    def require_id(value, kind):
        require(isinstance(value, int) and not isinstance(value, bool)
                and 0 <= value <= 0xFFFFFFFFFFFFFFFF,
                f"{label} contains an invalid saved layout {kind} ID")
        return value

    def visit(node):
        require(isinstance(node, dict), f"{label} contains an invalid saved pane layout")
        node_type = node.get("type")
        if node_type == "split":
            require_id(node.get("id"), "split")
            require(node.get("axis") in ("horizontal", "vertical"),
                    f"{label} contains an invalid saved split axis")
            ratios = node.get("ratios")
            children = node.get("children")
            require(isinstance(ratios, list) and isinstance(children, list),
                    f"{label} contains an invalid saved split")
            require(all(isinstance(ratio, (int, float)) and not isinstance(ratio, bool)
                        and math.isfinite(ratio) for ratio in ratios),
                    f"{label} contains an invalid saved split ratio")
            for child in children:
                visit(child)
            return

        require(node_type in (
            "terminal", "editor", "preview", "diff", "dashboard", "repository",
        ), f"{label} contains an unknown saved pane type")
        pane_id = require_id(node.get("id"), "pane")
        require(pane_id not in leaf_ids,
                f"{label} contains duplicate saved layout pane IDs")
        leaf_ids.add(pane_id)
        leaves.append((node_type, pane_id))

    visit(layout)
    return tuple(leaves)


def _restore_session_identity(session, label):
    require(isinstance(session, dict), f"{label} has no saved session; restore state is ambiguous")
    version = session.get("version")
    require(isinstance(version, int) and not isinstance(version, bool) and 0 <= version <= 0xFFFFFFFF,
            f"{label} has an invalid session version")
    windows = session.get("windows")
    require(isinstance(windows, list), f"{label} has no saved windows list; restore state is ambiguous")

    tab_ids = set()
    pane_by_id = {}
    tabs = {}
    window_signatures = {}
    for window in windows:
        require(isinstance(window, dict), f"{label} contains an invalid window")
        for field in ("x", "y", "width", "height"):
            coordinate = window.get(field)
            require(isinstance(coordinate, (int, float)) and not isinstance(coordinate, bool)
                    and math.isfinite(coordinate),
                    f"{label} contains an invalid window {field}")
        saved_tabs = window.get("tabs")
        selected = window.get("selected")
        require(isinstance(saved_tabs, list), f"{label} contains a window without a tab list")
        require(isinstance(selected, int) and not isinstance(selected, bool),
                f"{label} contains an invalid selected-tab index")
        require(not saved_tabs or 0 <= selected < len(saved_tabs),
                f"{label} contains an out-of-range selected-tab index")

        ordered_tab_ids = []
        for tab in saved_tabs:
            require(isinstance(tab, dict), f"{label} contains an invalid tab")
            raw_uuid = tab.get("uuid")
            require(isinstance(raw_uuid, str),
                    f"{label} contains a tab without a stable UUID; refusing an ambiguous comparison")
            try:
                tab_uuid = str(uuid.UUID(raw_uuid))
            except (ValueError, AttributeError) as error:
                raise UpdateError(f"{label} contains an invalid tab UUID") from error
            require(tab_uuid == raw_uuid.lower(), f"{label} contains a non-canonical tab UUID")
            require(tab_uuid not in tab_ids, f"{label} contains duplicate tab UUIDs")
            tab_ids.add(tab_uuid)
            ordered_tab_ids.append(tab_uuid)

            panes = tab.get("panes")
            require(isinstance(panes, list), f"{label} contains a tab without a pane list")
            pane_ids = set()
            pane_order = []
            pane_summaries = {}
            for pane in panes:
                require(isinstance(pane, dict), f"{label} contains an invalid terminal pane")
                pane_id = pane.get("id")
                require(isinstance(pane_id, int) and not isinstance(pane_id, bool) and pane_id >= 0,
                        f"{label} contains an invalid pane ID")
                require(pane_id not in pane_ids and pane_id not in pane_by_id,
                        f"{label} contains duplicate pane IDs")
                pane_ids.add(pane_id)
                pane_order.append(pane_id)
                scrollback = pane.get("scrollback", False)
                require(isinstance(scrollback, bool), f"{label} contains an invalid scrollback flag")
                pane_by_id[pane_id] = pane
                pane_summaries[pane_id] = {
                    key: pane.get(key)
                    for key in (
                        "ai_provider", "ai_session_id", "ai_session_id_source",
                        "ai_resume_command", "archived_ai_resume", "agent_launch_command",
                    )
                }
            layout_leaves = _saved_layout_leaf_ids(tab.get("layout"), label)
            restored_layout_leaves = (
                (("terminal", pane_order[0]),) if layout_leaves is None and pane_order
                else (() if layout_leaves is None else layout_leaves)
            )
            tabs[tab_uuid] = {
                "panes": pane_summaries,
                "restored_layout_leaves": restored_layout_leaves,
            }

        if ordered_tab_ids:
            signature = tuple(sorted(ordered_tab_ids))
            require(signature not in window_signatures,
                    f"{label} contains ambiguous window identities")
            window_signatures[signature] = frozenset(ordered_tab_ids)

    return {
        "has_tabs": bool(tab_ids),
        "tab_count": len(tab_ids),
        "window_count": len(window_signatures),
        "windows": window_signatures,
        "tabs": tabs,
        "panes": pane_by_id,
    }

def _validated_restore_bundle(root, bundle_bytes, index_bytes, label):
    bundle = _decode_restore_object(bundle_bytes, label)
    schema_version = bundle.get("schema_version")
    require(isinstance(schema_version, int) and not isinstance(schema_version, bool)
            and schema_version == 1, f"{label} has an unsupported schema")
    save_token = _valid_restore_token(bundle.get("save_token"), f"{label} save_token")
    previous_token = bundle.get("previous_index_token")
    if previous_token is not None:
        _valid_restore_token(previous_token, f"{label} previous_index_token")
    explicit_clear = bundle.get("explicit_clear")
    require(isinstance(explicit_clear, bool), f"{label} has an invalid explicit_clear marker")
    session = bundle.get("session")
    identity = _restore_session_identity(session, label)
    require(explicit_clear or identity["has_tabs"],
            f"{label} is empty without an explicit clear marker")

    index = None
    if index_bytes is not None:
        index = _decode_restore_object(index_bytes, "Rust restore index session.json")
        index_token = index.get("save_token")
        if index_token is not None:
            _valid_restore_token(index_token, "Rust restore index save_token")
        if index_token is not None and save_token != index_token and previous_token != index_token:
            raise UpdateError(
                "the current restore bundle and session.json do not form a verified save transaction"
            )
        if "explicit_clear" in index:
            require(isinstance(index["explicit_clear"], bool),
                    "Rust restore index has an invalid explicit_clear marker")
        index_identity = _restore_session_identity(index, "Rust restore index session.json")
        if index_token is not None and index_token == save_token:
            require(index_identity["windows"] == identity["windows"]
                    and index_identity["tabs"] == identity["tabs"],
                    "current restore bundle and session.json share a save_token but differ")

    contexts = bundle.get("contexts")
    require(isinstance(contexts, dict), f"{label} has no contexts map")
    referenced_contexts = {}
    context_bytes = {}
    for raw_pane_id, reference in contexts.items():
        require(isinstance(raw_pane_id, str) and raw_pane_id.isdigit(),
                f"{label} contains an invalid context pane key")
        pane_id = int(raw_pane_id)
        require(pane_id not in referenced_contexts,
                f"{label} contains duplicate context pane IDs")
        pane = identity["panes"].get(pane_id)
        require(pane is not None and pane.get("scrollback") is True,
                f"{label} contains an unreferenced context")
        require(isinstance(reference, dict), f"{label} contains an invalid context reference")
        digest = reference.get("sha256")
        byte_count = reference.get("byte_count")
        require(isinstance(digest, str) and RESTORE_SHA_RE.fullmatch(digest) is not None,
                f"{label} contains an invalid context hash")
        require(isinstance(byte_count, int) and not isinstance(byte_count, bool)
                and 0 <= byte_count <= MAX_RESTORE_CONTEXT_BYTES,
                f"{label} contains an invalid context byte count")
        context_path = root / RESTORE_CONTEXTS_RELATIVE / f"{digest}.txt"
        payload = _read_restore_file(context_path, MAX_RESTORE_CONTEXT_BYTES,
                                     f"restore context {digest}.txt")
        require(len(payload) == byte_count and hashlib.sha256(payload).hexdigest() == digest,
                f"{label} context hash or byte count does not verify: {context_path}")
        referenced_contexts[pane_id] = digest
        context_bytes.setdefault(digest, payload)

    for pane_id, pane in identity["panes"].items():
        if pane.get("scrollback") is True:
            require(pane_id in referenced_contexts,
                    f"{label} is missing the context for pane {pane_id}")
    identity["contexts"] = referenced_contexts
    return {
        "mode": "explicit-clear" if explicit_clear and not identity["has_tabs"] else "current",
        "save_token": save_token,
        "explicit_clear": explicit_clear,
        "identity": identity,
        "bundle_bytes": bundle_bytes,
        "index_bytes": index_bytes,
        "context_bytes": context_bytes,
    }


def _read_fallback_state(root, relative, label):
    payload = _read_optional_restore_file(root, relative, MAX_RESTORE_MANIFEST_BYTES, label)
    if payload is None:
        return None, None
    value = _decode_restore_object(payload, label)
    session = value.get("session") if isinstance(value.get("session"), dict) else value
    identity = _restore_session_identity(session, label)
    explicit_clear = value.get("explicit_clear", False)
    require(isinstance(explicit_clear, bool), f"{label} has an invalid explicit_clear marker")
    return payload, {"identity": identity, "explicit_clear": explicit_clear}


def _fallback_restore_paths(root):
    paths = [RESTORE_LATEST_RELATIVE]
    archive = root / RESTORE_ARCHIVE_RELATIVE
    try:
        archive_info = archive.lstat()
    except FileNotFoundError:
        return paths
    except OSError as error:
        raise UpdateError(f"cannot inspect Rust restore archive at {archive}: {error}") from error
    require(stat.S_ISDIR(archive_info.st_mode),
            f"Rust restore archive is not a directory: {archive}")
    try:
        entries = sorted((entry for entry in archive.iterdir() if entry.suffix == ".json"),
                         key=lambda item: item.name, reverse=True)
    except OSError as error:
        raise UpdateError(f"cannot list Rust restore archive at {archive}: {error}") from error
    require(len(entries) <= MAX_RESTORE_ARCHIVE_FILES,
            f"Rust restore archive has too many entries to verify safely: {archive}")
    paths.extend(path.relative_to(root) for path in entries)
    return paths


def _empty_restore_state(root, index_bytes, label):
    if index_bytes is not None:
        index = _decode_restore_object(index_bytes, "Rust restore index session.json")
        index_identity = _restore_session_identity(index, "Rust restore index session.json")
        index_clear = index.get("explicit_clear", False)
        require(isinstance(index_clear, bool), "Rust restore index has an invalid explicit_clear marker")
        index_token = index.get("save_token")
        if index_token is not None:
            _valid_restore_token(index_token, "Rust restore index save_token")
        if index_clear:
            require(not index_identity["has_tabs"],
                    "Rust restore index marks a populated session as explicitly cleared")
            return {"mode": "explicit-clear", "identity": index_identity, "index_bytes": index_bytes}
        if index_identity["has_tabs"]:
            raise UpdateError(
                f"{label} is missing, but session.json contains restorable tabs; refusing to ask you to quit"
            )

    fallback_paths = _fallback_restore_paths(root)
    fallback_payloads = {}
    for relative in fallback_paths:
        payload, value = _read_fallback_state(root, relative, f"Rust restore fallback {relative}")
        if payload is None:
            continue
        fallback_payloads[relative] = payload
        if value["identity"]["has_tabs"]:
            raise UpdateError(
                f"{label} is missing, but {relative} contains restorable tabs; "
                "refusing to ask you to quit without a valid current transaction"
            )
    return {
        "mode": "unused",
        "identity": {"has_tabs": False, "tab_count": 0, "window_count": 0,
                     "windows": {}, "tabs": {}, "panes": {}, "contexts": {}},
        "index_bytes": index_bytes,
        "fallback_paths": fallback_paths,
        "fallback_payloads": fallback_payloads,
    }


def read_restore_state(root, label="Rust restore state"):
    """Read the app-selected current transaction or prove the profile is empty."""
    root = plain_path(root, "RustV1 state root", must_exist=False)
    if not root.exists():
        return {
            "mode": "unused",
            "identity": {"has_tabs": False, "tab_count": 0, "window_count": 0,
                         "windows": {}, "tabs": {}, "panes": {}, "contexts": {}},
            "index_bytes": None,
            "fallback_paths": [],
            "fallback_payloads": {},
        }
    require(root.is_dir(), f"RustV1 state root is not a directory: {root}")
    current_relative = RESTORE_CURRENT_RELATIVE
    current_path = root / current_relative
    current_bytes = _read_optional_restore_file(
        root, current_relative, MAX_RESTORE_MANIFEST_BYTES, f"{label} current bundle"
    )
    index_bytes = _read_optional_restore_file(
        root, RESTORE_INDEX_RELATIVE, MAX_RESTORE_MANIFEST_BYTES, f"{label} index session.json"
    )
    if current_bytes is None:
        empty = _empty_restore_state(root, index_bytes, label)
        current_after = _read_optional_restore_file(
            root, current_relative, MAX_RESTORE_MANIFEST_BYTES, f"{label} current bundle"
        )
        index_after = _read_optional_restore_file(
            root, RESTORE_INDEX_RELATIVE, MAX_RESTORE_MANIFEST_BYTES, f"{label} index session.json"
        )
        require(current_after is None and index_after == index_bytes,
                f"{label} changed while being checked; refusing an ambiguous snapshot")
        if empty["mode"] == "unused":
            fallback_paths_after = _fallback_restore_paths(root)
            require(fallback_paths_after == empty["fallback_paths"],
                    f"{label} fallback membership changed while being checked")
            for relative in empty["fallback_paths"]:
                fallback_after = _read_optional_restore_file(
                    root, relative, MAX_RESTORE_MANIFEST_BYTES,
                    f"{label} fallback {relative}",
                )
                require(fallback_after == empty["fallback_payloads"].get(relative),
                        f"{label} fallback changed while being checked: {relative}")
        return empty

    snapshot = _validated_restore_bundle(root, current_bytes, index_bytes,
                                         f"{label} current bundle")
    # Content-addressed contexts are immutable. Re-read every referenced file,
    # then the transaction markers, to prove the pre-quit copy is one generation.
    for digest, payload in snapshot["context_bytes"].items():
        path = root / RESTORE_CONTEXTS_RELATIVE / f"{digest}.txt"
        require(_read_restore_file(path, MAX_RESTORE_CONTEXT_BYTES,
                                   f"restore context {digest}.txt") == payload,
                f"{label} context changed while being checked: {path}")
    current_after = _read_optional_restore_file(
        root, current_relative, MAX_RESTORE_MANIFEST_BYTES, f"{label} current bundle"
    )
    index_after = _read_optional_restore_file(
        root, RESTORE_INDEX_RELATIVE, MAX_RESTORE_MANIFEST_BYTES, f"{label} index session.json"
    )
    require(current_after == current_bytes and index_after == index_bytes,
            f"{label} save_token or index changed while being checked; retry before quitting")
    snapshot["bundle_path"] = current_path
    return snapshot

def _write_snapshot_file(source_bytes, destination, label):
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    require(not destination.exists() and not destination.is_symlink(),
            f"pre-quit snapshot path already exists: {destination}")
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb", closefd=True) as output:
            descriptor = -1
            output.write(source_bytes)
            output.flush()
            os.fsync(output.fileno())
    except OSError as error:
        raise UpdateError(f"cannot write {label} to {destination}: {error}") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def capture_prequit_restore(state_root, backup, home):
    """Atomically publish a verified restore transaction before asking the user to quit."""
    home = plain_path(home, "home directory")
    state_root = plain_path(state_root, "RustV1 state root", must_exist=False)
    try:
        state_relative = state_root.relative_to(home)
    except ValueError as error:
        raise UpdateError(f"RustV1 state root is outside the home directory: {state_root}") from error

    backup = plain_path(backup, "update backup directory")
    staging = backup / f".pre-quit-stage-{uuid.uuid4().hex}"
    published = backup / "pre-quit"
    require(not published.exists() and not published.is_symlink(),
            f"pre-quit snapshot already exists: {published}")
    staging.mkdir(mode=0o700)
    try:
        staged_state_root = staging / state_relative
        staged_state_root.mkdir(parents=True, mode=0o700)
        state = read_restore_state(state_root, "pre-quit Rust restore state")
        if state.get("bundle_bytes") is not None:
            _write_snapshot_file(state["bundle_bytes"],
                                 staged_state_root / RESTORE_CURRENT_RELATIVE,
                                 "pre-quit current restore bundle")
            for digest, payload in state["context_bytes"].items():
                _write_snapshot_file(
                    payload,
                    staged_state_root / RESTORE_CONTEXTS_RELATIVE / f"{digest}.txt",
                    "pre-quit restore context",
                )
        if state.get("index_bytes") is not None:
            _write_snapshot_file(state["index_bytes"],
                                 staged_state_root / RESTORE_INDEX_RELATIVE,
                                 "pre-quit restore index")
        marker = {
            "schema_version": 1,
            "mode": state["mode"],
            "save_token": state.get("save_token"),
            "window_count": state["identity"]["window_count"],
            "tab_count": state["identity"]["tab_count"],
        }
        _write_snapshot_file(
            json.dumps(marker, sort_keys=True, indent=2).encode("utf-8") + b"\n",
            staging / "restore-guard.json",
            "pre-quit restore guard manifest",
        )

        staged_state = read_restore_state(staged_state_root, "staged pre-quit Rust restore state")
        require(staged_state["mode"] == state["mode"]
                and staged_state.get("save_token") == state.get("save_token")
                and staged_state.get("index_bytes") == state.get("index_bytes"),
                "staged pre-quit restore snapshot failed verification")
        if state.get("bundle_bytes") is not None:
            require(staged_state.get("bundle_bytes") == state["bundle_bytes"]
                    and staged_state.get("context_bytes") == state["context_bytes"],
                    "staged pre-quit restore bundle or contexts differ from the verified source")
        os.rename(staging, published)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise

    state["prequit_root"] = published / state_relative
    state["prequit_manifest"] = published / "restore-guard.json"
    return state


def compare_restore_states(prequit, postquit, backup):
    """Reject shutdown saves that omit pre-existing windows, tabs, panes or resumes."""
    pre_identity = prequit["identity"]
    post_identity = postquit["identity"]
    reason = None

    if pre_identity["has_tabs"]:
        pre_windows = list(pre_identity["windows"].values())
        post_windows = list(post_identity["windows"].values())
        used_post_windows = set()
        for pre_window in pre_windows:
            overlaps = [
                index for index, post_window in enumerate(post_windows)
                if pre_window.intersection(post_window)
            ]
            if (len(overlaps) != 1
                    or not pre_window.issubset(post_windows[overlaps[0]])
                    or overlaps[0] in used_post_windows):
                reason = "the saved window or tab identities changed"
                break
            used_post_windows.add(overlaps[0])

        if reason is None:
            for tab_uuid, previous_tab in pre_identity["tabs"].items():
                current_tab = post_identity["tabs"].get(tab_uuid)
                if current_tab is None:
                    reason = "the saved window or tab identities changed"
                    break
                previous_panes = previous_tab["panes"]
                current_panes = current_tab["panes"]
                if not set(previous_panes).issubset(current_panes):
                    reason = "the saved window or tab identities changed"
                    break
                missing_layout_leaves = (
                    set(previous_tab["restored_layout_leaves"])
                    - set(current_tab["restored_layout_leaves"])
                )
                if missing_layout_leaves:
                    if any(node_type == "terminal" for node_type, _ in missing_layout_leaves):
                        reason = "a previously saved terminal pane is missing from the restored layout"
                    else:
                        reason = "a previously saved layout pane is missing from the restored layout"
                    break
                for pane_id, previous_pane in previous_panes.items():
                    current_pane = current_panes[pane_id]
                    for field, previous_value in previous_pane.items():
                        if (_has_saved_identity(previous_value)
                                and not _preserves_saved_identity(
                                    previous_value, current_pane.get(field)
                                )):
                            reason = "saved provider resume identity changed"
                            break
                    if reason is not None:
                        break
                if reason is not None:
                    break

        if reason is None and any(
                pane_id not in post_identity["contexts"]
                for pane_id in pre_identity["contexts"]):
            reason = "a previously saved terminal context is missing"

    if reason:
        pre_path = prequit["prequit_root"]
        post_path = backup / "state" / STATE_RELATIVES[0]
        raise UpdateError(
            f"{reason} after Chau7 quit; the installed app was not changed. Keep both backups. "
            f"Pre-quit restore snapshot: {pre_path}. Post-quit state snapshot: {post_path}. "
            "If recovery is needed, keep Chau7 closed and restore the pre-quit "
            "TabRestoreBundles/current.json, its matching contexts/ files and the captured "
            "session.json index from that snapshot; do not restore state while Chau7 is running."
        )

def ensure_profiles_unchanged(before, home):
    for source, manifest in before.items():
        allowed = state_socket_paths(source, home)
        require(tree_manifest(source, allowed) == manifest,
                f"RustV1 profile changed during the update: {source}")


def ask_for_normal_quit(wait_seconds, prequit_snapshot):
    print(
        f"Quit Chau7 normally with Cmd+Q. This updater will wait up to {wait_seconds} "
        "seconds and will never send a quit or process signal. The pre-quit restore "
        f"snapshot is retained at {prequit_snapshot}.",
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
                f"no app change was made. Pre-quit restore snapshot: {prequit_snapshot}."
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
    roots = state_roots(home)
    run_id = time.strftime("%Y%m%d-%H%M%S") + "-" + str(os.getpid()) + "-" + uuid.uuid4().hex[:8]
    backup = create_backup_directory(home, run_id)
    try:
        canonical_restore_root = plain_path(
            home / STATE_RELATIVES[0], "RustV1 restore state root", must_exist=False
        )
        require(canonical_restore_root.is_dir(),
                f"canonical RustV1 restore state root is missing; no quit was requested: "
                f"{canonical_restore_root}")
        prequit = capture_prequit_restore(canonical_restore_root, backup, home)
    except UpdateError as error:
        raise UpdateError(
            f"{error}. No quit was requested. The updater backup directory is retained at {backup}."
        ) from error
    print(f"Pre-quit restore snapshot: {prequit['prequit_root']}", flush=True)
    print(f"Pre-quit restore guard: {prequit['prequit_manifest']}", flush=True)
    ask_for_normal_quit(wait_seconds, prequit["prequit_root"])
    try:
        lock_file = acquire_instance_lock(home)
    except UpdateError as error:
        raise UpdateError(
            f"{error} Pre-quit restore snapshot is retained at {prequit['prequit_root']}."
        ) from error
    try:
        require(not active_application_pids(),
                f"Chau7 reopened after quit; no app replacement occurred. "
                f"Pre-quit restore snapshot: {prequit['prequit_root']}.")
        perform_update_locked(candidate, receipt_path, expected_sha, info, home, backup, prequit, run_id)
    finally:
        lock_file.close()


def perform_update_locked(candidate, receipt_path, expected_sha, info, home, backup, prequit, run_id):
    # The Rust lifetime flock stays held through verification and replacement.
    # Revalidate every source and target after the wait, before creating backups.
    candidate = plain_path(candidate, "candidate app")
    receipt_path = plain_path(receipt_path, "build receipt")
    receipt = read_receipt(receipt_path)
    candidate_info = validate_candidate(candidate, receipt, expected_sha)
    installed_info = validate_installed_production(APP_DESTINATION)
    roots = state_roots(home)
    require(not active_application_pids(),
            "Chau7 reopened after quit; no app replacement occurred.")

    state_before = snapshot_state(roots, backup, home)
    postquit = read_restore_state(
        backup / "state" / STATE_RELATIVES[0], "post-quit Rust restore state"
    )
    compare_restore_states(prequit, postquit, backup)

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
    print(f"Pre-quit restore snapshot: {prequit['prequit_root']}")
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
    mode.add_argument("--apply", action="store_true", help="snapshot restore state, wait for normal quit, verify and install")
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
