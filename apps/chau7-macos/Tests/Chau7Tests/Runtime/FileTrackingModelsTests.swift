import XCTest
@testable import Chau7Core

final class FileTrackingModelsTests: XCTestCase {
    func testBashActivitiesCaptureReadAndModifiedPaths() {
        let event = RuntimeEvent(
            seq: 1,
            sessionID: "s1",
            turnID: "t1",
            timestamp: Date(),
            type: RuntimeEventType.toolUse.rawValue,
            data: [
                "tool": "Bash",
                "args_summary": "cp src/config.json dist/config.json > logs/output.txt"
            ]
        )

        let activities = FileTrackingParser.activities(from: event, gitRoot: nil)
        XCTAssertEqual(
            activities,
            [
                TrackedFileActivity(path: "src/config.json", action: .read),
                TrackedFileActivity(path: "dist/config.json", action: .modified),
                TrackedFileActivity(path: "logs/output.txt", action: .modified)
            ]
        )
    }

    func testGrepActivitiesReadTargets() {
        let event = RuntimeEvent(
            seq: 1,
            sessionID: "s1",
            turnID: "t1",
            timestamp: Date(),
            type: RuntimeEventType.toolUse.rawValue,
            data: [
                "tool": "Grep",
                "args_summary": "EventJournal apps/chau7-macos/Sources/Chau7Core/Runtime/EventJournal.swift"
            ]
        )

        let activities = FileTrackingParser.activities(from: event, gitRoot: "/repo")
        XCTAssertEqual(
            activities,
            [TrackedFileActivity(path: "apps/chau7-macos/Sources/Chau7Core/Runtime/EventJournal.swift", action: .read)]
        )
    }

    func testCommandBlockFallbackUsesChangedFilesAndDefaultAction() {
        var block = CommandBlock(command: "python script.py", startLine: 1, directory: "/repo")
        block.changedFiles = ["Sources/App.swift", "Tests/AppTests.swift"]

        let activities = FileTrackingParser.activities(from: block, gitRoot: nil)
        XCTAssertEqual(
            activities,
            [
                TrackedFileActivity(path: "Sources/App.swift", action: .modified),
                TrackedFileActivity(path: "Tests/AppTests.swift", action: .modified)
            ]
        )
    }

    func testFleetFileIndexTracksOverlapsAndRemoval() {
        let index = FleetFileIndex()
        index.publish(agentID: "a1", files: ["a.swift", "b.swift"])
        index.publish(agentID: "a2", files: ["b.swift", "c.swift"])

        let overlaps = index.overlappingFiles()
        XCTAssertEqual(overlaps["b.swift"], Set(["a1", "a2"]))

        index.remove(agentID: "a1")
        XCTAssertNil(index.overlappingFiles()["b.swift"])
    }
}
