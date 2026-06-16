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

    static func scheduleApproval(for payload: ApprovalRequestPayload) {
        let isProtectedRemoteAction = payload.flaggedCommand != payload.command
        let content = makeContent(
            title: isProtectedRemoteAction ? "Protected Remote Action" : "Command Approval",
            body: approvalBody(for: payload),
            categoryIdentifier: RemoteNotificationID.approvalCategory,
            userInfo: [
                RemoteNotificationID.UserInfoKey.requestID: payload.requestID,
                RemoteNotificationID.UserInfoKey.openApprovals: true
            ]
        )
        add(content, identifier: payload.requestID)
    }

    static func scheduleInteractivePrompt(for prompt: RemoteInteractivePrompt) {
        let content = makeContent(
            title: "Interactive Prompt",
            body: interactivePromptBody(for: prompt),
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
        body: String,
        categoryIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.relevanceScore = 1
        content.categoryIdentifier = categoryIdentifier
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
        let context = contextSummary(
            tabTitle: request.tabTitle,
            toolName: request.toolName,
            projectName: request.projectName,
            branchName: request.branchName
        )
        let headline = request.flaggedCommand != request.command ? request.flaggedCommand : request.command
        let directory = abbreviatedPath(request.currentDirectory)
        let note = trimmed(request.contextNote)
        let recentCommand = trimmed(request.recentCommand)
        let detail = note ?? recentCommand
        return bodyLines([context, directory, detail, headline])
    }

    private static func interactivePromptBody(for prompt: RemoteInteractivePrompt) -> String {
        let context = contextSummary(
            tabTitle: prompt.tabTitle,
            toolName: prompt.toolName,
            projectName: prompt.projectName,
            branchName: prompt.branchName
        )
        let directory = abbreviatedPath(prompt.currentDirectory)
        let promptText = prompt.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = prompt.options.prefix(3).map(\.label).joined(separator: " / ")
        let detail = options.isEmpty ? promptText : "\(promptText)\n\(options)"
        return bodyLines([context, directory, detail])
    }

    private static func contextSummary(
        tabTitle: String?,
        toolName: String?,
        projectName: String?,
        branchName: String?
    ) -> String {
        [toolName, tabTitle, projectName, branchName]
            .compactMap(trimmed)
            .joined(separator: " · ")
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

    private static func abbreviatedPath(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let home = NSHomeDirectory()
        if trimmed == home {
            return "~"
        }
        if trimmed.hasPrefix(home + "/") {
            return "~" + String(trimmed.dropFirst(home.count))
        }
        return trimmed
    }
}
