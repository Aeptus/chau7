import AppKit

// MARK: - Command Center Environment

enum CommandCenterSnippetInsertionResult: Equatable {
    case inserted
    case copiedToClipboard
}

@MainActor
struct CommandCenterEnvironment {
    var sessionSource: () -> [CommandCenterSessionSummary]
    var focusSession: (CommandCenterSessionSummary) -> Void
    var openSettings: (_ section: SettingsSection?, _ anchorID: String?) -> Void
    var insertSnippet: (SnippetEntry) -> CommandCenterSnippetInsertionResult
    var closePopover: () -> Void
    var notificationHistorySource: () -> [NotificationHistory.Entry]

    static func production(
        appDelegateProvider: @escaping () -> AppDelegate?,
        closePopover: @escaping () -> Void
    ) -> CommandCenterEnvironment {
        CommandCenterEnvironment(
            sessionSource: {
                guard let delegate = appDelegateProvider() else { return [] }
                let overlayModels = delegate.overlayHosts.map(\.model)
                if overlayModels.isEmpty, let overlayModel = delegate.overlayModel {
                    return CommandCenterSessionSummary.collectLiveSessions(in: overlayModel)
                }
                return CommandCenterSessionSummary.collectLiveSessions(
                    in: overlayModels
                )
            },
            focusSession: { session in
                guard let delegate = appDelegateProvider() else { return }
                guard let host = delegate.overlayHosts.first(where: { host in
                    host.model.tabs.contains { $0.id == session.tabID }
                }) else {
                    if let overlayModel = delegate.overlayModel,
                       focusSession(session, in: overlayModel) {
                        delegate.showOverlay()
                        return
                    }
                    Log.info("CommandCenterEnvironment: No overlay host found for tab \(session.tabID)")
                    return
                }

                _ = focusSession(session, in: host.model)
                delegate.showOverlayWindow(host, reason: "commandCenterFocus")
            },
            openSettings: { section, anchorID in
                appDelegateProvider()?.showSettings(section: section, anchorID: anchorID)
            },
            insertSnippet: { entry in
                guard let delegate = appDelegateProvider() else {
                    pasteSnippetToClipboard(entry)
                    return .copiedToClipboard
                }

                let overlayModel = delegate.activeOverlayModel
                    ?? delegate.overlayHosts.first?.model
                    ?? delegate.overlayModel
                guard let session = overlayModel?.selectedTab?.session else {
                    pasteSnippetToClipboard(entry)
                    return .copiedToClipboard
                }
                session.insertSnippet(entry)
                return .inserted
            },
            closePopover: closePopover,
            notificationHistorySource: {
                NotificationServices.current?.manager.history.recent(limit: 8) ?? []
            }
        )
    }

    @discardableResult
    static func focusSession(
        _ session: CommandCenterSessionSummary,
        in overlayModel: OverlayTabsModel
    ) -> Bool {
        guard let tab = overlayModel.tabs.first(where: { $0.id == session.tabID }) else {
            return false
        }
        guard overlayModel.focusTab(id: session.tabID) else {
            return false
        }
        tab.splitController.setFocusedPane(session.paneID)
        return true
    }

    static func testing(
        sessionSource: @escaping () -> [CommandCenterSessionSummary] = { [] },
        focusSession: @escaping (CommandCenterSessionSummary) -> Void = { _ in },
        openSettings: @escaping (_ section: SettingsSection?, _ anchorID: String?) -> Void = { _, _ in },
        insertSnippet: @escaping (SnippetEntry) -> CommandCenterSnippetInsertionResult = { _ in .inserted },
        closePopover: @escaping () -> Void = {},
        notificationHistorySource: @escaping () -> [NotificationHistory.Entry] = { [] }
    ) -> CommandCenterEnvironment {
        CommandCenterEnvironment(
            sessionSource: sessionSource,
            focusSession: focusSession,
            openSettings: openSettings,
            insertSnippet: insertSnippet,
            closePopover: closePopover,
            notificationHistorySource: notificationHistorySource
        )
    }
}

private func pasteSnippetToClipboard(_ entry: SnippetEntry) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(entry.snippet.body, forType: .string)
}
