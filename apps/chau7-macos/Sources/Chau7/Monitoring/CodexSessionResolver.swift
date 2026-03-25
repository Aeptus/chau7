import Foundation
import Chau7Core

enum CodexSessionResolver {
    /// Register CWD resolver with TabResolver so Codex events route
    /// through the same generic cwd fallback tier as every other tool.
    static func registerWithTabResolver() {
        TabResolver.registerCWDResolver(forProviderKey: "codex") { dir in
            sessionCandidates(forDirectory: dir).map(\.lastActivity).max()
        }
    }

    struct Candidate: Equatable {
        let sessionId: String
        let cwd: String
        let touchedAt: Date
    }

    private static let cacheLock = NSLock()
    private static var metadataCache: [String: Candidate] = [:]

    static func metadata(
        forSessionID sessionId: String,
        referenceDate: Date? = nil
    ) -> Candidate? {
        let normalizedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AIResumeParser.isValidSessionId(normalizedSessionId) else { return nil }

        cacheLock.lock()
        if let cached = metadataCache[normalizedSessionId] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let fm = FileManager.default
        let sessionsDir = RuntimeIsolation.urlInHome(".codex/sessions", fileManager: fm)

        let candidateDirs = prioritizedDayDirectories(
            in: sessionsDir,
            referenceDate: referenceDate,
            fileManager: fm
        )

        for dayDir in candidateDirs {
            guard let files = try? fm.contentsOfDirectory(atPath: dayDir.path) else { continue }
            let matchingFiles = files
                .filter { $0.hasSuffix(".jsonl") && $0.contains(normalizedSessionId) }
                .sorted()
                .reversed()

            for file in matchingFiles {
                let fileURL = dayDir.appendingPathComponent(file)
                guard let firstLine = readFirstLine(at: fileURL.path),
                      let metadata = parseSessionMeta(firstLine) else {
                    continue
                }
                guard metadata.sessionId == normalizedSessionId else { continue }

                let touchedAt = (
                    try? fm.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
                ) ?? referenceDate ?? Date.distantPast
                let candidate = Candidate(
                    sessionId: metadata.sessionId,
                    cwd: metadata.cwd,
                    touchedAt: touchedAt
                )

                cacheLock.lock()
                metadataCache[normalizedSessionId] = candidate
                cacheLock.unlock()
                return candidate
            }
        }

        return nil
    }

    /// Returns Codex sessions whose cwd matches the given directory, sorted
    /// by most recently modified first.  Mirrors `ClaudeCodeMonitor.sessionCandidates(forDirectory:)`.
    static func sessionCandidates(forDirectory directory: String) -> [(sessionId: String, lastActivity: Date)] {
        let fm = FileManager.default
        let sessionsDir = RuntimeIsolation.urlInHome(".codex/sessions", fileManager: fm)

        let dayDirs = prioritizedDayDirectories(
            in: sessionsDir,
            referenceDate: Date(),
            fileManager: fm
        )

        var results: [(sessionId: String, lastActivity: Date, rank: Int)] = []
        var seenSessionIds = Set<String>()

        for dayDir in dayDirs.prefix(3) {
            guard let files = try? fm.contentsOfDirectory(atPath: dayDir.path) else { continue }
            for file in files.filter({ $0.hasSuffix(".jsonl") }).sorted().reversed() {
                let fileURL = dayDir.appendingPathComponent(file)
                guard let firstLine = readFirstLine(at: fileURL.path),
                      let metadata = parseSessionMeta(firstLine) else { continue }

                guard seenSessionIds.insert(metadata.sessionId).inserted else { continue }
                guard let rank = directoryMatchRank(forDirectory: directory, sessionDirectory: metadata.cwd) else { continue }

                let touchedAt = (
                    try? fm.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
                ) ?? Date.distantPast
                results.append((sessionId: metadata.sessionId, lastActivity: touchedAt, rank: rank))
            }
        }

        guard let bestRank = results.map(\.rank).min() else { return [] }
        return results
            .filter { $0.rank == bestRank }
            .map { (sessionId: $0.sessionId, lastActivity: $0.lastActivity) }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    static func bestMatchingSessionID(
        forDirectory directory: String,
        referenceDate: Date? = nil,
        candidates: [Candidate]
    ) -> String? {
        let matches = deduplicatedCandidates(candidates).compactMap { candidate -> (String, Date, Int)? in
            guard let rank = directoryMatchRank(forDirectory: directory, sessionDirectory: candidate.cwd) else { return nil }
            return (candidate.sessionId, candidate.touchedAt, rank)
        }
        guard let bestRank = matches.map({ $0.2 }).min() else { return nil }
        let rankedCandidates = matches
            .filter { $0.2 == bestRank }
            .map { (sessionId: $0.0, touchedAt: $0.1) }
        return AIResumeParser.bestSessionMatch(candidates: rankedCandidates, referenceDate: referenceDate)
    }

    static func directoryMatchRank(forDirectory directory: String, sessionDirectory: String) -> Int? {
        let target = normalizedSessionDirectory(directory)
        let session = normalizedSessionDirectory(sessionDirectory)
        guard !target.isEmpty, !session.isEmpty else { return nil }
        if target == session {
            return 0
        }
        if target.hasPrefix(session + "/") || session.hasPrefix(target + "/") {
            return 1
        }
        return nil
    }

    private static func deduplicatedCandidates(_ candidates: [Candidate]) -> [Candidate] {
        var bestBySessionId: [String: Candidate] = [:]
        for candidate in candidates {
            if let existing = bestBySessionId[candidate.sessionId] {
                if candidate.touchedAt > existing.touchedAt {
                    bestBySessionId[candidate.sessionId] = candidate
                }
            } else {
                bestBySessionId[candidate.sessionId] = candidate
            }
        }
        return Array(bestBySessionId.values)
    }

    private static func prioritizedDayDirectories(
        in sessionsDir: URL,
        referenceDate: Date?,
        fileManager: FileManager
    ) -> [URL] {
        var ordered: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL) {
            let path = url.path
            guard seen.insert(path).inserted else { return }
            ordered.append(url)
        }

        if let referenceDate {
            for dayOffset in [0, -1, 1] {
                if let url = dayDirectory(
                    for: referenceDate.addingTimeInterval(Double(dayOffset) * 86400),
                    under: sessionsDir
                ) {
                    append(url)
                }
            }
        }

        for url in recentDayDirectories(in: sessionsDir, fileManager: fileManager, limit: 14) {
            append(url)
        }

        return ordered
    }

    private static func dayDirectory(for date: Date, under sessionsDir: URL) -> URL? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return nil
        }

        return sessionsDir
            .appendingPathComponent(String(format: "%04d", year))
            .appendingPathComponent(String(format: "%02d", month))
            .appendingPathComponent(String(format: "%02d", day))
    }

    private static func recentDayDirectories(
        in sessionsDir: URL,
        fileManager: FileManager,
        limit: Int
    ) -> [URL] {
        let isDateComponent = { (name: String) in
            !name.isEmpty && name.allSatisfy(\.isNumber)
        }

        guard let years = try? fileManager.contentsOfDirectory(atPath: sessionsDir.path) else {
            return []
        }

        var dayDirs: [URL] = []
        for year in years.filter(isDateComponent).sorted().reversed() {
            let yearURL = sessionsDir.appendingPathComponent(year)
            guard let months = try? fileManager.contentsOfDirectory(atPath: yearURL.path) else { continue }
            for month in months.filter(isDateComponent).sorted().reversed() {
                let monthURL = yearURL.appendingPathComponent(month)
                guard let days = try? fileManager.contentsOfDirectory(atPath: monthURL.path) else { continue }
                for day in days.filter(isDateComponent).sorted().reversed() {
                    dayDirs.append(monthURL.appendingPathComponent(day))
                    if dayDirs.count >= limit {
                        return dayDirs
                    }
                }
            }
        }

        return dayDirs
    }

    private static func readFirstLine(at path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        let chunkSize = 4096
        let maxLineBytes = 262_144
        var buffer = Data()

        while buffer.count < maxLineBytes {
            let chunk = handle.readData(ofLength: chunkSize)
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)

            if let newlineIndex = buffer.firstIndex(of: 10) {
                buffer = Data(buffer.prefix(upTo: newlineIndex))
                break
            }
        }

        guard !buffer.isEmpty, buffer.count <= maxLineBytes else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }

    private static func parseSessionMeta(_ line: String) -> (cwd: String, sessionId: String)? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String, type == "session_meta",
              let payload = json["payload"] as? [String: Any],
              let cwd = payload["cwd"] as? String,
              let id = payload["id"] as? String else {
            return nil
        }

        let normalizedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCwd.isEmpty, AIResumeParser.isValidSessionId(normalizedId) else {
            return nil
        }

        return (cwd: normalizedCwd, sessionId: normalizedId)
    }

    private static func normalizedSessionDirectory(_ directory: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let expanded = RuntimeIsolation.expandTilde(in: trimmed)
        return URL(fileURLWithPath: expanded).standardized.path
    }

}
