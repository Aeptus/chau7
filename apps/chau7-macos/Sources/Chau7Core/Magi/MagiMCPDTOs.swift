import Foundation

public struct MagiMCPAgentLaunchRequest: Encodable, Equatable {
    public var directory: String
    public var agentCommand: String
    public var prompt: String
    public var count: Int
    public var readyTimeoutMs: Int

    public init(
        directory: String,
        agentCommand: String,
        prompt: String,
        count: Int = 1,
        readyTimeoutMs: Int
    ) {
        self.directory = directory
        self.agentCommand = agentCommand
        self.prompt = prompt
        self.count = count
        self.readyTimeoutMs = readyTimeoutMs
    }

    private enum CodingKeys: String, CodingKey {
        case directory
        case agentCommand = "agent_command"
        case prompt
        case count
        case readyTimeoutMs = "ready_timeout_ms"
    }
}

public struct MagiMCPAgentLaunchResponse: Decodable, Equatable {
    public var agents: [MagiMCPAgentLaunchAgent]

    public init(agents: [MagiMCPAgentLaunchAgent]) {
        self.agents = agents
    }
}

public struct MagiMCPAgentLaunchAgent: Decodable, Equatable {
    public var tabID: String?
    public var status: String
    public var promptStatus: String
    public var promptInputVisible: Bool?
    public var promptSubmitted: Bool?
    public var agentRunning: Bool?
    public var error: String?

    public var promptVerificationFieldsPresent: Bool {
        promptInputVisible != nil || promptSubmitted != nil || agentRunning != nil
    }

    public init(
        tabID: String?,
        status: String = "",
        promptStatus: String = "",
        promptInputVisible: Bool? = nil,
        promptSubmitted: Bool? = nil,
        agentRunning: Bool? = nil,
        error: String? = nil
    ) {
        self.tabID = tabID
        self.status = status
        self.promptStatus = promptStatus
        self.promptInputVisible = promptInputVisible
        self.promptSubmitted = promptSubmitted
        self.agentRunning = agentRunning
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case status
        case promptStatus = "prompt"
        case promptInputVisible = "prompt_input_visible"
        case promptSubmitted = "prompt_submitted"
        case agentRunning = "agent_running"
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabID = try MagiMCPDTOCoding.optionalString(container, forKey: .tabID)
        status = try MagiMCPDTOCoding.string(container, forKey: .status)
        promptStatus = try MagiMCPDTOCoding.string(container, forKey: .promptStatus)
        promptInputVisible = try MagiMCPDTOCoding.optionalBool(container, forKey: .promptInputVisible)
        promptSubmitted = try MagiMCPDTOCoding.optionalBool(container, forKey: .promptSubmitted)
        agentRunning = try MagiMCPDTOCoding.optionalBool(container, forKey: .agentRunning)
        error = try MagiMCPDTOCoding.optionalString(container, forKey: .error)
    }
}

public struct MagiMCPTabRenameRequest: Encodable, Equatable {
    public var tabID: String
    public var title: String

    public init(tabID: String, title: String) {
        self.tabID = tabID
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case title
    }
}

public struct MagiMCPTabOutputRequest: Encodable, Equatable {
    public var tabID: String
    public var lines: Int
    public var waitForStableMs: Int
    public var source: String

    public init(
        tabID: String,
        lines: Int,
        waitForStableMs: Int = 0,
        source: String = "pty_log"
    ) {
        self.tabID = tabID
        self.lines = lines
        self.waitForStableMs = waitForStableMs
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case lines
        case waitForStableMs = "wait_for_stable_ms"
        case source
    }
}

public struct MagiMCPTabOutputResponse: Decodable, Equatable {
    public var output: String

    public init(output: String) {
        self.output = output
    }
}

public struct MagiMCPTabStatusRequest: Encodable, Equatable {
    public var tabID: String

    public init(tabID: String) {
        self.tabID = tabID
    }

    private enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
    }
}

public struct MagiMCPTabStatus: Decodable, Equatable {
    public var activeRun: JSONValue?
    public var activeApp: String
    public var aiProvider: String
    public var status: String
    public var rawStatus: String
    public var canAcceptExec: Bool
    public var readyForExec: Bool
    public var isAtPrompt: Bool
    public var rawIsAtPrompt: Bool

    public var hasActiveRun: Bool {
        activeRun != nil
    }

    public init(
        activeRun: JSONValue? = nil,
        activeApp: String = "",
        aiProvider: String = "",
        status: String = "",
        rawStatus: String = "",
        canAcceptExec: Bool = false,
        readyForExec: Bool = false,
        isAtPrompt: Bool = false,
        rawIsAtPrompt: Bool = false
    ) {
        self.activeRun = activeRun
        self.activeApp = activeApp
        self.aiProvider = aiProvider
        self.status = status
        self.rawStatus = rawStatus
        self.canAcceptExec = canAcceptExec
        self.readyForExec = readyForExec
        self.isAtPrompt = isAtPrompt
        self.rawIsAtPrompt = rawIsAtPrompt
    }

    private enum CodingKeys: String, CodingKey {
        case activeRun = "active_run"
        case activeApp = "active_app"
        case aiProvider = "ai_provider"
        case status
        case rawStatus = "raw_status"
        case canAcceptExec = "can_accept_exec"
        case readyForExec = "ready_for_exec"
        case isAtPrompt = "is_at_prompt"
        case rawIsAtPrompt = "raw_is_at_prompt"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeRun = try MagiMCPDTOCoding.optionalJSONValue(container, forKey: .activeRun)
        activeApp = try MagiMCPDTOCoding.string(container, forKey: .activeApp)
        aiProvider = try MagiMCPDTOCoding.string(container, forKey: .aiProvider)
        status = try MagiMCPDTOCoding.string(container, forKey: .status)
        rawStatus = try MagiMCPDTOCoding.string(container, forKey: .rawStatus)
        canAcceptExec = try MagiMCPDTOCoding.bool(container, forKey: .canAcceptExec)
        readyForExec = try MagiMCPDTOCoding.bool(container, forKey: .readyForExec)
        isAtPrompt = try MagiMCPDTOCoding.bool(container, forKey: .isAtPrompt)
        rawIsAtPrompt = try MagiMCPDTOCoding.bool(container, forKey: .rawIsAtPrompt)
    }
}

public struct MagiMCPTabInputRequest: Encodable, Equatable {
    public var tabID: String
    public var input: String

    public init(tabID: String, input: String) {
        self.tabID = tabID
        self.input = input
    }

    private enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case input
    }
}

public struct MagiMCPTabSendInputResponse: Decodable, Equatable {
    public var ok: String

    public init(ok: String = "") {
        self.ok = ok
    }

    private enum CodingKeys: String, CodingKey {
        case ok
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try MagiMCPDTOCoding.string(container, forKey: .ok)
    }
}

public struct MagiMCPTabSubmitPromptRequest: Encodable, Equatable {
    public var tabID: String

    public init(tabID: String) {
        self.tabID = tabID
    }

    private enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
    }
}

public struct MagiMCPTabSubmitPromptResponse: Decodable, Equatable {
    public var ok: String
    public var enterCount: String

    public init(ok: String = "", enterCount: String = "") {
        self.ok = ok
        self.enterCount = enterCount
    }

    private enum CodingKeys: String, CodingKey {
        case ok
        case enterCount = "enter_count"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try MagiMCPDTOCoding.string(container, forKey: .ok)
        enterCount = try MagiMCPDTOCoding.string(container, forKey: .enterCount)
    }
}

public struct MagiMCPTabCloseRequest: Encodable, Equatable {
    public var tabID: String
    public var force: Bool

    public init(tabID: String, force: Bool = true) {
        self.tabID = tabID
        self.force = force
    }

    private enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case force
    }
}

public struct MagiMCPRuntimeEventsRequest: Encodable, Equatable {
    public var limit: Int
    public var sinceMillis: Int64?

    public init(limit: Int, sinceMillis: Int64? = nil) {
        self.limit = limit
        self.sinceMillis = sinceMillis
    }

    private enum CodingKeys: String, CodingKey {
        case limit
        case sinceMillis = "since_millis"
    }
}

public struct MagiMCPRuntimeEventsResponse: Decodable, Equatable {
    public var events: [MagiMCPRuntimeEvent]

    public init(events: [MagiMCPRuntimeEvent]) {
        self.events = events
    }
}

public struct MagiMCPRuntimeEvent: Decodable, Equatable {
    public var type: String
    public var tabID: String
    public var detail: MagiMCPRuntimeEventDetail

    public init(
        type: String = "",
        tabID: String = "",
        detail: MagiMCPRuntimeEventDetail = MagiMCPRuntimeEventDetail()
    ) {
        self.type = type
        self.tabID = tabID
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case tabID = "tab_id"
        case detail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try MagiMCPDTOCoding.string(container, forKey: .type)
        tabID = try MagiMCPDTOCoding.string(container, forKey: .tabID)
        detail = (try? container.decode(MagiMCPRuntimeEventDetail.self, forKey: .detail)) ?? MagiMCPRuntimeEventDetail()
    }
}

public struct MagiMCPRuntimeEventDetail: Decodable, Equatable {
    public var eventType: String
    public var message: String

    public init(eventType: String = "", message: String = "") {
        self.eventType = eventType
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventType = try MagiMCPDTOCoding.string(container, forKey: .eventType)
        message = try MagiMCPDTOCoding.string(container, forKey: .message)
    }
}

public struct MagiMCPRepoGetEventsRequest: Encodable, Equatable {
    public var repoPath: String
    public var limit: Int
    public var tabID: String
    public var eventTypes: [String]
    public var truncateMessages: Bool

    public init(
        repoPath: String,
        limit: Int,
        tabID: String,
        eventTypes: [String],
        truncateMessages: Bool
    ) {
        self.repoPath = repoPath
        self.limit = limit
        self.tabID = tabID
        self.eventTypes = eventTypes
        self.truncateMessages = truncateMessages
    }

    private enum CodingKeys: String, CodingKey {
        case repoPath = "repo_path"
        case limit
        case tabID = "tab_id"
        case eventTypes = "event_types"
        case truncateMessages = "truncate_messages"
    }
}

public struct MagiMCPRepoEventsResponse: Decodable, Equatable {
    public var events: [MagiMCPRepoEvent]

    public init(events: [MagiMCPRepoEvent]) {
        self.events = events
    }
}

public struct MagiMCPRepoEvent: Decodable, Equatable {
    public var message: String

    public init(message: String = "") {
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try MagiMCPDTOCoding.string(container, forKey: .message)
    }
}

public struct MagiMCPTabCreateRequest: Encodable, Equatable {
    public var directory: String

    public init(directory: String) {
        self.directory = directory
    }
}

public struct MagiMCPTabCreateResponse: Decodable, Equatable {
    public var tabID: String?

    public init(tabID: String?) {
        self.tabID = tabID
    }

    private enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabID = try MagiMCPDTOCoding.optionalString(container, forKey: .tabID)
    }
}

public struct MagiMCPTabWaitReadyRequest: Encodable, Equatable {
    public var tabID: String
    public var timeoutMs: Int

    public init(tabID: String, timeoutMs: Int) {
        self.tabID = tabID
        self.timeoutMs = timeoutMs
    }

    private enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case timeoutMs = "timeout_ms"
    }
}

public struct MagiMCPTabWaitReadyResponse: Decodable, Equatable {
    public var canAcceptExec: Bool

    public init(canAcceptExec: Bool = false) {
        self.canAcceptExec = canAcceptExec
    }

    private enum CodingKeys: String, CodingKey {
        case canAcceptExec = "can_accept_exec"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canAcceptExec = try MagiMCPDTOCoding.bool(container, forKey: .canAcceptExec)
    }
}

public struct MagiMCPTabExecRequest: Encodable, Equatable {
    public var tabID: String
    public var command: String

    public init(tabID: String, command: String) {
        self.tabID = tabID
        self.command = command
    }

    private enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case command
    }
}

public struct MagiMCPOperationResponse: Decodable, Equatable {
    public init() {}

    public init(from decoder: Decoder) throws {
        _ = try? decoder.container(keyedBy: EmptyCodingKeys.self)
    }

    private enum EmptyCodingKeys: CodingKey {}
}

private enum MagiMCPDTOCoding {
    static func string<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> String {
        try optionalString(container, forKey: key) ?? ""
    }

    static func optionalString<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> String? {
        guard container.contains(key), try !container.decodeNil(forKey: key) else { return nil }
        if let value = try? container.decode(String.self, forKey: key) { return value }
        if let value = try? container.decode(Bool.self, forKey: key) { return String(value) }
        if let value = try? container.decode(Int.self, forKey: key) { return String(value) }
        if let value = try? container.decode(Double.self, forKey: key) { return String(value) }
        if let value = try? container.decode(JSONValue.self, forKey: key) {
            return String(describing: value.foundationValue)
        }
        return nil
    }

    static func bool<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> Bool {
        try optionalBool(container, forKey: key) ?? false
    }

    static func optionalBool<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> Bool? {
        guard container.contains(key), try !container.decodeNil(forKey: key) else { return nil }
        if let value = try? container.decode(Bool.self, forKey: key) { return value }
        if let value = try? container.decode(Int.self, forKey: key) { return value != 0 }
        if let value = try? container.decode(Double.self, forKey: key) { return value != 0 }
        if let value = try? container.decode(String.self, forKey: key) {
            return ["true", "yes", "1"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        return nil
    }

    static func optionalJSONValue<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> JSONValue? {
        guard container.contains(key), try !container.decodeNil(forKey: key) else { return nil }
        return try container.decode(JSONValue.self, forKey: key)
    }
}
