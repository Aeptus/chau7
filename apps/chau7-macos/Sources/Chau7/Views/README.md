# Views

General-purpose views: help documentation browser, power user tips, and splash screen.

## Files

| File | Purpose |
|------|---------|
| `HelpDocumentation.swift` | Searchable help topic browser with related topics and category navigation |
| `PowerUserTips.swift` | Curated tips displayed on new terminal tabs to help users discover shortcuts |
| `SplashView.swift` | Launch splash screen with app icon, name, and loading indicator |

## Key Types

- `HelpTopic` — model for a help entry with title, icon, content, and related topic IDs
- `PowerUserTips` — enum providing categorized tips (keyboard, mouse, tabs, search, etc.)
- `SplashView` — SwiftUI view shown during app startup

## Dependencies

- **Uses:** App (AppIcon), Localization
- **Used by:** App, Overlay
