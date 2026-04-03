# Documentation Map

This repository keeps public-facing documentation close to the code it describes, but a few files are the canonical entry points:

## Canonical Docs

- [`README.md`](../README.md): public product overview, repo layout, and top-level entry points
- [`CONTRIBUTING.md`](../CONTRIBUTING.md): contributor workflow, prerequisites, CI, and PR expectations
- [`apps/chau7-macos/README.md`](../apps/chau7-macos/README.md): macOS app build, run, packaging, and local verification
- [`services/chau7-relay/README.md`](../services/chau7-relay/README.md): relay build and deployment notes
- [`services/chau7-remote/README.md`](../services/chau7-remote/README.md): remote agent build and runtime notes
- [`services/chau7-remote/docs/PROTOCOL.md`](../services/chau7-remote/docs/PROTOCOL.md): remote transport and payload contract
- [`apps/chau7-ios/docs/REMOTE-UX.md`](../apps/chau7-ios/docs/REMOTE-UX.md): iOS remote-control product behavior
- [`apps/chau7-macos/docs/ARCHITECTURE.md`](../apps/chau7-macos/docs/ARCHITECTURE.md): current macOS architecture overview
- [`apps/chau7-macos/docs/FEATURES.md`](../apps/chau7-macos/docs/FEATURES.md): stable feature inventory
- [`apps/chau7-macos/docs/CHANGELOG.md`](../apps/chau7-macos/docs/CHANGELOG.md): release and shipped-change history

## Rules

- Root docs describe the product, repository, and contribution path.
- App and service READMEs own implementation-specific build, run, deploy, and ops details.
- Specs and assessments should not duplicate onboarding instructions.
- Leaf `README.md` files should explain local code and point back to the canonical docs instead of restating repo-wide setup.

## Public Repo Rule

Working assessments, planning notes, and TODO-style documents should not live in the public repository. Keep public docs focused on current product, contributor, and operational guidance.
