import Chau7Core
import CryptoKit
import XCTest

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
        XCTAssertNil(controller.nonceMac, "a fresh Mac HELLO must acknowledge the new epoch")
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
                RemoteInteractivePromptOption(id: "2", label: "No", response: "2"),
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
            (.failed, false),
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
            tab(id: 2, title: "Alpha 2"),
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

final class RemoteTabSelectionTests: XCTestCase {
    func testKeepsPhoneSelectionWhenMacActiveTabChanges() {
        let tabs = [tab(id: 1, isActive: true), tab(id: 2, isActive: false)]

        XCTAssertEqual(
            RemoteTabSelectionPolicy.resolvedActiveTabID(currentActiveTabID: 2, incoming: tabs),
            2
        )
    }

    func testInitialSelectionUsesMacActiveTab() {
        let tabs = [tab(id: 1, isActive: false), tab(id: 2, isActive: true)]

        XCTAssertEqual(
            RemoteTabSelectionPolicy.resolvedActiveTabID(currentActiveTabID: 0, incoming: tabs),
            2
        )
    }

    func testMissingSelectionFallsBackToMacActiveThenFirstTab() {
        XCTAssertEqual(
            RemoteTabSelectionPolicy.resolvedActiveTabID(
                currentActiveTabID: 9,
                incoming: [tab(id: 3, isActive: false), tab(id: 4, isActive: true)]
            ),
            4
        )
        XCTAssertEqual(
            RemoteTabSelectionPolicy.resolvedActiveTabID(
                currentActiveTabID: 9,
                incoming: [tab(id: 3, isActive: false)]
            ),
            3
        )
        XCTAssertEqual(
            RemoteTabSelectionPolicy.resolvedActiveTabID(currentActiveTabID: 9, incoming: []),
            0
        )
    }

    private func tab(id: UInt32, isActive: Bool) -> RemoteTab {
        RemoteTab(tabID: id, title: "Tab \(id)", isActive: isActive, isMCPControlled: false)
    }
}

final class RemoteTerminalScrollPolicyTests: XCTestCase {
    func testLayoutDrivenScrollCallbacksAreNeverForwarded() {
        XCTAssertFalse(RemoteTerminalScrollPolicy.shouldForwardUserScroll(
            isSynchronizing: false,
            isTracking: false,
            isDragging: false,
            isDecelerating: false
        ))
        XCTAssertFalse(RemoteTerminalScrollPolicy.shouldForwardUserScroll(
            isSynchronizing: true,
            isTracking: true,
            isDragging: true,
            isDecelerating: true
        ))
    }

    func testDirectAndDeceleratingUserScrollsAreForwarded() {
        XCTAssertTrue(RemoteTerminalScrollPolicy.shouldForwardUserScroll(
            isSynchronizing: false,
            isTracking: true,
            isDragging: false,
            isDecelerating: false
        ))
        XCTAssertTrue(RemoteTerminalScrollPolicy.shouldForwardUserScroll(
            isSynchronizing: false,
            isTracking: false,
            isDragging: false,
            isDecelerating: true
        ))
    }

    func testDisplayOffsetMeasuresRowsFromLiveBottom() {
        XCTAssertEqual(RemoteTerminalScrollPolicy.displayOffset(
            contentHeight: 1000,
            viewportHeight: 400,
            contentOffsetY: 600,
            cellHeight: 20,
            scrollbackRows: 100
        ), 0)
        XCTAssertEqual(RemoteTerminalScrollPolicy.displayOffset(
            contentHeight: 1000,
            viewportHeight: 400,
            contentOffsetY: 400,
            cellHeight: 20,
            scrollbackRows: 100
        ), 10)
    }
}

final class RemoteConnectionStartPolicyTests: XCTestCase {
    func testAutomaticConnectionCoalescesBehindOpenTransport() {
        XCTAssertFalse(RemoteConnectionStartPolicy.shouldStartConnection(
            transportIsOpen: true,
            forceRestart: false
        ))
        XCTAssertTrue(RemoteConnectionStartPolicy.shouldStartConnection(
            transportIsOpen: false,
            forceRestart: false
        ))
    }

    func testManualConnectionMayRestartOpenTransport() {
        XCTAssertTrue(RemoteConnectionStartPolicy.shouldStartConnection(
            transportIsOpen: true,
            forceRestart: true
        ))
    }

    func testReconnectSchedulingIsSingleFlight() {
        XCTAssertTrue(RemoteConnectionStartPolicy.shouldScheduleReconnect(
            hasScheduledReconnect: false,
            shouldReconnect: true,
            hasRemainingAttempts: true
        ))
        XCTAssertFalse(RemoteConnectionStartPolicy.shouldScheduleReconnect(
            hasScheduledReconnect: true,
            shouldReconnect: true,
            hasRemainingAttempts: true
        ))
        XCTAssertFalse(RemoteConnectionStartPolicy.shouldScheduleReconnect(
            hasScheduledReconnect: false,
            shouldReconnect: false,
            hasRemainingAttempts: true
        ))
    }

    func testFailureClassifierKeepsLogsBoundedAndNonSensitive() {
        XCTAssertEqual(RemoteConnectionFailureClassifier.classify("handshake_timeout"), "timeout")
        XCTAssertEqual(RemoteConnectionFailureClassifier.classify("The network is offline"), "network_unavailable")
        XCTAssertEqual(RemoteConnectionFailureClassifier.classify("TLS certificate rejected"), "transport_security")
        XCTAssertEqual(RemoteConnectionFailureClassifier.classify("private relay URL details"), "other")
        XCTAssertEqual(RemoteConnectionFailureClassifier.classify(nil), "unknown")
    }
}

final class DiagnosticsRetentionPolicyTests: XCTestCase {
    func testSensitiveOverflowTrimsOnlyOldestSensitiveEntriesToTarget() {
        let categories = [
            "connection", "keystroke", "tab", "input",
            "lifecycle", "keystroke", "input", "keystroke",
        ]

        let removals = DiagnosticsRetentionPolicy.removalIndexes(
            categories: categories,
            maxEntries: 20,
            sensitiveLimit: 4,
            sensitiveTarget: 2
        )

        XCTAssertEqual(Array(removals), [1, 3, 5])
        XCTAssertEqual(
            categories.indices.filter { !removals.contains($0) }.map { categories[$0] },
            ["connection", "tab", "lifecycle", "input", "keystroke"]
        )
    }

    func testGlobalCapRunsAfterSensitiveQuota() {
        let categories = ["connection", "tab", "keystroke", "lifecycle", "ui", "network"]

        let removals = DiagnosticsRetentionPolicy.removalIndexes(
            categories: categories,
            maxEntries: 3,
            sensitiveLimit: 1,
            sensitiveTarget: 1
        )

        XCTAssertEqual(Array(removals), [0, 1, 2])
        XCTAssertEqual(
            categories.indices.filter { !removals.contains($0) }.map { categories[$0] },
            ["lifecycle", "ui", "network"]
        )
    }

    func testInvalidLimitsFailClosedWithoutRemovingEntries() {
        XCTAssertTrue(DiagnosticsRetentionPolicy.removalIndexes(
            categories: ["keystroke"],
            maxEntries: 8,
            sensitiveLimit: 1,
            sensitiveTarget: 2
        ).isEmpty)
    }
}

final class RemoteIssueReportComposerTests: XCTestCase {
    private let context = RemoteIssueReportContext(
        appVersion: "1.2.3 (45)",
        osVersion: "20.0",
        deviceModel: "iPhone",
        connectionStatus: "Connected",
        tabInventoryStatus: "Syncing…",
        tabCount: 0
    )

    func testReportIncludesDescriptionContactAndEnvironment() {
        let report = RemoteIssueReportComposer.markdown(
            description: "  The tab list was empty.  ",
            contact: "  octocat  ",
            context: context,
            diagnostics: nil
        )

        XCTAssertTrue(report.contains("The tab list was empty."))
        XCTAssertTrue(report.contains("octocat"))
        XCTAssertTrue(report.contains("- App version: 1.2.3 (45)"))
        XCTAssertTrue(report.contains("- Remote tabs: Syncing…"))
        XCTAssertTrue(report.contains("- Tab count: 0"))
        XCTAssertFalse(report.contains("Recent diagnostics"))
    }

    func testDiagnosticsAreIncludedOnlyWhenProvided() {
        let report = RemoteIssueReportComposer.markdown(
            description: "Unexpected disconnect",
            contact: "",
            context: context,
            diagnostics: "2026-08-29T06:01:09Z [info] connection: Session ready"
        )

        XCTAssertTrue(report.contains("Not provided"))
        XCTAssertTrue(report.contains("## Recent diagnostics"))
        XCTAssertTrue(report.contains("```text"))
        XCTAssertTrue(report.contains("Session ready"))
    }
}

final class RemoteStreamingPerformanceWindowTests: XCTestCase {
    func testFrameTraceMeasuresEveryRenderingBoundary() {
        let trace = completedFrameTrace()
        let latency = trace.latency

        assertMilliseconds(latency.macCaptureToSendMs, equals: 4)
        assertMilliseconds(latency.estimatedMacSendToIOSReceiveMs, equals: 10)
        assertMilliseconds(latency.iosReceiveToApplyMs, equals: 2)
        assertMilliseconds(latency.iosApplyToEngineMs, equals: 3)
        assertMilliseconds(latency.engineToPublishMs, equals: 5)
        assertMilliseconds(latency.publishToViewMs, equals: 2)
        assertMilliseconds(latency.viewToDrawMs, equals: 4)
        assertMilliseconds(latency.drawToNextVSyncMs, equals: 8)
        assertMilliseconds(latency.estimatedMacCaptureToDrawMs, equals: 30)
        assertMilliseconds(latency.estimatedMacCaptureToNextVSyncMs, equals: 38)
        XCTAssertEqual(trace.identity.description, "7:42")
    }

    func testFrameTraceClampsNegativeCrossDeviceClockDelta() {
        var trace = completedFrameTrace()
        trace.nextVSyncAt = Date(timeIntervalSince1970: 999)

        XCTAssertEqual(trace.latency.estimatedMacCaptureToNextVSyncMs, 0)
    }

    func testWindowAggregatesPipelineAndCoalescingMetrics() {
        let start = Date(timeIntervalSince1970: 1000)
        var window = RemoteStreamingPerformanceWindow(startedAt: start)
        window.recordFrame(
            type: .output,
            admission: .admitted,
            bytes: 100,
            queueAgeMs: 4,
            receiveToApplyMs: 7,
            supersededGrids: 2,
            evictedOutput: 3
        )
        window.recordFrame(
            type: .terminalGridSnapshot,
            admission: .admitted,
            bytes: 300,
            queueAgeMs: 9,
            receiveToApplyMs: 15,
            supersededGrids: 0,
            evictedOutput: 0
        )
        window.recordGridDecode(durationMs: 6)
        window.recordPublish(durationMs: 2)
        window.recordOutputTiming(senderBatchMs: 4, estimatedCaptureToReceiveMs: 35)
        window.recordPresentation(completedFrameTrace())
        window.recordOutputRecovery()

        XCTAssertNil(window.takeSnapshotIfDue(now: start.addingTimeInterval(4)))
        guard let sample = window.takeSnapshotIfDue(now: start.addingTimeInterval(5)) else {
            return XCTFail("Expected a due streaming snapshot")
        }
        XCTAssertEqual(sample.frameCount, 2)
        XCTAssertEqual(sample.admittedFrameCount, 2)
        XCTAssertEqual(sample.decodeFailureCount, 0)
        XCTAssertEqual(sample.decryptFailureCount, 0)
        XCTAssertEqual(sample.outputFrameCount, 1)
        XCTAssertEqual(sample.gridFrameCount, 1)
        XCTAssertEqual(sample.bytes, 400)
        XCTAssertEqual(sample.maxQueueAgeMs, 9)
        XCTAssertEqual(sample.maxReceiveToApplyMs, 15)
        XCTAssertEqual(sample.averageGridDecodeMs, 6)
        XCTAssertEqual(sample.averagePublishMs, 2)
        XCTAssertEqual(sample.supersededGridFrames, 2)
        XCTAssertEqual(sample.evictedOutputFrames, 3)
        XCTAssertEqual(sample.outputRecoveryCount, 1)
        XCTAssertEqual(sample.maxSenderBatchMs, 4)
        XCTAssertEqual(sample.maxEstimatedCaptureToReceiveMs, 35)
        XCTAssertEqual(sample.presentedFrameCount, 1)
        XCTAssertEqual(sample.maxEstimatedMacSendToIOSReceiveMs, 10, accuracy: 0.001)
        XCTAssertEqual(sample.maxIOSReceiveToApplyMs, 2, accuracy: 0.001)
        XCTAssertEqual(sample.maxIOSApplyToEngineMs, 3, accuracy: 0.001)
        XCTAssertEqual(sample.maxEngineToPublishMs, 5, accuracy: 0.001)
        XCTAssertEqual(sample.maxPublishToViewMs, 2, accuracy: 0.001)
        XCTAssertEqual(sample.maxViewToDrawMs, 4, accuracy: 0.001)
        XCTAssertEqual(sample.maxDrawToNextVSyncMs, 8, accuracy: 0.001)
        XCTAssertEqual(sample.maxEstimatedMacCaptureToDrawMs, 30, accuracy: 0.01)
        XCTAssertEqual(sample.maxEstimatedMacCaptureToNextVSyncMs, 38, accuracy: 0.01)
        XCTAssertEqual(sample.lastPresentedTraceIdentity?.description, "7:42")
        XCTAssertEqual(sample.lastPresentedBytes, 128)
    }

    func testWindowSeparatesAdmissionFailuresFromAcceptedFrameTypes() {
        let start = Date(timeIntervalSince1970: 1000)
        var window = RemoteStreamingPerformanceWindow(startedAt: start)
        window.recordFrame(
            type: .output,
            admission: .decryptFailed,
            bytes: 120,
            queueAgeMs: 1,
            receiveToApplyMs: 2,
            supersededGrids: 0,
            evictedOutput: 0
        )
        window.recordFrame(
            type: nil,
            admission: .decodeFailed,
            bytes: 5,
            queueAgeMs: 1,
            receiveToApplyMs: 2,
            supersededGrids: 0,
            evictedOutput: 0
        )
        window.recordFrame(
            type: .tabList,
            admission: .admitted,
            bytes: 80,
            queueAgeMs: 1,
            receiveToApplyMs: 2,
            supersededGrids: 0,
            evictedOutput: 0
        )
        window.recordFrame(
            type: .sessionReady,
            admission: .admitted,
            bytes: 40,
            queueAgeMs: 1,
            receiveToApplyMs: 2,
            supersededGrids: 0,
            evictedOutput: 0
        )

        guard let sample = window.takeSnapshotIfDue(now: start.addingTimeInterval(5)) else {
            return XCTFail("Expected a due streaming snapshot")
        }
        XCTAssertEqual(sample.frameCount, 4)
        XCTAssertEqual(sample.admittedFrameCount, 2)
        XCTAssertEqual(sample.decodeFailureCount, 1)
        XCTAssertEqual(sample.decryptFailureCount, 1)
        XCTAssertEqual(sample.outputFrameCount, 0, "rejected output is not admitted output")
        XCTAssertEqual(sample.tabInventoryFrameCount, 1)
        XCTAssertEqual(sample.sessionReadyFrameCount, 1)
    }

    private func completedFrameTrace() -> RemoteTerminalFrameTrace {
        RemoteTerminalFrameTrace(
            transportGeneration: 7,
            sequence: 42,
            tabID: 3,
            bytes: 128,
            macCapturedAtMicroseconds: 1_000_000_000,
            macSentAtMicroseconds: 1_000_004_000,
            iosReceivedAt: Date(timeIntervalSince1970: 1000.014),
            iosAppliedAt: Date(timeIntervalSince1970: 1000.016),
            engineAppliedAt: Date(timeIntervalSince1970: 1000.019),
            statePublishedAt: Date(timeIntervalSince1970: 1000.024),
            viewUpdatedAt: Date(timeIntervalSince1970: 1000.026),
            canvasDrawnAt: Date(timeIntervalSince1970: 1000.030),
            nextVSyncAt: Date(timeIntervalSince1970: 1000.038)
        )
    }

    private func assertMilliseconds(
        _ actual: Double?,
        equals expected: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            return XCTFail("Expected a latency value", file: file, line: line)
        }
        XCTAssertEqual(actual, expected, accuracy: 0.01, file: file, line: line)
    }
}

@MainActor
final class RemoteTransportTests: XCTestCase {
    func testInboundQueueCoalescesGridSnapshotsWithoutReorderingRetainedFrames() {
        var queue = RemoteInboundMessageQueue()
        let output1 = RemoteFrame(type: RemoteFrameType.output.rawValue, tabID: 1, seq: 1, payload: Data([1])).encode()
        let grid1 = RemoteFrame(type: RemoteFrameType.terminalGridSnapshot.rawValue, tabID: 1, seq: 2, payload: Data([2])).encode()
        let output2 = RemoteFrame(type: RemoteFrameType.output.rawValue, tabID: 1, seq: 3, payload: Data([3])).encode()
        let grid2 = RemoteFrame(type: RemoteFrameType.terminalGridSnapshot.rawValue, tabID: 1, seq: 4, payload: Data([4])).encode()

        for data in [output1, grid1, output2, grid2] {
            queue.enqueue(data: data, generation: 7)
        }

        let retained = queue.messages.compactMap { try? RemoteFrame.decode(from: $0.data).seq }
        XCTAssertEqual(retained, [1, 3, 4])
        XCTAssertEqual(queue.takeShedCounts().supersededGrids, 1)
    }

    func testInboundQueueShedsOnlyReplaceableGridStateAtByteLimit() {
        var queue = RemoteInboundMessageQueue(maxBufferedBytes: 64)
        let output = RemoteFrame(type: RemoteFrameType.output.rawValue, tabID: 1, seq: 1, payload: Data(repeating: 1, count: 30)).encode()
        let grid = RemoteFrame(type: RemoteFrameType.terminalGridSnapshot.rawValue, tabID: 1, seq: 2, payload: Data(repeating: 2, count: 30)).encode()

        queue.enqueue(data: output, generation: 1)
        queue.enqueue(data: grid, generation: 1)

        XCTAssertEqual(queue.messages.count, 1)
        XCTAssertFalse(queue.messages[0].isGridSnapshot)
        XCTAssertEqual(queue.takeShedCounts().supersededGrids, 1)
    }

    func testInboundQueueFastForwardsOrderedOutputAndSignalsCheckpointAfterDrain() {
        var queue = RemoteInboundMessageQueue(maxBufferedBytes: 80)
        let output1 = RemoteFrame(
            type: RemoteFrameType.output.rawValue,
            tabID: 1,
            seq: 1,
            payload: Data(repeating: 1, count: 30)
        ).encode()
        let control = RemoteFrame(
            type: RemoteFrameType.activityState.rawValue,
            tabID: 1,
            seq: 2,
            payload: Data([2])
        ).encode()
        let output2 = RemoteFrame(
            type: RemoteFrameType.output.rawValue,
            tabID: 1,
            seq: 3,
            payload: Data(repeating: 3, count: 30)
        ).encode()

        for data in [output1, control, output2] {
            queue.enqueue(data: data, generation: 1)
        }

        // Output is marked for fast-forward *and* dropped: its visual content
        // was already abandoned in favour of a checkpoint, so the bytes are not
        // worth holding. The control frame has no checkpoint equivalent and is
        // kept regardless. Dropping a sequence number is safe because the
        // replay guard only requires strict monotonicity, not contiguity.
        XCTAssertTrue(queue.outputRecoveryPending)
        XCTAssertEqual(queue.messages.count, 2)
        XCTAssertEqual(queue.messages.map(\.suppressOutputApplication), [false, true])
        XCTAssertEqual(queue.evictedOutputFrames, 1)
        XCTAssertFalse(
            queue.messages.contains { message in
                guard message.isOutput else { return false }
                return message.data.count == 50 && message.data[message.data.startIndex + 8] == 1
            },
            "the seq-1 output frame is the one shed"
        )

        XCTAssertFalse(queue.takeOutputRecoverySignalIfDrained())
        while queue.popFirst() != nil {}
        XCTAssertTrue(queue.takeOutputRecoverySignalIfDrained())
        XCTAssertFalse(queue.takeOutputRecoverySignalIfDrained())
    }

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

/// Regression coverage for the rich terminal renderer's viewport declaration.
///
/// The renderer used to gate its viewport declaration behind
/// `renderState != nil`. The store only publishes a `renderState` after it has
/// been told the viewport, and the viewport can only be learned from a
/// laid-out view — so the renderer could never start. Because `.replay` mode
/// deliberately does not feed the plain-text output store, the text fallback
/// then showed a permanently empty terminal.
///
/// These lock in the arithmetic half of the fix; the wiring itself is covered
/// by the always-mounted declaration in `RemoteTerminalRendererView`, which
/// cannot be host-tested (the rendering stack links the Rust terminal FFI).
final class RemoteTerminalViewportGeometryTests: XCTestCase {
    private let cell = CGSize(width: 8, height: 18)

    func testGridFitsWholeCells() {
        let size = RemoteTerminalViewportGeometry.gridSize(
            available: CGSize(width: 81, height: 37),
            cell: cell
        )
        XCTAssertEqual(size?.cols, 10, "81pt / 8pt is 10 whole columns, not 10.125")
        XCTAssertEqual(size?.rows, 2, "37pt / 18pt is 2 whole rows, not 2.05")
    }

    func testDegenerateAvailableSizeDeclaresNothing() {
        // A zero size means "not laid out yet" and must be distinguishable from
        // a real 1x1 grid, otherwise the first layout pass would pin the store
        // to a 1-column viewport.
        XCTAssertNil(RemoteTerminalViewportGeometry.gridSize(available: .zero, cell: cell))
        XCTAssertNil(
            RemoteTerminalViewportGeometry.gridSize(
                available: CGSize(width: -10, height: 40),
                cell: cell
            )
        )
    }

    func testSubCellViewportStillDeclaresOneColumnAndRow() {
        let size = RemoteTerminalViewportGeometry.gridSize(
            available: CGSize(width: 3, height: 4),
            cell: cell
        )
        XCTAssertEqual(size?.cols, 1)
        XCTAssertEqual(size?.rows, 1)
    }

    func testDegenerateCellSizeDeclaresNothing() {
        XCTAssertNil(
            RemoteTerminalViewportGeometry.gridSize(
                available: CGSize(width: 100, height: 100),
                cell: .zero
            )
        )
    }

    func testLargerViewportYieldsLargerGrid() {
        let small = RemoteTerminalViewportGeometry.gridSize(
            available: CGSize(width: 100, height: 100),
            cell: cell
        )
        let large = RemoteTerminalViewportGeometry.gridSize(
            available: CGSize(width: 200, height: 200),
            cell: cell
        )
        XCTAssertEqual(small?.cols, 12)
        XCTAssertEqual(small?.rows, 5)
        XCTAssertEqual(large?.cols, 25)
        XCTAssertEqual(large?.rows, 11)
    }
}

/// A lock-screen Allow/Deny can be delivered on a cold launch, before the
/// WebSocket has connected and before `/pending` has populated the approval
/// list. Dropping it there left the request looking untouched with the Mac's
/// agent still blocked, so the decision is deferred until the request is known.
@MainActor
final class DeferredDecisionLedgerTests: XCTestCase {
    func testEmptyLedgerYieldsNothing() {
        let ledger = DeferredDecisionLedger()
        XCTAssertTrue(ledger.isEmpty)
        XCTAssertTrue(ledger.takeReady(knownRequestIDs: ["r1"]).isEmpty)
    }

    func testDecisionForUnknownRequestIsHeld() {
        let ledger = DeferredDecisionLedger()
        ledger.record(requestID: "r1", approved: true)
        XCTAssertFalse(ledger.isEmpty)
        // A list that does not contain the request must not consume it.
        XCTAssertTrue(ledger.takeReady(knownRequestIDs: ["other"]).isEmpty)
        XCTAssertEqual(ledger.count, 1)
    }

    func testDecisionIsReleasedOnceRequestIsKnown() {
        let ledger = DeferredDecisionLedger()
        ledger.record(requestID: "r1", approved: true)
        ledger.record(requestID: "r2", approved: false)

        let ready = ledger.takeReady(knownRequestIDs: ["r1", "unrelated"])
        XCTAssertEqual(ready.count, 1)
        XCTAssertEqual(ready.first?.requestID, "r1")
        XCTAssertEqual(ready.first?.approved, true)
        // r2 is still unknown, so it stays deferred.
        XCTAssertEqual(ledger.count, 1)
    }

    func testNewestDecisionForTheSameRequestWins() {
        let ledger = DeferredDecisionLedger()
        ledger.record(requestID: "r1", approved: true)
        ledger.record(requestID: "r1", approved: false)
        let ready = ledger.takeReady(knownRequestIDs: ["r1"])
        XCTAssertEqual(ready.count, 1)
        XCTAssertEqual(ready.first?.approved, false)
    }

    func testReleasedDecisionsAreNotReturnedTwice() {
        let ledger = DeferredDecisionLedger()
        ledger.record(requestID: "r1", approved: true)
        XCTAssertEqual(ledger.takeReady(knownRequestIDs: ["r1"]).count, 1)
        XCTAssertTrue(ledger.takeReady(knownRequestIDs: ["r1"]).isEmpty)
        XCTAssertTrue(ledger.isEmpty)
    }

    func testLedgerIsBoundedAndEvictsOldestFirst() {
        let ledger = DeferredDecisionLedger(capacity: 3)
        for index in 0 ..< 5 {
            ledger.record(requestID: "r\(index)", approved: true)
        }
        XCTAssertEqual(ledger.count, 3)
        XCTAssertEqual(ledger.requestIDs, ["r2", "r3", "r4"])
        // The two oldest are gone; the newest three are still deliverable.
        let ready = ledger.takeReady(knownRequestIDs: ["r0", "r1", "r2", "r3", "r4"])
        XCTAssertEqual(Set(ready.map(\.requestID)), ["r2", "r3", "r4"])
    }

    func testOverwritingARequestDoesNotConsumeCapacity() {
        let ledger = DeferredDecisionLedger(capacity: 2)
        ledger.record(requestID: "r1", approved: true)
        ledger.record(requestID: "r1", approved: false)
        ledger.record(requestID: "r2", approved: true)
        XCTAssertEqual(ledger.count, 2)
        XCTAssertEqual(ledger.requestIDs, ["r1", "r2"])
    }

    func testResetDiscardsEverything() {
        let ledger = DeferredDecisionLedger()
        ledger.record(requestID: "r1", approved: true)
        ledger.reset()
        XCTAssertTrue(ledger.isEmpty)
        XCTAssertTrue(ledger.takeReady(knownRequestIDs: ["r1"]).isEmpty)
    }
}

/// The receive queue's byte budget used to be advisory only: grids were shed
/// first, but once they were gone nothing was ever removed, so a `cat` of a
/// large file (or a relay replaying captured output) grew `bufferedBytes`
/// without limit until the process was jetsammed.
@MainActor
final class RemoteInboundQueueEvictionTests: XCTestCase {
    private func outputFrame(bytes: Int) -> Data {
        var data = Data([1 /* RemoteFrame version */, RemoteFrameType.output.rawValue, 0, 0])
        data.append(contentsOf: [UInt8](repeating: 0x41, count: bytes))
        return data
    }

    private func controlFrame(bytes: Int) -> Data {
        var data = Data([1 /* RemoteFrame version */, RemoteFrameType.ping.rawValue, 0, 0])
        data.append(contentsOf: [UInt8](repeating: 0x42, count: bytes))
        return data
    }

    func testOutputFramesAreEvictedOnceOverBudget() {
        var queue = RemoteInboundMessageQueue(maxBufferedBytes: 4_096)
        for _ in 0 ..< 40 {
            queue.enqueue(data: outputFrame(bytes: 1_024), generation: 1)
        }
        XCTAssertLessThanOrEqual(
            queue.bufferedBytes, 4_096 + 1_024,
            "output frames must be evicted, not merely marked suppressed"
        )
        XCTAssertGreaterThan(queue.evictedOutputFrames, 0)
    }

    func testControlFramesAreNeverEvicted() {
        var queue = RemoteInboundMessageQueue(maxBufferedBytes: 4_096)
        for _ in 0 ..< 20 {
            queue.enqueue(data: controlFrame(bytes: 1_024), generation: 1)
        }
        // Control frames have no checkpoint equivalent, so they must survive
        // even when that means the budget is exceeded.
        XCTAssertEqual(queue.messages.count, 20)
        XCTAssertEqual(queue.evictedOutputFrames, 0)
    }

    func testEvictionOnlyTargetsAlreadySuppressedOutput() {
        // 1_024 payload bytes + a 4-byte header is 1_028 per frame, so three
        // frames (3_084) stay under the 4_096 budget and nothing is shed.
        var queue = RemoteInboundMessageQueue(maxBufferedBytes: 4_096)
        for _ in 0 ..< 3 {
            queue.enqueue(data: outputFrame(bytes: 1_024), generation: 1)
        }
        XCTAssertEqual(queue.evictedOutputFrames, 0)
        XCTAssertEqual(queue.messages.count, 3)

        // The frame that crosses the budget suppresses every queued output
        // frame and then sheds the oldest until the queue is back under it.
        queue.enqueue(data: outputFrame(bytes: 1_024), generation: 1)
        XCTAssertGreaterThan(queue.evictedOutputFrames, 0)
        XCTAssertLessThanOrEqual(queue.bufferedBytes, 4_096)
        // Only output was shed, and every survivor is a frame the queue is
        // still holding for a reason: an in-flight recovery, or a control event.
        // The newest output frame stays queued but suppressed -- its visual
        // application is what the checkpoint recovers.
        XCTAssertTrue(queue.messages.allSatisfy(\.isOutput))
    }

    func testShedCountsAreSnapshottedAndReset() {
        var queue = RemoteInboundMessageQueue(maxBufferedBytes: 2_048)
        for _ in 0 ..< 20 {
            queue.enqueue(data: outputFrame(bytes: 1_024), generation: 1)
        }
        let first = queue.takeShedCounts()
        XCTAssertGreaterThan(first.evictedOutput, 0)
        XCTAssertEqual(queue.takeShedCounts(), QueueShedCounts.none)
    }

    func testRemoveAllResetsEvictionCounters() {
        var queue = RemoteInboundMessageQueue(maxBufferedBytes: 2_048)
        for _ in 0 ..< 20 {
            queue.enqueue(data: outputFrame(bytes: 1_024), generation: 1)
        }
        queue.removeAll()
        XCTAssertEqual(queue.evictedOutputFrames, 0)
        XCTAssertEqual(queue.bufferedBytes, 0)
        XCTAssertEqual(queue.takeShedCounts(), QueueShedCounts.none)
    }
}
