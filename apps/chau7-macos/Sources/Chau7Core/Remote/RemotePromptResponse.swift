import Foundation

/// Direct keyboard input names the pane whose terminal stream the client is
/// displaying. Exactly one of text/keys is valid (checked on the receiver).
public struct RemotePaneInput: Codable, Equatable, Sendable {
    public let paneID: UUID
    public let text: String?
    public let keys: [RemoteKeyInputPayload.Key]?

    public init(paneID: UUID, text: String? = nil, keys: [RemoteKeyInputPayload.Key]? = nil) {
        self.paneID = paneID
        self.text = text
        self.keys = keys
    }

    enum CodingKeys: String, CodingKey { case paneID = "pane_id", text, keys }
}

/// Semantic prompt actions, bound to both the advertised prompt and its pane.
/// The Mac derives keystrokes from its current prompt, not client-supplied text
/// pretending to be an option. Unknown/stale identities fail closed.
public struct RemotePromptResponse: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case select, toggle, submit, custom }
    public let promptID: String
    public let paneID: UUID
    public let action: Action
    public let optionID: String?
    public let customText: String?

    public init(promptID: String, paneID: UUID, action: Action, optionID: String? = nil, customText: String? = nil) {
        self.promptID = promptID
        self.paneID = paneID
        self.action = action
        self.optionID = optionID
        self.customText = customText
    }

    enum CodingKeys: String, CodingKey {
        case promptID = "prompt_id", paneID = "pane_id", optionID = "option_id", customText = "custom_text", action
    }

    public static func navigationKeys(for response: String) -> [RemoteKeyInputPayload.Key]? {
        var rest = Substring(response)
        var keys: [RemoteKeyInputPayload.Key] = []
        while rest.hasPrefix("\u{1B}[A") || rest.hasPrefix("\u{1B}[B") {
            guard keys.count < RemoteKeyInputPayload.maxKeys else { return nil }
            keys.append(.init(key: rest.hasPrefix("\u{1B}[A") ? "up" : "down"))
            rest = rest.dropFirst(3)
        }
        if rest == "\r" || rest == "\n" {
            keys.append(.init(key: "enter"))
            rest = ""
        }
        guard rest.isEmpty, !keys.isEmpty, keys.count <= RemoteKeyInputPayload.maxKeys else { return nil }
        return keys
    }

    public func responseText(for prompt: RemoteInteractivePrompt, tabID: UInt32, availablePaneIDs: Set<UUID>) -> String? {
        guard prompt.id == promptID, prompt.tabID == tabID, prompt.paneID == paneID,
              availablePaneIDs.contains(paneID) else { return nil }
        switch action {
        case .select, .toggle:
            guard customText == nil, let optionID,
                  let option = prompt.options.first(where: { $0.id == optionID }) else { return nil }
            guard action == .toggle else { return option.response }
            guard prompt.isMultiSelect == true else { return nil }
            let text = option.response.trimmingCharacters(in: .newlines)
            return text.isEmpty ? nil : text
        case .submit:
            guard prompt.isMultiSelect == true, optionID == nil, customText == nil else { return nil }
            return "\r"
        case .custom:
            guard optionID == nil, let text = customText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text.utf8.count <= 16384,
                  !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return "\u{1B}" + text + "\r"
        }
    }
}
