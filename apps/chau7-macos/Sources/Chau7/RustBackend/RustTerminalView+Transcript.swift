import Foundation
import AppKit
import Chau7Core

extension RustTerminalView {
    func terminalRuntimeStateForScroll() -> TerminalRuntimeState {
        let transcriptAvailable = transcriptTextProvider?(4096) != nil
        return TerminalRuntimeState(
            alternateScreenActive: rustTerminal?.isAlternateScreenActive() ?? false,
            mouseReportingActive: isMouseReportingEnabled(),
            scrollbackRows: cachedScrollbackRows,
            displayOffset: Int(rustTerminal?.displayOffset ?? 0),
            transcriptAvailable: transcriptAvailable,
            transcriptOverlayVisible: transcriptOverlayController?.isVisible ?? false
        )
    }

    func showTranscriptOverlayAndScroll(lines: Int) {
        if transcriptOverlayController?.isVisible == true {
            transcriptOverlayController?.scroll(lines: lines, lineHeight: cellHeight)
            return
        }

        guard let text = transcriptTextProvider?(512_000) else {
            Log.traceThrottled(
                "tui-transcript-unavailable-\(viewId)",
                interval: 10.0,
                "RustTerminalView[\(viewId)]: TUI transcript requested but no captured PTY output is available"
            )
            return
        }

        if transcriptOverlayController == nil {
            let controller = TerminalTranscriptOverlayController()
            controller.attach(to: overlayContainer)
            transcriptOverlayController = controller
        }

        transcriptOverlayController?.layout(in: overlayContainer?.bounds ?? bounds)
        transcriptOverlayController?.show(text: text)
        transcriptOverlayController?.scroll(lines: lines, lineHeight: cellHeight)
    }

    func hideTranscriptOverlay() {
        transcriptOverlayController?.hide()
    }
}
