---
name: chau7-next-build
description: Build and package the Rust Chau7 Next macOS application while preserving session data.
---

# Chau7 Next build

Work in the managed Chau7 repository checkout. Read its AGENTS.md and the
Rust port handoff before changing sources. Build from apps/chau7-next:

```sh
./scripts/bundle-macos.sh
```

The output is target/bundle/Chau7 Next.app. CARGO_TARGET_DIR and OUT_DIR may
select an isolated cache and output location. The bundle contains the app,
MCP bridge and standalone skills CLI. Verify its signature before launch.

Chau7 Next uses its own state and settings directories. Preserve its saved
tabs, splits and scrollback. Do not remove state or quit a running app unless
the user authorizes it. Launch test bundles separately; keep the Swift Chau7
application and its helpers untouched. Report the source revision, build
result and checks actually performed.
