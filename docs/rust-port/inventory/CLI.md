# CLI

Swift: `apps/chau7-macos/Sources/Chau7CLI/`
Swift tests: see each row
Wave: 3
Depends on: Skills

The current chau7 skills CLI. The Next app executable and MCP bridge do not provide this command interface.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| CLI-001 | Provide help/version and skills list/doctor/validate/diff with actionable status and exit codes | `Chau7CLI/Chau7CLIRunner.swift`; `Chau7CLI/main.swift` | Chau7CLISkillsTests |  | missing |  |
| CLI-002 | skills install/update/sync/uninstall supports --source-root, --home, --repo, --scope, --provider and --force; CHAU7_HOME relocates Swift state, Next needs isolated equivalent | `Chau7CLI/Chau7CLIRunner.swift` | Chau7CLISkillsTests |  | missing |  |
| CLI-003 | Install CLI entrypoint from macOS app bundle and expose shell-accessible command without replacing Chau7 production executable | `App/Chau7App.swift`; `scripts/install-chau7-cli.sh` | Chau7CLIInstallerScriptTests |  | missing |  |
