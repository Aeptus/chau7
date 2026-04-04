# Documentation Map

This repository keeps public-facing documentation close to the code it describes, but a few files are the canonical entry points:

## Canonical Docs

- [`README.md`](../README.md): public product overview, repo layout, and top-level entry points
- [`CONTRIBUTING.md`](../CONTRIBUTING.md): contributor workflow, prerequisites, CI, and PR expectations
- [`SECURITY.md`](../SECURITY.md): vulnerability reporting and security surface documentation
- [`PRIVACY.md`](../PRIVACY.md): what data stays local, bug report data flow, sub-processors
- [`Scripts/README.md`](../Scripts/README.md): build orchestration and CI script reference
- [`apps/chau7-macos/README.md`](../apps/chau7-macos/README.md): macOS app build, run, packaging, and local verification
- [`apps/chau7-macos/docs/ARCHITECTURE.md`](../apps/chau7-macos/docs/ARCHITECTURE.md): current macOS architecture overview
- [`apps/chau7-macos/docs/FEATURES.md`](../apps/chau7-macos/docs/FEATURES.md): stable feature inventory
- [`apps/chau7-macos/docs/CHANGELOG.md`](../apps/chau7-macos/docs/CHANGELOG.md): release and shipped-change history
- [`apps/chau7-macos/docs/STYLING_GUIDE.md`](../apps/chau7-macos/docs/STYLING_GUIDE.md): UI spacing, typography, and color system
- [`apps/chau7-macos/rust/chau7_terminal/README.md`](../apps/chau7-macos/rust/chau7_terminal/README.md): Rust terminal crate build and source overview
- [`apps/chau7-macos/rust/chau7_terminal/FFI_DESIGN.md`](../apps/chau7-macos/rust/chau7_terminal/FFI_DESIGN.md): FFI contract, memory rules, and thread safety
- [`services/chau7-relay/README.md`](../services/chau7-relay/README.md): relay build and deployment notes
- [`services/chau7-remote/README.md`](../services/chau7-remote/README.md): remote agent build and runtime notes
- [`services/chau7-remote/docs/PROTOCOL.md`](../services/chau7-remote/docs/PROTOCOL.md): remote transport and payload contract
- [`apps/chau7-ios/README.md`](../apps/chau7-ios/README.md): iOS companion app scope and build
- [`apps/chau7-ios/docs/REMOTE-UX.md`](../apps/chau7-ios/docs/REMOTE-UX.md): iOS remote-control product behavior

## Rules

- Root docs describe the product, repository, and contribution path.
- App and service READMEs own implementation-specific build, run, deploy, and ops details.
- Specs and assessments should not duplicate onboarding instructions.
- Leaf `README.md` files should explain local code and point back to the canonical docs instead of restating repo-wide setup.

## Public Repo Rule

Working assessments, planning notes, and TODO-style documents should not live in the public repository. Keep public docs focused on current product, contributor, and operational guidance.
