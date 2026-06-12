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

    private static let cacheLock = NSLock()
    private static var metadataCache: [String: Candidate] = [:]
    /// Bounds the cache: keys are distinct session IDs seen for the process
    /// lifetime, so without a cap the map only ever grows.
    private static let metadataCacheMaxEntries = 256

    static func metadata(
        forSessionID sessionId: String,
        transcriptPath: String? = nil,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Candidate? {
        let normalizedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AIResumeParser.isValidSessionId(normalizedSessionId) else { return nil }

        if transcriptPath == nil {
            cacheLock.lock()
            if let cached = metadataCache[normalizedSessionId] {
                cacheLock.unlock()
                return cached
            }
            cacheLock.unlock()
        }

        let historyProject = latestHistoryProject(
            forSessionID: normalizedSessionId,
            fileManager: fileManager,
            environment: environment
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
        guard candidate.projectDirectory != nil || candidate.transcriptPath != nil else {
            return nil
        }

        if transcriptPath == nil {
            cacheLock.lock()
            if metadataCache.count >= Self.metadataCacheMaxEntries {
                metadataCache.removeAll(keepingCapacity: true)
            }
            metadataCache[normalizedSessionId] = candidate
            cacheLock.unlock()
        }
        return candidate
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
        cacheLock.unlock()
    }

    private static func latestHistoryProject(
        forSessionID sessionId: String,
        fileManager: FileManager,
        environment: [String: String]
    ) -> String? {
        let historyURL = RuntimeIsolation.urlInHome(
            ".claude/history.jsonl",
            fileManager: fileManager,
            environment: environment
        )
        guard let content = try? String(contentsOf: historyURL, encoding: .utf8) else {
            return nil
        }

        var latest: HistoryEntry?
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains(sessionId),
                  let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["sessionId"] as? String == sessionId,
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
            if latest.map({ timestamp >= $0.timestamp }) ?? true {
                latest = HistoryEntry(project: project, timestamp: timestamp)
            }
        }
        return latest?.project
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
