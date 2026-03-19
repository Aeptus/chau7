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
    private static let approvalCategoryID = "MCP_APPROVAL"
    private static let interactivePromptCategoryID = "INTERACTIVE_PROMPT"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
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
                application.registerForRemoteNotifications()
            }
        }
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.approvalCategoryID,
                actions: [
                    UNNotificationAction(
                        identifier: "APPROVE", title: "Allow",
                        options: [.authenticationRequired]
                    ),
                    UNNotificationAction(
                        identifier: "DENY", title: "Deny",
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
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        await MainActor.run {
            switch response.actionIdentifier {
            case "APPROVE", "DENY":
                guard let requestID = userInfo["request_id"] as? String,
                      !requestID.isEmpty else { return }
                NotificationCenter.default.post(
                    name: .approvalNotificationResponse,
                    object: nil,
                    userInfo: [
                        "request_id": requestID,
                        "approved": response.actionIdentifier == "APPROVE"
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

    enum Tab { case terminal, approvals, settings }

    private var approvalsBadgeCount: Int {
        client.pendingApprovals.count + client.pendingInteractivePrompts.count
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            TerminalView(client: client, isPairingPresented: $isPairingPresented)
                .tabItem { Label("Terminal", systemImage: "terminal") }
                .tag(Tab.terminal)

            ApprovalsView(client: client)
                .tabItem { Label("Approvals", systemImage: "lock.shield") }
                .tag(Tab.approvals)
                .badge(approvalsBadgeCount)

            SettingsView(client: client, isPairingPresented: $isPairingPresented)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .overlay {
            if showsLaunchSplash {
                LaunchSplashView(tip: launchTip)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .task {
            guard showsLaunchSplash else { return }
            try? await Task.sleep(for: .milliseconds(1400))
            withAnimation(.easeOut(duration: 0.25)) {
                showsLaunchSplash = false
            }
        }
        .onChange(of: approvalsBadgeCount) { oldCount, newCount in
            if newCount > oldCount { selectedTab = .approvals }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openApprovals)) { _ in
            selectedTab = .approvals
        }
        .sheet(isPresented: $isPairingPresented) {
            PairingSheetView(client: client)
        }
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
