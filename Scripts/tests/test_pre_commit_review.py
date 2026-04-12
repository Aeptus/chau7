import importlib.util
import importlib.machinery
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


if __name__ == "__main__":
    unittest.main()
