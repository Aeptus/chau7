import Foundation

public struct TerminalRuntimeState: Equatable, Sendable {
    public let alternateScreenActive: Bool
    public let mouseReportingActive: Bool
    public let scrollbackRows: Int
    public let displayOffset: Int
    public let transcriptAvailable: Bool
    public let transcriptOverlayVisible: Bool

    public init(
        alternateScreenActive: Bool,
        mouseReportingActive: Bool,
        scrollbackRows: Int,
        displayOffset: Int,
        transcriptAvailable: Bool,
        transcriptOverlayVisible: Bool = false
    ) {
        self.alternateScreenActive = alternateScreenActive
        self.mouseReportingActive = mouseReportingActive
        self.scrollbackRows = max(0, scrollbackRows)
        self.displayOffset = max(0, displayOffset)
        self.transcriptAvailable = transcriptAvailable
        self.transcriptOverlayVisible = transcriptOverlayVisible
    }

    public var canUseNormalScrollback: Bool {
        scrollbackRows > 0
    }

    public var needsTranscriptForHistory: Bool {
        alternateScreenActive && !canUseNormalScrollback && transcriptAvailable
    }
}

public enum TerminalScrollAction: Equatable, Sendable {
    case ignore
    case forwardToApplication
    case scrollback(lines: Int)
    case transcript(lines: Int)
}

public enum TerminalScrollPolicy {
    public static let minimumUsefulDelta = 0.5

    public static func action(
        deltaY: Double,
        state: TerminalRuntimeState
    ) -> TerminalScrollAction {
        guard abs(deltaY) > minimumUsefulDelta else { return .ignore }

        let lines = max(1, Int(abs(deltaY) / 3.0))

        if state.transcriptOverlayVisible {
            return .transcript(lines: deltaY > 0 ? lines : -lines)
        }

        if state.mouseReportingActive {
            return .forwardToApplication
        }

        if state.needsTranscriptForHistory, deltaY > 0 {
            return .transcript(lines: lines)
        }

        return .scrollback(lines: deltaY > 0 ? lines : -lines)
    }
}
