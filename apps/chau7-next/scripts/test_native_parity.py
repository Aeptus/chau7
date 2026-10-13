import copy
import importlib.util
import json
import os
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).with_name("native-parity.py")
SPEC = importlib.util.spec_from_file_location("native_parity", SCRIPT)
NATIVE_PARITY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NATIVE_PARITY)


def make_owned_activation_fixture(root, stage):
    root = Path(root).resolve(strict=True)
    bundle = root / "Owned Fixture.app"
    executable = bundle / "Contents" / "MacOS" / "chau7-next"
    executable.parent.mkdir(parents=True)
    executable.write_bytes(b"owned fixture executable")
    bundle_identifier = "com.chau7.next.native.fixture.test"
    with (bundle / "Contents" / "Info.plist").open("xb") as plist:
        plistlib.dump({"CFBundleIdentifier": bundle_identifier}, plist)
    home = root / "fixture-home"
    home.mkdir()
    evidence = root / "evidence"
    evidence.mkdir()
    environment = {
        "CHAU7_NEXT_NATIVE_PARITY_FIXTURE": "1",
        "CHAU7_NEXT_ISOLATED_TEST_MODE": "1",
        "CHAU7_NEXT_HOME_ROOT": str(home.resolve(strict=True)),
        "HISTFILE": "",
    }
    handshake = {
        "stage": stage,
        "pid": 1234,
        "bundle_identifier": bundle_identifier,
        "bundle_path": str(bundle.resolve(strict=True)),
        "activation_ack_path": str(home.resolve(strict=True) / NATIVE_PARITY.ACTIVATION_ACK_FILENAME_BY_STAGE[stage]),
    }
    return bundle, executable, home, evidence, environment, handshake


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


class NativeArtifactModeTests(unittest.TestCase):
    def test_build_only_requires_a_new_durable_evidence_directory(self):
        args = NATIVE_PARITY.argument_parser().parse_args(["--build-only"])
        with self.assertRaisesRegex(ValueError, "requires --evidence-directory"):
            NATIVE_PARITY.validate_arguments(args)
        args = NATIVE_PARITY.argument_parser().parse_args(
            ["--build-only", "--evidence-directory", "/private/tmp/native-build"]
        )
        self.assertEqual(NATIVE_PARITY.validate_arguments(args), "system")

    def test_build_only_rejects_case_and_locale_selectors(self):
        args = NATIVE_PARITY.argument_parser().parse_args(
            ["--build-only", "--evidence-directory", "/private/tmp/native-build", "--case", "restore"]
        )
        with self.assertRaisesRegex(ValueError, "does not accept"):
            NATIVE_PARITY.validate_arguments(args)
        args = NATIVE_PARITY.argument_parser().parse_args(
            ["--build-only", "--evidence-directory", "/private/tmp/native-build", "--settings-locale", "fr"]
        )
        with self.assertRaisesRegex(ValueError, "does not accept"):
            NATIVE_PARITY.validate_arguments(args)

    def test_receipt_mode_requires_one_case_and_durable_evidence(self):
        args = NATIVE_PARITY.argument_parser().parse_args(["--from-build-receipt", "/private/tmp/receipt.json"])
        with self.assertRaisesRegex(ValueError, "requires --evidence-directory"):
            NATIVE_PARITY.validate_arguments(args)
        args = NATIVE_PARITY.argument_parser().parse_args(
            ["--from-build-receipt", "/private/tmp/receipt.json", "--evidence-directory", "/private/tmp/row"]
        )
        with self.assertRaisesRegex(ValueError, "exactly one"):
            NATIVE_PARITY.validate_arguments(args)
        args = NATIVE_PARITY.argument_parser().parse_args(
            [
                "--from-build-receipt",
                "/private/tmp/receipt.json",
                "--evidence-directory",
                "/private/tmp/row",
                "--case",
                "restore",
            ]
        )
        self.assertEqual(NATIVE_PARITY.validate_arguments(args), "system")
        self.assertIsNone(NATIVE_PARITY.native_build_command(args, "/toolchain/bin/cargo", "aarch64-apple-darwin"))

    def test_settings_locale_is_distinct_from_accessibility_locale(self):
        args = NATIVE_PARITY.argument_parser().parse_args(["--case", "settings", "--settings-locale", "ar"])
        self.assertEqual(NATIVE_PARITY.validate_arguments(args), "system")
        args = NATIVE_PARITY.argument_parser().parse_args(["--case", "accessibility", "--fixture-locale", "he"])
        self.assertEqual(NATIVE_PARITY.validate_arguments(args), "he")
        args = NATIVE_PARITY.argument_parser().parse_args(["--case", "accessibility", "--settings-locale", "ar"])
        with self.assertRaisesRegex(ValueError, "only supported with --case settings"):
            NATIVE_PARITY.validate_arguments(args)

    def test_target_directory_is_an_explicit_cli_input(self):
        args = NATIVE_PARITY.argument_parser().parse_args(["--target-directory", "/private/tmp/fast-199"])
        self.assertEqual(args.target_directory, "/private/tmp/fast-199")

    def test_evidence_directory_refuses_to_reuse_existing_path(self):
        with tempfile.TemporaryDirectory() as parent:
            evidence = Path(parent) / "already-used"
            evidence.mkdir()
            with self.assertRaises(FileExistsError):
                NATIVE_PARITY.create_evidence_directory(evidence)

    def test_receipt_revalidates_exact_source_toolchain_feature_and_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(strict=True)
            workspace = root / "workspace"
            workspace.mkdir()
            target = root / "target"
            target.mkdir()
            triple = "aarch64-apple-darwin"
            binary = target / "release" / "chau7-next"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"fixture binary")
            toolchain_id = "1.99.0-aarch64-apple-darwin"
            toolchain = root / "rustup" / "toolchains" / toolchain_id / "bin"
            toolchain.mkdir(parents=True)
            for name in ("cargo", "rustc", "rustdoc"):
                (toolchain / name).write_bytes(name.encode())
            features = ["native-parity-fixture"]
            args = [
                "build",
                "--release",
                "--locked",
                "-p",
                "chau7_next",
                "--features",
                "native-parity-fixture",
                "--message-format=json-render-diagnostics",
            ]
            fast_profile_environment = {
                "BUILD_MODE": "fast",
                "CARGO_PROFILE_RELEASE_DEBUG": "0",
                "CARGO_PROFILE_RELEASE_STRIP": "symbols",
                "CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG": "0",
                "CARGO_PROFILE_RELEASE_OPT_LEVEL": "3",
                "CARGO_PROFILE_RELEASE_CODEGEN_UNITS": "64",
                "CARGO_PROFILE_RELEASE_LTO": "off",
                "CARGO_PROFILE_RELEASE_INCREMENTAL": "true",
                "CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP": "none",
                "RUSTFLAGS": "",
                "CARGO_ENCODED_RUSTFLAGS": "",
                "RUSTC_WRAPPER": "",
                "RUSTC_WORKSPACE_WRAPPER": "",
            }
            receipt = {
                "schema_version": NATIVE_PARITY.RECEIPT_SCHEMA_VERSION,
                "source": {
                    "revision": "commit",
                    "tree": "tree",
                    "clean_before": True,
                    "status_before": "",
                    "clean_after": True,
                    "status_after": "",
                },
                "artifact": {
                    "path": str(binary),
                    "sha256": NATIVE_PARITY.sha256(binary),
                    "package": "chau7_next",
                    "requested_features": features,
                    "requested_features_sha256": NATIVE_PARITY.feature_fingerprint(features),
                    "cargo_build_args": args,
                    "target_triple": triple,
                    "release_profile": NATIVE_PARITY.release_profile_from_environment(fast_profile_environment),
                    "cargo_artifact": {
                        "target_name": "chau7-next",
                        "target_triple": triple,
                        "target_kind": ["bin"],
                        "executable": str(binary),
                        "features": features,
                        "features_sha256": NATIVE_PARITY.feature_fingerprint(features),
                        "profile": {"debug_assertions": False, "debuginfo": 0, "opt_level": 3},
                    },
                },
                "toolchain": {
                    "release": toolchain_id,
                    "host_triple": triple,
                    **{name: NATIVE_PARITY.file_identity(toolchain / name) for name in ("cargo", "rustc", "rustdoc")},
                },
                "workspace": str(workspace),
                "target_directory": str(target),
            }
            receipt_path = root / "receipt.json"
            receipt_path.write_text(json.dumps(receipt))
            source = {"revision": "commit", "tree": "tree", "status": ""}
            with mock.patch.object(NATIVE_PARITY, "source_snapshot", return_value=source):
                loaded, actual_binary = NATIVE_PARITY.validate_build_receipt(
                    receipt_path, root, workspace, triple, toolchain_id, toolchain
                )
            self.assertEqual(loaded["source"]["tree"], "tree")
            self.assertEqual(actual_binary, binary)
            mutations = [
                ("source revision", lambda value: value["source"].update(revision="other")),
                ("source tree", lambda value: value["source"].update(tree="other")),
                ("dirty build", lambda value: value["source"].update(clean_after=False)),
                (
                    "extra Cargo feature",
                    lambda value: (
                        value["artifact"]["cargo_artifact"].update(features=["native-parity-fixture", "extra"]),
                        value["artifact"]["cargo_artifact"].update(
                            features_sha256=NATIVE_PARITY.feature_fingerprint(
                                value["artifact"]["cargo_artifact"]["features"]
                            )
                        ),
                    ),
                ),
                (
                    "wrong release profile",
                    lambda value: value["artifact"]["cargo_artifact"].update(
                        profile={"debug_assertions": False, "debuginfo": 2, "opt_level": 3}
                    ),
                ),
                ("wrong target kind", lambda value: value["artifact"]["cargo_artifact"].update(target_kind=["cdylib"])),
                ("wrong toolchain hash", lambda value: value["toolchain"]["cargo"].update(sha256="0" * 64)),
                ("wrong binary hash", lambda value: value["artifact"].update(sha256="0" * 64)),
            ]
            for label, mutate in mutations:
                with self.subTest(label=label):
                    invalid = copy.deepcopy(receipt)
                    mutate(invalid)
                    receipt_path.write_text(json.dumps(invalid))
                    with (
                        mock.patch.object(NATIVE_PARITY, "source_snapshot", return_value=source),
                        self.assertRaises(ValueError),
                    ):
                        NATIVE_PARITY.validate_build_receipt(
                            receipt_path, root, workspace, triple, toolchain_id, toolchain
                        )

    def test_cargo_artifact_parser_ignores_non_object_json_records(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "chau7-next"
            binary.write_bytes(b"fixture")
            log = root / "build.log"
            log.write_text("null\n42\n[]\n")
            with self.assertRaisesRegex(ValueError, "expected one Cargo binary artifact"):
                NATIVE_PARITY.cargo_binary_artifact(log, binary, "aarch64-apple-darwin")

    def test_cargo_artifact_parser_requires_exact_feature_target_and_release_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "chau7-next"
            binary.write_bytes(b"fixture")
            log = root / "build.log"
            artifact = {
                "reason": "compiler-artifact",
                "package_id": "path+file:///workspace/crates/chau7_next#chau7_next@0.1.0",
                "target": {"name": "chau7-next", "kind": ["bin"]},
                "executable": str(binary),
                "features": ["native-parity-fixture"],
                "profile": {"debug_assertions": False, "debuginfo": 0, "opt_level": 3},
            }
            log.write_text(json.dumps(artifact) + "\n")
            parsed = NATIVE_PARITY.cargo_binary_artifact(log, binary, "aarch64-apple-darwin")
            self.assertEqual(parsed["features"], ["native-parity-fixture"])
            for label, change in (
                ("extra feature", lambda value: value.update(features=["native-parity-fixture", "extra"])),
                (
                    "debug assertions",
                    lambda value: value.update(profile={"debug_assertions": True, "debuginfo": 0, "opt_level": 3}),
                ),
                (
                    "debug info",
                    lambda value: value.update(profile={"debug_assertions": False, "debuginfo": 2, "opt_level": 3}),
                ),
                (
                    "optimization",
                    lambda value: value.update(profile={"debug_assertions": False, "debuginfo": 0, "opt_level": 2}),
                ),
                ("target kind", lambda value: value.update(target={"name": "chau7-next", "kind": ["cdylib"]})),
                ("missing profile", lambda value: value.update(profile=None)),
            ):
                with self.subTest(label=label):
                    invalid = copy.deepcopy(artifact)
                    change(invalid)
                    log.write_text(json.dumps(invalid) + "\n")
                    with self.assertRaises(ValueError):
                        NATIVE_PARITY.cargo_binary_artifact(log, binary, "aarch64-apple-darwin")


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
        self.ordered_front_handshake = {
            **self.handshake,
            "stage": "ordered_front_surface_reveal",
            "activation_ack_path": ("/private/tmp/fixture-home/native-parity-ordered-front-activation.ack"),
        }
        self.ordered_front_line = NATIVE_PARITY.ORDERED_FRONT_ACTIVATION_HANDSHAKE_PREFIX + json.dumps(
            self.ordered_front_handshake
        )

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

    def test_parses_complete_ordered_front_handshake(self):
        self.assertEqual(
            NATIVE_PARITY.parse_ordered_front_activation_handshake("other log\n" + self.ordered_front_line + "\n"),
            self.ordered_front_handshake,
        )

    def test_ordered_front_handshake_without_newline_is_not_a_request(self):
        self.assertIsNone(NATIVE_PARITY.parse_ordered_front_activation_handshake(self.ordered_front_line))

    def test_rejects_duplicate_ordered_front_handshakes(self):
        with self.assertRaises(ValueError):
            NATIVE_PARITY.parse_ordered_front_activation_handshake(
                self.ordered_front_line + "\n" + self.ordered_front_line + "\n"
            )

    def test_rejects_malformed_ordered_front_handshake(self):
        with self.assertRaises(ValueError):
            NATIVE_PARITY.parse_ordered_front_activation_handshake(
                NATIVE_PARITY.ORDERED_FRONT_ACTIVATION_HANDSHAKE_PREFIX + "not-json\n"
            )

    def test_handshake_parsers_are_separated_by_prefix(self):
        self.assertIsNone(NATIVE_PARITY.parse_activation_handshake(self.ordered_front_line + "\n"))
        self.assertIsNone(NATIVE_PARITY.parse_ordered_front_activation_handshake(self.line + "\n"))

    def test_rejects_an_unexpected_stage_for_the_ordered_front_prefix(self):
        wrong_stage = {
            **self.ordered_front_handshake,
            "stage": "deminiaturized_surface_reveal",
        }
        line = NATIVE_PARITY.ORDERED_FRONT_ACTIVATION_HANDSHAKE_PREFIX + json.dumps(wrong_stage)
        with self.assertRaises(ValueError):
            NATIVE_PARITY.parse_ordered_front_activation_handshake(line + "\n")

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

    def test_wait_owned_fixture_marks_both_missing_handshakes_on_exit(self):
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
        self.assertTrue(record["ordered_front_activation_request_attempted"])
        self.assertFalse(record["ordered_front_activation_request_passed"])
        self.assertIn("before emitting", record["ordered_front_activation_request_error"])
        self.assertTrue(record["activation_request_attempted"])
        self.assertFalse(record["activation_request_passed"])
        self.assertIn("before emitting", record["activation_request_error"])

    def test_wait_owned_fixture_rejects_late_handshake_before_ordered_front_pass(self):
        class ExitedProcess:
            def poll(self):
                return 2

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stderr = root / "restore.stderr"
            stderr.write_text(self.line + "\n")
            record = {"bundle_identifier": "owned-id", "timed_out": False}
            NATIVE_PARITY.wait_owned_fixture(
                ExitedProcess(),
                record,
                Path("/private/tmp/Owned Fixture.app"),
                stderr,
                root,
                {},
                "auto",
            )
        self.assertTrue(record["ordered_front_activation_request_attempted"])
        self.assertFalse(record["ordered_front_activation_request_passed"])
        self.assertTrue(record["activation_request_attempted"])
        self.assertFalse(record["activation_request_passed"])
        self.assertIn("before the ordered-front", record["activation_request_error"])


class NativeOwnedActivationRequestTests(unittest.TestCase):
    def test_request_uses_exact_owned_pid_path_and_stage_ack(self):
        stages = {
            "ordered_front_surface_reveal": "restore.ordered_front_activation",
            "deminiaturized_surface_reveal": "restore.activation",
        }
        for stage, evidence_prefix in stages.items():
            with self.subTest(stage=stage), tempfile.TemporaryDirectory() as directory:
                bundle, executable, home, evidence, environment, handshake = make_owned_activation_fixture(
                    directory, stage
                )
                ack_path = home / NATIVE_PARITY.ACTIVATION_ACK_FILENAME_BY_STAGE[stage]
                with (
                    mock.patch.object(
                        NATIVE_PARITY,
                        "_pid_executable_path",
                        return_value=os.fsencode(executable),
                    ),
                    mock.patch.object(
                        NATIVE_PARITY,
                        "owned_executable_pids",
                        side_effect=[[handshake["pid"]], [handshake["pid"]]],
                    ) as owned_pids,
                    mock.patch.object(
                        NATIVE_PARITY.subprocess,
                        "run",
                        return_value=mock.Mock(returncode=0),
                    ) as open_bundle,
                ):
                    request = NATIVE_PARITY.request_owned_activation(
                        bundle,
                        handshake["bundle_identifier"],
                        handshake,
                        evidence,
                        environment,
                        "software",
                    )
                expected_executable = (bundle / "Contents" / "MacOS" / "chau7-next").resolve(strict=True)
                self.assertEqual(owned_pids.call_count, 2)
                self.assertEqual(owned_pids.call_args_list[0].args[0], expected_executable)
                self.assertEqual(owned_pids.call_args_list[1].args[0], expected_executable)
                open_bundle.assert_called_once()
                command = open_bundle.call_args.args[0]
                self.assertEqual(command[command.index("-a") + 1], str(bundle.resolve(strict=True)))
                self.assertEqual(request["pid_before"], [handshake["pid"]])
                self.assertEqual(request["pid_after"], [handshake["pid"]])
                self.assertEqual(request["activation_ack_path"], str(ack_path.resolve()))
                self.assertTrue(ack_path.is_file())
                self.assertTrue((evidence / f"{evidence_prefix}.stdout").is_file())
                self.assertTrue((evidence / f"{evidence_prefix}.stderr").is_file())

    def test_wrong_ack_or_pid_is_rejected_before_launchservices_open(self):
        for mismatch in ("ack", "pid"):
            with self.subTest(mismatch=mismatch), tempfile.TemporaryDirectory() as directory:
                bundle, executable, home, evidence, environment, handshake = make_owned_activation_fixture(
                    directory, "ordered_front_surface_reveal"
                )
                wrong_executable = Path(directory) / "other-executable"
                wrong_executable.write_bytes(b"different executable")
                if mismatch == "ack":
                    handshake["activation_ack_path"] = str(home / "wrong.ack")
                    executable_path = executable
                else:
                    executable_path = wrong_executable
                with (
                    mock.patch.object(
                        NATIVE_PARITY,
                        "_pid_executable_path",
                        return_value=os.fsencode(executable_path),
                    ),
                    mock.patch.object(NATIVE_PARITY.subprocess, "run") as open_bundle,
                    self.assertRaises(ValueError),
                ):
                    NATIVE_PARITY.request_owned_activation(
                        bundle,
                        handshake["bundle_identifier"],
                        handshake,
                        evidence,
                        environment,
                        "software",
                    )
                open_bundle.assert_not_called()


class NativeParityResultTests(unittest.TestCase):
    def passing_record(self, launch_services):
        return {
            "launch_services": launch_services,
            "timed_out": False,
            "exit_code": 0,
            "outcome": {
                "passed": True,
                "owned_resources_closed": True,
                "owned_profile_removed": True,
            },
            "owned_home_removed": True,
            "application_pid_verified": True,
            "application_process_gone": True,
            "ordered_front_activation_request_passed": False,
            "activation_request_passed": False,
        }

    def test_launchservices_result_requires_both_activation_stages(self):
        for ordered_front_passed in (False, True):
            for deminiaturized_passed in (False, True):
                with self.subTest(
                    ordered_front_passed=ordered_front_passed,
                    deminiaturized_passed=deminiaturized_passed,
                ):
                    record = self.passing_record(launch_services=True)
                    record["ordered_front_activation_request_passed"] = ordered_front_passed
                    record["activation_request_passed"] = deminiaturized_passed
                    self.assertEqual(
                        NATIVE_PARITY.case_passed(record),
                        ordered_front_passed and deminiaturized_passed,
                    )

    def test_direct_fixture_result_does_not_require_activation_requests(self):
        record = self.passing_record(launch_services=False)
        self.assertTrue(NATIVE_PARITY.case_passed(record))


if __name__ == "__main__":
    unittest.main()
