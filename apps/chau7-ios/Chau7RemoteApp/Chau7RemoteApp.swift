import SwiftUI
import UserNotifications
import os

private let log = Logger(subsystem: "ch7", category: "App")

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
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            RemoteClient.shared.updatePushToken(token)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
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
