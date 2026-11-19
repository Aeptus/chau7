import Chau7Core
import Foundation
import UserNotifications

/// Builds, schedules, and removes local notifications for approval requests and
/// interactive prompts.
///
/// Extracted from `RemoteClient` to isolate `UserNotifications` formatting and
/// scheduling from connection/session orchestration. Callers own the decision of
/// *whether* to notify (which depends on app state, push capability, and the
/// suppression window); this type owns *how* a notification is composed and
/// delivered, keeping the content scaffolding in a single place.
@MainActor
enum RemoteNotificationScheduler {

    // MARK: - Scheduling

    static func scheduleApproval(for payload: ApprovalRequestPayload, redactDetails: Bool) {
        let flagged = trimmed(payload.flaggedCommand)
        let isProtectedRemoteAction = flagged != nil && payload.flaggedCommand != payload.command
        let content = makeContent(
            title: trimmed(payload.pushTitle) ?? NotificationContentFormatter.approvalTitle(
                toolName: payload.toolName,
                isProtectedAction: isProtectedRemoteAction
            ),
            subtitle: redactDetails ? nil : NotificationContentFormatter.locationSummary(
                tabTitle: payload.tabTitle,
                projectName: payload.projectName,
                branchName: payload.branchName,
                currentDirectory: payload.currentDirectory
            ),
            body: redactDetails
                ? "Open Chau7 to review."
                : (trimmed(payload.pushBody) ?? flagged ?? trimmed(payload.command) ?? "Open Chau7 to review."),
            threadIdentifier: payload.sessionID ?? payload.tabTitle,
            categoryIdentifier: RemoteNotificationID.approvalCategory,
            userInfo: [
                RemoteNotificationID.UserInfoKey.requestID: payload.requestID,
                RemoteNotificationID.UserInfoKey.openApprovals: true
            ]
        )
        add(content, identifier: payload.requestID)
    }

    static func scheduleInteractivePrompt(for prompt: RemoteInteractivePrompt, redactDetails: Bool) {
        let content = makeContent(
            title: NotificationContentFormatter.interactivePromptTitle(toolName: prompt.toolName),
            subtitle: redactDetails ? nil : NotificationContentFormatter.locationSummary(
                tabTitle: prompt.tabTitle,
                projectName: prompt.projectName,
                branchName: prompt.branchName,
                currentDirectory: prompt.currentDirectory
            ),
            body: redactDetails
                ? "Open Chau7 to reply."
                : (trimmed(prompt.prompt) ?? "Open Chau7 to reply."),
            threadIdentifier: "tab-\(prompt.tabID)",
            categoryIdentifier: RemoteNotificationID.interactivePromptCategory,
            userInfo: [
                RemoteNotificationID.UserInfoKey.promptID: prompt.id,
                RemoteNotificationID.UserInfoKey.tabID: prompt.tabID,
                RemoteNotificationID.UserInfoKey.openApprovals: true
            ]
        )
        add(content, identifier: interactivePromptIdentifier(prompt.id))
    }

    // MARK: - Removal

    static func removeApprovalNotifications(requestIDs: [String]) {
        guard !requestIDs.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        // Remove pending too: a not-yet-presented request must never fire
        // after its approval was resolved.
        center.removePendingNotificationRequests(withIdentifiers: requestIDs)
        center.removeDeliveredNotifications(withIdentifiers: requestIDs)
    }

    static func removeInteractivePromptNotifications(promptIDs: [String]) {
        guard !promptIDs.isEmpty else { return }
        let identifiers = promptIDs.map(interactivePromptIdentifier)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    static func interactivePromptIdentifier(_ promptID: String) -> String {
        "interactive-prompt-\(promptID)"
    }

    /// Removes any *actionable* approval/prompt notification that is no longer
    /// backed by a pending request.
    ///
    /// A notification stays on the lock screen until something removes it, and
    /// nothing removed it when the request was resolved on the Mac: no frame is
    /// sent to the phone, so `/pending` reported it gone and the removal path
    /// simply never ran. The Allow/Deny buttons on such a notification then did
    /// nothing, because the request was no longer in `pendingApprovals`.
    ///
    /// Called on launch and after every authoritative snapshot.
    static func pruneStaleActionableNotifications(
        liveRequestIDs: Set<String>,
        livePromptIDs: Set<String>
    ) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let stale = delivered.compactMap { notification -> String? in
                let identifier = notification.request.identifier
                let userInfo = notification.request.content.userInfo
                if let requestID = userInfo[RemoteNotificationID.UserInfoKey.requestID] as? String {
                    return liveRequestIDs.contains(requestID) ? nil : identifier
                }
                if let promptID = userInfo[RemoteNotificationID.UserInfoKey.promptID] as? String {
                    return livePromptIDs.contains(promptID) ? nil : identifier
                }
                return nil
            }
            guard !stale.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: stale)
        }
    }

    // MARK: - Content

    private static func makeContent(
        title: String,
        subtitle: String?,
        body: String,
        threadIdentifier: String?,
        categoryIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle = trimmed(subtitle) {
            content.subtitle = subtitle
        }
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.relevanceScore = 1
        content.categoryIdentifier = categoryIdentifier
        // Group a tab's approvals/prompts under one stack on the lock screen
        // instead of a wall of separate banners.
        if let threadIdentifier = trimmed(threadIdentifier) {
            content.threadIdentifier = threadIdentifier
        }
        content.userInfo = userInfo
        return content
    }

    private static func add(_ content: UNMutableNotificationContent, identifier: String) {
        // trigger nil = deliver immediately. The old 0.1s timer trigger left
        // a ~100ms window where a just-resolved approval could still fire,
        // because resolution only removed *delivered* notifications.
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private static func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

}
