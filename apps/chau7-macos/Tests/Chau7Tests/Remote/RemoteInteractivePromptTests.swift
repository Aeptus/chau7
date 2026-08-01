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
            currentDirectory: "/tmp/test-project",
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
        XCTAssertEqual(decoded.currentDirectory, "/tmp/test-project")
    }

    func testMultiSelectFlagRoundTripsAndFalseIsOmitted() throws {
        let multi = RemoteInteractivePrompt(
            id: "p",
            tabID: 1,
            tabTitle: "t",
            toolName: "Claude",
            prompt: "Pick several",
            options: [
                RemoteInteractivePromptOption(id: "1", label: "A", response: "1\r"),
                RemoteInteractivePromptOption(id: "2", label: "B", response: "2\r")
            ],
            detectedAt: Date(timeIntervalSince1970: 0),
            isMultiSelect: true
        )
        let decoded = try JSONDecoder().decode(
            RemoteInteractivePrompt.self, from: JSONEncoder().encode(multi)
        )
        XCTAssertEqual(decoded.isMultiSelect, true)

        // omitempty parity with the Go mirror: false normalizes to nil and
        // the key never appears on the wire.
        let single = RemoteInteractivePrompt(
            id: "p",
            tabID: 1,
            tabTitle: "t",
            toolName: "Claude",
            prompt: "Pick one",
            options: multi.options,
            detectedAt: Date(timeIntervalSince1970: 0),
            isMultiSelect: false
        )
        XCTAssertNil(single.isMultiSelect)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(single)) as? [String: Any]
        )
        XCTAssertNil(object["multi_select"])
    }

    func testComposedPushTextPreservesMultiSelect() throws {
        // Every prompt is composed through withComposedPushText() on its way to
        // the wire, so a field dropped there is dropped for all of them —
        // silently, since composition is otherwise additive.
        let multi = RemoteInteractivePrompt(
            id: "p",
            tabID: 1,
            tabTitle: "t",
            toolName: "Claude",
            prompt: "Pick several",
            options: [RemoteInteractivePromptOption(id: "1", label: "A", response: "1\r")],
            detectedAt: Date(timeIntervalSince1970: 0),
            isMultiSelect: true
        )
        XCTAssertEqual(multi.withComposedPushText().isMultiSelect, true)
    }

    func testDecodesWithoutMultiSelectKey() throws {
        // Prompts from older Macs (and the Go agent's re-encode) omit the key.
        let json = """
        {"id":"p","tab_id":1,"tab_title":"t","tool_name":"Claude","prompt":"q",
         "options":[{"id":"1","label":"A","response":"1"}],"detected_at":0}
        """
        let decoded = try JSONDecoder().decode(RemoteInteractivePrompt.self, from: Data(json.utf8))
        XCTAssertNil(decoded.isMultiSelect)
    }
}
