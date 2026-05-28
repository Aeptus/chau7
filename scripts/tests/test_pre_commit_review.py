import importlib.machinery
import importlib.util
import pathlib
import unittest

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


if __name__ == "__main__":
    unittest.main()
