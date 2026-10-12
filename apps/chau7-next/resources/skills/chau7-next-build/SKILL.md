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

This selects the fast optimized release build. If it fails, explicitly request
one symbol-rich rebuild with `BUILD_MODE=diagnostic ./scripts/bundle-macos.sh`;
there is no automatic second build. `CARGO_BUILD_VERBOSE=1 BUILD_LOG=target/logs/fast.log`
adds verbose Cargo commands and records their output.

The output is target/bundle/Chau7 Next.app. CARGO_TARGET_DIR and OUT_DIR may
select a private per-worktree cache and output location; OPTIM_TARGET_DIR and
BUILD_METADATA_DIR override the shared-helper cache and build-evidence output.
An explicit OPTIM_TARGET_DIR is also passed to Cargo for the helper build, so
packaging cannot silently copy an older helper from another cache.
Do not share writable Cargo target directories across worktrees. Set
CARGO_BUILD_JOBS explicitly only when a worker limit is needed; otherwise Cargo
uses its normal jobserver. The bundle contains the app, MCP bridge, standalone
skills CLI and shared app helpers.
The adjacent `Chau7-Next-<target>-<mode>.json` records compiler versions,
source revision and dirty status, profile settings and hashes for the seven
expected executables. Missing optional local helpers are marked null; CI
requires all seven. Verify the bundle signature before launch.

The standalone CLI installer reads Cargo's executable-artifact message, so it
uses the binary Cargo actually built when `CARGO_BUILD_TARGET` or Cargo config
selects a target. `CHAU7_NEXT_CLI_PRODUCT_BIN` remains an explicit source path;
when `CHAU7_NEXT_CLI_SKIP_BUILD=1`, set it to select a non-default target
artifact. Python 3 is required when the installer must resolve the Cargo
artifact message itself.

Chau7 Next uses its own state and settings directories. Preserve its saved
tabs, splits and scrollback. Do not remove state or quit a running app unless
the user authorizes it. Launch test bundles separately; keep the Swift Chau7
application and its helpers untouched. Report the source revision, build
result and checks actually performed.
