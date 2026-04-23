import XCTest
@testable import Chau7

final class PersistTests: XCTestCase {
    private struct Sample: Codable, Equatable {
        let name: String
        let count: Int
    }

    // MARK: - encodeLogged

    func testEncodeLoggedReturnsDataOnSuccess() {
        let value = Sample(name: "ok", count: 3)
        let data = Persist.encodeLogged(value, context: "test.encode")
        XCTAssertNotNil(data)
    }

    // MARK: - decodeLogged

    func testDecodeLoggedReturnsNilForNilData() {
        let decoded = Persist.decodeLogged(Sample.self, from: nil, context: "test.decode.nil")
        XCTAssertNil(decoded)
    }

    func testDecodeLoggedReturnsNilAndLogsOnGarbage() {
        let garbage = Data("not-json".utf8)
        let decoded = Persist.decodeLogged(Sample.self, from: garbage, context: "test.decode.garbage")
        XCTAssertNil(decoded)
    }

    func testDecodeLoggedRoundTrip() throws {
        let value = Sample(name: "rt", count: 7)
        let data = try JSONEncoder().encode(value)
        let decoded = Persist.decodeLogged(Sample.self, from: data, context: "test.decode.roundtrip")
        XCTAssertEqual(decoded, value)
    }

    // MARK: - saveLogged / loadLogged

    func testSaveLoggedAndLoadLoggedRoundTrip() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let value = Sample(name: "disk", count: 42)

        XCTAssertTrue(Persist.saveLogged(value, to: url, context: "test.save"))

        let result = Persist.loadLogged(Sample.self, from: url, context: "test.load")
        switch result {
        case .loaded(let v): XCTAssertEqual(v, value)
        default: XCTFail("expected .loaded, got \(result)")
        }
    }

    func testLoadLoggedReturnsNotFoundForMissingFile() {
        let url = tempURL()
        let result = Persist.loadLogged(Sample.self, from: url, context: "test.load.missing")
        if case .notFound = result { /* ok */ } else {
            XCTFail("expected .notFound, got \(result)")
        }
    }

    func testLoadLoggedReturnsFailedForCorruptFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not-json".utf8).write(to: url)

        let result = Persist.loadLogged(Sample.self, from: url, context: "test.load.corrupt")
        if case .failed = result { /* ok */ } else {
            XCTFail("expected .failed, got \(result)")
        }
    }

    func testLoadResultValueAccessor() {
        let loaded = Persist.LoadResult.loaded(Sample(name: "v", count: 1))
        XCTAssertEqual(loaded.value, Sample(name: "v", count: 1))

        let missing = Persist.LoadResult<Sample>.notFound
        XCTAssertNil(missing.value)

        let failed = Persist.LoadResult<Sample>.failed
        XCTAssertNil(failed.value)
    }

    // MARK: - throwing save

    func testSaveThrowsWrappedFileWriteFailedOnBadPath() {
        let value = Sample(name: "x", count: 1)
        // A path under a file (not a dir) cannot be written — forces write failure.
        let parent = tempURL()
        try? Data().write(to: parent)
        defer { try? FileManager.default.removeItem(at: parent) }
        let url = parent.appendingPathComponent("child.json")

        XCTAssertThrowsError(try Persist.save(value, to: url, context: "test.save.throws")) { error in
            guard case Chau7Error.fileWriteFailed = error else {
                XCTFail("expected fileWriteFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - helpers

    private func tempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("persist-test-\(UUID().uuidString).json")
    }
}
