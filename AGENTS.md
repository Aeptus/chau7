# AGENTS

Guidelines for AI agents working on the Chau7 codebase.

## Communication

- When asking questions, number them for easier back-and-forth.

## Project Structure

```
Chau7/
├── apps/
│   ├── chau7-macos/      # SwiftUI + AppKit macOS app (SwiftPM)
│   └── chau7-ios/        # Native iOS app
├── services/
│   ├── chau7-relay/      # Cloudflare relay (Workers + Durable Objects)
│   └── chau7-remote/     # Go relay client for macOS
└── docs/
    └── remote-control/  # Remote control spec
```

## Testing Requirements

### Before Submitting Changes

1. **Run tests**: `swift test` - All tests must pass
2. **Build check**: `swift build` - Must compile without errors
3. **Add tests for new logic**: Any new pure functions should have tests

Run these from `apps/chau7-macos`.

### Test Infrastructure

- **Chau7Core module**: Contains testable pure functions
- **Tests location**: `apps/chau7-macos/Tests/Chau7Tests/`
- **Test framework**: XCTest (requires Xcode)

### When to Add Tests

Add tests when:
- Adding new AI CLI detection (update `CommandDetection.swift` and `CommandDetectionTests.swift`)
- Adding new event types (update `EventParsing` and `EventParsingTests.swift`)
- Adding any pure function that can be tested in isolation

### Test Patterns

```swift
// Good: Pure function in Chau7Core
public static func detectApp(from commandLine: String) -> String?

// Test it:
func testDetectClaude() {
    XCTAssertEqual(CommandDetection.detectApp(from: "claude"), "Claude")
}
```

## Debugging Tools

### Debug Console (Cmd+Shift+D)

Use the debug console to inspect runtime state:
- Tab states and active apps
- Claude Code sessions and events
- Live logs with filtering
- Generate bug reports

### Structured Logging

Use `DebugContext` for operations that need tracing:

```swift
let ctx = DebugContext(operation: "my-operation", metadata: ["key": value])
ctx.log("Step completed", metadata: ["result": result])
ctx.complete(success: true)
```

### State Snapshots

Capture full app state for debugging:

```swift
let snapshot = StateSnapshot.capture(from: appModel, overlayModel: overlayModel)
_ = snapshot.save()  // Saves to ~/.chau7/snapshots/
```

## Code Quality

### Extracting Testable Logic

When adding complex logic:

1. Extract pure functions to `apps/chau7-macos/Sources/Chau7Core/`
2. Keep UI/state management in `apps/chau7-macos/Sources/Chau7/`
3. Add corresponding tests

Example:
```swift
// In apps/chau7-macos/Sources/Chau7Core/CommandDetection.swift
public static func tokenize(_ line: String) -> [String]

// In apps/chau7-macos/Sources/Chau7/TerminalSessionModel.swift
let tokens = CommandDetection.tokenize(commandLine)
```

### AI CLI Detection

When adding support for new AI CLIs:

1. Add entries to `CommandDetection.appNameMap`:
   ```swift
   "new-cli": "NewCLI",
   "new-cli-variant": "NewCLI"
   ```

2. Add output detection patterns if the CLI has identifiable banners:
   ```swift
   ("New CLI Banner", "NewCLI")
   ```

3. Add tab icon in `Chau7OverlayView.swift`:
   ```swift
   case "NewCLI":
       return "sf.symbol.name"
   ```

4. Add tests:
   ```swift
   func testDetectNewCLI() {
       XCTAssertEqual(CommandDetection.detectApp(from: "new-cli"), "NewCLI")
   }
   ```

5. Run `swift test` to verify

## File Locations

| Purpose | Location |
|---------|----------|
| Main app entry | `apps/chau7-macos/Sources/Chau7/Chau7App.swift` |
| App delegate | `apps/chau7-macos/Sources/Chau7/AppDelegate.swift` |
| Terminal session | `apps/chau7-macos/Sources/Chau7/TerminalSessionModel.swift` |
| AI detection (testable) | `apps/chau7-macos/Sources/Chau7Core/CommandDetection.swift` |
| Debug tools | `apps/chau7-macos/Sources/Chau7/DebugContext.swift`, `apps/chau7-macos/Sources/Chau7/DebugConsoleView.swift` |
| Tests | `apps/chau7-macos/Tests/Chau7Tests/CommandDetectionTests.swift` |
| Logs | `~/Library/Logs/Chau7.log` |
| Bug reports | `~/.chau7/reports/` |
| State snapshots | `~/.chau7/snapshots/` |

## Common Tasks

### Adding a New Feature

1. Plan the implementation
2. Extract testable logic to Chau7Core if applicable
3. Write tests first (TDD) or alongside implementation
4. Implement in Chau7
5. Run `swift test`
6. Run `swift build`
7. Test manually with Debug Console (Cmd+Shift+D)

### Debugging an Issue

1. Open Debug Console (Cmd+Shift+D)
2. Check State tab for current app state
3. Check Events tab for recent Claude Code activity
4. Check Logs tab for errors
5. Generate bug report if needed
6. Check `~/Library/Logs/Chau7.log` for full history

### Fixing a Bug

1. Reproduce the issue
2. Add a failing test that demonstrates the bug
3. Fix the code
4. Verify test passes
5. Run full test suite: `swift test`
