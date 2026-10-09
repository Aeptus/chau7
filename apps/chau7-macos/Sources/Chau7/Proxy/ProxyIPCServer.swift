import Foundation
import os.log
import Chau7Core

/// ProxyIPCServer listens on a Unix socket for real-time API call notifications from the proxy.
/// When the proxy completes forwarding an API call, it sends a JSON message to this server,
/// which then broadcasts the event via NotificationCenter.
@MainActor
@Observable
final class ProxyIPCServer {

    // MARK: - Singleton

    static let shared = ProxyIPCServer()

    // MARK: - Observable State

    private(set) var isListening = false

    /// Task lifecycle state
    private(set) var pendingCandidates: [String: TaskCandidate] = [:] { // tabId -> candidate
        didSet { onPendingCandidatesChange?(pendingCandidates) }
    }

    private(set) var activeTasks: [String: TrackedTask] = [:] { // tabId -> task
        didSet { onActiveTasksChange?(activeTasks) }
    }

    /// Callbacks for cross-class subscribers (replaces Combine $property.sink)
    @ObservationIgnored var onPendingCandidatesChange: (([String: TaskCandidate]) -> Void)?
    @ObservationIgnored var onActiveTasksChange: (([String: TrackedTask]) -> Void)?

    // MARK: - Private Properties

    @ObservationIgnored private var listener: UnixSocketListener?
    @ObservationIgnored private var clientFD: Int32 = -1
    @ObservationIgnored private var clientSource: DispatchSourceRead?
    @ObservationIgnored private let queue = DispatchQueue(label: "com.chau7.proxy.ipc", qos: .utility)
    @ObservationIgnored private let logger = Logger(subsystem: "com.chau7.proxy", category: "IPCServer")

    @ObservationIgnored private var buffer = Data()

    /// Socket path
    private var socketPath: URL {
        RuntimeIsolation.appSupportDirectory(named: "Chau7")
            .appendingPathComponent("Proxy", isDirectory: true)
            .appendingPathComponent("proxy.sock")
    }

    // MARK: - Initialization

    private init() {}

    deinit {
        // Perform cleanup directly without calling stop()
        // to avoid actor isolation issues
        clientSource?.cancel()
        if clientFD >= 0 {
            close(clientFD)
        }
        // stop() is nonisolated on the listener; it closes the listening
        // descriptor and removes the socket file.
        listener?.stop(removeSocketFile: true)
    }

    // MARK: - Public Interface

    /// Starts listening on the Unix socket
    func start() {
        guard !isListening else {
            logger.info("IPC server already listening")
            return
        }

        let path = socketPath.path

        // Create data directory if needed
        let dir = socketPath.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Log.error("ProxyIPCServer: failed to create socket directory: \(error)")
        }

        // Remove any stale socket, then bind/listen and start accepting.
        let listener = UnixSocketListener(path: path, queue: queue)
        listener.removeStaleSocketFile()

        do {
            try listener.start(
                backlog: 1,
                onAccept: { [weak self] newClientFD in
                    self?.handleAcceptedClient(newClientFD)
                },
                onAcceptFailure: { [weak self] acceptErrno in
                    self?.logger.warning("Failed to accept connection: \(String(cString: strerror(acceptErrno)), privacy: .public)")
                }
            )
        } catch {
            logStartFailure(error)
            return
        }

        self.listener = listener
        isListening = true
        logger.info("IPC server listening at \(path, privacy: .public)")
    }

    /// Stops the IPC server
    func stop() {
        logger.info("Stopping IPC server")

        // Cancel handlers own close(fd) — don't double-close here.
        if let cs = clientSource {
            cs.cancel()
            clientSource = nil
        } else if clientFD >= 0 {
            close(clientFD)
            clientFD = -1
        }

        if let listener {
            listener.stop(removeSocketFile: true)
            self.listener = nil
        } else {
            unlink(socketPath.path)
        }

        isListening = false
    }

    // MARK: - Private Methods

    private func logStartFailure(_ error: Error) {
        guard let failure = error as? UnixSocketListener.StartFailure else {
            logger.error("Failed to start IPC server: \(error.localizedDescription, privacy: .public)")
            return
        }
        switch failure.step {
        case .createSocket:
            logger.error("Failed to create socket: \(failure.errnoDescription, privacy: .public)")
        case .bind:
            logger.error("Failed to bind socket: \(failure.errnoDescription, privacy: .public)")
        case .listen:
            logger.error("Failed to listen: \(failure.errnoDescription, privacy: .public)")
        }
    }

    private func handleAcceptedClient(_ newClientFD: Int32) {
        // Close previous client if any — cancel handler owns close(fd)
        if let cs = clientSource {
            cs.cancel()
            clientSource = nil
        } else if clientFD >= 0 {
            close(clientFD)
        }

        clientFD = newClientFD
        buffer = Data()

        logger.debug("Accepted IPC connection")

        // Set up read source for client.
        // Capture fd by value so cancel handler closes the correct descriptor.
        clientSource = DispatchSource.makeReadSource(fileDescriptor: newClientFD, queue: queue)
        clientSource?.setEventHandler { [weak self] in
            self?.readFromClient()
        }
        clientSource?.setCancelHandler { [weak self] in
            close(newClientFD)
            self?.clientFD = -1
        }
        clientSource?.resume()
    }

    private func readFromClient() {
        guard clientFD >= 0 else { return }

        var readBuffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(clientFD, &readBuffer, readBuffer.count)

        if bytesRead <= 0 {
            // Connection closed or error
            if bytesRead < 0 {
                logger.warning("Read error: \(String(cString: strerror(errno)), privacy: .public)")
            }
            clientSource?.cancel()
            return
        }

        // Append to buffer
        buffer.append(contentsOf: readBuffer.prefix(bytesRead))

        // Process complete lines
        processBuffer()
    }

    private func processBuffer() {
        // Messages are newline-delimited JSON
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = Data(buffer.prefix(upTo: newlineIndex))
            buffer = Data(buffer.suffix(from: buffer.index(after: newlineIndex)))

            guard !lineData.isEmpty else { continue }

            do {
                let message = try ProxyIPCServerMessage.decode(from: lineData)
                handleMessage(message)
            } catch {
                logger.warning("Failed to decode IPC message: \(error.localizedDescription, privacy: .public)")
                if let str = String(data: lineData, encoding: .utf8) {
                    logger.debug("Raw message: \(str, privacy: .public)")
                }
            }
        }
    }

    private func handleMessage(_ message: ProxyIPCServerMessage) {
        switch message.type {
        case "api_call":
            handleAPICallMessage(message.data)

        case "generation_progress":
            handleGenerationProgressMessage(message.rawData)

        case "task_candidate":
            handleTaskCandidateMessage(message.rawData)

        case "task_started":
            handleTaskStartedMessage(message.rawData)

        case "task_candidate_dismissed":
            handleTaskDismissedMessage(message.rawData)

        case "task_assessment":
            handleTaskAssessmentMessage(message.rawData)

        default:
            logger.warning("Unknown message type: \(message.type, privacy: .public)")
        }
    }

    private func handleAPICallMessage(_ data: ProxyIPCServerData) {
        // Convert to APICallEvent
        let event = APICallEvent(
            id: UUID(),
            sessionId: data.sessionId,
            provider: APICallEvent.Provider(rawValue: data.provider) ?? .unknown,
            model: data.model,
            endpoint: data.endpoint,
            inputTokens: data.inputTokens,
            outputTokens: data.outputTokens,
            cacheCreationInputTokens: data.cacheCreationInputTokens,
            cacheReadInputTokens: data.cacheReadInputTokens,
            reasoningOutputTokens: data.reasoningOutputTokens,
            latencyMs: Int(data.latencyMs),
            statusCode: data.statusCode,
            costUSD: data.costUSD,
            pricingVersion: data.pricingVersion,
            timestamp: DateFormatters.parseISO8601(data.timestamp) ?? Date(),
            errorMessage: data.errorMessage.isEmpty ? nil : data.errorMessage,
            projectPath: data.projectPath,
            ttftMs: data.ttftMs.map(Int.init),
            outputTokensEstimated: data.outputTokensEstimated
        )

        TelemetryStore.shared.insertUsageEvidence(data.usageEvidence(observedAt: event.timestamp))

        // Update state on main thread
        Task { @MainActor in
            self.addEvent(event)

            if (200 ..< 300).contains(data.statusCode),
               let tabID = data.tabId, !tabID.isEmpty {
                TokenRateStore.shared.record(
                    tabID: tabID,
                    provider: event.provider.displayName,
                    outputTokens: event.outputTokens,
                    durationMs: data.isStreaming
                        ? max(1, Int(data.latencyMs) - max(0, Int(data.ttftMs ?? 0)))
                        : max(1, Int(data.latencyMs)),
                    source: data.outputTokensEstimated
                        ? .proxyEstimatedUsage
                        : (data.isStreaming ? .proxyUsage : .proxyRequestUsage),
                    updatedAt: Date()
                )
            }

            // Update task metrics if associated with a task
            if let tabId = data.tabId, !tabId.isEmpty,
               var task = self.activeTasks[tabId] {
                task.totalAPICalls += 1
                task.totalTokens += event.totalTokens
                task.totalCostUSD += event.costUSD
                self.activeTasks[tabId] = task
            }
        }
    }

    private func handleGenerationProgressMessage(_ rawData: Data?) {
        guard let rawData,
              let message = try? JSONDecoder().decode(ProxyGenerationProgressMessage.self, from: rawData) else {
            return
        }
        let progress = message.data
        let updatedAt = DateFormatters.parseISO8601(progress.timestamp) ?? Date()
        let provider = APICallEvent.Provider(rawValue: progress.provider)?.displayName ?? progress.provider
        let providerName = progress.model.map { "\(provider) · \($0)" } ?? provider
        Task { @MainActor in
            TokenRateStore.shared.recordStreamEstimate(
                tabID: progress.tabId,
                provider: providerName,
                outputTokens: progress.outputTokensEstimate,
                tokensPerSecond: progress.tokensPerSecond,
                durationMs: Int(progress.durationMs),
                updatedAt: updatedAt
            )
        }
    }

    private func handleTaskCandidateMessage(_ rawData: Data?) {
        guard let data = rawData else { return }

        do {
            let eventData = try JSONDecoder().decode(TaskCandidateEventWrapper.self, from: data)
            let candidateData = eventData.data

            let candidate = TaskCandidate(
                id: candidateData.candidateId,
                tabId: candidateData.tabId,
                sessionId: candidateData.sessionId,
                projectPath: candidateData.projectPath,
                suggestedName: candidateData.suggestedName,
                trigger: TaskTrigger(rawValue: candidateData.trigger) ?? .manual,
                confidence: candidateData.confidence,
                gracePeriodEnd: Date().addingTimeInterval(Double(candidateData.gracePeriodSeconds)),
                createdAt: Date()
            )

            Task { @MainActor in
                self.pendingCandidates[candidate.tabId] = candidate
                NotificationCenter.default.post(
                    name: .taskCandidateReceived,
                    object: nil,
                    userInfo: ["candidate": candidate]
                )
                self.logger.info("Task candidate received: \(candidate.suggestedName, privacy: .public)")
            }
        } catch {
            logger.warning("Failed to decode task_candidate: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleTaskStartedMessage(_ rawData: Data?) {
        guard let data = rawData else { return }

        do {
            let eventData = try JSONDecoder().decode(TaskStartedEventWrapper.self, from: data)
            let taskData = eventData.data

            let task = TrackedTask(
                id: taskData.taskId,
                candidateId: taskData.candidateId,
                tabId: taskData.tabId,
                sessionId: taskData.sessionId,
                projectPath: taskData.projectPath,
                name: taskData.taskName,
                state: .active,
                startMethod: TaskStartMethod(rawValue: taskData.startMethod) ?? .autoConfirmed,
                trigger: TaskTrigger(rawValue: taskData.trigger) ?? .manual,
                startedAt: Date(),
                completedAt: nil,
                totalAPICalls: 0,
                totalTokens: 0,
                totalCostUSD: 0,
                baselineTotalTokens: 0,
                tokensSaved: 0
            )

            Task { @MainActor in
                // Remove candidate if it was confirmed
                self.pendingCandidates.removeValue(forKey: task.tabId)
                self.activeTasks[task.tabId] = task
                NotificationCenter.default.post(
                    name: .taskStarted,
                    object: nil,
                    userInfo: ["task": task]
                )
                self.logger.info("Task started: \(task.name, privacy: .public)")
            }
        } catch {
            logger.warning("Failed to decode task_started: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleTaskDismissedMessage(_ rawData: Data?) {
        guard let data = rawData else { return }

        do {
            let eventData = try JSONDecoder().decode(TaskDismissedEventWrapper.self, from: data)
            let dismissData = eventData.data

            Task { @MainActor in
                if let removed = self.pendingCandidates.removeValue(forKey: dismissData.tabId) {
                    NotificationCenter.default.post(
                        name: .taskCandidateDismissed,
                        object: nil,
                        userInfo: ["candidateId": removed.id, "tabId": dismissData.tabId]
                    )
                    self.logger.info("Task candidate dismissed: \(removed.suggestedName, privacy: .public)")
                }
            }
        } catch {
            logger.warning("Failed to decode task_candidate_dismissed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleTaskAssessmentMessage(_ rawData: Data?) {
        guard let data = rawData else { return }

        do {
            let eventData = try JSONDecoder().decode(TaskAssessmentEventWrapper.self, from: data)
            let assessData = eventData.data

            let assessment = TaskAssessment(
                taskId: assessData.taskId,
                approved: assessData.approved,
                note: assessData.note,
                totalAPICalls: assessData.totalAPICalls,
                totalTokens: assessData.totalTokens,
                totalCostUSD: assessData.totalCostUSD,
                tokensSaved: assessData.tokensSaved,
                durationSeconds: assessData.durationSeconds,
                assessedAt: Date()
            )

            Task { @MainActor in
                // Update task state
                for (tabId, var task) in self.activeTasks {
                    if task.id == assessment.taskId {
                        task.completedAt = Date()
                        self.activeTasks[tabId] = task
                        break
                    }
                }
                NotificationCenter.default.post(
                    name: .taskAssessmentReceived,
                    object: nil,
                    userInfo: ["assessment": assessment]
                )
                let outcome: StaticString = assessment.approved ? "approved" : "failed"
                self.logger.info("Task assessed: \(assessment.taskId, privacy: .public) - \(outcome)")
            }
        } catch {
            logger.warning("Failed to decode task_assessment: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func addEvent(_ event: APICallEvent) {
        // Post notification for other components
        NotificationCenter.default.post(
            name: .apiCallRecorded,
            object: nil,
            userInfo: ["event": event]
        )

        let cost = String(format: "%.4f", event.costUSD)
        logger.info(
            "API call: \(event.provider.rawValue, privacy: .public) \(event.model, privacy: .public) - in:\(event.inputTokens, privacy: .public) out:\(event.outputTokens, privacy: .public) $\(cost, privacy: .public)"
        )
    }
}

// MARK: - IPC Message Types

/// Structure matching Go proxy's IPC message format
struct ProxyIPCServerMessage {
    let type: String
    let data: ProxyIPCServerData
    let rawData: Data? // Raw JSON for non-API events
}

private struct ProxyGenerationProgressMessage: Decodable {
    let data: ProxyGenerationProgressData
}

private struct ProxyGenerationProgressData: Decodable {
    let tabId: String
    let provider: String
    let model: String?
    let outputTokensEstimate: Int
    let tokensPerSecond: Double
    let durationMs: Int64
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case tabId = "tab_id"
        case provider
        case model
        case outputTokensEstimate = "output_tokens_estimate"
        case tokensPerSecond = "tokens_per_second"
        case durationMs = "duration_ms"
        case timestamp
    }
}

extension ProxyIPCServerMessage {
    static func decode(from lineData: Data) throws -> ProxyIPCServerMessage {
        // First, decode just the type
        struct TypeOnly: Decodable {
            let type: String
        }
        let typeInfo = try JSONDecoder().decode(TypeOnly.self, from: lineData)

        // For api_call, decode the full data; for others, keep raw
        if typeInfo.type == "api_call" {
            struct APICallMessage: Decodable {
                let type: String
                let data: ProxyIPCServerData
            }
            let message = try JSONDecoder().decode(APICallMessage.self, from: lineData)
            return ProxyIPCServerMessage(type: message.type, data: message.data, rawData: nil)
        } else {
            // For task events, pass raw data for specialized decoding
            return ProxyIPCServerMessage(
                type: typeInfo.type,
                data: ProxyIPCServerData.empty,
                rawData: lineData
            )
        }
    }
}

struct ProxyIPCServerData: Decodable {
    let requestId: String?
    let sessionId: String
    let provider: String
    let model: String
    let endpoint: String
    let inputTokens: Int?
    let outputTokens: Int?
    let outputTokensEstimated: Bool
    let isStreaming: Bool
    let cacheCreationInputTokens: Int?
    let cacheReadInputTokens: Int?
    let reasoningOutputTokens: Int?
    let latencyMs: Int64
    let ttftMs: Int64?
    let statusCode: Int
    let costUSD: Double?
    let pricingVersion: String?
    let timestamp: String
    let errorMessage: String
    let taskId: String?
    let tabId: String?
    let projectPath: String?

    static let empty = ProxyIPCServerData(
        sessionId: "", provider: "", model: "", endpoint: "",
        inputTokens: nil, outputTokens: nil,
        outputTokensEstimated: false,
        isStreaming: false,
        cacheCreationInputTokens: nil, cacheReadInputTokens: nil, reasoningOutputTokens: nil,
        latencyMs: 0, ttftMs: nil, statusCode: 0,
        costUSD: nil, pricingVersion: nil, timestamp: "", errorMessage: "", taskId: nil, tabId: nil, projectPath: nil
    )

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case sessionId = "session_id"
        case provider
        case model
        case endpoint
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case outputTokensEstimated = "output_tokens_estimated"
        case isStreaming = "is_streaming"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case latencyMs = "latency_ms"
        case ttftMs = "ttft_ms"
        case statusCode = "status_code"
        case costUSD = "cost_usd"
        case pricingVersion = "pricing_version"
        case timestamp
        case errorMessage = "error_message"
        case taskId = "task_id"
        case tabId = "tab_id"
        case projectPath = "project_path"
    }

    init(
        sessionId: String,
        provider: String,
        model: String,
        endpoint: String,
        inputTokens: Int?,
        outputTokens: Int?,
        outputTokensEstimated: Bool = false,
        isStreaming: Bool = false,
        cacheCreationInputTokens: Int? = nil,
        cacheReadInputTokens: Int? = nil,
        reasoningOutputTokens: Int? = nil,
        latencyMs: Int64,
        ttftMs: Int64? = nil,
        statusCode: Int,
        costUSD: Double?,
        pricingVersion: String? = nil,
        timestamp: String,
        errorMessage: String,
        taskId: String?,
        tabId: String?,
        projectPath: String?,
        requestId: String? = nil
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.provider = provider
        self.model = model
        self.endpoint = endpoint
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.outputTokensEstimated = outputTokensEstimated
        self.isStreaming = isStreaming
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.latencyMs = latencyMs
        self.ttftMs = ttftMs
        self.statusCode = statusCode
        self.costUSD = costUSD
        self.pricingVersion = pricingVersion
        self.timestamp = timestamp
        self.errorMessage = errorMessage
        self.taskId = taskId
        self.tabId = tabId
        self.projectPath = projectPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.provider = try container.decode(String.self, forKey: .provider)
        self.model = try container.decode(String.self, forKey: .model)
        self.endpoint = try container.decode(String.self, forKey: .endpoint)
        self.inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
        self.outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens)
        self.outputTokensEstimated = try container.decodeIfPresent(Bool.self, forKey: .outputTokensEstimated) ?? false
        self.isStreaming = try container.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        self.cacheCreationInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens)
        self.cacheReadInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens)
        self.reasoningOutputTokens = try container.decodeIfPresent(Int.self, forKey: .reasoningOutputTokens)
        self.latencyMs = try container.decode(Int64.self, forKey: .latencyMs)
        self.ttftMs = try container.decodeIfPresent(Int64.self, forKey: .ttftMs)
        self.statusCode = try container.decode(Int.self, forKey: .statusCode)
        self.costUSD = try container.decodeIfPresent(Double.self, forKey: .costUSD)
        self.pricingVersion = try container.decodeIfPresent(String.self, forKey: .pricingVersion)
        self.timestamp = try container.decode(String.self, forKey: .timestamp)
        self.errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage) ?? ""
        self.taskId = try container.decodeIfPresent(String.self, forKey: .taskId)
        self.tabId = try container.decodeIfPresent(String.self, forKey: .tabId)
        self.projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath)
    }
}

// MARK: - Task Event Wrappers

struct TaskCandidateEventWrapper: Decodable {
    let data: TaskCandidateEventData
}

struct TaskStartedEventWrapper: Decodable {
    let data: TaskStartedEventData
}

struct TaskDismissedEventWrapper: Decodable {
    let data: TaskDismissedEventData
}

struct TaskAssessmentEventWrapper: Decodable {
    let data: TaskAssessmentEventData
}

extension ProxyIPCServerData {
    func usageEvidence(observedAt: Date) -> UsageEvidence {
        var metadata: [String: String] = [:]
        if let tabId, !tabId.isEmpty { metadata["tab_id"] = tabId }
        return UsageEvidence.proxyEvent(
            provider: provider, model: model.isEmpty ? nil : model,
            sessionID: sessionId.isEmpty ? nil : sessionId, endpoint: endpoint.isEmpty ? nil : endpoint,
            projectPath: projectPath, observedAt: observedAt, inputTokens: inputTokens, outputTokens: outputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens, cacheReadInputTokens: cacheReadInputTokens,
            reasoningOutputTokens: reasoningOutputTokens, costUSD: costUSD, pricingVersion: pricingVersion,
            metadata: metadata, requestID: requestId
        )
    }
}
