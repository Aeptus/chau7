import SwiftUI
import UserNotifications

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
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: "MCP_APPROVAL",
                actions: [
                    UNNotificationAction(identifier: "APPROVE", title: "Allow", options: [.authenticationRequired]),
                    UNNotificationAction(identifier: "DENY", title: "Deny", options: [.destructive])
                ],
                intentIdentifiers: [],
                options: []
            )
        ])
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let requestID = response.notification.request.content.userInfo["request_id"] as? String,
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
    @StateObject private var client = RemoteClient()
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

            RemoteSettingsView(client: client, isPairingPresented: $isPairingPresented)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .onChange(of: client.pendingApprovals.count) { old, new in
            if new > old { selectedTab = .approvals }
        }
        .sheet(isPresented: $isPairingPresented) {
            PairingSheetView(client: client)
        }
    }
}
