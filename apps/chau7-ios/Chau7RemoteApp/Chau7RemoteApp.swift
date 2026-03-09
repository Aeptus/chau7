import SwiftUI
import UserNotifications
import os

private let log = Logger(subsystem: "ch7", category: "App")

@main
struct Chau7RemoteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            RemoteRootView()
        }
    }
}

// MARK: - App Delegate (Notification Handling)

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

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
        }
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: "MCP_APPROVAL",
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
            )
        ])
        return true
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
        guard let requestID = userInfo["request_id"] as? String,
              !requestID.isEmpty else { return }
        let approved = response.actionIdentifier == "APPROVE"
        await MainActor.run {
            NotificationCenter.default.post(
                name: .approvalNotificationResponse, object: nil,
                userInfo: ["request_id": requestID, "approved": approved]
            )
        }
    }
}

extension Notification.Name {
    static let approvalNotificationResponse = Notification.Name("ch7.approvalResponse")
}

// MARK: - Root View

struct RemoteRootView: View {
    @State private var client = RemoteClient()
    @State private var selectedTab = Tab.terminal
    @State private var isPairingPresented = false

    enum Tab { case terminal, approvals, settings }

    var body: some View {
        TabView(selection: $selectedTab) {
            TerminalView(client: client, isPairingPresented: $isPairingPresented)
                .tabItem { Label("Terminal", systemImage: "terminal") }
                .tag(Tab.terminal)

            ApprovalsView(client: client)
                .tabItem { Label("Approvals", systemImage: "lock.shield") }
                .tag(Tab.approvals)
                .badge(client.pendingApprovals.count)

            SettingsView(client: client, isPairingPresented: $isPairingPresented)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .onChange(of: client.pendingApprovals.count) { oldCount, newCount in
            if newCount > oldCount { selectedTab = .approvals }
        }
        .sheet(isPresented: $isPairingPresented) {
            PairingSheetView(client: client)
        }
    }
}
