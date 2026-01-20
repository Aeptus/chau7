// MARK: - Predictive Text Rendering Cache
// Pre-renders likely text to reduce latency when it appears.
// Uses pattern recognition from shell history and common commands.

import Foundation
import Atomics

/// Predictive text renderer that pre-caches likely terminal output.
/// Reduces perceived latency by having common responses ready before they arrive.
public final class PredictiveRenderer {

    // MARK: - Types

    /// Cached render result
    public struct CachedRender {
        let text: String
        let renderedData: Data  // Pre-rendered bitmap/glyph data
        let timestamp: CFAbsoluteTime
        let hitCount: Int
    }

    /// Prediction source
    public enum PredictionSource {
        case shellHistory      // From ~/.bash_history, ~/.zsh_history
        case recentOutput      // Recent terminal output patterns
        case commonCommands    // Common shell commands
        case userTyping        // What user is currently typing
    }

    /// Prediction confidence level
    public struct Prediction: Hashable {
        let text: String
        let confidence: Float  // 0.0-1.0
        let source: PredictionSource

        public func hash(into hasher: inout Hasher) {
            hasher.combine(text)
        }

        public static func == (lhs: Prediction, rhs: Prediction) -> Bool {
            lhs.text == rhs.text
        }
    }

    // MARK: - Properties

    /// Maximum cache size
    private let maxCacheSize: Int

    /// Minimum confidence to pre-render
    private let confidenceThreshold: Float = 0.3

    /// Cache of pre-rendered text
    private var cache: [String: CachedRender] = [:]
    private let cacheLock = NSLock()

    /// Recent input for pattern matching
    private var recentInput: [String] = []
    private let maxRecentInput = 100

    /// Common command prefixes and their likely completions
    private var commandCompletions: [String: [String]] = [:]

    /// Shell history patterns
    private var historyPatterns: [String: Int] = [:]

    /// Statistics
    private let cacheHits = ManagedAtomic<UInt64>(0)
    private let cacheMisses = ManagedAtomic<UInt64>(0)
    private let predictionsGenerated = ManagedAtomic<UInt64>(0)

    /// Background queue for pre-rendering
    private let renderQueue: DispatchQueue

    // MARK: - Initialization

    public init(maxCacheSize: Int = 1000) {
        self.maxCacheSize = maxCacheSize
        self.renderQueue = DispatchQueue(
            label: "com.chau7.predictive-renderer",
            qos: .utility,
            attributes: .concurrent
        )

        setupCommonCompletions()
        loadShellHistory()
    }

    // MARK: - Prediction Generation

    /// Generates predictions based on current input
    public func predict(currentInput: String) -> [Prediction] {
        var predictions: [Prediction] = []

        // 1. Command completion predictions
        predictions.append(contentsOf: predictCommandCompletions(for: currentInput))

        // 2. History-based predictions
        predictions.append(contentsOf: predictFromHistory(for: currentInput))

        // 3. Common response predictions
        predictions.append(contentsOf: predictCommonResponses(for: currentInput))

        // Sort by confidence and deduplicate
        let unique = Array(Set(predictions))
        return unique
            .sorted { $0.confidence > $1.confidence }
            .prefix(20)
            .map { $0 }

    }

    /// Pre-renders predictions above confidence threshold
    public func prerender(predictions: [Prediction], renderer: @escaping (String) -> Data?) {
        let toRender = predictions.filter { $0.confidence >= confidenceThreshold }
        predictionsGenerated.wrappingIncrement(by: UInt64(toRender.count), ordering: .relaxed)

        for prediction in toRender {
            renderQueue.async { [weak self] in
                guard let self = self else { return }

                // Skip if already cached
                self.cacheLock.lock()
                let alreadyCached = self.cache[prediction.text] != nil
                self.cacheLock.unlock()

                if alreadyCached { return }

                // Render the prediction
                if let rendered = renderer(prediction.text) {
                    let cached = CachedRender(
                        text: prediction.text,
                        renderedData: rendered,
                        timestamp: CFAbsoluteTimeGetCurrent(),
                        hitCount: 0
                    )

                    self.cacheLock.lock()
                    self.cache[prediction.text] = cached
                    self.evictIfNeeded()
                    self.cacheLock.unlock()
                }
            }
        }
    }

    // MARK: - Cache Access

    /// Checks if text is in pre-render cache
    public func getCached(text: String) -> Data? {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let cached = cache[text] {
            cacheHits.wrappingIncrement(ordering: .relaxed)

            // Update hit count
            cache[text] = CachedRender(
                text: cached.text,
                renderedData: cached.renderedData,
                timestamp: cached.timestamp,
                hitCount: cached.hitCount + 1
            )

            return cached.renderedData
        }

        cacheMisses.wrappingIncrement(ordering: .relaxed)
        return nil
    }

    /// Checks if text is likely cached (without retrieving)
    public func isCached(text: String) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[text] != nil
    }

    // MARK: - Input Tracking

    /// Records user input for pattern learning
    public func recordInput(_ input: String) {
        guard !input.isEmpty else { return }

        recentInput.append(input)
        if recentInput.count > maxRecentInput {
            recentInput.removeFirst()
        }

        // Learn command patterns
        learnCommandPattern(input)
    }

    /// Records terminal output for response pattern learning
    public func recordOutput(_ output: String, forCommand command: String) {
        // Learn what outputs follow what commands
        // Used for predictCommonResponses
        let key = normalizeCommand(command)
        if !output.isEmpty && output.count < 500 {
            commandCompletions[key + "_response"] = [output]
        }
    }

    // MARK: - Private: Prediction Generators

    private func predictCommandCompletions(for input: String) -> [Prediction] {
        var predictions: [Prediction] = []

        // Find matching command prefixes
        for (prefix, completions) in commandCompletions {
            if input.hasPrefix(prefix) || prefix.hasPrefix(input) {
                for completion in completions {
                    let confidence: Float
                    if input == prefix {
                        confidence = 0.8
                    } else if input.hasPrefix(prefix) {
                        confidence = 0.6
                    } else {
                        confidence = 0.4
                    }

                    predictions.append(Prediction(
                        text: completion,
                        confidence: confidence,
                        source: .commonCommands
                    ))
                }
            }
        }

        return predictions
    }

    private func predictFromHistory(for input: String) -> [Prediction] {
        var predictions: [Prediction] = []

        // Find history entries matching input
        let lowercaseInput = input.lowercased()
        for (pattern, count) in historyPatterns {
            if pattern.lowercased().hasPrefix(lowercaseInput) {
                let confidence = min(0.9, Float(count) / 10.0)
                predictions.append(Prediction(
                    text: pattern,
                    confidence: confidence,
                    source: .shellHistory
                ))
            }
        }

        return predictions
    }

    private func predictCommonResponses(for input: String) -> [Prediction] {
        var predictions: [Prediction] = []
        let normalized = normalizeCommand(input)

        // Predict common command outputs
        let commonOutputs: [String: [String]] = [
            "ls": [".", "..", "node_modules", "src", "build", "package.json"],
            "git status": [
                "On branch main",
                "nothing to commit, working tree clean",
                "Changes not staged for commit:"
            ],
            "git branch": ["* main", "  develop", "  feature/"],
            "pwd": ["/Users/", "/home/"],
            "whoami": [NSUserName()],
            "cd": [],  // No output
            "echo": [],  // Variable output
        ]

        if let outputs = commonOutputs[normalized] {
            for output in outputs {
                predictions.append(Prediction(
                    text: output,
                    confidence: 0.5,
                    source: .commonCommands
                ))
            }
        }

        return predictions
    }

    // MARK: - Private: Learning

    private func learnCommandPattern(_ command: String) {
        let normalized = normalizeCommand(command)
        historyPatterns[normalized, default: 0] += 1
    }

    private func normalizeCommand(_ command: String) -> String {
        // Strip arguments for pattern matching
        let parts = command.split(separator: " ", maxSplits: 1)
        return parts.first.map(String.init) ?? command
    }

    // MARK: - Private: Setup

    private func setupCommonCompletions() {
        // Common shell command prefixes and their typical completions
        commandCompletions = [
            "git ": ["git status", "git add .", "git commit -m \"", "git push", "git pull", "git branch", "git checkout "],
            "cd ": ["cd ..", "cd ~", "cd /"],
            "ls": ["ls -la", "ls -lh"],
            "npm ": ["npm install", "npm run ", "npm test", "npm start"],
            "yarn ": ["yarn install", "yarn add ", "yarn dev", "yarn build"],
            "docker ": ["docker ps", "docker images", "docker compose up"],
            "kubectl ": ["kubectl get pods", "kubectl get services", "kubectl logs "],
            "vim ": [],
            "code ": [],
            "cat ": [],
            "grep ": ["grep -r \"", "grep -i "],
            "find ": ["find . -name \""],
            "python ": ["python -m ", "python3 "],
            "swift ": ["swift build", "swift test", "swift run"],
            "make": ["make", "make clean", "make install"],
        ]
    }

    private func loadShellHistory() {
        renderQueue.async { [weak self] in
            guard let self = self else { return }

            // Load zsh history
            let zshHistoryPath = NSHomeDirectory() + "/.zsh_history"
            if let history = try? String(contentsOfFile: zshHistoryPath, encoding: .utf8) {
                self.parseHistory(history)
            }

            // Load bash history
            let bashHistoryPath = NSHomeDirectory() + "/.bash_history"
            if let history = try? String(contentsOfFile: bashHistoryPath, encoding: .utf8) {
                self.parseHistory(history)
            }

            Log.info("PredictiveRenderer: Loaded \(self.historyPatterns.count) history patterns")
        }
    }

    private func parseHistory(_ history: String) {
        let lines = history.split(separator: "\n")
        for line in lines.suffix(500) {  // Last 500 commands
            var command = String(line)

            // Handle zsh extended history format (: timestamp:0;command)
            if command.hasPrefix(": ") {
                if let semicolonIndex = command.firstIndex(of: ";") {
                    command = String(command[command.index(after: semicolonIndex)...])
                }
            }

            // Skip empty or very long commands
            if command.isEmpty || command.count > 200 { continue }

            historyPatterns[command, default: 0] += 1
        }
    }

    // MARK: - Private: Cache Management

    private func evictIfNeeded() {
        guard cache.count > maxCacheSize else { return }

        // Remove least recently used entries
        let sorted = cache.values.sorted { $0.timestamp < $1.timestamp }
        let toRemove = sorted.prefix(cache.count - maxCacheSize / 2)

        for entry in toRemove {
            cache.removeValue(forKey: entry.text)
        }
    }

    /// Clears the entire cache
    public func clearCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }

    // MARK: - Statistics

    public struct Statistics {
        public let cacheSize: Int
        public let cacheHits: UInt64
        public let cacheMisses: UInt64
        public let hitRate: Double
        public let predictionsGenerated: UInt64
    }

    public var statistics: Statistics {
        cacheLock.lock()
        let size = cache.count
        cacheLock.unlock()

        let hits = cacheHits.load(ordering: .relaxed)
        let misses = cacheMisses.load(ordering: .relaxed)
        let total = hits + misses
        let hitRate = total > 0 ? Double(hits) / Double(total) : 0

        return Statistics(
            cacheSize: size,
            cacheHits: hits,
            cacheMisses: misses,
            hitRate: hitRate,
            predictionsGenerated: predictionsGenerated.load(ordering: .relaxed)
        )
    }
}

// MARK: - Input Echo Predictor

/// Specialized predictor for local echo (showing typed characters immediately)
public final class LocalEchoPredictor {

    /// Characters that typically echo immediately in raw mode
    private let echoableCharacters = CharacterSet.alphanumerics
        .union(CharacterSet.punctuationCharacters)
        .union(CharacterSet.symbols)
        .union(CharacterSet(charactersIn: " "))

    /// Current echo buffer
    private var echoBuffer: String = ""

    /// Whether the terminal is in a mode that supports echo
    public var isEchoEnabled: Bool = true

    /// Predicts the echo for a keypress
    public func predictEcho(for character: Character) -> String? {
        guard isEchoEnabled else { return nil }

        // Most printable characters echo directly
        if character.unicodeScalars.allSatisfy({ echoableCharacters.contains($0) }) {
            return String(character)
        }

        // Special cases
        switch character {
        case "\r", "\n":
            return "\r\n"  // Enter typically produces CRLF
        case "\t":
            return nil  // Tab usually triggers completion, not echo
        case "\u{7F}", "\u{08}":  // Delete/Backspace
            return "\u{08} \u{08}"  // Erase character visually
        default:
            return nil
        }
    }

    /// Updates based on actual terminal output
    public func reconcile(actualOutput: String) {
        // Clear echo buffer if output matches our prediction
        if !echoBuffer.isEmpty && actualOutput.contains(echoBuffer) {
            echoBuffer = ""
        }
    }

    /// Clears pending echo predictions
    public func clear() {
        echoBuffer = ""
    }
}
