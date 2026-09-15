import Foundation
import Chau7Core

enum ClaudeSessionResolver {
    struct Candidate: Equatable {
        let sessionId: String
        let projectDirectory: String?
        let transcriptPath: String?
    }

    private struct HistoryEntry {
        let project: String
        let timestamp: TimeInterval
    }

    /// A cheap identity for the two Claude stores consulted during restore.
    /// Autosave asks about many sessions in one pass; using the file metadata
    /// as the cache generation lets us retain negative lookups without ever
    /// hiding a newly-written history entry or transcript directory.
    private struct FileFingerprint: Equatable {
        let size: UInt64
        let modificationDate: Date
        let fileNumber: UInt64?
    }

    private struct MetadataCacheContext: Equatable {
        let history: FileFingerprint?
        let projects: FileFingerprint?
    }

    private struct MetadataCacheEntry {
        let context: MetadataCacheContext
        let candidate: Candidate?
        let negativeCacheExpiry: Date?
    }

    private struct HistoryIndex {
        let fingerprint: FileFingerprint
        let entries: [String: HistoryEntry]
    }

    private static let cacheLock = NSLock()
    private static var metadataCache: [String: MetadataCacheEntry] = [:]
    private static var historyIndexCache: [String: HistoryIndex] = [:]
    /// Bounds the caches: keys are distinct session IDs and history paths seen
    /// for the process lifetime, so without a cap the maps only ever grow.
    private static let metadataCacheMaxEntries = 256
    private static let historyIndexCacheMaxEntries = 4
    private static let negativeMetadataCacheTTL: TimeInterval = 2

    static func metadata(
        forSessionID sessionId: String,
        transcriptPath: String? = nil,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Candidate? {
        let normalizedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AIResumeParser.isValidSessionId(normalizedSessionId) else { return nil }

        let cacheContext: MetadataCacheContext?
        if transcriptPath == nil {
            cacheContext = metadataCacheContext(fileManager: fileManager, environment: environment)
            cacheLock.lock()
            let cached = metadataCache[normalizedSessionId]
            cacheLock.unlock()
            if let cached,
               cached.context == cacheContext,
               cached.candidate != nil || cached.negativeCacheExpiry.map({ $0 > Date() }) == true {
                // A transcript can be removed without changing either store's
                // directory metadata. Do not let a cached positive result turn
                // that removal into a false restore candidate.
                if let transcriptPath = cached.candidate?.transcriptPath,
                   !fileManager.fileExists(atPath: transcriptPath) {
                    cacheLock.lock()
                    metadataCache.removeValue(forKey: normalizedSessionId)
                    cacheLock.unlock()
                } else {
                    return cached.candidate
                }
            }
        } else {
            cacheContext = nil
        }

        let historyProject = latestHistoryProject(
            forSessionID: normalizedSessionId,
            fileManager: fileManager,
            environment: environment,
            fingerprint: cacheContext?.history
        )
        let historyTranscript = historyProject.flatMap {
            transcriptPathForProject(
                sessionId: normalizedSessionId,
                projectDirectory: $0,
                fileManager: fileManager,
                environment: environment
            )
        }
        let eventTranscript = usableTranscriptPath(
            transcriptPath,
            sessionId: normalizedSessionId,
            fileManager: fileManager
        )
        let scannedTranscript = historyTranscript == nil && eventTranscript == nil
            ? scanTranscriptPath(
                forSessionID: normalizedSessionId,
                fileManager: fileManager,
                environment: environment
            )
            : nil

        let candidate = Candidate(
            sessionId: normalizedSessionId,
            projectDirectory: historyProject,
            transcriptPath: historyTranscript ?? eventTranscript ?? scannedTranscript
        )

        if transcriptPath == nil, let cacheContext {
            cacheLock.lock()
            if metadataCache.count >= Self.metadataCacheMaxEntries {
                metadataCache.removeAll(keepingCapacity: true)
            }
            metadataCache[normalizedSessionId] = MetadataCacheEntry(
                context: cacheContext,
                candidate: candidate.projectDirectory != nil || candidate.transcriptPath != nil ? candidate : nil,
                negativeCacheExpiry: candidate.projectDirectory != nil || candidate.transcriptPath != nil
                    ? nil
                    : Date().addingTimeInterval(Self.negativeMetadataCacheTTL)
            )
            cacheLock.unlock()
        }
        return candidate.projectDirectory != nil || candidate.transcriptPath != nil ? candidate : nil
    }

    /// Reverse lookup: given a saved working directory, list every
    /// candidate session ID Claude has a transcript for, ranked by
    /// transcript file mtime (newest first). Used by the restore pipeline
    /// to recover a real `--resume <id>` command for tabs that were
    /// autosaved with a synthetic identity (no real session ID yet) —
    /// without it, `buildAIResumeCommand` returns nil for synthetic
    /// sources and nothing gets prefilled on restart.
    ///
    /// Scans `~/.claude/projects/<dir-as-dashes>/<sessionId>.jsonl` —
    /// the canonical layout Claude writes to on disk. Sessions whose
    /// session ID would be rejected by `AIResumeParser.isValidSessionId`
    /// (e.g. shell-metacharacter contamination) are filtered out so the
    /// resulting command is always safe to feed to `isSafeResumeCommand`.
    static func sessionCandidates(
        forDirectory directory: String,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [(sessionId: String, lastActivity: Date)] {
        let projectsRoot = RuntimeIsolation.urlInHome(
            ".claude/projects",
            fileManager: fileManager,
            environment: environment
        )
        let projectDirName = normalizedSessionDirectory(directory)
            .replacingOccurrences(of: "/", with: "-")
        guard !projectDirName.isEmpty else { return [] }
        let projectDir = projectsRoot.appendingPathComponent(projectDirName, isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(atPath: projectDir.path) else {
            return []
        }
        var results: [(sessionId: String, lastActivity: Date)] = []
        for file in files {
            guard file.hasSuffix(".jsonl") else { continue }
            let sessionId = String(file.dropLast(".jsonl".count))
            guard AIResumeParser.isValidSessionId(sessionId) else { continue }
            let path = projectDir.appendingPathComponent(file).path
            let touchedAt = (
                try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date
            ) ?? Date.distantPast
            results.append((sessionId: sessionId, lastActivity: touchedAt))
        }
        return results.sorted { $0.lastActivity > $1.lastActivity }
    }

    static func restoreDirectory(
        forSessionID sessionId: String,
        savedDirectory: String,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let metadata = metadata(
            forSessionID: sessionId,
            fileManager: fileManager,
            environment: environment
        ),
            let projectDirectory = metadata.projectDirectory,
            isProjectDirectory(projectDirectory, relatedToSavedDirectory: savedDirectory),
            directoryExists(projectDirectory, fileManager: fileManager)
        else {
            return nil
        }
        return projectDirectory
    }

    static func hasRestorableTranscript(
        sessionId: String,
        savedDirectory: String,
        transcriptPath: String? = nil,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let normalizedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AIResumeParser.isValidSessionId(normalizedSessionId) else { return false }

        if exactTranscriptExists(
            sessionId: normalizedSessionId,
            projectDirectory: savedDirectory,
            fileManager: fileManager,
            environment: environment
        ) {
            return true
        }

        guard let metadata = metadata(
            forSessionID: normalizedSessionId,
            transcriptPath: transcriptPath,
            fileManager: fileManager,
            environment: environment
        ) else {
            return false
        }
        guard metadata.transcriptPath != nil else { return false }
        guard let projectDirectory = metadata.projectDirectory else {
            return true
        }
        return isProjectDirectory(projectDirectory, relatedToSavedDirectory: savedDirectory)
    }

    static func canAdoptSessionID(
        _ sessionId: String,
        transcriptPath: String?,
        cwd: String,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        hasRestorableTranscript(
            sessionId: sessionId,
            savedDirectory: cwd,
            transcriptPath: transcriptPath,
            fileManager: fileManager,
            environment: environment
        )
    }

    static func clearCache() {
        cacheLock.lock()
        metadataCache.removeAll()
        historyIndexCache.removeAll()
        cacheLock.unlock()
    }

    private static func metadataCacheContext(
        fileManager: FileManager,
        environment: [String: String]
    ) -> MetadataCacheContext {
        let historyURL = RuntimeIsolation.urlInHome(
            ".claude/history.jsonl",
            fileManager: fileManager,
            environment: environment
        )
        let projectsURL = RuntimeIsolation.urlInHome(
            ".claude/projects",
            fileManager: fileManager,
            environment: environment
        )
        return MetadataCacheContext(
            history: fileFingerprint(at: historyURL.path, fileManager: fileManager),
            projects: fileFingerprint(at: projectsURL.path, fileManager: fileManager)
        )
    }

    private static func fileFingerprint(
        at path: String,
        fileManager: FileManager
    ) -> FileFingerprint? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modificationDate = attributes[.modificationDate] as? Date else {
            return nil
        }
        return FileFingerprint(
            size: size,
            modificationDate: modificationDate,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    private static func latestHistoryProject(
        forSessionID sessionId: String,
        fileManager: FileManager,
        environment: [String: String],
        fingerprint suppliedFingerprint: FileFingerprint? = nil
    ) -> String? {
        let historyURL = RuntimeIsolation.urlInHome(
            ".claude/history.jsonl",
            fileManager: fileManager,
            environment: environment
        )
        let fingerprint = suppliedFingerprint ?? fileFingerprint(
            at: historyURL.path,
            fileManager: fileManager
        )
        if let fingerprint {
            cacheLock.lock()
            if let cached = historyIndexCache[historyURL.path], cached.fingerprint == fingerprint {
                let project = cached.entries[sessionId]?.project
                cacheLock.unlock()
                return project
            }
            cacheLock.unlock()
        }
        guard let content = try? String(contentsOf: historyURL, encoding: .utf8) else {
            return nil
        }

        var entries: [String: HistoryEntry] = [:]
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let data = Data(line.utf8)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let historySessionId = json["sessionId"] as? String,
                  let project = (json["project"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !project.isEmpty else {
                continue
            }
            let timestamp: TimeInterval
            if let number = json["timestamp"] as? NSNumber {
                timestamp = number.doubleValue
            } else if let value = json["timestamp"] as? TimeInterval {
                timestamp = value
            } else {
                timestamp = 0
            }
            if entries[historySessionId].map({ timestamp >= $0.timestamp }) ?? true {
                entries[historySessionId] = HistoryEntry(project: project, timestamp: timestamp)
            }
        }
        if let fingerprint {
            cacheLock.lock()
            if historyIndexCache.count >= Self.historyIndexCacheMaxEntries {
                historyIndexCache.removeAll(keepingCapacity: true)
            }
            historyIndexCache[historyURL.path] = HistoryIndex(
                fingerprint: fingerprint,
                entries: entries
            )
            cacheLock.unlock()
        }
        return entries[sessionId]?.project
    }

    private static func transcriptPathForProject(
        sessionId: String,
        projectDirectory: String,
        fileManager: FileManager,
        environment: [String: String]
    ) -> String? {
        let projectsRoot = RuntimeIsolation.urlInHome(
            ".claude/projects",
            fileManager: fileManager,
            environment: environment
        )
        let projectDirName = normalizedSessionDirectory(projectDirectory)
            .replacingOccurrences(of: "/", with: "-")
        guard !projectDirName.isEmpty else { return nil }
        let projectDir = projectsRoot.appendingPathComponent(projectDirName, isDirectory: true)
        let transcriptFile = projectDir.appendingPathComponent("\(sessionId).jsonl")
        if fileManager.fileExists(atPath: transcriptFile.path) {
            return transcriptFile.path
        }
        let transcriptDir = projectDir.appendingPathComponent(sessionId, isDirectory: true)
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: transcriptDir.path, isDirectory: &isDir),
           isDir.boolValue {
            return transcriptDir.path
        }
        return nil
    }

    private static func exactTranscriptExists(
        sessionId: String,
        projectDirectory: String,
        fileManager: FileManager,
        environment: [String: String]
    ) -> Bool {
        transcriptPathForProject(
            sessionId: sessionId,
            projectDirectory: projectDirectory,
            fileManager: fileManager,
            environment: environment
        ) != nil
    }

    private static func usableTranscriptPath(
        _ transcriptPath: String?,
        sessionId: String,
        fileManager: FileManager
    ) -> String? {
        guard let trimmed = transcriptPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: trimmed)
        let lastComponent = url.lastPathComponent
        guard lastComponent == "\(sessionId).jsonl" || lastComponent == sessionId else {
            return nil
        }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return nil
        }
        return url.path
    }

    private static func scanTranscriptPath(
        forSessionID sessionId: String,
        fileManager: FileManager,
        environment: [String: String]
    ) -> String? {
        let projectsRoot = RuntimeIsolation.urlInHome(
            ".claude/projects",
            fileManager: fileManager,
            environment: environment
        )
        guard let projectNames = try? fileManager.contentsOfDirectory(atPath: projectsRoot.path) else {
            return nil
        }
        for projectName in projectNames.sorted() {
            let projectDir = projectsRoot.appendingPathComponent(projectName, isDirectory: true)
            let transcriptFile = projectDir.appendingPathComponent("\(sessionId).jsonl")
            if fileManager.fileExists(atPath: transcriptFile.path) {
                return transcriptFile.path
            }
            let transcriptDir = projectDir.appendingPathComponent(sessionId, isDirectory: true)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: transcriptDir.path, isDirectory: &isDir),
               isDir.boolValue {
                return transcriptDir.path
            }
        }
        return nil
    }

    private static func isProjectDirectory(_ projectDirectory: String, relatedToSavedDirectory savedDirectory: String) -> Bool {
        DirectoryPathMatcher.bidirectionalPrefixRank(
            targetPath: normalizedSessionDirectory(savedDirectory),
            candidatePath: normalizedSessionDirectory(projectDirectory)
        ) != nil
    }

    private static func directoryExists(_ path: String, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func normalizedSessionDirectory(_ directory: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let expanded = RuntimeIsolation.expandTilde(in: trimmed)
        return URL(fileURLWithPath: expanded).standardized.path
    }
}
