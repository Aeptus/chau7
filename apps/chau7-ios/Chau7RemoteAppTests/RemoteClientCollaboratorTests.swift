import CryptoKit
import XCTest
import Chau7Core

/// First test bundle for the iOS app code, exercising the collaborators
/// extracted from RemoteClient (C6/C7). The bundle compiles the collaborator
/// sources directly (host-less logic tests — the full app makes a poor test
/// host because it boots the Rust terminal FFI); pure protocol logic lives
/// in Chau7Core and is covered by the macOS package suite.
@MainActor
final class ApprovalCoordinatorTests: XCTestCase {

    func testQueueAndSendableLifecycle() {
        let coordinator = ApprovalCoordinator()
        coordinator.queue(requestID: "r1", approved: true)
        coordinator.queue(requestID: "r2", approved: false)
        XCTAssertTrue(coordinator.hasQueuedResponses)

        let sendable = coordinator.takeSendable { _ in true }
        XCTAssertEqual(Set(sendable.map(\.requestID)), ["r1", "r2"])

        // In-flight responses are not handed out twice.
        XCTAssertTrue(coordinator.takeSendable { _ in true }.isEmpty)
    }

    func testResolveSendCompletesRequeuesAndSupersedes() {
        let coordinator = ApprovalCoordinator()
        coordinator.queue(requestID: "r1", approved: true)
        _ = coordinator.takeSendable { _ in true }

        // Failure → requeue (answer still current).
        XCTAssertEqual(
            coordinator.resolveSend(requestID: "r1", approved: true, success: false),
            .requeue(approved: true)
        )
        XCTAssertTrue(coordinator.hasQueuedResponses)

        // The user flips the answer while a retry is in flight → the stale
        // outcome is superseded, the new answer stays queued.
        _ = coordinator.takeSendable { _ in true }
        coordinator.queue(requestID: "r1", approved: false)
        XCTAssertEqual(
            coordinator.resolveSend(requestID: "r1", approved: true, success: true),
            .superseded
        )
        XCTAssertTrue(coordinator.hasQueuedResponses)

        // The current answer delivers → completed and cleared.
        _ = coordinator.takeSendable { _ in true }
        XCTAssertEqual(
            coordinator.resolveSend(requestID: "r1", approved: false, success: true),
            .completed(approved: false)
        )
        XCTAssertFalse(coordinator.hasQueuedResponses)
    }

    func testTakeSendableForgetsResolvedElsewhere() {
        let coordinator = ApprovalCoordinator()
        coordinator.queue(requestID: "gone", approved: true)
        let sendable = coordinator.takeSendable { _ in false }
        XCTAssertTrue(sendable.isEmpty)
        XCTAssertFalse(coordinator.hasQueuedResponses, "answers for vanished requests are forgotten")
    }
}

@MainActor
final class RemoteSessionControllerTests: XCTestCase {

    private func makeControllers() -> (ios: RemoteSessionController, macKey: Curve25519.KeyAgreement.PrivateKey) {
        (RemoteSessionController(iosKey: Curve25519.KeyAgreement.PrivateKey()),
         Curve25519.KeyAgreement.PrivateKey())
    }

    func testEstablishRequiresBothNoncesAndMacKey() {
        let (controller, macKey) = makeControllers()
        XCTAssertEqual(controller.establishIfPossible(), .notReady)

        controller.mintIOSNonce()
        XCTAssertEqual(controller.establishIfPossible(), .notReady, "mac nonce still missing")

        controller.setMacNonce(Data((0 ..< 16).map { UInt8($0) }))
        XCTAssertTrue(controller.adoptMacPublicKey(macKey.publicKey.rawRepresentation))
        XCTAssertEqual(controller.establishIfPossible(), .established)
        XCTAssertTrue(controller.isEstablished)

        // Re-entrancy: an existing session is not re-derived.
        XCTAssertEqual(controller.establishIfPossible(), .notReady)
    }

    func testInvalidateSessionResetsSequencing() {
        let (controller, macKey) = makeControllers()
        controller.mintIOSNonce()
        controller.setMacNonce(Data(repeating: 7, count: 16))
        _ = controller.adoptMacPublicKey(macKey.publicKey.rawRepresentation)
        XCTAssertEqual(controller.establishIfPossible(), .established)

        XCTAssertEqual(controller.nextSeq(), 1)
        XCTAssertEqual(controller.nextSeq(), 2)

        controller.invalidateSession(clearHandshakeMaterial: true)
        XCTAssertFalse(controller.isEstablished)
        XCTAssertNil(controller.nonceIOS)
        XCTAssertNil(controller.nonceMac)
        XCTAssertEqual(controller.nextSeq(), 1, "sequence restarts with the session")
    }

    func testRehandshakeResetKeepsMacKeyMintsFreshNonce() {
        let (controller, macKey) = makeControllers()
        controller.mintIOSNonce()
        let firstNonce = controller.nonceIOS
        controller.setMacNonce(Data(repeating: 1, count: 16))
        _ = controller.adoptMacPublicKey(macKey.publicKey.rawRepresentation)
        XCTAssertEqual(controller.establishIfPossible(), .established)

        controller.resetForRehandshake()
        XCTAssertFalse(controller.isEstablished)
        XCTAssertNotNil(controller.macPublicKey, "mac key survives a re-handshake reset")
        XCTAssertNotEqual(controller.nonceIOS, firstNonce, "fresh iOS nonce minted")
    }

    func testHelloEpochResetOrdersRehandshake() {
        let (controller, macKey) = makeControllers()
        controller.mintIOSNonce()
        let nonceA = Data(repeating: 0xA, count: 16)
        controller.setMacNonce(nonceA)
        _ = controller.adoptMacPublicKey(macKey.publicKey.rawRepresentation)
        XCTAssertEqual(controller.evaluateHello(macNonce: nonceA), .accept)
        XCTAssertEqual(controller.establishIfPossible(), .established)

        // Same nonce again: no reset.
        XCTAssertEqual(controller.evaluateHello(macNonce: nonceA), .accept)

        // Changed nonce with a live session: reset ordered.
        let nonceB = Data(repeating: 0xB, count: 16)
        guard case .resetSession = controller.evaluateHello(macNonce: nonceB) else {
            return XCTFail("changed mac nonce with a live session must order a reset")
        }
    }
}

final class RemoteMenuKeyHeuristicsTests: XCTestCase {

    private func prompt(tabID: UInt32) -> RemoteInteractivePrompt {
        RemoteInteractivePrompt(
            id: "tab-\(tabID)-test",
            tabID: tabID,
            tabTitle: "Tab \(tabID)",
            toolName: "Claude",
            prompt: "Which option?",
            options: [
                RemoteInteractivePromptOption(id: "1", label: "Yes", response: "1"),
                RemoteInteractivePromptOption(id: "2", label: "No", response: "2")
            ],
            detectedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func activity(tabID: UInt32, status: RemoteActivityStatus) -> RemoteActivityState {
        RemoteActivityState(
            activityID: "a-\(tabID)",
            tabID: tabID,
            tabTitle: "Tab \(tabID)",
            toolName: "Claude",
            status: status,
            headline: "",
            isSelectedTab: true,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - activeTabNeedsMenuKeys

    func testPromptOnActiveTabNeedsKeys() {
        XCTAssertTrue(RemoteMenuKeyHeuristics.activeTabNeedsMenuKeys(
            prompts: [prompt(tabID: 3)], activity: nil, activeTabID: 3
        ))
    }

    func testPromptOnOtherTabDoesNotNeedKeys() {
        XCTAssertFalse(RemoteMenuKeyHeuristics.activeTabNeedsMenuKeys(
            prompts: [prompt(tabID: 4)], activity: nil, activeTabID: 3
        ))
    }

    func testActivityStatusDrivesKeys() {
        for (status, expected) in [
            (RemoteActivityStatus.waitingInput, true),
            (.approvalRequired, true),
            (.running, false),
            (.idle, false),
            (.completed, false),
            (.failed, false)
        ] {
            XCTAssertEqual(
                RemoteMenuKeyHeuristics.activeTabNeedsMenuKeys(
                    prompts: [], activity: activity(tabID: 3, status: status), activeTabID: 3
                ),
                expected,
                "status \(status)"
            )
        }
    }

    func testActivityForOtherTabIsIgnored() {
        XCTAssertFalse(RemoteMenuKeyHeuristics.activeTabNeedsMenuKeys(
            prompts: [], activity: activity(tabID: 9, status: .waitingInput), activeTabID: 3
        ))
    }

    func testNoSignalsMeansNoKeys() {
        XCTAssertFalse(RemoteMenuKeyHeuristics.activeTabNeedsMenuKeys(
            prompts: [], activity: nil, activeTabID: 3
        ))
    }

    func testUnsetActiveTabNeverNeedsKeys() {
        XCTAssertFalse(RemoteMenuKeyHeuristics.activeTabNeedsMenuKeys(
            prompts: [prompt(tabID: 0)],
            activity: activity(tabID: 0, status: .waitingInput),
            activeTabID: 0
        ))
    }

    // MARK: - semanticKeys(forNavigationResponse:)

    func testNavigationResponsesTranslateToSemanticKeys() {
        XCTAssertEqual(
            RemoteMenuKeyHeuristics.semanticKeys(forNavigationResponse: "\u{1B}[B\u{1B}[B\r")?.map(\.key),
            ["down", "down", "enter"]
        )
        XCTAssertEqual(
            RemoteMenuKeyHeuristics.semanticKeys(forNavigationResponse: "\u{1B}[A\r")?.map(\.key),
            ["up", "enter"]
        )
        XCTAssertEqual(
            RemoteMenuKeyHeuristics.semanticKeys(forNavigationResponse: "\r")?.map(\.key),
            ["enter"],
            "bare Enter (already-selected option) is pure navigation"
        )
    }

    func testNonNavigationResponsesStayOnTextPath() {
        for response in ["1\r", "y\r", "", "text\r", "\u{1B}[B1\r", "\u{1B}"] {
            XCTAssertNil(
                RemoteMenuKeyHeuristics.semanticKeys(forNavigationResponse: response),
                "response \(response.debugDescription) must not translate"
            )
        }
    }

    // MARK: - shouldSuppressSubmitTerminator

    func testSuppressesShortDigitSendsWhilePromptPending() {
        for text in ["1", "12", "123"] {
            XCTAssertTrue(
                RemoteMenuKeyHeuristics.shouldSuppressSubmitTerminator(
                    text: text, hasPendingPromptForActiveTab: true
                ),
                "text \(text)"
            )
        }
    }

    func testKeepsTerminatorWithoutPendingPrompt() {
        XCTAssertFalse(RemoteMenuKeyHeuristics.shouldSuppressSubmitTerminator(
            text: "2", hasPendingPromptForActiveTab: false
        ))
    }

    func testKeepsTerminatorForNonMenuText() {
        // Too long, mixed, empty, and non-ASCII digits: all keep their Enter.
        for text in ["1234", "1a", "", "y", "١٢"] {
            XCTAssertFalse(
                RemoteMenuKeyHeuristics.shouldSuppressSubmitTerminator(
                    text: text, hasPendingPromptForActiveTab: true
                ),
                "text \(text)"
            )
        }
    }
}

final class RemoteTabOrderingTests: XCTestCase {
    func testAlphabeticalOrderIsIndependentOfActivityOrder() {
        let tabs = [
            tab(id: 3, title: "Zulu"),
            tab(id: 1, title: "Alpha 10"),
            tab(id: 2, title: "Alpha 2")
        ]

        XCTAssertEqual(
            RemoteTabOrdering.alphabetically(tabs).map(\.tabID),
            [2, 1, 3]
        )
        XCTAssertEqual(
            RemoteTabOrdering.alphabetically(Array(tabs.reversed())).map(\.tabID),
            [2, 1, 3]
        )
    }

    func testDuplicateTitlesUseStableTabIDTieBreaker() {
        let tabs = [tab(id: 9, title: "Build"), tab(id: 4, title: " build ")]

        XCTAssertEqual(RemoteTabOrdering.alphabetically(tabs).map(\.tabID), [4, 9])
    }

    private func tab(id: UInt32, title: String) -> RemoteTab {
        RemoteTab(
            tabID: id,
            title: title,
            isActive: false,
            isMCPControlled: false
        )
    }
}

final class RemoteTabInventoryTests: XCTestCase {
    func testReorderOnlySnapshotDoesNotPublishReplacement() {
        let current = [tab(id: 1, title: "Alpha"), tab(id: 2, title: "Beta")]
        let incoming = Array(current.reversed())

        XCTAssertNil(RemoteTabInventory.replacementIfChanged(current: current, incoming: incoming))
    }

    func testMetadataChangePublishesCanonicalReplacement() {
        let current = [tab(id: 2, title: "Old"), tab(id: 1, title: "Alpha")]
        let incoming = [tab(id: 2, title: "New"), tab(id: 1, title: "Alpha")]

        let replacement = RemoteTabInventory.replacementIfChanged(current: current, incoming: incoming)
        XCTAssertEqual(replacement?.map(\.tabID), [1, 2])
        XCTAssertEqual(replacement?.last?.title, "New")
    }

    private func tab(id: UInt32, title: String) -> RemoteTab {
        RemoteTab(tabID: id, title: title, isActive: false, isMCPControlled: false)
    }
}

@MainActor
final class RemoteTransportTests: XCTestCase {

    func testSendWithoutSocketReturnsFalse() {
        let transport = RemoteTransport()
        XCTAssertFalse(transport.isOpen)
        XCTAssertFalse(transport.send(Data([1, 2, 3])))
    }

    func testCloseInvalidatesGenerationAndIsIdempotent() {
        let transport = RemoteTransport()
        let g0 = transport.generation
        transport.close()
        let g1 = transport.generation
        XCTAssertGreaterThan(g1, g0, "close must invalidate the generation")
        transport.close()
        XCTAssertGreaterThan(transport.generation, g1)
        XCTAssertFalse(transport.isOpen)
    }
}
