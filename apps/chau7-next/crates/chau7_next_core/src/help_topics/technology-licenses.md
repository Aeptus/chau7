# Technology, Licenses & Acknowledgments

This page summarizes the Chau7 monorepo, the technologies used to build it, and the third-party notices kept with the repository.

## Monorepo Layout

```text
apps/chau7-next         macOS app (Rust/GPUI)
apps/chau7-ios          iOS companion app
crates                  shared Rust crates (terminal, token optimizer, markdown)
services/chau7-proxy    Go analytics proxy
services/chau7-relay    Cloudflare relay
services/chau7-remote   Go remote agent
```

The former SwiftUI/AppKit macOS app has been removed from the repository; it remains in git history and prior release tags.

## Languages and Platforms

| Area | Main tech |
|------|-----------|
| macOS app UI | Rust, GPUI |
| macOS app logic | Rust (`chau7_next_core`) |
| Terminal emulator | Rust (`chau7_terminal`, built on `alacritty_terminal`) |
| Local proxy binary | Go |
| Relay service | Cloudflare Workers + Durable Objects, npm build flow |
| iOS companion | Swift, Xcode, ActivityKit, shared `Chau7Core` package |
| Build and packaging glue | Shell scripts |

## macOS App Components

| Component | Path | Notes |
|-----------|------|-------|
| App and UI | `apps/chau7-next/crates/chau7_next` | GPUI application, windows, views |
| Core logic | `apps/chau7-next/crates/chau7_next_core` | Testable logic without UI |
| Shared Rust crates | `crates` | Terminal emulator and helper binaries |
| Go proxy | `services/chau7-proxy` | Local TLS/WSS proxy binary bundled into the app |
| Remote agent | `services/chau7-remote` | Go binary bundled into the app |

## Shared Rust Crates

| Crate | Purpose |
|------|---------|
| `chau7_terminal` | Terminal emulation, used by the macOS and iOS apps |
| `chau7_md` | Markdown-to-terminal rendering helper |
| `chau7_optim` | Built-in command token optimizer |

## Bundled Helper Binaries

The macOS app bundle includes these helper binaries next to the app executable:

- `chau7-optim`
- `chau7-md`
- `chau7-proxy`
- `chau7-remote`

## Direct Third-Party Dependencies

| Dependency | Upstream repo | Used for | License |
|-----------|---------------|----------|---------|
| `gpui-pre` (GPUI) | `https://github.com/zed-industries/zed` | UI framework; three locally modified packages ship their notices in the app bundle | Apache-2.0 |
| `alacritty_terminal` | `https://github.com/alacritty/alacritty` | Terminal emulation core | Apache-2.0 |

## RTK-Derived Code

Chau7 contains a modified fork of RTK inside:

- `crates/chau7_optim`

Recorded provenance:

- Upstream repo: `https://github.com/rtk-ai/rtk`
- Local fork record: `crates/chau7_optim/UPSTREAM-SYNC.md`
- Preserved MIT text: `crates/chau7_optim/LICENSE-RTK`
- Conservative Apache notice copy: `crates/chau7_optim/LICENSE-RTK-APACHE`
- Repo-wide notice index: `THIRD_PARTY_NOTICES.md`

Licensing note:

- The imported fork preserves the MIT notice text that accompanied the forked subtree.
- RTK upstream currently publishes inconsistent license metadata.
- Chau7 therefore keeps both local notice files until upstream license history is clarified.

## System Frameworks

On macOS, GPUI uses Apple system frameworks including Metal, Core Text, Core Graphics and AppKit.

## Cloud and Remote Components

| Component | Path | Stack |
|-----------|------|-------|
| Relay | `services/chau7-relay` | Cloudflare Workers + Durable Objects |
| Remote agent | `services/chau7-remote` | Go |
| iOS companion | `apps/chau7-ios` | Swift / Xcode project |

## Notice Files

For source-level notices kept in this repository, start with:

- `THIRD_PARTY_NOTICES.md`
- `crates/chau7_optim/LICENSE-RTK`
- `crates/chau7_optim/LICENSE-RTK-APACHE`
- `crates/chau7_optim/UPSTREAM-SYNC.md`
