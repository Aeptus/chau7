import importlib.util
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("native-parity.py")
SPEC = importlib.util.spec_from_file_location("native_parity", SCRIPT)
NATIVE_PARITY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NATIVE_PARITY)


class NativeParityArgumentTests(unittest.TestCase):
    def test_all_keeps_the_original_four_cases(self):
        self.assertEqual(
            NATIVE_PARITY.cases_for("all"),
            ("restore", "settings", "editor", "cache"),
        )

    def test_keyboard_is_opt_in_only(self):
        self.assertEqual(NATIVE_PARITY.cases_for("keyboard"), ("keyboard",))
        self.assertEqual(
            NATIVE_PARITY.argument_parser().parse_args(["--case", "keyboard"]).case,
            "keyboard",
        )

    def test_parser_rejects_unknown_cases(self):
        with self.assertRaises(SystemExit):
            NATIVE_PARITY.argument_parser().parse_args(["--case", "unknown"])

    def test_fixture_locale_is_limited_to_accessibility(self):
        self.assertEqual(NATIVE_PARITY.fixture_locale_for("accessibility", ["fr"]), "fr")
        self.assertEqual(NATIVE_PARITY.fixture_locale_for("keyboard", []), "system")
        with self.assertRaises(ValueError):
            NATIVE_PARITY.fixture_locale_for("keyboard", ["fr"])
        with self.assertRaises(ValueError):
            NATIVE_PARITY.fixture_locale_for("accessibility", ["fr", "es"])


if __name__ == "__main__":
    unittest.main()
