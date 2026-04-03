import SwiftUI
import AppKit

// MARK: - Help Topic

struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let content: String
    let relatedTopicIDs: [String]

    init(id: String, title: String, icon: String, content: String, relatedTopicIDs: [String] = []) {
        self.id = id
        self.title = title
        self.icon = icon
        self.content = content
        self.relatedTopicIDs = relatedTopicIDs
    }
}

// MARK: - Help Content

enum HelpContent {
    static let technologyLicensesContent = """
    # Technology, Licenses & Acknowledgments

    This page summarizes the Chau7 monorepo, the technologies used to build it, and the third-party notices kept with the repository.

    ## Monorepo Layout

    ```text
    apps/chau7-macos        macOS app
    apps/chau7-ios          iOS companion app
    services/chau7-relay    Cloudflare relay
    services/chau7-remote   Go remote agent
    docs/remote-control     protocol and UX spec
    ```

    ## Languages and Platforms

    | Area | Main tech |
    |------|-----------|
    | macOS app UI | Swift, SwiftUI, AppKit |
    | Shared app logic | Swift (`Chau7Core`) |
    | Native rendering/performance helpers | Rust |
    | Local proxy binary | Go |
    | Relay service | Cloudflare Workers + Durable Objects, npm build flow |
    | iOS companion | Swift, Xcode, ActivityKit |
    | Build and packaging glue | Shell scripts |

    ## macOS App Components

    | Component | Path | Notes |
    |-----------|------|-------|
    | Main app | `apps/chau7-macos/Sources/Chau7` | SwiftUI/AppKit executable target |
    | Shared core | `apps/chau7-macos/Sources/Chau7Core` | Testable Swift logic shared by app features |
    | Rust workspace | `apps/chau7-macos/rust` | Native crates used by the macOS app |
    | Go proxy | `apps/chau7-macos/chau7-proxy` | Local TLS/WSS proxy binary bundled into the app |

    ## Rust Crates in the macOS App

    | Crate | Purpose |
    |------|---------|
    | `chau7_terminal` | Terminal backend and rendering support |
    | `chau7_parse` | Parsing helpers |
    | `chau7_md` | Markdown-to-terminal rendering helper |
    | `chau7_optim` | Built-in command token optimizer |

    ## Bundled Helper Binaries

    The macOS app build scripts bundle helper binaries into the app resources, including:

    - `chau7-optim`
    - `chau7-md`
    - `chau7-proxy`

    ## Main Repository Paths

    Chau7 is developed as a single monorepo. The main paths are:

    - `apps/chau7-macos`
    - `apps/chau7-ios`
    - `services/chau7-relay`
    - `services/chau7-remote`
    - `docs/remote-control`

    ## Direct Third-Party Dependencies

    | Dependency | Upstream repo | Used for | License |
    |-----------|---------------|----------|---------|
    | `swift-atomics` | `https://github.com/apple/swift-atomics` | Swift atomic primitives used by app performance/concurrency code | Apache-2.0 |

    ## RTK-Derived Code

    Chau7 contains a modified fork of RTK inside:

    - `apps/chau7-macos/rust/chau7_optim`

    Recorded provenance:

    - Upstream repo: `https://github.com/rtk-ai/rtk`
    - Local fork record: `apps/chau7-macos/rust/chau7_optim/UPSTREAM-SYNC.md`
    - Preserved MIT text: `apps/chau7-macos/rust/chau7_optim/LICENSE-RTK`
    - Conservative Apache notice copy: `apps/chau7-macos/rust/chau7_optim/LICENSE-RTK-APACHE`
    - Repo-wide notice index: `THIRD_PARTY_NOTICES.md`

    Licensing note:

    - The imported fork is dual-licensed under Apache 2.0 OR MIT, at your option.
    - Both license texts are preserved locally for full attribution.

    ## System Frameworks

    The macOS target links Apple system frameworks including:

    - Metal
    - MetalKit
    - IOKit
    - IOSurface
    - CoreVideo
    - SwiftUI
    - AppKit
    - Foundation

    ## Cloud and Remote Components

    | Component | Path | Stack |
    |-----------|------|-------|
    | Relay | `services/chau7-relay` | Cloudflare Workers + Durable Objects |
    | Remote agent | `services/chau7-remote` | Go |
    | iOS companion | `apps/chau7-ios` | Swift / Xcode project |

    ## Notice Files

    For source-level notices kept in this repository, start with:

    - `THIRD_PARTY_NOTICES.md`
    - `apps/chau7-macos/rust/chau7_optim/LICENSE-RTK`
    - `apps/chau7-macos/rust/chau7_optim/LICENSE-RTK-APACHE`
    - `apps/chau7-macos/rust/chau7_optim/UPSTREAM-SYNC.md`
    """

    static let topics: [HelpTopic] = [
        // Getting Started
        HelpTopic(
            id: "getting-started",
            title: L("help.topic.gettingStarted.title", "Getting Started"),
            icon: "play.circle",
            content: L("help.topic.gettingStarted.content", """
            # Welcome to Chau7

            Chau7 is a modern terminal emulator designed for AI-assisted development. It provides a rich set of features to enhance your command-line workflow.

            ## Quick Start

            1. **Create a new tab**: Press **⌘T** or click the + button
            2. **Close a tab**: Press **⌘W** or click the X on the tab
            3. **Switch between tabs**: Press **⌘1-9** or click the tab
            4. **Open settings**: Press **⌘,**

            ## Key Features

            - **AI CLI Detection**: Automatically detects Claude, Codex, Gemini and other AI CLIs
            - **Command Palette**: Press **⇧⌘P** to access all commands
            - **SSH Manager**: Manage your SSH connections easily
            - **Split Panes**: Work with multiple terminals side by side
            - **Snippets**: Save and reuse common commands
            """),
            relatedTopicIDs: ["tabs-windows", "command-palette", "settings"]
        ),

        // Tabs & Windows
        HelpTopic(
            id: "tabs-windows",
            title: L("help.topic.tabsWindows.title", "Tabs & Windows"),
            icon: "rectangle.stack",
            content: L("help.topic.tabsWindows.content", """
            # Working with Tabs & Windows

            ## Tab Management

            | Action | Shortcut |
            |--------|----------|
            | New Tab | ⌘T |
            | Close Tab | ⌘W |
            | Close Other Tabs | ⌥⌘W |
            | Next Tab | ⇧⌘] or ⌃Tab or ⌥⌘→ |
            | Previous Tab | ⇧⌘[ or ⌃⇧Tab or ⌥⌘← |
            | Select Tab 1-9 | ⌘1-9 |
            | Move Tab Right | ⇧⌥⌘] |
            | Move Tab Left | ⇧⌥⌘[ |
            | Rename Tab | ⇧⌘R |

            ## Window Management

            | Action | Shortcut |
            |--------|----------|
            | New Window | ⌘N |
            | Close Window | ⇧⌘W |
            | Full Screen | ⌃⌘F |

            ## Moving Tabs Between Windows

            **Right-click menu:** Right-click any tab → **Move to Window** → select the target window or **New Window**. For grouped tabs, right-click the group bracket (repo name) → **Move Group to Window**.

            **Drag and drop:** In windowed (non-fullscreen) mode, drag a tab or group bracket to the other visible window. Note: drag between windows does not work in fullscreen mode — macOS prevents cursor movement between fullscreen Spaces during drag. Use the right-click menu instead.

            ## Repo Tab Grouping

            Tabs in the same git repository are automatically grouped with a colored bracket showing the repo name. Right-click the bracket for group actions (move group, ungroup, close group). You can also manually group tabs via right-click → **Group All Same Repo**.

            ## Tab Colors

            Each tab can have a custom color. Right-click a tab or use **⇧⌘R** to change its color. Tabs can also be automatically colored based on the AI CLI you're using.
            """),
            relatedTopicIDs: ["getting-started", "ai-integration"]
        ),

        // Command Palette
        HelpTopic(
            id: "command-palette",
            title: L("help.topic.commandPalette.title", "Command Palette"),
            icon: "command",
            content: L("help.topic.commandPalette.content", """
            # Command Palette

            The Command Palette provides quick access to all Chau7 commands without memorizing keyboard shortcuts.

            ## Opening the Command Palette

            Press **⇧⌘P** to open the Command Palette.

            ## Using the Command Palette

            1. Start typing to filter commands
            2. Use **↑** and **↓** arrows to navigate
            3. Press **Enter** to execute the selected command
            4. Press **Escape** to close

            ## Available Commands

            The Command Palette includes commands for:
            - File operations (New Tab, Close Tab, Export)
            - Edit operations (Copy, Paste, Find)
            - View settings (Zoom, Clear Screen)
            - Tab management (Navigate, Rename, Move)
            - Window management (Settings, Debug Console)
            - Help (Documentation, About)
            """),
            relatedTopicIDs: ["keyboard-shortcuts", "getting-started"]
        ),

        // SSH Manager
        HelpTopic(
            id: "ssh-manager",
            title: L("help.topic.sshManager.title", "SSH Manager"),
            icon: "server.rack",
            content: L("help.topic.sshManager.content", """
            # SSH Connection Manager

            Manage your SSH connections in one place. Save hosts, configure options, and connect with a single click.

            ## Opening SSH Manager

            - Press **⇧⌘O**
            - Or use Command Palette: **⇧⌘P** → "SSH Connections"

            ## Adding a Connection

            1. Click the **+** button
            2. Enter the connection details:
               - **Name**: A friendly name for the connection
               - **Host**: The hostname or IP address
               - **Port**: SSH port (default: 22)
               - **User**: Your username
               - **Identity File**: Path to your SSH key (optional)
               - **Jump Host**: Bastion/proxy host (optional)

            ## Importing from ~/.ssh/config

            Click the **...** menu and select "Import from ~/.ssh/config" to automatically import your existing SSH configurations.

            ## Connecting

            Double-click a connection or select it and click "Connect" to open a new tab with the SSH session.
            """),
            relatedTopicIDs: ["tabs-windows", "terminal-features"]
        ),

        // AI Integration
        HelpTopic(
            id: "ai-integration",
            title: L("help.topic.aiIntegration.title", "AI Integration"),
            icon: "sparkles",
            content: L("help.topic.aiIntegration.content", """
            # AI CLI Integration

            Chau7 automatically detects when you're using AI CLI tools and provides enhanced features.

            ## Supported AI CLIs

            - **Claude Code** (Anthropic)
            - **Codex** (OpenAI)
            - **Gemini** (Google)
            - **ChatGPT** (OpenAI)
            - **GitHub Copilot**

            ## Auto Tab Theming

            When an AI CLI is detected, the tab color automatically changes to match the AI:
            - Claude: Purple
            - Codex: Green
            - Gemini: Blue
            - ChatGPT: Teal
            - Copilot: Orange

            Enable/disable in Settings → AI Integration.

            ## Custom Detection Rules

            Add your own detection rules in Settings → AI Integration → Custom Detection Rules.

            Enter a command pattern and the tab color to use when that pattern is detected.
            """),
            relatedTopicIDs: ["tabs-windows", "settings", "token-optimizer"]
        ),

        // Keyboard Shortcuts
        HelpTopic(
            id: "keyboard-shortcuts",
            title: L("help.topic.keyboardShortcuts.title", "Keyboard Shortcuts"),
            icon: "keyboard",
            content: L("help.topic.keyboardShortcuts.content", """
            # Keyboard Shortcuts

            Chau7 provides extensive keyboard shortcuts for efficient navigation.

            ## Customizing Shortcuts

            Open the Keyboard Shortcuts editor from:
            - **⌘/**: Keyboard Shortcuts
            - Command Palette: **⇧⌘P** → "Keyboard Shortcuts"
            - Settings → Input → Keyboard Shortcuts

            Click any shortcut to record a new key combination.

            ## Default Shortcuts

            ### Window & Tabs
            - **⌘N**: New Window
            - **⌘T**: New Tab
            - **⌘W**: Close Tab
            - **⇧⌘W**: Close Window
            - **⌘1-9**: Switch to Tab

            ### Edit
            - **⌘C**: Copy (or interrupt if no selection)
            - **⌘V**: Paste
            - **⌥⌘V**: Paste Escaped
            - **⌘F**: Find
            - **⌘G**: Find Next
            - **⇧⌘G**: Find Previous

            ### View
            - **⌘=**: Zoom In
            - **⌘-**: Zoom Out
            - **⌘0**: Reset Zoom
            - **⌘K**: Clear Screen
            - **⇧⌘K**: Clear Scrollback
            - **⌃⌘F**: Full Screen

            ### Tools
            - **⇧⌘P**: Command Palette
            - **⇧⌘O**: SSH Connections
            - **⌘;**: Snippets
            - **⇧⌘L**: Debug Console
            """),
            relatedTopicIDs: ["command-palette", "settings"]
        ),

        // Terminal Features
        HelpTopic(
            id: "terminal-features",
            title: L("help.topic.terminalFeatures.title", "Terminal Features"),
            icon: "terminal",
            content: L("help.topic.terminalFeatures.content", """
            # Terminal Features

            ## Mouse Features

            - **Option+Click**: Move cursor to clicked position
            - **⌘+Click**: Open file path or URL
            - **Select text**: Automatically copies if "Copy on Select" is enabled

            ## Inline Images

            Display images directly in the terminal using the imgcat protocol:

            ```bash
            imgcat image.png
            cat image.png | imgcat
            ```

            Enable/disable in Settings → Terminal → Inline Images.

            ## Syntax Highlighting

            Chau7 provides automatic syntax highlighting for:
            - JSON output
            - URLs
            - File paths
            - Error messages

            ## Split Panes

            Split the terminal view to work with multiple terminals:
            - **⌘D**: Split horizontally
            - **⇧⌘D**: Split vertically

            ## Scrollback

            - Default: 10,000 lines
            - Adjustable in Settings → Terminal → Scrollback
            - **Scroll to Top**: Access via Command Palette
            - **Scroll to Bottom**: Access via Command Palette
            """),
            relatedTopicIDs: ["settings", "keyboard-shortcuts"]
        ),

        // Snippets
        HelpTopic(
            id: "snippets",
            title: L("help.topic.snippets.title", "Snippets"),
            icon: "text.badge.plus",
            content: L("help.topic.snippets.content", """
            # Snippets

            Save and reuse common commands with Snippets. Snippets support dynamic tokens, placeholders with Tab navigation, and can be organized by User (available everywhere) or Repo (project-specific).

            ## Quick Access

            - **⌘;**: Open snippet picker in terminal
            - **Command Palette** → "Snippets": Same as above
            - **Command Palette** → "Manage Snippets": Open full snippet manager

            ## Snippet Types

            ### User Snippets
            Available everywhere, stored locally in Chau7. Perfect for personal commands you use across all projects.

            ### Repo Snippets
            Project-specific snippets stored in `.chau7/snippets.json`. Share with your team via version control. Repo snippets override User snippets with the same ID.

            ## Managing Snippets

            Open **Settings → Productivity → Manage Snippets** or use Command Palette → "Manage Snippets" to:
            - Create, edit, and delete snippets
            - Filter by User or Repo snippets
            - Import/Export snippets as JSON
            - See all available tokens

            ## Available Tokens

            Use these tokens in your snippet body:
            - `${cwd}` - Current working directory
            - `${home}` - User home directory
            - `${date}` - Current date (yyyy-MM-dd)
            - `${time}` - Current time (HH:mm:ss)
            - `${clip}` - Clipboard content
            - `${env:VARNAME}` - Environment variable

            ## Placeholders

            Use numbered placeholders for Tab navigation:

            ```
            ssh ${1:user}@${2:host}
            git commit -m "${1:message}"
            docker run -it ${1:image} ${2:command}
            ```

            Press **Tab** to move to next placeholder, **Shift+Tab** for previous.

            ## Repository Snippets Setup

            1. Enable "Repository Snippets" in Settings
            2. Create `.chau7/snippets.json` in your repo:

            ```json
            {
              "version": 1,
              "snippets": [
                {
                  "id": "deploy-prod",
                  "title": "Deploy to Production",
                  "body": "npm run deploy --env=${1:production}",
                  "tags": ["deploy", "npm"]
                }
              ]
            }
            ```
            """),
            relatedTopicIDs: ["settings"]
        ),

        // Token Optimizer
        HelpTopic(
            id: "token-optimizer",
            title: L("help.topic.tokenOptimizer.title", "Token Optimizer"),
            icon: "bolt.shield",
            content: L("help.topic.tokenOptimizer.content", """
            # Token Optimizer (CTO)

            The Chau7 Token Optimizer reduces the number of tokens AI CLI tools consume by compacting command output before it reaches the model. It works transparently — your commands run normally, but their output is reformatted into a denser representation that preserves all useful information.

            ## How It Works

            When the optimizer is active, Chau7 inserts lightweight wrapper scripts into your PATH. \
            These wrappers intercept supported commands, route them through the `chau7-optim` binary, \
            and produce compact output. If the optimizer can't handle a particular invocation, \
            it falls through to the real binary — your commands always work.

            ```
            you type: grep "TODO" src/
                 ↓
            wrapper intercepts
                 ↓
            chau7-optim grep "TODO" src/
                 ↓
            compact output → AI reads fewer tokens
            ```

            The optimizer is only active in tabs where an AI CLI is detected (Claude, Codex, Gemini, etc.). Regular terminal usage is never affected.

            ## Enabling the Optimizer

            Go to **Settings → Token Optimization** to enable CTO. You can also toggle it per-tab from the tab context menu.

            ## Supported Commands

            The optimizer handles 30+ commands across multiple ecosystems. Below are examples showing native output vs. optimized output.

            ### grep — Compact Search Results

            Groups matches by file, truncates long lines, and shows a match summary.

            ```
            ── native grep ──────────────────────
            src/auth/middleware.ts:12:  if (!session.token) {
            src/auth/middleware.ts:45:  const token = req.headers.authorization;
            src/auth/middleware.ts:89:  validateToken(token);
            src/api/handler.ts:7:     const token = getToken();
            src/api/handler.ts:23:    refreshToken(token);

            ── optimized ────────────────────────
            🔍 5 in 2F:

            📄 src/auth/middleware.ts (3):
              12: if (!session.token) {
              45: const token = req.headers.authorization;
              89: validateToken(token);

            📄 src/api/handler.ts (2):
               7: const token = getToken();
              23: refreshToken(token);
            ```

            ### cat / read — Filtered File Reading

            Strips blank lines, comments, and boilerplate. Shows line numbers for context.

            ```
            ── native cat ───────────────────────
            // Copyright 2024 Acme Corp
            // Licensed under MIT
            //
            // Main application entry point
            //

            import express from "express";

            // Create app
            const app = express();

            // Start server
            app.listen(3000);

            ── optimized ────────────────────────
               1│ import express from "express";
               2│ const app = express();
               3│ app.listen(3000);
            ```

            ### git status — Compact Status

            Merges staged/unstaged into a single view with change-type icons.

            ```
            ── native git status ────────────────
            On branch main
            Your branch is up to date with 'origin/main'.

            Changes to be committed:
              (use "git restore --staged..." to unstage)
                    modified:   src/index.ts
                    new file:   src/utils.ts

            Changes not staged for commit:
              (use "git add..." to update)
                    modified:   README.md

            ── optimized ────────────────────────
            main ≡ origin/main
            M  src/index.ts
            A  src/utils.ts
            ?M README.md
            ```

            ### git diff — Condensed Diff

            Shows only changed lines with minimal context, strips diff headers.

            ```
            ── native git diff ──────────────────
            diff --git a/src/app.ts b/src/app.ts
            index 1a2b3c4..5d6e7f8 100644
            --- a/src/app.ts
            +++ b/src/app.ts
            @@ -10,7 +10,7 @@ export class App {
               private db: Database;
               private cache: Cache;

            -  constructor() {
            +  constructor(config: AppConfig) {
                 this.db = new Database();

            ── optimized ────────────────────────
            src/app.ts:
            -  constructor() {
            +  constructor(config: AppConfig) {
            ```

            ### git log — One-Line History

            Compresses log to one line per commit with short hashes.

            ```
            ── native git log ───────────────────
            commit a1b2c3d (HEAD -> main, origin/main)
            Author: Jane Dev <jane@example.com>
            Date:   Mon Mar 3 14:30:00 2026 +0100

                Fix auth token refresh loop

            commit e4f5g6h
            Author: Jane Dev <jane@example.com>
            Date:   Mon Mar 3 12:00:00 2026 +0100

                Add rate limiting middleware

            ── optimized ────────────────────────
            a1b2c3d Fix auth token refresh loop
            e4f5g6h Add rate limiting middleware
            ```

            ### cargo test — Failures Only

            Strips all passing tests and compilation progress, shows only failures.

            ```
            ── native cargo test ────────────────
               Compiling serde v1.0.228
               Compiling tokio v1.43.0
               Compiling myapp v0.1.0
                Finished test target(s) in 12.34s
                 Running unittests src/lib.rs
            running 47 tests
            test auth::tests::login_success ... ok
            test auth::tests::login_failure ... ok
            test api::tests::handler_404 ... FAILED
            test api::tests::handler_200 ... ok
            ... (43 more ok lines)

            ── optimized ────────────────────────
            ✗ 1/47 failed (12.3s)

            FAIL api::tests::handler_404
              assert_eq!(status, 404)
              left: 200, right: 404
            ```

            ### curl — Auto-JSON Schema

            Detects JSON responses and shows structure without values.

            ```
            ── native curl ──────────────────────
            {"users":[{"id":1,"name":"Alice",
            "email":"alice@example.com","role":"admin",
            "created_at":"2026-01-15T10:30:00Z"},
            {"id":2,"name":"Bob",...}],"total":142,
            "page":1,"per_page":20}

            ── optimized ────────────────────────
            {
              users: [{id, name, email, role, created_at}],
              total, page, per_page
            }
            ```

            ### docker ps — Compact Containers

            Strips padding and aligns output to minimal width.

            ```
            ── native docker ps ─────────────────
            CONTAINER ID   IMAGE          COMMAND       CREATED        STATUS        PORTS                    NAMES
            a1b2c3d4e5f6   postgres:16    "docker..."   2 hours ago    Up 2 hours    0.0.0.0:5432->5432/tcp   db
            f6e5d4c3b2a1   redis:7        "docker..."   2 hours ago    Up 2 hours    0.0.0.0:6379->6379/tcp   cache

            ── optimized ────────────────────────
            a1b2c3d4 postgres:16 Up 2h :5432 db
            f6e5d4c3 redis:7    Up 2h :6379 cache
            ```

            ### tsc — Grouped TypeScript Errors

            Groups errors by file instead of listing them flat.

            ```
            ── native tsc ───────────────────────
            src/api.ts(12,5): error TS2345: Argument of
              type 'string' is not assignable to 'number'.
            src/api.ts(45,10): error TS2339: Property
              'foo' does not exist on type 'Bar'.
            src/utils.ts(8,3): error TS7006: Parameter
              'x' implicitly has an 'any' type.

            ── optimized ────────────────────────
            3 errors in 2 files

            src/api.ts (2):
              12: TS2345 string ≠ number
              45: TS2339 'foo' missing on Bar

            src/utils.ts (1):
               8: TS7006 implicit any
            ```

            ## Full Command Reference

            ### Core Utilities
            - **grep**: Groups by file, truncates lines, shows match count
            - **cat** (read): Strips comments/blanks, shows line numbers
            - **ls**: Compact directory listing
            - **tree**: Token-efficient tree output
            - **find**: Compact file search with tree output
            - **wc**: Strips padding and paths
            - **diff**: Only changed lines, no headers
            - **curl**: Auto-detects JSON, shows schema
            - **wget**: Strips progress bars

            ### Git
            - **git status**: Single-line per file, branch info
            - **git diff**: Condensed diff, minimal context
            - **git log**: One line per commit
            - **git show**: Commit summary + compact diff
            - **git branch**: Current/local/remote grouped
            - **git stash**: Compact stash listing

            ### JavaScript / TypeScript
            - **npm**: Strips boilerplate from npm run
            - **npx**: Routes to specialized filters (tsc, eslint, prisma)
            - **pnpm**: Ultra-compact list, outdated, install
            - **vitest**: Failures only, 90% token reduction
            - **tsc**: Errors grouped by file
            - **lint** (ESLint): Violations grouped by rule
            - **prettier**: Compact format check
            - **next**: Compact Next.js build output
            - **prisma**: Strips ASCII art, compact migrations
            - **playwright**: Compact E2E test results

            ### Rust
            - **cargo build**: Strips Compiling lines, keeps errors
            - **cargo test**: Failures only
            - **cargo clippy**: Warnings grouped by lint rule
            - **cargo check**: Strips Checking lines

            ### Python
            - **pytest**: Compact test results
            - **ruff**: Compact linter/formatter output
            - **pip**: Compact package listing (auto-detects uv)

            ### Go
            - **go test**: Failures only via JSON streaming
            - **go build**: Errors only
            - **go vet**: Compact output
            - **golangci-lint**: Compact linter output

            ### DevOps
            - **docker**: Compact ps, images, logs
            - **docker compose**: Compact services, logs, build
            - **kubectl**: Compact pods, services, logs
            - **gh**: Compact PRs, issues, runs, repos

            ## Fallthrough Behavior

            When the optimizer encounters a command invocation it can't handle (unsupported flags, piped input, etc.), it transparently falls through to the real binary. Your command always runs — the optimizer never blocks execution.

            Flags like `-q` (quiet), `-c` (count), and `-l` (files-only) in grep produce no searchable output, so the optimizer intentionally falls through for those.

            ## Monitoring

            Open the **Debug Console** (⇧⌘L → Token Optimizer tab) to see:
            - **Optimization rate**: Percentage of commands successfully optimized
            - **Tokens saved**: Total token savings from the optimizer
            - **Per-tab breakdown**: Stats for each terminal tab
            - **Recent commands**: Color-coded command history (green = optimized, orange = fallthrough)
            """),
            relatedTopicIDs: ["ai-integration", "settings"]
        ),

        // Settings
        HelpTopic(
            id: "settings",
            title: L("help.topic.settings.title", "Settings"),
            icon: "gear",
            content: L("help.topic.settings.content", """
            # Settings

            Access settings with **⌘,** or from the menu bar.

            ## Settings Sections

            - **General**: Startup, profiles, sync
            - **Appearance**: Font, colors, window opacity
            - **Terminal**: Shell, cursor, scrollback
            - **Tabs**: Behavior, appearance
            - **Input**: Keyboard, mouse settings
            - **Productivity**: Snippets, bookmarks, search
            - **Windows**: Overlay, split panes
            - **AI Integration**: Detection, tab theming
            - **Logs**: History, terminal logs
            - **About**: Version info, links

            ## Settings Profiles

            Create multiple profiles to quickly switch between configurations:
            1. Go to Settings → General → Settings Profiles
            2. Click "Save Current" to create a profile
            3. Select a profile to apply it

            ## Backup & Sync

            Export your settings to a file or enable iCloud sync to share settings across devices.
            """),
            relatedTopicIDs: ["getting-started", "token-optimizer"]
        ),

        // Technology, Licenses & Acknowledgments
        HelpTopic(
            id: "technology-licenses",
            title: L("help.topic.technologyLicenses.title", "Technology, Licenses & Acknowledgments"),
            icon: "doc.text.magnifyingglass",
            content: L("help.topic.technologyLicenses.content", technologyLicensesContent),
            relatedTopicIDs: ["getting-started", "token-optimizer", "settings"]
        )
    ]

    static func topic(id: String) -> HelpTopic? {
        topics.first { $0.id == id }
    }
}

// MARK: - Help Window View

struct HelpWindowView: View {
    @State private var selectedTopic: HelpTopic?
    @State private var searchText = ""

    init(initialTopicID: String? = nil) {
        let initialTopic = initialTopicID.flatMap { HelpContent.topic(id: $0) } ?? HelpContent.topics.first
        _selectedTopic = State(initialValue: initialTopic)
    }

    private var filteredTopics: [HelpTopic] {
        if searchText.isEmpty {
            return HelpContent.topics
        }
        let query = searchText.lowercased()
        return HelpContent.topics.filter {
            $0.title.lowercased().contains(query) ||
                $0.content.lowercased().contains(query)
        }
    }

    var body: some View {
        HSplitView {
            // Sidebar
            VStack(spacing: 0) {
                // Search
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField(L("Search help...", "Search help..."), text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))

                Divider()

                // Topics list
                List(filteredTopics, selection: $selectedTopic) { topic in
                    HStack(spacing: 8) {
                        Image(systemName: topic.icon)
                            .foregroundColor(.accentColor)
                            .frame(width: 20)

                        Text(topic.title)
                            .font(.system(size: 13))
                    }
                    .padding(.vertical, 4)
                    .tag(topic)
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 200, maxWidth: 250)

            // Content
            if let topic = selectedTopic {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Header
                        HStack {
                            Image(systemName: topic.icon)
                                .font(.title)
                                .foregroundColor(.accentColor)
                            Text(topic.title)
                                .font(.title)
                                .fontWeight(.bold)
                        }
                        .padding(.bottom, 8)

                        // Content (rendered as markdown)
                        MarkdownContentView(content: topic.content)

                        // Related topics
                        if !topic.relatedTopicIDs.isEmpty {
                            Divider()
                                .padding(.vertical, 8)

                            Text(L("Related Topics", "Related Topics"))
                                .font(.headline)
                                .foregroundColor(.secondary)

                            HStack(spacing: 12) {
                                ForEach(topic.relatedTopicIDs, id: \.self) { relatedID in
                                    Button {
                                        if let relatedTopic = HelpContent.topic(id: relatedID) {
                                            selectedTopic = relatedTopic
                                        }
                                    } label: {
                                        HStack {
                                            if let relatedTopic = HelpContent.topic(id: relatedID) {
                                                Image(systemName: relatedTopic.icon)
                                                Text(relatedTopic.title)
                                            } else {
                                                Text(relatedID)
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.accentColor.opacity(0.1))
                                        .cornerRadius(8)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text(L("Select a topic", "Select a topic"))
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 700, minHeight: 500)
    }
}

// MARK: - Markdown Content View

private struct MarkdownContentView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(content.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                renderParagraph(paragraph)
            }
        }
    }

    @ViewBuilder
    private func renderParagraph(_ text: String) -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("# ") {
            Text(String(trimmed.dropFirst(2)))
                .font(.title2)
                .fontWeight(.bold)
        } else if trimmed.hasPrefix("## ") {
            Text(String(trimmed.dropFirst(3)))
                .font(.headline)
                .padding(.top, 8)
        } else if trimmed.hasPrefix("### ") {
            Text(String(trimmed.dropFirst(4)))
                .font(.subheadline)
                .fontWeight(.semibold)
        } else if trimmed.hasPrefix("```") {
            // Code block
            let code = trimmed
                .replacingOccurrences(of: "```bash\n", with: "")
                .replacingOccurrences(of: "```\n", with: "")
                .replacingOccurrences(of: "\n```", with: "")
                .replacingOccurrences(of: "```", with: "")

            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(8)
        } else if trimmed.hasPrefix("|") {
            // Table
            TableView(markdown: trimmed)
        } else if trimmed.hasPrefix("- ") {
            // Bullet list
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(trimmed.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    if line.hasPrefix("- ") {
                        HStack(alignment: .top, spacing: 8) {
                            Text(L("•", "•"))
                            renderInlineText(String(line.dropFirst(2)))
                        }
                    }
                }
            }
        } else if !trimmed.isEmpty {
            renderInlineText(trimmed)
        }
    }

    @ViewBuilder
    private func renderInlineText(_ text: String) -> some View {
        // Handle bold (**text**) inline
        let attributed = parseInlineFormatting(text)
        Text(attributed)
            .font(.body)
    }

    private func parseInlineFormatting(_ text: String) -> AttributedString {
        var result = AttributedString(text)

        // Bold: **text**
        let boldPattern = #"\*\*([^*]+)\*\*"#
        if let regex = try? NSRegularExpression(pattern: boldPattern) {
            let nsText = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

            for match in matches.reversed() {
                if let range = Range(match.range, in: text),
                   let contentRange = Range(match.range(at: 1), in: text) {
                    let content = String(text[contentRange])
                    if let attrRange = result.range(of: text[range]) {
                        var boldString = AttributedString(content)
                        boldString.font = .body.bold()
                        result.replaceSubrange(attrRange, with: boldString)
                    }
                }
            }
        }

        return result
    }
}

// MARK: - Simple Table View

private struct TableView: View {
    let markdown: String

    private var rows: [[String]] {
        let lines = markdown.components(separatedBy: "\n")
            .filter { !$0.isEmpty && !$0.contains("---") }

        return lines.map { line in
            line.split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    var body: some View {
        if rows.count > 1 {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 0) {
                    ForEach(Array(rows[0].enumerated()), id: \.offset) { _, header in
                        Text(header)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color(NSColor.separatorColor).opacity(0.3))
                    }
                }

                // Rows
                ForEach(Array(rows.dropFirst().enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { idx, cell in
                            Text(cell)
                                .font(.system(size: 12, design: idx == 1 ? .monospaced : .default))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                    }
                    Divider()
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }
}

// MARK: - Help Window Controller

final class HelpWindowController {
    static let shared = HelpWindowController()

    private var window: NSWindow?

    private init() {}

    func show(topicID: String? = nil) {
        let view = HelpWindowView(initialTopicID: topicID)
        let hostingView = NSHostingView(rootView: view)

        if let existing = window {
            existing.contentView = hostingView
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = L("help.window.title", "Chau7 Help")
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }
}
