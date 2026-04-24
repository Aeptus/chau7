import Foundation
import Chau7Core

/// Manages per-repository and global prompt injection rules.
///
/// Rules are persisted to `~/.chau7/prompt-rules.json` (the same file the proxy reads).
/// Per-repo rules from `{repo}/.chau7/injection.json` are loaded on demand
/// and surfaced in the Settings UI but not written back by this store — the
/// proxy reads them directly.
@Observable
final class InjectionRuleStore {
    static let shared = InjectionRuleStore()

    // MARK: - Rule Model

    struct Rule: Codable, Identifiable, Equatable {
        var id: UUID
        /// Repository name (e.g. "my-api"), absolute path, or "*" for all.
        var repository: String
        /// Content to inject.
        var content: String
        /// Where to inject relative to the user message.
        var position: Position

        enum Position: String, Codable, CaseIterable, Identifiable {
            case prepend
            case append
            case system

            var id: String {
                rawValue
            }

            var label: String {
                switch self {
                case .prepend: return L("injection.position.prepend", "Prepend to prompt")
                case .append: return L("injection.position.append", "Append to prompt")
                case .system: return L("injection.position.system", "System prompt")
                }
            }
        }

        /// Custom coding — id is transient, not stored in the JSON file.
        enum CodingKeys: String, CodingKey {
            case repository, content, position
        }

        init(id: UUID = UUID(), repository: String, content: String, position: Position = .prepend) {
            self.id = id
            self.repository = repository
            self.content = content
            self.position = position
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = UUID()
            self.repository = try container.decode(String.self, forKey: .repository)
            self.content = try container.decode(String.self, forKey: .content)
            self.position = try container.decodeIfPresent(Position.self, forKey: .position) ?? .prepend
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(repository, forKey: .repository)
            try container.encode(content, forKey: .content)
            try container.encode(position, forKey: .position)
        }
    }

    /// Wrapper matching the proxy's JSON format.
    private struct RulesFile: Codable {
        var rules: [Rule]
    }

    // MARK: - State

    /// All rules from the global config file.
    private(set) var rules: [Rule] = []

    /// Per-repo local rules discovered from .chau7/injection.json files.
    /// Keyed by repo root path.
    private(set) var localRules: [String: Rule] = [:]

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.chau7.injection-rules", qos: .utility)

    // MARK: - Computed

    /// The global rule that applies to all repositories (repository == "*").
    var globalRule: Rule? {
        rules.first { $0.repository == "*" }
    }

    /// Rules targeting specific repositories (not the "*" wildcard).
    var repoRules: [Rule] {
        rules.filter { $0.repository != "*" }
    }

    // MARK: - Init

    init(fileURL: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.fileURL = fileURL ?? home
            .appendingPathComponent(".chau7", isDirectory: true)
            .appendingPathComponent("prompt-rules.json")
        load()
    }

    // MARK: - Persistence

    func load() {
        let url = fileURL
        queue.async { [weak self] in
            guard FileManager.default.fileExists(atPath: url.path) else {
                DispatchQueue.main.async { self?.rules = [] }
                return
            }
            guard let data = try? Data(contentsOf: url) else {
                Log.warn("Failed to read injection rules from \(url.path)")
                return
            }
            guard let file = try? JSONDecoder().decode(RulesFile.self, from: data) else {
                Log.warn("Failed to decode injection rules from \(url.path)")
                return
            }
            let loaded = file.rules
            DispatchQueue.main.async { self?.rules = loaded }
        }
    }

    func save() {
        let snapshot = rules
        queue.async { [fileURL] in
            let dir = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            Persist.saveLogged(
                RulesFile(rules: snapshot),
                to: fileURL,
                context: "injectionRules.global",
                encoder: encoder
            )
        }
    }

    // MARK: - Mutations (must be called on main thread)

    func setGlobalRule(content: String, position: Rule.Position) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let idx = rules.firstIndex(where: { $0.repository == "*" }) {
            rules[idx].content = content
            rules[idx].position = position
        } else {
            // Insert wildcard at the end so specific rules take precedence.
            rules.append(Rule(repository: "*", content: content, position: position))
        }
        save()
    }

    func removeGlobalRule() {
        dispatchPrecondition(condition: .onQueue(.main))
        rules.removeAll { $0.repository == "*" }
        save()
    }

    func addRepoRule(_ rule: Rule) {
        dispatchPrecondition(condition: .onQueue(.main))
        // Insert before any "*" wildcard to preserve priority ordering.
        if let wildcardIdx = rules.firstIndex(where: { $0.repository == "*" }) {
            rules.insert(rule, at: wildcardIdx)
        } else {
            rules.append(rule)
        }
        save()
    }

    func updateRule(_ rule: Rule) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[idx] = rule
        save()
    }

    func removeRule(id: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        rules.removeAll { $0.id == id }
        save()
    }

    // MARK: - Per-repo local rules

    /// Load injection rule from {repoRoot}/.chau7/injection.json.
    /// Called when a repository is discovered. Result is cached in `localRules`.
    func loadLocalRule(repoRoot: String) {
        let url = URL(fileURLWithPath: repoRoot)
            .appendingPathComponent(".chau7", isDirectory: true)
            .appendingPathComponent("injection.json")

        queue.async { [weak self] in
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let rule = try? JSONDecoder().decode(Rule.self, from: data)
            else {
                return
            }

            DispatchQueue.main.async {
                self?.localRules[repoRoot] = rule
            }
        }
    }

    /// Save a rule to {repoRoot}/.chau7/injection.json.
    /// Must be called on the main thread (mutates @Observable state).
    func saveLocalRule(_ rule: Rule, repoRoot: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        localRules[repoRoot] = rule

        let url = URL(fileURLWithPath: repoRoot)
            .appendingPathComponent(".chau7", isDirectory: true)
            .appendingPathComponent("injection.json")

        queue.async {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            Persist.saveLogged(rule, to: url, context: "injectionRules.local", encoder: encoder)
        }
    }

    /// Remove the local injection file for a repo.
    /// Must be called on the main thread (mutates @Observable state).
    func removeLocalRule(repoRoot: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        localRules.removeValue(forKey: repoRoot)

        let url = URL(fileURLWithPath: repoRoot)
            .appendingPathComponent(".chau7", isDirectory: true)
            .appendingPathComponent("injection.json")

        queue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
