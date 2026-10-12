#!/usr/bin/env python3
"""Run owned macOS parity fixtures and retain exact source/binary evidence."""

import argparse
import hashlib
import json
import os
import platform
import re
import subprocess
import tempfile
import uuid
from pathlib import Path


def output(argv, cwd=None, env=None):
    return subprocess.check_output(argv, cwd=cwd, env=env, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--case", choices=("all", "restore", "settings", "editor"), default="all"
    )
    parser.add_argument(
        "--toolchain",
        default="1.96.0",
        help="Exact already installed Rust release; never installed or upgraded by this script",
    )
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("native parity fixtures require macOS")
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.toolchain):
        parser.error("use an exact Rust version, not a mutable toolchain alias")
    workspace = Path(__file__).resolve().parents[1]
    repo = workspace.parents[1]
    revision = output(["git", "rev-parse", "HEAD"], cwd=repo)
    if output(["git", "status", "--porcelain"], cwd=repo):
        parser.error(
            "commit or preserve source changes before collecting exact-revision evidence"
        )
    architecture = {"arm64": "aarch64", "x86_64": "x86_64"}.get(platform.machine())
    if architecture is None:
        parser.error("unsupported macOS architecture")
    target_triple = f"{architecture}-apple-darwin"
    toolchain_id = f"{args.toolchain}-{target_triple}"
    toolchain = (
        Path(os.environ.get("RUSTUP_HOME", str(Path.home() / ".rustup")))
        / "toolchains"
        / toolchain_id
        / "bin"
    )
    for name in ("cargo", "rustc", "rustdoc"):
        if not (toolchain / name).is_file():
            parser.error(
                f"required already installed executable is missing: {toolchain / name}"
            )
    evidence = Path(tempfile.mkdtemp(prefix="chau7-native-results-")).resolve()
    target = workspace / "target" / "native-parity"
    environment = dict(os.environ)
    environment.update(
        {
            "RUSTUP_TOOLCHAIN": toolchain_id,
            "RUSTC": str(toolchain / "rustc"),
            "RUSTDOC": str(toolchain / "rustdoc"),
            "RUSTC_WRAPPER": "",
            "CARGO_TARGET_DIR": str(target),
            # Dedicated fixture artifacts; normal packaging keeps its release profile.
            "CARGO_PROFILE_RELEASE_LTO": "off",
        }
    )
    manifest = {
        "source_revision": revision,
        "compiler": output([str(toolchain / "rustc"), "--version"]),
        "cargo": output([str(toolchain / "cargo"), "--version"]),
        "fixture_feature": "native-parity-fixture",
        "release_lto": "off",
        "target_triple": target_triple,
        "target_directory": str(target),
        "bundle_build_sha": None,
        "results": [],
    }
    build_log = evidence / "build.log"
    with build_log.open("x") as log:
        build = subprocess.run(
            [
                str(toolchain / "cargo"),
                "build",
                "--release",
                "--locked",
                "--target",
                target_triple,
                "-p",
                "chau7_next",
                "--features",
                "native-parity-fixture",
            ],
            cwd=workspace,
            env=environment,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=False,
        )
    if build.returncode:
        manifest["build_exit_code"] = build.returncode
        (evidence / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(f"Build failed; evidence: {evidence}")
        return 1
    if output(["git", "rev-parse", "HEAD"], cwd=repo) != revision or output(
        ["git", "status", "--porcelain"], cwd=repo
    ):
        print(f"Source changed during build; evidence: {evidence}")
        return 1
    binary = target / target_triple / "release" / "chau7-next"
    digest = hashlib.sha256()
    with binary.open("rb") as artifact:
        for block in iter(lambda: artifact.read(1024 * 1024), b""):
            digest.update(block)
    manifest["binary_sha256"] = digest.hexdigest()
    cases = ("restore", "settings", "editor") if args.case == "all" else (args.case,)
    success = True
    for case in cases:
        # Do not create this directory: the runner validates and creates it.
        home = (
            Path(tempfile.gettempdir()).resolve()
            / f"chau7-native-fixture-{uuid.uuid4()}"
        )
        child_environment = dict(environment)
        child_environment.update(
            {
                "CHAU7_NEXT_HOME_ROOT": str(home),
                "CHAU7_NEXT_ISOLATED_TEST_MODE": "1",
                "CHAU7_NEXT_NATIVE_PARITY_FIXTURE": "1",
                "HISTFILE": "",
            }
        )
        stdout_path = evidence / f"{case}.stdout"
        stderr_path = evidence / f"{case}.stderr"
        with stdout_path.open("x") as stdout, stderr_path.open("x") as stderr:
            process = subprocess.Popen(
                [str(binary), "--native-parity-fixture", case],
                cwd=Path(tempfile.gettempdir()).resolve(),
                env=child_environment,
                stdout=stdout,
                stderr=stderr,
            )
            try:
                exit_code = process.wait(timeout=75)
            except subprocess.TimeoutExpired:
                # Leave an unexpectedly stuck owned process available to diagnose;
                # never send forced signals or silently destroy its evidence.
                manifest["results"].append(
                    {
                        "case": case,
                        "passed": False,
                        "timed_out": True,
                        "process_id": process.pid,
                        "owned_home": str(home),
                    }
                )
                success = False
                break
        outcomes = []
        for line in stdout_path.read_text().splitlines():
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if (
                isinstance(value, dict)
                and value.get("case") == case
                and isinstance(value.get("passed"), bool)
            ):
                outcomes.append(value)
        passed = (
            exit_code == 0
            and len(outcomes) == 1
            and outcomes[0]["passed"]
            and not home.exists()
        )
        manifest["results"].append(
            {
                "case": case,
                "passed": passed,
                "exit_code": exit_code,
                "owned_home_removed": not home.exists(),
                "outcome": outcomes[0] if len(outcomes) == 1 else None,
            }
        )
        success = success and passed
        print(f"{case}: {'PASS' if passed else 'FAIL'}")
    manifest["source_unchanged"] = output(
        ["git", "rev-parse", "HEAD"], cwd=repo
    ) == revision and not output(["git", "status", "--porcelain"], cwd=repo)
    success = success and manifest["source_unchanged"]
    manifest["passed"] = bool(success)
    (evidence / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Evidence: {evidence}")
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
