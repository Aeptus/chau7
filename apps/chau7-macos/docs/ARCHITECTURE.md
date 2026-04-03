# Chau7 Architecture

This document describes the architecture of the Chau7 terminal application.

Canonical documentation ownership is listed in [../../../docs/README.md](../../../docs/README.md).

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

**Files**: `TerminalSessionModel.swift`, `RustTerminalView.swift`, `AnsiParser.swift`

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

### Source Areas by Category

| Category | What Lives There |
|----------|------------------|
| UI Views | Overlay, settings, dashboards, and supporting SwiftUI/AppKit surfaces |
| Models | App, tab, session, repository, and runtime state |
| Managers | Notifications, monitoring, telemetry, MCP, and service orchestration |
| Terminal | PTY session handling, rendering integration, shell/event tracking |
| Utilities | Shared helpers, parsing, logging, and platform glue |
| Core Library | Pure Swift logic in `Chau7Core` |

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
│  │               Unit Tests                         │    │
│  │  - Core parsing and detection                   │    │
│  │  - Notification semantics and routing           │    │
│  │  - Telemetry, history, and runtime helpers      │    │
│  └─────────────────────────────────────────────────┘    │
│                                                          │
│  ┌─────────────────────────────────────────────────┐    │
│  │            Integration Coverage                  │    │
│  │  - Terminal session lifecycle                   │    │
│  │  - Settings persistence                         │    │
│  │  - Multi-system notification/event behavior     │    │
│  └─────────────────────────────────────────────────┘    │
│                                                          │
│  ┌─────────────────────────────────────────────────┐    │
│  │              UI / Manual Flows                  │    │
│  │  - Settings flow                                │    │
│  │  - SSH connection flow                          │    │
│  │  - Tab and window management                    │    │
│  └─────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
```

## Design Trade-offs

### Singletons

Chau7 uses ~50 singletons (`.shared`) for app-lifetime services: settings, stores, monitors, managers. This is a deliberate trade-off for a desktop app where the process lifetime equals the app lifetime. DI containers add complexity without benefit when there's exactly one instance of each service, created at launch, destroyed at quit. Tests use `@testable import` to access internals directly.

### Notification Pipeline in Chau7Core

The 11-file notification subsystem (`CanonicalNotificationEvent`, `NotificationIngress`, provider adapters, etc.) lives in Chau7Core despite having no external consumers. This is intentional: the full notification pipeline — ingress, semantic mapping, trigger evaluation, style planning — is covered by unit tests that don't import AppKit. Moving it to the app target would make it untestable without the full UI stack.

### FeatureSettings (132 properties)

One property per feature flag with explicit `didSet` UserDefaults persistence. This is large by design — every flag is independently toggleable, persisted, exportable, and resettable. A macro-based approach would reduce boilerplate but add a build-time dependency and make debugging harder (you can't breakpoint inside a macro expansion).

## Future Considerations

1. **Plugin Architecture**: Allow third-party extensions
2. **Richer Plugin Boundaries**: Cleaner extension points for future automation and integrations
3. **Theme Marketplace**: User-created color schemes
4. **Cloud Sync**: iCloud settings synchronization
5. **Terminal Multiplexer**: tmux-like functionality
