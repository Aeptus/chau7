import XCTest
import AppKit

#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class TerminalSystemRestoreTests: XCTestCase {
    func testSystemRestoreInputDoesNotCreateCommandBlocks() {
        let session = TerminalSessionModel(appModel: AppModel())
        let tabID = UUID()
        let terminalView = RustTerminalView(frame: .zero)

        session.ownerTabID = tabID
        session.attachRustTerminal(terminalView)
        session.bufferRowProvider = { 12 }
        CommandBlockManager.shared.clearBlocks(tabID: tabID.uuidString)

        session.sendOrQueueSystemRestoreInput(" stty -echo && cat '/tmp/chau7_restore.txt' && clear && stty echo\n")
        session.handleInputLine(" stty -echo && cat '/tmp/chau7_restore.txt' && clear && stty echo")

        terminalView.onShellIntegrationEvent?(.commandStart)
        terminalView.onShellIntegrationEvent?(.commandExecuted)
        terminalView.onShellIntegrationEvent?(.commandFinished(exitCode: 0))

        XCTAssertNil(session.pendingSystemRestoreInputLine)
        XCTAssertNil(session.pendingCommandLine)
        XCTAssertFalse(session.systemRestoreCommandInFlight)
        XCTAssertNil(session.currentCommandBlockID)
        XCTAssertTrue(CommandBlockManager.shared.blocksForTab(tabID.uuidString).isEmpty)
    }
}
#endif
