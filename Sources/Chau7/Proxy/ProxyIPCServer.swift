import Foundation
import os.log

/// ProxyIPCServer listens on a Unix socket for real-time API call notifications from the proxy.
/// When the proxy completes forwarding an API call, it sends a JSON message to this server,
/// which then broadcasts the event via NotificationCenter.
@MainActor
public final class ProxyIPCServer: ObservableObject {

    // MARK: - Singleton

    public static let shared = ProxyIPCServer()

    // MARK: - Published State

    @Published public private(set) var isListening = false
    @Published public private(set) var recentEvents: [APICallEvent] = []

    // Task lifecycle state
    @Published public private(set) var pendingCandidates: [String: TaskCandidate] = [:] // tabId -> candidate
    @Published public private(set) var activeTasks: [String: TrackedTask] = [:] // tabId -> task

    // MARK: - Private Properties

    private var socketFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var listeningSource: DispatchSourceRead?
    private var clientSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.chau7.proxy.ipc", qos: .utility)
    private let logger = Logger(subsystem: "com.chau7.proxy", category: "IPCServer")

    private var buffer = Data()
    private let maxRecentEvents = 100

    /// Socket path
    private var socketPath: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Chau7/Proxy")
            .appendingPathComponent("proxy.sock")
    }

    // MARK: - Initialization

    private init() {}

    deinit {
        // Perform cleanup directly without calling stop()
        // to avoid actor isolation issues
        clientSource?.cancel()
        listeningSource?.cancel()
        if clientFD >= 0 {
            close(clientFD)
        }
        if socketFD >= 0 {
            close(socketFD)
        }
        // Compute socket path inline to avoid actor isolation issue
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let path = appSupport
                .appendingPathComponent("Chau7/Proxy")
                .appendingPathComponent("proxy.sock")
                .path
            unlink(path)
        }
    }

    // MARK: - Public Interface

    /// Starts listening on the Unix socket
    public func start() {
        guard !isListening else {
            logger.info("IPC server already listening")
            return
        }

        let path = socketPath.path

        // Create data directory if needed
        let dir = socketPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Remove any stale socket
        unlink(path)

        // Create socket
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        if socketFD < 0 {
            logger.error("Failed to create socket: \(String(cString: strerror(errno)))")
            return
        }

        // Bind to path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy path to sun_path (fixed-size C array)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path) - 1
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let buffer = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            _ = path.withCString { cPath in
                strncpy(buffer, cPath, maxPathLength)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if bindResult < 0 {
            logger.error("Failed to bind socket: \(String(cString: strerror(errno)))")
            close(socketFD)
            socketFD = -1
            return
        }

        // Listen for connections
        if listen(socketFD, 1) < 0 {
            logger.error("Failed to listen: \(String(cString: strerror(errno)))")
            close(socketFD)
            socketFD = -1
            return
        }

        // Set up dispatch source for incoming connections
        listeningSource = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        listeningSource?.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        listeningSource?.setCancelHandler { [weak self] in
            if let fd = self?.socketFD, fd >= 0 {
                close(fd)
            }
            self?.socketFD = -1
        }
        listeningSource?.resume()

        isListening = true
        logger.info("IPC server listening at \(path)")
    }

    /// Stops the IPC server
    public func stop() {
        logger.info("Stopping IPC server")

        clientSource?.cancel()
        clientSource = nil

        listeningSource?.cancel()
        listeningSource = nil

        if clientFD >= 0 {
            close(clientFD)
            clientFD = -1
        }

        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }

        unlink(socketPath.path)

        isListening = false
    }

    /// Clear all recent events
    public func clearEvents() {
        recentEvents.removeAll()
    }

    // MARK: - Private Methods

    private func acceptConnection() {
        var clientAddr = sockaddr_un()
        var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let newClientFD = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                accept(socketFD, sockaddrPtr, &clientAddrLen)
            }
        }

        if newClientFD < 0 {
            logger.warning("Failed to accept connection: \(String(cString: strerror(errno)))")
            return
        }

        // Close previous client if any
        if clientFD >= 0 {
            clientSource?.cancel()
            close(clientFD)
        }

        clientFD = newClientFD
        buffer = Data()

        logger.debug("Accepted IPC connection")

        // Set up read source for client
        clientSource = DispatchSource.makeReadSource(fileDescriptor: newClientFD, queue: queue)
        clientSource?.setEventHandler { [weak self] in
            self?.readFromClient()
        }
        clientSource?.setCancelHandler { [weak self] in
            if let fd = self?.clientFD, fd >= 0 {
                close(fd)
            }
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
                logger.warning("Read error: \(String(cString: strerror(errno)))")
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
                logger.warning("Failed to decode IPC message: \(error.localizedDescription)")
                if let str = String(data: lineData, encoding: .utf8) {
                    logger.debug("Raw message: \(str)")
                }
            }
        }
    }

    private func handleMessage(_ message: ProxyIPCServerMessage) {
        switch message.type {
        case "api_call":
            handleAPICallMessage(message.data)

        case "task_candidate":
            handleTaskCandidateMessage(message.rawData)

        case "task_started":
            handleTaskStartedMessage(message.rawData)

        case "task_candidate_dismissed":
            handleTaskDismissedMessage(message.rawData)

        case "task_assessment":
            handleTaskAssessmentMessage(message.rawData)

        default:
            logger.warning("Unknown message type: \(message.type)")
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
            latencyMs: Int(data.latencyMs),
            statusCode: data.statusCode,
            costUSD: data.costUSD,
            timestamp: ISO8601DateFormatter().date(from: data.timestamp) ?? Date(),
            errorMessage: data.errorMessage.isEmpty ? nil : data.errorMessage
        )

        // Update state on main thread
        Task { @MainActor in
            self.addEvent(event)

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
                self.logger.info("Task candidate received: \(candidate.suggestedName)")
            }
        } catch {
            logger.warning("Failed to decode task_candidate: \(error.localizedDescription)")
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
                totalCostUSD: 0
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
                self.logger.info("Task started: \(task.name)")
            }
        } catch {
            logger.warning("Failed to decode task_started: \(error.localizedDescription)")
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
                    self.logger.info("Task candidate dismissed: \(removed.suggestedName)")
                }
            }
        } catch {
            logger.warning("Failed to decode task_candidate_dismissed: \(error.localizedDescription)")
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
                self.logger.info("Task assessed: \(assessment.taskId) - \(assessment.approved ? "approved" : "failed")")
            }
        } catch {
            logger.warning("Failed to decode task_assessment: \(error.localizedDescription)")
        }
    }

    private func addEvent(_ event: APICallEvent) {
        // Add to recent events (keep bounded)
        recentEvents.insert(event, at: 0)
        if recentEvents.count > maxRecentEvents {
            recentEvents.removeLast(recentEvents.count - maxRecentEvents)
        }

        // Post notification for other components
        NotificationCenter.default.post(
            name: .apiCallRecorded,
            object: nil,
            userInfo: ["event": event]
        )

        logger.info("API call: \(event.provider.rawValue) \(event.model) - in:\(event.inputTokens) out:\(event.outputTokens) $\(String(format: "%.4f", event.costUSD))")
    }
}

// MARK: - IPC Message Types

/// Structure matching Go proxy's IPC message format
struct ProxyIPCServerMessage {
    let type: String
    let data: ProxyIPCServerData
    let rawData: Data?  // Raw JSON for task events
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
    let sessionId: String
    let provider: String
    let model: String
    let endpoint: String
    let inputTokens: Int
    let outputTokens: Int
    let latencyMs: Int64
    let statusCode: Int
    let costUSD: Double
    let timestamp: String
    let errorMessage: String
    let tabId: String?
    let projectPath: String?

    static let empty = ProxyIPCServerData(
        sessionId: "", provider: "", model: "", endpoint: "",
        inputTokens: 0, outputTokens: 0, latencyMs: 0, statusCode: 0,
        costUSD: 0, timestamp: "", errorMessage: "", tabId: nil, projectPath: nil
    )

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case provider
        case model
        case endpoint
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case latencyMs = "latency_ms"
        case statusCode = "status_code"
        case costUSD = "cost_usd"
        case timestamp
        case errorMessage = "error_message"
        case tabId = "tab_id"
        case projectPath = "project_path"
    }

    init(sessionId: String, provider: String, model: String, endpoint: String,
         inputTokens: Int, outputTokens: Int, latencyMs: Int64, statusCode: Int,
         costUSD: Double, timestamp: String, errorMessage: String,
         tabId: String?, projectPath: String?) {
        self.sessionId = sessionId
        self.provider = provider
        self.model = model
        self.endpoint = endpoint
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.latencyMs = latencyMs
        self.statusCode = statusCode
        self.costUSD = costUSD
        self.timestamp = timestamp
        self.errorMessage = errorMessage
        self.tabId = tabId
        self.projectPath = projectPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        provider = try container.decode(String.self, forKey: .provider)
        model = try container.decode(String.self, forKey: .model)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        outputTokens = try container.decode(Int.self, forKey: .outputTokens)
        latencyMs = try container.decode(Int64.self, forKey: .latencyMs)
        statusCode = try container.decode(Int.self, forKey: .statusCode)
        costUSD = try container.decode(Double.self, forKey: .costUSD)
        timestamp = try container.decode(String.self, forKey: .timestamp)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage) ?? ""
        tabId = try container.decodeIfPresent(String.self, forKey: .tabId)
        projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath)
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
