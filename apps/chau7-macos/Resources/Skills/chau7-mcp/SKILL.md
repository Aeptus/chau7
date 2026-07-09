---
name: chau7-mcp
description: Use when controlling Chau7 through its MCP server, orchestrating tabs or AI sessions, launching agents, collecting terminal output, diagnosing Chau7 MCP failures, inspecting logs, or reasoning about Chau7 permissions and safety boundaries, especially to avoid unsafe tab/session operations or killing Chau7 itself.
---

# Chau7 MCP

Chau7 MCP lets agents control Chau7 terminal tabs and sessions through a structured tool boundary. Use it to launch agents, submit prompts, read outputs, inspect runtime events, and gather diagnostics without scraping the app UI manually.

## Safe Orchestration

Prefer high-level Chau7 MCP operations when available. Use low-level tab operations only when the high-level tool does not cover the workflow.

When launching or coordinating agents:

- Create or select the intended tab explicitly.
- Use the requested working directory.
- Wait for provider readiness before submitting prompts.
- Check prompt visibility/submission/running status when the MCP response provides those fields.
- Collect output through runtime events first when available; fetch PTY tails only when needed.
- Keep each agent isolated unless the orchestrator intentionally shares a structured packet.

Do not assume a tab is ready because it exists. A created tab, a visible prompt, and a running provider are different states.

## Permission Boundaries

Respect the permission model exposed by Chau7 and the active agent provider.

- Do not bypass prompts for file access, shell commands, web access, or destructive operations.
- Do not use MCP to hide side effects from the user.
- Do not grant broader permissions than the task needs.
- Do not treat a failed or denied permission as success.

If an MCP tool reports a permission or readiness failure, surface that failure clearly and preserve the run or diagnostic artifacts when possible.

## Logs And Diagnostics

Use Chau7 diagnostics before guessing. Helpful places include:

- Per-run technical logs such as `.chau7/magi/runs/<run-id>/technical.jsonl`
- MAGI artifacts under `.chau7/magi/runs/<run-id>/`
- Chau7 logs at `~/Library/Logs/Chau7.log`
- Chau7 debug reports and snapshots under `~/.chau7/reports/` and `~/.chau7/snapshots/`
- MCP tool responses, especially structured fields for tab IDs, launch status, prompt submission, events, and errors

When reporting a failure, include the tool or command used, the tab ID when available, the relevant artifact/log path, and the precise failure message.

## Never Kill Chau7

Do not kill, restart, force-quit, or relaunch the Chau7 app unless the user explicitly asks for that action.

If the MCP server appears stale, missing, or wedged:

- Diagnose the socket and logs first.
- Prefer restarting only helper processes when there is a dedicated safe path.
- Ask before any action that could interrupt the user's running Chau7 app or live agent sessions.

Chau7 may be the host application the user is actively using. Treat it as production state, not a disposable test process.

## Tab And Session Hygiene

Name tabs clearly when orchestrating multi-agent work. Close temporary collector tabs when the workflow is done, unless the user asked to keep them for debugging.

Avoid reading unrelated tabs. If a workflow needs output from another tab, use the orchestrator's intended sharing mechanism or ask the user.

Prefer small output tails for progress and full output only for parsing, repair, replay, or failure analysis.
