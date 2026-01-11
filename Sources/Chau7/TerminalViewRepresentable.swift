import SwiftUI
import AppKit
import SwiftTerm

struct TerminalViewRepresentable: NSViewRepresentable {
    @ObservedObject var model: TerminalSessionModel
    var isSuspended: Bool

    func makeNSView(context: Context) -> Chau7TerminalView {
        let view = Chau7TerminalView(frame: .zero)
        view.processDelegate = model
        view.font = NSFont.monospacedSystemFont(ofSize: model.fontSize, weight: .regular)
        view.configureNativeColors()
        view.notifyUpdateChanges = !isSuspended
        view.isHidden = isSuspended
        view.allowMouseReporting = false
        view.onInput = { [weak model] text in
            model?.handleInput(text)
        }
        view.onOutput = { [weak model] data in
            model?.handleOutput(data)
        }
        view.onBufferChanged = { [weak model] in
            model?.scheduleSearchRefresh()
            model?.highlightView?.needsDisplay = true
        }

        let cursorLineView = TerminalCursorLineView(frame: .zero)
        cursorLineView.autoresizingMask = [.width, .height]
        view.addSubview(cursorLineView)
        view.attachCursorLineView(cursorLineView)

        let highlightView = TerminalHighlightView(frame: .zero)
        highlightView.terminalView = view
        highlightView.session = model
        highlightView.autoresizingMask = [.width, .height]
        highlightView.wantsLayer = true
        highlightView.layer?.backgroundColor = NSColor.clear.cgColor
        view.addSubview(highlightView)
        highlightView.frame = view.bounds
        model.attachHighlightView(highlightView)

        let shell = model.defaultShell()
        let execName = "-" + URL(fileURLWithPath: shell).lastPathComponent
        let env = model.buildEnvironment()
        // Note: Do NOT change process-wide CWD here - it affects all tabs.
        // The shell process starts with its own CWD from the environment.
        view.startProcess(executable: shell, args: [], environment: env, execName: execName)

        model.attachTerminal(view)
        model.applyFontSize()

        // Apply shell integration after shell is ready.
        // We detect readiness by watching for the first output (prompt).
        model.scheduleShellIntegration(for: view)
        return view
    }

    func updateNSView(_ nsView: Chau7TerminalView, context: Context) {
        if nsView.isHidden != isSuspended {
            nsView.isHidden = isSuspended
            if !isSuspended {
                nsView.needsDisplay = true
            }
        }
        if nsView.notifyUpdateChanges == isSuspended {
            nsView.notifyUpdateChanges = !isSuspended
        }
        let isCodex = model.activeAppName == "Codex"
        nsView.setCursorLineHighlightEnabled(isCodex)
        nsView.configureCursorLineHighlight(contextLines: isCodex, inputHistory: isCodex)

        if nsView.font.pointSize != model.fontSize {
            nsView.font = NSFont.monospacedSystemFont(ofSize: model.fontSize, weight: .regular)
        }
    }
}
