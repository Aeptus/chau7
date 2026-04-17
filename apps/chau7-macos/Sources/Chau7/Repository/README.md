# Repository

Shared git state per repository, deduplicated across tabs.

## Files

| File | Purpose |
|------|---------|
| `RepositoryModel.swift` | Per-repo `@Observable` model with branch + metadata. Shared via `RepositoryCache`. |
| `RepositoryCache.swift` | Singleton cache: path → `RepositoryModel`. 3-tier lookup (protected path → negative cache → prefix match). |
| `RepoMetadata.swift` | Persisted description/labels/favorites at `.chau7/metadata.json`. `RepoMetadataStore` handles load/save. |
| `KnownRepoIdentityStore.swift` | Persists up to 50 known repo identities (root path + branch) in UserDefaults for protected-path fallback. |
| `RepoStats.swift` | On-demand computed stats (commands, AI runs, tokens, cost) per repo from SQLite stores. |
| `InjectionRuleStore.swift` | Manages per-repo and global prompt injection rules. Reads/writes `~/.chau7/prompt-rules.json` and discovers `{repo}/.chau7/injection.json`. |

## Key Patterns

- One `RepositoryModel` per unique git root, shared across all tabs in that repo
- `@Observable var branch` updates all subscribers when any tab changes branches
- `@Observable var metadata` for user-curated repo identity (description, labels, favorites)
- Metadata saved with 0.5s debounce on a dedicated `metadataQueue` (not `gitQueue`)
- Negative cache prevents re-querying non-git directories
- All `@Observable` mutations must happen on the main thread (use `DispatchQueue.main.async`)
