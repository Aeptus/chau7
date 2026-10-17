#!/usr/bin/env python3
"""Synthetic, non-installing tests for update-macos-production.command."""

import fcntl
import hashlib
import json
import plistlib
import re
import shutil
import socket
import tempfile
import types
import unittest
import uuid
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).with_name("update-macos-production.command")
SOURCE = SCRIPT.read_text(encoding="utf-8")
match = re.search(
    r"(?ms)^# PYTHON_CORE_BEGIN\n(.*?)^# PYTHON_CORE_END$",
    SOURCE,
)
if match is None:
    raise RuntimeError("updater Python core markers are missing")
CORE = types.ModuleType("production_updater_core")
exec(compile(match.group(1), str(SCRIPT), "exec"), CORE.__dict__)

REVISION = "0123456789abcdef0123456789abcdef01234567"
BUILD = "202610160001"


class ProductionUpdaterTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="chau7-production-update-", dir="/private/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / f"{CORE.EXPECTED_EXECUTABLE}.app"
        executable_directory = self.app / "Contents/MacOS"
        executable_directory.mkdir(parents=True)
        self.info = {
            "CFBundleIdentifier": CORE.EXPECTED_BUNDLE_ID,
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": CORE.EXPECTED_EXECUTABLE,
            "CFBundleVersion": BUILD,
            "CFBundleShortVersionString": "0.6.0-rc.1",
            "Chau7BuildChannel": "production",
            "Chau7SourceRevision": REVISION,
        }
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))
        artifacts = {}
        for name, relative in CORE.ARTIFACTS.items():
            path = self.app / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            payload = ("synthetic executable " + name).encode()
            path.write_bytes(payload)
            path.chmod(0o755)
            artifacts[name] = {"path": relative, "sha256": hashlib.sha256(payload).hexdigest()}
        self.receipt = {
            "channel": "production",
            "target": CORE.host_rust_target(),
            "bundleIdentifier": CORE.EXPECTED_BUNDLE_ID,
            "sourceRevision": REVISION,
            "sourceDirty": False,
            "appSignatureVerified": True,
            "cargoFeatures": ["chau7_next_core/production"],
            "appExecutable": CORE.EXPECTED_EXECUTABLE,
            "buildNumber": BUILD,
            "releaseVersion": "0.6.0-rc.1",
            "artifacts": artifacts,
        }

    def transaction_folders(self):
        root = self.root / "transaction"
        root.mkdir()
        paths = [root / name for name in ("stage", "destination", "rollback", "failed")]
        for path in paths[:2]:
            path.mkdir()
        return tuple(paths)

    @staticmethod
    def move_locally(source, destination):
        source.rename(destination)

    @staticmethod
    def verify_new_bundle(bundle):
        marker = (bundle / "build").read_text(encoding="utf-8")
        if marker != "new":
            raise CORE.UpdateError("not the synthetic new build")
        return marker

    @staticmethod
    def verify_old_bundle(bundle):
        marker = (bundle / "build").read_text(encoding="utf-8")
        if marker != "old":
            raise CORE.UpdateError("not the synthetic old build")
        return marker

    def validate(self, receipt=None, expected=REVISION):
        with mock.patch.object(CORE, "verify_code_signature"):
            return CORE.validate_candidate(self.app, receipt or self.receipt, expected)

    def write_restore_state(self, windows, token, explicit_clear=False, contexts=None, previous_index_token=None):
        state = self.root / CORE.STATE_RELATIVES[0]
        state.mkdir(parents=True, exist_ok=True)
        contexts = contexts or {}
        references = {}
        context_directory = state / CORE.RESTORE_CONTEXTS_RELATIVE
        for pane_id, payload in contexts.items():
            context_directory.mkdir(parents=True, exist_ok=True)
            digest = hashlib.sha256(payload).hexdigest()
            (context_directory / f"{digest}.txt").write_bytes(payload)
            references[str(pane_id)] = {"sha256": digest, "byte_count": len(payload)}

        session = {"version": 1, "windows": windows}
        bundle = {
            "schema_version": 1,
            "save_token": token,
            "previous_index_token": previous_index_token,
            "explicit_clear": explicit_clear,
            "session": session,
            "contexts": references,
        }
        index = {
            "save_token": token,
            "explicit_clear": explicit_clear,
            **session,
        }
        current_path = state / CORE.RESTORE_CURRENT_RELATIVE
        current_path.parent.mkdir(parents=True, exist_ok=True)
        current_path.write_text(json.dumps(bundle), encoding="utf-8")
        (state / CORE.RESTORE_INDEX_RELATIVE).write_text(json.dumps(index), encoding="utf-8")
        return state, bundle, index

    @staticmethod
    def saved_tab(tab_uuid, pane_id, session_id, scrollback=False):
        return {
            "uuid": str(uuid.UUID(tab_uuid)),
            "cwd": "/repo",
            "custom_title": None,
            "color": "blue",
            "repo_group_id": None,
            "created_at": 10.0,
            "manual_color": False,
            "focused_pane": pane_id,
            "panes": [
                {
                    "id": pane_id,
                    "directory": "/repo",
                    "scrollback": scrollback,
                    "ai_provider": "claude",
                    "ai_session_id": session_id,
                    "ai_session_id_source": "observed",
                    "ai_resume_command": f"claude --resume {session_id}",
                    "archived_ai_resume": None,
                    "agent_launch_command": None,
                }
            ],
        }

    @classmethod
    def saved_window(cls, *tabs, selected=0):
        return {
            "tabs": list(tabs),
            "selected": selected,
            "x": 100.0,
            "y": 100.0,
            "width": 900.0,
            "height": 700.0,
        }

    def new_run_backup(self):
        backup = self.root / "update-backup"
        backup.mkdir(mode=0o700)
        return backup

    def new_historical_backup(self, run_id):
        parent = self.root / CORE.UPDATE_BACKUP_RELATIVE
        parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        backup = parent / run_id
        backup.mkdir(mode=0o700)
        return backup

    def write_historical_run(self, run_id, pre_windows, post_windows=None, previous=False):
        state, _, _ = self.write_restore_state(pre_windows, str(uuid.uuid4()))
        backup = self.new_historical_backup(run_id)
        CORE.capture_prequit_restore(state, backup, self.root)
        if post_windows is not None:
            self.write_restore_state(post_windows, str(uuid.uuid4()))
            CORE.snapshot_state([state], backup, self.root)
        if previous:
            previous_bundle = backup / "previous" / "Chau7.app"
            previous_bundle.parent.mkdir(mode=0o700)
            shutil.copytree(self.app, previous_bundle)
        return backup

    def capture_current_run(self, run_id):
        state = self.root / CORE.STATE_RELATIVES[0]
        backup = self.new_historical_backup(run_id)
        current = CORE.capture_prequit_restore(state, backup, self.root)
        return backup, current

    @staticmethod
    def saved_split(*pane_ids):
        return {
            "type": "split",
            "id": max(pane_ids, default=0) + 100,
            "axis": "horizontal",
            "ratios": [1.0 / len(pane_ids)] * len(pane_ids) if pane_ids else [],
            "children": [{"type": "terminal", "id": pane_id, "directory": "/repo"} for pane_id in pane_ids],
        }

    def test_accepts_exact_clean_rust_production_receipt(self):
        result = self.validate()
        self.assertEqual(result["sourceRevision"], REVISION)
        self.assertEqual(result["buildNumber"], BUILD)

    def test_host_target_mapping_and_receipt_compatibility(self):
        self.assertEqual(CORE.host_rust_target("arm64"), "aarch64-apple-darwin")
        self.assertEqual(CORE.host_rust_target("x86_64"), "x86_64-apple-darwin")
        with self.assertRaises(CORE.UpdateError):
            CORE.host_rust_target("unsupported")

        other_target = (
            "x86_64-apple-darwin" if CORE.host_rust_target() == "aarch64-apple-darwin" else "aarch64-apple-darwin"
        )
        with self.assertRaisesRegex(CORE.UpdateError, "receipt target"):
            self.validate(dict(self.receipt, target=other_target))

    def test_rejects_dirty_or_mismatched_source(self):
        dirty = dict(self.receipt, sourceDirty=True)
        with self.assertRaises(CORE.UpdateError):
            self.validate(dirty)
        with self.assertRaises(CORE.UpdateError):
            self.validate(expected="f" * 40)

    def test_rejects_wrong_channel_identity_and_swift_markers(self):
        for changed in (
            dict(self.receipt, channel="next"),
            dict(self.receipt, bundleIdentifier=f"{CORE.EXPECTED_BUNDLE_ID}.wrong"),
        ):
            with self.subTest(changed=changed), self.assertRaises(CORE.UpdateError):
                self.validate(changed)
        self.info.pop("Chau7BuildChannel")
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))
        with mock.patch.object(CORE, "verify_code_signature"), self.assertRaises(CORE.UpdateError):
            CORE.validate_installed_production(self.app)

    def test_rejects_missing_or_mismatched_executable_hash(self):
        artifact = self.app / CORE.ARTIFACTS["chau7-optim"]
        artifact.write_bytes(b"modified")
        with self.assertRaises(CORE.UpdateError):
            self.validate()

    def test_rejects_extra_executable_and_symlink_entries(self):
        extra = self.app / "Contents/MacOS/unreceipted-helper"
        extra.write_bytes(b"unexpected")
        extra.chmod(0o755)
        with self.assertRaises(CORE.UpdateError):
            self.validate()
        extra.unlink()
        link = self.app / "Contents/MacOS/linked-helper"
        link.symlink_to(self.app / CORE.ARTIFACTS[CORE.EXPECTED_EXECUTABLE])
        with self.assertRaises(CORE.UpdateError):
            self.validate()

    def test_apply_terminal_gate_checks_the_controlling_terminal(self):
        class FakeTerminal:
            def isatty(self):
                return True

            def close(self):
                pass

        with (
            mock.patch.object(CORE.sys.stdout, "isatty", return_value=True),
            mock.patch("builtins.open", return_value=FakeTerminal()) as open_terminal,
        ):
            CORE.require_terminal()
        open_terminal.assert_called_once_with("/dev/tty", "r", encoding="utf-8")

    def test_rejects_short_sha_and_symlink_input_path(self):
        with self.assertRaises(CORE.UpdateError):
            self.validate(expected="01234567")
        link = self.root / "Candidate.app"
        link.symlink_to(self.app, target_is_directory=True)
        with self.assertRaises(CORE.UpdateError):
            CORE.plain_path(link, "candidate app")

    def test_installed_validation_requires_rust_production_identity(self):
        with mock.patch.object(CORE, "verify_code_signature"):
            self.assertEqual(CORE.validate_installed_production(self.app)["sourceRevision"], REVISION)
        next_info = dict(self.info)
        next_info["CFBundleIdentifier"] = f"{CORE.EXPECTED_BUNDLE_ID}.wrong"
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(next_info))
        with mock.patch.object(CORE, "verify_code_signature"), self.assertRaises(CORE.UpdateError):
            CORE.validate_installed_production(self.app)

    def test_existing_lifetime_lock_refuses_busy_and_is_held_until_close(self):
        state = self.root / CORE.STATE_RELATIVES[0]
        state.mkdir(parents=True)
        lock_path = state / "app-instance.lock"
        lock_path.write_bytes(b"")
        original = lock_path.read_bytes()

        with lock_path.open("r+b") as owner:
            fcntl.flock(owner.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(CORE.UpdateError):
                CORE.acquire_instance_lock(self.root.resolve())

        with (
            CORE.acquire_instance_lock(self.root.resolve()),
            lock_path.open("r+b") as contender,
            self.assertRaises(BlockingIOError),
        ):
            fcntl.flock(contender.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        with lock_path.open("r+b") as contender:
            fcntl.flock(contender.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assertEqual(lock_path.read_bytes(), original)

    def test_only_known_runtime_socket_nodes_are_omitted_from_state_backup(self):
        with tempfile.TemporaryDirectory(prefix="c7u-", dir="/private/tmp") as temporary:
            short_root = Path(temporary).resolve()
            state = short_root / CORE.STATE_RELATIVES[0]
            state.mkdir(parents=True)
            (state / "profile.json").write_text('{"tabs":1}\n', encoding="utf-8")
            socket_relative = next(
                path for path in CORE.KNOWN_RUNTIME_SOCKETS[CORE.STATE_RELATIVES[0]] if path.parent == Path("Proxy")
            )
            proxy = state / socket_relative.parent
            proxy.mkdir()
            socket_path = state / socket_relative

            allowed = {socket_relative}
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(str(socket_path))
                before = CORE.tree_manifest(state, allowed)
                backup = short_root / "backup" / CORE.STATE_RELATIVES[0]
                backup.parent.mkdir(parents=True)
                CORE.copy_state_tree(state, backup, allowed)
                expected = {key: value for key, value in before.items() if value[0] != "known-runtime-socket"}
                self.assertEqual(CORE.tree_manifest(backup), expected)
                self.assertEqual(CORE.tree_manifest(state, allowed), before)
                self.assertTrue((backup / "profile.json").is_file())
                self.assertFalse((backup / socket_relative).exists())

            config_relative = CORE.STATE_RELATIVES[1]
            unexpected = short_root / config_relative
            unexpected.mkdir(parents=True)
            unknown_socket = unexpected / "other.sock"
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as other_listener:
                other_listener.bind(str(unknown_socket))
                with self.assertRaises(CORE.UpdateError):
                    CORE.tree_manifest(unexpected, CORE.KNOWN_RUNTIME_SOCKETS[config_relative])

    def test_snapshot_state_preserves_regular_file_at_known_socket_path(self):
        source = self.root / CORE.STATE_RELATIVES[0]
        socket_relative = next(
            path for path in CORE.KNOWN_RUNTIME_SOCKETS[CORE.STATE_RELATIVES[0]] if path.parent == Path("Proxy")
        )
        proxy = source / socket_relative.parent
        proxy.mkdir(parents=True)
        socket_named_file = source / socket_relative
        socket_named_file.write_text("preserve this regular file\n", encoding="utf-8")
        backup = self.root / "snapshot"
        backup.mkdir()

        before = CORE.snapshot_state([source], backup, self.root)
        relative = source.relative_to(self.root)
        copied_state = backup / "state" / relative

        self.assertEqual(before[source][socket_relative.as_posix()][0], "file")
        self.assertEqual(CORE.tree_manifest(copied_state), before[source])
        self.assertEqual(
            (copied_state / socket_relative).read_text(encoding="utf-8"),
            "preserve this regular file\n",
        )

    def test_prequit_snapshot_keeps_bundle_index_and_verified_contexts(self):
        first = self.saved_tab("00000000-0000-0000-0000-000000000001", 11, "claude-a", True)
        second = self.saved_tab("00000000-0000-0000-0000-000000000002", 22, "codex-b")
        windows = [self.saved_window(first), self.saved_window(second)]
        state, bundle, _ = self.write_restore_state(
            windows, "10000000-0000-0000-0000-000000000001", contexts={11: b"saved context\n"}
        )
        backup = self.new_run_backup()

        prequit = CORE.capture_prequit_restore(state, backup, self.root)

        pre_root = prequit["prequit_root"]
        self.assertEqual(prequit["identity"]["window_count"], 2)
        self.assertEqual(prequit["identity"]["tab_count"], 2)
        self.assertEqual(
            json.loads((pre_root / CORE.RESTORE_CURRENT_RELATIVE).read_text(encoding="utf-8")),
            bundle,
        )
        context_name = hashlib.sha256(b"saved context\n").hexdigest() + ".txt"
        self.assertEqual(
            (pre_root / CORE.RESTORE_CONTEXTS_RELATIVE / context_name).read_bytes(),
            b"saved context\n",
        )
        self.assertTrue((pre_root / CORE.RESTORE_INDEX_RELATIVE).is_file())
        self.assertTrue(prequit["prequit_manifest"].is_file())

        CORE.snapshot_state([state], backup, self.root)
        postquit = CORE.read_restore_state(backup / "state" / CORE.STATE_RELATIVES[0])
        CORE.compare_restore_states(prequit, postquit, backup)

    def test_prequit_snapshot_syncs_staging_before_rename_and_backup_after(self):
        tab = self.saved_tab("00000000-0000-0000-0000-000000000003", 13, "sync-session", True)
        state, _, _ = self.write_restore_state(
            [self.saved_window(tab)], str(uuid.uuid4()), contexts={13: b"durable context\n"}
        )
        backup = self.new_run_backup()
        events = []
        real_rename = CORE.os.rename

        def record_sync(directory, label):
            events.append(("sync", Path(directory), label))

        def record_rename(source, destination):
            events.append(("rename", Path(source), Path(destination)))
            real_rename(source, destination)

        with (
            mock.patch.object(CORE, "_fsync_directory", side_effect=record_sync),
            mock.patch.object(CORE.os, "rename", side_effect=record_rename),
        ):
            CORE.capture_prequit_restore(state, backup, self.root)

        rename_index = next(index for index, event in enumerate(events) if event[0] == "rename")
        staging = events[rename_index][1]
        self.assertGreater(rename_index, 0)
        self.assertTrue(all(event[0] == "sync" for event in events[:rename_index]))
        self.assertTrue(all(event[1] == staging or staging in event[1].parents for event in events[:rename_index]))
        self.assertTrue(any(event[1] == staging for event in events[:rename_index]))
        self.assertEqual(events[-1], ("sync", backup, "pre-quit snapshot parent"))

    def test_prequit_directory_sync_failure_stops_before_quit(self):
        tab = self.saved_tab("00000000-0000-0000-0000-000000000004", 14, "sync-session")
        self.write_restore_state([self.saved_window(tab)], str(uuid.uuid4()))
        ask = mock.Mock()
        rename = mock.Mock()

        with (
            mock.patch.object(CORE, "require_terminal"),
            mock.patch.object(CORE, "ask_for_normal_quit", ask),
            mock.patch.object(CORE, "_fsync_directory", side_effect=CORE.UpdateError("directory sync failed")),
            mock.patch.object(CORE.os, "rename", rename),
            self.assertRaisesRegex(CORE.UpdateError, "No quit was requested"),
        ):
            CORE.apply_update(self.app, self.root / "receipt.json", REVISION, 30, {}, self.root.resolve())

        ask.assert_not_called()
        rename.assert_not_called()

    def test_postquit_snapshot_rejects_a_dropped_window_and_keeps_recovery_paths(self):
        first = self.saved_tab("00000000-0000-0000-0000-000000000011", 11, "claude-a")
        second = self.saved_tab("00000000-0000-0000-0000-000000000012", 12, "codex-b")
        old_token = "10000000-0000-0000-0000-000000000011"
        state, _, _ = self.write_restore_state([self.saved_window(first), self.saved_window(second)], old_token)
        backup = self.new_run_backup()
        prequit = CORE.capture_prequit_restore(state, backup, self.root)
        self.write_restore_state([self.saved_window(first)], "10000000-0000-0000-0000-000000000012")

        CORE.snapshot_state([state], backup, self.root)
        postquit = CORE.read_restore_state(backup / "state" / CORE.STATE_RELATIVES[0])
        with self.assertRaisesRegex(CORE.UpdateError, "saved window or tab identities changed") as error:
            CORE.compare_restore_states(prequit, postquit, backup)

        self.assertIn(str(prequit["prequit_root"]), str(error.exception))
        self.assertIn(str(backup / "state" / CORE.STATE_RELATIVES[0]), str(error.exception))
        self.assertIn("keep Chau7 closed", str(error.exception))

    def test_postquit_snapshot_rejects_changed_provider_resume_identity(self):
        tab_uuid = "00000000-0000-0000-0000-000000000021"
        original = self.saved_tab(tab_uuid, 21, "claude-original")
        state, _, _ = self.write_restore_state([self.saved_window(original)], "10000000-0000-0000-0000-000000000021")
        backup = self.new_run_backup()
        prequit = CORE.capture_prequit_restore(state, backup, self.root)
        changed = self.saved_tab(tab_uuid, 21, "claude-changed")
        self.write_restore_state([self.saved_window(changed)], "10000000-0000-0000-0000-000000000022")

        CORE.snapshot_state([state], backup, self.root)
        postquit = CORE.read_restore_state(backup / "state" / CORE.STATE_RELATIVES[0])
        with self.assertRaisesRegex(CORE.UpdateError, "provider resume identity changed"):
            CORE.compare_restore_states(prequit, postquit, backup)

    def test_missing_current_bundle_with_populated_index_fails_before_quit_prompt(self):
        tab = self.saved_tab("00000000-0000-0000-0000-000000000031", 31, "claude-a")
        state, _, _ = self.write_restore_state([self.saved_window(tab)], "10000000-0000-0000-0000-000000000031")
        (state / CORE.RESTORE_CURRENT_RELATIVE).unlink()
        backup = self.new_run_backup()

        with self.assertRaisesRegex(CORE.UpdateError, "refusing to ask you to quit"):
            CORE.capture_prequit_restore(state, backup, self.root)

    def test_apply_does_not_ask_for_quit_when_current_transaction_is_missing(self):
        tab = self.saved_tab("00000000-0000-0000-0000-000000000032", 32, "claude-a")
        state, _, _ = self.write_restore_state([self.saved_window(tab)], "10000000-0000-0000-0000-000000000032")
        (state / CORE.RESTORE_CURRENT_RELATIVE).unlink()
        ask = mock.Mock()

        with (
            mock.patch.object(CORE, "require_terminal"),
            mock.patch.object(CORE, "ask_for_normal_quit", ask),
            self.assertRaisesRegex(CORE.UpdateError, "refusing to ask you to quit"),
        ):
            CORE.apply_update(self.app, self.root / "receipt.json", REVISION, 30, {}, self.root.resolve())

        ask.assert_not_called()

    def test_apply_captures_prequit_transaction_before_asking_for_quit(self):
        tab = self.saved_tab("00000000-0000-0000-0000-000000000033", 33, "claude-a", True)
        state, _, _ = self.write_restore_state(
            [self.saved_window(tab)],
            "10000000-0000-0000-0000-000000000033",
            contexts={33: b"before quit\n"},
        )
        events = []

        class FakeLock:
            def close(self):
                events.append("lock closed")

        def ask_for_quit(wait_seconds, snapshot_path):
            prequit_root = Path(snapshot_path)
            guard_path = prequit_root.parents[3] / "restore-guard.json"
            events.append(("asked", guard_path.is_file()))

        with (
            mock.patch.object(CORE, "require_terminal", side_effect=lambda: events.append("terminal")),
            mock.patch.object(CORE, "ask_for_normal_quit", side_effect=ask_for_quit),
            mock.patch.object(
                CORE,
                "acquire_instance_lock",
                side_effect=lambda home: (events.append("lock"), FakeLock())[1],
            ),
            mock.patch.object(CORE, "active_application_pids", side_effect=lambda: (events.append("pids"), [])[1]),
            mock.patch.object(CORE, "perform_update_locked", side_effect=lambda *args: events.append("update")),
        ):
            CORE.apply_update(self.app, self.root / "receipt.json", REVISION, 30, {}, self.root.resolve())

        asked = next(item for item in events if isinstance(item, tuple))
        self.assertLess(events.index("terminal"), events.index(asked))
        self.assertEqual(events[-3:], ["pids", "update", "lock closed"])
        self.assertEqual(asked, ("asked", True))

    def test_missing_current_bundle_with_populated_fallback_fails_closed(self):
        tab = self.saved_tab("00000000-0000-0000-0000-000000000041", 41, "claude-a")
        state, bundle, _ = self.write_restore_state([self.saved_window(tab)], "10000000-0000-0000-0000-000000000041")
        (state / CORE.RESTORE_CURRENT_RELATIVE).unlink()
        (state / CORE.RESTORE_INDEX_RELATIVE).unlink()
        latest = state / CORE.RESTORE_LATEST_RELATIVE
        latest.parent.mkdir(parents=True)
        latest.write_text(json.dumps(bundle), encoding="utf-8")
        backup = self.new_run_backup()

        with self.assertRaisesRegex(CORE.UpdateError, "contains restorable tabs"):
            CORE.capture_prequit_restore(state, backup, self.root)

    def test_absent_current_bundle_accepts_explicit_clear_index(self):
        state = self.root / CORE.STATE_RELATIVES[0]
        state.mkdir(parents=True)
        index = {
            "save_token": "10000000-0000-0000-0000-000000000051",
            "explicit_clear": True,
            "version": 1,
            "windows": [],
        }
        (state / CORE.RESTORE_INDEX_RELATIVE).write_text(json.dumps(index), encoding="utf-8")
        backup = self.new_run_backup()

        prequit = CORE.capture_prequit_restore(state, backup, self.root)

        self.assertEqual(prequit["mode"], "explicit-clear")
        self.assertFalse(prequit["identity"]["has_tabs"])
        self.assertEqual(
            json.loads((prequit["prequit_root"] / CORE.RESTORE_INDEX_RELATIVE).read_text(encoding="utf-8")),
            index,
        )

    def test_genuinely_unused_state_is_accepted_and_compared_with_empty_postquit(self):
        state = self.root / CORE.STATE_RELATIVES[0]
        state.mkdir(parents=True)
        backup = self.new_run_backup()

        prequit = CORE.capture_prequit_restore(state, backup, self.root)
        CORE.snapshot_state([state], backup, self.root)
        postquit = CORE.read_restore_state(backup / "state" / CORE.STATE_RELATIVES[0])
        CORE.compare_restore_states(prequit, postquit, backup)

        self.assertEqual(prequit["mode"], "unused")
        self.assertTrue(prequit["prequit_manifest"].is_file())

    def test_corrupt_context_hash_fails_before_quit_prompt(self):
        tab = self.saved_tab("00000000-0000-0000-0000-000000000061", 61, "claude-a", True)
        state, _, _ = self.write_restore_state(
            [self.saved_window(tab)],
            "10000000-0000-0000-0000-000000000061",
            contexts={61: b"original context\n"},
        )
        context_path = next((state / CORE.RESTORE_CONTEXTS_RELATIVE).glob("*.txt"))
        context_path.write_bytes(b"corrupt context\n")
        backup = self.new_run_backup()

        with self.assertRaisesRegex(CORE.UpdateError, "hash or byte count does not verify"):
            CORE.capture_prequit_restore(state, backup, self.root)
        self.assertFalse((backup / "pre-quit").exists())
        self.assertEqual(list(backup.glob(".pre-quit-stage-*")), [])

    def test_current_bundle_and_index_tokens_must_form_one_transaction(self):
        tab = self.saved_tab("00000000-0000-0000-0000-000000000071", 71, "claude-a")
        state, _, index = self.write_restore_state([self.saved_window(tab)], "10000000-0000-0000-0000-000000000071")
        index["save_token"] = "10000000-0000-0000-0000-000000000072"
        (state / CORE.RESTORE_INDEX_RELATIVE).write_text(json.dumps(index), encoding="utf-8")
        backup = self.new_run_backup()

        with self.assertRaisesRegex(CORE.UpdateError, "do not form a verified save transaction"):
            CORE.capture_prequit_restore(state, backup, self.root)

    def test_postquit_allows_added_windows_tabs_and_resume_metadata_enrichment(self):
        first = self.saved_tab("00000000-0000-0000-0000-000000000081", 81, "stable-session")
        initially_unknown = self.saved_tab("00000000-0000-0000-0000-000000000082", 82, "placeholder")
        for field in (
            "ai_provider",
            "ai_session_id",
            "ai_session_id_source",
            "ai_resume_command",
            "agent_launch_command",
        ):
            initially_unknown["panes"][0][field] = None
        state, _, _ = self.write_restore_state(
            [self.saved_window(first), self.saved_window(initially_unknown)],
            "10000000-0000-0000-0000-000000000081",
        )
        backup = self.new_run_backup()
        prequit = CORE.capture_prequit_restore(state, backup, self.root)

        enriched = self.saved_tab("00000000-0000-0000-0000-000000000082", 82, "enriched-session")
        added_to_first = self.saved_tab("00000000-0000-0000-0000-000000000083", 83, "new-tab-session")
        added_window = self.saved_tab("00000000-0000-0000-0000-000000000084", 84, "new-window-session")
        self.write_restore_state(
            [
                self.saved_window(first, added_to_first, selected=1),
                self.saved_window(enriched),
                self.saved_window(added_window),
            ],
            "10000000-0000-0000-0000-000000000082",
        )
        CORE.snapshot_state([state], backup, self.root)
        postquit = CORE.read_restore_state(backup / "state" / CORE.STATE_RELATIVES[0])

        CORE.compare_restore_states(prequit, postquit, backup)

    def test_postquit_allows_selection_and_focused_pane_changes(self):
        first = self.saved_tab("00000000-0000-0000-0000-000000000085", 85, "first")
        first["panes"].append(
            {
                "id": 86,
                "directory": "/repo",
                "scrollback": False,
                "ai_provider": None,
                "ai_session_id": None,
                "ai_session_id_source": None,
                "ai_resume_command": None,
                "archived_ai_resume": None,
                "agent_launch_command": None,
            }
        )
        first["focused_pane"] = 85
        first["created_at"] = 1000.0
        first["panes"][0]["last_input_at"] = 1000.1
        first["panes"][0]["last_output_at"] = 1000.2
        first["panes"][0]["last_status"] = "running"
        second = self.saved_tab("00000000-0000-0000-0000-000000000087", 87, "second")
        state, _, _ = self.write_restore_state(
            [self.saved_window(first, second, selected=0)],
            "10000000-0000-0000-0000-000000000085",
        )
        backup = self.new_run_backup()
        prequit = CORE.capture_prequit_restore(state, backup, self.root)

        post_first = json.loads(json.dumps(first))
        post_first["focused_pane"] = 86
        post_first["created_at"] = 1000.00001
        post_first["panes"][0]["last_input_at"] = 1001.0
        post_first["panes"][0]["last_output_at"] = 1002.0
        post_first["panes"][0]["last_status"] = "idle"
        post_second = json.loads(json.dumps(second))
        self.write_restore_state(
            [self.saved_window(post_first, post_second, selected=1)],
            "10000000-0000-0000-0000-000000000086",
        )
        CORE.snapshot_state([state], backup, self.root)
        postquit = CORE.read_restore_state(backup / "state" / CORE.STATE_RELATIVES[0])

        CORE.compare_restore_states(prequit, postquit, backup)

    def test_missing_canonical_restore_root_does_not_read_legacy_config_state(self):
        legacy = self.root / CORE.STATE_RELATIVES[1]
        legacy.mkdir(parents=True)
        tab = self.saved_tab("00000000-0000-0000-0000-000000000088", 88, "legacy-session")
        (legacy / CORE.RESTORE_INDEX_RELATIVE).write_text(
            json.dumps({"version": 1, "windows": [self.saved_window(tab)]}),
            encoding="utf-8",
        )
        backup = self.new_run_backup()

        prequit = CORE.capture_prequit_restore(self.root / CORE.STATE_RELATIVES[0], backup, self.root)

        self.assertEqual(prequit["mode"], "unused")
        self.assertFalse(prequit["identity"]["has_tabs"])
        self.assertFalse((prequit["prequit_root"] / CORE.RESTORE_INDEX_RELATIVE).exists())

    def test_apply_missing_canonical_state_fails_before_quit_prompt(self):
        legacy = self.root / CORE.STATE_RELATIVES[1]
        legacy.mkdir(parents=True)
        ask = mock.Mock()

        with (
            mock.patch.object(CORE, "require_terminal"),
            mock.patch.object(CORE, "ask_for_normal_quit", ask),
            self.assertRaisesRegex(CORE.UpdateError, "canonical RustV1 restore state root is missing"),
        ):
            CORE.apply_update(self.app, self.root / "receipt.json", REVISION, 30, {}, self.root.resolve())

        ask.assert_not_called()

    def test_missing_current_rechecks_fallback_bytes_after_unused_scan(self):
        state = self.root / CORE.STATE_RELATIVES[0]
        state.mkdir(parents=True)
        latest = state / CORE.RESTORE_LATEST_RELATIVE
        latest.parent.mkdir(parents=True)
        latest.write_text(json.dumps({"version": 1, "windows": []}), encoding="utf-8")
        original_empty_scan = CORE._empty_restore_state

        def change_fallback_after_scan(root, index_bytes, label):
            result = original_empty_scan(root, index_bytes, label)
            latest.write_text(
                json.dumps({"version": 1, "windows": [], "changed": True}),
                encoding="utf-8",
            )
            return result

        with (
            mock.patch.object(CORE, "_empty_restore_state", side_effect=change_fallback_after_scan),
            self.assertRaisesRegex(CORE.UpdateError, "fallback changed while being checked"),
        ):
            CORE.read_restore_state(state)

    def test_apply_update_happy_path_reaches_mocked_bundle_install(self):
        first = self.saved_tab("00000000-0000-0000-0000-000000000089", 89, "session-a")
        second = self.saved_tab("00000000-0000-0000-0000-000000000090", 90, "session-b")
        self.write_restore_state(
            [self.saved_window(first), self.saved_window(second)],
            "10000000-0000-0000-0000-000000000089",
        )

        installed = self.root / "installed" / "Chau7.app"
        installed.parent.mkdir(parents=True)
        shutil.copytree(self.app, installed)
        receipt_path = self.root / "receipt.json"
        receipt_path.write_text(json.dumps(self.receipt), encoding="utf-8")
        reached_install = []
        original_install = CORE.install_staged_bundle

        class FakeLock:
            def close(self):
                pass

        def copy_tree(source, destination, needs_sudo=False):
            self.assertFalse(Path(destination).exists())
            shutil.copytree(source, destination, symlinks=True, copy_function=shutil.copy2)

        def local_install(*args, **kwargs):
            reached_install.append(Path(args[0]))
            return original_install(*args, move=self.move_locally, **kwargs)

        def app_path(prefix, run_id):
            path = self.root / f"{prefix}-{run_id}.app"
            self.assertFalse(path.exists())
            return path

        with (
            mock.patch.object(CORE, "APP_DESTINATION", installed),
            mock.patch.object(CORE, "require_terminal"),
            mock.patch.object(CORE, "ask_for_normal_quit"),
            mock.patch.object(CORE, "acquire_instance_lock", return_value=FakeLock()),
            mock.patch.object(CORE, "active_application_pids", return_value=[]),
            mock.patch.object(CORE, "verify_code_signature"),
            mock.patch.object(CORE, "copy_with_ditto", side_effect=copy_tree),
            mock.patch.object(CORE, "unique_app_path", side_effect=app_path),
            mock.patch.object(CORE, "install_staged_bundle", side_effect=local_install),
        ):
            CORE.apply_update(self.app, receipt_path, REVISION, 30, {}, self.root.resolve())

        self.assertEqual(len(reached_install), 1)
        self.assertTrue((installed / "Contents/MacOS/Chau7").is_file())
        backup_parent = self.root / "Library/Application Support/Chau7 Production Update Backups"
        backups = list(backup_parent.iterdir())
        self.assertEqual(len(backups), 1)
        self.assertTrue((backups[0] / "pre-quit/restore-guard.json").is_file())
        self.assertTrue((backups[0] / "previous/Chau7.app").is_dir())
        self.assertTrue((backups[0] / CORE.UPDATE_COMPLETE_MARKER).is_file())
        marker, _ = CORE._read_update_marker(backups[0], CORE.UPDATE_COMPLETE_MARKER)
        CORE._validate_completed_update(backups[0], backups[0].name, marker)

    def test_apply_blocks_retry_after_historical_window_loss_without_quitting(self):
        first = self.saved_tab("00000000-0000-0000-0000-000000000101", 101, "first-session")
        second = self.saved_tab("00000000-0000-0000-0000-000000000102", 102, "second-session")
        incident = self.write_historical_run(
            "20261017-100001-123-01234567",
            [self.saved_window(first), self.saved_window(second)],
            [self.saved_window(second)],
        )
        state = self.root / CORE.STATE_RELATIVES[0]
        before = CORE.tree_manifest(state)
        ask = mock.Mock()

        with (
            mock.patch.object(CORE, "require_terminal"),
            mock.patch.object(CORE, "ask_for_normal_quit", ask),
            self.assertRaisesRegex(CORE.UpdateError, "earlier update has unresolved restore loss"),
        ):
            CORE.apply_update(self.app, self.root / "receipt.json", REVISION, 30, {}, self.root.resolve())

        ask.assert_not_called()
        self.assertEqual(CORE.tree_manifest(state), before)
        unresolved_path = incident / CORE.RESTORE_LOSS_MARKER
        marker, _ = CORE._read_update_marker(incident, CORE.RESTORE_LOSS_MARKER)
        self.assertEqual(marker["kind"], "postquit-restore-loss")
        self.assertTrue(unresolved_path.is_file())
        current_backup = next(path for path in (self.root / CORE.UPDATE_BACKUP_RELATIVE).iterdir() if path != incident)
        blocked, _ = CORE._read_update_marker(current_backup, CORE.RESTORE_GUARD_BLOCKED_MARKER)
        self.assertEqual(blocked["status"], "blocked-before-quit")

    def test_verified_recovery_resolves_incident_and_later_tab_closing_is_allowed(self):
        first = self.saved_tab("00000000-0000-0000-0000-000000000103", 103, "first-session")
        second = self.saved_tab("00000000-0000-0000-0000-000000000104", 104, "second-session")
        incident = self.write_historical_run(
            "20261017-100002-123-01234568",
            [self.saved_window(first), self.saved_window(second)],
            [self.saved_window(second)],
        )

        self.write_restore_state([self.saved_window(first), self.saved_window(second)], str(uuid.uuid4()))
        recovery_backup, recovered = self.capture_current_run("20261017-100003-123-01234569")
        CORE.require_prior_restore_losses_resolved(self.root, recovered, recovery_backup)
        state = self.root / CORE.STATE_RELATIVES[0]
        CORE.snapshot_state([state], recovery_backup, self.root)
        postquit = CORE.read_restore_state(recovery_backup / "state" / CORE.STATE_RELATIVES[0])
        CORE._write_update_complete_marker(
            recovery_backup,
            recovery_backup.name,
            recovered,
            postquit,
            {"buildNumber": BUILD, "sourceRevision": REVISION},
        )

        self.write_restore_state([self.saved_window(second)], str(uuid.uuid4()))
        later_backup, later = self.capture_current_run("20261017-100004-123-01234570")
        CORE.require_prior_restore_losses_resolved(self.root, later, later_backup)

        resolution, _ = CORE._read_update_marker(incident, CORE.RESTORE_LOSS_RESOLVED_MARKER)
        self.assertEqual(resolution["recovery_run_id"], recovery_backup.name)
        self.assertTrue((recovery_backup / CORE.UPDATE_COMPLETE_MARKER).is_file())
        self.assertEqual(later["identity"]["tab_count"], 1)

    def test_timeout_then_late_quit_loss_blocks_retry_as_ambiguous(self):
        first = self.saved_tab("00000000-0000-0000-0000-000000000113", 113, "first-session")
        second = self.saved_tab("00000000-0000-0000-0000-000000000114", 114, "second-session")
        full_windows = [self.saved_window(first), self.saved_window(second)]
        self.write_restore_state(full_windows, str(uuid.uuid4()))

        with (
            mock.patch.object(CORE, "require_terminal"),
            mock.patch.object(
                CORE,
                "ask_for_normal_quit",
                side_effect=CORE.UpdateError("normal quit wait timed out"),
            ),
            self.assertRaisesRegex(CORE.UpdateError, "Quit timing is ambiguous"),
        ):
            CORE.apply_update(self.app, self.root / "receipt.json", REVISION, 30, {}, self.root.resolve())

        backup_parent = self.root / CORE.UPDATE_BACKUP_RELATIVE
        timeout_backup = next(backup_parent.iterdir())
        marker, _ = CORE._read_update_marker(timeout_backup, CORE.RESTORE_LOSS_MARKER)
        self.assertEqual(marker["kind"], "ambiguous-postquit")

        # Model the app completing its save after the updater's wait already timed out.
        state = self.root / CORE.STATE_RELATIVES[0]
        self.write_restore_state([self.saved_window(second)], str(uuid.uuid4()))
        before_retry = CORE.tree_manifest(state)
        ask = mock.Mock()

        with (
            mock.patch.object(CORE, "require_terminal"),
            mock.patch.object(CORE, "ask_for_normal_quit", ask),
            self.assertRaisesRegex(CORE.UpdateError, "timed out.*restore loss is unverified"),
        ):
            CORE.apply_update(self.app, self.root / "receipt.json", REVISION, 30, {}, self.root.resolve())

        ask.assert_not_called()
        self.assertEqual(CORE.tree_manifest(state), before_retry)

    def test_legacy_previous_bundle_cannot_hide_contradictory_restore_snapshots(self):
        first = self.saved_tab("00000000-0000-0000-0000-000000000115", 115, "first-session")
        second = self.saved_tab("00000000-0000-0000-0000-000000000116", 116, "second-session")
        contradictory = self.write_historical_run(
            "20261017-100013-123-01234580",
            [self.saved_window(first), self.saved_window(second)],
            [self.saved_window(second)],
            previous=True,
        )

        with self.assertRaisesRegex(CORE.UpdateError, "legacy previous app backup conflicts"):
            CORE._legacy_previous_bundle(contradictory)

    def test_legacy_quit_not_observed_marker_is_migrated_to_ambiguous_incident(self):
        first = self.saved_tab("00000000-0000-0000-0000-000000000117", 117, "first-session")
        second = self.saved_tab("00000000-0000-0000-0000-000000000118", 118, "second-session")
        self.write_restore_state([self.saved_window(first), self.saved_window(second)], str(uuid.uuid4()))
        timeout_backup = self.new_historical_backup("20261017-100014-123-01234581")
        state = self.root / CORE.STATE_RELATIVES[0]
        prequit = CORE.capture_prequit_restore(state, timeout_backup, self.root)
        CORE._record_blocked_before_quit(timeout_backup, timeout_backup.name, prequit, status="quit-not-observed")

        self.write_restore_state([self.saved_window(second)], str(uuid.uuid4()))
        current_backup, current = self.capture_current_run("20261017-100015-123-01234582")
        with self.assertRaisesRegex(CORE.UpdateError, "timed out.*restore loss is unverified"):
            CORE.require_prior_restore_losses_resolved(self.root, current, current_backup)

        marker, _ = CORE._read_update_marker(timeout_backup, CORE.RESTORE_LOSS_MARKER)
        self.assertEqual(marker["kind"], "ambiguous-postquit")

    def test_validated_legacy_previous_bundle_allows_later_intentional_closing(self):
        first = self.saved_tab("00000000-0000-0000-0000-000000000105", 105, "first-session")
        second = self.saved_tab("00000000-0000-0000-0000-000000000106", 106, "second-session")
        completed = self.write_historical_run(
            "20261017-100005-123-01234571",
            [self.saved_window(first), self.saved_window(second)],
            [self.saved_window(first), self.saved_window(second)],
            previous=True,
        )
        self.write_restore_state([self.saved_window(second)], str(uuid.uuid4()))
        current_backup, current = self.capture_current_run("20261017-100006-123-01234572")

        CORE.require_prior_restore_losses_resolved(self.root, current, current_backup)

        self.assertFalse((completed / CORE.RESTORE_LOSS_MARKER).exists())

    def test_dry_run_history_check_reports_loss_without_writing_markers(self):
        first = self.saved_tab("00000000-0000-0000-0000-000000000107", 107, "first-session")
        second = self.saved_tab("00000000-0000-0000-0000-000000000108", 108, "second-session")
        incident = self.write_historical_run(
            "20261017-100007-123-01234573",
            [self.saved_window(first), self.saved_window(second)],
            [self.saved_window(second)],
        )
        state = self.root / CORE.STATE_RELATIVES[0]
        live = CORE.read_restore_state(state)
        live["snapshot_root"] = state
        before = CORE.tree_manifest(state)

        with self.assertRaisesRegex(CORE.UpdateError, "(?i)restore recovery is still required"):
            CORE.inspect_prior_restore_losses(self.root, live)

        self.assertFalse((incident / CORE.RESTORE_LOSS_MARKER).exists())
        self.assertEqual(CORE.tree_manifest(state), before)

    def test_missing_postquit_evidence_is_sticky_and_symlink_history_fails_closed(self):
        first = self.saved_tab("00000000-0000-0000-0000-000000000109", 109, "first-session")
        second = self.saved_tab("00000000-0000-0000-0000-000000000110", 110, "second-session")
        ambiguous = self.write_historical_run(
            "20261017-100008-123-01234574",
            [self.saved_window(first), self.saved_window(second)],
        )
        self.write_restore_state([self.saved_window(second)], str(uuid.uuid4()))
        current_backup, current = self.capture_current_run("20261017-100009-123-01234575")
        with self.assertRaisesRegex(CORE.UpdateError, "timed out.*restore loss is unverified"):
            CORE.require_prior_restore_losses_resolved(self.root, current, current_backup)
        marker, _ = CORE._read_update_marker(ambiguous, CORE.RESTORE_LOSS_MARKER)
        self.assertEqual(marker["kind"], "ambiguous-postquit")

    def test_postquit_rejects_lost_tab_working_directory(self):
        tab = self.saved_tab("00000000-0000-0000-0000-000000000119", 119, "cwd-session")
        state, _, _ = self.write_restore_state([self.saved_window(tab)], str(uuid.uuid4()))
        backup = self.new_run_backup()
        prequit = CORE.capture_prequit_restore(state, backup, self.root)

        post_tab = json.loads(json.dumps(tab))
        post_tab["cwd"] = None
        self.write_restore_state([self.saved_window(post_tab)], str(uuid.uuid4()))
        CORE.snapshot_state([state], backup, self.root)
        postquit = CORE.read_restore_state(backup / "state" / CORE.STATE_RELATIVES[0])

        with self.assertRaisesRegex(CORE.UpdateError, "tab working directory is missing"):
            CORE.compare_restore_states(prequit, postquit, backup)

    def test_postquit_rejects_lost_pane_working_directory(self):
        tab = self.saved_tab("00000000-0000-0000-0000-000000000120", 120, "cwd-session")
        state, _, _ = self.write_restore_state([self.saved_window(tab)], str(uuid.uuid4()))
        backup = self.new_run_backup()
        prequit = CORE.capture_prequit_restore(state, backup, self.root)

        post_tab = json.loads(json.dumps(tab))
        post_tab["panes"][0]["directory"] = None
        self.write_restore_state([self.saved_window(post_tab)], str(uuid.uuid4()))
        CORE.snapshot_state([state], backup, self.root)
        postquit = CORE.read_restore_state(backup / "state" / CORE.STATE_RELATIVES[0])

        with self.assertRaisesRegex(CORE.UpdateError, "pane working directory is missing"):
            CORE.compare_restore_states(prequit, postquit, backup)

    def test_postquit_allows_changed_nonempty_working_directories(self):
        tab = self.saved_tab("00000000-0000-0000-0000-000000000121", 121, "cwd-session")
        state, _, _ = self.write_restore_state([self.saved_window(tab)], str(uuid.uuid4()))
        backup = self.new_run_backup()
        prequit = CORE.capture_prequit_restore(state, backup, self.root)

        post_tab = json.loads(json.dumps(tab))
        post_tab["cwd"] = "/repo/subdirectory"
        post_tab["panes"][0]["directory"] = "/repo/subdirectory"
        self.write_restore_state([self.saved_window(post_tab)], str(uuid.uuid4()))
        CORE.snapshot_state([state], backup, self.root)
        postquit = CORE.read_restore_state(backup / "state" / CORE.STATE_RELATIVES[0])

        CORE.compare_restore_states(prequit, postquit, backup)

    def test_symlink_history_fails_closed(self):
        tab = self.saved_tab("00000000-0000-0000-0000-000000000111", 111, "session")
        malformed = self.new_historical_backup("20261017-100010-123-01234576")
        (malformed / "pre-quit").symlink_to(self.root, target_is_directory=True)
        self.write_restore_state([self.saved_window(tab)], str(uuid.uuid4()))
        current_backup, current = self.capture_current_run("20261017-100011-123-01234577")

        with self.assertRaisesRegex(CORE.UpdateError, "uses a symlink"):
            CORE.require_prior_restore_losses_resolved(self.root, current, current_backup)

    def test_historical_update_scan_is_bounded_and_rejects_unknown_entries(self):
        parent = self.root / CORE.UPDATE_BACKUP_RELATIVE
        parent.mkdir(parents=True)
        (parent / "unknown-run-name").mkdir()
        with self.assertRaisesRegex(CORE.UpdateError, "unrecognized or ambiguous"):
            CORE._update_backup_runs(self.root)

        (parent / "unknown-run-name").rmdir()
        for index in range(CORE.MAX_UPDATE_BACKUP_ENTRIES + 1):
            (parent / f"20261017-100012-123-{index:08x}").mkdir()
        with self.assertRaisesRegex(CORE.UpdateError, "verification bound"):
            CORE._update_backup_runs(self.root)

    def test_postquit_rejects_terminal_removed_from_layout_even_when_record_remains(self):
        tab = self.saved_tab("00000000-0000-0000-0000-000000000091", 91, "layout-session")
        extra = self.saved_tab("00000000-0000-0000-0000-000000000092", 92, "second-session")
        tab["panes"].append(extra["panes"][0])
        tab["layout"] = self.saved_split(91, 92)
        state, _, _ = self.write_restore_state([self.saved_window(tab)], "10000000-0000-0000-0000-000000000091")
        backup = self.new_run_backup()
        prequit = CORE.capture_prequit_restore(state, backup, self.root)

        post_tab = json.loads(json.dumps(tab))
        post_tab["layout"] = self.saved_split(91)
        self.write_restore_state([self.saved_window(post_tab)], "10000000-0000-0000-0000-000000000092")
        CORE.snapshot_state([state], backup, self.root)
        postquit = CORE.read_restore_state(backup / "state" / CORE.STATE_RELATIVES[0])

        self.assertEqual(set(prequit["identity"]["tabs"][tab["uuid"]]["panes"]), {91, 92})
        self.assertEqual(set(postquit["identity"]["tabs"][tab["uuid"]]["panes"]), {91, 92})
        with self.assertRaisesRegex(CORE.UpdateError, "terminal pane is missing from the restored layout"):
            CORE.compare_restore_states(prequit, postquit, backup)

    def test_postquit_rejects_removed_editor_from_layout(self):
        tab = self.saved_tab("00000000-0000-0000-0000-000000000097", 97, "editor-session")
        tab["layout"] = {
            "type": "split",
            "id": 197,
            "axis": "horizontal",
            "ratios": [0.5, 0.5],
            "children": [
                {"type": "terminal", "id": 97, "directory": "/repo"},
                {"type": "editor", "id": 98, "path": "/repo/notes.md"},
            ],
        }
        state, _, _ = self.write_restore_state([self.saved_window(tab)], "10000000-0000-0000-0000-000000000097")
        backup = self.new_run_backup()
        prequit = CORE.capture_prequit_restore(state, backup, self.root)

        post_tab = json.loads(json.dumps(tab))
        post_tab["layout"] = {"type": "terminal", "id": 97, "directory": "/repo"}
        self.write_restore_state([self.saved_window(post_tab)], "10000000-0000-0000-0000-000000000098")
        CORE.snapshot_state([state], backup, self.root)
        postquit = CORE.read_restore_state(backup / "state" / CORE.STATE_RELATIVES[0])

        with self.assertRaisesRegex(CORE.UpdateError, "layout pane is missing from the restored layout"):
            CORE.compare_restore_states(prequit, postquit, backup)

    def test_postquit_rejects_reordered_primary_pane_for_layoutless_tab(self):
        tab = self.saved_tab("00000000-0000-0000-0000-000000000093", 93, "primary-session")
        extra = self.saved_tab("00000000-0000-0000-0000-000000000094", 94, "other-session")
        tab["panes"].append(extra["panes"][0])
        state, _, _ = self.write_restore_state([self.saved_window(tab)], "10000000-0000-0000-0000-000000000093")
        backup = self.new_run_backup()
        prequit = CORE.capture_prequit_restore(state, backup, self.root)

        post_tab = json.loads(json.dumps(tab))
        post_tab["panes"].reverse()
        self.write_restore_state([self.saved_window(post_tab)], "10000000-0000-0000-0000-000000000094")
        CORE.snapshot_state([state], backup, self.root)
        postquit = CORE.read_restore_state(backup / "state" / CORE.STATE_RELATIVES[0])

        with self.assertRaisesRegex(CORE.UpdateError, "terminal pane is missing from the restored layout"):
            CORE.compare_restore_states(prequit, postquit, backup)

    def test_postquit_allows_added_split_while_retaining_old_terminal(self):
        tab = self.saved_tab("00000000-0000-0000-0000-000000000095", 95, "primary-session")
        state, _, _ = self.write_restore_state([self.saved_window(tab)], "10000000-0000-0000-0000-000000000095")
        backup = self.new_run_backup()
        prequit = CORE.capture_prequit_restore(state, backup, self.root)

        post_tab = json.loads(json.dumps(tab))
        extra = self.saved_tab("00000000-0000-0000-0000-000000000096", 96, "new-session")
        post_tab["panes"].append(extra["panes"][0])
        post_tab["layout"] = self.saved_split(95, 96)
        self.write_restore_state([self.saved_window(post_tab)], "10000000-0000-0000-0000-000000000096")
        CORE.snapshot_state([state], backup, self.root)
        postquit = CORE.read_restore_state(backup / "state" / CORE.STATE_RELATIVES[0])

        CORE.compare_restore_states(prequit, postquit, backup)

    def test_transactional_swap_success_retains_rollback(self):
        stage, destination, rollback, failed = self.transaction_folders()
        (stage / "build").write_text("new", encoding="utf-8")
        (destination / "build").write_text("old", encoding="utf-8")

        result = CORE.install_staged_bundle(
            stage,
            destination,
            rollback,
            failed,
            self.verify_new_bundle,
            self.verify_old_bundle,
            move=self.move_locally,
        )

        self.assertEqual(result, "new")
        self.assertEqual((destination / "build").read_text(encoding="utf-8"), "new")
        self.assertEqual((rollback / "build").read_text(encoding="utf-8"), "old")
        self.assertFalse(stage.exists())
        self.assertFalse(failed.exists())

    def test_move_fault_restores_previous_bundle(self):
        stage, destination, rollback, failed = self.transaction_folders()
        (stage / "build").write_text("new", encoding="utf-8")
        (destination / "build").write_text("old", encoding="utf-8")
        calls = []

        def fail_second_move(source, target):
            calls.append((source, target))
            if len(calls) == 2:
                raise OSError("synthetic stage move failure")
            source.rename(target)

        with self.assertRaisesRegex(CORE.UpdateError, "previous app was restored"):
            CORE.install_staged_bundle(
                stage,
                destination,
                rollback,
                failed,
                self.verify_new_bundle,
                self.verify_old_bundle,
                move=fail_second_move,
            )
        self.assertEqual((destination / "build").read_text(encoding="utf-8"), "old")
        self.assertTrue(stage.exists())
        self.assertFalse(rollback.exists())

    def test_interrupt_during_swap_restores_previous_bundle(self):
        stage, destination, rollback, failed = self.transaction_folders()
        (stage / "build").write_text("new", encoding="utf-8")
        (destination / "build").write_text("old", encoding="utf-8")
        calls = []

        def interrupt_second_move(source, target):
            calls.append((source, target))
            if len(calls) == 2:
                raise KeyboardInterrupt()
            source.rename(target)

        with self.assertRaisesRegex(CORE.UpdateError, "previous app was restored"):
            CORE.install_staged_bundle(
                stage,
                destination,
                rollback,
                failed,
                self.verify_new_bundle,
                self.verify_old_bundle,
                move=interrupt_second_move,
            )
        self.assertEqual((destination / "build").read_text(encoding="utf-8"), "old")
        self.assertTrue(stage.exists())
        self.assertFalse(rollback.exists())

    def test_interrupt_after_candidate_move_retains_candidate_and_restores_previous(self):
        stage, destination, rollback, failed = self.transaction_folders()
        (stage / "build").write_text("new", encoding="utf-8")
        (destination / "build").write_text("old", encoding="utf-8")
        calls = []

        def interrupt_after_second_move(source, target):
            calls.append((source, target))
            source.rename(target)
            if len(calls) == 2:
                raise KeyboardInterrupt()

        with self.assertRaisesRegex(CORE.UpdateError, "candidate retained"):
            CORE.install_staged_bundle(
                stage,
                destination,
                rollback,
                failed,
                self.verify_new_bundle,
                self.verify_old_bundle,
                move=interrupt_after_second_move,
            )
        self.assertEqual((destination / "build").read_text(encoding="utf-8"), "old")
        self.assertEqual((failed / "build").read_text(encoding="utf-8"), "new")
        self.assertFalse(rollback.exists())

    def test_interrupt_after_candidate_move_restores_previous_when_verify_rejects(self):
        stage, destination, rollback, failed = self.transaction_folders()
        (stage / "build").write_text("bad", encoding="utf-8")
        (destination / "build").write_text("old", encoding="utf-8")
        calls = []

        def interrupt_after_second_move(source, target):
            calls.append((source, target))
            source.rename(target)
            if len(calls) == 2:
                raise KeyboardInterrupt()

        def reject_new_bundle(bundle):
            raise CORE.UpdateError("synthetic interrupted candidate verification failure")

        with self.assertRaisesRegex(CORE.UpdateError, "candidate retained"):
            CORE.install_staged_bundle(
                stage,
                destination,
                rollback,
                failed,
                reject_new_bundle,
                self.verify_old_bundle,
                move=interrupt_after_second_move,
            )
        self.assertEqual((destination / "build").read_text(encoding="utf-8"), "old")
        self.assertEqual((failed / "build").read_text(encoding="utf-8"), "bad")
        self.assertFalse(rollback.exists())

    def test_verification_fault_retains_bad_bundle_and_restores_previous(self):
        stage, destination, rollback, failed = self.transaction_folders()
        (stage / "build").write_text("bad", encoding="utf-8")
        (destination / "build").write_text("old", encoding="utf-8")

        def reject_new_bundle(bundle):
            raise CORE.UpdateError("synthetic installed verification failure")

        with self.assertRaisesRegex(CORE.UpdateError, "previous app restored"):
            CORE.install_staged_bundle(
                stage,
                destination,
                rollback,
                failed,
                reject_new_bundle,
                self.verify_old_bundle,
                move=self.move_locally,
            )
        self.assertEqual((destination / "build").read_text(encoding="utf-8"), "old")
        self.assertEqual((failed / "build").read_text(encoding="utf-8"), "bad")
        self.assertFalse(rollback.exists())

    def test_interrupt_after_failed_bundle_move_still_restores_previous(self):
        stage, destination, rollback, failed = self.transaction_folders()
        (stage / "build").write_text("bad", encoding="utf-8")
        (destination / "build").write_text("old", encoding="utf-8")
        calls = []

        def interrupt_after_failed_move(source, target):
            calls.append((source, target))
            source.rename(target)
            if len(calls) == 3:
                raise KeyboardInterrupt()

        def reject_new_bundle(bundle):
            raise CORE.UpdateError("synthetic installed verification failure")

        with self.assertRaisesRegex(CORE.UpdateError, "previous app restored"):
            CORE.install_staged_bundle(
                stage,
                destination,
                rollback,
                failed,
                reject_new_bundle,
                self.verify_old_bundle,
                move=interrupt_after_failed_move,
            )
        self.assertEqual((destination / "build").read_text(encoding="utf-8"), "old")
        self.assertEqual((failed / "build").read_text(encoding="utf-8"), "bad")
        self.assertFalse(rollback.exists())

    def test_tree_snapshot_detects_profile_change_and_copy_is_equal(self):
        state = self.root / CORE.STATE_RELATIVES[0]
        state.mkdir(parents=True)
        (state / "profile.json").write_text('{"tabs":1}\n', encoding="utf-8")
        original = CORE.tree_manifest(state)
        backup = self.root / "backup" / CORE.STATE_RELATIVES[0]
        backup.parent.mkdir(parents=True)
        shutil.copytree(state, backup, copy_function=shutil.copy2)
        self.assertEqual(CORE.tree_manifest(backup), original)
        self.assertEqual(CORE.tree_manifest(state), original)
        (state / "profile.json").write_text('{"tabs":2}\n', encoding="utf-8")
        self.assertNotEqual(CORE.tree_manifest(state), original)


if __name__ == "__main__":
    unittest.main()
