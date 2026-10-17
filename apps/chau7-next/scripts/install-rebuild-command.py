#!/usr/bin/env python3
"""Install a stable local entrypoint to this checkout's Rust rebuild workflow."""

from __future__ import annotations

import argparse
import os
import shlex
import tempfile
from pathlib import Path

MARKER = "# Managed by Chau7 install-rebuild-command.py"


def launcher_text(repo: Path, target_directory: Path | None = None) -> str:
    lines = [
        "#!/bin/bash",
        MARKER,
        "set -euo pipefail",
        "default_repo=" + shlex.quote(str(repo)),
        'repo="${CHAU7_REBUILD_REPO:-$default_repo}"',
        'script="$repo/apps/chau7-next/scripts/rebuild-macos-production.command"',
        'if [[ ! -f "$script" ]]; then',
        "  printf 'error: Rust rebuild source unavailable: %s\\n' \"$repo\" >&2",
        '  echo "Mount its disk, or rerun install-rebuild-command.py from your current Rust checkout." >&2',
        "  exit 1",
        "fi",
    ]
    if target_directory is not None:
        lines += [
            "# Inject the configured cache only for this checkout; keep explicit caller overrides.",
            'if [[ "$repo" == "$default_repo" ]]; then',
            "  default_target=" + shlex.quote(str(target_directory)),
            '  export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$default_target}"',
            "fi",
        ]
    lines += ['exec /bin/bash "$script" "$@"', ""]
    return "\n".join(lines)


def install_launcher(destination: Path, content: str, dry_run: bool = False) -> None:
    if destination.is_symlink():
        raise ValueError(f"refusing to replace a symlink: {destination}")
    if destination.exists() and (not destination.is_file() or MARKER not in destination.read_text().splitlines()[:3]):
        raise ValueError(f"refusing to replace an unrelated command: {destination}")
    if dry_run:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".chau7-rebuild-", dir=destination.parent)
    temporary_path = Path(temporary)
    try:
        with os.fdopen(fd, "w") as output:
            output.write(content)
            output.flush()
            os.fchmod(output.fileno(), 0o755)
            os.fsync(output.fileno())
        os.replace(temporary_path, destination)
    finally:
        temporary_path.unlink(missing_ok=True)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", type=Path, default=Path.home() / ".local/bin")
    parser.add_argument("--target-directory", type=Path, help="private Cargo cache to reuse for fast builds")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    try:
        if os.geteuid() == 0:
            raise ValueError("run as your normal user, without sudo")
        repo = Path(__file__).resolve().parents[3]
        script = repo / "apps/chau7-next/scripts/rebuild-macos-production.command"
        if not script.is_file():
            raise ValueError(f"Rust rebuild entrypoint missing: {script}")
        destination = args.bin_dir.expanduser().absolute() / "chau7-rebuild"
        target = args.target_directory.expanduser().resolve() if args.target_directory else None
        install_launcher(destination, launcher_text(repo, target), args.dry_run)
        print(("Would install: " if args.dry_run else "Installed: ") + str(destination))
        print(f"Source checkout: {repo}")
        print("In macOS Terminal, run: " + shlex.quote(str(destination)))
        print("No app was built, quit, installed or launched.")
        return 0
    except (OSError, ValueError) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
