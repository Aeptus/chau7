#!/usr/bin/env python3
"""Owned Claude hook: never writes Swift or provider state; failures are non-blocking."""

import datetime
import json
import os
import sys
import uuid

EVENTS_FILE = "__CHAU7_NEXT_EVENTS_FILE__"
CLAUDE_PROJECTS = "__CHAU7_NEXT_CLAUDE_PROJECTS__"
HOOK_TYPES = {
    "UserPromptSubmit": "user_prompt",
    "PreToolUse": "tool_start",
    "PostToolUse": "tool_complete",
    "PostToolUseFailure": "tool_failed",
    "PermissionRequest": "permission_request",
    "Notification": "notification",
    "Stop": "response_complete",
    "StopFailure": "response_failed",
    "SubagentStop": "tool_complete",
    "SessionStart": "session_start",
    "SessionEnd": "session_end",
    "Elicitation": "elicitation",
}


def main():
    tab = os.environ.get("CHAU7_NEXT_TAB_ID", "").strip()
    if os.environ.get("TERM_PROGRAM") != "Chau7Next" or not tab:
        return
    uuid.UUID(tab)
    raw = sys.stdin.buffer.read(1048577)
    if len(raw) > 1048576:
        return
    payload = json.loads(raw) if raw.strip() else {}
    if not isinstance(payload, dict):
        return
    transcript = payload.get("transcript_path") or ""
    if transcript:
        projects = (
            os.path.join(
                os.path.expanduser(os.environ["CLAUDE_CONFIG_DIR"]), "projects"
            )
            if os.environ.get("CLAUDE_CONFIG_DIR")
            else CLAUDE_PROJECTS
        )
        full = os.path.abspath(os.path.expanduser(transcript))
        if os.path.commonpath([full, os.path.abspath(projects)]) != os.path.abspath(
            projects
        ):
            return
    hook = payload.get("hook_event_name", "")
    kind = HOOK_TYPES.get(hook, "unknown")
    if hook == "Notification":
        message = str(payload.get("message") or "").lower()
        if "permission" in message or "approval" in message:
            kind = "permission_request"
    event = {
        "type": kind,
        "hook": hook,
        "sessionId": payload.get("session_id", ""),
        "transcriptPath": transcript,
        "toolName": payload.get("tool_name", ""),
        "toolUseID": payload.get("tool_use_id", ""),
        "message": payload.get("message") or payload.get("prompt") or "",
        "cwd": payload.get("cwd") or os.environ.get("CHAU7_NEXT_PROJECT", ""),
        "tabID": tab,
        "timestamp": datetime.datetime.now(datetime.timezone.utc)
        .isoformat()
        .replace("+00:00", "Z"),
    }
    if hook == "PreToolUse" and payload.get("tool_name") in (
        "AskUserQuestion",
        "ExitPlanMode",
    ):
        tool_input = payload.get("tool_input")
        if (
            tool_input is not None
            and len(json.dumps(tool_input, ensure_ascii=True)) <= 16384
        ):
            event["toolInput"] = tool_input
    os.makedirs(os.path.dirname(EVENTS_FILE), exist_ok=True)
    line = (json.dumps(event, ensure_ascii=True) + "\n").encode("utf-8")
    descriptor = os.open(EVENTS_FILE, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(descriptor, line)
    finally:
        os.close(descriptor)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError, AttributeError):
        sys.exit(0)
