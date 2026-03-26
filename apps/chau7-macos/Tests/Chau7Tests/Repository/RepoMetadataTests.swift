import XCTest
@testable import Chau7

final class RepoMetadataTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoMetadataTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - Codable Round-Trip

    func testRoundTripFullMetadata() throws {
        let original = RepoMetadata(
            description: "Backend API service",
            labels: ["backend", "rust"],
            favoriteFiles: ["src/main.rs", "Cargo.toml"],
            updatedAt: Date(timeIntervalSince1970: 1700000000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RepoMetadata.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testDecodeEmptyObject() throws {
        let json = "{}".data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RepoMetadata.self, from: json)

        XCTAssertNil(decoded.description)
        XCTAssertTrue(decoded.labels.isEmpty)
        XCTAssertTrue(decoded.favoriteFiles.isEmpty)
        XCTAssertNil(decoded.updatedAt)
    }

    func testEmptyFieldsOmittedFromJSON() throws {
        let metadata = RepoMetadata.empty
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        let json = String(data: data, encoding: .utf8)!

        // Empty metadata should produce just "{}"
        XCTAssertFalse(json.contains("labels"))
        XCTAssertFalse(json.contains("favoriteFiles"))
        XCTAssertFalse(json.contains("description"))
    }

    // MARK: - RepoMetadataStore

    func testSaveAndLoad() {
        let root = tmpDir.path
        let metadata = RepoMetadata(
            description: "Test repo",
            labels: ["test"],
            favoriteFiles: ["README.md"],
            updatedAt: Date()
        )
        RepoMetadataStore.save(metadata, repoRoot: root)

        // Verify .chau7/ directory was created
        let chau7Dir = tmpDir.appendingPathComponent(".chau7")
        XCTAssertTrue(FileManager.default.fileExists(atPath: chau7Dir.path))

        let loaded = RepoMetadataStore.load(repoRoot: root)
        XCTAssertEqual(loaded.description, "Test repo")
        XCTAssertEqual(loaded.labels, ["test"])
        XCTAssertEqual(loaded.favoriteFiles, ["README.md"])
    }

    func testLoadMissingFileReturnsEmpty() {
        let loaded = RepoMetadataStore.load(repoRoot: tmpDir.path)
        XCTAssertEqual(loaded, .empty)
    }

    func testSaveEmptyMetadataRemovesFile() {
        let root = tmpDir.path
        // First save something
        RepoMetadataStore.save(
            RepoMetadata(description: "x", labels: [], favoriteFiles: [], updatedAt: nil),
            repoRoot: root
        )
        let url = RepoMetadataStore.metadataURL(for: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // Save empty → file removed
        RepoMetadataStore.save(.empty, repoRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testLoadCorruptJSONReturnsEmpty() {
        let chau7Dir = tmpDir.appendingPathComponent(".chau7")
        try? FileManager.default.createDirectory(at: chau7Dir, withIntermediateDirectories: true)
        let url = chau7Dir.appendingPathComponent("metadata.json")
        try? "not valid json {{{".data(using: .utf8)?.write(to: url)

        let loaded = RepoMetadataStore.load(repoRoot: tmpDir.path)
        XCTAssertEqual(loaded, .empty)
    }

    // MARK: - isEmpty

    func testIsEmpty() {
        XCTAssertTrue(RepoMetadata.empty.isEmpty)
        XCTAssertFalse(RepoMetadata(description: "x", labels: [], favoriteFiles: [], updatedAt: nil).isEmpty)
        XCTAssertFalse(RepoMetadata(description: nil, labels: ["a"], favoriteFiles: [], updatedAt: nil).isEmpty)
        XCTAssertFalse(RepoMetadata(description: nil, labels: [], favoriteFiles: ["f"], updatedAt: nil).isEmpty)
    }
}
