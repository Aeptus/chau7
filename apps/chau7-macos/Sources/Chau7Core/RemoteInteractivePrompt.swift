import Foundation

public struct RemoteInteractivePromptOption: Codable, Equatable, Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String
    public let response: String
    public let isDestructive: Bool

    public init(id: String, label: String, response: String, isDestructive: Bool = false) {
        self.id = id
        self.label = label
        self.response = response
        self.isDestructive = isDestructive
    }

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case response
        case isDestructive = "is_destructive"
    }
}

public struct RemoteInteractivePrompt: Codable, Equatable, Sendable, Hashable, Identifiable {
    public let id: String
    public let tabID: UInt32
    public let tabTitle: String
    public let toolName: String
    public let prompt: String
    public let detail: String?
    public let options: [RemoteInteractivePromptOption]
    public let detectedAt: Date

    public init(
        id: String,
        tabID: UInt32,
        tabTitle: String,
        toolName: String,
        prompt: String,
        detail: String? = nil,
        options: [RemoteInteractivePromptOption],
        detectedAt: Date
    ) {
        self.id = id
        self.tabID = tabID
        self.tabTitle = tabTitle
        self.toolName = toolName
        self.prompt = prompt
        self.detail = detail
        self.options = options
        self.detectedAt = detectedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case tabID = "tab_id"
        case tabTitle = "tab_title"
        case toolName = "tool_name"
        case prompt
        case detail
        case options
        case detectedAt = "detected_at"
    }
}

public struct RemoteInteractivePromptListPayload: Codable, Equatable, Sendable, Hashable {
    public let prompts: [RemoteInteractivePrompt]

    public init(prompts: [RemoteInteractivePrompt]) {
        self.prompts = prompts
    }
}
