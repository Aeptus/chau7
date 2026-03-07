import Foundation
import Chau7Core

/// Syncs SSH profiles between ~/.ssh/config and Chau7's SSH connection manager.
/// Watches the config file for changes and auto-imports new hosts.
@MainActor
final class SharedSSHProfileManager: ObservableObject {
    static let shared = SharedSSHProfileManager()

    @Published var configEntries: [SSHConfigEntry] = []
    @Published var isWatching = false
    @Published var lastSyncTime: Date?

    private var fileMonitorSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    private var sshConfigPath: String {
        NSHomeDirectory() + "/.ssh/config"
    }

    private init() {
        loadSSHConfig()
        startWatching()
        Log.info("SharedSSHProfileManager initialized: \(configEntries.count) entries")
    }

    deinit {
        fileMonitorSource?.cancel()
        fileMonitorSource = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    // MARK: - Load/Parse

    func loadSSHConfig() {
        guard let content = try? String(contentsOfFile: sshConfigPath, encoding: .utf8) else {
            Log.info("SharedSSHProfileManager: no SSH config found at \(sshConfigPath)")
            return
        }

        configEntries = SSHConfigParser.parse(content)
        lastSyncTime = Date()
        Log.info("SharedSSHProfileManager: loaded \(configEntries.count) SSH config entries")
    }

    // MARK: - Import to Chau7

    func importEntry(_ entry: SSHConfigEntry) -> SSHConnection {
        let connection = SSHConnection(
            name: entry.host,
            host: entry.hostname ?? entry.host,
            port: entry.port ?? 22,
            user: entry.user ?? "",
            identityFile: entry.identityFile ?? "",
            jumpHost: entry.proxyJump ?? ""
        )
        Log.info("SharedSSHProfileManager: imported '\(entry.host)' as SSHConnection")
        return connection
    }

    func importAllEntries() -> [SSHConnection] {
        let connections = configEntries
            .filter { !$0.host.contains("*") } // Skip wildcard entries
            .map { importEntry($0) }
        Log.info("SharedSSHProfileManager: imported \(connections.count) connections")
        return connections
    }

    // MARK: - Export from Chau7

    func exportConnection(_ connection: SSHConnection) -> SSHConfigEntry {
        SSHConfigEntry(
            host: connection.name.isEmpty ? connection.host : connection.name,
            hostname: connection.host,
            user: connection.user.isEmpty ? nil : connection.user,
            port: connection.port != 22 ? connection.port : nil,
            identityFile: connection.identityFile.isEmpty ? nil : connection.identityFile,
            proxyJump: connection.jumpHost.isEmpty ? nil : connection.jumpHost
        )
    }

    func appendToSSHConfig(_ entry: SSHConfigEntry) {
        let serialized = SSHConfigParser.serialize([entry])
        guard let data = ("\n" + serialized).data(using: .utf8) else { return }

        if let handle = FileHandle(forWritingAtPath: sshConfigPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
            Log.info("SharedSSHProfileManager: appended '\(entry.host)' to SSH config")
        }
    }

    // MARK: - File Watching

    func startWatching() {
        guard !isWatching else { return }

        fileDescriptor = open(sshConfigPath, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            Log.warn("SharedSSHProfileManager: cannot watch \(sshConfigPath)")
            return
        }

        // Capture fd by value so cancel handler closes the correct descriptor.
        let fd = fileDescriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename],
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                self?.loadSSHConfig()
            }
        }

        source.setCancelHandler { [weak self] in
            close(fd)
            self?.fileDescriptor = -1
        }

        source.resume()
        fileMonitorSource = source
        isWatching = true
        Log.info("SharedSSHProfileManager: watching \(sshConfigPath)")
    }

    func stopWatching() {
        if let source = fileMonitorSource {
            source.cancel()
            fileMonitorSource = nil
        } else if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        isWatching = false
    }
}
