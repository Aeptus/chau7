import XCTest
@testable import Chau7

@MainActor
final class ConflictDetectorTests: XCTestCase {
    func testConflictsForTabFiltersCorrectly() {
        let detector = ConflictDetector.shared
        let tab1 = UUID()
        let tab2 = UUID()
        let unrelatedTab = UUID()

        // No conflicts by default for an unrelated tab
        XCTAssertTrue(detector.conflictsForTab(unrelatedTab).isEmpty)
    }

    func testFileConflictEquality() {
        let id = UUID()
        let tabs: Set<UUID> = [UUID(), UUID()]
        let date = Date()
        let a = FileConflict(id: id, filePath: "f.swift", repoRoot: "/r", tabIDs: tabs, detectedAt: date)
        let b = FileConflict(id: id, filePath: "f.swift", repoRoot: "/r", tabIDs: tabs, detectedAt: date)
        XCTAssertEqual(a, b)
    }

    func testFileConflictInequality() {
        let tabs: Set<UUID> = [UUID(), UUID()]
        let a = FileConflict(id: UUID(), filePath: "a.swift", repoRoot: "/r", tabIDs: tabs, detectedAt: Date())
        let b = FileConflict(id: UUID(), filePath: "b.swift", repoRoot: "/r", tabIDs: tabs, detectedAt: Date())
        XCTAssertNotEqual(a, b)
    }

    func testConflictDetectorLookbackWindow() {
        let detector = ConflictDetector.shared
        XCTAssertEqual(detector.lookbackWindow, 300) // default 5 minutes
    }
}
