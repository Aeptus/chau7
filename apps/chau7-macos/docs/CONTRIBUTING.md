# macOS App Contributing Notes

This directory no longer owns the repository-wide contributor workflow.

Use the canonical guides instead:

- [../../../CONTRIBUTING.md](../../../CONTRIBUTING.md) for setup, CI, and pull request expectations
- [../README.md](../README.md) for macOS app build, run, packaging, and local verification
- [../../../docs/README.md](../../../docs/README.md) for the documentation map and ownership rules

## When to Read This File

Read this file only if you are already working inside `apps/chau7-macos` and need app-specific context.

## App-Specific Notes

- The Swift package declares the supported macOS version in [../Package.swift](../Package.swift).
- Run `swift build` and `swift test` from `apps/chau7-macos`.
- Use repo-root scripts in `../../../Scripts/` for hooks and CI entry points.
- Treat the docs in this folder as implementation references, not the canonical public onboarding path.
