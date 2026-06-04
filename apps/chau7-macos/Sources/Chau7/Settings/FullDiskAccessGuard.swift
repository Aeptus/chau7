import AppKit
import Foundation
import Chau7Core

/// App-wide coordinator that detects loss of macOS **Full Disk Access** and
/// turns it into an immediate, actionable message — instead of letting it
/// surface as a cryptic "Operation not permitted" from a child CLI
/// (codex/claude/shell) and sending the user debugging the wrong layer.
///
/// Two entry points feed the same throttled alert:
///   - **proactive**: `FullDiskAccessProbe` re-run at launch and whenever the
///     app becomes active (the moment a cold TCC re-evaluation realistically
///     happens after a signature change);
///   - **reactive**: `reportChildDenial(protectedRoot:)`, called by the
///     terminal layer when a command fails with EPERM in a protected folder.
///
/// Mutable state and all UI are confined to the main thread; the filesystem
/// probe runs on a utility queue. Disable via the
/// `com.chau7.fullDiskAccessGuardEnabled` user-default (defaults to enabled).
final class FullDiskAccessGuard {
    static let shared = FullDiskAccessGuard()

    private(set) var status: FullDiskAccessProbe.Status = .indeterminate

    private var lastAlertAt: Date?
    private var started = false
    private var becameActiveObserver: NSObjectProtocol?
    private let alertMinInterval: TimeInterval = 300
    private let probeQueue = DispatchQueue(label: "com.chau7.fda-probe", qos: .utility)

    private static let enabledDefaultsKey = "com.chau7.fullDiskAccessGuardEnabled"

    private init() {}

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool ?? true
    }

    /// Begin monitoring. Call once on the main thread at startup; idempotent.
    func start() {
        guard isEnabled, !started else { return }
        started = true
        becameActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recheck(reason: "didBecomeActive")
        }
        recheck(reason: "startup")
    }

    /// Re-probe FDA off the main thread, then reconcile + alert on a fresh loss.
    func recheck(reason: String) {
        guard isEnabled else { return }
        probeQueue.async { [weak self] in
            let result = FullDiskAccessProbe.probe()
            DispatchQueue.main.async { self?.apply(result, reason: reason) }
        }
    }

    /// Called by the terminal layer when a child command failed with EPERM in a
    /// protected folder. Confirms with a probe first, so a non-FDA EPERM (where
    /// the probe still reports access) is suppressed rather than mis-attributed.
    func reportChildDenial(protectedRoot: String) {
        guard isEnabled else { return }
        probeQueue.async { [weak self] in
            let result = FullDiskAccessProbe.probe()
            DispatchQueue.main.async {
                guard let self else { return }
                if result != .indeterminate { self.status = result }
                guard result != .granted else {
                    Log.info("FullDiskAccessGuard: child EPERM in \(protectedRoot) but probe reports access; not attributing to FDA")
                    return
                }
                Log.warn("FullDiskAccessGuard: child denied in protected root \(protectedRoot) — likely Full Disk Access loss")
                self.presentAlertIfNeeded(detail: self.childDeniedDetail(root: protectedRoot))
            }
        }
    }

    // MARK: - Main-thread internals

    private func apply(_ newStatus: FullDiskAccessProbe.Status, reason: String) {
        let previous = status
        status = newStatus
        switch newStatus {
        case .denied:
            Log.warn("FullDiskAccessGuard: Full Disk Access denied (reason=\(reason))")
            presentAlertIfNeeded(detail: deniedDetail)
        case .granted:
            if previous == .denied { Log.info("FullDiskAccessGuard: Full Disk Access restored") }
        case .indeterminate:
            break
        }
    }

    /// Pure throttle decision (unit-tested).
    static func shouldAlert(now: Date, lastAlertAt: Date?, minInterval: TimeInterval) -> Bool {
        guard let last = lastAlertAt else { return true }
        return now.timeIntervalSince(last) >= minInterval
    }

    private func presentAlertIfNeeded(detail: String) {
        let now = Date()
        guard Self.shouldAlert(now: now, lastAlertAt: lastAlertAt, minInterval: alertMinInterval) else { return }
        lastAlertAt = now

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("permissions.fda.title", "Chau7 has lost Full Disk Access")
        alert.informativeText = detail
        alert.addButton(withTitle: L("permissions.fda.openSettings", "Open Full Disk Access…"))
        alert.addButton(withTitle: L("permissions.fda.later", "Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            Self.openFullDiskAccessSettings()
        }
    }

    private var deniedDetail: String {
        L("permissions.fda.detail",
          "Terminal commands and AI agents (codex, claude) running in protected folders like ~/Downloads will fail with \"Operation not permitted\". This usually follows a rebuild or re-sign of Chau7. Re-enable Full Disk Access for Chau7 to fix it.")
    }

    private func childDeniedDetail(root: String) -> String {
        L("permissions.fda.childDetail",
          "A command just failed with \"Operation not permitted\" in \(root). That is Chau7's Full Disk Access, not a bug in the CLI. Re-enable Full Disk Access for Chau7 to fix it.")
    }

    /// Opens System Settings directly to the Full Disk Access pane.
    static func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}
