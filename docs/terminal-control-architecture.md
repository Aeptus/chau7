# Terminal control responsibilities

TerminalControlService owns window/tab registration, canonical tab aliases,
terminal mutation and approval routing. MCPRepositoryQueryService owns repository
metadata, frequent-command and event read contracts. It receives value snapshots;
metadata I/O, history/statistics waits and encoding stay on the MCP worker after
the facade's bounded main-actor metadata capture. Repository event snapshots and
alias allocation preserve their existing main-actor order. RepoEventQuery in
Chau7Core owns normalized filters and the shared 50-event cap.

This extraction reduces TerminalControlService's repository-read responsibility;
it does not claim a measured rendering or responsiveness improvement. The prior
main-actor responsiveness test remains required alongside event JSON/alias tests.
Other large terminal/session/UI owners remain candidates for later focused work;
line count alone is not justification for a broad rewrite or weaker lint gates.

Repository aggregates coalesce each optional counter before summing. Combined
run/proxy cost subtracts the measured overlap retained in both sources once;
separate source totals keep their provenance. This prevents the new measured
run fields from disappearing through SQL NULL arithmetic or being added twice.

ProviderTokenAccounting converts raw proxy counters to separate canonical
buckets before run/reconciliation totals. OpenAI cached/reasoning counters are
subsets of input/output totals; Gemini cached tokens are included in prompt
tokens while thoughts are separate. Anthropic cache buckets are independent.
See the [OpenAI caching contract](https://developers.openai.com/api/docs/guides/prompt-caching),
[reasoning contract](https://developers.openai.com/api/docs/guides/reasoning) and
[Gemini usage metadata](https://ai.google.dev/api/generate-content#UsageMetadata).
The Go pricing boundary applies the same rules. Stored raw evidence remains
unchanged and historical costs keep their original pricing version.
