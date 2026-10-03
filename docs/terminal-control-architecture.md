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
