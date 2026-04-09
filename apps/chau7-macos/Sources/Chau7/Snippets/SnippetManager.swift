import Foundation
import AppKit
import Chau7Core

enum SnippetSource: String, Codable, CaseIterable, Identifiable {
    case global // Stored as "global" for backwards compatibility
    case profile
    case repo

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .global:
            return L("snippets.source.user", "User") // User-friendly name (stored as "global")
        case .profile:
            return L("snippets.source.profile", "Profile")
        case .repo:
            return L("snippets.source.repo", "Repo")
        }
    }

    var description: String {
        switch self {
        case .global:
            return L("snippets.source.user.description", "Available everywhere")
        case .profile:
            return L("snippets.source.profile.description", "Profile-specific")
        case .repo:
            return L("snippets.source.repo.description", "Repository-specific")
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
    /// Optional single-letter shortcut key (a-z) for quick selection in the snippet picker
    var key: String?
    /// Whether this snippet is pinned to the top of the list
    var isPinned: Bool
    var createdAt: Date?
    var updatedAt: Date?

    init(
        id: String,
        title: String,
        body: String,
        tags: [String] = [],
        folder: String? = nil,
        shells: [String]? = nil,
        key: String? = nil,
        isPinned: Bool = false,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.tags = tags
        self.folder = folder
        self.shells = shells
        self.key = key
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Clean JSON encoding

    enum CodingKeys: String, CodingKey {
        case id, title, body, tags, folder, shells, key, isPinned, createdAt, updatedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        // Only write tags if non-empty
        if !tags.isEmpty {
            try container.encode(tags, forKey: .tags)
        }
        // Only write optionals if non-nil (and non-empty for arrays)
        try container.encodeIfPresent(folder, forKey: .folder)
        if let shells, !shells.isEmpty {
            try container.encode(shells, forKey: .shells)
        }
        try container.encodeIfPresent(key, forKey: .key)
        // Only write isPinned if true
        if isPinned {
            try container.encode(isPinned, forKey: .isPinned)
        }
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.body = try container.decode(String.self, forKey: .body)
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.folder = try container.decodeIfPresent(String.self, forKey: .folder)
        self.shells = try container.decodeIfPresent([String].self, forKey: .shells)
        self.key = try container.decodeIfPresent(String.self, forKey: .key)
        self.isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    /// Validated key - returns the key only if it's a single lowercase letter a-z
    /// Handles externally-edited JSON that might have invalid keys
    var validatedKey: Character? {
        guard let key = key, !key.isEmpty else { return nil }
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 1, let char = normalized.first, char >= "a", char <= "z" else {
            return nil
        }
        return char
    }
}

struct SnippetFile: Codable {
    var version: Int
    var snippets: [Snippet]
}

struct SnippetEntry: Identifiable, Equatable {
    var id: String {
        "\(source.rawValue)::\(snippet.id)"
    }

    var snippet: Snippet
    var source: SnippetSource
    var sourcePath: String
    var isOverridden: Bool
    var repoRoot: String?
}

struct SnippetDraft: Equatable {
    var id: String
    var title: String
    var body: String
    var tagsText: String
    var folder: String
    var shellsText: String
    /// Quick-select key (single letter a-z, or empty for auto-assign)
    var key: String
    var source: SnippetSource
    /// Optional repo root for repo-scoped snippets
    var repoPath: String

    init(
        id: String = "",
        title: String = "",
        body: String = "",
        tagsText: String = "",
        folder: String = "",
        shellsText: String = "",
        key: String = "",
        source: SnippetSource = .global,
        repoPath: String = ""
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.tagsText = tagsText
        self.folder = folder
        self.shellsText = shellsText
        self.key = key
        self.source = source
        self.repoPath = repoPath
    }
}

struct SnippetPlaceholder: Equatable {
    let index: Int
    let start: Int
    let length: Int
}

/// The type of input control for a snippet variable
enum SnippetInputType: Equatable {
    case text // Free-form text input
    case singleSelect // Single selection from options (dropdown)
    case multiSelect // Multiple selection from options (checkboxes)
}

/// Represents a prompted input variable in a snippet
/// Syntax:
/// - ${input:name} - text input, no default
/// - ${input:name:default} - text input with default value
/// - ${input:name:opt1|opt2|opt3} - single select picker (pipe-delimited options)
/// - ${multiselect:name:opt1|opt2|opt3} - multi select picker
struct SnippetInputVariable: Identifiable, Equatable {
    let id: String // The variable name (unique within snippet)
    let name: String // Display name
    let defaultValue: String
    var value: String // User-provided value (for text and single select)

    // Picker support
    let inputType: SnippetInputType
    let options: [String] // Available options for picker types
    var selectedOptions: Set<String> // Selected options for multi-select

    /// Creates a text input variable
    init(name: String, defaultValue: String = "") {
        self.id = name
        self.name = name
        self.defaultValue = defaultValue
        self.value = defaultValue
        self.inputType = .text
        self.options = []
        self.selectedOptions = []
    }

    /// Creates a picker variable (single or multi select)
    init(name: String, options: [String], inputType: SnippetInputType) {
        self.id = name
        self.name = name
        self.options = options
        self.inputType = inputType

        // For single select, default to first option
        // For multi select, default to empty selection
        if inputType == .singleSelect, let first = options.first {
            self.defaultValue = first
            self.value = first
            self.selectedOptions = []
        } else {
            self.defaultValue = ""
            self.value = ""
            self.selectedOptions = []
        }
    }
}

struct SnippetInsertion {
    let text: String
    let placeholders: [SnippetPlaceholder]
    let finalCursorOffset: Int
}

/// Manages code snippets with support for global, profile, and repository scopes.
/// - Note: Thread Safety - @Observable properties must be modified on main thread.
///   Background file operations dispatch to main via DispatchQueue.main.async.
@Observable
final class SnippetManager {
    static let shared = SnippetManager()

    private(set) var entries: [SnippetEntry] = []
    private(set) var activeRepoRoot: String?

    /// Background queue for file I/O operations
    private let queue = DispatchQueue(label: "com.chau7.snippets", qos: .utility)
    private var globalMonitor: FileMonitor?
    private var profileMonitor: FileMonitor?
    /// File monitor for the active repo's snippet directory only
    private var activeRepoMonitor: FileMonitor?
    private var lastContextPath = ""
    private var resolveWorkItem: DispatchWorkItem?

    /// In-memory caches — avoid disk I/O when switching repos
    private var globalSnippetsCache: [Snippet] = []
    private var profileSnippetsCache: [Snippet] = []
    private var allRepoSnippets: [String: [Snippet]] = [:]

    private init() {
        ensureBaseDirectories()
        migrateIfNeeded()
        // Sync load global + profile for immediate availability
        let globalDir = globalURL()
        let profileDir = profileURL()
        FileOperations.createDirectory(at: globalDir)
        FileOperations.createDirectory(at: profileDir)
        self.globalSnippetsCache = loadSnippetsFromDirectory(globalDir)
        self.profileSnippetsCache = loadSnippetsFromDirectory(profileDir)
        setupMonitors()
        rebuildEntries()
        // Async pre-load all known repos
        queue.async { [weak self] in
            guard let self else { return }
            let repos = loadAllRepoSnippetsFromDisk()
            DispatchQueue.main.async {
                self.allRepoSnippets = repos
                self.rebuildEntries()
            }
        }
    }

    func updateContextPath(_ path: String, force: Bool = false) {
        guard FeatureSettings.shared.isSnippetsEnabled else { return }
        let normalized = URL(fileURLWithPath: path).standardized.path
        if !force && normalized == lastContextPath { return }
        lastContextPath = normalized

        // Quick check: still within the current active repo — cancel any stale resolve and no-op.
        // Without the cancel, a prior updateContextPath (e.g. from init with home dir) can fire
        // its 0.25s delayed resolve AFTER we've already confirmed the correct repo, stomping
        // activeRepoRoot and clearing repo snippets from all subsequent tabs.
        if let root = activeRepoRoot, normalized == root || normalized.hasPrefix(root + "/") {
            resolveWorkItem?.cancel()
            return
        }

        resolveWorkItem?.cancel()
        if StartupRestoreCoordinator.shared.shouldDebounceSnippetResolve(forPath: normalized) {
            let workItem = DispatchWorkItem { [weak self] in
                self?.resolveContextPath(normalized)
            }
            resolveWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + StartupSnippetResolvePolicy.debouncedDelay,
                execute: workItem
            )
        } else {
            resolveContextPath(normalized)
        }
    }

    private func resolveContextPath(_ normalized: String) {
        RepositoryCache.shared.resolveDetailed(path: normalized) { [weak self] result in
            guard let self else { return }
            StartupRestoreCoordinator.shared.noteSnippetResolveCompleted()
            let root: String?
            switch result {
            case .live(let model, access: _):
                root = model.rootPath
            case .cachedIdentity(identity: let identity, access: _):
                root = identity.rootPath
            case .blocked, .notRepository:
                root = nil
            }
            Log.info("Snippet context: path=\(normalized) resolved repoRoot=\(root ?? "nil")")

            // Migrate legacy repo snippets if needed
            if let root {
                let legacyFile = legacyRepoURL(for: root)
                let targetDir = repoURL(for: root)
                migrateSourceIfNeeded(legacyFile: legacyFile, targetDir: targetDir)
            }

            guard activeRepoRoot != root else { return }
            activeRepoRoot = root

            if let root {
                // recordRecentRepo is now handled by RepositoryCache on first discovery

                if allRepoSnippets[root] == nil {
                    // New repo discovered: load its snippets into cache
                    queue.async {
                        let repoDir = self.repoURL(for: root)
                        FileOperations.createDirectory(at: repoDir)
                        let snippets = self.loadSnippetsFromDirectory(repoDir)
                        DispatchQueue.main.async {
                            self.allRepoSnippets[root] = snippets
                            self.rebuildEntries()
                            Log.info("Loaded new repo snippets: \(root) count=\(snippets.count)")
                        }
                    }
                } else {
                    // Already cached: instant switch
                    rebuildEntries()
                }

                setupActiveRepoMonitor(for: root)
            } else {
                // No repo: rebuild with global + profile only
                activeRepoMonitor?.stop()
                activeRepoMonitor = nil
                rebuildEntries()
            }
        }
    }

    func refreshContextForCurrentPath() {
        guard !lastContextPath.isEmpty else { return }
        updateContextPath(lastContextPath, force: true)
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
            let (global, profile, repos) = loadAllSourcesFromDisk()
            DispatchQueue.main.async {
                self.globalSnippetsCache = global
                self.profileSnippetsCache = profile
                self.allRepoSnippets = repos
                self.rebuildEntries()
            }
        }
    }

    /// Manual reload: re-reads all sources from disk and rebuilds entries.
    /// Intended for "Reload Snippets" command palette action.
    func forceReloadAll() {
        queue.async { [weak self] in
            guard let self else { return }
            let (global, profile, repos) = loadAllSourcesFromDisk()
            DispatchQueue.main.async {
                self.globalSnippetsCache = global
                self.profileSnippetsCache = profile
                self.allRepoSnippets = repos
                self.rebuildEntries()
                Log.info("Snippets force-reloaded: global=\(global.count) profile=\(profile.count) repos=\(repos.count)")
            }
        }
    }

    /// Loads global, profile, and all known repo snippets from disk.
    /// Returns local values — does NOT write to instance caches (thread-safe).
    /// Must be called on the background queue.
    private func loadAllSourcesFromDisk() -> (global: [Snippet], profile: [Snippet], repos: [String: [Snippet]]) {
        let globalDir = globalURL()
        let profileDir = profileURL()
        FileOperations.createDirectory(at: globalDir)
        FileOperations.createDirectory(at: profileDir)
        let global = loadSnippetsFromDirectory(globalDir)
        let profile = loadSnippetsFromDirectory(profileDir)
        let repos = loadAllRepoSnippetsFromDisk()
        return (global, profile, repos)
    }

    /// Loads snippets from all known repo roots.
    /// Returns a new dictionary — does NOT write to instance caches (thread-safe).
    /// Must be called on the background queue.
    private func loadAllRepoSnippetsFromDisk() -> [String: [Snippet]] {
        guard FeatureSettings.shared.isRepoSnippetsEnabled else { return [:] }
        let fm = FileManager.default
        var cache: [String: [Snippet]] = [:]
        for root in KnownRepoIdentityStore.shared.allRoots() {
            let repoDir = repoURL(for: root)
            guard fm.fileExists(atPath: repoDir.path) else { continue }
            let snippets = loadSnippetsFromDirectory(repoDir)
            if !snippets.isEmpty {
                cache[root] = snippets
            }
        }
        Log.info("Pre-loaded snippets from \(cache.count) repos (\(cache.values.reduce(0) { $0 + $1.count }) snippets total)")
        return cache
    }

    /// Rebuilds `entries` from in-memory caches using the current `activeRepoRoot`.
    /// No disk I/O. Must be called on the main thread.
    private func rebuildEntries() {
        guard FeatureSettings.shared.isSnippetsEnabled else {
            entries = []
            return
        }
        let repoSnippets: [Snippet]
        if let root = activeRepoRoot, let cached = allRepoSnippets[root] {
            repoSnippets = cached
        } else {
            repoSnippets = []
        }
        entries = mergeEntries(
            global: globalSnippetsCache,
            profile: profileSnippetsCache,
            repo: repoSnippets
        )
    }

    /// Re-saves all snippet files using the clean encoder (pretty-printed, sorted
    /// keys, ISO 8601 dates, no empty arrays). Also migrates any remaining legacy
    /// single-file format to per-file format.
    func migrateToCleanJSON() {
        queue.async { [weak self] in
            guard let self else { return }
            // First, migrate any remaining legacy single-file formats
            migrateIfNeeded()

            var migrated: [String] = []
            let dirs: [(String, URL)] = [
                ("global", globalURL()),
                ("default", profileURL())
            ]
            for (label, dirURL) in dirs {
                let snippets = loadSnippetsFromDirectory(dirURL)
                guard !snippets.isEmpty else { continue }
                for snippet in snippets {
                    saveSnippet(snippet, to: dirURL)
                }
                migrated.append("\(label) (\(snippets.count) snippets)")
            }
            // Migrate all known repos from the persisted identity store, not the in-memory cache
            let fm = FileManager.default
            for root in KnownRepoIdentityStore.shared.allRoots() {
                let repoDir = repoURL(for: root)
                guard fm.fileExists(atPath: repoDir.path) else { continue }
                let snippets = loadSnippetsFromDirectory(repoDir)
                if !snippets.isEmpty {
                    for snippet in snippets {
                        saveSnippet(snippet, to: repoDir)
                    }
                    let name = URL(fileURLWithPath: root).lastPathComponent
                    migrated.append("repo:\(name) (\(snippets.count))")
                }
            }
            let summary = migrated.isEmpty ? "No snippets to migrate" : "Migrated: \(migrated.joined(separator: ", "))"
            Log.info("Snippet migration: \(summary)")
            DispatchQueue.main.async {
                self.reloadAll()
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
            guard let dirURL = url(for: draft.source, repoRootOverride: draft.repoPath) else { return }

            let id = draft.id.isEmpty ? makeSnippetID(from: draft.title) : draft.id
            let now = Date()
            let snippet = Snippet(
                id: id,
                title: draft.title,
                body: draft.body,
                tags: parseCSV(draft.tagsText),
                folder: draft.folder.isEmpty ? nil : draft.folder,
                shells: parseCSV(draft.shellsText),
                key: Self.normalizeKey(draft.key),
                createdAt: now,
                updatedAt: now
            )
            saveSnippet(snippet, to: dirURL)
            reloadAll()
        }
    }

    func updateSnippet(entry: SnippetEntry, with draft: SnippetDraft) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let newDirURL = url(for: draft.source, repoRootOverride: draft.repoPath) else { return }

            let now = Date()
            let resolvedID = draft.id.isEmpty ? entry.snippet.id : draft.id
            let updated = Snippet(
                id: resolvedID,
                title: draft.title,
                body: draft.body,
                tags: parseCSV(draft.tagsText),
                folder: draft.folder.isEmpty ? nil : draft.folder,
                shells: parseCSV(draft.shellsText),
                key: Self.normalizeKey(draft.key),
                isPinned: entry.snippet.isPinned,
                createdAt: entry.snippet.createdAt ?? now,
                updatedAt: now
            )

            let oldRepo = entry.repoRoot?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let newRepo = draft.repoPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let sameRepo = entry.source != .repo || draft.source != .repo || oldRepo == newRepo

            if entry.source == draft.source, sameRepo {
                // Same source: write updated file, delete old file if ID changed
                if resolvedID != entry.snippet.id {
                    deleteSnippetFile(id: entry.snippet.id, from: newDirURL)
                }
                saveSnippet(updated, to: newDirURL)
            } else {
                // Moving between sources: delete from old, write to new
                if let oldDirURL = url(for: entry.source, repoRootOverride: entry.repoRoot) {
                    deleteSnippetFile(id: entry.snippet.id, from: oldDirURL)
                }
                saveSnippet(updated, to: newDirURL)
            }

            reloadAll()
        }
    }

    func deleteSnippet(_ entry: SnippetEntry) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let dirURL = url(for: entry.source, repoRootOverride: entry.repoRoot) else { return }
            deleteSnippetFile(id: entry.snippet.id, from: dirURL)
            reloadAll()
        }
    }

    func duplicateSnippet(_ entry: SnippetEntry, to target: SnippetSource, repoRootOverride: String? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let dirURL = url(for: target, repoRootOverride: repoRootOverride) else { return }

            let now = Date()
            var copied = entry.snippet
            copied.createdAt = now
            copied.updatedAt = now
            // Check if a file with this ID already exists
            let existingFile = dirURL.appendingPathComponent("\(copied.id).json")
            if FileManager.default.fileExists(atPath: existingFile.path) {
                copied.id = makeSnippetID(from: copied.title)
            }
            saveSnippet(copied, to: dirURL)
            reloadAll()
        }
    }

    func togglePin(_ entry: SnippetEntry) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let dirURL = url(for: entry.source, repoRootOverride: entry.repoRoot) else { return }
            var snippet = entry.snippet
            snippet.isPinned.toggle()
            snippet.updatedAt = Date()
            saveSnippet(snippet, to: dirURL)
            reloadAll()
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
        let range = NSRange(input.startIndex ..< input.endIndex, in: input)
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
        text = text.replacingOccurrences(of: "${home}", with: RuntimeIsolation.homePath())

        text = text.replacingOccurrences(of: "${date}", with: LocalizedFormatters.formatShortDate(Date()))
        text = text.replacingOccurrences(of: "${time}", with: LocalizedFormatters.formatShortTime(Date()))

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
        let range = NSRange(input.startIndex ..< input.endIndex, in: input)
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
            let before = input[cursor ..< fullRange.lowerBound]
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

        output.append(contentsOf: input[cursor ..< input.endIndex])

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

    /// Normalizes a key input: trims, lowercases, takes first char, validates a-z
    /// Returns nil if invalid or empty
    private static func normalizeKey(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let first = trimmed.first, first >= "a", first <= "z" else {
            return nil
        }
        return String(first)
    }

    // MARK: - Input Variables

    /// Regex pattern for input variables: ${input:Name} or ${input:Name:default value}
    /// Also matches ${input:Name:opt1|opt2|opt3} for single-select pickers
    private static let inputVariablePattern = #"\$\{input:([^:}]+)(?::([^}]*))?\}"#

    /// Regex pattern for multi-select variables: ${multiselect:Name:opt1|opt2|opt3}
    private static let multiselectPattern = #"\$\{multiselect:([^:}]+):([^}]+)\}"#

    /// Parses input variables from a snippet body
    /// Returns unique variables in order of first occurrence
    /// Supports: ${input:name}, ${input:name:default}, ${input:name:opt1|opt2}, ${multiselect:name:opt1|opt2}
    static func parseInputVariables(from text: String) -> [SnippetInputVariable] {
        var seenNames = Set<String>()
        var variables: [SnippetInputVariable] = []

        // First, parse multiselect variables
        if let multiselectRegex = try? NSRegularExpression(pattern: multiselectPattern) {
            let range = NSRange(text.startIndex ..< text.endIndex, in: text)
            let matches = multiselectRegex.matches(in: text, range: range)

            for match in matches {
                guard let nameRange = Range(match.range(at: 1), in: text),
                      let optionsRange = Range(match.range(at: 2), in: text) else { continue }

                let name = String(text[nameRange])
                guard !seenNames.contains(name) else { continue }
                seenNames.insert(name)

                let optionsString = String(text[optionsRange])
                // Trim whitespace and filter empty options, then deduplicate
                var seenOptions = Set<String>()
                let options = optionsString.split(separator: "|")
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && seenOptions.insert($0).inserted }

                guard !options.isEmpty else { continue } // Skip if no valid options
                variables.append(SnippetInputVariable(name: name, options: options, inputType: .multiSelect))
            }
        }

        // Then, parse input variables (text or single-select)
        guard let inputRegex = try? NSRegularExpression(pattern: inputVariablePattern) else {
            return variables
        }

        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        let matches = inputRegex.matches(in: text, range: range)

        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[nameRange])

            // Skip duplicates - only use first occurrence
            guard !seenNames.contains(name) else { continue }
            seenNames.insert(name)

            // Check if there's a value/options portion
            if match.numberOfRanges > 2, let valueRange = Range(match.range(at: 2), in: text) {
                let valueString = String(text[valueRange])

                // If value contains "|", treat as single-select picker options
                if valueString.contains("|") {
                    // Trim whitespace and filter empty options, then deduplicate
                    var seenOptions = Set<String>()
                    let options = valueString.split(separator: "|")
                        .map { String($0).trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty && seenOptions.insert($0).inserted }

                    // If no valid options remain, treat as text input with the original value
                    if options.isEmpty {
                        variables.append(SnippetInputVariable(name: name, defaultValue: valueString))
                    } else {
                        variables.append(SnippetInputVariable(name: name, options: options, inputType: .singleSelect))
                    }
                } else {
                    // Regular text input with default value
                    variables.append(SnippetInputVariable(name: name, defaultValue: valueString))
                }
            } else {
                // Text input with no default
                variables.append(SnippetInputVariable(name: name, defaultValue: ""))
            }
        }

        return variables
    }

    /// Checks if a snippet contains input variables that require user input
    static func hasInputVariables(_ snippet: Snippet) -> Bool {
        let range = NSRange(snippet.body.startIndex ..< snippet.body.endIndex, in: snippet.body)

        // Check for ${input:...}
        if let inputRegex = try? NSRegularExpression(pattern: inputVariablePattern),
           inputRegex.firstMatch(in: snippet.body, range: range) != nil {
            return true
        }

        // Check for ${multiselect:...}
        if let multiselectRegex = try? NSRegularExpression(pattern: multiselectPattern),
           multiselectRegex.firstMatch(in: snippet.body, range: range) != nil {
            return true
        }

        return false
    }

    /// Replaces input variables in text with user-provided values
    static func replaceInputVariables(in text: String, with variables: [SnippetInputVariable]) -> String {
        var result = text
        for variable in variables {
            // Determine the replacement value based on input type
            let replacementValue: String
            switch variable.inputType {
            case .text, .singleSelect:
                replacementValue = variable.value
            case .multiSelect:
                // Join selected options with space
                replacementValue = variable.selectedOptions.sorted().joined(separator: " ")
            }

            // Escape the value for regex replacement (handles special characters like $, \)
            let escapedValue = NSRegularExpression.escapedTemplate(for: replacementValue)

            // Replace ${input:Name:...} and ${input:Name}
            let inputPatterns = [
                "\\$\\{input:\(NSRegularExpression.escapedPattern(for: variable.name)):[^}]*\\}",
                "\\$\\{input:\(NSRegularExpression.escapedPattern(for: variable.name))\\}"
            ]
            for pattern in inputPatterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(result.startIndex ..< result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: escapedValue)
            }

            // Replace ${multiselect:Name:...}
            let multiselectPattern = "\\$\\{multiselect:\(NSRegularExpression.escapedPattern(for: variable.name)):[^}]*\\}"
            if let regex = try? NSRegularExpression(pattern: multiselectPattern) {
                let range = NSRange(result.startIndex ..< result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: escapedValue)
            }
        }
        return result
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

        let globalDir = globalURL()
        let profileDir = profileURL()
        var entries: [SnippetEntry] = []
        entries.append(contentsOf: global.map {
            SnippetEntry(
                snippet: $0,
                source: .global,
                sourcePath: globalDir.appendingPathComponent("\($0.id).json").path,
                isOverridden: highestById[$0.id] != .global,
                repoRoot: nil
            )
        })
        entries.append(contentsOf: profile.map {
            SnippetEntry(
                snippet: $0,
                source: .profile,
                sourcePath: profileDir.appendingPathComponent("\($0.id).json").path,
                isOverridden: highestById[$0.id] != .profile,
                repoRoot: nil
            )
        })
        if let repoDir = repoURL() {
            entries.append(contentsOf: repo.map {
                SnippetEntry(
                    snippet: $0,
                    source: .repo,
                    sourcePath: repoDir.appendingPathComponent("\($0.id).json").path,
                    isOverridden: highestById[$0.id] != .repo,
                    repoRoot: activeRepoRoot
                )
            })
        }

        return entries.sorted { lhs, rhs in
            // Pinned snippets always come first
            if lhs.snippet.isPinned != rhs.snippet.isPinned {
                return lhs.snippet.isPinned
            }
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

    // MARK: - Directory monitoring

    /// Debounce work item for global/profile directory change notifications
    private var reloadDebounceItem: DispatchWorkItem?
    /// Separate debounce for repo directory changes (independent from global/profile)
    private var repoReloadDebounceItem: DispatchWorkItem?

    private func debouncedReload() {
        reloadDebounceItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reloadAll()
        }
        reloadDebounceItem = work
        // 100ms debounce — directory monitors fire per-child-change
        queue.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func setupMonitors() {
        guard FeatureSettings.shared.isSnippetsEnabled else {
            stopMonitors()
            return
        }
        let globalDir = globalURL()
        FileOperations.createDirectory(at: globalDir)
        if globalMonitor?.url != globalDir {
            globalMonitor?.stop()
            let monitor = FileMonitor(url: globalDir) { [weak self] in
                self?.debouncedReload()
            }
            monitor.start()
            globalMonitor = monitor
        }

        let profileDir = profileURL()
        FileOperations.createDirectory(at: profileDir)
        if profileMonitor?.url != profileDir {
            profileMonitor?.stop()
            let monitor = FileMonitor(url: profileDir) { [weak self] in
                self?.debouncedReload()
            }
            monitor.start()
            profileMonitor = monitor
        }

        // Repo monitor is handled separately by setupActiveRepoMonitor()
    }

    /// Sets up a file monitor for the active repo's snippet directory.
    private func setupActiveRepoMonitor(for root: String) {
        guard FeatureSettings.shared.isRepoSnippetsEnabled else {
            activeRepoMonitor?.stop()
            activeRepoMonitor = nil
            return
        }
        let repoDir = repoURL(for: root)
        FileOperations.createDirectory(at: repoDir)
        if activeRepoMonitor?.url != repoDir {
            activeRepoMonitor?.stop()
            let capturedRoot = root
            let monitor = FileMonitor(url: repoDir) { [weak self] in
                self?.debouncedReloadRepo(root: capturedRoot)
            }
            monitor.start()
            activeRepoMonitor = monitor
        }
    }

    /// Reloads a single repo's snippets from disk and updates its cache entry.
    private func debouncedReloadRepo(root: String) {
        repoReloadDebounceItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let repoDir = repoURL(for: root)
            let snippets = loadSnippetsFromDirectory(repoDir)
            DispatchQueue.main.async {
                self.allRepoSnippets[root] = snippets
                if self.activeRepoRoot == root {
                    self.rebuildEntries()
                }
            }
        }
        repoReloadDebounceItem = work
        queue.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func stopMonitors() {
        globalMonitor?.stop()
        globalMonitor = nil
        profileMonitor?.stop()
        profileMonitor = nil
        activeRepoMonitor?.stop()
        activeRepoMonitor = nil
    }

    private func ensureBaseDirectories() {
        FileOperations.createDirectory(at: globalURL())
        FileOperations.createDirectory(at: profileURL())
    }

    // MARK: - Encoding / Decoding

    /// Decoder that reads ISO 8601 strings first, then falls back to Double
    /// (timeIntervalSinceReferenceDate) for legacy files written before the fix.
    static func snippetDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            // Try ISO 8601 string first (new format)
            if let str = try? container.decode(String.self) {
                let fmt = ISO8601DateFormatter()
                fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = fmt.date(from: str) { return date }
                // Try without fractional seconds
                fmt.formatOptions = [.withInternetDateTime]
                if let date = fmt.date(from: str) { return date }
            }
            // Fall back to Double (legacy Apple epoch)
            if let ts = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: ts)
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date")
        }
        return decoder
    }

    /// Encoder that produces clean, human-readable JSON.
    static func snippetEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    // MARK: - Per-file storage

    /// Loads all snippets from a directory (one `.json` file per snippet).
    private func loadSnippetsFromDirectory(_ dirURL: URL) -> [Snippet] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dirURL.path) else { return [] }
        guard let files = try? fm.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let decoder = Self.snippetDecoder()
        var snippets: [Snippet] = []
        for file in files where file.pathExtension == "json" {
            guard let data = FileOperations.readData(from: file) else { continue }
            if let snippet = JSONOperations.decode(Snippet.self, from: data, decoder: decoder, context: "snippet \(file.lastPathComponent)") {
                snippets.append(snippet)
            } else {
                Log.warn("Could not decode snippet from \(file.lastPathComponent)")
            }
        }
        return snippets
    }

    /// Writes a single snippet as `{id}.json` in the given directory.
    private func saveSnippet(_ snippet: Snippet, to dirURL: URL) {
        FileOperations.createDirectory(at: dirURL)
        let encoder = Self.snippetEncoder()
        let fileURL = dirURL.appendingPathComponent("\(snippet.id).json")
        guard let data = JSONOperations.encode(snippet, encoder: encoder, context: "snippet \(snippet.id)") else { return }
        FileOperations.writeData(data, to: fileURL, options: [.atomic])
    }

    /// Removes a single snippet file from the directory.
    private func deleteSnippetFile(id: String, from dirURL: URL) {
        let fileURL = dirURL.appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Legacy single-file loading (for migration only)

    /// Loads snippets from a legacy single-file format (`{ version, snippets: [...] }`).
    private func loadSnippetsLegacy(from url: URL) -> [Snippet] {
        guard let data = FileOperations.readData(from: url) else { return [] }
        let decoder = Self.snippetDecoder()
        if let file = JSONOperations.decode(SnippetFile.self, from: data, decoder: decoder, context: "legacy file \(url.lastPathComponent)") {
            return file.snippets
        }
        if let legacy = JSONOperations.decode([Snippet].self, from: data, decoder: decoder, context: "legacy array \(url.lastPathComponent)") {
            return legacy
        }
        Log.warn("Could not decode legacy snippets from \(url.lastPathComponent)")
        return []
    }

    // MARK: - Auto-migration from single-file to per-file

    /// Detects legacy single-file snippet format and migrates to per-file.
    /// Safe: writes all individual files before deleting the legacy file.
    private func migrateIfNeeded() {
        migrateSourceIfNeeded(legacyFile: legacyGlobalURL(), targetDir: globalURL())
        migrateSourceIfNeeded(legacyFile: legacyProfileURL(), targetDir: profileURL())
        // Repo migration happens in updateContextPath() since activeRepoRoot is nil at init
    }

    private func migrateSourceIfNeeded(legacyFile: URL, targetDir: URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: legacyFile.path, isDirectory: &isDir), !isDir.boolValue else { return }

        let snippets = loadSnippetsLegacy(from: legacyFile)
        guard !snippets.isEmpty else {
            // Empty file, just remove it
            try? fm.removeItem(at: legacyFile)
            Log.info("Removed empty legacy snippet file: \(legacyFile.lastPathComponent)")
            return
        }

        FileOperations.createDirectory(at: targetDir)
        for snippet in snippets {
            saveSnippet(snippet, to: targetDir)
        }
        try? fm.removeItem(at: legacyFile)
        Log.info("Migrated \(snippets.count) snippets from \(legacyFile.lastPathComponent) to per-file format in \(targetDir.lastPathComponent)/")
    }

    // MARK: - URL resolution

    private func supportDirectory() -> URL {
        RuntimeIsolation.appSupportDirectory(named: "Chau7")
    }

    /// Returns the directory URL for global snippets.
    private func globalURL() -> URL {
        supportDirectory()
            .appendingPathComponent("snippets", isDirectory: true)
            .appendingPathComponent("global", isDirectory: true)
    }

    /// Returns the directory URL for profile snippets.
    private func profileURL() -> URL {
        supportDirectory()
            .appendingPathComponent("snippets", isDirectory: true)
            .appendingPathComponent("default", isDirectory: true)
    }

    private func repoURL() -> URL? {
        guard FeatureSettings.shared.isSnippetsEnabled else { return nil }
        guard FeatureSettings.shared.isRepoSnippetsEnabled else { return nil }
        guard let activeRepoRoot else { return nil }
        return repoURL(for: activeRepoRoot)
    }

    /// Returns the directory URL for repo-scoped snippets.
    private func repoURL(for root: String) -> URL {
        var relative = FeatureSettings.shared.repoSnippetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if relative.isEmpty { relative = ".chau7/snippets" }
        // Strip .json suffix from legacy settings
        if relative.hasSuffix(".json") {
            relative = String(relative.dropLast(5))
        }
        return URL(fileURLWithPath: root).appendingPathComponent(relative, isDirectory: true)
    }

    private func url(for source: SnippetSource, repoRootOverride: String? = nil) -> URL? {
        switch source {
        case .global:
            return globalURL()
        case .profile:
            return profileURL()
        case .repo:
            let root = repoRootOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let root, !root.isEmpty {
                return repoURL(for: root)
            }
            return repoURL()
        }
    }

    // MARK: - Legacy URL helpers (for migration)

    private func legacyGlobalURL() -> URL {
        supportDirectory()
            .appendingPathComponent("snippets", isDirectory: true)
            .appendingPathComponent("global.json")
    }

    private func legacyProfileURL() -> URL {
        supportDirectory()
            .appendingPathComponent("snippets", isDirectory: true)
            .appendingPathComponent("default.json")
    }

    private func legacyRepoURL(for root: String) -> URL {
        URL(fileURLWithPath: root).appendingPathComponent(".chau7/snippets.json")
    }

    // nonGitPathCache and resolveRepoRoot(path:) removed — centralized in RepositoryCache

    /// Resolves the git root for a path. Used by settings UI for manual path selection.
    /// Delegates to GitDiffTracker.runGit for the actual git query.
    static func resolveRepoRoot(at path: String) -> String? {
        let normalized = URL(fileURLWithPath: path).standardized.path
        let output = GitDiffTracker.runGit(args: ["rev-parse", "--show-toplevel"], in: normalized)
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
