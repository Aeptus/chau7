import importlib.util
import json
import tempfile
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


class NativeActivationHandshakeTests(unittest.TestCase):
    def setUp(self):
        self.handshake = {
            "stage": "deminiaturized_surface_reveal",
            "pid": 1234,
            "bundle_identifier": "com.chau7.next.native.fixture.test",
            "bundle_path": "/private/tmp/Owned Fixture.app",
            "activation_ack_path": "/private/tmp/fixture-home/native-parity-activation.ack",
        }
        self.line = NATIVE_PARITY.ACTIVATION_HANDSHAKE_PREFIX + json.dumps(self.handshake)

    def test_parses_one_exact_restore_handshake(self):
        self.assertEqual(
            NATIVE_PARITY.parse_activation_handshake("other log\n" + self.line + "\n"),
            self.handshake,
        )

    def test_incomplete_handshake_without_newline_is_not_a_request(self):
        self.assertIsNone(NATIVE_PARITY.parse_activation_handshake(self.line))

    def test_rejects_complete_malformed_handshake(self):
        with self.assertRaises(ValueError):
            NATIVE_PARITY.parse_activation_handshake(NATIVE_PARITY.ACTIVATION_HANDSHAKE_PREFIX + "not-json\n")

    def test_rejects_two_complete_handshakes(self):
        self.assertRaises(
            ValueError,
            NATIVE_PARITY.parse_activation_handshake,
            self.line + "\n" + self.line + "\n",
        )

    def test_reopen_targets_exact_bundle_with_all_fixture_guards(self):
        bundle = Path("/private/tmp/Owned Fixture.app")
        environment = {
            "CHAU7_NEXT_NATIVE_PARITY_FIXTURE": "1",
            "CHAU7_NEXT_ISOLATED_TEST_MODE": "1",
            "CHAU7_NEXT_HOME_ROOT": "/private/tmp/fixture-home",
            "HISTFILE": "",
        }
        command = NATIVE_PARITY.activation_request_command(bundle, environment, "software")
        self.assertEqual(
            command,
            [
                "/usr/bin/open",
                "--env",
                "CHAU7_NEXT_NATIVE_PARITY_FIXTURE=1",
                "--env",
                "CHAU7_NEXT_ISOLATED_TEST_MODE=1",
                "--env",
                "CHAU7_NEXT_HOME_ROOT=/private/tmp/fixture-home",
                "--env",
                "HISTFILE=",
                "-a",
                str(bundle),
                "--args",
                "--native-parity-fixture",
                "restore",
                "--window-renderer",
                "software",
            ],
        )
        self.assertNotIn("-n", command)

    def test_wait_owned_fixture_is_importable_and_fail_closes_before_handshake(self):
        class ExitedProcess:
            def poll(self):
                return 2

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stderr = root / "restore.stderr"
            stderr.write_text("ordinary stderr\n")
            record = {"bundle_identifier": "owned-id", "timed_out": False}
            exit_code = NATIVE_PARITY.wait_owned_fixture(
                ExitedProcess(),
                record,
                Path("/private/tmp/Owned Fixture.app"),
                stderr,
                root,
                {},
                "auto",
            )
        self.assertEqual(exit_code, 2)
        self.assertTrue(record["activation_request_attempted"])
        self.assertFalse(record["activation_request_passed"])
        self.assertIn("before emitting", record["activation_request_error"])


if __name__ == "__main__":
    unittest.main()
