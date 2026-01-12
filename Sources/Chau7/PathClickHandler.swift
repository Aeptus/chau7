import Foundation
import AppKit
import Chau7Core

// MARK: - F03: Path Click Handler

/// Handles Cmd+Click on file paths and URLs in terminal output
struct PathClickHandler {
    struct PathMatch {
        let path: String
        let line: Int?
        let column: Int?
        let range: NSRange
    }

    static func findPaths(in text: String) -> [PathMatch] {
        var matches: [PathMatch] = []
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)

        RegexPatterns.filePath.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match = match else { return }

            // Group 1: file path
            guard match.range(at: 1).location != NSNotFound else { return }
            let path = nsText.substring(with: match.range(at: 1))

            // Group 2: line number (optional)
            var line: Int? = nil
            if match.range(at: 2).location != NSNotFound {
                line = Int(nsText.substring(with: match.range(at: 2)))
            }

            // Group 3: column number (optional)
            var column: Int? = nil
            if match.range(at: 3).location != NSNotFound {
                column = Int(nsText.substring(with: match.range(at: 3)))
            }

            matches.append(PathMatch(path: path, line: line, column: column, range: match.range))
        }

        return matches
    }

    static func openPath(_ match: PathMatch, relativeTo workingDir: String) {
        var fullPath = match.path

        // Resolve relative paths
        if !fullPath.hasPrefix("/") {
            if fullPath.hasPrefix("~") {
                fullPath = FileManager.default.homeDirectoryForCurrentUser.path + String(fullPath.dropFirst())
            } else {
                fullPath = URL(fileURLWithPath: workingDir).appendingPathComponent(fullPath).path
            }
        }

        // Check if file exists
        guard FileManager.default.fileExists(atPath: fullPath) else {
            Log.warn("Path does not exist: \(fullPath)")
            return
        }

        // Determine editor
        let settings = FeatureSettings.shared
        var editorCommand = settings.defaultEditor

        if editorCommand.isEmpty {
            editorCommand = ProcessInfo.processInfo.environment["EDITOR"] ?? ""
        }

        // Validate and sanitize the path before use
        guard ShellEscaping.isValidPath(fullPath) else {
            Log.warn("PathClickHandler: Invalid path detected, refusing to open")
            return
        }
        let safePath = ShellEscaping.escapePath(fullPath)

        if editorCommand.isEmpty {
            // Use system default (open command)
            if let line = match.line {
                // Try common editors with line number support
                // Using properly escaped path for security
                let commonEditors = [
                    ("code", "--goto \(safePath):\(line):\(match.column ?? 1)"),
                    ("subl", "\(safePath):\(line):\(match.column ?? 1)"),
                    ("atom", "\(safePath):\(line):\(match.column ?? 1)")
                ]

                for (editor, args) in commonEditors {
                    if let editorPath = findExecutable(editor) {
                        runCommand(ShellEscaping.escapeArgument(editorPath) + " " + args)
                        return
                    }
                }
            }

            // Fallback: just open the file using NSWorkspace (safe, no shell)
            NSWorkspace.shared.open(URL(fileURLWithPath: fullPath))
        } else {
            // Use configured editor with proper escaping
            let safeEditor = ShellEscaping.escapeArgument(editorCommand)

            if let line = match.line {
                // Try to add line number based on editor
                if editorCommand.contains("code") || editorCommand.contains("subl") {
                    runCommand("\(safeEditor) --goto \(safePath):\(line):\(match.column ?? 1)")
                } else if editorCommand.contains("vim") || editorCommand.contains("nvim") {
                    runCommand("\(safeEditor) +\(line) \(safePath)")
                } else if editorCommand.contains("emacs") {
                    runCommand("\(safeEditor) +\(line):\(match.column ?? 1) \(safePath)")
                } else {
                    runCommand("\(safeEditor) \(safePath)")
                }
            } else {
                runCommand("\(safeEditor) \(safePath)")
            }
        }
    }

    static func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        let handler = FeatureSettings.shared.urlHandler
        guard let bundleID = handler.bundleIdentifier else {
            NSWorkspace.shared.open(url)
            return
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config, completionHandler: nil)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private static func findExecutable(_ name: String) -> String? {
        let paths = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin"]
        for dir in paths {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private static func runCommand(_ command: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", command]
        task.standardOutput = nil
        task.standardError = nil
        do {
            try task.run()
        } catch {
            Log.warn("PathClickHandler: Failed to run command: \(error.localizedDescription)")
        }
    }
}
