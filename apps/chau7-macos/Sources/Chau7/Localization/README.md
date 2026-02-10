# Localization

Multi-language support with runtime language switching and RTL layout handling.

## Files

| File | Purpose |
|------|---------|
| `Localization.swift` | Language enum, L() lookup function, and runtime locale/bundle management |

## Key Types

- `AppLanguage` — enum of supported languages (English, French, Arabic, Hebrew) with RTL detection
- `L(_:_:)` — global localization function used throughout the app for string lookups

## Dependencies

- **Uses:** Utilities (Chau7Resources)
- **Used by:** All UI modules (Settings/Views, Overlay, StatusBar, Views, etc.)
