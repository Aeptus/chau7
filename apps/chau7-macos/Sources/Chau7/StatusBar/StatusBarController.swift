import AppKit
import SwiftUI

/// Controls the menu bar status item and popover panel.
/// Uses NSStatusItem + NSPopover for proper multi-monitor support instead of SwiftUI's
/// MenuBarExtra which has positioning issues on multi-monitor setups.
///
/// - Note: This is a singleton. Call `setup(model:)` from AppDelegate.applicationDidFinishLaunching
///   and `cleanup()` from applicationWillTerminate.
@MainActor
final class StatusBarController: NSObject {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private weak var model: AppModel?
    private var lastRenderedPresentation: StatusBarIconPresentation?

    /// Panel view model — lives as long as the controller so popover doesn't recreate state.
    private var panelViewModel: CommandCenterViewModel?

    override private init() {
        super.init()
    }

    /// Initialize the status bar with the app model.
    /// - Parameter model: The app model to observe and display.
    /// - Note: Must be called from main thread.
    func setup(model: AppModel, environment: CommandCenterEnvironment? = nil) {
        self.model = model
        let environment = environment ?? CommandCenterEnvironment.production(
            appDelegateProvider: { AppDelegate.shared },
            closePopover: { [weak self] in self?.closePopover() }
        )
        self.panelViewModel = CommandCenterViewModel(model: model, environment: environment)

        // Create status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            applyIconPresentation(StatusBarIconPresenter.presentation(
                isMonitoring: model.isMonitoring,
                badgeCounts: .empty
            ))
        }

        // Create popover with persistent content (fix #6: no recreation on every open)
        guard let panelViewModel else { return }
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 400, height: 520)
        popover?.behavior = .applicationDefined
        popover?.animates = true
        popover?.contentViewController = NSHostingController(
            rootView: StatusBarPanelView(viewModel: panelViewModel).localized()
        )

        // Monitor for clicks outside to close popover (global events = clicks in other apps)
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }

        // Local monitor for clicks within the app but outside the popover
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self,
                  let popover = popover,
                  popover.isShown,
                  let popoverWindow = popover.contentViewController?.view.window else {
                return event
            }

            if event.window != popoverWindow {
                if let button = statusItem?.button,
                   let buttonWindow = button.window,
                   event.window == buttonWindow {
                    return event
                }
                closePopover()
            }
            return event
        }

        // Observe monitoring state changes to update icon
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateIcon),
            name: .monitoringStateChanged,
            object: nil
        )

        // Reactive badge updates from session state changes via didSet callback
        panelViewModel.onBadgeCountsChange = { [weak self] counts in
            DispatchQueue.main.async {
                self?.updateBadgeAndIcon(counts: counts)
            }
        }

        model.onMonitoringChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.updateIcon()
            }
        }
    }

    /// Cleanup all resources. Call from applicationWillTerminate.
    func cleanup() {
        NotificationCenter.default.removeObserver(self)
        panelViewModel?.onBadgeCountsChange = nil
        model?.onMonitoringChanged = nil

        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }

        statusItem = nil
        popover = nil
        panelViewModel = nil
        lastRenderedPresentation = nil
    }

    /// Flash the status bar icon to draw attention (used by menuBarAlert action).
    func flashAlert(duration: Int, animate: Bool) {
        guard let button = statusItem?.button else { return }
        let originalImage = button.image
        let alertImage = NSImage(
            systemSymbolName: "bell.badge.fill",
            accessibilityDescription: L("statusBar.alert", "Alert")
        )

        button.image = alertImage

        if animate {
            // Pulse animation: alternate icon rapidly before restoring
            let pulseCount = min(duration * 2, 10)
            for i in 0 ..< pulseCount {
                let delay = Double(i) * 0.5
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    button.image = i.isMultiple(of: 2) ? alertImage : originalImage
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(duration)) {
                button.image = originalImage
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(duration)) {
                button.image = originalImage
            }
        }
        Log.info("StatusBarController: Menu bar alert for \(duration)s (animate=\(animate))")
    }

    /// Update the status bar icon based on monitoring state.
    @objc func updateIcon() {
        updateBadgeAndIcon(counts: panelViewModel?.badgeCounts ?? .empty)
    }

    /// Update icon and badge count based on session states.
    /// Three states: bell (off), bell.badge.fill (on, clear), bell.badge.fill + count (attention needed).
    private func updateBadgeAndIcon(counts: CommandCenterBadgeCounts) {
        let presentation = StatusBarIconPresenter.presentation(
            isMonitoring: model?.isMonitoring ?? false,
            badgeCounts: counts
        )
        applyIconPresentation(presentation)
    }

    private func applyIconPresentation(_ presentation: StatusBarIconPresentation) {
        guard let button = statusItem?.button else { return }
        guard presentation != lastRenderedPresentation else {
            return
        }

        button.image = NSImage(
            systemSymbolName: presentation.symbolName,
            accessibilityDescription: presentation.accessibilityLabel
        )
        button.title = presentation.title
        button.toolTip = presentation.tooltip
        button.setAccessibilityLabel(presentation.accessibilityLabel)
        lastRenderedPresentation = presentation
    }

    @objc private func togglePopover(_ sender: Any?) {
        if let popover, popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button,
              let popover else { return }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        if let popoverWindow = popover.contentViewController?.view.window {
            popoverWindow.level = .popUpMenu
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
    }
}
