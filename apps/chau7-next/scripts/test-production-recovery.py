#!/usr/bin/env python3
"""Synthetic, non-installing tests for recover-macos-production.py."""

import copy
import hashlib
import io
import json
import runpy
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).with_name("recover-macos-production.py")
RECOVERY = runpy.run_path(str(SCRIPT))
RECOVERY_GLOBALS = RECOVERY["publish_restore_state"].__globals__
CORE = RECOVERY["CORE"]
merge_restore_states = RECOVERY["merge_restore_states"]
publish_restore_state = RECOVERY["publish_restore_state"]
RecoveryConflict = RECOVERY["RecoveryConflict"]


class ProductionRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="chau7-production-recovery-", dir="/private/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    @staticmethod
    def saved_pane(pane_id, *, directory="/repo", provider="claude", session_id="session-1", scrollback=False):
        resume_command = None
        if session_id:
            resume_command = f"codex resume {session_id}" if provider == "codex" else f"claude --resume {session_id}"
        return {
            "id": pane_id,
            "directory": directory,
            "scrollback": scrollback,
            "ai_provider": provider,
            "ai_session_id": session_id,
            "ai_session_id_source": "observed" if session_id else None,
            "ai_resume_command": resume_command,
            "archived_ai_resume": None,
            "agent_launch_command": None,
        }

    @classmethod
    def saved_tab(cls, tab_uuid, pane_id, *, pane=None, cwd="/repo", title=None, layout=None, archived_context=None):
        return {
            "uuid": str(uuid.UUID(tab_uuid)),
            "cwd": cwd,
            "custom_title": title,
            "color": "blue",
            "repo_group_id": None,
            "created_at": 10.0,
            "manual_color": False,
            "focused_pane": pane_id,
            "layout": layout,
            "archived_context": archived_context,
            "panes": [pane or cls.saved_pane(pane_id)],
        }

    @staticmethod
    def saved_window(*tabs, selected=0, x=100.0, y=100.0, width=900.0, height=700.0):
        return {
            "tabs": list(tabs),
            "selected": selected,
            "x": x,
            "y": y,
            "width": width,
            "height": height,
        }

    def write_restore_state(
        self,
        windows,
        *,
        contexts=None,
        token=None,
        root=None,
        schema_version=1,
        previous_index_token=None,
        validate=True,
    ):
        root = root or self.root / f"state-{uuid.uuid4()}"
        root.mkdir(parents=True, exist_ok=True)
        contexts = contexts or {}
        references = {}
        context_directory = root / CORE.RESTORE_CONTEXTS_RELATIVE
        for pane_id, payload in contexts.items():
            context_directory.mkdir(parents=True, exist_ok=True)
            digest = hashlib.sha256(payload).hexdigest()
            (context_directory / f"{digest}.txt").write_bytes(payload)
            references[str(pane_id)] = {"sha256": digest, "byte_count": len(payload)}

        token = token or str(uuid.uuid4())
        session = {"version": 1, "windows": windows}
        bundle = {
            "schema_version": schema_version,
            "save_token": token,
            "previous_index_token": previous_index_token,
            "explicit_clear": False,
            "session": session,
            "contexts": references,
        }
        index = {"save_token": token, "explicit_clear": False, **session}
        current_path = root / CORE.RESTORE_CURRENT_RELATIVE
        current_path.parent.mkdir(parents=True, exist_ok=True)
        current_path.write_text(json.dumps(bundle), encoding="utf-8")
        (root / CORE.RESTORE_INDEX_RELATIVE).write_text(json.dumps(index), encoding="utf-8")
        return root, CORE.read_restore_state(root) if validate else None

    def snapshot(self, windows, **kwargs):
        return self.write_restore_state(windows, **kwargs)[1]

    def test_preserves_current_window_and_appends_missing_old_window(self):
        shared_id = "10000000-0000-0000-0000-000000000001"
        missing_id = "10000000-0000-0000-0000-000000000002"
        latest = self.snapshot(
            [
                self.saved_window(self.saved_tab(shared_id, 1), x=40.0, selected=0),
            ]
        )
        older = self.snapshot(
            [
                self.saved_window(self.saved_tab(shared_id, 1), x=40.0, selected=0),
                self.saved_window(self.saved_tab(missing_id, 2), x=1200.0, y=90.0),
            ]
        )

        merged = merge_restore_states([latest, older])

        self.assertEqual(len(merged["session"]["windows"]), 2)
        self.assertEqual(merged["session"]["windows"][0]["x"], 40.0)
        self.assertEqual(merged["session"]["windows"][1]["tabs"][0]["uuid"], missing_id)
        self.assertEqual(merged["session"]["windows"][1]["x"], 1200.0)

    def test_overlapping_tab_uuid_merges_without_duplicates(self):
        tab_id = "10000000-0000-0000-0000-000000000003"
        latest_tab = self.saved_tab(tab_id, 3, cwd=None, title=None)
        older_tab = self.saved_tab(
            tab_id,
            3,
            cwd="/work/project",
            title=None,
            layout={"type": "terminal", "id": 3, "directory": "/work/project"},
        )
        latest = self.snapshot([self.saved_window(latest_tab)])
        older = self.snapshot([self.saved_window(older_tab)])

        merged = merge_restore_states([latest, older])

        tabs = merged["session"]["windows"][0]["tabs"]
        self.assertEqual([tab["uuid"] for tab in tabs], [tab_id])
        self.assertEqual(tabs[0]["cwd"], "/work/project")
        self.assertEqual(tabs[0]["layout"]["directory"], "/work/project")

    def test_preserves_latest_context_and_editor_content(self):
        tab_id = "10000000-0000-0000-0000-000000000004"
        latest_payload = b"latest terminal context"
        old_payload = b"stale terminal context"
        editor_path = self.root / "latest-editor.md"
        editor_payload = b"synthetic latest editor bytes"
        editor_path.write_bytes(editor_payload)
        latest_tab = self.saved_tab(
            tab_id,
            4,
            pane=self.saved_pane(4, scrollback=True),
            layout={"type": "editor", "id": 99, "path": str(editor_path)},
            archived_context={
                "command_blocks": [{"command": "latest command"}],
                "preview_snapshot_png_data": "bGF0ZXN0IGVkaXRvciBjb250ZW50",
            },
        )
        older_tab = self.saved_tab(
            tab_id,
            4,
            pane=self.saved_pane(4, scrollback=True),
            layout={"type": "editor", "id": 99, "path": str(editor_path)},
            archived_context=None,
        )
        latest = self.snapshot([self.saved_window(latest_tab)], contexts={4: latest_payload})
        older = self.snapshot([self.saved_window(older_tab)], contexts={4: old_payload})

        merged = merge_restore_states([latest, older])

        pane = merged["session"]["windows"][0]["tabs"][0]["panes"][0]
        context_digest = hashlib.sha256(latest_payload).hexdigest()
        self.assertEqual(merged["context_bytes"][context_digest], latest_payload)
        self.assertEqual(pane["scrollback"], True)
        tab = merged["session"]["windows"][0]["tabs"][0]
        self.assertEqual(tab["layout"]["path"], str(editor_path))
        self.assertEqual(
            tab["archived_context"]["preview_snapshot_png_data"],
            "bGF0ZXN0IGVkaXRvciBjb250ZW50",
        )
        backup = self.root / "synthetic-recovery-backup"
        backup.mkdir()
        records = RECOVERY["verify_and_snapshot_editor_files"]([latest, older], backup, "prequit")
        self.assertEqual(len(records), 1)
        editor_snapshot = backup / "editor-files" / Path(records[0]["backup"]).name
        self.assertEqual(editor_snapshot.read_bytes(), editor_payload)
        self.assertEqual(editor_path.read_bytes(), editor_payload)

    def test_fills_missing_critical_fields_from_older_snapshot(self):
        tab_id = "10000000-0000-0000-0000-000000000005"
        latest = self.snapshot(
            [
                self.saved_window(
                    self.saved_tab(
                        tab_id,
                        5,
                        cwd=None,
                        pane=self.saved_pane(5, directory=None, provider=None, session_id=None),
                    )
                ),
            ]
        )
        older = self.snapshot(
            [
                self.saved_window(
                    self.saved_tab(
                        tab_id,
                        5,
                        cwd="/work/project",
                        pane=self.saved_pane(5, directory="/work/project", provider="codex", session_id="thread-5"),
                        archived_context={
                            "command_blocks": [{"command": "recovered command"}],
                            "preview_snapshot_png_data": "cmVjb3ZlcmVkIHByZXZpZXc=",
                        },
                    )
                ),
            ]
        )

        merged = merge_restore_states([latest, older])

        tab = merged["session"]["windows"][0]["tabs"][0]
        pane = tab["panes"][0]
        self.assertEqual(tab["cwd"], "/work/project")
        self.assertEqual(pane["directory"], "/work/project")
        self.assertEqual(pane["ai_provider"], "codex")
        self.assertEqual(pane["ai_session_id"], "thread-5")
        self.assertEqual(pane["ai_resume_command"], "codex resume thread-5")
        self.assertEqual(
            tab["archived_context"]["command_blocks"],
            [{"command": "recovered command"}],
        )

    def test_rejects_conflicting_nonempty_provider(self):
        tab_id = "10000000-0000-0000-0000-000000000006"
        latest = self.snapshot(
            [
                self.saved_window(
                    self.saved_tab(tab_id, 6, pane=self.saved_pane(6, provider="claude", session_id="same"))
                ),
            ]
        )
        older = self.snapshot(
            [
                self.saved_window(
                    self.saved_tab(tab_id, 6, pane=self.saved_pane(6, provider="codex", session_id="same"))
                ),
            ]
        )

        with self.assertRaises(RecoveryConflict):
            merge_restore_states([latest, older])

    def test_preserves_distinct_tabs_using_the_same_provider_and_session(self):
        current_id = "10000000-0000-0000-0000-000000000016"
        intermediate_id = "10000000-0000-0000-0000-000000000029"
        recovered_id = "10000000-0000-0000-0000-000000000017"
        current_tab = self.saved_tab(
            current_id,
            16,
            pane=self.saved_pane(16, provider="claude", session_id="shared-session"),
        )
        intermediate_tab = self.saved_tab(
            intermediate_id,
            18,
            pane=self.saved_pane(18, provider="codex", session_id="other-session"),
        )
        latest = self.snapshot(
            [
                self.saved_window(current_tab),
            ]
        )
        intermediate = self.snapshot(
            [
                self.saved_window(current_tab, intermediate_tab),
            ]
        )
        old = self.snapshot(
            [
                self.saved_window(
                    current_tab,
                    intermediate_tab,
                    self.saved_tab(
                        recovered_id,
                        17,
                        pane=self.saved_pane(17, provider="claude", session_id="shared-session"),
                    ),
                ),
            ]
        )

        merged = merge_restore_states([latest, intermediate, old])

        tabs = merged["session"]["windows"][0]["tabs"]
        self.assertEqual([tab["uuid"] for tab in tabs], [current_id, intermediate_id, recovered_id])
        self.assertEqual(
            [tab["panes"][0]["ai_session_id"] for tab in tabs],
            ["shared-session", "other-session", "shared-session"],
        )
        self.assertEqual(merged["summary"]["duplicate_provider_pairs"], 1)

    def test_rejects_old_window_spanning_two_current_windows(self):
        first = "10000000-0000-0000-0000-000000000007"
        second = "10000000-0000-0000-0000-000000000008"
        third = "10000000-0000-0000-0000-000000000009"
        latest = self.snapshot(
            [
                self.saved_window(self.saved_tab(first, 7)),
                self.saved_window(self.saved_tab(second, 8)),
            ]
        )
        older = self.snapshot(
            [
                self.saved_window(self.saved_tab(first, 7), self.saved_tab(second, 8), self.saved_tab(third, 9)),
            ]
        )

        with self.assertRaises(RecoveryConflict):
            merge_restore_states([latest, older])

    def test_rejects_pane_id_collision_between_distinct_tabs(self):
        first = "10000000-0000-0000-0000-000000000010"
        second = "10000000-0000-0000-0000-000000000011"
        latest = self.snapshot([self.saved_window(self.saved_tab(first, 10))])
        older = self.snapshot([self.saved_window(self.saved_tab(second, 10))])

        with self.assertRaises(RecoveryConflict):
            merge_restore_states([latest, older])

    def test_rejects_malformed_schema(self):
        tab_id = "10000000-0000-0000-0000-000000000012"
        root, _ = self.write_restore_state(
            [self.saved_window(self.saved_tab(tab_id, 12))],
            schema_version=99,
            validate=False,
        )

        with self.assertRaises(CORE.UpdateError):
            CORE.read_restore_state(root)

    def test_rejects_malformed_context_reference_and_hash_path(self):
        tab_id = "10000000-0000-0000-0000-000000000013"
        root, _ = self.write_restore_state(
            [self.saved_window(self.saved_tab(tab_id, 13, pane=self.saved_pane(13, scrollback=True)))],
            contexts={13: b"synthetic transcript"},
        )
        bundle_path = root / CORE.RESTORE_CURRENT_RELATIVE
        bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
        bundle["contexts"]["13"]["sha256"] = "../outside"
        bundle_path.write_text(json.dumps(bundle), encoding="utf-8")

        with self.assertRaises(CORE.UpdateError):
            CORE.read_restore_state(root)

    def test_rejects_missing_context_reference_for_saved_scrollback(self):
        tab_id = "10000000-0000-0000-0000-000000000027"
        root, _ = self.write_restore_state(
            [self.saved_window(self.saved_tab(tab_id, 27, pane=self.saved_pane(27, scrollback=True)))],
            validate=False,
        )

        with self.assertRaisesRegex(CORE.UpdateError, "missing the context"):
            CORE.read_restore_state(root)

    def test_rejects_context_reference_with_wrong_byte_count(self):
        tab_id = "10000000-0000-0000-0000-000000000028"
        root, _ = self.write_restore_state(
            [self.saved_window(self.saved_tab(tab_id, 28, pane=self.saved_pane(28, scrollback=True)))],
            contexts={28: b"synthetic context"},
        )
        bundle_path = root / CORE.RESTORE_CURRENT_RELATIVE
        bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
        bundle["contexts"]["28"]["byte_count"] += 1
        bundle_path.write_text(json.dumps(bundle), encoding="utf-8")

        with self.assertRaisesRegex(CORE.UpdateError, "hash or byte count"):
            CORE.read_restore_state(root)

    def test_rejects_context_content_with_wrong_hash(self):
        tab_id = "10000000-0000-0000-0000-000000000014"
        root, _ = self.write_restore_state(
            [self.saved_window(self.saved_tab(tab_id, 14, pane=self.saved_pane(14, scrollback=True)))],
            contexts={14: b"synthetic context"},
        )
        digest = hashlib.sha256(b"synthetic context").hexdigest()
        (root / CORE.RESTORE_CONTEXTS_RELATIVE / f"{digest}.txt").write_bytes(b"tampered")

        with self.assertRaises(CORE.UpdateError):
            CORE.read_restore_state(root)

    def test_rejects_symlinked_restore_file(self):
        tab_id = "10000000-0000-0000-0000-000000000015"
        root, _ = self.write_restore_state([self.saved_window(self.saved_tab(tab_id, 15))])
        current = root / CORE.RESTORE_CURRENT_RELATIVE
        target = self.root / "valid-current.json"
        target.write_bytes(current.read_bytes())
        current.unlink()
        current.symlink_to(target)

        with self.assertRaises(CORE.UpdateError):
            CORE.read_restore_state(root)

    def test_repeated_merge_is_idempotent(self):
        current_id = "10000000-0000-0000-0000-000000000018"
        recovered_id = "10000000-0000-0000-0000-000000000019"
        latest = self.snapshot(
            [
                self.saved_window(self.saved_tab(current_id, 18)),
            ]
        )
        older = self.snapshot(
            [
                self.saved_window(self.saved_tab(current_id, 18)),
                self.saved_window(self.saved_tab(recovered_id, 19)),
            ]
        )

        first = merge_restore_states([latest, older])
        second = merge_restore_states([latest, older])

        self.assertEqual(first["session"], second["session"])
        self.assertEqual(first["summary"], second["summary"])

    def test_interrupted_bundle_index_publication_remains_readable(self):
        home, current_root, source_root = self._recovery_paths()
        current = CORE.read_restore_state(current_root)
        source = CORE.read_restore_state(source_root)
        merged = merge_restore_states([current, source])
        index_path = current_root / CORE.RESTORE_INDEX_RELATIVE
        original_replace = RECOVERY["os"].replace

        def interrupt_index(source_path, destination_path):
            if Path(destination_path) == index_path:
                raise OSError("synthetic crash before restore-index rename")
            return original_replace(source_path, destination_path)

        with (
            mock.patch.object(RECOVERY["os"], "replace", side_effect=interrupt_index),
            self.assertRaisesRegex(CORE.UpdateError, "cannot atomically publish restore index"),
        ):
            publish_restore_state(current_root, merged, current)

        readable = CORE.read_restore_state(current_root)
        self.assertEqual(readable["identity"]["tab_count"], 2)
        self.assertEqual(
            set(readable["identity"]["tabs"]),
            {"10000000-0000-0000-0000-000000000020", "10000000-0000-0000-0000-000000000021"},
        )
        self.assertFalse(any(path.name.endswith(".tmp") for path in current_root.rglob("*")))

    def test_publication_fsyncs_manifests_before_rename_and_parent_after(self):
        _, current_root, source_root = self._recovery_paths()
        current = CORE.read_restore_state(current_root)
        source = CORE.read_restore_state(source_root)
        merged = merge_restore_states([current, source])
        events = []
        original_write = RECOVERY["_write_exclusive"]
        original_replace = RECOVERY["os"].replace
        original_directory_sync = CORE._fsync_directory

        def tracked_write(path, payload, label):
            result = original_write(path, payload, label)
            events.append(("file-sync", label))
            return result

        def tracked_replace(source_path, destination_path):
            result = original_replace(source_path, destination_path)
            events.append(("rename", Path(destination_path).name))
            return result

        def tracked_directory_sync(directory, label):
            result = original_directory_sync(directory, label)
            events.append(("directory-sync", label))
            return result

        with (
            mock.patch.dict(RECOVERY_GLOBALS, {"_write_exclusive": tracked_write}),
            mock.patch.object(RECOVERY["os"], "replace", side_effect=tracked_replace),
            mock.patch.object(CORE, "_fsync_directory", side_effect=tracked_directory_sync),
        ):
            publish_restore_state(current_root, merged, current)

        for label, filename in (
            ("current restore bundle", CORE.RESTORE_CURRENT_RELATIVE.name),
            ("restore index", CORE.RESTORE_INDEX_RELATIVE.name),
        ):
            file_sync = next(
                index for index, event in enumerate(events) if event[0] == "file-sync" and event[1].endswith(label)
            )
            rename = events.index(("rename", filename))
            directory_sync = events.index(("directory-sync", f"{label} parent"))
            self.assertLess(file_sync, rename)
            self.assertLess(rename, directory_sync)

    def test_invalid_merged_candidate_cannot_replace_manifests(self):
        _, current_root, source_root = self._recovery_paths()
        current = CORE.read_restore_state(current_root)
        source = CORE.read_restore_state(source_root)
        merged = merge_restore_states([current, source])
        invalid = copy.deepcopy(merged)
        invalid["session"]["windows"][0]["tabs"][0]["color"] = "purple"
        invalid["bundle"]["session"] = invalid["session"]
        invalid["index"]["windows"] = invalid["session"]["windows"]
        invalid["bundle_bytes"] = RECOVERY["_json_bytes"](invalid["bundle"])
        invalid["index_bytes"] = RECOVERY["_json_bytes"](invalid["index"])
        before_current = self._tree_state(current_root)

        with self.assertRaises(CORE.UpdateError):
            publish_restore_state(current_root, invalid, current)

        self.assertEqual(self._tree_state(current_root), before_current)

    def test_publish_rejects_valid_plan_based_on_stale_same_identity_before_writes(self):
        home = self.root / "synthetic-home"
        home.mkdir()
        current_root = home / CORE.STATE_RELATIVES[0]
        source_root = self.root / "preserved-source"
        current_id = "10000000-0000-0000-0000-000000000030"
        source_id = "10000000-0000-0000-0000-000000000031"
        current_payload = b"synthetic current scrollback"
        source_payload = b"synthetic source scrollback"
        current_windows = [
            self.saved_window(
                self.saved_tab(
                    current_id,
                    30,
                    pane=self.saved_pane(30, scrollback=True),
                )
            )
        ]
        self.write_restore_state(current_windows, contexts={30: current_payload}, root=current_root)
        self.write_restore_state(
            [
                self.saved_window(
                    self.saved_tab(
                        source_id,
                        31,
                        pane=self.saved_pane(31, scrollback=True),
                    )
                )
            ],
            contexts={31: source_payload},
            root=source_root,
        )
        old_current = CORE.read_restore_state(current_root)
        source = CORE.read_restore_state(source_root)
        plan = merge_restore_states([old_current, source])
        old_ids = set(old_current["identity"]["tabs"])
        old_token = old_current["save_token"]

        self.write_restore_state(
            current_windows,
            contexts={30: current_payload},
            token=str(uuid.UUID(int=99)),
            root=current_root,
        )
        expected_live = CORE.read_restore_state(current_root)
        before_current = self._tree_state(current_root)
        source_digest = hashlib.sha256(source_payload).hexdigest()
        source_context = current_root / CORE.RESTORE_CONTEXTS_RELATIVE / f"{source_digest}.txt"

        self.assertNotEqual(old_token, expected_live["save_token"])
        self.assertEqual(set(expected_live["identity"]["tabs"]), old_ids)
        self.assertFalse(source_context.exists())
        with self.assertRaisesRegex(CORE.UpdateError, "not based on the expected live snapshot"):
            publish_restore_state(current_root, plan, expected_live)

        self.assertEqual(self._tree_state(current_root), before_current)
        self.assertFalse(source_context.exists())

    @staticmethod
    def _tree_state(root):
        return {
            path.relative_to(root).as_posix(): (
                "directory" if path.is_dir() else "file",
                path.read_bytes() if path.is_file() else None,
            )
            for path in sorted(root.rglob("*"))
        }

    def _recovery_paths(self):
        home = self.root / "synthetic-home"
        home.mkdir()
        current_root = home / CORE.STATE_RELATIVES[0]
        source_root = self.root / "preserved-source"
        current_id = "10000000-0000-0000-0000-000000000020"
        source_id = "10000000-0000-0000-0000-000000000021"
        self.write_restore_state([self.saved_window(self.saved_tab(current_id, 20))], root=current_root)
        self.write_restore_state([self.saved_window(self.saved_tab(source_id, 21))], root=source_root)
        return home, current_root, source_root

    def test_dry_run_reads_synthetic_states_without_writing_or_requesting_quit(self):
        home, current_root, source_root = self._recovery_paths()
        before_current = self._tree_state(current_root)
        before_source = self._tree_state(source_root)
        output = io.StringIO()

        with (
            mock.patch.object(CORE, "ask_for_normal_quit", side_effect=AssertionError),
            mock.patch("sys.stdout", output),
        ):
            RECOVERY["dry_run"](source_root, home)

        self.assertEqual(self._tree_state(current_root), before_current)
        self.assertEqual(self._tree_state(source_root), before_source)

    def test_dry_run_summary_does_not_print_transcript_contents(self):
        home = self.root / "synthetic-home"
        home.mkdir()
        current_root = home / CORE.STATE_RELATIVES[0]
        source_root = self.root / "preserved-source"
        current_id = "10000000-0000-0000-0000-000000000022"
        source_id = "10000000-0000-0000-0000-000000000023"
        secret_marker = b"SYNTHETIC-TRANSCRIPT-MUST-NOT-BE-PRINTED"
        self.write_restore_state([self.saved_window(self.saved_tab(current_id, 22))], root=current_root)
        self.write_restore_state(
            [self.saved_window(self.saved_tab(source_id, 23, pane=self.saved_pane(23, scrollback=True)))],
            contexts={23: secret_marker},
            root=source_root,
        )
        output = io.StringIO()

        with mock.patch("sys.stdout", output):
            RECOVERY["dry_run"](source_root, home)

        self.assertNotIn(secret_marker.decode("ascii"), output.getvalue())
        self.assertIn("union: tabs=2", output.getvalue())

    def test_preflight_accepts_empty_metadata_fills_and_ordered_appends(self):
        home = self.root / "synthetic-home"
        home.mkdir()
        current_root = home / CORE.STATE_RELATIVES[0]
        source_root = self.root / "preserved-source"
        current_id = "10000000-0000-0000-0000-000000000024"
        recovered_id = "10000000-0000-0000-0000-000000000025"
        current_tab = self.saved_tab(
            current_id,
            24,
            cwd=None,
            pane=self.saved_pane(24, directory=None, provider=None, session_id=None),
        )
        current_window = self.saved_window(current_tab, x=40.0)
        self.write_restore_state([current_window], root=current_root)

        recovered_shared_tab = self.saved_tab(
            current_id,
            24,
            cwd="/recovered/project",
            pane=self.saved_pane(24, directory="/recovered/project", provider="codex", session_id="thread-24"),
            layout={
                "type": "split",
                "id": 200,
                "axis": "horizontal",
                "ratios": [0.5, 0.5],
                "children": [
                    {"type": "terminal", "id": 24, "directory": "/recovered/project"},
                    {"type": "terminal", "id": 26, "directory": "/recovered/project"},
                ],
            },
        )
        recovered_shared_tab["panes"].append(
            self.saved_pane(26, directory="/recovered/project", provider=None, session_id=None)
        )
        recovered_only_tab = self.saved_tab(recovered_id, 25)
        source_window = self.saved_window(recovered_shared_tab, recovered_only_tab, x=40.0)
        self.write_restore_state([source_window], root=source_root)
        current = CORE.read_restore_state(current_root)
        source = CORE.read_restore_state(source_root)
        before_current = self._tree_state(current_root)
        merged = merge_restore_states([current, source])

        self.assertEqual(merged["session"]["windows"][0]["x"], 40.0)
        tabs = merged["session"]["windows"][0]["tabs"]
        self.assertEqual([tab["uuid"] for tab in tabs], [current_id, recovered_id])
        self.assertEqual([pane["id"] for pane in tabs[0]["panes"]], [24, 26])
        self.assertEqual(tabs[0]["cwd"], "/recovered/project")
        self.assertEqual(self._tree_state(current_root), before_current)
        published = publish_restore_state(current_root, merged, current)
        RECOVERY["_verify_full_preservation"](published, [current, source], merged)

    def test_dry_run_rejects_identity_conflict_without_writing_manifests(self):
        home = self.root / "synthetic-home"
        home.mkdir()
        current_root = home / CORE.STATE_RELATIVES[0]
        source_root = self.root / "preserved-source"
        tab_id = "10000000-0000-0000-0000-000000000026"
        self.write_restore_state(
            [
                self.saved_window(
                    self.saved_tab(tab_id, 26, pane=self.saved_pane(26, provider="claude", session_id="same"))
                )
            ],
            root=current_root,
        )
        self.write_restore_state(
            [
                self.saved_window(
                    self.saved_tab(tab_id, 26, pane=self.saved_pane(26, provider="codex", session_id="same"))
                )
            ],
            root=source_root,
        )
        before_current = self._tree_state(current_root)
        before_source = self._tree_state(source_root)

        with self.assertRaises(RecoveryConflict):
            RECOVERY["dry_run"](source_root, home)

        self.assertEqual(self._tree_state(current_root), before_current)
        self.assertEqual(self._tree_state(source_root), before_source)

    def test_apply_does_not_write_live_state_before_quit_lock(self):
        home, current_root, source_root = self._recovery_paths()
        before_current = self._tree_state(current_root)
        output = _TTYBuffer()

        def observe_quit_request(*_args):
            self.assertEqual(self._tree_state(current_root), before_current)

        with (
            mock.patch.object(CORE, "require_terminal"),
            mock.patch.object(CORE, "ask_for_normal_quit", side_effect=observe_quit_request),
            mock.patch.object(
                CORE, "acquire_instance_lock", side_effect=CORE.UpdateError("synthetic lock unavailable")
            ),
            mock.patch.object(RECOVERY["sys"], "stdout", output),
            self.assertRaisesRegex(CORE.UpdateError, "synthetic lock unavailable"),
        ):
            RECOVERY["apply_recovery"](source_root, home, 1)

        self.assertEqual(self._tree_state(current_root), before_current)

    def test_live_app_blocks_publication_and_markers_remain_untouched(self):
        home, current_root, source_root = self._recovery_paths()
        before_current = self._tree_state(current_root)
        marker_directory = home / CORE.UPDATE_BACKUP_RELATIVE / "synthetic-update"
        marker_directory.mkdir(parents=True)
        marker_contents = {
            CORE.UPDATE_COMPLETE_MARKER: b"synthetic complete marker",
            CORE.RESTORE_LOSS_MARKER: b"synthetic unresolved marker",
            CORE.RESTORE_LOSS_RESOLVED_MARKER: b"synthetic resolved marker",
        }
        for name, payload in marker_contents.items():
            (marker_directory / name).write_bytes(payload)
        output = _TTYBuffer()
        lock_file = mock.MagicMock()
        publish = mock.Mock()

        with (
            mock.patch.object(CORE, "require_terminal"),
            mock.patch.object(CORE, "ask_for_normal_quit"),
            mock.patch.object(CORE, "acquire_instance_lock", return_value=lock_file),
            mock.patch.object(CORE, "active_application_pids", return_value=[4321]),
            mock.patch.object(RECOVERY["sys"], "stdout", output),
            mock.patch.dict(RECOVERY_GLOBALS, {"publish_restore_state": publish}),
            self.assertRaisesRegex(CORE.UpdateError, "reopened after normal quit"),
        ):
            RECOVERY["apply_recovery"](source_root, home, 1)

        publish.assert_not_called()
        lock_file.close.assert_called_once()
        self.assertEqual(self._tree_state(current_root), before_current)
        for name, payload in marker_contents.items():
            self.assertEqual((marker_directory / name).read_bytes(), payload)

    def test_successful_recovery_leaves_updater_markers_untouched(self):
        home, current_root, source_root = self._recovery_paths()
        marker_directory = home / CORE.UPDATE_BACKUP_RELATIVE / "synthetic-update"
        marker_directory.mkdir(parents=True)
        marker_contents = {
            CORE.UPDATE_COMPLETE_MARKER: b"synthetic complete marker",
            CORE.RESTORE_LOSS_MARKER: b"synthetic unresolved marker",
            CORE.RESTORE_LOSS_RESOLVED_MARKER: b"synthetic resolved marker",
        }
        for name, payload in marker_contents.items():
            (marker_directory / name).write_bytes(payload)
        output = _TTYBuffer()
        lock_file = mock.MagicMock()

        with (
            mock.patch.object(CORE, "require_terminal"),
            mock.patch.object(CORE, "ask_for_normal_quit"),
            mock.patch.object(CORE, "acquire_instance_lock", return_value=lock_file),
            mock.patch.object(CORE, "active_application_pids", return_value=[]),
            mock.patch.object(RECOVERY["sys"], "stdout", output),
        ):
            RECOVERY["apply_recovery"](source_root, home, 1)

        lock_file.close.assert_called_once()
        self.assertEqual(CORE.read_restore_state(current_root)["identity"]["tab_count"], 2)
        for name, payload in marker_contents.items():
            self.assertEqual((marker_directory / name).read_bytes(), payload)


class _TTYBuffer(io.StringIO):
    def isatty(self):
        return True


if __name__ == "__main__":
    unittest.main()
