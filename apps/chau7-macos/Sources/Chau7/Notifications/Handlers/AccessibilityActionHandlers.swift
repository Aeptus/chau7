import Foundation
import AppKit
import AVFoundation
import Chau7Core

// MARK: - voiceAnnounce

/// Stateful: holds the latest AVSpeechSynthesizer instance so it stays
/// alive until speech completes. Speaking a new utterance replaces the
/// reference (the previous utterance, if still active, is allowed to
/// continue speaking via its own retain inside AVFoundation).
@MainActor
final class VoiceAnnounceActionHandler: NotificationActionHandler {
    let supportedActionTypes: [NotificationActionType] = [.voiceAnnounce]

    /// Held to prevent the speech synthesizer from being deallocated
    /// before speech completes.
    private var synthesizer: AVSpeechSynthesizer?

    func execute(payload: ActionPayload, environment _: ActionEnvironment) -> NotificationActionExecutor.ExecutionReport {
        let text = payload.interpolate(payload.configValue("text"))
        let voice = payload.configValue("voice") ?? "default"
        let rate = payload.configInt("rate", default: 175)

        DispatchQueue.main.async { [weak self] in
            let synthesizer = AVSpeechSynthesizer()
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = Float(rate) / 350.0

            if voice != "default" {
                utterance.voice = AVSpeechSynthesisVoice(identifier: "com.apple.speech.synthesis.voice.\(voice.lowercased())")
            }

            self?.synthesizer = synthesizer
            synthesizer.speak(utterance)

            Log.info("Action voiceAnnounce: Speaking '\(text.prefix(50))...'")
        }
        var report = NotificationActionExecutor.ExecutionReport()
        report.recordSuccess(.voiceAnnounce)
        return report
    }
}

// MARK: - flashScreen

/// Stateful: holds the latest fullscreen flash window so it stays alive
/// during the animation. A new flash dismisses the previous window
/// first.
@MainActor
final class FlashScreenActionHandler: NotificationActionHandler {
    let supportedActionTypes: [NotificationActionType] = [.flashScreen]

    /// Held to prevent the flash window from being deallocated during
    /// animation.
    private var flashWindow: NSWindow?

    func execute(payload: ActionPayload, environment _: ActionEnvironment) -> NotificationActionExecutor.ExecutionReport {
        let colorName = payload.configValue("color") ?? "white"
        let duration = payload.configInt("duration", default: 200)
        let count = payload.configInt("count", default: 2)

        let color: NSColor
        switch colorName {
        case "yellow": color = .yellow
        case "red": color = .red
        case "green": color = .green
        case "blue": color = .blue
        default: color = .white
        }

        Task { @MainActor [weak self] in
            guard let screen = NSScreen.main else { return }

            self?.flashWindow?.orderOut(nil)

            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.backgroundColor = color
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            self?.flashWindow = window
            Log.info("Action flashScreen: Flashing \(count) times")

            for _ in 0 ..< count {
                window.alphaValue = 0.5
                window.orderFront(nil)
                try? await Task.sleep(for: .milliseconds(duration))
                window.alphaValue = 0
                try? await Task.sleep(for: .milliseconds(100))
            }

            self?.flashWindow?.orderOut(nil)
            self?.flashWindow = nil
        }
        var report = NotificationActionExecutor.ExecutionReport()
        report.recordSuccess(.flashScreen)
        return report
    }
}

// MARK: - menuBarAlert

@MainActor
struct MenuBarAlertActionHandler: NotificationActionHandler {
    let supportedActionTypes: [NotificationActionType] = [.menuBarAlert]

    func execute(payload: ActionPayload, environment: ActionEnvironment) -> NotificationActionExecutor.ExecutionReport {
        let duration = payload.configInt("duration", default: 5)
        let animate = payload.configBool("animate", default: true)

        let delegate = environment.delegate
        DispatchQueue.main.async {
            delegate?.flashMenuBar(duration: duration, animate: animate)
            Log.info("Action menuBarAlert: Alert for \(duration) seconds")
        }
        var report = NotificationActionExecutor.ExecutionReport()
        report.recordSuccess(.menuBarAlert)
        return report
    }
}
