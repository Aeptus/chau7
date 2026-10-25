# Documentation Map

This repository keeps public-facing documentation close to the code it describes, but a few files are the canonical entry points:

## Canonical Docs

- [`README.md`](../README.md): public product overview, repo layout, and top-level entry points
- [`CONTRIBUTING.md`](../CONTRIBUTING.md): contributor workflow, prerequisites, CI, and PR expectations
- [`SECURITY.md`](../SECURITY.md): vulnerability reporting and security surface documentation
- [`PRIVACY.md`](../PRIVACY.md): what data stays local, bug report data flow, sub-processors
- [`scripts/README.md`](../scripts/README.md): build orchestration and CI script reference
- [`quality-gates.md`](quality-gates.md): hook architecture, quality registry contract, cache policy, and failure reproduction
- [`aethyme-pr-delivery.md`](aethyme-pr-delivery.md): durable Aethyme PR activity delivery to exact Chau7 agent sessions
- [`apps/chau7-next/README.md`](../apps/chau7-next/README.md): the macOS app (Rust/GPUI): build, packaging, channels, and data locations
- [`rust-port/DUAL-SHIP.md`](rust-port/DUAL-SHIP.md): history of the Swift and Rust coexistence and the production cutover
- [`rust-port/PARITY.md`](rust-port/PARITY.md): implementation inventory and revision-scoped validation status
- [`rust-port/PRODUCTION-RELEASE.md`](rust-port/PRODUCTION-RELEASE.md): release candidate, migration, and production release process
- [`CHANGELOG.md`](../CHANGELOG.md): release and shipped-change history
- [`crates/chau7_optim/README.md`](../crates/chau7_optim/README.md): Context Token Optimization helper (RTK-derived)
- [`crates/chau7_terminal/README.md`](../crates/chau7_terminal/README.md): Rust terminal crate build and source overview
- [`crates/chau7_terminal/FFI_DESIGN.md`](../crates/chau7_terminal/FFI_DESIGN.md): FFI contract, memory rules, and thread safety
- [`services/chau7-relay/README.md`](../services/chau7-relay/README.md): remote relay build and deployment notes
- [`services/chau7-issues/README.md`](../services/chau7-issues/README.md): bug-report intake worker build and deployment notes
- [`services/chau7-remote/README.md`](../services/chau7-remote/README.md): remote agent build and runtime notes
- [`services/chau7-remote/docs/PROTOCOL.md`](../services/chau7-remote/docs/PROTOCOL.md): remote transport and payload contract
- [`apps/chau7-ios/README.md`](../apps/chau7-ios/README.md): iOS companion app scope and build, including the `Chau7Core` Swift package
- [`services/chau7-proxy/README.md`](../services/chau7-proxy/README.md): API analytics proxy build and behavior
- [`apps/chau7-ios/docs/REMOTE-UX.md`](../apps/chau7-ios/docs/REMOTE-UX.md): iOS remote-control product behavior

## Rules

- Root docs describe the product, repository, and contribution path.
- App and service READMEs own implementation-specific build, run, deploy, and ops details.
- Specs and assessments should not duplicate onboarding instructions.
- Leaf `README.md` files should explain local code and point back to the canonical docs instead of restating repo-wide setup.

## Public Repo Rule

Working assessments, planning notes, and TODO-style documents should not live in the public repository. Keep public docs focused on current product, contributor, and operational guidance.

- [MAGI removal](magi-removal.md): removed command compatibility and preserved artifacts
- [Archived MAGI protocol](magi-rfc.md): historical specification only
