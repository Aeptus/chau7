import AppKit
import SwiftUI

/// Floating panel that displays files changed by the last AI command.
/// Shown via Cmd+Shift+G (showChangedFiles keybinding).
final class ChangedFilesPanel {
    private static var panel: NSPanel?

    @MainActor
    static func show(files: [String]) {
        // Dismiss existing panel
        panel?.close()

        let view = ChangedFilesView(files: files)
        let hosting = NSHostingController(rootView: view)

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: min(CGFloat(files.count * 24 + 80), 500)),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        p.title = "Changed Files (\(files.count))"
        p.contentViewController = hosting
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.center()
        p.makeKeyAndOrderFront(nil)

        panel = p
    }
}

private struct ChangedFilesView: View {
    let files: [String]
    @State private var searchText = ""

    private var filtered: [String] {
        if searchText.isEmpty { return files }
        return files.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search field
            TextField("Filter files...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(8)

            Divider()

            // File list
            List(filtered, id: \.self) { file in
                HStack(spacing: 6) {
                    Image(systemName: iconForFile(file))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(file)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .contextMenu {
                    Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(file, forType: .string) }
                    Button("Copy All Paths") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(files.joined(separator: "\n"), forType: .string)
                    }
                }
            }
            .listStyle(.plain)

            Divider()

            // Footer
            HStack {
                Text("\(filtered.count) file\(filtered.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Spacer()
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(files.joined(separator: "\n"), forType: .string)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(8)
        }
        .frame(minWidth: 300, minHeight: 200)
    }

    private func iconForFile(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "rs": return "gearshape"
        case "go": return "server.rack"
        case "ts", "tsx", "js", "jsx": return "chevron.left.forwardslash.chevron.right"
        case "css", "scss": return "paintpalette"
        case "html": return "globe"
        case "json", "yaml", "yml", "toml": return "doc.text"
        case "md": return "text.document"
        case "png", "jpg", "jpeg", "svg": return "photo"
        default: return "doc"
        }
    }
}
