# RFC: MAGI Protocol

## Summary

MAGI means Multi Agent Gathering Intelligence.

MAGI is Chau7's multi-agent decision protocol. A user asks one question, Chau7 convenes three isolated agent sessions, the agents deliberate through controlled rounds, MAGI gathers approved evidence when needed, and the run ends with a replayable decision artifact.

The default council is named `magi` and contains three members:

- Melchior: rational, scientific, and systemic judgment.
- Balthasar: protective, continuity, and risk judgment.
- Casper: human, intuitive, and social judgment.

The feature is CLI-first and should work through both `magi` and `MAGI`.

## Goals

- Use real Chau7 shell sessions through MCP.
- Preserve independent reasoning before debate.
- Share only completed round outputs between members.
- Require user approval before evidence collection.
- Produce Markdown, JSON, transcript, graph, replay, and local share artifacts.
- Keep personas editable.
- Make verdicts auditable and reproducible.

## Non-Goals

- Agents do not freely inspect sibling tabs.
- MAGI does not bypass Chau7/MCP permissions.
- Hosted sharing is not part of the first production slice.
- MAGI does not require three different providers; fallback duplication is allowed.

## Configuration

Global configuration lives at:

```text
~/.chau7/magi/config.toml
```

Default editable personas live at:

```text
~/.chau7/magi/personas/melchior.md
~/.chau7/magi/personas/balthasar.md
~/.chau7/magi/personas/casper.md
```

The first-run wizard asks which provider and model class should power each member. Supported model classes are:

```text
fast
balanced
strongest
```

Supported first-run providers are:

```text
codex
claude
gemini
```

Reasoning defaults to:

```text
max
```

The wizard dry-runs each selected provider command with a local version check. If one or more selected providers fail and at least one selected provider passes, MAGI offers to duplicate the failed members onto a passing provider. If all selected providers fail, MAGI still writes the requested editable configuration and reports the failure.

The default policy is:

```text
fallback = duplicate
web = true
evidence_requires_approval = true
deadlock_extra_round = true
veto_blocks = true
```

## Protocol

Each run follows this sequence:

```text
1. Boot MAGI.
2. Create one real Chau7/MCP-controlled shell per member.
3. Inject each member's persona and the user question.
4. Round 1: independent analysis.
5. MAGI collects completed Round 1 outputs.
6. Round 2: MAGI shares completed outputs and asks for critique.
7. MAGI collects critiques and any evidence requests.
8. If evidence was requested, ask the user for approval.
9. Run approved collectors through Chau7/MCP.
10. Round 3: MAGI packages approved evidence.
11. Round 4: final vote.
12. If deadlocked, run one extra round.
13. Resolve majority unless a blocking veto exists.
14. Save artifacts.
```

Round visibility is controlled by MAGI:

```text
Independent analysis: isolated.
Critique/revision: completed outputs only.
Evidence: approved evidence only.
```

## Output Contract

Every agent round must end with one structured JSON block. Marker lines must appear alone on their own lines. MAGI ignores marker names that are merely mentioned inside prompts or prose.

Round 1 position blocks use:

```json
{
  "member": "melchior",
  "round": 1,
  "position": "Final Fantasy VI",
  "summary": "Short rationale.",
  "confidence": 0.82,
  "evidence_requests": [],
  "veto": null
}
```

Critique blocks use:

```json
{
  "member": "melchior",
  "round": 2,
  "critiques": [],
  "evidence_requests": []
}
```

Vote blocks use:

```json
{
  "member": "melchior",
  "round": 4,
  "verdict": "SELECT",
  "vote": "Final Fantasy VI",
  "confidence": 0.82,
  "rationale": "Short rationale.",
  "veto": null
}
```

MAGI validates both `member` and `round`. Raw terminal output is captured for every parsed round. If structured parsing fails, MAGI records the raw output, asks the same agent once to repair/extract a valid structured block from its own transcript, and records the repair transcript. If repair still fails, the run is marked failed and partial artifacts are preserved.

## Evidence

Evidence is a structured request, not informal chat.

```json
{
  "member_id": "balthasar",
  "priority": "high",
  "reason": "Rollback risk cannot be evaluated without deployment context.",
  "required_evidence": ["git_diff", "test_status"]
}
```

Every evidence request must be approved by the user before collectors run.

Initial collectors should stay small:

```text
local.git_status
local.git_diff
local.repo_search:<query>
local.file_read:<path>
local.command:<command>
web.query:<query>
```

All evidence collection requires explicit user approval in MAGI V1, even if an older config sets `evidence_requires_approval = false`.

`local.command` is executed only through Chau7/MCP `tab_exec`, so existing MCP command permissions, prompts, and remote approval flows still apply. Fixed local collectors are also run through Chau7/MCP collector tabs.

`web.query` is allowed when `web_access_allowed = true`, requires the same user approval as local evidence, and is recorded in packet metadata with the query, web-access flag, and collection status. If web access is disabled, MAGI records a skipped evidence packet instead of making a network request.

## Verdicts

Majority decides by default. All members have equal weight. A single deadlock triggers one extra deliberation round. A persona-defined veto blocks the normal majority verdict.

Default verdict states:

```text
APPROVE
REJECT
CONDITIONAL
NEED_EVIDENCE
DEADLOCK
ESCALATE
BLOCKED_BY_VETO
SELECT
RANK
NO_CONSENSUS
```

Generic questions can use `SELECT`, `RANK`, and `NO_CONSENSUS`. Engineering questions can use approve/reject-style verdicts.

For engineering questions, final vote blocks must set `verdict` to one of:

```text
APPROVE
REJECT
CONDITIONAL
NEED_EVIDENCE
ESCALATE
```

For generic questions, final vote blocks must set `verdict` to `SELECT` or `RANK`.

If no majority is reached, MAGI returns `DEADLOCK` and runs one extra deliberation round when `deadlock_extra_round_enabled = true`. If no majority is reached after that extra round, MAGI returns `NO_CONSENSUS`. If any persona issues a blocking veto and `veto_blocks_verdict = true`, MAGI returns `BLOCKED_BY_VETO`.

## Artifacts

When MAGI runs inside a repository, meaning the current directory or an ancestor contains a `.git` directory or `.git` file, artifacts live at the repository root:

```text
.chau7/magi/runs/<run-id>/
```

Outside a repository, artifacts live at:

```text
~/.chau7/magi/runs/<run-id>/
```

Each completed or failed run should write:

```text
decision.md
decision.json
transcript.jsonl
graph.json
replay.jsonl
share.html
```

`magi replay <run-id>` reads `decision.json` and `replay.jsonl` from the repository artifact directory first, then the global artifact directory, and renders the run timeline in the terminal. If `decision.json` is unavailable, it falls back to the replay JSONL lines.

`magi share <run-id>` reads `decision.json` using the same lookup order and generates or refreshes local `share.html`. If only a preexisting `share.html` is available, it reports that file. V1 never uploads hosted share artifacts.

Partial runs should be marked with a failed or interrupted status and preserve any useful transcript and error context.

## Production Readiness

The protocol is production-ready when:

- `swift test` passes.
- `swift build` passes.
- first-run configuration works.
- three real Chau7 tabs spawn through MCP.
- Round 1 isolation is preserved.
- controlled sharing is used for later rounds.
- vetoes block final verdicts.
- deadlocks can trigger one extra round.
- evidence approval is enforced.
- artifacts are complete.
- replay and local share output work.
- failure states are explicit and recoverable.
