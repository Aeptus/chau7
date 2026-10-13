import importlib.machinery
import importlib.util
import pathlib
import unittest
from unittest import mock

SCRIPT_PATH = pathlib.Path(__file__).resolve().parents[1] / "pre-commit-review"


def load_script_module():
    loader = importlib.machinery.SourceFileLoader("pre_commit_review", str(SCRIPT_PATH))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


hook = load_script_module()


class PreCommitReviewExtractionTests(unittest.TestCase):
    def test_extract_review_json_prefers_sentinel_block(self):
        transcript = """
No issues found.
__CHAU7_REVIEW_JSON_BEGIN__
{"summary":"ok","findings":[],"recommendations":["none"],"confidence":"high"}
__CHAU7_REVIEW_JSON_END__
› prompt
""".strip()

        payload = hook.extract_review_json(transcript)

        self.assertEqual(payload["summary"], "ok")
        self.assertEqual(payload["confidence"], "high")

    def test_extract_review_json_from_markers_requires_complete_block(self):
        transcript = """
__CHAU7_REVIEW_JSON_BEGIN__
{"summary":"ok","findings":[],"recommendations":["none"],"confidence":"high"}
""".strip()

        self.assertIsNone(hook.extract_review_json_from_markers(transcript))

    def test_extract_review_json_falls_back_to_fenced_json_without_markers(self):
        transcript = """
Review complete.
```json
{"summary":"ok","findings":[],"recommendations":["none"],"confidence":"high"}
```
""".strip()

        payload = hook.extract_review_json(transcript)

        self.assertEqual(payload["summary"], "ok")
        self.assertEqual(payload["recommendations"], ["none"])

    def test_extract_review_result_from_events_uses_latest_matching_tab(self):
        events = [
            {
                "tab_id": "tab_1",
                "type": "waiting_input",
                "message": "Older\n__CHAU7_REVIEW_JSON_BEGIN__\n"
                '{"summary":"old","findings":[],"recommendations":[],"confidence":"low"}\n'
                "__CHAU7_REVIEW_JSON_END__",
            },
            {
                "tab_id": "tab_2",
                "type": "waiting_input",
                "message": "Wrong tab\n__CHAU7_REVIEW_JSON_BEGIN__\n"
                '{"summary":"wrong","findings":[],"recommendations":[],"confidence":"medium"}\n'
                "__CHAU7_REVIEW_JSON_END__",
            },
            {
                "tab_id": "tab_1",
                "type": "finished",
                "producer": "runtime_session_manager",
                "message": "Latest\n__CHAU7_REVIEW_JSON_BEGIN__\n"
                '{"summary":"latest","findings":[],"recommendations":[],"confidence":"high"}\n'
                "__CHAU7_REVIEW_JSON_END__",
            },
        ]

        payload, event = hook.extract_review_result_from_events(events, tab_id="tab_1")

        self.assertEqual(payload["summary"], "latest")
        self.assertEqual(event["type"], "finished")

    def test_extract_review_result_from_events_ignores_preexisting_event_ids(self):
        events = [
            {
                "id": "old-event",
                "tab_id": "tab_1",
                "type": "finished",
                "message": "Old\n__CHAU7_REVIEW_JSON_BEGIN__\n"
                '{"summary":"old","findings":[],"recommendations":[],"confidence":"high"}\n'
                "__CHAU7_REVIEW_JSON_END__",
            },
            {
                "id": "new-event",
                "tab_id": "tab_1",
                "type": "finished",
                "message": "New\n__CHAU7_REVIEW_JSON_BEGIN__\n"
                '{"summary":"new","findings":[],"recommendations":[],"confidence":"high"}\n'
                "__CHAU7_REVIEW_JSON_END__",
            },
        ]

        payload, event = hook.extract_review_result_from_events(
            events,
            tab_id="tab_1",
            ignored_event_ids={"old-event"},
        )

        self.assertEqual(payload["summary"], "new")
        self.assertEqual(event["id"], "new-event")


class PreCommitCodexIdentityTests(unittest.TestCase):
    def valid_status(self):
        return {
            "is_at_prompt": True,
            "status": "running",
            "raw_status": "running",
            "raw_active_app": "Codex",
            "ai_provider": "codex",
            "processes": [{"pid": 321, "name": "codex"}],
        }

    def test_stale_codex_banner_without_live_identity_is_not_prompt_ready(self):
        output = "OpenAI Codex gpt-5.3-codex\n›"
        response = self.valid_status()
        response.pop("processes")
        self.assertFalse(hook.is_codex_prompt_ready(response, output, "gpt-5.3-codex"))
        response = self.valid_status()
        response.pop("raw_active_app")
        self.assertFalse(hook.is_codex_prompt_ready(response, output, "gpt-5.3-codex"))

    def test_status_requires_codex_name_state_and_positive_integer_pid(self):
        response = self.valid_status()
        self.assertEqual(hook.codex_pid_from_status(response), 321)
        for invalid_pid in (True, 0, -1, "321"):
            invalid = self.valid_status()
            invalid["processes"][0]["pid"] = invalid_pid
            self.assertIsNone(hook.codex_pid_from_status(invalid))
        wrong_process = self.valid_status()
        wrong_process["processes"][0]["name"] = "node"
        self.assertIsNone(hook.codex_pid_from_status(wrong_process))
        wrong_provider = self.valid_status()
        wrong_provider["ai_provider"] = "claude"
        self.assertIsNone(hook.codex_pid_from_status(wrong_provider))
        wrong_state = self.valid_status()
        wrong_state["raw_status"] = "done"
        self.assertIsNone(hook.codex_pid_from_status(wrong_state))

    def test_expected_pid_must_remain_in_codex_process_rows(self):
        response = self.valid_status()
        self.assertEqual(hook.codex_pid_from_status(response, 321), 321)
        self.assertIsNone(hook.codex_pid_from_status(response, 322))

    def test_process_probe_requires_current_codex_comm(self):
        with mock.patch.object(
            hook.subprocess,
            "run",
            return_value=hook.subprocess.CompletedProcess([], 0, stdout="/opt/bin/codex\n", stderr=""),
        ) as run:
            self.assertTrue(hook.codex_process_is_live(321))
            self.assertEqual(run.call_args.args[0], ["/bin/ps", "-p", "321", "-o", "comm="])
            self.assertIsNotNone(run.call_args.kwargs.get("timeout"))
        with mock.patch.object(
            hook.subprocess,
            "run",
            return_value=hook.subprocess.CompletedProcess([], 0, stdout="node\n", stderr=""),
        ):
            self.assertFalse(hook.codex_process_is_live(321))
        self.assertFalse(hook.codex_process_is_live(True))

    def test_send_refuses_when_fresh_identity_check_fails(self):
        with (
            mock.patch.object(hook, "has_live_codex_identity", return_value=False),
            mock.patch.object(hook, "send_input") as send,
        ):
            self.assertFalse(hook.send_prompt_with_confirmation("tab", "review", 321))
            send.assert_not_called()

    def test_submit_refuses_when_fresh_identity_check_fails(self):
        with (
            mock.patch.object(hook, "has_live_codex_identity", return_value=False),
            mock.patch.object(hook, "submit_prompt") as submit,
        ):
            self.assertFalse(hook.submit_prompt_with_fallback("tab", "baseline", 321))
            submit.assert_not_called()

    def test_raw_newline_fallback_rechecks_identity_and_refuses_on_change(self):
        with (
            mock.patch.object(hook, "has_live_codex_identity", side_effect=[True, False]),
            mock.patch.object(hook, "submit_prompt", return_value={"ok": True}),
            mock.patch.object(hook, "wait_for_submission_start", return_value=False),
            mock.patch.object(hook, "send_input") as send,
        ):
            self.assertFalse(hook.submit_prompt_with_fallback("tab", "baseline", 321))
            send.assert_not_called()

    def test_prompt_sentinel_alone_does_not_pass_without_live_identity(self):
        with (
            mock.patch.object(hook, "has_live_codex_identity", side_effect=[True, False]),
            mock.patch.object(hook, "get_output", return_value={"output": hook.PROMPT_SENTINEL}) as get_output,
            mock.patch.object(hook.time, "monotonic", side_effect=[0.0, 0.0, 10.0]),
            mock.patch.object(hook.time, "sleep"),
        ):
            self.assertFalse(hook.validate_prompt_visible("tab", 1, 321))
            get_output.assert_called_once()


if __name__ == "__main__":
    unittest.main()
