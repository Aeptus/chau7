# CLI

Swift: `apps/chau7-macos/Sources/Chau7CLI/`
Swift tests: see each row
Wave: 3
Depends on: Skills

The current Chau7 skills CLI has a distinct Next counterpart: the standalone `chau7-next-cli` helper and shell command `chau7-next`. Both use Next state and preserve production Chau7 commands.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| CLI-001 | Provide help/version and skills list/doctor/validate/diff with actionable status and exit codes | `Chau7CLI/Chau7CLIRunner.swift`; `Chau7CLI/main.swift` | Chau7CLISkillsTests; all_help_version_errors_and_parser_constraints; list_doctor_validate_and_path_validation_report_full_state | chau7_next_core/src/skills/cli.rs; chau7_next_core/src/bin/chau7-next-cli.rs | done |  |
| CLI-002 | skills install/update/sync/uninstall supports --source-root, --home, --repo, --scope, --provider and --force; CHAU7_HOME relocates Swift state, Next needs isolated equivalent | `Chau7CLI/Chau7CLIRunner.swift` | Chau7CLISkillsTests; explicit_provider_install_default_detection_update_sync_diff_and_uninstall; unmanaged_force_modified_guard_and_provider_all_are_independent; repo_scope_preserves_read_only_source_and_uses_own_home_state | chau7_next_core/src/skills/cli.rs; chau7_next_core/src/data_root.rs | done |  |
| CLI-003 | Opt-in installer exposes the app-bundled CLI and Skills through `chau7-next` without replacing Chau7 production commands; a `Contents/Resources` copy uses sibling bundle artifacts and never builds from a checkout | `App/Chau7App.swift`; `Scripts/install-chau7-cli.sh` | Chau7CLIInstallerScriptTests; standalone_installer_preserves_swift_helpers_and_forwards_arguments; bundled_installer_uses_sibling_artifacts_without_checkout_or_cargo | scripts/install-chau7-next-cli.sh; scripts/bundle-macos.sh; chau7_next_core/src/bin/chau7-next-cli.rs | done |  |

## Verification

- `ce9baf627f2d` implements every current help/version/skills command, option constraint and exit-code contract. The real release executable passed all commands with both providers against an isolated home; all 21 focused skills/CLI tests and 2,101 core tests passed.
- CLI-003 installer acceptance covers repeat installation, exact literal argument
  forwarding and preservation of `chau7`/`chau7-cli` and Swift state. The bundle
  recipe now places the opt-in installer at
  `Contents/Resources/install-chau7-next-cli.sh`; it reads
  `Contents/MacOS/chau7-next-cli` and `Contents/Resources/Skills`, so it needs no
  checkout or Cargo build. Users invoke it explicitly, for example:
  `bash "/Applications/Chau7 Next.app/Contents/Resources/install-chau7-next-cli.sh"`.
  Launching the app does not install shell commands. A new bundle-only contract
  regression covers paths with spaces, no Cargo invocation, argument forwarding,
  and preservation of existing Swift helpers/state and unrelated installed files.
  Current-source verification and final signed bundle acceptance remain with the
  coordinator.
