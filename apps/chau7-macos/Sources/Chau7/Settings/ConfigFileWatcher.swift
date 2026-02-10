import Foundation
import Chau7Core

/// Watches for .chau7 config files and applies them.
/// Checks two locations:
/// 1. ~/.chau7/config.toml (global config)
/// 2. .chau7/config.toml (per-repo config, relative to working directory)
///
/// Per-repo config overrides global config.
@MainActor
final class ConfigFileWatcher: ObservableObject {
    static let shared = ConfigFileWatcher()

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "feature.configFile") }
    }
    @Published var globalConfig: Chau7ConfigFile?
    @Published var repoConfig: Chau7ConfigFile?
    @Published var lastLoadTime: Date?
    @Published var lastError: String?

    private var fileMonitorSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    private var globalConfigPath: String {
        NSHomeDirectory() + "/.chau7/config.toml"
    }

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: "feature.configFile") as? Bool ?? true
        if isEnabled {
            loadGlobalConfig()
            startWatching()
        }
        Log.info("ConfigFileWatcher initialized: enabled=\(isEnabled)")
    }

    deinit {
        fileMonitorSource?.cancel()
        fileMonitorSource = nil
    }

    // MARK: - Load

    func loadGlobalConfig() {
        guard let content = try? String(contentsOfFile: globalConfigPath, encoding: .utf8) else {
            Log.info("ConfigFileWatcher: no global config at \(globalConfigPath)")
            return
        }
        globalConfig = ConfigFileParser.parse(content)
        lastLoadTime = Date()
        lastError = nil
        Log.info("ConfigFileWatcher: loaded global config")
    }

    func loadRepoConfig(directory: String) {
        let repoPath = (directory as NSString).appendingPathComponent(".chau7/config.toml")
        guard let content = try? String(contentsOfFile: repoPath, encoding: .utf8) else {
            repoConfig = nil
            return
        }
        repoConfig = ConfigFileParser.parse(content)
        Log.info("ConfigFileWatcher: loaded repo config from \(repoPath)")
    }

    // MARK: - Apply

    /// Applies the merged config (global + repo overrides) to FeatureSettings
    func applyConfig() {
        guard isEnabled else { return }
        let settings = FeatureSettings.shared

        // Apply global first, then repo overrides
        if let global = globalConfig {
            applyConfigToSettings(global, settings: settings)
        }
        if let repo = repoConfig {
            applyConfigToSettings(repo, settings: settings)
        }

        Log.info("ConfigFileWatcher: applied merged config")
    }

    private func applyConfigToSettings(_ config: Chau7ConfigFile, settings: FeatureSettings) {
        if let g = config.general {
            if let v = g.startupCommand { settings.startupCommand = v }
            if let v = g.defaultDirectory { settings.defaultStartDirectory = v }
        }

        if let a = config.appearance {
            if let v = a.fontFamily { settings.fontFamily = v }
            if let v = a.fontSize { settings.fontSize = v }
            if let v = a.colorScheme { settings.colorSchemeName = v }
            if let v = a.cursorStyle { settings.cursorStyle = v }
            if let v = a.cursorBlink { settings.cursorBlink = v }
        }

        if let t = config.terminal {
            if let v = t.scrollbackLines { settings.scrollbackLines = v }
            if let v = t.bellEnabled { settings.bellEnabled = v }
            if let v = t.bellSound { settings.bellSound = v }
        }
    }

    // MARK: - Scaffold

    /// Creates a default config file at ~/.chau7/config.toml
    func createDefaultConfig() {
        let dir = (globalConfigPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let defaultConfig = Chau7ConfigFile(
            general: .init(shell: nil, startupCommand: nil, defaultDirectory: nil),
            appearance: .init(fontFamily: "Menlo", fontSize: 13, cursorStyle: "block"),
            terminal: .init(scrollbackLines: 10000, bellEnabled: true)
        )

        let content = ConfigFileParser.serialize(defaultConfig)
        try? content.write(toFile: globalConfigPath, atomically: true, encoding: .utf8)
        Log.info("ConfigFileWatcher: created default config at \(globalConfigPath)")
    }

    // MARK: - File Watching

    func startWatching() {
        let path = globalConfigPath
        guard FileManager.default.fileExists(atPath: path) else { return }

        fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        // Capture fd by value so cancel handler closes the correct descriptor.
        let fd = fileDescriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename],
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                self?.loadGlobalConfig()
                self?.applyConfig()
            }
        }

        source.setCancelHandler { [weak self] in
            close(fd)
            self?.fileDescriptor = -1
        }

        source.resume()
        fileMonitorSource = source
        Log.info("ConfigFileWatcher: watching \(path)")
    }

    func stopWatching() {
        if let source = fileMonitorSource {
            source.cancel()
            fileMonitorSource = nil
        } else if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }
}
