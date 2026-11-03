#!/usr/bin/env python3
"""Owned notify dispatcher: append Next evidence and compose literal user argv."""

import datetime
import json
import os
import re
import sqlite3
import stat
import subprocess
import sys
import uuid
from contextlib import closing
from itertools import islice
from pathlib import Path

try:
    import tomllib
except ImportError:  # Python before 3.11 keeps the dependency-free fallback.
    tomllib = None

EVENTS_FILE = "__CHAU7_NEXT_EVENTS_FILE__"
CHAIN_ENV = "CHAU7_NEXT_CODEX_NOTIFY_CHAIN"


def first(*values):
    return next(
        (value.strip() for value in values if isinstance(value, str) and value.strip()),
        None,
    )


def valid_chain(value):
    if not isinstance(value, list) or not all(isinstance(part, str) for part in value):
        raise ValueError("notify must be a string array")
    return value


def read_array(text):
    """TOML string arrays without a dependency on Python 3.11's tomllib."""
    index, result = 0, []

    def skip():
        nonlocal index
        while index < len(text):
            if text[index].isspace() or text[index] == ",":
                index += 1
            elif text[index] == "#":
                end = text.find("\n", index)
                index = len(text) if end < 0 else end + 1
            else:
                break

    skip()
    if index >= len(text) or text[index] != "[":
        raise ValueError("notify must be an array")
    index += 1
    while True:
        skip()
        if index >= len(text):
            raise ValueError("unterminated notify array")
        if text[index] == "]":
            return result
        quote = text[index]
        if quote not in ('"', "'"):
            raise ValueError("notify argv must contain strings")
        triple = text.startswith(quote * 3, index)
        marker = quote * (3 if triple else 1)
        index += len(marker)
        if triple and text[index : index + 1] == "\n":
            index += 1
        chars = []
        while index < len(text):
            if text.startswith(marker, index):
                index += len(marker)
                result.append("".join(chars))
                break
            ch = text[index]
            index += 1
            if quote == '"' and ch == "\\":
                if index >= len(text):
                    raise ValueError("unterminated escape")
                esc = text[index]
                index += 1
                if triple and esc.isspace():
                    while index < len(text) and text[index].isspace():
                        index += 1
                    continue
                mapping = {
                    "b": "\b",
                    "t": "\t",
                    "n": "\n",
                    "f": "\f",
                    "r": "\r",
                    '"': '"',
                    "\\": "\\",
                }
                if esc in mapping:
                    chars.append(mapping[esc])
                elif esc in ("u", "U"):
                    length = 4 if esc == "u" else 8
                    code = int(text[index : index + length], 16)
                    chars.append(chr(code))
                    index += length
                else:
                    raise ValueError("unsupported TOML string escape")
            else:
                chars.append(ch)
        else:
            raise ValueError("unterminated notify string")
        # A comma or the closing bracket is required after each string.
        while index < len(text) and text[index].isspace():
            index += 1
        if index < len(text) and text[index] == "#":
            end = text.find("\n", index)
            index = len(text) if end < 0 else end + 1
            while index < len(text) and text[index].isspace():
                index += 1
        if index >= len(text) or text[index] not in ",]":
            raise ValueError("invalid notify array separator")


def configured_notify():
    directory = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
    config = os.path.join(directory, "config.toml")
    try:
        with open(config, encoding="utf-8") as handle:
            content = handle.read(2097153)
    except FileNotFoundError:
        return []
    if len(content.encode("utf-8")) > 2097152:
        raise ValueError("Codex config exceeds 2 MiB")
    if tomllib is None:
        # The current Swift installer uses only the top-level notify key.
        # Stop at a TOML table header; never consume an unrelated table's key.
        match = re.search(r'(?m)^\s*(?:notify|"notify"|\'notify\')\s*=\s*', content)
        if match and not re.search(r"(?m)^\s*\[", content[: match.start()]):
            return read_array(content[match.end() :])
        return []
    config_data = tomllib.loads(content)
    return valid_chain(config_data.get("notify", []))


def own_or_swift_notify(argv):
    if not argv:
        return False
    index = (
        1
        if os.path.basename(argv[0]) in ("python", "python3", "python3.11", "python3.12", "python3.13", "python3.14")
        else 0
    )
    if index >= len(argv):
        return False
    return os.path.basename(argv[index]) in (
        "chau7-codex-notify",
        "chau7-next-codex-notify",
    )


def wrap(real, args):
    chain, forwarded, index = configured_notify(), [], 0
    while index < len(args):
        arg = args[index]
        if arg == "--":
            forwarded.extend(args[index:])
            break
        config_value = None
        consumed = 1
        if arg in ("-c", "--config") and index + 1 < len(args):
            config_value, consumed = args[index + 1], 2
        elif arg.startswith("--config="):
            config_value = arg.split("=", 1)[1]
        elif arg.startswith("-c") and len(arg) > 2:
            config_value = arg[2:]
        if config_value is not None:
            key, equals, value = config_value.partition("=")
            if equals and key.strip().strip("\"'") == "notify":
                chain = read_array(value)
                index += consumed
                continue
        forwarded.extend(args[index : index + consumed])
        index += consumed
    # Swift's helper may write a fixed default file even with its stamp blank.
    # Exclude only an actual recognized helper command, never arbitrary args.
    if own_or_swift_notify(chain):
        chain = []
    os.environ[CHAIN_ENV] = json.dumps(chain)
    os.environ["CHAU7_TAB_ID"] = ""
    # A preserved third-party command can invoke Swift notify indirectly.
    # Its compatibility log override stays scoped to this Next invocation.
    os.environ["CHAU7_AI_EVENTS_LOG"] = EVENTS_FILE
    helper = os.path.abspath(sys.argv[0])
    os.execv(
        real,
        [
            real,
            "-c",
            "notify=" + json.dumps([helper]),
            "-c",
            'tui.notification_condition="always"',
            "-c",
            'tui.notification_method="osc9"',
        ]
        + forwarded,
    )


def foreground_session(session_id):
    """Bounded exact-ID proof, off the UI thread, without transcript body reads.

    A notify hook can run for a subagent in the same native CLI process, even
    for ephemeral threads with no resumable history. A PID or cwd alone cannot
    grant that thread the foreground tab's persistence identity.
    """
    try:
        identity = uuid.UUID(session_id)
    except (ValueError, TypeError, AttributeError):
        return False
    home = Path(os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex"))
    sessions = home / "sessions"
    candidates = []
    if identity.version == 7:
        created = int(identity.hex[:12], 16) / 1000
        for offset in (0, -86400, 86400):
            day = datetime.datetime.fromtimestamp(created + offset, datetime.timezone.utc)  # noqa: UP017 - Python 3.9 macOS compatibility
            folder = sessions / day.strftime("%Y/%m/%d")
            candidates.extend(islice(folder.glob(f"*-{identity}.jsonl"), 4))
    else:
        # Legacy UUIDs have no creation date. Ask only the provider's indexed
        # exact ID; never scan directory history or choose a nearby session.
        databases = sorted(home.glob("state_*.sqlite"), reverse=True)[:4]
        for database in databases:
            try:
                with closing(sqlite3.connect(database.absolute().as_uri() + "?mode=ro", timeout=0.01)) as connection:
                    row = connection.execute(
                        "SELECT rollout_path FROM threads WHERE id = ?", (str(identity),)
                    ).fetchone()
                if row:
                    candidates.append(Path(row[0]))
                    break
            except (OSError, sqlite3.Error, ValueError):
                continue
    for path in candidates:
        try:
            if os.path.commonpath((path.resolve(), sessions.resolve())) != str(sessions.resolve()):
                continue
            descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0))
            with os.fdopen(descriptor, "rb") as transcript:
                if not stat.S_ISREG(os.fstat(transcript.fileno()).st_mode):
                    continue
                line = transcript.readline(65537)
            if len(line) > 65536:
                continue
            record = json.loads(line)
            metadata = record.get("payload") if isinstance(record, dict) else None
            if (
                record.get("type") == "session_meta"
                and isinstance(metadata, dict)
                and metadata.get("id") == str(identity)
                and metadata.get("source") in ("cli", "exec")
            ):
                return True
        except (OSError, ValueError, TypeError, AttributeError):
            continue
    return False


def event_for(payload):
    raw_type = first(payload.get("type")) or "notification"
    message = first(
        payload.get("last-assistant-message"),
        payload.get("last_assistant_message"),
        payload.get("message"),
    )
    metadata = {
        "agent-turn-complete": (
            "Codex finished",
            "Codex finished the current turn.",
            None,
        ),
        "approval-requested": (
            "Codex needs your approval",
            "Codex requested your approval.",
            "permission_prompt",
        ),
        "user-input-requested": (
            "Codex is waiting for input",
            "Codex is waiting for your input.",
            "idle_prompt",
        ),
    }
    title, default, subtype = metadata.get(raw_type, (None, "Codex emitted a notification event.", None))
    session_id = first(payload.get("thread-id"), payload.get("thread_id"))
    verified = foreground_session(session_id)
    event = {
        "source": "codex",
        "type": raw_type,
        "rawType": raw_type,
        "tool": "Codex",
        "message": message or default,
        "ts": datetime.datetime.now(datetime.timezone.utc)  # noqa: UP017 - Python 3.9 macOS compatibility
        .isoformat()
        .replace("+00:00", "Z"),
        "directory": first(payload.get("cwd"), os.environ.get("CHAU7_NEXT_PROJECT")),
        "sessionID": session_id,
        "tabID": os.environ["CHAU7_NEXT_TAB_ID"].strip(),
        "producer": "codex_notify_hook",
        # The native Codex process invokes this helper directly. Child CLIs
        # inherit the tab environment, but have a different process owner.
        "providerProcessID": os.getppid(),
        "reliability": "authoritative" if verified else "fallback",
    }
    if title:
        event["title"] = title
    if subtype:
        event["notificationType"] = subtype
    turn = first(payload.get("turn-id"), payload.get("turn_id"))
    if turn:
        event["turnID"] = turn
    return event


def dispatch(raw):
    try:
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            return
        event = event_for(payload)
        os.makedirs(os.path.dirname(EVENTS_FILE), exist_ok=True)
        line = (json.dumps(event, ensure_ascii=True) + "\n").encode("utf-8")
        descriptor = os.open(EVENTS_FILE, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(descriptor, line)
        finally:
            os.close(descriptor)
    except (OSError, ValueError, TypeError, AttributeError):
        print("Chau7 Next: failed to append owned Codex notification.", file=sys.stderr)
    try:
        argv = valid_chain(json.loads(os.environ.get(CHAIN_ENV, "[]")))
        if argv and not own_or_swift_notify(argv):
            # Do not let an inherited user hook failure block Codex completion.
            subprocess.run(
                argv + [raw],
                timeout=5,
                check=False,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
    except (OSError, ValueError, TypeError, subprocess.SubprocessError):
        return


def main():
    tab = os.environ.get("CHAU7_NEXT_TAB_ID", "").strip()
    if os.environ.get("TERM_PROGRAM") != "Chau7Next" or not tab:
        return 0
    try:
        uuid.UUID(tab)
    except ValueError:
        return 0
    if len(sys.argv) > 2 and sys.argv[1] == "--wrap":
        try:
            wrap(sys.argv[2], sys.argv[3:])
        except (OSError, ValueError, TypeError, AttributeError):
            print(
                "Chau7 Next: cannot compose Codex notify configuration; check notify argv.",
                file=sys.stderr,
            )
            return 2
    raw = sys.argv[-1] if len(sys.argv) > 1 else "{}"
    if len(raw.encode("utf-8")) <= 1048576:
        dispatch(raw)
    return 0


if __name__ == "__main__":
    sys.exit(main())
