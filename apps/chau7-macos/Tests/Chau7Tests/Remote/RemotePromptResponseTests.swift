import XCTest
@testable import Chau7
@testable import Chau7Core

final class RemotePromptResponseTests: XCTestCase {
    private let firstPane = UUID()
    private let secondPane = UUID()

    private func prompt(id: String = "question", multi: Bool = false) -> RemoteInteractivePrompt {
        RemoteInteractivePrompt(
            id: id, tabID: 7, tabTitle: "split", toolName: "Claude", prompt: "Continue?",
            options: [.init(id: "yes", label: "Yes", response: "1\r"), .init(id: "no", label: "No", response: "2\r")],
            detectedAt: Date(timeIntervalSince1970: 0), isMultiSelect: multi, paneID: secondPane
        )
    }

    func testResponseTargetsSecondPaneWithoutFallingBackToFirst() {
        let request = RemotePromptResponse(promptID: "question", paneID: secondPane, action: .select, optionID: "yes")
        XCTAssertEqual(request.responseText(for: prompt(), tabID: 7, availablePaneIDs: [firstPane, secondPane]), "1\r")
        XCTAssertNil(request.responseText(for: prompt(), tabID: 7, availablePaneIDs: [firstPane]), "closed pane must never fall back to another shell")
        let wrongPane = RemotePromptResponse(promptID: "question", paneID: firstPane, action: .select, optionID: "yes")
        XCTAssertNil(wrongPane.responseText(for: prompt(), tabID: 7, availablePaneIDs: [firstPane, secondPane]))
    }

    func testStalePromptWrongTabAndUnknownOptionFailClosed() {
        let request = RemotePromptResponse(promptID: "question", paneID: secondPane, action: .select, optionID: "yes")
        XCTAssertNil(request.responseText(for: prompt(id: "replacement"), tabID: 7, availablePaneIDs: [secondPane]))
        XCTAssertNil(request.responseText(for: prompt(), tabID: 8, availablePaneIDs: [secondPane]))
        let unknown = RemotePromptResponse(promptID: "question", paneID: secondPane, action: .select, optionID: "injected")
        XCTAssertNil(unknown.responseText(for: prompt(), tabID: 7, availablePaneIDs: [secondPane]))
    }

    func testMultiSelectToggleDoesNotSubmitAndSubmitRequiresMultiSelect() {
        let toggle = RemotePromptResponse(promptID: "question", paneID: secondPane, action: .toggle, optionID: "yes")
        XCTAssertEqual(toggle.responseText(for: prompt(multi: true), tabID: 7, availablePaneIDs: [secondPane]), "1")
        XCTAssertNil(toggle.responseText(for: prompt(), tabID: 7, availablePaneIDs: [secondPane]))
        let submit = RemotePromptResponse(promptID: "question", paneID: secondPane, action: .submit)
        XCTAssertEqual(submit.responseText(for: prompt(multi: true), tabID: 7, availablePaneIDs: [secondPane]), "\r")
        XCTAssertNil(submit.responseText(for: prompt(), tabID: 7, availablePaneIDs: [secondPane]))
    }

    func testCustomResponsesAreBoundedAndRejectControlSequenceInjection() {
        for text in ["", " \n ", "yes\u{1B}[2J", String(repeating: "x", count: 16385)] {
            let request = RemotePromptResponse(promptID: "question", paneID: secondPane, action: .custom, customText: text)
            XCTAssertNil(request.responseText(for: prompt(), tabID: 7, availablePaneIDs: [secondPane]))
        }
        let request = RemotePromptResponse(promptID: "question", paneID: secondPane, action: .custom, customText: "  Explain first  ")
        XCTAssertEqual(request.responseText(for: prompt(), tabID: 7, availablePaneIDs: [secondPane]), "\u{1B}Explain first\r")
    }

    func testPaneIdentitySurvivesWireEncodingAndPushComposition() throws {
        let value = prompt().withComposedPushText()
        XCTAssertEqual(value.paneID, secondPane)
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(RemoteInteractivePrompt.self, from: data).paneID, secondPane)
        let request = RemotePromptResponse(promptID: value.id, paneID: secondPane, action: .select, optionID: "yes")
        XCTAssertEqual(try JSONDecoder().decode(RemotePromptResponse.self, from: JSONEncoder().encode(request)), request)
        XCTAssertEqual(RemoteFrameType.interactivePromptResponse.rawValue, 0x26)
        XCTAssertEqual(RemoteFrameType.paneInput.rawValue, 0x27)
    }

    func testTabInventoryCarriesTheStreamedInputPane() throws {
        let value = RemoteTabDescriptor(tabID: 7, title: "split", isActive: true, isMCPControlled: false, inputPaneID: firstPane)
        XCTAssertEqual(try JSONDecoder().decode(RemoteTabDescriptor.self, from: JSONEncoder().encode(value)).inputPaneID, firstPane)
        let text = RemotePaneInput(paneID: firstPane, text: "hello\r")
        XCTAssertEqual(try JSONDecoder().decode(RemotePaneInput.self, from: JSONEncoder().encode(text)), text)
    }

    func testNavigationUsesSemanticKeysAndBoundsSequences() {
        XCTAssertEqual(RemotePromptResponse.navigationKeys(for: "\u{1B}[B\u{1B}[A\r")?.map(\.key), ["down", "up", "enter"])
        XCTAssertEqual(RemotePromptResponse.navigationKeys(for: "\r")?.map(\.key), ["enter"])
        XCTAssertNil(RemotePromptResponse.navigationKeys(for: "1\r"))
        XCTAssertNil(RemotePromptResponse.navigationKeys(for: String(repeating: "\u{1B}[B", count: 33)))
        XCTAssertNil(RemotePromptResponse.navigationKeys(for: String(repeating: "\u{1B}[B", count: 32) + "\r"))
    }

    func testDelayedApprovalCannotMoveToReplacementTerminal() {
        let terminal = NSObject()
        let replacement = NSObject()
        let input = ProtectedRemoteInput(
            tabID: 7,
            text: "fixture",
            flaggedCommand: "fixture",
            paneID: secondPane,
            runtimeSessionID: "original",
            terminalIdentity: ObjectIdentifier(terminal)
        )
        XCTAssertTrue(input.matchesTarget(sessionID: "original", terminalIdentity: ObjectIdentifier(terminal)))
        XCTAssertFalse(input.matchesTarget(sessionID: "other", terminalIdentity: ObjectIdentifier(terminal)))
        XCTAssertFalse(input.matchesTarget(sessionID: "original", terminalIdentity: ObjectIdentifier(replacement)))
        XCTAssertFalse(input.matchesTarget(sessionID: "original", terminalIdentity: nil))
    }
}
