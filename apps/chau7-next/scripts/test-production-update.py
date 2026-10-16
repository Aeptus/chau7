#!/usr/bin/env python3
"""Synthetic, non-installing tests for update-macos-production.command."""

import fcntl
import hashlib
import plistlib
import re
import shutil
import socket
import tempfile
import types
import unittest
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
        self.temporary = tempfile.TemporaryDirectory(prefix="chau7-production-update-")
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
