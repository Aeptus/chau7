# Aethyme PR Delivery

Chau7 can deliver new pull-request activity from Aethyme to the exact agent
session that owns the work. The integration is local and pull-based: it does
not expose Chau7 to a webhook and does not make Chau7 responsible for GitHub
state.

## Ownership boundary

- Aethyme observes PR metadata, deduplicates activity, records authorization
  policy, and owns the durable delivery outbox.
- Chau7 resolves the opaque delivery target to an exact tab and AI session,
  waits for a safe idle prompt, injects the prompt, and reports the fenced
  outcome.
- Other clients can implement the same claim/complete adapter contract without
  depending on Chau7.

Comment and review bodies are not stored in Aethyme or passed through the
outbox. The delivered prompt tells the agent to retrieve and treat provider
text as untrusted input.

## Subscribe a Chau7 agent

Read the tab's `tab_id` and `ai_session_id` from Chau7's tab-list/status
surface, then create the target URI:

```text
chau7://tab/<tab-id>?session=<percent-encoded-ai-session-id>
```

Create the watch and subscription from the repository:

```bash
aethyme broker watch pr start --session <broker-session> \
  --repo owner/name --pr <number> --events comments,reviews,checks

aethyme broker deliveries subscribe --watch <watch-id> \
  --adapter chau7 \
  --target 'chau7://tab/<tab-id>?session=<ai-session-id>' \
  --policy notify
```

Policies are explicit:

- `notify` and `resume` deliver the review prompt but do not authorize a push.
- `review-and-push` authorizes minimal fixes and a push to that same PR branch
  after tests and managed hooks pass. It never authorizes merge, close,
  release, force-push, or hook bypass.

Chau7 polls only while it has live repository tabs. It delivers only when the
target tab and AI session still match, the repository path matches, the agent
is `idle` or `done`, the input prompt is ready, and no MCP text is staged.
Busy or temporarily absent tabs are retried through Aethyme's durable outbox;
identity or repository drift fails closed.

If the installed Aethyme binary or repository deployment does not support the
delivery commands, Chau7 backs off quietly. It never falls back to guessing a
tab, starting an agent, or sending to a different session.
