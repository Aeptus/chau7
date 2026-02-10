# Utilities

Shared helpers: error types, accessibility, bounded collections, formatters, keychain, and regex patterns.

## Files

| File | Purpose |
|------|---------|
| `AccessibilityUtilities.swift` | Dynamic Type scaled fonts, high contrast, and reduced motion helpers |
| `BoundedArray.swift` | Fixed-capacity array and set that auto-evict oldest elements when full |
| `Chau7Error.swift` | Typed error enum covering file, config, terminal, snippet, and network failures |
| `Chau7Resources.swift` | Locates the correct resource bundle for localized strings and assets |
| `Formatters.swift` | Shared DateFormatter instances (short time, medium time, terminal login, relative) |
| `KeychainHelper.swift` | Secure storage for API keys using the macOS Keychain (SecItem APIs) |
| `ProtectedPathPolicy.swift` | Guards against auto-access to protected folders (Downloads, Desktop, Library) |
| `RegexPatterns.swift` | Pre-compiled shared NSRegularExpression instances for URLs, file paths, and ANSI codes |
| `Utilities.swift` | Array extensions (trimToLast), ISO8601 date formatting helpers |

## Key Types

- `Chau7Error` — LocalizedError enum with cases for all app-level error categories
- `BoundedArray<T>` — auto-evicting fixed-capacity array for log buffers and history
- `RegexPatterns` — pre-compiled regex patterns for URLs, file paths, and ANSI sequences
- `KeychainHelper` — static Keychain CRUD for secure API key storage

## Dependencies

- **Uses:** Logging, Settings (FeatureSettings for ProtectedPathPolicy)
- **Used by:** Nearly all modules (Commands, History, Monitoring, AI, Terminal, etc.)
