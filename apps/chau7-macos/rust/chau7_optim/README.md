# chau7_optim (CTO — Context Token Optimization)

The token optimization engine that powers Chau7's Context Token Optimization feature.
Wraps CLI commands and rewrites their output to minimize LLM context token consumption,
achieving ~40% token savings on average.

Forked from [RTK](https://github.com/rtk-ai/rtk) by Patrick Szymkowiak. See
[UPSTREAM-SYNC.md](UPSTREAM-SYNC.md) for fork history and sync process.

## How It Works

When an AI agent runs a CLI command inside Chau7, the terminal intercepts the command
and pipes it through `chau7-optim`. The optimizer:

1. Identifies the command (git, cargo, npm, go, etc.)
2. Runs it with a command-specific parser
3. Strips noise (timestamps, progress bars, ANSI cruft, redundant paths)
4. Returns a compact summary optimized for LLM consumption

## Supported Commands (46 parsers)

| Category | Commands |
|----------|----------|
| Version control | `git` (status, diff, log, show, blame, stash, etc.) |
| Build tools | `cargo`, `go`, `swift`, `npm`, `pnpm`, `pip` |
| Test frameworks | `pytest`, `vitest`, `playwright` |
| Linters/formatters | `golangci-lint`, `ruff`, `prettier`, `tsc`, `eslint`/`biome` |
| File operations | `find`, `ls`, `tree`, `grep`, `wc`, `diff`, `read` |
| Data tools | `jq`, `curl`, `wget` |
| DevOps | `gh` (GitHub CLI), `prisma`, `next` (Next.js) |
| System | `env`, `tee`, `format_cmd` |
| Meta | `discover` (scans unhandled commands), `container` (Docker/Podman) |

## Source Files

| File | Purpose |
|------|---------|
| `main.rs` | CLI entry point (clap), subcommand dispatch |
| `runner.rs` | Command execution and output capture |
| `filter.rs` | Output filtering and noise removal |
| `gain.rs` | Token savings calculation and reporting |
| `tracking.rs` | Usage tracking (local SQLite) |
| `config.rs` | Configuration loading (TOML) |
| `summary.rs` | Summary generation for optimized output |
| `discover.rs` | Scans for unhandled commands to inform new parser development |
| `display_helpers.rs` | Terminal display formatting utilities |
| `utils.rs` | Shared utility functions |
| `deps.rs` | Dependency resolution |
| `parser/` | Shared parsing primitives |
| `*_cmd.rs` | Per-command parsers (one file per supported command) |

## Building

From the Rust workspace root (`apps/chau7-macos/rust/`):

```bash
cargo build -p chau7_optim           # debug
cargo build -p chau7_optim --release # release
cargo test -p chau7_optim            # tests
```

Binary lands in `target/{debug,release}/chau7-optim`.

## License

MIT (from upstream RTK) — see [LICENSE-RTK](LICENSE-RTK). An additional
Apache 2.0 notice is preserved in [LICENSE-RTK-APACHE](LICENSE-RTK-APACHE)
due to upstream license metadata inconsistency. See
[UPSTREAM-SYNC.md](UPSTREAM-SYNC.md) for details.
