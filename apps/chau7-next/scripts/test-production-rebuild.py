#!/usr/bin/env python3
"""Synthetic tests for the Rust production rebuild coordinator and launcher."""

import hashlib
import importlib.util
import io
import json
import os
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime
from pathlib import Path
from unittest import mock


def load_script_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load script module: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


SCRIPTS = Path(__file__).resolve().parent
INSTALLER = load_script_module("chau7_install_rebuild_command_tests", SCRIPTS / "install-rebuild-command.py")
REBUILD = load_script_module("chau7_rebuild_production_tests", SCRIPTS / "rebuild-macos-production.py")
REVISION = "0123456789abcdef0123456789abcdef01234567"
CHANGED_REVISION = "fedcba9876543210fedcba9876543210fedcba98"
INSTALLED_BUILD = "202610160001"


class RebuildLauncherInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="chau7-rebuild-installer-", dir="/private/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "checkout with spaces ' quote ; $literal"
        self.target = self.root / "private cache ; $literal (fast)"
        self.log = self.root / "fake-rebuild.log"
        self.make_fake_checkout(self.repo)

    @staticmethod
    def make_fake_checkout(repo):
        script = repo / "apps/chau7-next/scripts/rebuild-macos-production.command"
        script.parent.mkdir(parents=True, exist_ok=True)
        script.write_text(
            '#!/bin/bash\nset -euo pipefail\nprintf \'%s\\0\' "${CARGO_TARGET_DIR-__unset__}" "$@" > "$REBUILD_LOG"\n',
            encoding="utf-8",
        )
        script.chmod(0o755)

    def launcher(self, repo=None, target=None):
        repo = repo or self.repo
        destination = self.root / "local bin with spaces" / "chau7-rebuild"
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(
            INSTALLER.launcher_text(repo, self.target if target is None else target),
            encoding="utf-8",
        )
        destination.chmod(0o755)
        return destination

    def run_launcher(self, launcher, *arguments, env=None):
        environment = os.environ.copy()
        environment.pop("CARGO_TARGET_DIR", None)
        environment.pop("CHAU7_REBUILD_REPO", None)
        environment["REBUILD_LOG"] = str(self.log)
        if env:
            environment.update(env)
        return subprocess.run(
            ["/bin/bash", str(launcher), *arguments],
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_launcher_quotes_paths_and_forwards_arguments_without_splitting(self):
        launcher = self.launcher()
        result = self.run_launcher(launcher, "arg with spaces", "--release-version", "1.2.3")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.log.read_bytes().split(b"\0")[:-1],
            [str(self.target).encode(), b"arg with spaces", b"--release-version", b"1.2.3"],
        )

    def test_caller_cache_override_wins_over_configured_fast_cache(self):
        launcher = self.launcher()
        caller_cache = self.root / "caller selected cache"
        result = self.run_launcher(launcher, "--no-install", env={"CARGO_TARGET_DIR": str(caller_cache)})

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.log.read_bytes().split(b"\0")[:-1][0],
            str(caller_cache).encode(),
        )

    def test_alternate_checkout_does_not_inherit_configured_checkout_cache(self):
        alternate = self.root / "alternate checkout with spaces"
        alternate_log = self.root / "alternate.log"
        self.make_fake_checkout(alternate)
        launcher = self.launcher()
        result = self.run_launcher(
            launcher,
            "--debug",
            env={
                "CHAU7_REBUILD_REPO": str(alternate),
                "REBUILD_LOG": str(alternate_log),
            },
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            alternate_log.read_bytes().split(b"\0")[:-1],
            [b"__unset__", b"--debug"],
        )

    def test_install_launcher_dry_run_creates_nothing(self):
        destination = self.root / "not created" / "bin" / "chau7-rebuild"
        content = INSTALLER.launcher_text(self.repo, self.target)

        INSTALLER.install_launcher(destination, content, dry_run=True)

        self.assertFalse(destination.parent.exists())
        self.assertFalse(destination.exists())

    def test_install_launcher_refuses_unrelated_file_and_symlink(self):
        parent = self.root / "bin"
        parent.mkdir()
        destination = parent / "chau7-rebuild"
        destination.write_text("#!/bin/bash\necho unrelated\n", encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "unrelated command"):
            INSTALLER.install_launcher(destination, "managed", dry_run=False)

        link = parent / "linked-rebuild"
        target = self.root / "target file"
        target.write_text("synthetic", encoding="utf-8")
        link.symlink_to(target)
        with self.assertRaisesRegex(ValueError, "symlink"):
            INSTALLER.install_launcher(link, "managed", dry_run=False)

        self.assertEqual(target.read_text(encoding="utf-8"), "synthetic")

    def test_install_launcher_allows_atomic_replacement_of_managed_file(self):
        destination = self.root / "bin" / "chau7-rebuild"
        destination.parent.mkdir()
        destination.write_text(
            "#!/bin/bash\n" + INSTALLER.MARKER + "\nold\n",
            encoding="utf-8",
        )
        destination.chmod(0o755)

        INSTALLER.install_launcher(destination, "#!/bin/bash\nnew\n")

        self.assertEqual(destination.read_text(encoding="utf-8"), "#!/bin/bash\nnew\n")
        self.assertEqual(destination.stat().st_mode & 0o777, 0o755)


class SyntheticRunner:
    def __init__(self, tests):
        self.tests = tests
        self.calls = []
        self.events = []
        self.revision_calls = 0
        self.status_calls = 0
        self.revision_after_build = None
        self.dirty_status_calls = set()
        self.build_status = 0
        self.dry_run_status = 0
        self.dry_run_stdout = "Recovery report: recovered 2 snapshots.\n"
        self.apply_status = 0
        self.candidate_info_overrides = {}
        self.receipt_overrides = {}
        self.tamper_installed = False
        self.build_environments = []
        self.candidate_paths = []

    @staticmethod
    def result(returncode=0, stdout="", stderr=""):
        return types.SimpleNamespace(returncode=returncode, stdout=stdout, stderr=stderr)

    def __call__(self, argv, **options):
        argv = list(argv)
        self.calls.append(
            {
                "argv": argv,
                "cwd": options.get("cwd"),
                "env": dict(options["env"]) if options.get("env") is not None else None,
                "capture_output": options.get("capture_output", False),
            }
        )

        if argv and argv[0] == "git":
            if argv[3:5] == ["rev-parse", "HEAD"]:
                self.revision_calls += 1
                revision = self.tests.revision
                if self.revision_after_build and self.revision_calls >= 2:
                    revision = self.revision_after_build
                return self.result(stdout=revision + "\n")
            if argv[3:5] == ["status", "--porcelain"] and "--untracked-files=all" in argv:
                self.status_calls += 1
                status = " M synthetic-source-file\n" if self.status_calls in self.dirty_status_calls else ""
                return self.result(stdout=status)
            raise AssertionError(f"unexpected git command in fake runner: {argv}")

        if argv[:1] == ["/bin/bash"] and len(argv) > 1:
            if argv[1] == str(self.tests.root / REBUILD.BUILD_SCRIPT):
                self.events.append("build")
                environment = self.calls[-1]["env"]
                self.build_environments.append(environment)
                if self.build_status != 0:
                    return self.result(self.build_status, stderr="synthetic package build failed")
                self.write_candidate(environment)
                return self.result()
            if argv[1] == str(self.tests.root / REBUILD.UPDATER_SCRIPT):
                if "--dry-run" in argv:
                    self.events.append("updater-dry-run")
                    return self.result(self.dry_run_status, self.dry_run_stdout, "")
                if "--apply" in argv:
                    self.events.append("updater-apply")
                    if self.apply_status != 0:
                        return self.result(self.apply_status, stderr="synthetic updater apply failed")
                    app_path = Path(argv[argv.index("--app") + 1])
                    installed = self.tests.services.installed_app
                    if installed.exists():
                        shutil.rmtree(installed)
                    shutil.copytree(app_path, installed)
                    if self.tamper_installed:
                        artifact = installed / self.tests.updater_core.ARTIFACTS["Chau7"]
                        artifact.write_bytes(b"modified after synthetic install")
                    return self.result()
            raise AssertionError(f"unexpected Bash command in fake runner: {argv}")

        if argv and argv[0] == str(self.tests.services.open_path):
            self.events.append("open")
            return self.result()

        raise AssertionError(f"unexpected command reached fake runner: {argv}")

    def write_candidate(self, environment):
        output = Path(environment["OUT_DIR"])
        app = output / "Chau7.app"
        self.tests.write_bundle(
            app,
            revision=self.tests.revision,
            build_number=environment["BUILD_NUMBER"],
            release_version=environment["RELEASE_VERSION"],
            info_overrides=self.candidate_info_overrides,
            write_receipt=False,
        )
        receipt = {
            "channel": "production",
            "buildMode": environment["BUILD_MODE"],
            "target": environment["TARGET"],
            "sourceRevision": self.tests.revision,
            "sourceDirty": False,
            "bundleIdentifier": "com.chau7.app",
            "appExecutable": "Chau7",
            "releaseVersion": environment["RELEASE_VERSION"],
            "buildNumber": environment["BUILD_NUMBER"],
            "appSignatureVerified": True,
            "cargoFeatures": ["chau7_next_core/production"],
            "artifacts": self.tests.artifact_receipt(app),
        }
        receipt.update(self.receipt_overrides)
        receipt_path = output / f"Chau7-Production-{environment['TARGET']}-{environment['BUILD_MODE']}.json"
        receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
        self.candidate_paths.append((app, receipt_path))


class RebuildCoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(
            prefix="chau7 rebuild coordinator with spaces ", dir="/private/tmp"
        )
        self.addCleanup(self.temporary.cleanup)
        self.temp_root = Path(self.temporary.name)
        self.root = self.temp_root / "fake checkout with spaces ; $literal"
        self.root.mkdir()
        self.home = self.temp_root / "fake home"
        self.home.mkdir()
        self.installed_app = self.temp_root / "private Applications" / "Chau7.app"
        self.revision = REVISION
        self.now = datetime(2026, 10, 17, 12, 34).timestamp()
        self.make_checkout()
        self.services = REBUILD.Services(
            root=self.root,
            installed_app=self.installed_app,
            runner=None,
            environ={"HOME": str(self.home)},
            platform_name="darwin",
            machine_name=platform.machine(),
            clock=lambda: self.now,
            pid=lambda: 4242,
            euid=lambda: 501,
            parent_pid=lambda: 1,
            open_path=self.temp_root / "fake open command",
            ps_path=self.temp_root / "fake ps command",
        )
        self.runner = SyntheticRunner(self)
        self.services.runner = self.runner
        self.updater_core = REBUILD.updater_core(self.services)
        signature = mock.patch.object(self.updater_core, "verify_code_signature", return_value=None)
        self.signature_verifier = signature.start()
        self.addCleanup(signature.stop)
        self.write_bundle(
            self.installed_app,
            revision=self.revision,
            build_number=INSTALLED_BUILD,
            release_version="0.6.0",
            write_receipt=False,
        )

    def make_checkout(self):
        build_script = self.root / REBUILD.BUILD_SCRIPT
        build_script.parent.mkdir(parents=True, exist_ok=True)
        build_script.write_text("#!/bin/bash\n# intercepted by the synthetic runner\n", encoding="utf-8")
        updater_script = self.root / REBUILD.UPDATER_SCRIPT
        updater_script.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(SCRIPTS / REBUILD.UPDATER_SCRIPT.name, updater_script)
        cargo_manifest = self.root / REBUILD.APP_WORKSPACE / "Cargo.toml"
        cargo_manifest.parent.mkdir(parents=True, exist_ok=True)
        cargo_manifest.write_text('[package]\nname = "synthetic"\nversion = "0.0.0"\n', encoding="utf-8")

    def artifact_receipt(self, bundle):
        result = {}
        for name, relative in self.updater_core.ARTIFACTS.items():
            path = bundle.joinpath(*Path(relative).parts)
            result[name] = {
                "path": relative,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            }
        return result

    def write_bundle(
        self,
        bundle,
        *,
        revision,
        build_number,
        release_version,
        info_overrides=None,
        write_receipt=False,
    ):
        contents = bundle / "Contents"
        executable_dir = contents / "MacOS"
        executable_dir.mkdir(parents=True, exist_ok=True)
        info = {
            "CFBundleIdentifier": "com.chau7.app",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "Chau7",
            "CFBundleVersion": str(build_number),
            "CFBundleShortVersionString": REBUILD.version_core(release_version),
            "Chau7BuildChannel": "production",
            "Chau7SourceRevision": revision,
        }
        if info_overrides:
            info.update(info_overrides)
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        for name, relative in self.updater_core.ARTIFACTS.items():
            artifact = bundle.joinpath(*Path(relative).parts)
            artifact.parent.mkdir(parents=True, exist_ok=True)
            artifact.write_bytes(("synthetic Rust artifact " + name).encode())
            artifact.chmod(0o755)
        if write_receipt:
            (bundle / "receipt.json").write_text("{}", encoding="utf-8")

    def run_main(self, argv):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            status = REBUILD.main(argv, self.services)
        return status, stdout.getvalue(), stderr.getvalue()

    def build_calls(self):
        return [
            call
            for call in self.runner.calls
            if call["argv"][:1] == ["/bin/bash"]
            and len(call["argv"]) > 1
            and call["argv"][1] == str(self.root / REBUILD.BUILD_SCRIPT)
        ]

    def updater_calls(self):
        return [
            call
            for call in self.runner.calls
            if call["argv"][:1] == ["/bin/bash"]
            and len(call["argv"]) > 1
            and call["argv"][1] == str(self.root / REBUILD.UPDATER_SCRIPT)
        ]

    def test_dry_run_is_read_only_and_never_builds_or_runs_updater(self):
        target = self.root / REBUILD.APP_WORKSPACE / "target"

        status, stdout, stderr = self.run_main(["--dry-run"])

        self.assertEqual(status, 0, stderr)
        self.assertIn(f"persistent Cargo cache: {target}", stdout)
        self.assertFalse(target.exists())
        self.assertEqual(self.build_calls(), [])
        self.assertEqual(self.updater_calls(), [])
        self.assertNotIn("open", self.runner.events)
        self.assertTrue(all(call["argv"][0] == "git" for call in self.runner.calls))

    def test_fast_and_diagnostic_builds_use_separate_ignored_caches_and_spaced_paths(self):
        fast_status, _, fast_stderr = self.run_main(["--no-install"])
        self.assertEqual(fast_status, 0, fast_stderr)
        diagnostic_status, _, diagnostic_stderr = self.run_main(["--no-install", "--debug"])
        self.assertEqual(diagnostic_status, 0, diagnostic_stderr)

        calls = self.build_calls()
        self.assertEqual(len(calls), 2)
        fast_env, diagnostic_env = (call["env"] for call in calls)
        target = self.root / REBUILD.APP_WORKSPACE / "target"
        self.assertEqual(Path(fast_env["CARGO_TARGET_DIR"]), target)
        self.assertEqual(Path(diagnostic_env["CARGO_TARGET_DIR"]), target / "diagnostic")
        self.assertNotEqual(fast_env["CARGO_TARGET_DIR"], diagnostic_env["CARGO_TARGET_DIR"])
        self.assertTrue(Path(fast_env["OUT_DIR"]).is_relative_to(target / "production-local"))
        self.assertTrue(Path(diagnostic_env["OUT_DIR"]).is_relative_to(target / "production-local"))
        self.assertFalse((self.root / "target").exists())
        for call in calls:
            self.assertEqual(call["argv"], ["/bin/bash", str(self.root / REBUILD.BUILD_SCRIPT)])
            self.assertEqual(call["cwd"], str(self.root / REBUILD.APP_WORKSPACE))
            self.assertIn(" ", call["argv"][1])
        self.assertEqual(self.updater_calls(), [])
        self.assertNotIn("open", self.runner.events)

    def test_release_build_number_advances_from_installed_date_and_never_downgrades(self):
        self.assertEqual(
            REBUILD.next_build_number(INSTALLED_BUILD, self.now),
            "202610171234",
        )
        self.assertGreater(
            int(REBUILD.next_build_number(INSTALLED_BUILD, self.now)),
            int(INSTALLED_BUILD),
        )
        self.assertEqual(
            REBUILD.next_build_number("209912312359", self.now),
            "209912312360",
        )

        status, _, stderr = self.run_main(["--no-install"])
        self.assertEqual(status, 0, stderr)
        build_number = self.runner.build_environments[0]["BUILD_NUMBER"]
        self.assertEqual(build_number, "202610171234")
        self.assertGreater(int(build_number), int(INSTALLED_BUILD))

    def test_dirty_source_blocks_build_before_cache_or_output_creation(self):
        self.runner.dirty_status_calls.add(1)

        status, _, stderr = self.run_main(["--no-install"])

        self.assertEqual(status, 1)
        self.assertIn("source tree is dirty", stderr)
        self.assertEqual(self.build_calls(), [])
        self.assertEqual(self.updater_calls(), [])
        self.assertFalse((self.root / REBUILD.APP_WORKSPACE / "target").exists())

    def test_source_revision_change_after_build_blocks_updater(self):
        self.runner.revision_after_build = CHANGED_REVISION

        status, _, stderr = self.run_main(["--no-install"])

        self.assertEqual(status, 1)
        self.assertIn("source revision changed during", stderr)
        self.assertEqual(len(self.build_calls()), 1)
        self.assertEqual(self.updater_calls(), [])
        self.assertEqual(self.runner.events, ["build"])

    def test_source_becoming_dirty_after_build_blocks_updater(self):
        self.runner.dirty_status_calls.add(2)

        status, _, stderr = self.run_main(["--no-install"])

        self.assertEqual(status, 1)
        self.assertIn("source tree became dirty", stderr)
        self.assertEqual(self.runner.events, ["build"])
        self.assertEqual(self.updater_calls(), [])

    def test_source_becoming_dirty_before_apply_blocks_mutation(self):
        self.runner.dirty_status_calls.add(3)

        status, _, stderr = self.run_main(["--no-launch"])

        self.assertEqual(status, 1)
        self.assertIn("source tree became dirty", stderr)
        self.assertEqual(self.runner.events, ["build", "updater-dry-run"])
        self.assertEqual(len(self.updater_calls()), 1)
        self.assertNotIn("open", self.runner.events)

    def test_root_user_is_rejected_before_build_only_cache_creation(self):
        self.services.euid = lambda: 0
        target = self.root / REBUILD.APP_WORKSPACE / "target"

        status, _, stderr = self.run_main(["--no-install"])

        self.assertEqual(status, 1)
        self.assertIn("never with sudo", stderr)
        self.assertEqual(self.build_calls(), [])
        self.assertEqual(self.updater_calls(), [])
        self.assertFalse(target.exists())

    def test_updater_environment_clears_isolated_profile_overrides(self):
        self.services.environ = {
            "HOME": str(self.home),
            "CHAU7_HOME_ROOT": str(self.temp_root / "wrong home"),
            "CHAU7_ISOLATED_TEST_MODE": "1",
            "CHAU7_NEXT_ISOLATED_TEST_MODE": "1",
            "CFFIXED_USER_HOME": str(self.temp_root / "fixed home"),
            "CHAU7_NEXT_HOME_ROOT": str(self.temp_root / "next home"),
        }

        environment = REBUILD.updater_environment(self.services)

        for key in (
            "CHAU7_HOME_ROOT",
            "CHAU7_ISOLATED_TEST_MODE",
            "CHAU7_NEXT_ISOLATED_TEST_MODE",
            "CFFIXED_USER_HOME",
        ):
            self.assertNotIn(key, environment)
        self.assertEqual(
            environment["CHAU7_NEXT_HOME_ROOT"],
            str(self.temp_root / "next home"),
        )
        self.assertIn("CHAU7_HOME_ROOT", self.services.environ)

    def test_candidate_rust_metadata_is_revalidated_before_updater(self):
        self.runner.candidate_info_overrides["Chau7BuildChannel"] = "next"

        status, _, stderr = self.run_main(["--no-install"])

        self.assertEqual(status, 1)
        self.assertIn("candidate is not marked as the production channel", stderr)
        self.assertEqual(self.runner.events, ["build"])
        self.assertEqual(self.updater_calls(), [])
        self.signature_verifier.assert_not_called()

    def test_installed_rust_metadata_is_revalidated_before_any_build(self):
        info_path = self.installed_app / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["Chau7BuildChannel"] = "next"
        info_path.write_bytes(plistlib.dumps(info))

        status, _, stderr = self.run_main(["--no-install"])

        self.assertEqual(status, 1)
        self.assertIn("installed target is not marked production", stderr)
        self.assertEqual(self.build_calls(), [])
        self.assertEqual(self.updater_calls(), [])
        self.signature_verifier.assert_not_called()

    def test_no_install_is_allowed_in_a_chau7_session_and_skips_updater(self):
        self.services.environ = {"HOME": str(self.home), "TERM_PROGRAM": "Chau7"}

        status, stdout, stderr = self.run_main(["--no-install"])

        self.assertEqual(status, 0, stderr)
        self.assertIn("Build-only mode", stdout)
        self.assertEqual(len(self.build_calls()), 1)
        self.assertEqual(self.updater_calls(), [])
        self.assertEqual(self.runner.events, ["build"])
        self.assertNotIn("open", self.runner.events)

    def test_install_inside_chau7_is_rejected_before_build(self):
        self.services.environ = {"HOME": str(self.home), "TERM_PROGRAM": "Chau7"}

        status, _, stderr = self.run_main(["--no-launch"])

        self.assertEqual(status, 1)
        self.assertIn("cannot run from a Chau7 terminal", stderr)
        self.assertEqual(self.build_calls(), [])
        self.assertEqual(self.updater_calls(), [])
        self.assertEqual(self.runner.events, [])

    def test_optimizer_environment_marker_does_not_misidentify_external_terminal(self):
        self.services.environ = {
            "HOME": str(self.home),
            "CHAU7_CTO_OPTIM_ACTIVE": "1",
        }

        status, _, stderr = self.run_main(["--no-launch"])

        self.assertEqual(status, 0, stderr)
        self.assertEqual(self.runner.events, ["build", "updater-dry-run", "updater-apply"])
        self.assertEqual(len(self.updater_calls()), 2)
        self.assertNotIn("open", self.runner.events)

    def test_recovered_snapshot_prose_does_not_block_successful_updater_dry_run(self):
        self.runner.dry_run_stdout = "Recovered 2 snapshots before installation.\n"

        status, stdout, stderr = self.run_main(["--no-launch"])

        self.assertEqual(status, 0, stderr)
        self.assertIn("Recovered 2 snapshots", stdout)
        self.assertEqual(self.runner.events, ["build", "updater-dry-run", "updater-apply"])
        self.assertNotIn("open", self.runner.events)
        self.signature_verifier.assert_called()

    def test_updater_dry_run_failure_stops_before_apply_or_open(self):
        self.runner.dry_run_status = 4

        status, _, stderr = self.run_main([])

        self.assertEqual(status, 1)
        self.assertIn("guarded updater dry-run failed", stderr)
        self.assertEqual(self.runner.events, ["build", "updater-dry-run"])
        self.assertEqual(len(self.updater_calls()), 1)

    def test_updater_apply_failure_stops_before_open(self):
        self.runner.apply_status = 5

        status, _, stderr = self.run_main([])

        self.assertEqual(status, 1)
        self.assertIn("guarded updater apply failed", stderr)
        self.assertEqual(self.runner.events, ["build", "updater-dry-run", "updater-apply"])
        self.assertNotIn("open", self.runner.events)

    def test_installed_artifact_hash_failure_stops_before_open(self):
        self.runner.tamper_installed = True

        status, _, stderr = self.run_main([])

        self.assertEqual(status, 1)
        self.assertIn("receipt executable hash differs", stderr)
        self.assertEqual(
            self.runner.events,
            ["build", "updater-dry-run", "updater-apply"],
        )
        self.assertNotIn("open", self.runner.events)

    def test_success_validates_installed_app_before_launch(self):
        original = REBUILD.verify_installed_candidate

        def track_validation(*args, **kwargs):
            self.runner.events.append("validate-installed")
            return original(*args, **kwargs)

        with mock.patch.object(REBUILD, "verify_installed_candidate", side_effect=track_validation) as validate:
            status, _, stderr = self.run_main([])

        self.assertEqual(status, 0, stderr)
        self.assertEqual(
            self.runner.events,
            ["build", "updater-dry-run", "updater-apply", "validate-installed", "open"],
        )
        validate.assert_called_once()
        self.signature_verifier.assert_called()

    def test_no_launch_leaves_successfully_installed_app_closed(self):
        status, stdout, stderr = self.run_main(["--no-launch"])

        self.assertEqual(status, 0, stderr)
        self.assertIn("Launch skipped", stdout)
        self.assertEqual(self.runner.events, ["build", "updater-dry-run", "updater-apply"])
        self.assertNotIn("open", self.runner.events)

    def test_build_failure_stops_before_apply_or_open(self):
        self.runner.build_status = 7

        status, _, stderr = self.run_main([])

        self.assertEqual(status, 1)
        self.assertIn("production package build failed", stderr)
        self.assertEqual(self.runner.events, ["build"])
        self.assertEqual(self.updater_calls(), [])

    def test_candidate_receipt_version_mismatch_stops_before_updater(self):
        self.runner.receipt_overrides["releaseVersion"] = "0.9.0"

        status, _, stderr = self.run_main(["--no-install", "--release-version", "0.8.0"])

        self.assertEqual(status, 1)
        self.assertIn("production receipt does not match expected releaseVersion", stderr)
        self.assertEqual(self.runner.events, ["build"])
        self.assertEqual(self.updater_calls(), [])


if __name__ == "__main__":
    unittest.main()
