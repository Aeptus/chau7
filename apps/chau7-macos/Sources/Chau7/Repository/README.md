# Repository

Shared git state per repository, deduplicated across tabs.

## Files

| File | Purpose |
|------|---------|
| `RepositoryModel.swift` | Per-repo `ObservableObject` with branch + metadata. Shared via `RepositoryCache`. |
| `RepositoryCache.swift` | Singleton cache: path → `RepositoryModel`. 3-tier lookup (protected path → negative cache → prefix match). |
| `RepoMetadata.swift` | Persisted description/labels/favorites at `.chau7/metadata.json`. `RepoMetadataStore` handles load/save. |

## Key Patterns

- One `RepositoryModel` per unique git root, shared across all tabs in that repo
- `@Published var branch` updates all subscribers when any tab changes branches
- `@Published var metadata` for user-curated repo identity (description, labels, favorites)
- Metadata saved with 0.5s debounce on a dedicated `metadataQueue` (not `gitQueue`)
- Negative cache prevents re-querying non-git directories
