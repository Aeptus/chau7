---
name: chau7-magi
description: Use for questions or work items that may benefit from Chau7 MAGI multi-agent deliberation instead of a single-agent direct answer, especially ambiguous decisions, engineering tradeoffs, product choices, code reviews needing independent opinions, or requests involving MAGI artifacts, replay, share, verdicts, council behavior, or the magi CLI.
---

# Chau7 MAGI

Use MAGI when independent perspectives are likely to improve the answer. Prefer a direct answer when the task is simple, factual, low-risk, or already has enough context for one agent to act confidently.

## Decide Direct Answer Or Council Run

Use a direct answer when:

- The user asks for a small factual answer, command, or code edit.
- The answer is obvious from local context.
- A council would add latency without improving correctness.
- The user asks you personally to implement or explain something.

Use `magi` when:

- The user asks for a decision, ranking, approval, review, or recommendation with meaningful tradeoffs.
- Multiple valid answers exist and dissent would be useful.
- The task is high-impact enough that independent critique is worth the cost.
- The user explicitly asks for MAGI, a council, a verdict, replay, share, or multi-agent deliberation.

If unsure, briefly explain the tradeoff and ask whether to run MAGI. Do not run a council just to make a simple answer look more dramatic.

## Invoke MAGI

Use the CLI from the relevant repository or working directory:

```bash
magi "Should we approve this implementation?"
magi ask "Rank these migration options"
magi --mode engineering "Should this patch ship?"
magi --mode generic "What is the best Final Fantasy game?"
magi replay <run-id>
magi share <run-id>
magi doctor
magi config
```

`MAGI` may also work as an uppercase command on case-insensitive systems, but prefer `magi` in examples and scripts.

Use `--mode engineering` for approve/reject/conditional engineering decisions. Use `--mode generic` for subjective selection, ranking, or open-ended questions. If mode is omitted, let the CLI infer it and report the inference.

## Council Integrity

Never fake council output. Do not invent member votes, debate, vetoes, evidence packets, run IDs, or artifacts.

If the CLI cannot run, report the failure and the command attempted. If only a direct answer is possible, label it as your direct answer, not a MAGI verdict.

MAGI agents should not read sibling tabs directly. Chau7 MAGI controls what is shared between members through structured council packets.

## Verdicts And Artifacts

Expect verdicts such as:

- `APPROVE`
- `REJECT`
- `CONDITIONAL`
- `NEED_EVIDENCE`
- `DEADLOCK`
- `ESCALATE`
- `BLOCKED_BY_VETO`
- `SELECT`
- `RANK`
- `NO_CONSENSUS`

After a run, look for the artifact path printed by the CLI. Repository runs normally write under:

```text
.chau7/magi/runs/<run-id>/
```

Common artifacts:

- `decision.md`
- `decision.json`
- `transcript.jsonl`
- `graph.json`
- `replay.jsonl`
- `share.html`
- `technical.jsonl`

Use `magi replay <run-id>` to inspect the timeline in the terminal. Use `magi share <run-id>` to generate or refresh a local `share.html`; do not claim hosted sharing exists unless the CLI says it does.

## Evidence And Approval

Evidence collection is part of deliberation, not decoration. Treat evidence requests as claims that external or local facts could change the verdict.

Respect Chau7 permissions. Do not bypass approval for local commands, file reads, repo searches, git diffs, or web queries. If evidence is denied, continue only within the available record and mention the limitation.
