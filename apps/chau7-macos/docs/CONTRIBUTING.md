# Contributing to Chau7

Thank you for your interest in contributing to Chau7! This document provides guidelines and information for contributors.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Code Style](#code-style)
- [Testing](#testing)
- [Submitting Changes](#submitting-changes)
- [Localization](#localization)

## Code of Conduct

Please be respectful and constructive in all interactions. We welcome contributors of all backgrounds and experience levels.

## Getting Started

### Prerequisites

- macOS 13.0 (Ventura) or later
- Xcode 15.0 or later
- Swift 5.9 or later

### Building from Source

```bash
# Clone the repository
git clone https://github.com/schiste/Chau7.git
cd Chau7

# Enter the macOS app directory
cd apps/chau7-macos

# Build the project
swift build

# Run tests
swift test

# Build for release
swift build -c release
```

## Development Setup

### Project Structure

```
Chau7/
├── apps/
│   ├── chau7-macos/
│   │   ├── Sources/
│   │   │   ├── Chau7/             # Main application
│   │   │   │   ├── SettingsViews/ # Settings UI components
│   │   │   │   └── Resources/     # Localization files
│   │   │   └── Chau7Core/         # Core library
│   │   ├── Tests/                 # Unit tests
│   │   └── Package.swift
│   └── chau7-ios/                 # Native iOS companion app
├── services/
│   ├── chau7-relay/               # Cloudflare relay service
│   └── chau7-remote/              # Go remote agent + protocol docs
└── docs/                          # Shared top-level docs only when cross-cutting
```

### Key Components

| Component | Purpose |
|-----------|---------|
| `AppModel` | Application state management |
| `TerminalSessionModel` | Terminal session and PTY handling |
| `FeatureSettings` | User preferences and settings |
| `Chau7OverlayView` | Main overlay window UI |
| `CommandDetection` | AI CLI detection logic |
| `ShellEscaping` | Security utilities |

## Code Style

### Swift Guidelines

1. **File Length**: Keep files under 500-600 lines. Use extensions to split large types.

2. **MARK Sections**: Use MARK comments for code organization:
   ```swift
   // MARK: - Properties
   // MARK: - Initialization
   // MARK: - Public Methods
   // MARK: - Private Methods
   ```

3. **Documentation**: Document all public APIs:
   ```swift
   /// Validates SSH options for dangerous commands.
   /// - Parameter options: Raw SSH options string
   /// - Returns: Validation result with any issues
   static func validateSSHOptions(_ options: String) -> SSHValidationResult
   ```

4. **Error Handling**: Use typed errors and Result types:
   ```swift
   enum MyError: LocalizedError {
       case invalidInput(reason: String)
       var errorDescription: String? { ... }
   }
   ```

5. **Optionals**: Prefer `guard let` over force unwraps:
   ```swift
   // Preferred
   guard let value = optionalValue else { return }

   // Avoid
   let value = optionalValue!
   ```

### Localization

All user-facing strings must be localized:

```swift
// Use the L() function
let message = L("error.file.not.found", "File not found")

// Or the String extension
let label = "settings.title".localized
```

## Testing

### Running Tests

```bash
# Run all tests
swift test

# Run specific test suite
swift test --filter CommandDetectionTests

# Run with verbose output
swift test --verbose
```

### Writing Tests

1. **Location**: Add tests to `apps/chau7-macos/Tests/Chau7Tests/`
2. **Naming**: Use descriptive test names: `testValidateSSHOptions_BlocksProxyCommand`
3. **Coverage**: Aim for 80% code coverage on new code
4. **Categories**:
   - Unit tests for pure functions
   - Integration tests for component interaction
   - UI tests for critical user flows

### Test Structure

```swift
import XCTest
@testable import Chau7Core

final class MyFeatureTests: XCTestCase {

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        // Setup code
    }

    // MARK: - Tests

    func testBasicFunctionality() {
        // Arrange
        let input = "test"

        // Act
        let result = myFunction(input)

        // Assert
        XCTAssertEqual(result, expected)
    }

    func testEdgeCase_EmptyInput() {
        // Test edge cases
    }
}
```

## Submitting Changes

### Pull Request Process

1. **Fork** the repository
2. **Create a branch** for your feature: `git checkout -b feature/my-feature`
3. **Make changes** following the code style guidelines
4. **Add tests** for new functionality
5. **Update documentation** if needed
6. **Run tests**: `swift test`
7. **Commit** with a descriptive message
8. **Push** to your fork
9. **Open a Pull Request** with:
   - Clear description of changes
   - Link to any related issues
   - Screenshots for UI changes

### Commit Messages

Follow conventional commits format:

```
type(scope): description

[optional body]

[optional footer]
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`

Examples:
```
feat(ssh): add connection timeout setting
fix(clipboard): prevent duplicate entries
docs(readme): update build instructions
test(escaping): add command injection tests
```

## Localization

### Adding Translations

1. **English strings**: `apps/chau7-macos/Sources/Chau7/Resources/en.lproj/Localizable.strings`
2. **French strings**: `apps/chau7-macos/Sources/Chau7/Resources/fr.lproj/Localizable.strings`

### String Format

```
// MARK: - Section Name
"key.name" = "Translated value";
"key.with.args" = "Value with %@ argument";
```

### Adding a New Language

1. Create `apps/chau7-macos/Sources/Chau7/Resources/{lang}.lproj/Localizable.strings`
2. Copy all keys from `en.lproj/Localizable.strings`
3. Translate all values
4. Add the language to `AppLanguage` enum in `Localization.swift`
5. Test RTL layout if applicable (Arabic, Hebrew)

## Questions?

- Open an issue for bugs or feature requests
- Check existing issues before creating new ones
- Be specific and include reproduction steps for bugs

Thank you for contributing!
