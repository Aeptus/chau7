import Foundation

// MARK: - Claude Code Monitor

/// Monitors Claude Code events via hooks and provides real-time updates
final class ClaudeCodeMonitor: ObservableObject {
    static let shared = ClaudeCodeMonitor()

    // MARK: - Published State

    @Published private(set) var recentEvents: [ClaudeCodeEvent] = []
    @Published private(set) var activeSessions: [String: ClaudeSessionInfo] = [:]
    @Published private(set) var isMonitoring = false

    // MARK: - Session Info

    struct ClaudeSessionInfo: Identifiable, Equatable {
        let id: String  // sessionId
        let projectName: String
        let transcriptPath: String
        var lastActivity: Date
        var state: SessionState

        enum SessionState: String {
            case active
            case idle
            case responding
            case closed
        }
    }

    // MARK: - Configuration

    private let eventsFilePath: String
    private let maxRecentEvents = 50
    private let idleThreshold: TimeInterval = 5.0

    // MARK: - Internal State

    private var eventTailer: FileTailer<ClaudeCodeEvent>?
    private var idleTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.chau7.claudeMonitor")

    // MARK: - Callbacks

    var onEvent: ((ClaudeCodeEvent) -> Void)?
    var onSessionIdle: ((ClaudeSessionInfo) -> Void)?
    var onResponseComplete: ((ClaudeCodeEvent) -> Void)?

    // MARK: - Init

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.eventsFilePath = home.appendingPathComponent(".chau7/claude-events.jsonl").path
    }

    // MARK: - Lifecycle

    func start() {
        guard !isMonitoring else { return }

        // Ensure events file exists
        let fm = FileManager.default
        let dir = (eventsFilePath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: eventsFilePath) {
            fm.createFile(atPath: eventsFilePath, contents: nil)
        }

        // Start tailing events file
        let url = URL(fileURLWithPath: eventsFilePath)
        eventTailer = FileTailer<ClaudeCodeEvent>(
            fileURL: url,
            pollInterval: .milliseconds(250),
            createIfMissing: true,
            queueLabel: "com.chau7.claudeMonitor",
            parser: { line in
                try ClaudeCodeEventParser.parse(line: line)
            },
            onItem: { [weak self] event in
                self?.handleEvent(event)
            }
        )
        eventTailer?.start()

        // Start idle check timer
        startIdleTimer()

        DispatchQueue.main.async {
            self.isMonitoring = true
        }
        Log.info("ClaudeCodeMonitor started. path=\(eventsFilePath)")
    }

    func stop() {
        eventTailer?.stop()
        eventTailer = nil
        idleTimer?.cancel()
        idleTimer = nil

        DispatchQueue.main.async {
            self.isMonitoring = false
            self.activeSessions.removeAll()
        }
        Log.info("ClaudeCodeMonitor stopped.")
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: ClaudeCodeEvent) {
        Log.trace("Claude event: type=\(event.type.rawValue) session=\(event.shortSessionId) tool=\(event.toolName)")

        // Update session state (dispatches to main internally)
        updateSession(for: event)

        // All UI updates and callbacks on main thread
        DispatchQueue.main.async {
            // Update recent events
            self.recentEvents.append(event)
            if self.recentEvents.count > self.maxRecentEvents {
                self.recentEvents.removeFirst(self.recentEvents.count - self.maxRecentEvents)
            }

            // Fire callbacks
            self.onEvent?(event)

            switch event.type {
            case .responseComplete:
                self.onResponseComplete?(event)
                self.notifyResponseComplete(event)
            case .sessionEnd:
                self.markSessionClosed(event.sessionId)
            default:
                break
            }
        }
    }

    private func updateSession(for event: ClaudeCodeEvent) {
        let sessionId = event.sessionId
        guard !sessionId.isEmpty else { return }

        DispatchQueue.main.async {
            if var session = self.activeSessions[sessionId] {
                session.lastActivity = event.timestamp
                session.state = self.stateForEvent(event.type)
                self.activeSessions[sessionId] = session
            } else {
                let session = ClaudeSessionInfo(
                    id: sessionId,
                    projectName: event.projectName,
                    transcriptPath: event.transcriptPath,
                    lastActivity: event.timestamp,
                    state: self.stateForEvent(event.type)
                )
                self.activeSessions[sessionId] = session
            }
        }
    }

    private func stateForEvent(_ type: ClaudeEventType) -> ClaudeSessionInfo.SessionState {
        switch type {
        case .toolStart:
            return .responding
        case .toolComplete:
            return .responding
        case .responseComplete:
            return .active
        case .sessionEnd:
            return .closed
        default:
            return .active
        }
    }

    private func markSessionClosed(_ sessionId: String) {
        DispatchQueue.main.async {
            self.activeSessions[sessionId]?.state = .closed
        }
    }

    // MARK: - Idle Detection

    private func startIdleTimer() {
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.checkIdleSessions()
        }
        timer.resume()
        idleTimer = timer
    }

    private func checkIdleSessions() {
        let now = Date()

        DispatchQueue.main.async {
            for (sessionId, session) in self.activeSessions {
                guard session.state == .active || session.state == .responding else { continue }

                let idleFor = now.timeIntervalSince(session.lastActivity)
                if idleFor >= self.idleThreshold {
                    var updated = session
                    updated.state = .idle
                    self.activeSessions[sessionId] = updated
                    self.onSessionIdle?(updated)
                    self.notifySessionIdle(updated, idleFor: idleFor)
                }
            }
        }
    }

    // MARK: - Notifications

    private func notifyResponseComplete(_ event: ClaudeCodeEvent) {
        let aiEvent = AIEvent(
            type: "finished",
            tool: "Claude",
            message: "Response complete in \(event.projectName)",
            ts: DateFormatters.nowISO8601()
        )
        NotificationManager.shared.notify(for: aiEvent)
    }

    private func notifySessionIdle(_ session: ClaudeSessionInfo, idleFor: TimeInterval) {
        let aiEvent = AIEvent(
            type: "idle",
            tool: "Claude",
            message: "Waiting for input in \(session.projectName) (\(Int(idleFor))s idle)",
            ts: DateFormatters.nowISO8601()
        )
        NotificationManager.shared.notify(for: aiEvent)
    }

    // MARK: - Transcript Access

    /// Get recent messages from a session's transcript
    /// - Note: Must be called from main thread
    func getTranscriptMessages(for sessionId: String, count: Int = 20) -> [ClaudeTranscriptMessage] {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let session = activeSessions[sessionId],
              !session.transcriptPath.isEmpty else {
            return []
        }
        return ClaudeTranscriptParser.latestMessages(from: session.transcriptPath, count: count)
    }

    /// Get all messages from a transcript path
    func getTranscriptMessages(at path: String) -> [ClaudeTranscriptMessage] {
        return ClaudeTranscriptParser.parseTranscript(at: path)
    }

    // MARK: - Utilities

    /// Check if hook script is installed
    static var isHookInstalled: Bool {
        let hookPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".chau7/hooks/claude-notify.sh").path
        return FileManager.default.isExecutableFile(atPath: hookPath)
    }

    /// Get the hook command for settings.json
    static var hookCommand: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.chau7/hooks/claude-notify.sh"
    }
}
