import XCTest
@testable import Chau7Core

final class RuntimeLaunchReadinessTests: XCTestCase {
    func testNotReadyWhileShellIsStillLoading() {
        XCTAssertFalse(
            RuntimeLaunchReadiness.isReady(
                snapshot: snapshot(shellLoading: true, isAtPrompt: false, effectiveStatus: "running", rawStatus: "running", aiProvider: "codex"),
                backendName: "codex"
            )
        )
    }

    func testCodeReviewCanBecomeReadyBeforeShellLoadingClears() {
        XCTAssertTrue(
            RuntimeLaunchReadiness.isReady(
                snapshot: snapshot(
                    shellLoading: true,
                    isAtPrompt: false,
                    effectiveStatus: "running",
                    rawStatus: "running",
                    aiProvider: "codex",
                    processNames: ["codex"]
                ),
                backendName: "codex",
                purpose: "code_review"
            )
        )
    }

    func testReadyWhenInteractivePromptIsAvailable() {
        XCTAssertTrue(
            RuntimeLaunchReadiness.isReady(
                snapshot: snapshot(
                    shellLoading: false,
                    isAtPrompt: true,
                    effectiveStatus: "idle",
                    rawStatus: "idle",
                    aiProvider: "codex"
                ),
                backendName: "codex"
            )
        )
    }

    func testNotReadyAtPromptWithoutMatchingBackendSignal() {
        XCTAssertFalse(
            RuntimeLaunchReadiness.isReady(
                snapshot: snapshot(
                    shellLoading: false,
                    isAtPrompt: true,
                    effectiveStatus: "idle",
                    rawStatus: "idle",
                    aiProvider: "claude"
                ),
                backendName: "codex"
            )
        )
    }

    func testNotReadyWhenStatusDoesNotLookRunning() {
        XCTAssertFalse(
            RuntimeLaunchReadiness.isReady(
                snapshot: snapshot(
                    shellLoading: false,
                    isAtPrompt: false,
                    effectiveStatus: "paused",
                    rawStatus: "paused",
                    aiProvider: "codex"
                ),
                backendName: "codex"
            )
        )
    }

    func testReadyWhenProviderSignalMatchesBackend() {
        XCTAssertTrue(
            RuntimeLaunchReadiness.isReady(
                snapshot: snapshot(shellLoading: false, isAtPrompt: false, effectiveStatus: "running", rawStatus: "running", aiProvider: "codex"),
                backendName: "codex"
            )
        )
    }

    func testReadyWhenProcessNameMatchesBackend() {
        XCTAssertTrue(
            RuntimeLaunchReadiness.isReady(
                snapshot: snapshot(
                    shellLoading: false,
                    isAtPrompt: false,
                    effectiveStatus: "waitingForInput",
                    rawStatus: "waitingForInput",
                    aiProvider: nil,
                    processNames: ["node", "codex"]
                ),
                backendName: "codex"
            )
        )
    }

    func testNotReadyWhenSignalsBelongToAnotherBackend() {
        XCTAssertFalse(
            RuntimeLaunchReadiness.isReady(
                snapshot: snapshot(
                    shellLoading: false,
                    isAtPrompt: false,
                    effectiveStatus: "running",
                    rawStatus: "running",
                    aiProvider: "claude",
                    processNames: ["claude"]
                ),
                backendName: "codex"
            )
        )
    }

    private func snapshot(
        shellLoading: Bool,
        isAtPrompt: Bool,
        effectiveStatus: String,
        rawStatus: String,
        aiProvider: String?,
        processNames: [String] = []
    ) -> RuntimeLaunchReadinessSnapshot {
        RuntimeLaunchReadinessSnapshot(
            shellLoading: shellLoading,
            isAtPrompt: isAtPrompt,
            effectiveStatus: effectiveStatus,
            rawStatus: rawStatus,
            activeApp: nil,
            rawActiveApp: nil,
            aiProvider: aiProvider,
            activeRunProvider: nil,
            processNames: processNames
        )
    }
}
