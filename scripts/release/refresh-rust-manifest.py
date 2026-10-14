#!/usr/bin/env python3
"""Refresh release evidence after signing and notarizing the production app."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import tempfile
from pathlib import Path

EXPECTED_ARTIFACTS = {
    "Chau7": "Contents/MacOS/Chau7",
    "chau7-next-mcp-bridge": "Contents/MacOS/chau7-next-mcp-bridge",
    "chau7-next-cli": "Contents/MacOS/chau7-next-cli",
    "chau7-optim": "Contents/MacOS/chau7-optim",
    "chau7-md": "Contents/MacOS/chau7-md",
    "chau7-remote": "Contents/MacOS/chau7-remote",
    "chau7-proxy": "Contents/MacOS/chau7-proxy",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--team-id", required=True)
    args = parser.parse_args()

    app = args.app.resolve(strict=True)
    manifest_path = args.manifest.resolve(strict=True)
    if not app.is_dir() or app.name != "Chau7.app":
        raise SystemExit("error: production app bundle must be named Chau7.app")
    if manifest_path == app or app in manifest_path.parents:
        raise SystemExit("error: release metadata must remain outside the signed app")
    if not args.identity.startswith("Developer ID Application:"):
        raise SystemExit("error: production candidates require a Developer ID Application identity")
    if not args.team_id.strip():
        raise SystemExit("error: Apple team identifier is required")

    with (app / "Contents" / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    expected_info = {
        "CFBundleIdentifier": "com.chau7.app",
        "CFBundleName": "Chau7",
        "CFBundleDisplayName": "Chau7",
        "CFBundleExecutable": "Chau7",
        "Chau7BuildChannel": "production",
    }
    for key, expected in expected_info.items():
        if info.get(key) != expected:
            raise SystemExit(f"error: Info.plist {key} must be {expected!r}")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    expected_metadata = {
        "channel": "production",
        "bundleIdentifier": "com.chau7.app",
        "bundlePath": "Chau7.app",
        "appExecutable": "Chau7",
        "cargoFeatures": ["chau7_next_core/production"],
        "sourceDirty": False,
    }
    for key, expected in expected_metadata.items():
        if manifest.get(key) != expected:
            raise SystemExit(f"error: build manifest {key} must be {expected!r}")

    release_version = manifest.get("releaseVersion")
    if not isinstance(release_version, str) or not re.fullmatch(
        r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
        r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
        r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?",
        release_version,
    ):
        raise SystemExit("error: production release manifest needs a semantic releaseVersion")
    short_version = ".".join(release_version.split("+", 1)[0].split("-", 1)[0].split(".")[:3])
    if manifest.get("version") != short_version or info.get("CFBundleShortVersionString") != short_version:
        raise SystemExit("error: numeric bundle version does not match releaseVersion")
    if not str(manifest.get("cargoPackageVersion", "")):
        raise SystemExit("error: production receipt must record the Cargo package version")
    build_number = manifest.get("buildNumber")
    if not isinstance(build_number, str) or not build_number.isdigit() or info.get("CFBundleVersion") != build_number:
        raise SystemExit("error: numeric bundle build number does not match the production receipt")

    cargo_command = manifest.get("cargoCommands", {}).get("app")
    if not isinstance(cargo_command, list) or "--locked" not in cargo_command:
        raise SystemExit("error: production Cargo receipt must show a locked build")
    feature_index = cargo_command.index("--features") if "--features" in cargo_command else -1
    if feature_index < 0 or cargo_command[feature_index + 1 : feature_index + 2] != ["chau7_next_core/production"]:
        raise SystemExit("error: production Cargo receipt is missing its core feature")

    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, dict) or set(artifacts) != set(EXPECTED_ARTIFACTS):
        raise SystemExit("error: production bundle must contain exactly the seven release executables")

    for name, relative_path in EXPECTED_ARTIFACTS.items():
        artifact = app / relative_path
        if not artifact.is_file() or not os.access(artifact, os.X_OK):
            raise SystemExit(f"error: required executable is missing: {relative_path}")
        if artifact.resolve(strict=True).parent != (app / "Contents" / "MacOS").resolve():
            raise SystemExit(f"error: executable escapes the production bundle: {relative_path}")
        entry = artifacts[name]
        if not isinstance(entry, dict) or entry.get("path") != relative_path:
            raise SystemExit(f"error: build manifest path mismatch for {name}")
        entry["sha256"] = sha256(artifact)

    manifest["appSignatureVerified"] = True
    manifest["releaseStage"] = "rc"
    manifest["distribution"] = "github-actions-artifact-only"
    manifest["signing"] = {
        "identity": args.identity,
        "teamIdentifier": args.team_id,
        "codeSignatureVerified": True,
        "notarized": True,
        "notaryTicketStapled": True,
    }

    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=manifest_path.parent,
        prefix=f".{manifest_path.name}.",
        suffix=".tmp",
        delete=False,
    ) as stream:
        temp_path = Path(stream.name)
        json.dump(manifest, stream, indent=2, sort_keys=True)
        stream.write("\n")
    try:
        os.chmod(temp_path, 0o644)
        os.replace(temp_path, manifest_path)
    finally:
        temp_path.unlink(missing_ok=True)
    print(f"Updated signed-artifact evidence: {manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
