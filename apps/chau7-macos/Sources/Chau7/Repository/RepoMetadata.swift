import Foundation

/// Persisted per-repo metadata stored at `{repo-root}/.chau7/metadata.json`.
struct RepoMetadata: Codable, Equatable {
    var description: String?
    var labels: [String]
    var favoriteFiles: [String]
    var updatedAt: Date?

    static let empty = RepoMetadata(description: nil, labels: [], favoriteFiles: [], updatedAt: nil)

    var isEmpty: Bool {
        description == nil && labels.isEmpty && favoriteFiles.isEmpty
    }
}

// MARK: - Custom encoding (omit empty fields for clean JSON)

extension RepoMetadata {
    enum CodingKeys: String, CodingKey {
        case description, labels, favoriteFiles, updatedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let description { try container.encode(description, forKey: .description) }
        if !labels.isEmpty { try container.encode(labels, forKey: .labels) }
        if !favoriteFiles.isEmpty { try container.encode(favoriteFiles, forKey: .favoriteFiles) }
        if let updatedAt { try container.encode(updatedAt, forKey: .updatedAt) }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
        self.favoriteFiles = try container.decodeIfPresent([String].self, forKey: .favoriteFiles) ?? []
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

// MARK: - Persistence

enum RepoMetadataStore {
    /// Load metadata from `{repoRoot}/.chau7/metadata.json`.
    /// Returns `.empty` if the file doesn't exist or can't be decoded.
    static func load(repoRoot: String) -> RepoMetadata {
        let url = metadataURL(for: repoRoot)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let metadata = try? decoder.decode(RepoMetadata.self, from: data) else {
            Log.warn("Failed to decode repo metadata at \(url.path)")
            return .empty
        }
        return metadata
    }

    /// Save metadata to `{repoRoot}/.chau7/metadata.json`.
    /// Creates the `.chau7/` directory on demand. Skips write if metadata is empty.
    static func save(_ metadata: RepoMetadata, repoRoot: String) {
        let url = metadataURL(for: repoRoot)
        if metadata.isEmpty {
            // Clean up the file if metadata is empty
            try? FileManager.default.removeItem(at: url)
            return
        }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(metadata) else {
            Log.warn("Failed to encode repo metadata for \(repoRoot)")
            return
        }
        // Atomic write via temp file
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            // Fallback: direct write
            try? data.write(to: url, options: .atomic)
        }
    }

    static func metadataURL(for repoRoot: String) -> URL {
        URL(fileURLWithPath: repoRoot)
            .appendingPathComponent(".chau7", isDirectory: true)
            .appendingPathComponent("metadata.json")
    }
}
