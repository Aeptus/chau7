#!/usr/bin/env python3
"""Session-only hook overlay, preserving all explicit Claude settings."""

import json
import os
import sys

OVERLAY = "__CHAU7_NEXT_OVERLAY__"
MAX_SETTINGS = 2 * 1024 * 1024


def read_settings(value):
    if value.lstrip().startswith("{"):
        text = value
    else:
        with open(os.path.expanduser(value), encoding="utf-8") as handle:
            text = handle.read(MAX_SETTINGS + 1)
    if len(text.encode("utf-8")) > MAX_SETTINGS:
        raise ValueError("settings exceed 2 MiB")
    result = json.loads(text)
    if not isinstance(result, dict):
        raise TypeError("settings must be an object")
    return result


def with_overlay(args):
    # Hook arrays are additive across scopes. Combine the user's explicit
    # session-level settings into the one CLI value, keeping every other key.
    remaining, explicit, index = [], None, 0
    while index < len(args):
        value = args[index]
        if value == "--":
            remaining.extend(args[index:])
            break
        if value == "--settings":
            if index + 1 >= len(args):
                raise ValueError("--settings requires a value")
            explicit = read_settings(args[index + 1])
            index += 2
            continue
        if value.startswith("--settings="):
            explicit = read_settings(value.split("=", 1)[1])
            index += 1
            continue
        remaining.append(value)
        index += 1
    settings = explicit or {}
    with open(OVERLAY, encoding="utf-8") as handle:
        overlay = json.load(handle)
    hooks = settings.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise TypeError("hooks must be an object")
    for event, own_entries in overlay.get("hooks", {}).items():
        existing = hooks.setdefault(event, [])
        if not isinstance(existing, list):
            raise TypeError("hook entries must be an array")
        for entry in own_entries:
            if entry not in existing:
                existing.append(entry)
    return ["--settings", json.dumps(settings, separators=(",", ":"))] + remaining


def main():
    real, args = sys.argv[1], sys.argv[2:]
    # Clear even if a shell alias/user rc reintroduced Swift's ownership stamp.
    os.environ["CHAU7_TAB_ID"] = ""
    sessions = (
        not args
        or args[0].startswith("-")
        or args[0]
        not in {
            "auth",
            "config",
            "doctor",
            "install",
            "mcp",
            "plugin",
            "plugins",
            "update",
            "uninstall",
            "setup-token",
            "daemon",
        }
    )
    if (
        sessions
        and not any(arg in ("--help", "-h", "--version", "-v", "--bare", "--safe-mode") for arg in args)
        and os.path.isfile(OVERLAY)
    ):
        try:
            args = with_overlay(args)
        except (OSError, ValueError, TypeError, AttributeError):
            print(
                "Chau7 Next: cannot compose Claude hook settings; check the explicit --settings file.",
                file=sys.stderr,
            )
            return 2
    os.execv(real, [real] + args)
    return 127


if __name__ == "__main__":
    sys.exit(main())
