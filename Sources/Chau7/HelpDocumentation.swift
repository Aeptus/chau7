import SwiftUI
import AppKit

// MARK: - Help Topic

struct HelpTopic: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let icon: String
    let content: String
    let relatedTopics: [String]

    init(title: String, icon: String, content: String, relatedTopics: [String] = []) {
        self.title = title
        self.icon = icon
        self.content = content
        self.relatedTopics = relatedTopics
    }
}

// MARK: - Help Content

enum HelpContent {
    static let topics: [HelpTopic] = [
        // Getting Started
        HelpTopic(
            title: "Getting Started",
            icon: "play.circle",
            content: """
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
            """,
            relatedTopics: ["Tabs & Windows", "Command Palette", "Settings"]
        ),

        // Tabs & Windows
        HelpTopic(
            title: "Tabs & Windows",
            icon: "rectangle.stack",
            content: """
            # Working with Tabs & Windows

            ## Tab Management

            | Action | Shortcut |
            |--------|----------|
            | New Tab | ⌘T |
            | Close Tab | ⌘W |
            | Close Other Tabs | ⌥⌘W |
            | Next Tab | ⇧⌘] or ⌃Tab |
            | Previous Tab | ⇧⌘[ or ⌃⇧Tab |
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

            ## Tab Colors

            Each tab can have a custom color. Right-click a tab or use **⇧⌘R** to change its color. Tabs can also be automatically colored based on the AI CLI you're using.
            """,
            relatedTopics: ["Getting Started", "AI Integration"]
        ),

        // Command Palette
        HelpTopic(
            title: "Command Palette",
            icon: "command",
            content: """
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
            """,
            relatedTopics: ["Keyboard Shortcuts", "Getting Started"]
        ),

        // SSH Manager
        HelpTopic(
            title: "SSH Manager",
            icon: "server.rack",
            content: """
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
            """,
            relatedTopics: ["Tabs & Windows", "Terminal Features"]
        ),

        // AI Integration
        HelpTopic(
            title: "AI Integration",
            icon: "sparkles",
            content: """
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
            """,
            relatedTopics: ["Tabs & Windows", "Settings"]
        ),

        // Keyboard Shortcuts
        HelpTopic(
            title: "Keyboard Shortcuts",
            icon: "keyboard",
            content: """
            # Keyboard Shortcuts

            Chau7 provides extensive keyboard shortcuts for efficient navigation.

            ## Customizing Shortcuts

            Open the Keyboard Shortcuts editor from:
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
            """,
            relatedTopics: ["Command Palette", "Settings"]
        ),

        // Terminal Features
        HelpTopic(
            title: "Terminal Features",
            icon: "terminal",
            content: """
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
            """,
            relatedTopics: ["Settings", "Keyboard Shortcuts"]
        ),

        // Snippets
        HelpTopic(
            title: "Snippets",
            icon: "text.badge.plus",
            content: """
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
            """,
            relatedTopics: ["Productivity", "Settings"]
        ),

        // Settings
        HelpTopic(
            title: "Settings",
            icon: "gear",
            content: """
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
            """,
            relatedTopics: ["Getting Started", "Appearance"]
        ),
    ]

    static func topic(titled: String) -> HelpTopic? {
        topics.first { $0.title == titled }
    }
}

// MARK: - Help Window View

struct HelpWindowView: View {
    @State private var selectedTopic: HelpTopic? = HelpContent.topics.first
    @State private var searchText = ""

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
                    TextField("Search help...", text: $searchText)
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
                        if !topic.relatedTopics.isEmpty {
                            Divider()
                                .padding(.vertical, 8)

                            Text("Related Topics")
                                .font(.headline)
                                .foregroundColor(.secondary)

                            HStack(spacing: 12) {
                                ForEach(topic.relatedTopics, id: \.self) { related in
                                    Button {
                                        if let relatedTopic = HelpContent.topic(titled: related) {
                                            selectedTopic = relatedTopic
                                        }
                                    } label: {
                                        HStack {
                                            if let relatedTopic = HelpContent.topic(titled: related) {
                                                Image(systemName: relatedTopic.icon)
                                            }
                                            Text(related)
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
                    Text("Select a topic")
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
                            Text("•")
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
                    ForEach(Array(rows[0].enumerated()), id: \.offset) { idx, header in
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

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let view = HelpWindowView()
        let hostingView = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Chau7 Help"
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }
}
