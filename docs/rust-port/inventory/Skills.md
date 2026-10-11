# Skills

Swift: `apps/chau7-macos/Sources/Chau7Core/Skills/`
Swift tests: see each row
Wave: 3
Depends on: none

Managed provider skill installation with validation, ownership, backups and rollback. Next must use its own state and ownership marker.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| SKL-001 | Validate SKILL.md frontmatter/name/description, optional assets/references/scripts directories and source folder naming; report errors before copying | `Chau7Core/Skills/Chau7SkillValidator.swift` | Chau7SkillValidatorTests; validator_matches_current_frontmatter_optional_folders_and_kebab_names | chau7_next_core/src/skills/validator.rs | done |  |
| SKL-002 | Resolve Claude/Codex user or repository skills targets, discover installed CLI/provider roots, and report unsupported provider explicitly | `Chau7Core/Skills/Chau7SkillProviderTargets.swift`; `Chau7Core/Skills/Chau7SkillModels.swift` | Chau7SkillProviderTargetsTests; Chau7SkillModelsTests; provider_native_roots_explicit_detection_and_unsupported_provider_are_deliberate | chau7_next_core/src/skills/targets.rs; chau7_next_core/src/skills/models.rs | done |  |
| SKL-003 | Manifest records schema, manager, skill/version/provider/scope, source hash and per-file hashes; inspect installed/stale/modified/broken/unmanaged-conflict states | `Chau7Core/Skills/Chau7SkillManifestHashing.swift`; `Chau7Core/Skills/Chau7SkillInstallInspector.swift` | Chau7SkillManifestHashingTests; Chau7SkillModelsTests; manifest_hashes_exclude_own_and_swift_markers_and_include_relative_paths; inspector_rejects_broken_mismatched_and_unsupported_manifests | chau7_next_core/src/skills/manifest.rs; chau7_next_core/src/skills/inspector.rs | done |  |
| SKL-004 | Install/update planning refuses user edits and unmanaged targets unless forced; identical source is a no-op | `Chau7Core/Skills/Chau7SkillInstallPlanner.swift` | Chau7SkillInstallPlannerTests; planner_priorities_warnings_modification_and_manifest_target_metadata_match_swift | chau7_next_core/src/skills/planner.rs | done |  |
| SKL-005 | Stage and validate installation, backup existing target, atomically replace and rollback on failure; Next markers/backups must not claim Swift ownership | `Chau7Core/Skills/Chau7SkillInstaller.swift` | Chau7SkillInstallerTests; installation_noop_update_and_backup_preserve_source_and_manifest; promotion_failure_rolls_back_and_staged_validation_failure_preserves_target | chau7_next_core/src/skills/installer.rs | done |  |
| SKL-006 | Ship and discover built-in Chau7 skills with their referenced assets, preserve source scope when installing | `Chau7CLI/Chau7CLIRunner.swift`; `Resources/Skills/` | Chau7BuiltInSkillsTests; bundled_next_skills_validate_and_have_distinct_identities | resources/skills/chau7-next-build; resources/skills/chau7-next-mcp; chau7_next_core/src/skills/cli.rs; scripts/bundle-macos.sh | done |  |

## Verification

- `ce9baf627f2d`: 21 focused skills/CLI tests, 2,101 core tests and strict release workspace/all-target Clippy passed. Own `.chau7-next-skill.json` manifests, same-filesystem promotion, backups and rollback preserve Swift ownership even when forced. Source `<repo>/.chau7/skills` is read only.
- Force install may override an unmanaged conflict; it cannot discard edits in a modified or broken managed installation. Forced uninstall follows the current explicit removal contract while preserving Swift-managed targets.
