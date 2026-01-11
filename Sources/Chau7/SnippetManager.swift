import Foundation
import AppKit

enum SnippetSource: String, Codable, CaseIterable, Identifiable {
    case global  // Stored as "global" for backwards compatibility
    case profile
    case repo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .global:
            return "User"  // User-friendly name (stored as "global")
        case .profile:
            return "Profile"
        case .repo:
            return "Repo"
        }
    }

    var description: String {
        switch self {
        case .global:
            return "Available everywhere"
        case .profile:
            return "Profile-specific"
        case .repo:
            return "Repository-specific"
        }
    }

    var icon: String {
        switch self {
        case .global:
            return "person.fill"
        case .profile:
            return "person.crop.circle"
        case .repo:
            return "folder.fill"
        }
    }
}

struct Snippet: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var body: String
    var tags: [String]
    var folder: String?
    var shells: [String]?
    var createdAt: Date?
    var updatedAt: Date?

    init(
        id: String,
        title: String,
        body: String,
        tags: [String] = [],
        folder: String? = nil,
        shells: [String]? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.tags = tags
        self.folder = folder
        self.shells = shells
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct SnippetFile: Codable {
    var version: Int
    var snippets: [Snippet]
}

struct SnippetEntry: Identifiable, Equatable {
    var id: String { "\(source.rawValue)::\(snippet.id)" }
    var snippet: Snippet
    var source: SnippetSource
    var sourcePath: String
    var isOverridden: Bool
}

struct SnippetDraft: Equatable {
    var id: String
    var title: String
    var body: String
    var tagsText: String
    var folder: String
    var shellsText: String
    var source: SnippetSource

    init(
        id: String = "",
        title: String = "",
        body: String = "",
        tagsText: String = "",
        folder: String = "",
        shellsText: String = "",
        source: SnippetSource = .global
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.tagsText = tagsText
        self.folder = folder
        self.shellsText = shellsText
        self.source = source
    }
}

struct SnippetPlaceholder: Equatable {
    let index: Int
    let start: Int
    let length: Int
}

struct SnippetInsertion {
    let text: String
    let placeholders: [SnippetPlaceholder]
    let finalCursorOffset: Int
}

final class SnippetManager: ObservableObject {
    static let shared = SnippetManager()

    @Published private(set) var entries: [SnippetEntry] = []
    @Published private(set) var repoRoot: String?

    private let queue = DispatchQueue(label: "com.chau7.snippets", qos: .utility)
    private var globalMonitor: FileMonitor?
    private var profileMonitor: FileMonitor?
    private var repoMonitor: FileMonitor?
    private var lastContextPath: String = ""
    private var resolveWorkItem: DispatchWorkItem?

    private init() {
        ensureBaseDirectories()
        setupMonitors()
        reloadAll()
    }

    func updateContextPath(_ path: String) {
        guard FeatureSettings.shared.isSnippetsEnabled else { return }
        let normalized = URL(fileURLWithPath: path).standardized.path
        guard normalized != lastContextPath else { return }
        lastContextPath = normalized

        if let root = repoRoot, normalized == root || normalized.hasPrefix(root + "/") {
            return
        }

        resolveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let root = self.resolveRepoRoot(path: normalized)
            DispatchQueue.main.async {
                if self.repoRoot != root {
                    self.repoRoot = root
                    self.setupMonitors()
                    self.reloadAll()
                }
            }
        }
        resolveWorkItem = work
        queue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func reloadAll() {
        queue.async { [weak self] in
            guard let self else { return }
            guard FeatureSettings.shared.isSnippetsEnabled else {
                DispatchQueue.main.async {
                    self.entries = []
                }
                return
            }
            let globalURL = self.globalURL()
            let profileURL = self.profileURL()
            self.ensureSnippetFileExists(at: globalURL)
            self.ensureSnippetFileExists(at: profileURL)
            if let repoURL = self.repoURL() {
                self.ensureSnippetFileExists(at: repoURL)
            }

            let globalSnippets = self.loadSnippets(from: globalURL)
            let profileSnippets = self.loadSnippets(from: profileURL)
            let repoSnippets = self.repoURL().map { self.loadSnippets(from: $0) } ?? []

            let entries = self.mergeEntries(
                global: globalSnippets,
                profile: profileSnippets,
                repo: repoSnippets
            )
            DispatchQueue.main.async {
                self.entries = entries
            }
        }
    }

    func refreshConfiguration() {
        guard FeatureSettings.shared.isSnippetsEnabled else {
            stopMonitors()
            entries = []
            return
        }
        setupMonitors()
        reloadAll()
    }

    func filteredEntries(query: String) -> [SnippetEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        let lower = trimmed.lowercased()
        return entries.filter { entry in
            let snippet = entry.snippet
            return snippet.title.lowercased().contains(lower)
                || snippet.body.lowercased().contains(lower)
                || snippet.tags.contains(where: { $0.lowercased().contains(lower) })
                || (snippet.folder?.lowercased().contains(lower) ?? false)
        }
    }

    func createSnippet(from draft: SnippetDraft) {
        queue.async { [weak self] in
            guard let self else { return }
            let sourceURL = self.url(for: draft.source)
            guard let sourceURL else { return }

            var snippets = self.loadSnippets(from: sourceURL)
            let id = draft.id.isEmpty ? self.makeSnippetID(from: draft.title) : draft.id
            let now = Date()
            let snippet = Snippet(
                id: id,
                title: draft.title,
                body: draft.body,
                tags: self.parseCSV(draft.tagsText),
                folder: draft.folder.isEmpty ? nil : draft.folder,
                shells: self.parseCSV(draft.shellsText),
                createdAt: now,
                updatedAt: now
            )
            if let index = snippets.firstIndex(where: { $0.id == id }) {
                snippets[index] = snippet
            } else {
                snippets.append(snippet)
            }
            self.saveSnippets(snippets, to: sourceURL)
            self.reloadAll()
        }
    }

    func updateSnippet(entry: SnippetEntry, with draft: SnippetDraft) {
        queue.async { [weak self] in
            guard let self else { return }
            let newSourceURL = self.url(for: draft.source)
            guard let newSourceURL else { return }

            let now = Date()
            let resolvedID = draft.id.isEmpty ? entry.snippet.id : draft.id
            let updated = Snippet(
                id: resolvedID,
                title: draft.title,
                body: draft.body,
                tags: self.parseCSV(draft.tagsText),
                folder: draft.folder.isEmpty ? nil : draft.folder,
                shells: self.parseCSV(draft.shellsText),
                createdAt: entry.snippet.createdAt ?? now,
                updatedAt: now
            )

            if entry.source == draft.source {
                var snippets = self.loadSnippets(from: newSourceURL)
                if resolvedID != entry.snippet.id {
                    snippets.removeAll { $0.id == resolvedID }
                }
                if let index = snippets.firstIndex(where: { $0.id == entry.snippet.id }) {
                    snippets[index] = updated
                } else {
                    snippets.append(updated)
                }
                self.saveSnippets(snippets, to: newSourceURL)
            } else {
                if let oldURL = self.url(for: entry.source) {
                    var oldSnippets = self.loadSnippets(from: oldURL)
                    oldSnippets.removeAll { $0.id == entry.snippet.id }
                    self.saveSnippets(oldSnippets, to: oldURL)
                }
                var newSnippets = self.loadSnippets(from: newSourceURL)
                if let index = newSnippets.firstIndex(where: { $0.id == resolvedID }) {
                    newSnippets[index] = updated
                } else {
                    newSnippets.append(updated)
                }
                self.saveSnippets(newSnippets, to: newSourceURL)
            }

            self.reloadAll()
        }
    }

    func deleteSnippet(_ entry: SnippetEntry) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let url = self.url(for: entry.source) else { return }
            var snippets = self.loadSnippets(from: url)
            snippets.removeAll { $0.id == entry.snippet.id }
            self.saveSnippets(snippets, to: url)
            self.reloadAll()
        }
    }

    func prepareInsertion(snippet: Snippet, currentDirectory: String) -> SnippetInsertion {
        let base = replaceTokens(in: snippet.body, currentDirectory: currentDirectory)
        if FeatureSettings.shared.snippetInsertMode == "paste" || !FeatureSettings.shared.snippetPlaceholdersEnabled {
            return SnippetInsertion(text: base, placeholders: [], finalCursorOffset: base.count)
        }
        let expanded = expandPlaceholders(in: base)
        let finalOffset = expanded.finalCursorOffset ?? expanded.text.count
        return SnippetInsertion(text: expanded.text, placeholders: expanded.placeholders, finalCursorOffset: finalOffset)
    }

    // MARK: - Internal helpers

    private func replaceEnvTokens(in input: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\$\{env:([A-Za-z0-9_]+)\}"#) else {
            return input
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        var output = input
        let matches = regex.matches(in: input, range: range).reversed()
        for match in matches {
            guard match.numberOfRanges == 2,
                  let keyRange = Range(match.range(at: 1), in: output),
                  let fullRange = Range(match.range(at: 0), in: output) else { continue }
            let key = String(output[keyRange])
            let value = ProcessInfo.processInfo.environment[key] ?? ""
            output.replaceSubrange(fullRange, with: value)
        }
        return output
    }

    private func replaceTokens(in input: String, currentDirectory: String) -> String {
        var text = input
        text = text.replacingOccurrences(of: "${cwd}", with: currentDirectory)
        text = text.replacingOccurrences(of: "${home}", with: FileManager.default.homeDirectoryForCurrentUser.path)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        text = text.replacingOccurrences(of: "${date}", with: dateFormatter.string(from: Date()))

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        text = text.replacingOccurrences(of: "${time}", with: timeFormatter.string(from: Date()))

        if text.contains("${clip}") {
            let clip = NSPasteboard.general.string(forType: .string) ?? ""
            text = text.replacingOccurrences(of: "${clip}", with: clip)
        }

        return replaceEnvTokens(in: text)
    }

    private func expandPlaceholders(in input: String) -> (text: String, placeholders: [SnippetPlaceholder], finalCursorOffset: Int?) {
        guard let regex = try? NSRegularExpression(pattern: #"\$\{(\d+)(?::([^}]*))?\}"#) else {
            return (input, [], nil)
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        let matches = regex.matches(in: input, range: range)
        guard !matches.isEmpty else {
            return (input, [], nil)
        }

        var output = ""
        var placeholders: [SnippetPlaceholder] = []
        var cursor = input.startIndex
        var currentLength = 0
        var finalOffset: Int?

        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: input) else { continue }
            let before = input[cursor..<fullRange.lowerBound]
            output.append(contentsOf: before)
            currentLength += before.count

            let indexString = Range(match.range(at: 1), in: input).map { String(input[$0]) } ?? "0"
            let index = Int(indexString) ?? 0
            let defaultText = Range(match.range(at: 2), in: input).map { String(input[$0]) } ?? ""

            output.append(contentsOf: defaultText)
            if index == 0 {
                finalOffset = currentLength + defaultText.count
            } else {
                placeholders.append(SnippetPlaceholder(index: index, start: currentLength, length: defaultText.count))
            }
            currentLength += defaultText.count
            cursor = fullRange.upperBound
        }

        output.append(contentsOf: input[cursor..<input.endIndex])

        let sorted = placeholders.sorted {
            if $0.index != $1.index {
                return $0.index < $1.index
            }
            return $0.start < $1.start
        }
        return (output, sorted, finalOffset)
    }

    private func parseCSV(_ text: String) -> [String] {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return parts.filter { !$0.isEmpty }
    }

    private func mergeEntries(global: [Snippet], profile: [Snippet], repo: [Snippet]) -> [SnippetEntry] {
        var highestById: [String: SnippetSource] = [:]
        func register(_ snippets: [Snippet], source: SnippetSource, priority: Int) {
            for snippet in snippets {
                let current = highestById[snippet.id]
                if current == nil || priority > priorityForSource(current!) {
                    highestById[snippet.id] = source
                }
            }
        }

        register(global, source: .global, priority: priorityForSource(.global))
        register(profile, source: .profile, priority: priorityForSource(.profile))
        register(repo, source: .repo, priority: priorityForSource(.repo))

        var entries: [SnippetEntry] = []
        entries.append(contentsOf: global.map {
            SnippetEntry(
                snippet: $0,
                source: .global,
                sourcePath: globalURL().path,
                isOverridden: highestById[$0.id] != .global
            )
        })
        entries.append(contentsOf: profile.map {
            SnippetEntry(
                snippet: $0,
                source: .profile,
                sourcePath: profileURL().path,
                isOverridden: highestById[$0.id] != .profile
            )
        })
        if let repoURL = repoURL() {
            entries.append(contentsOf: repo.map {
                SnippetEntry(
                    snippet: $0,
                    source: .repo,
                    sourcePath: repoURL.path,
                    isOverridden: highestById[$0.id] != .repo
                )
            })
        }

        return entries.sorted { lhs, rhs in
            if lhs.source != rhs.source {
                return priorityForSource(lhs.source) > priorityForSource(rhs.source)
            }
            return lhs.snippet.title.localizedCaseInsensitiveCompare(rhs.snippet.title) == .orderedAscending
        }
    }

    private func priorityForSource(_ source: SnippetSource) -> Int {
        switch source {
        case .repo:
            return 3
        case .profile:
            return 2
        case .global:
            return 1
        }
    }

    private func setupMonitors() {
        guard FeatureSettings.shared.isSnippetsEnabled else {
            stopMonitors()
            return
        }
        let globalURL = globalURL()
        ensureSnippetFileExists(at: globalURL)
        if globalMonitor?.url != globalURL {
            globalMonitor?.stop()
            let monitor = FileMonitor(url: globalURL) { [weak self] in
                self?.reloadAll()
            }
            monitor.start()
            globalMonitor = monitor
        }

        let profileURL = profileURL()
        ensureSnippetFileExists(at: profileURL)
        if profileMonitor?.url != profileURL {
            profileMonitor?.stop()
            let monitor = FileMonitor(url: profileURL) { [weak self] in
                self?.reloadAll()
            }
            monitor.start()
            profileMonitor = monitor
        }

        if FeatureSettings.shared.isRepoSnippetsEnabled, let repoURL = repoURL() {
            ensureSnippetFileExists(at: repoURL)
            if repoMonitor?.url != repoURL {
                repoMonitor?.stop()
                let monitor = FileMonitor(url: repoURL) { [weak self] in
                    self?.reloadAll()
                }
                monitor.start()
                repoMonitor = monitor
            }
        } else {
            repoMonitor?.stop()
            repoMonitor = nil
        }
    }

    private func stopMonitors() {
        globalMonitor?.stop()
        globalMonitor = nil
        profileMonitor?.stop()
        profileMonitor = nil
        repoMonitor?.stop()
        repoMonitor = nil
    }

    private func ensureBaseDirectories() {
        let base = supportDirectory().appendingPathComponent("snippets", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    private func ensureSnippetFileExists(at url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let file = SnippetFile(version: 1, snippets: [])
        saveSnippets(file.snippets, to: url)
    }

    private func loadSnippets(from url: URL) -> [Snippet] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let file = try? decoder.decode(SnippetFile.self, from: data) {
            return file.snippets
        }
        if let legacy = try? decoder.decode([Snippet].self, from: data) {
            return legacy
        }
        return []
    }

    private func saveSnippets(_ snippets: [Snippet], to url: URL) {
        let file = SnippetFile(version: 1, snippets: snippets)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(file) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }

    private func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Chau7", isDirectory: true)
    }

    private func globalURL() -> URL {
        supportDirectory()
            .appendingPathComponent("snippets", isDirectory: true)
            .appendingPathComponent("global.json")
    }

    private func profileURL() -> URL {
        supportDirectory()
            .appendingPathComponent("snippets", isDirectory: true)
            .appendingPathComponent("default.json")
    }

    private func repoURL() -> URL? {
        guard FeatureSettings.shared.isSnippetsEnabled else { return nil }
        guard FeatureSettings.shared.isRepoSnippetsEnabled else { return nil }
        guard let repoRoot else { return nil }
        let relative = FeatureSettings.shared.repoSnippetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = relative.isEmpty ? ".chau7/snippets.json" : relative
        return URL(fileURLWithPath: repoRoot).appendingPathComponent(path)
    }

    private func url(for source: SnippetSource) -> URL? {
        switch source {
        case .global:
            return globalURL()
        case .profile:
            return profileURL()
        case .repo:
            return repoURL()
        }
    }

    /// Directories where we skip git repo detection to avoid permission prompts
    private static let protectedDirectories: Set<String> = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Downloads",
            "\(home)/Desktop",
            "\(home)/Documents",
            "\(home)/Library",
            "/Applications",
            "/System",
            "/Library"
        ]
    }()

    /// Cache of paths we've already checked and found to not be git repos
    private var nonGitPathCache: Set<String> = []

    private func resolveRepoRoot(path: String) -> String? {
        // Skip protected directories to avoid repeated permission prompts
        for protected in Self.protectedDirectories {
            if path == protected || path.hasPrefix(protected + "/") {
                Log.trace("Skipping git check for protected directory: \(path)")
                return nil
            }
        }

        // Check if we've already determined this path isn't in a git repo
        if nonGitPathCache.contains(path) {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "rev-parse", "--show-toplevel"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            nonGitPathCache.insert(path)
            return nil
        }
        guard process.terminationStatus == 0 else {
            nonGitPathCache.insert(path)
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    private func makeSnippetID(from title: String) -> String {
        let base = title
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let suffix = UUID().uuidString.prefix(6)
        return "\(base.isEmpty ? "snippet" : base)-\(suffix)"
    }
}
