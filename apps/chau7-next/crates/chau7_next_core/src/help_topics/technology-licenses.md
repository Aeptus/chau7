# Technology, Licenses & Acknowledgments

This page summarizes the Chau7 monorepo, the technologies used to build it, and the third-party notices kept with the repository.

## Monorepo Layout

```text
apps/chau7-macos        macOS app
apps/chau7-next         Rust/GPUI port of the macOS app
apps/chau7-ios          iOS companion app
services/chau7-relay    Cloudflare relay
services/chau7-remote   Go remote agent
docs/remote-control     protocol and UX spec
```

## Languages and Platforms

| Area | Main tech |
|------|-----------|
| macOS app UI | Swift, SwiftUI, AppKit |
| Chau7 Next UI | Rust, GPUI |
| Shared app logic | Swift (`Chau7Core`) |
| Native rendering/performance helpers | Rust |
| Local proxy binary | Go |
| Relay service | Cloudflare Workers + Durable Objects, npm build flow |
| iOS companion | Swift, Xcode, ActivityKit |
| Build and packaging glue | Shell scripts |

## macOS App Components

| Component | Path | Notes |
|-----------|------|-------|
| Main app | `apps/chau7-macos/Sources/Chau7` | SwiftUI/AppKit executable target |
| Shared core | `apps/chau7-macos/Sources/Chau7Core` | Testable Swift logic shared by app features |
| Rust workspace | `apps/chau7-macos/rust` | Native crates used by the macOS app |
| Go proxy | `apps/chau7-macos/chau7-proxy` | Local TLS/WSS proxy binary bundled into the app |

## Rust Crates in the macOS App

| Crate | Purpose |
|------|---------|
| `chau7_terminal` | Terminal backend and rendering support |
| `chau7_parse` | Parsing helpers |
| `chau7_md` | Markdown-to-terminal rendering helper |
| `chau7_optim` | Built-in command token optimizer |

## Bundled Helper Binaries

The macOS app build scripts bundle helper binaries into the app resources, including:

- `chau7-optim`
- `chau7-md`
- `chau7-proxy`

## Main Repository Paths

Chau7 is developed as a single monorepo. The main paths are:

- `apps/chau7-macos`
- `apps/chau7-next`
- `apps/chau7-ios`
- `services/chau7-relay`
- `services/chau7-remote`
- `docs/remote-control`

## Direct Third-Party Dependencies

| Dependency | Upstream repo | Used for | License |
|-----------|---------------|----------|---------|
| `swift-atomics` | `https://github.com/apple/swift-atomics` | Swift atomic primitives used by app performance/concurrency code | Apache-2.0 |

## RTK-Derived Code

Chau7 contains a modified fork of RTK inside:

- `apps/chau7-macos/rust/chau7_optim`

Recorded provenance:

- Upstream repo: `https://github.com/rtk-ai/rtk`
- Local fork record: `apps/chau7-macos/rust/chau7_optim/UPSTREAM-SYNC.md`
- Preserved MIT text: `apps/chau7-macos/rust/chau7_optim/LICENSE-RTK`
- Conservative Apache notice copy: `apps/chau7-macos/rust/chau7_optim/LICENSE-RTK-APACHE`
- Repo-wide notice index: `THIRD_PARTY_NOTICES.md`

Licensing note:

- The imported fork preserves the MIT notice text that accompanied the forked subtree.
- RTK upstream currently publishes inconsistent license metadata.
- Chau7 therefore keeps both local notice files until upstream license history is clarified.

## System Frameworks

The macOS target links Apple system frameworks including:

- Metal
- MetalKit
- IOKit
- IOSurface
- CoreVideo
- SwiftUI
- AppKit
- Foundation

## Cloud and Remote Components

| Component | Path | Stack |
|-----------|------|-------|
| Relay | `services/chau7-relay` | Cloudflare Workers + Durable Objects |
| Remote agent | `services/chau7-remote` | Go |
| iOS companion | `apps/chau7-ios` | Swift / Xcode project |

## Notice Files

For source-level notices kept in this repository, start with:

- `THIRD_PARTY_NOTICES.md`
- `apps/chau7-macos/rust/chau7_optim/LICENSE-RTK`
- `apps/chau7-macos/rust/chau7_optim/LICENSE-RTK-APACHE`
- `apps/chau7-macos/rust/chau7_optim/UPSTREAM-SYNC.md`
