import AppKit

// chau7:// URL scheme handling, split out of AppDelegate.swift verbatim.
// `application(_:open:)` satisfies the NSApplicationDelegate requirement from
// this extension; the private helpers stay file-private to this scheme handler.
extension AppDelegate {

    // MARK: - URL Scheme Handler (chau7://)

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleChau7URL(url)
        }
    }

    private func handleChau7URL(_ url: URL) {
        guard url.scheme == "chau7" else { return }
        let host = url.host ?? ""
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        Log.info("AppDelegate: URL handler: \(url)")

        switch host {
        case "run":
            // chau7://run/<base64-encoded-command>
            guard !path.isEmpty,
                  let data = Data(base64Encoded: path),
                  let command = String(data: data, encoding: .utf8) else {
                Log.warn("AppDelegate: chau7://run — invalid base64 command")
                return
            }
            confirmAndRun(command: command, source: url.absoluteString)

        case "ssh":
            // chau7://ssh/user@host or chau7://ssh/user@host:port
            guard !path.isEmpty else { return }
            let sanitized = path.replacingOccurrences(of: "'", with: "'\\''")
            openNewTabWithCommand("ssh '\(sanitized)'")

        case "cd":
            // chau7://cd/path/to/directory
            let dir = "/" + path // URL path is already absolute minus leading /
            openNewTabWithCommand("cd '\(dir.replacingOccurrences(of: "'", with: "'\\''"))' && clear")

        case "open":
            // chau7://open/path/to/file.md — open file in editor pane
            let filePath = "/" + path
            ensureActiveOverlayModel()?.openTextEditorInCurrentTab(filePath: filePath)

        default:
            Log.warn("AppDelegate: unknown chau7:// host: \(host)")
        }
    }

    private func confirmAndRun(command: String, source: String) {
        let alert = NSAlert()
        alert.messageText = L("alert.urlCommand.title", "Run command from URL?")
        alert.informativeText = String(format: L("alert.urlCommand.message", "A URL is requesting to run:\n\n%@\n\nSource: %@"), String(command.prefix(500)), source)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("alert.urlCommand.confirm", "Run"))
        alert.addButton(withTitle: L("action.cancel", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        openNewTabWithCommand(command)
    }

    private func openNewTabWithCommand(_ command: String) {
        guard let model = ensureActiveOverlayModel() else { return }
        model.newTab()
        // Delay slightly to let the terminal initialize
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            model.selectedTab?.session?.sendInput(command + "\n")
        }
    }
}
