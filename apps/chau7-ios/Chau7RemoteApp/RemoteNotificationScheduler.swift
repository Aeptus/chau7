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
        let isProtectedRemoteAction = payload.flaggedCommand != payload.command
        let content = makeContent(
            title: NotificationContentFormatter.approvalTitle(
                toolName: payload.toolName,
                isProtectedAction: isProtectedRemoteAction
            ),
            subtitle: redactDetails ? nil : locationSubtitle(
                tabTitle: payload.tabTitle,
                projectName: payload.projectName,
                branchName: payload.branchName,
                currentDirectory: payload.currentDirectory
            ),
            body: redactDetails
                ? "Open Chau7 to review."
                : approvalBody(for: payload),
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
            subtitle: redactDetails ? nil : locationSubtitle(
                tabTitle: prompt.tabTitle,
                projectName: prompt.projectName,
                branchName: prompt.branchName,
                currentDirectory: prompt.currentDirectory
            ),
            body: redactDetails
                ? "Open Chau7 to reply."
                : interactivePromptBody(for: prompt),
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
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: requestIDs)
    }

    static func removeInteractivePromptNotifications(promptIDs: [String]) {
        guard !promptIDs.isEmpty else { return }
        let identifiers = promptIDs.map(interactivePromptIdentifier)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    static func interactivePromptIdentifier(_ promptID: String) -> String {
        "interactive-prompt-\(promptID)"
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
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Body formatting

    private static func approvalBody(for request: ApprovalRequestPayload) -> String {
        // Location (tab/project/dir) is now the subtitle; the body leads with the
        // command so the thing being approved is what the user reads first.
        let headline = request.flaggedCommand != request.command ? request.flaggedCommand : request.command
        let detail = trimmed(request.contextNote) ?? trimmed(request.recentCommand)
        return bodyLines([detail, headline])
    }

    private static func interactivePromptBody(for prompt: RemoteInteractivePrompt) -> String {
        let promptText = prompt.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = prompt.options.prefix(3).map(\.label).joined(separator: " / ")
        return options.isEmpty ? promptText : "\(promptText)\n\(options)"
    }

    /// One-line "where" summary shown as the notification subtitle:
    /// `tab · project (branch) · ~/dir`. The tool name already leads the title.
    /// Delegates to the shared formatter so push and local text stay identical.
    private static func locationSubtitle(
        tabTitle: String?,
        projectName: String?,
        branchName: String?,
        currentDirectory: String?
    ) -> String? {
        NotificationContentFormatter.locationSummary(
            tabTitle: tabTitle,
            projectName: projectName,
            branchName: branchName,
            currentDirectory: currentDirectory,
            homeDirectory: NSHomeDirectory()
        )
    }

    private static func bodyLines(_ values: [String?]) -> String {
        values
            .compactMap(trimmed)
            .joined(separator: "\n")
    }

    private static func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

}
