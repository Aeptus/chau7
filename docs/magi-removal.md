# MAGI removal

Issue #91 was resolved by removing MAGI altogether, rather than moving it to a
new runtime. Chau7 no longer builds a `magi`/`MAGI` executable, ships its installer
or bundled skill, or contains the MAGI protocol, council models, artifacts and CLI
orchestration implementation. There were no dedicated MAGI UI or MCP registrations
on current main; the removed CLI consumed generic `agent_launch`, event and terminal
tools. Those general capabilities remain supported for independent callers.

The [archived protocol](magi-rfc.md) is a historical specification. Existing
`.chau7/magi` artifacts are preserved; no automated migration, deletion or external
repository is required by this removal. Read saved JSON/Markdown/HTML files with
normal tools. Historical `magi replay/share/doctor/config/ask` commands are no
longer supported in Chau7. Previously installed standalone binaries and external
agent skill copies are outside the source change and are not silently modified.

Terminal path lookup used a repository-root helper that happened to live in the
MAGI module. That helper is now `RepositoryRootLocator` in Chau7Core, with tests for
normal repositories, Git-file worktrees and no-repository paths. Package graph and
bundled-skill tests ensure no MAGI product/target/implementation is shipped.
