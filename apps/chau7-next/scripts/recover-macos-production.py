#!/usr/bin/env python3
"""Merge a preserved RustV1 restore snapshot back into the installed profile.

Run from Terminal. This helper never launches, quits, or modifies the Chau7 app.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import stat
import sys
import time
import types
import uuid
from contextlib import suppress
from pathlib import Path

UPDATER = Path(__file__).with_name("update-macos-production.command")
_source = UPDATER.read_text(encoding="utf-8")
_match = re.search(r"(?ms)^# PYTHON_CORE_BEGIN\n(.*?)^# PYTHON_CORE_END$", _source)
if _match is None:
    raise RuntimeError("updater Python core markers are missing")
CORE = types.ModuleType("production_updater_core")
exec(compile(_match.group(1), str(UPDATER), "exec"), CORE.__dict__)


RECOVERY_BACKUP_RELATIVE = Path("Library/Application Support/Chau7 Recovery Transactions")
TAB_FIELDS = ("cwd", "layout", "archived_context")
PANE_FIELDS = (
    "directory",
    "ai_provider",
    "ai_session_id",
    "ai_session_id_source",
    "ai_resume_command",
    "archived_ai_resume",
    "agent_launch_command",
)


class RecoveryConflict(CORE.UpdateError):
    """A safe merge is impossible without choosing between populated values."""


def _conflict(message):
    raise RecoveryConflict(message)


def _json_object(payload, label):
    try:
        value = json.loads(payload.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise CORE.UpdateError(f"{label} is not valid UTF-8 JSON") from error
    CORE.require(isinstance(value, dict), f"{label} is not a JSON object")
    return value


def _state_documents(state):
    bundle_bytes = state.get("bundle_bytes")
    if bundle_bytes is not None:
        bundle = _json_object(bundle_bytes, "restore bundle")
        session = bundle.get("session")
        CORE.require(isinstance(session, dict), "restore bundle has no session object")
        return bundle, copy.deepcopy(session)

    index_bytes = state.get("index_bytes")
    if index_bytes is not None:
        index = _json_object(index_bytes, "restore index")
        session = {key: value for key, value in index.items() if key not in ("save_token", "explicit_clear")}
        if "version" in session and "windows" in session:
            return None, copy.deepcopy(session)
    return None, {"version": 1, "windows": []}


def _state_contexts(state):
    bundle, _ = _state_documents(state)
    if bundle is None:
        return {}
    contexts = bundle.get("contexts", {})
    CORE.require(isinstance(contexts, dict), "restore bundle contexts map is invalid")
    return contexts


def _critical_value_merge(target, incoming, key, label):
    target_has = key in target
    incoming_has = key in incoming
    old_value = target.get(key)
    new_value = incoming.get(key)
    old_populated = target_has and CORE._has_saved_identity(old_value)
    new_populated = incoming_has and CORE._has_saved_identity(new_value)

    if old_populated and new_populated and old_value != new_value:
        _conflict(f"overlapping {label} has conflicting populated field {key}")
    if not old_populated and new_populated:
        target[key] = copy.deepcopy(new_value)


def _merge_overlapping_tab(target, incoming, pane_owners):
    tab_uuid = target["uuid"]
    for field in TAB_FIELDS:
        _critical_value_merge(target, incoming, field, f"tab {tab_uuid}")

    target_panes = target.get("panes", [])
    incoming_panes = incoming.get("panes", [])
    by_id = {pane["id"]: pane for pane in target_panes}
    for pane in incoming_panes:
        pane_id = pane["id"]
        existing = by_id.get(pane_id)
        if existing is None:
            owner = pane_owners.get(pane_id)
            if owner is not None and owner != tab_uuid:
                _conflict("overlapping restore states reuse a pane ID across tabs")
            pane_owners[pane_id] = tab_uuid
            copied = copy.deepcopy(pane)
            target_panes.append(copied)
            by_id[pane_id] = copied
            continue

        if existing.get("scrollback", False) != pane.get("scrollback", False):
            _conflict(f"overlapping tab {tab_uuid} has conflicting pane context flags")
        for field in PANE_FIELDS:
            _critical_value_merge(existing, pane, field, f"pane {pane_id}")


def _pane_owners(session):
    owners = {}
    for window in session.get("windows", []):
        for tab in window.get("tabs", []):
            for pane in tab.get("panes", []):
                pane_id = pane["id"]
                owner = owners.get(pane_id)
                if owner is not None and owner != tab["uuid"]:
                    _conflict("restore states reuse a pane ID across tabs")
                owners[pane_id] = tab["uuid"]
    return owners


def _tab_locations(windows):
    locations = {}
    for window_index, window in enumerate(windows):
        for tab_index, tab in enumerate(window.get("tabs", [])):
            tab_uuid = tab["uuid"]
            if tab_uuid in locations:
                _conflict("restore states contain a duplicate tab UUID")
            locations[tab_uuid] = (window_index, tab_index)
    return locations


def _merge_context_maps(states, session):
    owners = _pane_owners(session)
    references = {}
    payloads = {}
    for state in states:
        for digest, payload in state.get("context_bytes", {}).items():
            actual = hashlib.sha256(payload).hexdigest()
            CORE.require(actual == digest, "a restore context failed its content hash")
            payloads.setdefault(digest, payload)
        for raw_pane_id, reference in _state_contexts(state).items():
            pane_id = int(raw_pane_id)
            CORE.require(pane_id in owners, "a restore context refers to a missing pane")
            digest = reference["sha256"]
            payload = state.get("context_bytes", {}).get(digest)
            CORE.require(payload is not None, "a restore context payload is unavailable")
            # For an overlapping pane, the first state is the newest one. Keep its
            # context; older snapshots supply only a missing context mapping.
            references.setdefault(pane_id, digest)

    identity = CORE._restore_session_identity(session, "merged restore session")
    for pane_id, pane in identity["panes"].items():
        if pane.get("scrollback") is True:
            CORE.require(pane_id in references, f"merged restore is missing context for pane {pane_id}")
    referenced_payloads = {digest: payloads[digest] for digest in set(references.values())}
    return references, referenced_payloads


def _restore_summary(session, references):
    identity = CORE._restore_session_identity(session, "merged restore session")
    provider_pairs = {}
    for pane in identity["panes"].values():
        provider = pane.get("ai_provider")
        session_id = pane.get("ai_session_id")
        if CORE._has_saved_identity(provider) and CORE._has_saved_identity(session_id):
            pair = (json.dumps(provider, sort_keys=True), json.dumps(session_id, sort_keys=True))
            provider_pairs[pair] = provider_pairs.get(pair, 0) + 1
    return {
        "tabs": identity["tab_count"],
        "windows": identity["window_count"],
        "panes": len(identity["panes"]),
        "contexts": len(references),
        "duplicate_provider_pairs": sum(count > 1 for count in provider_pairs.values()),
    }


def merge_restore_states(states):
    """Build a UUID-based conservative union of validated restore snapshots.

    `states` are ordered newest to oldest and must be `CORE.read_restore_state`
    results. Current tabs/windows/panes retain their ordering; missing objects
    are appended from older snapshots. Only empty critical metadata is filled.
    """
    CORE.require(isinstance(states, (list, tuple)) and bool(states), "at least one validated restore state is required")
    for state in states:
        CORE.require(
            isinstance(state, dict) and isinstance(state.get("identity"), dict),
            "merge inputs must come from CORE.read_restore_state",
        )

    _, merged_session = _state_documents(states[0])
    merged_session.setdefault("version", 1)
    merged_session.setdefault("windows", [])
    merged_session["windows"] = copy.deepcopy(merged_session["windows"])
    locations = _tab_locations(merged_session["windows"])
    pane_owners = _pane_owners(merged_session)

    for state in states[1:]:
        _, incoming_session = _state_documents(state)
        incoming_windows = incoming_session.get("windows", [])
        for incoming_window in incoming_windows:
            incoming_tabs = incoming_window.get("tabs", [])
            incoming_ids = [tab["uuid"] for tab in incoming_tabs]
            if not incoming_tabs:
                merged_session["windows"].append(copy.deepcopy(incoming_window))
                continue

            overlapping_windows = {locations[tab_uuid][0] for tab_uuid in incoming_ids if tab_uuid in locations}
            if len(overlapping_windows) > 1:
                _conflict("an older saved window overlaps multiple current windows")
            if not overlapping_windows:
                target_index = len(merged_session["windows"])
                target_window = copy.deepcopy(incoming_window)
                merged_session["windows"].append(target_window)
                for tab_index, tab in enumerate(target_window.get("tabs", [])):
                    locations[tab["uuid"]] = (target_index, tab_index)
                    for pane in tab.get("panes", []):
                        owner = pane_owners.get(pane["id"])
                        if owner is not None and owner != tab["uuid"]:
                            _conflict("restore states reuse a pane ID across tabs")
                        pane_owners[pane["id"]] = tab["uuid"]
                continue

            target_index = next(iter(overlapping_windows))
            target_window = merged_session["windows"][target_index]
            target_tabs = target_window.get("tabs", [])
            target_by_uuid = {tab["uuid"]: tab for tab in target_tabs}
            for incoming_tab in incoming_tabs:
                tab_uuid = incoming_tab["uuid"]
                target = target_by_uuid.get(tab_uuid)
                if target is None:
                    for pane in incoming_tab.get("panes", []):
                        owner = pane_owners.get(pane["id"])
                        if owner is not None and owner != tab_uuid:
                            _conflict("restore states reuse a pane ID across tabs")
                        pane_owners[pane["id"]] = tab_uuid
                    copied = copy.deepcopy(incoming_tab)
                    target_tabs.append(copied)
                    target_by_uuid[tab_uuid] = copied
                    locations[tab_uuid] = (target_index, len(target_tabs) - 1)
                else:
                    if locations[tab_uuid][0] != target_index:
                        _conflict("an older tab identity maps to multiple saved windows")
                    _merge_overlapping_tab(target, incoming_tab, pane_owners)

    references, payloads = _merge_context_maps(states, merged_session)
    token = str(uuid.uuid4())
    first_index = states[0].get("index_bytes")
    previous_token = None
    if first_index is not None:
        previous_token = _json_object(first_index, "current restore index").get("save_token")
        if previous_token is not None:
            CORE._valid_restore_token(previous_token, "current restore index save_token")

    context_map = {
        str(pane_id): {
            "sha256": digest,
            "byte_count": len(payloads[digest]),
        }
        for pane_id, digest in sorted(references.items())
    }
    bundle = {
        "schema_version": 1,
        "save_token": token,
        "previous_index_token": previous_token,
        "explicit_clear": False,
        "session": merged_session,
        "contexts": context_map,
    }
    index = {
        "save_token": token,
        "explicit_clear": False,
        **merged_session,
    }
    bundle_bytes = _json_bytes(bundle)
    index_bytes = _json_bytes(index)
    CORE.require(len(bundle_bytes) <= CORE.MAX_RESTORE_MANIFEST_BYTES, "merged restore bundle exceeds its byte bound")
    CORE.require(len(index_bytes) <= CORE.MAX_RESTORE_MANIFEST_BYTES, "merged restore index exceeds its byte bound")

    summary = _restore_summary(merged_session, references)
    result = {
        "session": merged_session,
        "bundle": bundle,
        "index": index,
        "bundle_bytes": bundle_bytes,
        "index_bytes": index_bytes,
        "context_bytes": payloads,
        "summary": summary,
        "input_states": list(states),
    }
    _validate_merge_candidate(result)
    return result


def _json_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8") + b"\n"


def _restore_fingerprint(state):
    parts = [CORE._restore_snapshot_fingerprint(state)]
    for relative, payload in sorted(state.get("fallback_payloads", {}).items(), key=lambda item: str(item[0])):
        parts.append(f"{relative}:{hashlib.sha256(payload).hexdigest()}")
    return hashlib.sha256("\0".join(parts).encode("utf-8")).hexdigest()


def _directory(path, label, create=False):
    path = CORE.plain_path(path, label, must_exist=not create)
    if create and not path.exists():
        with suppress(FileExistsError):
            path.mkdir(mode=0o700, parents=True)
        path = CORE.plain_path(path, label)
    CORE.require(path.is_dir(), f"{label} is not a directory: {path}")
    return path


def _write_exclusive(path, payload, label):
    path = CORE.plain_path(path, label, must_exist=False)
    CORE.require(not path.exists(), f"{label} already exists: {path}")
    descriptor = -1
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
        with os.fdopen(descriptor, "wb", closefd=True) as output:
            descriptor = -1
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
    except OSError as error:
        raise CORE.UpdateError(f"cannot persist {label}: {error}") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _sync_tree_directories(root):
    directories = [root]
    directories.extend(path for path in root.rglob("*") if path.is_dir())
    for directory in sorted(directories, key=lambda value: len(value.parts), reverse=True):
        CORE._fsync_directory(directory, "recovery backup")


def persist_restore_snapshot(state, destination):
    """Persist a validated restore transaction under a new private backup path."""
    destination = CORE.plain_path(destination, "snapshot destination", must_exist=False)
    CORE.require(not destination.exists(), f"snapshot destination already exists: {destination}")
    destination.mkdir(mode=0o700, parents=True)
    os.chmod(destination, 0o700)
    root = destination / CORE.STATE_RELATIVES[0]
    root.mkdir(mode=0o700, parents=True)
    os.chmod(root, 0o700)

    if state.get("bundle_bytes") is not None:
        bundle_path = root / CORE.RESTORE_CURRENT_RELATIVE
        bundle_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(bundle_path.parent, 0o700)
        _write_exclusive(bundle_path, state["bundle_bytes"], "restore bundle snapshot")
        for digest, payload in sorted(state.get("context_bytes", {}).items()):
            CORE.require(hashlib.sha256(payload).hexdigest() == digest, "restore context failed its content hash")
            context_directory = root / CORE.RESTORE_CONTEXTS_RELATIVE
            context_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
            os.chmod(context_directory, 0o700)
            _write_exclusive(context_directory / f"{digest}.txt", payload, "restore context snapshot")
    if state.get("index_bytes") is not None:
        _write_exclusive(root / CORE.RESTORE_INDEX_RELATIVE, state["index_bytes"], "restore index snapshot")

    _sync_tree_directories(destination)
    snapshot = CORE.read_restore_state(root, "persisted restore snapshot")
    CORE.require(
        _restore_fingerprint(snapshot) == _restore_fingerprint(state),
        "persisted restore snapshot differs from its verified source",
    )
    return root, snapshot


def _atomic_replace(path, payload, label):
    parent = _directory(path.parent, f"{label} parent", create=True)
    path = CORE.plain_path(parent / path.name, label, must_exist=False)
    if path.exists():
        info = path.lstat()
        CORE.require(stat.S_ISREG(info.st_mode), f"{label} is not a regular file: {path}")
    temporary = parent / f".{path.name}.recovery-{uuid.uuid4().hex}.tmp"
    _write_exclusive(temporary, payload, f"temporary {label}")
    try:
        os.replace(temporary, path)
    except OSError as error:
        with suppress(OSError):
            temporary.unlink()
        raise CORE.UpdateError(f"cannot atomically publish {label}: {error}") from error
    try:
        CORE._fsync_directory(parent, f"{label} parent")
    except CORE.UpdateError as error:
        raise CORE.UpdateError(
            f"{label} was renamed into place but its parent directory could not be synced: {error}"
        ) from error


def _install_context(context_directory, digest, payload):
    CORE.require(hashlib.sha256(payload).hexdigest() == digest, "merged context failed its content hash")
    destination = CORE.plain_path(
        context_directory / f"{digest}.txt", "content-addressed restore context", must_exist=False
    )
    if destination.exists():
        existing = CORE._read_restore_file(destination, CORE.MAX_RESTORE_CONTEXT_BYTES, f"restore context {digest}.txt")
        CORE.require(existing == payload, f"content-addressed restore context differs: {destination}")
        return

    temporary = context_directory / f".{digest}.recovery-{uuid.uuid4().hex}.tmp"
    _write_exclusive(temporary, payload, "temporary restore context")
    try:
        try:
            os.link(temporary, destination, follow_symlinks=False)
        except FileExistsError:
            existing = CORE._read_restore_file(
                destination, CORE.MAX_RESTORE_CONTEXT_BYTES, f"restore context {digest}.txt"
            )
            CORE.require(existing == payload, f"content-addressed restore context differs: {destination}")
        temporary.unlink()
    except OSError as error:
        with suppress(OSError):
            temporary.unlink()
        raise CORE.UpdateError(f"cannot persist restore context {digest}: {error}") from error


def publish_restore_state(root, state, expected_state):
    """Publish the bundle then index, after a lock-time fingerprint check."""
    _validate_merge_candidate(state)
    inputs = state.get("input_states")
    CORE.require(isinstance(inputs, (list, tuple)) and bool(inputs), "merged restore has no validated base snapshot")
    CORE.require(
        _restore_fingerprint(inputs[0]) == _restore_fingerprint(expected_state),
        "merged restore candidate was not based on the expected live snapshot; no files were written",
    )
    root = CORE.plain_path(root, "RustV1 restore state root")
    CORE.require(root.is_dir(), f"RustV1 restore state root is not a directory: {root}")
    contexts = state.get("context_bytes")
    CORE.require(isinstance(contexts, dict), "merged restore context payloads are invalid")
    bundle_bytes = state.get("bundle_bytes") or _json_bytes(state["bundle"])
    index_bytes = state.get("index_bytes") or _json_bytes(state["index"])
    CORE.require(len(bundle_bytes) <= CORE.MAX_RESTORE_MANIFEST_BYTES, "merged restore bundle exceeds its byte bound")
    CORE.require(len(index_bytes) <= CORE.MAX_RESTORE_MANIFEST_BYTES, "merged restore index exceeds its byte bound")

    before = CORE.read_restore_state(root, "current Rust restore state")
    CORE.require(
        _restore_fingerprint(before) == _restore_fingerprint(expected_state),
        "Rust restore state changed before recovery publication; no files were written",
    )

    context_directory = root / CORE.RESTORE_CONTEXTS_RELATIVE
    _directory(context_directory, "restore contexts directory", create=True)
    os.chmod(context_directory, 0o700)
    for digest, payload in sorted(contexts.items()):
        _install_context(context_directory, digest, payload)
    CORE._fsync_directory(context_directory, "restore contexts")

    # Re-read immediately before manifest publication. This catches any writer
    # that changed the profile while the content-addressed contexts were staged.
    current = CORE.read_restore_state(root, "current Rust restore state")
    CORE.require(
        _restore_fingerprint(current) == _restore_fingerprint(expected_state),
        "Rust restore state changed before recovery publication; no manifest was replaced",
    )
    for relative in (CORE.RESTORE_CURRENT_RELATIVE, CORE.RESTORE_INDEX_RELATIVE):
        target = root / relative
        CORE.plain_path(target, f"restore manifest {relative}", must_exist=False)
        if target.exists():
            CORE.require(stat.S_ISREG(target.lstat().st_mode), f"restore manifest is not a regular file: {target}")

    # RustV1 accepts a new current bundle that names the old on-disk index token;
    # replacing the index second leaves a valid recoverable pair at each step.
    _atomic_replace(root / CORE.RESTORE_CURRENT_RELATIVE, bundle_bytes, "current restore bundle")
    _atomic_replace(root / CORE.RESTORE_INDEX_RELATIVE, index_bytes, "restore index")
    CORE._fsync_directory(root, "RustV1 restore root")
    return CORE.read_restore_state(root, "published Rust restore state")


def _compare_preserved_object(original, actual, fill_fields, ignored_fields, label):
    CORE.require(isinstance(original, dict) and isinstance(actual, dict), f"{label} changed shape during recovery")
    for key in set(original) | set(actual):
        if key in ignored_fields:
            continue
        if key in fill_fields:
            old_present = key in original
            new_present = key in actual
            old_value = original.get(key)
            new_value = actual.get(key)
            if old_present and CORE._has_saved_identity(old_value):
                CORE.require(
                    new_present and new_value == old_value, f"populated {label} field {key} changed during recovery"
                )
            elif new_present and CORE._has_saved_identity(new_value):
                CORE.require(
                    not old_present or not CORE._has_saved_identity(old_value),
                    f"{label} field {key} changed during recovery",
                )
            else:
                CORE.require(
                    old_present == new_present and old_value == new_value,
                    f"empty {label} field {key} changed during recovery",
                )
            continue
        CORE.require(
            (key in original) == (key in actual) and original.get(key) == actual.get(key),
            f"{label} field {key} changed during recovery",
        )


def _verify_preserved_tab(original, actual):
    tab_uuid = original["uuid"]
    _compare_preserved_object(original, actual, set(TAB_FIELDS), {"panes"}, f"tab {tab_uuid}")
    original_panes = original.get("panes", [])
    actual_panes = actual.get("panes", [])
    CORE.require(len(actual_panes) >= len(original_panes), f"a pane was removed from current tab {tab_uuid}")
    CORE.require(
        [pane.get("id") for pane in actual_panes[: len(original_panes)]] == [pane.get("id") for pane in original_panes],
        f"current pane order changed in tab {tab_uuid}",
    )
    for old_pane, new_pane in zip(original_panes, actual_panes, strict=False):
        _compare_preserved_object(old_pane, new_pane, set(PANE_FIELDS), set(), f"pane {old_pane['id']}")


def _verify_preserved_pane(original, actual):
    _compare_preserved_object(original, actual, set(PANE_FIELDS), set(), f"pane {original['id']}")


def _verify_full_preservation(published, inputs, merged):
    """Check raw current payload and every copied older tab after publication."""
    bundle = _json_object(published["bundle_bytes"], "published restore bundle")
    actual_session = bundle["session"]
    CORE.require(actual_session == merged["session"], "published restore session differs from the verified merge")
    CORE.require(
        published.get("context_bytes") == merged["context_bytes"],
        "published restore contexts differ from the verified merge",
    )

    actual_tabs = {tab["uuid"]: tab for window in actual_session["windows"] for tab in window.get("tabs", [])}
    earlier_tabs = (
        {tab["uuid"] for window in _state_documents(inputs[0])[1].get("windows", []) for tab in window.get("tabs", [])}
        if inputs
        else set()
    )
    earlier_panes = (
        {
            tab["uuid"]: {pane["id"] for pane in tab.get("panes", [])}
            for window in _state_documents(inputs[0])[1].get("windows", [])
            for tab in window.get("tabs", [])
        }
        if inputs
        else {}
    )
    last_tab_layer = {}
    last_pane_layer = {}
    for layer, state in enumerate(inputs):
        _, layer_session = _state_documents(state)
        for layer_window in layer_session.get("windows", []):
            for layer_tab in layer_window.get("tabs", []):
                last_tab_layer[layer_tab["uuid"]] = layer
                for layer_pane in layer_tab.get("panes", []):
                    last_pane_layer[(layer_tab["uuid"], layer_pane["id"])] = layer

    for layer, state in enumerate(inputs[1:], start=1):
        _, source_session = _state_documents(state)
        for window in source_session.get("windows", []):
            for tab in window.get("tabs", []):
                CORE.require(tab["uuid"] in actual_tabs, "a previously saved tab is absent from the published restore")
                if tab["uuid"] not in earlier_tabs:
                    if last_tab_layer[tab["uuid"]] == layer:
                        CORE.require(
                            actual_tabs[tab["uuid"]] == tab, "a tab copied from an older restore snapshot changed"
                        )
                    else:
                        _verify_preserved_tab(tab, actual_tabs[tab["uuid"]])
                else:
                    actual_panes = {pane["id"]: pane for pane in actual_tabs[tab["uuid"]].get("panes", [])}
                    prior_panes = earlier_panes.setdefault(tab["uuid"], set())
                    for pane in tab.get("panes", []):
                        CORE.require(
                            pane["id"] in actual_panes, "a previously saved pane is absent from the published restore"
                        )
                        if pane["id"] not in prior_panes:
                            if last_pane_layer[(tab["uuid"], pane["id"])] == layer:
                                CORE.require(
                                    actual_panes[pane["id"]] == pane,
                                    "a pane copied from an older restore snapshot changed",
                                )
                            else:
                                _verify_preserved_pane(pane, actual_panes[pane["id"]])
                        prior_panes.add(pane["id"])
                earlier_panes.setdefault(tab["uuid"], set()).update(pane["id"] for pane in tab.get("panes", []))
                earlier_tabs.add(tab["uuid"])

    # Existing current payload and window order are retained; only missing tabs
    # and empty critical metadata can be added by the conservative merge.
    if inputs:
        _, base_session = _state_documents(inputs[0])
        actual_windows = actual_session.get("windows", [])
        base_windows = base_session.get("windows", [])
        CORE.require(len(actual_windows) >= len(base_windows), "a current window was removed during recovery")
        for window_index, base_window in enumerate(base_windows):
            base_ids = [tab["uuid"] for tab in base_window.get("tabs", [])]
            actual_window = actual_windows[window_index]
            if not base_ids:
                CORE.require(actual_window == base_window, "a current empty window changed during recovery")
                continue
            actual_ids = [tab["uuid"] for tab in actual_window.get("tabs", [])]
            CORE.require(
                actual_ids[: len(base_ids)] == base_ids, "current window or tab ordering changed during recovery"
            )
            _compare_preserved_object(base_window, actual_window, set(), {"tabs"}, f"window {window_index}")
            actual_by_uuid = {tab["uuid"]: tab for tab in actual_window.get("tabs", [])}
            for base_tab in base_window.get("tabs", []):
                _verify_preserved_tab(base_tab, actual_by_uuid[base_tab["uuid"]])
        _compare_preserved_object(base_session, actual_session, set(), {"windows"}, "current restore session")


def _validate_merge_candidate(state, input_states=None):
    """Run CORE and full-payload invariants before any manifest write."""
    inputs = list(input_states if input_states is not None else state.get("input_states", []))
    CORE.require(bool(inputs), "merged restore has no validated source snapshots")
    bundle = state.get("bundle")
    index = state.get("index")
    session = state.get("session")
    context_bytes = state.get("context_bytes")
    CORE.require(
        isinstance(bundle, dict)
        and isinstance(index, dict)
        and isinstance(session, dict)
        and isinstance(context_bytes, dict),
        "merged restore candidate is incomplete",
    )
    CORE.require(bundle.get("session") == session, "merged bundle and session object differ")
    CORE.require(
        index.get("version") == session.get("version") and index.get("windows") == session.get("windows"),
        "merged bundle and index sessions differ",
    )
    token = CORE._valid_restore_token(bundle.get("save_token"), "merged bundle save_token")
    CORE.require(index.get("save_token") == token, "merged bundle and index save tokens differ")
    CORE.require(
        index.get("explicit_clear") is False and bundle.get("explicit_clear") is False,
        "merged restore cannot be marked explicitly cleared",
    )
    expected_previous = None
    if inputs[0].get("index_bytes") is not None:
        expected_previous = _json_object(inputs[0]["index_bytes"], "current restore index").get("save_token")
    CORE.require(
        bundle.get("previous_index_token") == expected_previous,
        "merged bundle does not name the current on-disk index token",
    )

    identity = CORE._restore_session_identity(session, "merged restore session")
    context_map = bundle.get("contexts")
    CORE.require(isinstance(context_map, dict), "merged restore context map is invalid")
    mapped = {}
    for raw_pane_id, reference in context_map.items():
        CORE.require(
            isinstance(raw_pane_id, str) and raw_pane_id.isdigit(), "merged restore has an invalid context pane key"
        )
        pane_id = int(raw_pane_id)
        pane = identity["panes"].get(pane_id)
        CORE.require(
            pane is not None and pane.get("scrollback") is True,
            "merged restore context refers to an absent or non-scrollback pane",
        )
        CORE.require(isinstance(reference, dict), "merged restore context reference is invalid")
        digest = reference.get("sha256")
        payload = context_bytes.get(digest)
        CORE.require(
            isinstance(digest, str)
            and payload is not None
            and hashlib.sha256(payload).hexdigest() == digest
            and reference.get("byte_count") == len(payload),
            "merged restore context payload does not match its reference",
        )
        mapped[pane_id] = digest
    CORE.require(
        all(pane.get("scrollback") is not True or pane_id in mapped for pane_id, pane in identity["panes"].items()),
        "merged restore is missing a scrollback context",
    )
    CORE.require(set(context_bytes) == set(mapped.values()), "merged restore contains an unreferenced context payload")
    identity["contexts"] = mapped

    candidate = {
        "mode": "current",
        "save_token": token,
        "identity": identity,
        "bundle_bytes": state.get("bundle_bytes"),
        "index_bytes": state.get("index_bytes"),
        "context_bytes": context_bytes,
        "prequit_root": "<in-memory validated restore candidate>",
    }
    CORE.require(
        candidate["bundle_bytes"] == _json_bytes(bundle) and candidate["index_bytes"] == _json_bytes(index),
        "merged restore bytes differ from their in-memory objects",
    )
    _verify_full_preservation(candidate, inputs, state)
    for prior in inputs:
        prior_for_check = dict(prior)
        prior_for_check.setdefault("prequit_root", "<validated restore snapshot>")
        CORE.compare_restore_states(
            prior_for_check,
            candidate,
            backup=Path("/private/tmp"),
            post_path=Path("<in-memory-merged-restore>"),
        )
    return candidate


def _layout_editor_paths(session):
    paths = set()

    def visit(node):
        if not isinstance(node, dict):
            return
        if node.get("type") == "editor":
            raw_path = node.get("path")
            if raw_path is not None:
                CORE.require(
                    isinstance(raw_path, str) and bool(raw_path), "saved editor layout contains an invalid file path"
                )
                path = Path(raw_path)
                CORE.require(path.is_absolute(), "saved editor layout contains a non-absolute file path")
                paths.add(path)
        children = node.get("children")
        if isinstance(children, list):
            for child in children:
                visit(child)

    for window in session.get("windows", []):
        for tab in window.get("tabs", []):
            visit(tab.get("layout"))
    return sorted(paths, key=str)


def _editor_file_info(path, backup_directory=None):
    path = CORE.plain_path(path, "saved editor file")
    try:
        initial = path.lstat()
        CORE.require(stat.S_ISREG(initial.st_mode), f"saved editor path is not a regular file: {path}")
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError as error:
        raise CORE.UpdateError(f"cannot inspect saved editor file: {error}") from error

    temporary = None
    output = None
    digest = hashlib.sha256()
    byte_count = 0
    try:
        opened = os.fstat(descriptor)
        CORE.require(
            stat.S_ISREG(opened.st_mode) and (opened.st_dev, opened.st_ino) == (initial.st_dev, initial.st_ino),
            "saved editor file changed while being opened",
        )
        if backup_directory is not None:
            backup_directory = _directory(backup_directory, "editor snapshot directory", create=True)
            temporary = backup_directory / f".editor-{uuid.uuid4().hex}.tmp"
            output_descriptor = os.open(
                temporary,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
                0o600,
            )
            output = os.fdopen(output_descriptor, "wb", closefd=True)
        with os.fdopen(descriptor, "rb", closefd=True) as source:
            descriptor = -1
            while True:
                chunk = source.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
                byte_count += len(chunk)
                if output is not None:
                    output.write(chunk)
            final = os.fstat(source.fileno())
        CORE.require(
            (final.st_dev, final.st_ino, final.st_size, final.st_mtime_ns)
            == (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns)
            and byte_count == opened.st_size,
            "saved editor file changed while it was being snapshotted",
        )
        if output is not None:
            output.flush()
            os.fsync(output.fileno())
            output.close()
            output = None

        content_hash = digest.hexdigest()
        record = {
            "source": str(path),
            "sha256": content_hash,
            "byte_count": byte_count,
        }
        if backup_directory is not None:
            path_hash = hashlib.sha256(str(path).encode("utf-8")).hexdigest()
            filename = f"{path_hash}-{content_hash}.snapshot"
            destination = backup_directory / filename
            if destination.exists():
                CORE.require(
                    stat.S_ISREG(destination.lstat().st_mode) and CORE.sha256_file(destination) == content_hash,
                    "an existing editor snapshot differs from its source",
                )
                temporary.unlink()
            else:
                os.link(temporary, destination, follow_symlinks=False)
                temporary.unlink()
                CORE._fsync_directory(backup_directory, "editor snapshot")
            record["backup"] = str(destination.relative_to(backup_directory.parent))
        return record
    except OSError as error:
        raise CORE.UpdateError(f"cannot snapshot saved editor file: {error}") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if output is not None:
            output.close()
        if temporary is not None and temporary.exists():
            with suppress(OSError):
                temporary.unlink()


def verify_and_snapshot_editor_files(states, backup, phase):
    paths = set()
    for state in states:
        _, session = _state_documents(state)
        paths.update(_layout_editor_paths(session))
    editor_directory = backup / "editor-files" if backup is not None else None
    records = [_editor_file_info(path, editor_directory) for path in sorted(paths, key=str)]
    if backup is not None:
        manifest = backup / f"editor-files-{phase}.json"
        _write_exclusive(manifest, _json_bytes({"files": records}), f"{phase} editor snapshot manifest")
    return records


def _create_recovery_backup(home):
    parent = CORE.plain_path(home / RECOVERY_BACKUP_RELATIVE, "recovery backup parent", must_exist=False)
    if not parent.exists():
        parent.mkdir(mode=0o700, parents=True)
    CORE.require(parent.is_dir(), f"recovery backup parent is not a directory: {parent}")
    os.chmod(parent, 0o700)
    run_id = time.strftime("%Y%m%d-%H%M%S") + f"-{os.getpid()}-{uuid.uuid4().hex[:8]}"
    backup = parent / run_id
    backup.mkdir(mode=0o700)
    os.chmod(backup, 0o700)
    return backup


def _print_summary(label, summary):
    print(
        f"{label}: tabs={summary['tabs']} windows={summary['windows']} "
        f"panes={summary['panes']} contexts={summary['contexts']} "
        f"duplicate-provider-pairs={summary['duplicate_provider_pairs']}"
    )


def _counts(state):
    _, session = _state_documents(state)
    contexts = _state_contexts(state)
    references = {int(pane_id): reference["sha256"] for pane_id, reference in contexts.items()}
    return _restore_summary(session, references)


def _canonical_current_root(home):
    path = CORE.plain_path(home / CORE.STATE_RELATIVES[0], "canonical RustV1 state root")
    CORE.require(path.is_dir(), f"canonical RustV1 state root is not a directory: {path}")
    return path


def _require_historical_source(source_root, home):
    for relative in CORE.STATE_RELATIVES:
        live_root = CORE.plain_path(home / relative, f"live RustV1 state root {relative}", must_exist=False)
        try:
            source_root.relative_to(live_root)
            inside_live = True
        except ValueError:
            inside_live = False
        try:
            live_root.relative_to(source_root)
            contains_live = True
        except ValueError:
            contains_live = False
        CORE.require(
            not inside_live and not contains_live,
            "--source must be a preserved historical snapshot, not a live profile path",
        )


def dry_run(source_path, home):
    source_root = CORE.plain_path(source_path, "preserved RustV1 source snapshot")
    _require_historical_source(source_root, home)
    current_root = _canonical_current_root(home)
    source = CORE.read_restore_state(source_root, "preserved RustV1 source snapshot")
    current = CORE.read_restore_state(current_root, "current RustV1 state")
    CORE.require(source["identity"]["has_tabs"], "preserved source snapshot contains no restorable tabs")
    editor_records = verify_and_snapshot_editor_files([current, source], None, "dry-run")
    merged = merge_restore_states([current, source])
    _print_summary("current", _counts(current))
    _print_summary("source", _counts(source))
    _print_summary("union", merged["summary"])
    print(f"editor files: {len(editor_records)}")
    print("conflicts: none")


def apply_recovery(source_path, home, wait_seconds):
    CORE.require(sys.stdout.isatty(), "--apply must be run from an interactive Terminal")
    CORE.require(
        isinstance(wait_seconds, int) and 1 <= wait_seconds <= 3600, "--wait-seconds must be between 1 and 3600"
    )
    CORE.require_terminal()

    source_root = CORE.plain_path(source_path, "preserved RustV1 source snapshot")
    _require_historical_source(source_root, home)
    current_root = _canonical_current_root(home)
    source = CORE.read_restore_state(source_root, "preserved RustV1 source snapshot")
    CORE.require(source["identity"]["has_tabs"], "preserved source snapshot contains no restorable tabs")

    backup = _create_recovery_backup(home)
    try:
        prequit = CORE.capture_prequit_restore(current_root, backup, home)
        source_snapshot_root, source_snapshot = persist_restore_snapshot(source, backup / "preserved-source")
        editor_records = verify_and_snapshot_editor_files([prequit, source_snapshot], backup, "prequit")
        # Fail on identity/layout conflicts while the app is still open so the
        # user never has to quit for a merge that cannot be published safely.
        preflight = merge_restore_states([prequit, source_snapshot])
    except (CORE.UpdateError, OSError) as error:
        raise CORE.UpdateError(
            f"recovery preflight failed; no quit was requested. Backups retained at {backup}. {error}"
        ) from error

    _print_summary("preflight union", preflight["summary"])
    print(f"editor files backed up: {len(editor_records)}")
    print(f"Recovery snapshots are retained at {backup}.", flush=True)
    CORE.ask_for_normal_quit(wait_seconds, prequit["prequit_root"])

    try:
        lock_file = CORE.acquire_instance_lock(home)
    except CORE.UpdateError as error:
        raise CORE.UpdateError(f"{error} Keep Chau7 closed. Recovery snapshots are retained at {backup}.") from error
    try:
        try:
            CORE.require(
                not CORE.active_application_pids(),
                "Chau7 reopened after normal quit; recovery did not publish manifests",
            )
            postquit = CORE.read_restore_state(current_root, "post-quit RustV1 state")
            CORE.snapshot_state([current_root], backup, home)
            postquit_root = backup / "state" / CORE.STATE_RELATIVES[0]
            postquit_snapshot = CORE.read_restore_state(postquit_root, "post-quit state snapshot")
            postquit_editor_records = verify_and_snapshot_editor_files([postquit_snapshot], backup, "postquit")
            postquit["prequit_root"] = str(postquit_root)
            prequit.setdefault("prequit_root", str(prequit.get("snapshot_root", current_root)))
            prequit["prequit_root"] = str(prequit["prequit_root"])
            source_snapshot["prequit_root"] = str(source_snapshot_root)
            CORE.require(
                _restore_fingerprint(postquit) == _restore_fingerprint(postquit_snapshot),
                "post-quit restore snapshot differs from the locked live state",
            )

            merged = merge_restore_states([postquit_snapshot, prequit, source_snapshot])
            published = publish_restore_state(current_root, merged, postquit_snapshot)
            for prior in (postquit_snapshot, prequit, source_snapshot):
                prior.setdefault("prequit_root", str(prior.get("snapshot_root", current_root)))
                CORE.compare_restore_states(
                    prior,
                    published,
                    backup,
                    post_path=postquit_root,
                )
            _verify_full_preservation(published, [postquit_snapshot, prequit, source_snapshot], merged)
            _print_summary("recovered", _counts(published))
            print(f"post-quit editor files backed up: {len(postquit_editor_records)}")
            print(
                f"Recovery verified. Keep Chau7 closed and run the ordinary updater with --apply "
                f"immediately before opening it. Recovery snapshots are retained at {backup}.",
                flush=True,
            )
        except (CORE.UpdateError, OSError) as error:
            raise CORE.UpdateError(
                f"{error} Keep Chau7 closed. Re-read the current restore state before retrying; "
                f"a manifest may have advanced. Recovery snapshots are retained at {backup}; "
                "no app launch or installation was performed."
            ) from error
    finally:
        lock_file.close()


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source",
        required=True,
        type=Path,
        help="preserved, verified RustV1 state root containing the older restore snapshot",
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true", help="read and validate both snapshots, then print counts only")
    mode.add_argument("--apply", action="store_true", help="interactively capture, merge, and publish restore state")
    parser.add_argument(
        "--wait-seconds", type=int, default=120, help="time to wait for a normal Cmd+Q quit (default: 120)"
    )
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        CORE.require(os.geteuid() != 0, "run from your normal user account, never with sudo")
        home = CORE.account_home()
        CORE.ensure_default_profile_environment()
        if args.dry_run:
            try:
                dry_run(args.source, home)
            except RecoveryConflict as error:
                print("conflicts: 1")
                print(f"conflict: {error}")
                return 1
            except CORE.UpdateError:
                print("validation: failed")
                return 1
        else:
            os.umask(0o077)
            apply_recovery(args.source, home, args.wait_seconds)
    except (CORE.UpdateError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
