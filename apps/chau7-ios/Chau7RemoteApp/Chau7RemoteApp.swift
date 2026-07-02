/// Chau7 Remote — iOS companion app for controlling macOS Chau7 sessions.
///
/// Connects to a paired Mac over an encrypted WebSocket relay, providing:
/// - Live terminal output viewing (text and experimental grid renderer)
/// - Approval/deny workflow for AI agent tool use requests
/// - Interactive prompt selection for Claude/Codex sessions
/// - Live Activities and Dynamic Island integration
/// - APNs push notifications for offline approval requests
import SwiftUI
import UserNotifications
import os

private let log = Logger(subsystem: "ch7", category: "App")
private let pushNotificationsEnabled =
    (Bundle.main.object(forInfoDictionaryKey: "Chau7RemotePushNotificationsEnabled") as? Bool) ?? false

@main
struct Chau7RemoteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    private let client = RemoteClient.shared

    var body: some Scene {
        WindowGroup {
            RemoteRootView(client: client)
                .onOpenURL { url in
                    client.handle(url: url)
                }
                .onAppear {
                    if client.pairingInfo != nil, !client.isConnected {
                        client.connect()
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    client.handleScenePhase(newPhase)
                }
        }
    }
}

// MARK: - App Delegate (Notification Handling)

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private static let approvalCategoryID = RemoteNotificationID.approvalCategory
    private static let interactivePromptCategoryID = RemoteNotificationID.interactivePromptCategory

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Permission prompt-before-context fix: fresh installs see onboarding
        // first and are asked from its completion handler; returning users
        // (onboarding done) are asked immediately as before.
        if UserDefaults.standard.bool(forKey: AppSettings.hasCompletedOnboardingKey) {
            Self.requestNotificationAuthorization()
        }
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.approvalCategoryID,
                actions: [
                    UNNotificationAction(
                        identifier: RemoteNotificationID.Action.approve, title: "Allow",
                        options: [.authenticationRequired]
                    ),
                    UNNotificationAction(
                        identifier: RemoteNotificationID.Action.deny, title: "Deny",
                        options: [.destructive]
                    )
                ],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: Self.interactivePromptCategoryID,
                actions: [],
                intentIdentifiers: [],
                options: []
            )
        ])
        return true
    }

    /// Ask for notification permission and (when the build enables it)
    /// register for remote pushes. Deferred until after onboarding on first
    /// launch so the system prompt appears with context, not cold at launch.
    static func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                log.error("Notification auth failed: \(error.localizedDescription)")
            } else if !granted {
                log.info("Notification permission denied by user")
            }
            Task { @MainActor in
                RemoteClient.shared.updateNotificationAuthorization(isGranted: granted)
            }
            guard pushNotificationsEnabled else {
                log.info("Remote push notifications disabled for this build")
                return
            }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        guard pushNotificationsEnabled else { return }
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            RemoteClient.shared.updatePushToken(token)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        guard pushNotificationsEnabled else { return }
        log.error("APNs registration failed: \(error.localizedDescription)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            RemoteClient.shared.handlePushWake(userInfo: userInfo)
            completionHandler(.newData)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        await MainActor.run {
            switch response.actionIdentifier {
            case RemoteNotificationID.Action.approve, RemoteNotificationID.Action.deny:
                guard let requestID = userInfo[RemoteNotificationID.UserInfoKey.requestID] as? String,
                      !requestID.isEmpty else { return }
                NotificationCenter.default.post(
                    name: .approvalNotificationResponse,
                    object: nil,
                    userInfo: [
                        RemoteNotificationID.UserInfoKey.requestID: requestID,
                        RemoteNotificationID.UserInfoKey.approved: response.actionIdentifier == RemoteNotificationID.Action.approve
                    ]
                )
            default:
                NotificationCenter.default.post(name: .openApprovals, object: nil)
            }
        }
    }
}

extension Notification.Name {
    static let approvalNotificationResponse = Notification.Name("ch7.approvalResponse")
    static let openApprovals = Notification.Name("ch7.openApprovals")
}

// MARK: - Root View

struct RemoteRootView: View {
    var client: RemoteClient
    @State private var selectedTab = Tab.terminal
    @State private var isPairingPresented = false
    @State private var showsLaunchSplash = true
    @State private var launchTip = Chau7LaunchTips.randomTip()
    @State private var showOnboarding = false
    @State private var bannerVisible = false
    @State private var bannerDismissTask: Task<Void, Never>?
    @State private var showsKeystrokeConsent = false

    @AppStorage(AppSettings.hasCompletedOnboardingKey) private var hasCompletedOnboarding = false
    @AppStorage(AppSettings.logKeystrokesKey) private var logKeystrokes = AppSettings.logKeystrokesDefault
    @AppStorage(AppSettings.keystrokeConsentPromptedKey)
    private var keystrokeConsentPrompted = AppSettings.keystrokeConsentPromptedDefault

    enum Tab { case terminal, approvals, settings }

    private var approvalsBadgeCount: Int {
        client.pendingApprovals.count + client.pendingInteractivePrompts.count
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            TerminalView(client: client, isPairingPresented: $isPairingPresented)
                .tabItem { Label("Terminal", systemImage: "terminal") }
                .tag(Tab.terminal)

            ApprovalsView(client: client) { tabID in
                client.switchTab(tabID)
                selectedTab = .terminal
            }
                .tabItem { Label("Approvals", systemImage: "lock.shield") }
                .tag(Tab.approvals)
                .badge(approvalsBadgeCount)

            SettingsView(client: client, isPairingPresented: $isPairingPresented)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .overlay(alignment: .top) {
            if bannerVisible && selectedTab != .approvals {
                ApprovalBanner(count: approvalsBadgeCount) {
                    goToApprovals()
                } onDismiss: {
                    dismissBanner()
                }
                .padding(.horizontal)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(2)
            }
        }
        .overlay {
            if showsLaunchSplash {
                LaunchSplashView(tip: launchTip)
                    .transition(.opacity)
                    .zIndex(3)
            }
        }
        .task {
            guard showsLaunchSplash else { return }
            try? await Task.sleep(for: .milliseconds(1400))
            withAnimation(.easeOut(duration: 0.25)) {
                showsLaunchSplash = false
            }
            if !hasCompletedOnboarding {
                showOnboarding = true
            }
            // First-run consent: keystroke capture stays off until the user
            // explicitly accepts, so a fresh install never records typed
            // secrets before the user has seen the disclosure. Defer it while
            // onboarding is showing — an alert and a fullScreenCover raised in
            // the same tick fight over presentation, which made the consent
            // alert flash and vanish at launch. When onboarding runs, the
            // prompt is raised from its completion handler instead.
            if !keystrokeConsentPrompted, hasCompletedOnboarding {
                showsKeystrokeConsent = true
            }
        }
        .alert("Capture Keystrokes for Diagnostics?", isPresented: $showsKeystrokeConsent) {
            Button("Enable") {
                logKeystrokes = true
                keystrokeConsentPrompted = true
            }
            Button("Not Now", role: .cancel) {
                logKeystrokes = false
                keystrokeConsentPrompted = true
            }
        } message: {
            Text("Chau7 can record the keys you type — including terminal input — into an on-device diagnostics log to help investigate issues. This may include sensitive text such as passwords or tokens. Nothing leaves your device unless you export it, and you can change this anytime in Settings.")
        }
        .onChange(of: approvalsBadgeCount) { oldCount, newCount in
            // Surface new approvals with a non-intrusive banner instead of yanking
            // the user away from whatever they were doing.
            if newCount > oldCount, selectedTab != .approvals {
                showBanner()
            } else if newCount == 0 {
                dismissBanner()
            }
        }
        .onChange(of: selectedTab) { _, newTab in
            if newTab == .approvals { dismissBanner() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openApprovals)) { _ in
            goToApprovals()
        }
        .sheet(isPresented: $isPairingPresented) {
            PairingSheetView(client: client)
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView { startPairing in
                hasCompletedOnboarding = true
                showOnboarding = false
                // Now that the user has seen what notifications are for,
                // ask for permission (NF-11: no cold prompt at first launch).
                AppDelegate.requestNotificationAuthorization()
                if startPairing {
                    // Pairing takes over now; the consent prompt waits for the
                    // next calm launch so it never overlaps the pairing sheet.
                    isPairingPresented = true
                } else {
                    promptForKeystrokeConsentIfNeeded()
                }
            }
        }
    }

    /// Raises the first-run keystroke-consent alert once no other modal is on
    /// screen. Called after onboarding dismisses; the short delay lets the
    /// onboarding cover finish animating away so the alert doesn't get eaten by
    /// the in-flight dismissal.
    private func promptForKeystrokeConsentIfNeeded() {
        guard !keystrokeConsentPrompted else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !keystrokeConsentPrompted else { return }
            showsKeystrokeConsent = true
        }
    }

    private func goToApprovals() {
        dismissBanner()
        selectedTab = .approvals
    }

    private func showBanner() {
        bannerDismissTask?.cancel()
        withAnimation(.spring(duration: 0.3)) { bannerVisible = true }
        bannerDismissTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            dismissBanner()
        }
    }

    private func dismissBanner() {
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        withAnimation(.easeInOut(duration: 0.2)) { bannerVisible = false }
    }
}

/// Tappable banner announcing pending approvals without forcing a tab change.
private struct ApprovalBanner: View {
    let count: Int
    let onTap: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.title3)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text(count == 1 ? "Approval waiting" : "\(count) approvals waiting")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Tap to review")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(radius: 8, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { onTap() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(count == 1 ? "1 approval waiting. Tap to review." : "\(count) approvals waiting. Tap to review.")
        .accessibilityAddTraits(.isButton)
    }
}

private enum Chau7LaunchTips {
    static let all = [
        "Tip: Chau7 can keep multiple AI coding sessions separated by tab, repo, and branch.",
        "Tip: On Mac, ⌘⇧P opens the command palette for fast actions.",
        "Tip: Chau7 tracks AI state per tab, so waiting, running, and stuck sessions stay visible.",
        "Tip: On Mac, ⌘T opens a new tab instantly.",
        "Tip: Remote approvals let you respond without opening the full terminal stream.",
        "Tip: Chau7 can detect Claude and Codex activity directly from terminal sessions.",
        "Tip: On Mac, ⌘D splits the current pane vertically.",
        "Tip: Tab dot colors help you scan state quickly: green idle, orange running, blue waiting, red stuck.",
        "Tip: Chau7 remote can surface interactive Claude and Codex prompts in Approvals.",
        "Tip: On Mac, ⌘⇧O opens a new SSH connection."
    ]

    static func randomTip() -> String {
        all.randomElement() ?? all[0]
    }
}

struct Chau7LogoImage: View {
    var size: CGFloat = 72
    var cornerRadius: CGFloat = 18
    var fallbackFontSize: CGFloat = 34

    var body: some View {
        Group {
            if UIImage(named: "Chau7Logo") != nil {
                Image("Chau7Logo")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "terminal.fill")
                    .font(.system(size: fallbackFontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white.opacity(0.08))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct LaunchSplashView: View {
    let tip: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.06, blue: 0.08),
                    Color(red: 0.08, green: 0.10, blue: 0.14)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                Chau7LogoImage()
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    }

                VStack(spacing: 6) {
                    Text("Chau7 Remote")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Connected access to your Chau7 workspace")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Today’s tip")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(Color(red: 0.56, green: 0.82, blue: 0.92))

                    Text(tip)
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 360, alignment: .leading)
                .padding(16)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                ProgressView()
                    .tint(.white.opacity(0.8))
                    .padding(.top, 6)
            }
            .padding(.horizontal, 28)
        }
    }
}
