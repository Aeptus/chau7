# Skills

Swift: `apps/chau7-macos/Sources/Chau7Core/Skills/`
Swift tests: see each row
Wave: 3
Depends on: none

Managed provider skill installation with validation, ownership, backups and rollback. Next must use its own state and ownership marker.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| SKL-001 | Validate SKILL.md frontmatter/name/description, optional assets/references/scripts directories and source folder naming; report errors before copying | `Chau7Core/Skills/Chau7SkillValidator.swift` | Chau7SkillValidatorTests |  | missing |  |
| SKL-002 | Resolve Claude/Codex user or repository skills targets, discover installed CLI/provider roots, and report unsupported provider explicitly | `Chau7Core/Skills/Chau7SkillProviderTargets.swift`; `Chau7Core/Skills/Chau7SkillModels.swift` | Chau7SkillProviderTargetsTests; Chau7SkillModelsTests |  | missing |  |
| SKL-003 | Manifest records schema, manager, skill/version/provider/scope, source hash and per-file hashes; inspect installed/stale/modified/broken/unmanaged-conflict states | `Chau7Core/Skills/Chau7SkillManifestHashing.swift`; `Chau7Core/Skills/Chau7SkillInstallInspector.swift` | Chau7SkillManifestHashingTests; Chau7SkillModelsTests |  | missing |  |
| SKL-004 | Install/update planning refuses user edits and unmanaged targets unless forced; identical source is a no-op | `Chau7Core/Skills/Chau7SkillInstallPlanner.swift` | Chau7SkillInstallPlannerTests |  | missing |  |
| SKL-005 | Stage and validate installation, backup existing target, atomically replace and rollback on failure; Next markers/backups must not claim Swift ownership | `Chau7Core/Skills/Chau7SkillInstaller.swift` | Chau7SkillInstallerTests |  | missing |  |
| SKL-006 | Ship and discover built-in Chau7 skills with their referenced assets, preserve source scope when installing | `Chau7CLI/Chau7CLIRunner.swift`; `Resources/Skills/` | Chau7BuiltInSkillsTests |  | missing |  |
