# Views

Swift: `apps/chau7-macos/Sources/Chau7/Views/` (3 files, 1493 lines)
Swift tests: none
Wave: 5 (see README.md)
Depends on: App, Localization

Startup and help screens: the loading splash, the first launch welcome screen,
the help window with its topics, and the tip box printed at the top of every new
terminal.

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| VWS-001 | Loading splash on every launch (app icon, "Chau7", spinner in a dark borderless floating panel) while the shells start, fading out after about 1.5 s when the terminal windows appear | `Views/SplashView.swift` (`SplashView`, `SplashWindowController.show`), `App/AppDelegate.swift` |  | chau7_next/src/views/launch.rs, chau7_next_core/src/welcome.rs | done | NSWindow |
| VWS-002 | Welcome screen on first launch: three tips (tabs carry context, the menu bar command center, shortcuts) and a Get Started button; it closes once the user clicked and the app is ready, then is never shown again (`app.hasShownWelcome`) | `Views/SplashView.swift` (`WelcomeView`, `showWelcome`, `markAppReady`) |  | chau7_next/src/views/launch.rs, chau7_next_core/src/welcome.rs | done | NSWindow |
| VWS-003 | Help window: topic list with icons, search across titles and content, one topic shown at a time with Related Topics buttons; one window reused, can open on a given topic | `Views/HelpDocumentation.swift` (`HelpWindowView`, `HelpWindowController`) |  | chau7_next/src/views/help_window.rs, chau7_next_core/src/help.rs, chau7_next_core/src/help_topics/ | done | NSWindow |
| VWS-004 | Help content renders simple Markdown: three heading levels, "- " bullet lists, fenced code blocks, pipe tables and bold | `Views/HelpDocumentation.swift` (`MarkdownContentView`, `TableView`) |  | chau7_next/src/views/help_window.rs, chau7_next_core/src/help.rs, chau7_next_core/src/help_topics/ | done |  |
| VWS-005 | Help topics: Getting Started, Tabs and Windows, Command Palette, SSH Manager, AI Integration, Keyboard Shortcuts, Terminal Features, Snippets, Token Optimizer, Settings, Technology, Licenses & Acknowledgments (11 topics, localized) | `Views/HelpDocumentation.swift` (`HelpContent.topics`) |  | chau7_next/src/views/help_window.rs, chau7_next_core/src/help.rs, chau7_next_core/src/help_topics/ | done |  |
| VWS-006 | Technology, Licenses & Acknowledgments page: monorepo layout, languages, Rust crates, bundled helpers, third-party licenses (swift-atomics, RTK fork), system frameworks | `Views/HelpDocumentation.swift` (`technologyLicensesContent`) |  | chau7_next/src/views/help_window.rs, chau7_next_core/src/help.rs, chau7_next_core/src/help_topics/ | done |  |
| VWS-007 | Every new terminal starts with a framed tip box showing a random power user tip with its shortcut (36 tips: tabs, search, splits, selection, mouse, productivity) instead of "Last login" | `Views/PowerUserTips.swift`, `Terminal/Views/TerminalViewRepresentable.swift` (`terminalHeaderBox`) |  | chau7_next_core/src/shell_tips.rs, chau7_next/src/terminal/session.rs | done |  |

## Notes

- VWS-001 and VWS-002 timing: `AppDelegate` keeps the terminal windows hidden
  and calls `markAppReady` 1.5 s after setup; the welcome screen closes only
  when both that happened and the user clicked Get Started. Help > Welcome to
  Chau7 shows the same screen again (APP-069 in `App.md`).
- The splash and welcome windows follow the app theme (`windowAppearance`).
- VWS-007 tip box: drawn in bright white ANSI, two columns of margin, message
  centered and truncated with "..."; the lightbulb emoji becomes "TIP" and the
  symbols for Cmd and Shift become "CMD+" and "SHIFT+". Tip text comes from
  localization keys `tip.*`. If the terminal is narrower than 26 columns no box
  is printed.
- Several tips and help topics describe Swift shortcuts and features that
  Chau7 Next lacks or binds differently (see the shortcut conflicts in
  `App.md`); port the content with the shortcuts Chau7 Next actually uses.
- The welcome screen strings ("Welcome to Chau7", the three tips, "Get
  Started") are hard coded in English, not localized.
- `AppDelegate.showReleaseNotes` ("What's New in Chau7" alert) has no caller and
  is not listed.
