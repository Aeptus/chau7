import Foundation
import AppKit
import Chau7Core

// MARK: - showNotification

@MainActor
struct ShowNotificationActionHandler: NotificationActionHandler {
    let supportedActionTypes: [NotificationActionType] = [.showNotification]

    func execute(payload: ActionPayload, environment: ActionEnvironment) -> NotificationActionExecutor.ExecutionReport {
        let customTitle = payload.interpolate(payload.configValue("customTitle"))
        let customBody = payload.interpolate(payload.configValue("customBody"))
        let title = customTitle.isEmpty ? payload.event.notificationTitle(toolOverride: nil) : customTitle
        let body = customBody.isEmpty ? payload.event.notificationBody : customBody
        var report = NotificationActionExecutor.ExecutionReport()
        if environment.dispatchActionNotification(title, body, payload.event) {
            report.recordSuccess(.showNotification)
        } else {
            report.recordFailure("showNotification failed to dispatch")
        }
        return report
    }
}

// MARK: - playSound

@MainActor
struct PlaySoundActionHandler: NotificationActionHandler {
    let supportedActionTypes: [NotificationActionType] = [.playSound]

    func execute(payload: ActionPayload, environment _: ActionEnvironment) -> NotificationActionExecutor.ExecutionReport {
        let soundName = payload.configValue("sound") ?? "default"
        let volume = Float(payload.configInt("volume", default: 100)) / 100.0

        DispatchQueue.main.async {
            if soundName == "default" {
                NSSound.beep()
            } else if let sound = NSSound(named: NSSound.Name(soundName)) {
                sound.volume = volume
                sound.play()
            } else if let sound = NSSound(contentsOfFile: soundName, byReference: true) {
                sound.volume = volume
                sound.play()
            } else {
                let systemSoundPath = "/System/Library/Sounds/\(soundName).aiff"
                if let sound = NSSound(contentsOfFile: systemSoundPath, byReference: true) {
                    sound.volume = volume
                    sound.play()
                } else {
                    Log.warn("Action playSound: Sound not found: \(soundName)")
                    NSSound.beep()
                }
            }
        }
        var report = NotificationActionExecutor.ExecutionReport()
        report.recordSuccess(.playSound)
        return report
    }
}

// MARK: - focusWindow

@MainActor
struct FocusWindowActionHandler: NotificationActionHandler {
    let supportedActionTypes: [NotificationActionType] = [.focusWindow]

    func execute(payload: ActionPayload, environment: ActionEnvironment) -> NotificationActionExecutor.ExecutionReport {
        let focusTab = payload.configBool("focusTab", default: true)
        var report = NotificationActionExecutor.ExecutionReport()
        NSApp.activate(ignoringOtherApps: true)
        if focusTab {
            if let tabID = payload.event.tabID {
                if environment.delegate?.focusTab(tabID: tabID) == true {
                    Log.info("Action focusWindow: Focused tab \(tabID)")
                    report.recordSuccess(.focusWindow)
                } else {
                    Log.warn("Action focusWindow: Explicit tabID not found across windows for event \(payload.event.id.uuidString)")
                    report.recordFailure("focusWindow failed for explicit tabID \(tabID.uuidString)")
                }
            } else {
                Log.warn("Action focusWindow: Missing explicit tabID for event \(payload.event.id.uuidString)")
                report.recordFailure("focusWindow missing explicit tabID")
            }
        } else {
            report.recordSuccess(.focusWindow)
        }
        return report
    }
}

// MARK: - dockBounce

@MainActor
struct DockBounceActionHandler: NotificationActionHandler {
    let supportedActionTypes: [NotificationActionType] = [.dockBounce]

    func execute(payload: ActionPayload, environment _: ActionEnvironment) -> NotificationActionExecutor.ExecutionReport {
        let critical = payload.configBool("critical", default: false)
        DispatchQueue.main.async {
            let attentionType: NSApplication.RequestUserAttentionType = critical ? .criticalRequest : .informationalRequest
            NSApp.requestUserAttention(attentionType)
            Log.info("Action dockBounce: Requested user attention (critical=\(critical))")
        }
        var report = NotificationActionExecutor.ExecutionReport()
        report.recordSuccess(.dockBounce)
        return report
    }
}

// MARK: - badgeTab

@MainActor
struct BadgeTabActionHandler: NotificationActionHandler {
    let supportedActionTypes: [NotificationActionType] = [.badgeTab]

    func execute(payload: ActionPayload, environment: ActionEnvironment) -> NotificationActionExecutor.ExecutionReport {
        let badgeText = payload.configValue("badgeText") ?? "!"
        let badgeColor = payload.configValue("badgeColor") ?? "red"
        var report = NotificationActionExecutor.ExecutionReport()
        guard let tabID = payload.event.tabID else {
            let note = "badgeTab missing explicit tabID"
            Log.warn("Action badgeTab: Missing explicit tabID for event \(payload.event.id.uuidString)")
            report.recordFailure(note)
            return report
        }
        if environment.delegate?.badgeTab(tabID: tabID, text: badgeText, color: badgeColor) == true {
            report.recordSuccess(.badgeTab)
        } else {
            let note = "badgeTab failed for explicit tabID \(tabID.uuidString)"
            Log.warn("Action badgeTab: Explicit tabID not found across windows for event \(payload.event.id.uuidString)")
            report.recordFailure(note)
        }
        return report
    }
}

// MARK: - styleTab

@MainActor
struct StyleTabActionHandler: NotificationActionHandler {
    let supportedActionTypes: [NotificationActionType] = [.styleTab]

    func execute(payload: ActionPayload, environment: ActionEnvironment) -> NotificationActionExecutor.ExecutionReport {
        environment.styleCoordinator.apply(event: payload.event, config: payload.config)
    }
}
