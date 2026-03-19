import XCTest
@testable import Chau7Core

final class RemoteInteractivePromptTests: XCTestCase {
    func testCodableRoundTripPreservesContextFields() throws {
        let prompt = RemoteInteractivePrompt(
            id: "prompt-1",
            tabID: 7,
            tabTitle: "website",
            toolName: "Claude",
            projectName: "Chau7",
            branchName: "main",
            currentDirectory: ".",
            prompt: "Do you want to proceed?",
            detail: "Will run a protected command",
            options: [
                RemoteInteractivePromptOption(id: "1", label: "Yes", response: "1\r"),
                RemoteInteractivePromptOption(id: "2", label: "No", response: "2\r", isDestructive: true)
            ],
            detectedAt: Date(timeIntervalSince1970: 1_742_000_000)
        )

        let data = try JSONEncoder().encode(prompt)
        let decoded = try JSONDecoder().decode(RemoteInteractivePrompt.self, from: data)

        XCTAssertEqual(decoded, prompt)
        XCTAssertEqual(decoded.projectName, "Chau7")
        XCTAssertEqual(decoded.branchName, "main")
        XCTAssertEqual(decoded.currentDirectory, ".")
    }
}
