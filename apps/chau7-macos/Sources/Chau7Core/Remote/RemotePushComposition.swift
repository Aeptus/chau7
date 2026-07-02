import Foundation

/// Push-text composition for wire payloads: the Mac attaches pre-formatted
/// text (from the shared `NotificationContentFormatter`) so the Go agent
/// relays instead of formatting, and iOS local notifications render the
/// exact same words as the push.
public extension ApprovalRequestPayload {
    func withComposedPushText() -> ApprovalRequestPayload {
        let isProtected = flaggedCommand != command
        let headline = isProtected ? flaggedCommand : command
        return ApprovalRequestPayload(
            requestID: requestID,
            command: command,
            flaggedCommand: flaggedCommand,
            timestamp: timestamp,
            tabTitle: tabTitle,
            toolName: toolName,
            projectName: projectName,
            branchName: branchName,
            currentDirectory: currentDirectory,
            recentCommand: recentCommand,
            contextNote: contextNote,
            sessionID: sessionID,
            pushTitle: NotificationContentFormatter.approvalTitle(
                toolName: toolName,
                isProtectedAction: isProtected
            ),
            pushSubtitle: NotificationContentFormatter.locationSummary(
                tabTitle: tabTitle,
                projectName: projectName,
                branchName: branchName,
                currentDirectory: currentDirectory
            ),
            pushBody: headline
        )
    }
}

public extension RemoteInteractivePrompt {
    func withComposedPushText() -> RemoteInteractivePrompt {
        RemoteInteractivePrompt(
            id: id,
            tabID: tabID,
            tabTitle: tabTitle,
            toolName: toolName,
            projectName: projectName,
            branchName: branchName,
            currentDirectory: currentDirectory,
            prompt: prompt,
            detail: detail,
            options: options,
            detectedAt: detectedAt,
            pushTitle: NotificationContentFormatter.interactivePromptTitle(toolName: toolName),
            pushSubtitle: NotificationContentFormatter.locationSummary(
                tabTitle: tabTitle,
                projectName: projectName,
                branchName: branchName,
                currentDirectory: currentDirectory
            )
        )
    }
}
