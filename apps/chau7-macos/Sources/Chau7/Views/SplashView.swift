import AppKit
import SwiftUI

// MARK: - Loading Splash (shown on every launch)

struct SplashView: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.95)

            VStack(spacing: 20) {
                Image(nsImage: AppIcon.load())
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 128, height: 128)
                    .cornerRadius(24)
                    .shadow(color: .white.opacity(0.1), radius: 20)

                Text(L("Chau7", "Chau7"))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)

                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(0.8)
            }
        }
        .frame(width: 300, height: 280)
    }
}

// MARK: - Welcome Screen (first launch + Help menu)

struct WelcomeView: View {
    let onGetStarted: () -> Void

    private var tips: [(icon: String, title: String, body: String)] {
        [
            (
                "rectangle.stack.fill",
                L("splash.tip.tabs.title", "Tabs are context-full"),
                L("splash.tip.tabs.body", "Each tab tracks its AI session, repo, and command history. Name them (double-click) and group by repo (right-click) to manage parallel agents at a glance.")
            ),
            (
                "bell.badge.fill",
                L("splash.tip.panel.title", "Side panel is your companion"),
                L("splash.tip.panel.body", "The menu bar icon opens a command center with live AI activity, notifications, and quick actions. Keep it handy when running multiple agents.")
            ),
            (
                "keyboard.fill",
                L("splash.tip.shortcuts.title", "Shortcuts, shortcuts, shortcuts"),
                L("splash.tip.shortcuts.body", "Cmd+T new tab  ·  Cmd+W close  ·  Cmd+Shift+] / [ switch\nCmd+Shift+D data explorer  ·  Cmd+K command palette")
            )
        ]
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.95)

            VStack(spacing: 24) {
                // Header
                VStack(spacing: 12) {
                    Image(nsImage: AppIcon.load())
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)
                        .cornerRadius(14)
                        .shadow(color: .white.opacity(0.1), radius: 12)

                    Text(L("splash.welcome", "Welcome to Chau7"))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white)
                }

                // Tips
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(tips.indices, id: \.self) { i in
                        let tip = tips[i]
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: tip.icon)
                                .font(.system(size: 18))
                                .foregroundStyle(.white.opacity(0.7))
                                .frame(width: 24, alignment: .center)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(tip.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)

                                Text(tip.body)
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.6))
                                    .lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)

                // Get Started button
                Button(action: onGetStarted) {
                    Text(L("splash.getStarted", "Get Started"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(width: 140, height: 36)
                        .background(Color.white)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(.vertical, 28)
        }
        .frame(width: 440, height: 460)
    }
}

// MARK: - Window Controller

final class SplashWindowController {
    private var window: NSWindow?
    private(set) var onWelcomeDismiss: (() -> Void)?
    private var appReady = false
    private var userDismissed = false

    private static let hasShownWelcomeKey = "app.hasShownWelcome"

    static var hasShownWelcome: Bool {
        get { UserDefaults.standard.bool(forKey: hasShownWelcomeKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasShownWelcomeKey) }
    }

    /// Show the loading spinner splash (subsequent launches).
    func show() {
        showWindow(content: SplashView(), width: 300, height: 280)
    }

    /// Show the welcome onboarding splash (first launch or Help menu).
    /// The `onDismiss` callback fires when BOTH the user clicks "Get Started"
    /// AND the app has finished loading (whichever comes last).
    func showWelcome(onDismiss: @escaping () -> Void) {
        onWelcomeDismiss = onDismiss
        appReady = false
        userDismissed = false

        let welcomeView = WelcomeView { [weak self] in
            self?.userDismissed = true
            self?.tryDismissWelcome()
        }
        showWindow(content: welcomeView, width: 440, height: 460)
    }

    /// Called by AppDelegate when the app is ready (terminals loaded).
    func markAppReady() {
        appReady = true
        tryDismissWelcome()
    }

    private func tryDismissWelcome() {
        guard appReady, userDismissed, let callback = onWelcomeDismiss else { return }
        onWelcomeDismiss = nil
        dismiss(completion: callback)
    }

    func dismiss(completion: @escaping () -> Void) {
        guard let window else {
            completion()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            window.orderOut(nil)
            self?.window = nil
            completion()
        }
    }

    private func showWindow(content: some View, width: CGFloat, height: CGFloat) {
        let hostingView = NSHostingView(rootView: content.localized())

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = hostingView
        window.orderFront(nil)

        self.window = window
    }

    var windowAppearance: NSAppearance? {
        get { window?.appearance }
        set { window?.appearance = newValue }
    }
}
