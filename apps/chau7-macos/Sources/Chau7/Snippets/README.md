# Snippets

Reusable command snippet management with user, profile, and repo-scoped sources.

## Files

| File | Purpose |
|------|---------|
| `SnippetManager.swift` | Manages snippet CRUD with three scopes: user (global), profile, and repo |
| `SnippetsSettingsView.swift` | Settings UI for browsing, editing, importing, and exporting snippets |

## Key Types

- `SnippetManager` — singleton ObservableObject managing snippets across user/profile/repo scopes
- `SnippetSource` — enum defining snippet scope (global, profile, repo) with display names

## Dependencies

- **Uses:** Logging, Settings, Localization
- **Used by:** Overlay, Notifications, Scripting, Settings/Views
