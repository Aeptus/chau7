# Chau7 Architecture

This document describes the architecture of the Chau7 terminal application.

## Overview

Chau7 is a macOS terminal companion app designed for AI CLI tools. It provides terminal emulation, AI detection, notifications, and productivity features.

```
┌─────────────────────────────────────────────────────────────┐
│                      Chau7 Application                       │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │   SwiftUI   │  │   AppKit    │  │    Notifications    │  │
│  │   Views     │  │  Integration│  │      System         │  │
│  └──────┬──────┘  └──────┬──────┘  └──────────┬──────────┘  │
│         │                │                     │             │
│  ┌──────┴────────────────┴─────────────────────┴──────────┐  │
│  │                    Application Layer                    │  │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌───────────┐  │  │
│  │  │ AppModel │ │ Settings │ │ Managers │ │  Overlay  │  │  │
│  │  └──────────┘ └──────────┘ └──────────┘ └───────────┘  │  │
│  └─────────────────────────┬───────────────────────────────┘  │
│                            │                                  │
│  ┌─────────────────────────┴───────────────────────────────┐  │
│  │                    Terminal Layer                        │  │
│  │  ┌──────────────┐ ┌────────────┐ ┌───────────────────┐  │  │
│  │  │ SessionModel │ │ PTY/Shell  │ │ Output Processing │  │  │
│  │  └──────────────┘ └────────────┘ └───────────────────┘  │  │
│  └─────────────────────────┬───────────────────────────────┘  │
│                            │                                  │
│  ┌─────────────────────────┴───────────────────────────────┐  │
│  │                      Core Library                        │  │
│  │  ┌────────────┐ ┌─────────────┐ ┌─────────────────────┐ │  │
│  │  │ Detection  │ │  Escaping   │ │      Parsing        │ │  │
│  │  └────────────┘ └─────────────┘ └─────────────────────┘ │  │
│  └──────────────────────────────────────────────────────────┘  │
│                            │                                  │
│  ┌─────────────────────────┴───────────────────────────────┐  │
│  │               Native Rust Terminal Backend               │  │
│  │            Terminal Emulation and Rendering              │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Layers

### 1. UI Layer (SwiftUI + AppKit)

**Files**: `Chau7OverlayView.swift`, `SettingsViews/*.swift`, `CommandPalette.swift`

- SwiftUI for declarative UI
- AppKit integration for system features (menu bar, notifications)
- Carbon for global keyboard shortcuts

### 2. Application Layer

**Files**: `AppModel.swift`, `AppDelegate.swift`, `FeatureSettings.swift`

| Component | Responsibility |
|-----------|----------------|
| `AppModel` | Global application state, tab management |
| `AppDelegate` | App lifecycle, menu bar, system integration |
| `FeatureSettings` | User preferences, persistence |
| `LocalizationManager` | Language selection, string localization |

### 3. Manager Layer

**Files**: `*Manager.swift`

| Manager | Responsibility |
|---------|----------------|
| `ClipboardHistoryManager` | Clipboard monitoring and history |
| `BookmarkManager` | Terminal bookmarks per tab |
| `SnippetManager` | Snippet storage and expansion |
| `SSHConnectionManager` | SSH connection profiles |
| `NotificationManager` | System notification delivery |

### 4. Terminal Layer

**Files**: `TerminalSessionModel.swift`, `TerminalView.swift`, `AnsiParser.swift`

```
┌─────────────────────────────────────────────────────────┐
│                  TerminalSessionModel                    │
├─────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │
│  │    PTY      │  │   Buffer    │  │  AI Detection   │  │
│  │  Management │  │  Management │  │    Engine       │  │
│  └──────┬──────┘  └──────┬──────┘  └────────┬────────┘  │
│         │                │                   │           │
│         └────────────────┼───────────────────┘           │
│                          ▼                               │
│  ┌───────────────────────────────────────────────────┐  │
│  │          RustTerminalView + PTY Integration       │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

### 5. Core Library (Chau7Core)

**Files**: `apps/chau7-macos/Sources/Chau7Core/*.swift`

Pure Swift library with no UI dependencies:

| Module | Purpose |
|--------|---------|
| `CommandDetection` | AI CLI detection from command strings |
| `ShellEscaping` | Shell argument escaping, path validation |
| `SnippetParsing` | Template variable expansion |
| `ColorParsing` | Hex color parsing, manipulation |

## Data Flow

### Terminal Output Flow

```
PTY → Rust terminal backend → Buffer → AnsiParser → Render
                    │
                    ▼
         TerminalSessionModel
                    │
               ┌────┴────┐
               ▼         ▼
       AI Detection   Notifications
```

### User Input Flow

```
Keyboard → Rust terminal backend → PTY → Shell
                       │
                       ▼
               Input Tracking → Command Detection → Tab Theming
```

### Settings Flow

```
UI → FeatureSettings → UserDefaults
         │
         ├─→ @Published properties
         │
         └─→ NotificationCenter → Observers
```

## Key Design Patterns

### 1. Observable Object Pattern

```swift
final class FeatureSettings: ObservableObject {
    @Published var fontFamily: String {
        didSet {
            UserDefaults.standard.set(fontFamily, forKey: Keys.fontFamily)
            NotificationCenter.default.post(name: .terminalFontChanged, object: nil)
        }
    }
}
```

### 2. Singleton Managers

```swift
final class ClipboardHistoryManager: ObservableObject {
    static let shared = ClipboardHistoryManager()
    private init() { }
}
```

### 3. Result Types for Error Handling

```swift
struct SSHValidationResult {
    let isValid: Bool
    let warnings: [String]
    let blockedOptions: [String]
}

static func validateSSHOptions(_ options: String) -> SSHValidationResult
```

### 4. View Modifiers for Reusability

```swift
extension View {
    func scaledFont(size: CGFloat, weight: Font.Weight) -> some View {
        modifier(ScaledFontModifier(baseSize: size, weight: weight))
    }
}
```

## Threading Model

```
┌─────────────────────────────────────────────────────────┐
│                      Main Thread                         │
│  - SwiftUI rendering                                     │
│  - User interaction                                      │
│  - @Published property updates                           │
└───────────────────────────┬─────────────────────────────┘
                            │
┌───────────────────────────┼─────────────────────────────┐
│                    Background Queues                     │
├───────────────────────────┼─────────────────────────────┤
│  ┌────────────────────┐   │   ┌────────────────────┐    │
│  │ PTY I/O Queue      │   │   │ Syntax Highlight   │    │
│  │ (per session)      │   │   │ Queue              │    │
│  └────────────────────┘   │   └────────────────────┘    │
│                           │                              │
│  ┌────────────────────┐   │   ┌────────────────────┐    │
│  │ File Tailer Queue  │   │   │ Clipboard Poll     │    │
│  │                    │   │   │ Queue              │    │
│  └────────────────────┘   │   └────────────────────┘    │
└─────────────────────────────────────────────────────────┘
```

## Caching Strategy

| Cache | Location | Strategy | Size |
|-------|----------|----------|------|
| Color Cache | `TerminalColorScheme` | Write-through | Unbounded |
| Highlight Cache | `SyntaxHighlighter` | LRU eviction | 500 entries |
| Overlay Positions | `FeatureSettings` | Write-through | Per workspace |
| Search Matches | `TerminalHighlightView` | Invalidate on scroll | Visible only |

## Security Boundaries

```
┌─────────────────────────────────────────────────────────┐
│                    Untrusted Input                       │
│  - User text input                                       │
│  - SSH connection parameters                             │
│  - Snippet templates                                     │
│  - Clipboard content                                     │
└───────────────────────────┬─────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────┐
│                   Validation Layer                       │
│  - ShellEscaping.escapeArgument()                       │
│  - ShellEscaping.validateSSHOptions()                   │
│  - ShellEscaping.sanitizePath()                         │
└───────────────────────────┬─────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────┐
│                    Trusted Execution                     │
│  - Shell commands                                        │
│  - File operations                                       │
│  - SSH connections                                       │
└─────────────────────────────────────────────────────────┘
```

## File Organization

### Source Files by Category

| Category | Files | Lines |
|----------|-------|-------|
| UI Views | 15 | ~5,000 |
| Settings Views | 10 | ~3,500 |
| Models | 8 | ~4,000 |
| Managers | 6 | ~1,500 |
| Terminal | 10 | ~3,500 |
| Utilities | 12 | ~2,500 |
| Core Library | 4 | ~800 |
| **Total** | **72** | **~22,400** |

### Naming Conventions

| Suffix | Purpose | Example |
|--------|---------|---------|
| `*View` | SwiftUI view | `Chau7OverlayView` |
| `*Model` | Observable state | `TerminalSessionModel` |
| `*Manager` | Singleton service | `ClipboardHistoryManager` |
| `*Settings` | Preferences | `FeatureSettings` |
| `*Controller` | AppKit controller | `StatusBarController` |

## Dependencies

### External

| Dependency | Purpose | Version |
|------------|---------|---------|
| swift-atomics | Atomic primitives for concurrency/performance-sensitive code | 1.3.0 |

### System Frameworks

| Framework | Purpose |
|-----------|---------|
| Foundation | Core utilities |
| SwiftUI | Declarative UI |
| AppKit | macOS integration |
| Carbon | Keyboard shortcuts |
| UserNotifications | System notifications |
| Darwin | Low-level APIs |

## Testing Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     Test Suites                          │
├─────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────┐    │
│  │              Unit Tests (140)                    │    │
│  │  - CommandDetectionTests (51)                   │    │
│  │  - ShellEscapingTests (27)                      │    │
│  │  - ColorParsingTests (28)                       │    │
│  │  - SnippetParsingTests (20)                     │    │
│  └─────────────────────────────────────────────────┘    │
│                                                          │
│  ┌─────────────────────────────────────────────────┐    │
│  │           Integration Tests (planned)            │    │
│  │  - Terminal session lifecycle                   │    │
│  │  - Settings persistence                         │    │
│  └─────────────────────────────────────────────────┘    │
│                                                          │
│  ┌─────────────────────────────────────────────────┐    │
│  │              UI Tests (planned)                  │    │
│  │  - Settings flow                                │    │
│  │  - SSH connection flow                          │    │
│  │  - Tab management                               │    │
│  └─────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
```

## Future Considerations

1. **Plugin Architecture**: Allow third-party extensions
2. **Multiple Windows**: Support multiple overlay windows
3. **Theme Marketplace**: User-created color schemes
4. **Cloud Sync**: iCloud settings synchronization
5. **Terminal Multiplexer**: tmux-like functionality
