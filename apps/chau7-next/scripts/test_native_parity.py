import copy
import importlib.util
import json
import os
import plistlib
import subprocess
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

    def test_multiwindow_restore_is_opt_in_only(self):
        self.assertEqual(NATIVE_PARITY.cases_for("multiwindow-restore"), ("multiwindow-restore",))
        self.assertEqual(
            NATIVE_PARITY.argument_parser().parse_args(["--case", "multiwindow-restore"]).case,
            "multiwindow-restore",
        )

    def test_only_restore_and_keyboard_use_launchservices(self):
        for case in ("restore", "keyboard"):
            with self.subTest(case=case):
                self.assertTrue(NATIVE_PARITY.launch_services_for(case))
        for case in ("settings", "editor", "cache", "accessibility", "multiwindow-restore"):
            with self.subTest(case=case):
                self.assertFalse(NATIVE_PARITY.launch_services_for(case))

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


class NativeFullscreenMenuPointerTests(unittest.TestCase):
    def test_manual_pointer_mode_is_explicit_and_rejects_other_values(self):
        self.assertEqual(NATIVE_PARITY.fullscreen_menu_stimulus_mode({}), "forced_programmatic")
        self.assertEqual(
            NATIVE_PARITY.fullscreen_menu_stimulus_mode({NATIVE_PARITY.MANUAL_MENU_POINTER_ENV: "1"}),
            "manual_pointer",
        )
        with self.assertRaisesRegex(ValueError, "must be 0 or 1"):
            NATIVE_PARITY.fullscreen_menu_stimulus_mode({NATIVE_PARITY.MANUAL_MENU_POINTER_ENV: "yes"})

    def test_launchservices_forwards_pointer_opt_in_only_to_restore(self):
        environment = {
            "CHAU7_NEXT_NATIVE_PARITY_FIXTURE": "1",
            "CHAU7_NEXT_ISOLATED_TEST_MODE": "1",
            "CHAU7_NEXT_HOME_ROOT": "/private/tmp/fixture-home",
            "HISTFILE": "",
        }
        self.assertNotIn(
            NATIVE_PARITY.MANUAL_MENU_POINTER_ENV,
            NATIVE_PARITY.launch_services_environment_names("restore", environment),
        )
        opted_in = {
            **environment,
            NATIVE_PARITY.MANUAL_MENU_POINTER_ENV: "1",
        }
        self.assertIn(
            NATIVE_PARITY.MANUAL_MENU_POINTER_ENV,
            NATIVE_PARITY.launch_services_environment_names("restore", opted_in),
        )
        with self.assertRaisesRegex(ValueError, "limited to --case restore"):
            NATIVE_PARITY.launch_services_environment_names("keyboard", opted_in)

    def test_manual_pointer_result_requires_actual_three_phase_hover_coverage(self):
        phases = [
            {
                "phase": phase_number,
                "expected_menu_bar_visible": visible,
                "observed_menu_bar_visible": visible,
                "app_active": True,
                "window_visible": True,
                "window_key": True,
                "window_fullscreen": True,
                "synthetic_pointer_events_posted": False,
                "samples": 5,
                "stable_for_ms": (500, 3000, 750)[phase_number - 1],
                "pointer_near_screen_top": visible,
            }
            for phase_number, visible in ((1, False), (2, True), (3, False))
        ]
        stimulus = {
            "mode": "manual_pointer",
            "pointer_top_transition_observed": True,
            "pointer_hover_causality_proven": False,
            "synthetic_pointer_events_posted": False,
            "menu_api_mutation_calls": 0,
            "presentation_option_mutation_calls": 0,
            "phases": phases,
        }
        outcome = {
            "details": {
                "traffic_light_zoom_geometry": {
                    "actual_fullscreen_cycle": {"fullscreen": {"menu_reveal_cycle": {"stimulus": stimulus}}}
                }
            }
        }
        self.assertEqual(NATIVE_PARITY.extract_fullscreen_menu_stimulus(outcome), stimulus)
        record = {
            "fullscreen_menu_stimulus_mode_requested": "manual_pointer",
            "fullscreen_menu_stimulus": stimulus,
        }
        self.assertTrue(NATIVE_PARITY.manual_pointer_coverage_matches(record))
        phases[1]["window_key"] = False
        self.assertFalse(NATIVE_PARITY.manual_pointer_coverage_matches(record))


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


class MultiwindowRestoreManifestTests(unittest.TestCase):
    def valid_session(self):
        windows = []
        for expected_tabs in NATIVE_PARITY.MULTIWINDOW_RESTORE_EXPECTED:
            tabs = []
            for expected in expected_tabs:
                resume_id = expected["resume_id"]
                tabs.append(
                    {
                        "uuid": expected["uuid"],
                        "custom_title": expected["title"],
                        "panes": [
                            {
                                "id": expected["pane_id"],
                                "ai_provider": "codex",
                                "ai_session_id": resume_id,
                                "ai_resume_command": f"codex resume {resume_id}",
                            }
                        ],
                    }
                )
            windows.append({"tabs": tabs})
        return {"windows": windows}

    def test_manifest_requires_both_windows_and_late_second_window_metadata(self):
        session = self.valid_session()
        self.assertTrue(NATIVE_PARITY.multiwindow_restore_manifest_matches(session))
        session["windows"][1]["tabs"].pop()
        self.assertFalse(NATIVE_PARITY.multiwindow_restore_manifest_matches(session))

    def test_manifest_rejects_resume_metadata_mismatch(self):
        session = self.valid_session()
        session["windows"][1]["tabs"][1]["panes"][0]["ai_resume_command"] = "codex resume wrong"
        self.assertFalse(NATIVE_PARITY.multiwindow_restore_manifest_matches(session))


class FrontmostApplicationReaderTests(unittest.TestCase):
    def test_frontmost_reader_pumps_run_loop_before_each_fresh_workspace_read(self):
        events = []
        workspace_pids = iter((14525, 3355))

        def pump_run_loop():
            events.append("pump")

        def read_workspace_pid():
            events.append("workspace-read")
            return next(workspace_pids)

        with (
            mock.patch.object(NATIVE_PARITY, "_pump_appkit_run_loop", side_effect=pump_run_loop),
            mock.patch.object(
                NATIVE_PARITY,
                "_read_frontmost_application_pid",
                side_effect=read_workspace_pid,
            ),
        ):
            self.assertEqual(NATIVE_PARITY.frontmost_application_pid(), 14525)
            self.assertEqual(NATIVE_PARITY.frontmost_application_pid(), 3355)

        self.assertEqual(events, ["pump", "workspace-read", "pump", "workspace-read"])


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
        self.fullscreen_reactivation_handshake = {
            **self.handshake,
            "stage": "fullscreen_application_reactivation",
            "activation_ack_path": "/private/tmp/fixture-home/native-parity-fullscreen-reactivation.ack",
        }
        self.fullscreen_reactivation_line = NATIVE_PARITY.FULLSCREEN_REACTIVATION_HANDSHAKE_PREFIX + json.dumps(
            self.fullscreen_reactivation_handshake
        )
        self.fullscreen_focus_yield_handshake = {
            **self.handshake,
            "stage": "fullscreen_application_focus_yield",
            "activation_ack_path": "/private/tmp/fixture-home/native-parity-fullscreen-focus-yield.ack",
        }
        self.fullscreen_focus_yield_line = NATIVE_PARITY.FULLSCREEN_FOCUS_YIELD_HANDSHAKE_PREFIX + json.dumps(
            self.fullscreen_focus_yield_handshake
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

    def test_rejects_an_unexpected_stage_for_the_ordered_front_prefix(self):
        wrong_stage = {
            **self.ordered_front_handshake,
            "stage": "deminiaturized_surface_reveal",
        }
        line = NATIVE_PARITY.ORDERED_FRONT_ACTIVATION_HANDSHAKE_PREFIX + json.dumps(wrong_stage)
        with self.assertRaises(ValueError):
            NATIVE_PARITY.parse_ordered_front_activation_handshake(line + "\n")

    def test_parses_one_fullscreen_reactivation_handshake(self):
        self.assertEqual(
            NATIVE_PARITY.parse_fullscreen_reactivation_handshake(
                "other log\n" + self.fullscreen_reactivation_line + "\n"
            ),
            self.fullscreen_reactivation_handshake,
        )

    def test_fullscreen_reactivation_handshake_requires_newline_and_rejects_duplicates(self):
        self.assertIsNone(NATIVE_PARITY.parse_fullscreen_reactivation_handshake(self.fullscreen_reactivation_line))
        with self.assertRaises(ValueError):
            NATIVE_PARITY.parse_fullscreen_reactivation_handshake(
                self.fullscreen_reactivation_line + "\n" + self.fullscreen_reactivation_line + "\n"
            )

    def test_parses_one_fullscreen_focus_yield_handshake(self):
        self.assertEqual(
            NATIVE_PARITY.parse_fullscreen_focus_yield_handshake(
                "other log\n" + self.fullscreen_focus_yield_line + "\n"
            ),
            self.fullscreen_focus_yield_handshake,
        )

    def test_fullscreen_focus_yield_handshake_requires_newline_and_rejects_duplicates(self):
        self.assertIsNone(NATIVE_PARITY.parse_fullscreen_focus_yield_handshake(self.fullscreen_focus_yield_line))
        with self.assertRaises(ValueError):
            NATIVE_PARITY.parse_fullscreen_focus_yield_handshake(
                self.fullscreen_focus_yield_line + "\n" + self.fullscreen_focus_yield_line + "\n"
            )

    def test_rejects_malformed_or_wrong_stage_focus_yield_handshake(self):
        with self.assertRaises(ValueError):
            NATIVE_PARITY.parse_fullscreen_focus_yield_handshake(
                NATIVE_PARITY.FULLSCREEN_FOCUS_YIELD_HANDSHAKE_PREFIX + "not-json\n"
            )
        wrong_stage = {
            **self.fullscreen_focus_yield_handshake,
            "stage": "fullscreen_application_reactivation",
        }
        line = NATIVE_PARITY.FULLSCREEN_FOCUS_YIELD_HANDSHAKE_PREFIX + json.dumps(wrong_stage)
        with self.assertRaises(ValueError):
            NATIVE_PARITY.parse_fullscreen_focus_yield_handshake(line + "\n")

    def test_handshake_parsers_are_separated_by_prefix(self):
        self.assertIsNone(NATIVE_PARITY.parse_activation_handshake(self.ordered_front_line + "\n"))
        self.assertIsNone(NATIVE_PARITY.parse_ordered_front_activation_handshake(self.line + "\n"))
        self.assertIsNone(NATIVE_PARITY.parse_fullscreen_reactivation_handshake(self.line + "\n"))
        self.assertIsNone(NATIVE_PARITY.parse_fullscreen_reactivation_handshake(self.ordered_front_line + "\n"))
        self.assertIsNone(NATIVE_PARITY.parse_fullscreen_focus_yield_handshake(self.line + "\n"))
        self.assertIsNone(NATIVE_PARITY.parse_fullscreen_focus_yield_handshake(self.ordered_front_line + "\n"))
        self.assertIsNone(
            NATIVE_PARITY.parse_fullscreen_focus_yield_handshake(self.fullscreen_reactivation_line + "\n")
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

    def test_wait_owned_fixture_marks_all_missing_handshakes_on_exit(self):
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
        self.assertTrue(record["fullscreen_reactivation_request_attempted"])
        self.assertFalse(record["fullscreen_reactivation_request_passed"])
        self.assertIn("before emitting", record["fullscreen_reactivation_request_error"])
        self.assertTrue(record["fullscreen_focus_yield_request_attempted"])
        self.assertFalse(record["fullscreen_focus_yield_request_passed"])
        self.assertIn("before emitting", record["fullscreen_focus_yield_request_error"])

    def test_wait_owned_fixture_orders_focus_yield_and_reactivation_before_demini(self):
        class StagedStderr:
            def __init__(self, stages):
                self.stages = stages
                self.reads = 0

            def read_text(self, errors="replace"):
                index = min(self.reads, len(self.stages) - 1)
                self.reads += 1
                return self.stages[index]

        class Process:
            def __init__(self):
                self.poll_count = 0

            def poll(self):
                self.poll_count += 1
                return 0 if self.poll_count >= 8 else None

        ordered_front = self.ordered_front_line + "\n"
        focus_yield = self.fullscreen_focus_yield_line + "\n"
        fullscreen_reactivation = self.fullscreen_reactivation_line + "\n"
        demini = self.line + "\n"
        stages = (
            ordered_front,
            ordered_front + focus_yield,
            ordered_front + focus_yield + fullscreen_reactivation,
            ordered_front + focus_yield + fullscreen_reactivation + demini,
        )
        events = []

        def request_activation(
            bundle,
            bundle_identifier,
            handshake,
            evidence,
            environment,
            window_renderer,
            before_acknowledgement=None,
            deadline_seconds=6,
        ):
            stage = handshake["stage"]
            events.append(f"request:{stage}")
            if before_acknowledgement is not None:
                self.assertEqual(stage, "fullscreen_application_reactivation")
                self.assertEqual(deadline_seconds, 8)
                events.append(f"before-ack:{stage}")
                callback_result = before_acknowledgement(NATIVE_PARITY.time.monotonic() + deadline_seconds)
                events.append(f"callback-returned:{stage}")
            else:
                callback_result = None
            events.append(f"ack:{stage}")
            return {"exit_code": 0, "before_acknowledgement": callback_result}

        def request_focus_yield(bundle, bundle_identifier, handshake, evidence, environment, primary_pid, state):
            self.assertEqual(handshake["stage"], "fullscreen_application_focus_yield")
            self.assertEqual(primary_pid, self.handshake["pid"])
            events.append("request:fullscreen_application_focus_yield")
            return {"acknowledged": True}

        def wait_frontmost(pid, deadline):
            self.assertEqual(pid, self.handshake["pid"])
            self.assertGreater(deadline, NATIVE_PARITY.time.monotonic())
            events.append("primary-frontmost")

        def stop_companion(state, deadline):
            self.assertGreater(deadline, NATIVE_PARITY.time.monotonic())
            events.append("stop-companion")
            return {
                "process_gone": True,
                "bundle_removed": True,
                "home_removed": True,
            }

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            record = {"bundle_identifier": self.handshake["bundle_identifier"], "timed_out": False}
            with (
                mock.patch.object(NATIVE_PARITY, "request_owned_activation", side_effect=request_activation),
                mock.patch.object(NATIVE_PARITY, "request_owned_focus_yield", side_effect=request_focus_yield),
                mock.patch.object(NATIVE_PARITY, "wait_for_frontmost_application", side_effect=wait_frontmost),
                mock.patch.object(NATIVE_PARITY, "stop_focus_companion", side_effect=stop_companion),
                mock.patch.object(NATIVE_PARITY.time, "sleep"),
            ):
                exit_code = NATIVE_PARITY.wait_owned_fixture(
                    Process(),
                    record,
                    Path("/private/tmp/Owned Fixture.app"),
                    StagedStderr(stages),
                    root,
                    {},
                    "software",
                )

        self.assertEqual(exit_code, 0)
        self.assertEqual(
            events,
            [
                "request:ordered_front_surface_reveal",
                "ack:ordered_front_surface_reveal",
                "request:fullscreen_application_focus_yield",
                "request:fullscreen_application_reactivation",
                "before-ack:fullscreen_application_reactivation",
                "primary-frontmost",
                "stop-companion",
                "primary-frontmost",
                "callback-returned:fullscreen_application_reactivation",
                "ack:fullscreen_application_reactivation",
                "request:deminiaturized_surface_reveal",
                "ack:deminiaturized_surface_reveal",
            ],
        )
        self.assertTrue(record["ordered_front_activation_request_passed"])
        self.assertTrue(record["fullscreen_focus_yield_request_passed"])
        self.assertTrue(record["fullscreen_reactivation_request_passed"])
        self.assertTrue(record["activation_request_passed"])

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


class NativeLaunchServicesCaptureTests(unittest.TestCase):
    def make_fixture(self, directory):
        parent = Path(directory).resolve(strict=True)
        root = parent / "owned-bundle-root"
        root.mkdir(mode=0o700)
        bundle = root / "Chau7 Next Native Fixture.app"
        bundle.mkdir()
        evidence = parent / "evidence"
        evidence.mkdir(mode=0o700)
        record = {
            "case": "restore",
            "owned_bundle_root": str(root.resolve(strict=True)),
            "owned_bundle": str(bundle.resolve(strict=True)),
            "owned_bundle_removed": False,
            "application_pid_verified": False,
            "application_process_gone": False,
            "timed_out": False,
        }
        captures = {
            key: NATIVE_PARITY.create_owned_restore_capture(record, root, name)
            for key, name in NATIVE_PARITY.RESTORE_CAPTURE_NAMES.items()
        }
        record["launch_services_capture_paths"] = {key: str(path) for key, path in captures.items()}
        record["launch_services_capture_archive_paths"] = {
            key: str(evidence / name) for key, name in NATIVE_PARITY.RESTORE_CAPTURE_NAMES.items()
        }
        record["launch_services_captures_archived"] = False
        return root, evidence, record, captures

    def test_captures_are_exclusively_created_under_the_owned_bundle_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root, _, record, captures = self.make_fixture(directory)
            for capture in captures.values():
                self.assertEqual(capture.parent, root.resolve(strict=True))
                self.assertTrue(capture.is_file())
                self.assertEqual(capture.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                NATIVE_PARITY.create_owned_restore_capture(record, root, NATIVE_PARITY.RESTORE_CAPTURE_NAMES["stdout"])

    def test_unknown_or_live_application_preserves_bundle_and_captures(self):
        with tempfile.TemporaryDirectory() as directory:
            root, evidence, record, captures = self.make_fixture(directory)
            captures["stdout"].write_bytes(b"fixture output")
            with self.assertRaisesRegex(ValueError, "verified application retirement"):
                NATIVE_PARITY.archive_and_remove_owned_restore_bundle(record, root, evidence)
            self.assertTrue(root.is_dir())
            self.assertTrue(all(path.is_file() for path in captures.values()))
            self.assertFalse((evidence / "restore.stdout").exists())
            self.assertFalse(record["owned_bundle_removed"])

    def test_verified_retirement_archives_captures_then_removes_exact_owned_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root, evidence, record, captures = self.make_fixture(directory)
            captures["stdout"].write_bytes(b"fixture stdout")
            captures["stderr"].write_bytes(b"fixture stderr")
            record["application_pid_verified"] = True
            record["application_process_gone"] = True
            NATIVE_PARITY.archive_and_remove_owned_restore_bundle(record, root, evidence)
            self.assertEqual((evidence / "restore.stdout").read_bytes(), b"fixture stdout")
            self.assertEqual((evidence / "restore.stderr").read_bytes(), b"fixture stderr")
            self.assertTrue(record["launch_services_captures_archived"])
            self.assertTrue(record["owned_bundle_removed"])
            self.assertFalse(root.exists())

    def test_archive_rejects_symlinked_capture_without_following_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root, evidence, record, captures = self.make_fixture(directory)
            target = Path(directory) / "outside-capture"
            target.write_bytes(b"untouched")
            captures["stdout"].unlink()
            captures["stdout"].symlink_to(target)
            record["application_pid_verified"] = True
            record["application_process_gone"] = True
            with self.assertRaisesRegex(ValueError, "must not be a symlink"):
                NATIVE_PARITY.archive_and_remove_owned_restore_bundle(record, root, evidence)
            self.assertEqual(target.read_bytes(), b"untouched")
            self.assertTrue(root.is_dir())
            self.assertFalse((evidence / "restore.stdout").exists())

    def test_keyboard_bundle_can_archive_only_the_existing_guarded_restore_capture_names(self):
        with tempfile.TemporaryDirectory() as directory:
            root, evidence, record, captures = self.make_fixture(directory)
            record["case"] = "keyboard"
            captures["stdout"].write_bytes(b"keyboard fixture stdout")
            captures["stderr"].write_bytes(b"keyboard fixture stderr")
            record["application_pid_verified"] = True
            record["application_process_gone"] = True
            NATIVE_PARITY.archive_and_remove_owned_restore_bundle(record, root, evidence)
            self.assertEqual((evidence / "restore.stdout").read_bytes(), b"keyboard fixture stdout")
            self.assertEqual((evidence / "restore.stderr").read_bytes(), b"keyboard fixture stderr")
            self.assertTrue(record["launch_services_captures_archived"])
            self.assertTrue(record["owned_bundle_removed"])

    def test_archive_refuses_existing_symlink_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            root, evidence, record, captures = self.make_fixture(directory)
            captures["stdout"].write_bytes(b"fixture stdout")
            target = Path(directory) / "outside-evidence"
            target.write_bytes(b"untouched")
            (evidence / "restore.stdout").symlink_to(target)
            record["application_pid_verified"] = True
            record["application_process_gone"] = True
            with self.assertRaises(FileExistsError):
                NATIVE_PARITY.archive_and_remove_owned_restore_bundle(record, root, evidence)
            self.assertEqual(target.read_bytes(), b"untouched")
            self.assertTrue(root.is_dir())


class NativeOwnedActivationRequestTests(unittest.TestCase):
    def test_request_uses_exact_owned_pid_path_and_stage_ack(self):
        stages = {
            "ordered_front_surface_reveal": "restore.ordered_front_activation",
            "deminiaturized_surface_reveal": "restore.activation",
            "fullscreen_application_reactivation": "restore.fullscreen_reactivation",
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


class NativeFocusCompanionCommandTests(unittest.TestCase):
    def test_command_uses_owned_bundle_guarded_environment_and_software_case(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle = root / "Chau7 Next Native Focus Companion.app"
            stdout_path = root / "companion.stdout"
            stderr_path = root / "companion.stderr"
            environment = {
                "HOME": str(root / "home"),
                "ZDOTDIR": str(root / "home"),
                "CHAU7_NEXT_NATIVE_PARITY_FIXTURE": "1",
                "CHAU7_NEXT_ISOLATED_TEST_MODE": "1",
                "CHAU7_NEXT_HOME_ROOT": str(root / "home"),
                "HISTFILE": "",
            }
            command = NATIVE_PARITY.focus_companion_command(bundle, stdout_path, stderr_path, environment)
        expected = [
            "/usr/bin/open",
            "-n",
            "-W",
            "--stdout",
            str(stdout_path),
            "--stderr",
            str(stderr_path),
        ]
        for name in ("HOME", "ZDOTDIR") + NATIVE_PARITY.ACTIVATION_GUARD_ENV:
            expected.extend(["--env", name + "=" + environment[name]])
        expected.extend(
            [
                str(bundle),
                "--args",
                "--native-parity-fixture",
                "focus-companion",
                "--window-renderer",
                "software",
            ]
        )
        self.assertEqual(command, expected)
        self.assertIn("-n", command)
        self.assertIn("-W", command)


class NativeKeyboardInitialOpenTests(unittest.TestCase):
    def test_initial_open_observes_the_exact_staged_executable_without_ack_handshakes(self):
        class PollingProcess:
            def __init__(self):
                self.values = iter((None, None, 0))

            def poll(self):
                return next(self.values)

        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "Owned Fixture.app"
            executable = bundle / "Contents" / "MacOS" / "chau7-next"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"owned fixture executable")
            process = PollingProcess()
            record = {}
            with (
                mock.patch.object(
                    NATIVE_PARITY,
                    "owned_executable_pids",
                    side_effect=[[1234], [1234]],
                ) as owned_pids,
                mock.patch.object(NATIVE_PARITY.time, "sleep"),
            ):
                NATIVE_PARITY.wait_owned_keyboard_fixture(process, record, bundle)
            expected = executable.resolve(strict=True)
            self.assertEqual(owned_pids.call_count, 2)
            self.assertEqual(owned_pids.call_args_list[0].args[0], expected)
            self.assertEqual(owned_pids.call_args_list[1].args[0], expected)
            self.assertEqual(record["application_process_id_observed"], 1234)
            self.assertTrue(record["application_pid_observed_exact_executable"])
            self.assertEqual(record["application_executable_path"], str(expected))
            self.assertEqual(record["exit_code"], 0)
            self.assertNotIn("activation_request", record)
            self.assertNotIn("ordered_front_activation_request", record)

    def test_initial_open_exit_observed_at_deadline_is_a_timeout(self):
        process = mock.Mock(spec=["poll"])
        process.poll.return_value = 0
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "Owned Fixture.app"
            executable = bundle / "Contents" / "MacOS" / "chau7-next"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"owned fixture executable")
            with (
                mock.patch.object(NATIVE_PARITY.time, "monotonic", side_effect=[0.0, 75.0]),
                mock.patch.object(NATIVE_PARITY, "owned_executable_pids") as owned_pids,
            ):
                record = {}
                result = NATIVE_PARITY.wait_owned_keyboard_fixture(process, record, bundle)
            self.assertIsNone(result)
            self.assertTrue(record["timed_out"])
            self.assertIsNone(record["exit_code"])
            owned_pids.assert_not_called()
            self.assertFalse(hasattr(process, "terminate"))
            self.assertFalse(hasattr(process, "kill"))

    def test_initial_open_rejects_a_changed_application_pid(self):
        class RunningProcess:
            def poll(self):
                return None

        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "Owned Fixture.app"
            executable = bundle / "Contents" / "MacOS" / "chau7-next"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"owned fixture executable")
            with (
                mock.patch.object(
                    NATIVE_PARITY,
                    "owned_executable_pids",
                    side_effect=[[1234], [5678]],
                ),
                mock.patch.object(NATIVE_PARITY.time, "sleep"),
                self.assertRaisesRegex(RuntimeError, "PID changed"),
            ):
                NATIVE_PARITY.wait_owned_keyboard_fixture(RunningProcess(), {}, bundle)

    def test_pid_scan_timeout_expired_retries_without_termination_methods(self):
        process = mock.Mock(spec=["poll"])
        process.poll.side_effect = [None, None, 0]
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "Owned Fixture.app"
            executable = bundle / "Contents" / "MacOS" / "chau7-next"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"owned fixture executable")
            with (
                mock.patch.object(
                    NATIVE_PARITY,
                    "owned_executable_pids",
                    side_effect=[
                        subprocess.TimeoutExpired(cmd=["/bin/ps"], timeout=5),
                        [1234],
                    ],
                ) as owned_pids,
                mock.patch.object(NATIVE_PARITY.time, "monotonic", return_value=0.0),
                mock.patch.object(NATIVE_PARITY.time, "sleep"),
            ):
                record = {}
                NATIVE_PARITY.wait_owned_keyboard_fixture(process, record, bundle)
            self.assertEqual(owned_pids.call_count, 2)
            self.assertEqual(record["application_pid_scan_timeouts"], 1)
            self.assertEqual(record["application_process_id_observed"], 1234)
            self.assertTrue(record["application_pid_observed_exact_executable"])
            self.assertEqual(record["exit_code"], 0)
            self.assertFalse(record.get("timed_out", False))
            self.assertFalse(hasattr(process, "terminate"))
            self.assertFalse(hasattr(process, "kill"))

    def test_pid_scan_timeout_expired_at_outer_deadline_preserves_timeout_metadata(self):
        process = mock.Mock(spec=["poll"])
        process.poll.return_value = None
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "Owned Fixture.app"
            executable = bundle / "Contents" / "MacOS" / "chau7-next"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"owned fixture executable")
            with (
                mock.patch.object(
                    NATIVE_PARITY,
                    "owned_executable_pids",
                    side_effect=subprocess.TimeoutExpired(cmd=["/bin/ps"], timeout=5),
                ) as owned_pids,
                mock.patch.object(
                    NATIVE_PARITY.time,
                    "monotonic",
                    side_effect=[0.0, 74.0, 74.0, 75.0],
                ),
                mock.patch.object(NATIVE_PARITY.time, "sleep") as sleep,
            ):
                record = {}
                NATIVE_PARITY.wait_owned_keyboard_fixture(process, record, bundle)
            self.assertEqual(owned_pids.call_count, 1)
            self.assertEqual(owned_pids.call_args.args[1], 75.0)
            self.assertEqual(record["application_pid_scan_timeouts"], 1)
            self.assertTrue(record["timed_out"])
            self.assertIsNone(record["exit_code"])
            sleep.assert_not_called()
            self.assertFalse(hasattr(process, "terminate"))
            self.assertFalse(hasattr(process, "kill"))

    def test_initial_open_rejects_multiple_exact_bundle_processes(self):
        class RunningProcess:
            def poll(self):
                return None

        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "Owned Fixture.app"
            executable = bundle / "Contents" / "MacOS" / "chau7-next"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"owned fixture executable")
            with (
                mock.patch.object(NATIVE_PARITY, "owned_executable_pids", return_value=[1234, 5678]),
                self.assertRaisesRegex(RuntimeError, "multiple application PIDs"),
            ):
                NATIVE_PARITY.wait_owned_keyboard_fixture(RunningProcess(), {}, bundle)


class NativeParityResultTests(unittest.TestCase):
    def passing_record(self, launch_services):
        return {
            "case": "restore" if launch_services else "settings",
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
            "launcher_process_id": 50 if launch_services else None,
            "process_id": 60,
            "application_process_id": 60,
            "launch_services_captures_archived": True if launch_services else None,
            "owned_bundle_removed": True if launch_services else None,
            "launch_services_initial_open_passed": False,
            "ordered_front_activation_request_passed": False,
            "fullscreen_focus_yield_request_passed": False,
            "activation_request_passed": False,
            "fullscreen_reactivation_request_passed": False,
            "focus_companion": {
                "application_process_id": 70,
                "process_gone": True,
                "bundle_removed": True,
                "home_removed": True,
                "outcome": {
                    "pid": 70,
                    "passed": True,
                    "owned_resources_closed": True,
                    "owned_profile_removed": True,
                    "details": {"stopped_by": "owned_stop_file"},
                },
            },
        }

    def test_launchservices_result_requires_all_four_activation_stages(self):
        for ordered_front_passed in (False, True):
            for focus_yield_passed in (False, True):
                for deminiaturized_passed in (False, True):
                    for fullscreen_reactivation_passed in (False, True):
                        with self.subTest(
                            ordered_front_passed=ordered_front_passed,
                            focus_yield_passed=focus_yield_passed,
                            deminiaturized_passed=deminiaturized_passed,
                            fullscreen_reactivation_passed=fullscreen_reactivation_passed,
                        ):
                            record = self.passing_record(launch_services=True)
                            record["ordered_front_activation_request_passed"] = ordered_front_passed
                            record["fullscreen_focus_yield_request_passed"] = focus_yield_passed
                            record["activation_request_passed"] = deminiaturized_passed
                            record["fullscreen_reactivation_request_passed"] = fullscreen_reactivation_passed
                            self.assertEqual(
                                NATIVE_PARITY.case_passed(record),
                                ordered_front_passed
                                and focus_yield_passed
                                and deminiaturized_passed
                                and fullscreen_reactivation_passed,
                            )

    def test_restore_result_requires_focus_companion_acknowledged_and_retired(self):
        invalidations = (
            ("fullscreen_focus_yield_request_passed", False),
            ("process_gone", False),
            ("bundle_removed", False),
            ("home_removed", False),
            ("outcome.passed", False),
            ("outcome.owned_resources_closed", False),
            ("outcome.owned_profile_removed", False),
            ("outcome.details.stopped_by", "deadline"),
            ("outcome.pid", 71),
        )
        for field, invalid in invalidations:
            with self.subTest(field=field):
                record = self.passing_record(launch_services=True)
                record.update(
                    ordered_front_activation_request_passed=True,
                    fullscreen_focus_yield_request_passed=True,
                    fullscreen_reactivation_request_passed=True,
                    activation_request_passed=True,
                )
                companion = record["focus_companion"]
                if field == "fullscreen_focus_yield_request_passed":
                    record[field] = invalid
                elif field.startswith("outcome.details."):
                    companion["outcome"]["details"][field.rsplit(".", 1)[1]] = invalid
                elif field.startswith("outcome."):
                    companion["outcome"][field.split(".", 1)[1]] = invalid
                else:
                    companion[field] = invalid
                self.assertFalse(NATIVE_PARITY.case_passed(record))

    def test_keyboard_initial_open_passes_without_restore_acknowledgements(self):
        record = self.passing_record(launch_services=True)
        record.update(
            case="keyboard",
            launch_services_initial_open_passed=True,
        )
        self.assertTrue(NATIVE_PARITY.case_passed(record))

    def test_keyboard_launchservices_rejects_launcher_pid_as_application_pid(self):
        record = self.passing_record(launch_services=True)
        record.update(
            case="keyboard",
            launch_services_initial_open_passed=True,
            launcher_process_id=60,
        )
        self.assertFalse(NATIVE_PARITY.case_passed(record))

    def test_keyboard_launchservices_requires_initial_open_and_retirement(self):
        for field, invalid in (
            ("launch_services_initial_open_passed", False),
            ("launch_services_captures_archived", False),
            ("owned_bundle_removed", False),
        ):
            with self.subTest(field=field):
                record = self.passing_record(launch_services=True)
                record.update(case="keyboard", launch_services_initial_open_passed=True)
                record[field] = invalid
                self.assertFalse(NATIVE_PARITY.case_passed(record))

    def test_direct_fixture_result_does_not_require_activation_requests(self):
        record = self.passing_record(launch_services=False)
        self.assertTrue(NATIVE_PARITY.case_passed(record))


if __name__ == "__main__":
    unittest.main()
