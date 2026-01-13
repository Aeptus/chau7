# Changelog

All notable changes to Chau7 will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Security**: Shell escaping utilities (`ShellEscaping.swift`) for safe command execution
- **Security**: SSH option validation blocking dangerous commands (ProxyCommand, LocalCommand)
- **Security**: Path sanitization with null byte and traversal prevention
- **Accessibility**: Dynamic Type support with font scaling (0.8x - 2.2x)
- **Accessibility**: High contrast mode support
- **Accessibility**: Reduce motion preference support
- **Accessibility**: Minimum touch target size enforcement (44x44pt)
- **Accessibility**: 60+ VoiceOver accessibility labels
- **Performance**: Thread-safe color cache for hex parsing
- **Performance**: LRU cache for syntax highlighting (500 entries)
- **Performance**: Overlay positions cache
- **Performance**: Async syntax highlighting API
- **i18n**: RTL language support infrastructure (Arabic, Hebrew)
- **i18n**: Localized date/time/number formatters
- **i18n**: 60+ new localization strings (accessibility, validation, status)
- **Documentation**: Comprehensive API docstrings
- **Testing**: 140 unit tests (up from 97)
- **Testing**: Shell escaping security tests
- **Testing**: Command injection prevention tests

### Changed
- Improved ANSI parser documentation
- Enhanced terminal normalizer documentation
- Better input line tracker documentation
- File tailer API documentation

### Security
- SSH extra options now validated before use
- Path click handler validates and escapes paths
- Command substitution patterns blocked in SSH options

## [1.0.0] - 2024-XX-XX

### Added
- Initial release of Chau7
- AI CLI detection (Claude, Codex, Gemini, ChatGPT, Copilot, Aider, Cursor)
- Terminal emulation with SwiftTerm
- Tab management with drag-and-drop reordering
- Command palette (Cmd+Shift+P)
- SSH connection manager
- Snippet management with template expansion
- Clipboard history
- Bookmarks per tab
- Syntax highlighting for terminal output
- Notification system for AI events
- Multiple color schemes (Solarized, Dracula, Nord, Monokai, etc.)
- English and French localization
- Settings import/export
- Dropdown terminal mode
- Split pane support
- Custom keyboard shortcuts

### Technical
- SwiftUI-based UI
- SwiftTerm for terminal emulation
- macOS 13+ (Ventura) minimum
- Swift 5.9+ required
