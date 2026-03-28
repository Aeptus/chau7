import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class TabResolverTests: XCTestCase {
    private var appModel: AppModel!
    private var overlayModel: OverlayTabsModel!

    override func setUp() {
        super.setUp()
        appModel = AppModel()
        overlayModel = OverlayTabsModel(appModel: appModel, restoreState: false)
    }

    override func tearDown() {
        overlayModel = nil
        appModel = nil
        super.tearDown()
    }

    func testResolveUsesExactSessionIDEvenWhenToolLabelHasNoCandidates() {
        let sessionID = "019d25d0-d0bd-7501-99ba-1f937c17b29b"
        overlayModel.tabs[0].session?.restoreAIMetadata(provider: "codex", sessionId: sessionID)

        overlayModel.newTab()
        overlayModel.tabs[1].session?.restoreAIMetadata(
            provider: "codex",
            sessionId: "019d33c3-5f8e-7a21-809d-61b4c04fcbba"
        )

        let resolved = TabResolver.resolve(
            TabTarget(tool: "UnknownTool", sessionID: sessionID),
            in: overlayModel.tabs
        )

        XCTAssertEqual(resolved?.id, overlayModel.tabs[0].id)
    }

    func testResolveUsesSessionIDBeforeBroaderMostRecentFallback() {
        let targetSessionID = "019d1e81-b43e-7552-bd90-03baf5a80330"
        let otherSessionID = "019d33cd-6084-78c1-a0c4-8de2a6142049"

        overlayModel.tabs[0].session?.restoreAIMetadata(provider: "codex", sessionId: otherSessionID)
        overlayModel.newTab()
        overlayModel.tabs[1].session?.restoreAIMetadata(provider: "codex", sessionId: targetSessionID)

        // Make the non-target tab look more recent so a plain "most recently active"
        // fallback would choose the wrong one.
        overlayModel.tabs[0].session?.status = .running

        let resolved = TabResolver.resolve(
            TabTarget(tool: "Codex", sessionID: targetSessionID),
            in: overlayModel.tabs
        )

        XCTAssertEqual(resolved?.id, overlayModel.tabs[1].id)
    }
}
#endif
