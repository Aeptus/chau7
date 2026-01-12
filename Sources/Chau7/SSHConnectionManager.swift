import SwiftUI
import AppKit
import Chau7Core

// MARK: - SSH Connection Model

struct SSHConnection: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var user: String
    var identityFile: String
    var jumpHost: String  // ProxyJump / bastion host
    var extraOptions: String  // Additional SSH options
    var colorTag: String  // Tab color when connecting
    var lastConnected: Date?

    init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 22,
        user: String = "",
        identityFile: String = "",
        jumpHost: String = "",
        extraOptions: String = "",
        colorTag: String = "blue",
        lastConnected: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.identityFile = identityFile
        self.jumpHost = jumpHost
        self.extraOptions = extraOptions
        self.colorTag = colorTag
        self.lastConnected = lastConnected
    }

    var displayName: String {
        if !name.isEmpty { return name }
        if !user.isEmpty { return "\(user)@\(host)" }
        return host
    }

    var sshCommand: String {
        var parts = ["ssh"]

        if port != 22 {
            parts.append("-p \(port)")
        }

        if !identityFile.isEmpty {
            let expanded = (identityFile as NSString).expandingTildeInPath
            // Use proper shell escaping for identity file path
            parts.append("-i \(ShellEscaping.escapePath(expanded))")
        }

        if !jumpHost.isEmpty {
            // Use proper shell escaping for jump host
            parts.append("-J \(ShellEscaping.escapeArgument(jumpHost))")
        }

        if !extraOptions.isEmpty {
            // Validate extra options before including them
            let validation = ShellEscaping.validateSSHOptions(extraOptions)
            if validation.isValid {
                parts.append(extraOptions)
            }
            // If invalid, skip the extra options silently for security
        }

        if !user.isEmpty {
            parts.append("\(user)@\(host)")
        } else {
            parts.append(host)
        }

        return parts.joined(separator: " ")
    }

    /// Validates the extra SSH options for security
    var extraOptionsValidation: ShellEscaping.SSHValidationResult {
        ShellEscaping.validateSSHOptions(extraOptions)
    }
}

// MARK: - SSH Connection Manager

final class SSHConnectionManager: ObservableObject {
    static let shared = SSHConnectionManager()

    @Published var connections: [SSHConnection] = []
    @Published var folders: [String] = []  // For organizing connections

    private let storageKey = "ssh.connections"
    private let foldersKey = "ssh.folders"

    private init() {
        loadConnections()
    }

    func loadConnections() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = JSONOperations.decode([SSHConnection].self, from: data, context: "SSH connections") {
            connections = decoded
        }
        folders = UserDefaults.standard.stringArray(forKey: foldersKey) ?? []
    }

    func saveConnections() {
        if let encoded = JSONOperations.encode(connections, context: "SSH connections") {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        } else {
            Log.error("Failed to save SSH connections - encoding failed")
        }
        UserDefaults.standard.set(folders, forKey: foldersKey)
    }

    func addConnection(_ connection: SSHConnection) {
        connections.append(connection)
        saveConnections()
        Log.info("SSH: Added connection '\(connection.displayName)'")
    }

    func updateConnection(_ connection: SSHConnection) {
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
            saveConnections()
            Log.info("SSH: Updated connection '\(connection.displayName)'")
        }
    }

    func deleteConnection(_ connection: SSHConnection) {
        connections.removeAll { $0.id == connection.id }
        saveConnections()
        Log.info("SSH: Deleted connection '\(connection.displayName)'")
    }

    func markConnected(_ connection: SSHConnection) {
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index].lastConnected = Date()
            saveConnections()
        }
    }

    var recentConnections: [SSHConnection] {
        connections
            .filter { $0.lastConnected != nil }
            .sorted { ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast) }
            .prefix(5)
            .map { $0 }
    }

    // Import from ~/.ssh/config
    func importFromSSHConfig() -> Int {
        let configPath = (("~/.ssh/config" as NSString).expandingTildeInPath)
        guard let content = FileOperations.readString(from: configPath) else {
            return 0
        }

        var imported = 0
        var currentHost: SSHConnection?

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let key = String(parts[0]).lowercased()
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "host":
                // Save previous host if exists
                if let host = currentHost, !host.host.isEmpty {
                    if !connections.contains(where: { $0.host == host.host && $0.user == host.user }) {
                        addConnection(host)
                        imported += 1
                    }
                }
                // Start new host
                currentHost = SSHConnection(name: value)
            case "hostname":
                currentHost?.host = value
            case "user":
                currentHost?.user = value
            case "port":
                currentHost?.port = Int(value) ?? 22
            case "identityfile":
                currentHost?.identityFile = value
            case "proxyjump":
                currentHost?.jumpHost = value
            default:
                break
            }
        }

        // Save last host
        if let host = currentHost, !host.host.isEmpty {
            if !connections.contains(where: { $0.host == host.host && $0.user == host.user }) {
                addConnection(host)
                imported += 1
            }
        }

        Log.info("SSH: Imported \(imported) connections from ~/.ssh/config")
        return imported
    }
}

// MARK: - SSH Connection View

struct SSHConnectionView: View {
    @ObservedObject private var manager = SSHConnectionManager.shared
    @State private var selectedConnection: SSHConnection?
    @State private var isEditing = false
    @State private var editingConnection: SSHConnection?
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    let onConnect: (SSHConnection) -> Void

    private var filteredConnections: [SSHConnection] {
        if searchText.isEmpty {
            return manager.connections.sorted { $0.displayName < $1.displayName }
        }
        let query = searchText.lowercased()
        return manager.connections.filter {
            $0.displayName.lowercased().contains(query) ||
            $0.host.lowercased().contains(query) ||
            $0.user.lowercased().contains(query)
        }.sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        HSplitView {
            // Connection list
            VStack(spacing: 0) {
                // Search
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search connections...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))

                Divider()

                // Recent connections
                if searchText.isEmpty && !manager.recentConnections.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Recent")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)

                        ForEach(manager.recentConnections) { connection in
                            ConnectionRow(
                                connection: connection,
                                isSelected: selectedConnection?.id == connection.id
                            )
                            .onTapGesture {
                                selectedConnection = connection
                            }
                            .onTapGesture(count: 2) {
                                connect(to: connection)
                            }
                        }

                        Divider()
                            .padding(.vertical, 4)
                    }
                }

                // All connections
                List(filteredConnections, selection: $selectedConnection) { connection in
                    ConnectionRow(
                        connection: connection,
                        isSelected: selectedConnection?.id == connection.id
                    )
                    .tag(connection)
                    .onTapGesture(count: 2) {
                        connect(to: connection)
                    }
                    .contextMenu {
                        Button("Connect") { connect(to: connection) }
                        Button("Edit...") { editConnection(connection) }
                        Divider()
                        Button("Duplicate") { duplicateConnection(connection) }
                        Button("Delete", role: .destructive) { deleteConnection(connection) }
                    }
                }
                .listStyle(.sidebar)

                Divider()

                // Toolbar
                HStack {
                    Button {
                        createNewConnection()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .help("Add Connection")

                    Button {
                        if let selected = selectedConnection {
                            deleteConnection(selected)
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedConnection == nil)
                    .help("Remove Connection")

                    Spacer()

                    Menu {
                        Button("Import from ~/.ssh/config") {
                            let count = manager.importFromSSHConfig()
                            if count > 0 {
                                // Show success message
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 30)
                }
                .padding(8)
            }
            .frame(minWidth: 220, maxWidth: 300)

            // Detail view
            VStack {
                if let connection = selectedConnection {
                    ConnectionDetailView(
                        connection: connection,
                        onConnect: { connect(to: connection) },
                        onEdit: { editConnection(connection) }
                    )
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No Connection Selected")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Select a connection from the list or create a new one.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 350)
        }
        .frame(minWidth: 600, minHeight: 400)
        .sheet(isPresented: $isEditing) {
            if let connection = editingConnection {
                ConnectionEditorView(
                    connection: connection,
                    isNew: !manager.connections.contains(where: { $0.id == connection.id }),
                    onSave: { updated in
                        if manager.connections.contains(where: { $0.id == updated.id }) {
                            manager.updateConnection(updated)
                        } else {
                            manager.addConnection(updated)
                        }
                        selectedConnection = updated
                        isEditing = false
                    },
                    onCancel: {
                        isEditing = false
                    }
                )
            }
        }
    }

    private func connect(to connection: SSHConnection) {
        manager.markConnected(connection)
        onConnect(connection)
        dismiss()
    }

    private func createNewConnection() {
        editingConnection = SSHConnection()
        isEditing = true
    }

    private func editConnection(_ connection: SSHConnection) {
        editingConnection = connection
        isEditing = true
    }

    private func duplicateConnection(_ connection: SSHConnection) {
        var duplicate = connection
        duplicate.id = UUID()
        duplicate.name = connection.name + " (Copy)"
        duplicate.lastConnected = nil
        manager.addConnection(duplicate)
        selectedConnection = duplicate
    }

    private func deleteConnection(_ connection: SSHConnection) {
        manager.deleteConnection(connection)
        if selectedConnection?.id == connection.id {
            selectedConnection = nil
        }
    }
}

// MARK: - Connection Row

private struct ConnectionRow: View {
    let connection: SSHConnection
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 16))
                .foregroundColor(colorForTag(connection.colorTag))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(connection.displayName)
                    .font(.system(size: 13))
                    .lineLimit(1)

                if !connection.name.isEmpty {
                    Text(connection.host)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("SSH connection: \(connection.displayName), host: \(connection.host)")
        .accessibilityHint("Double-tap to connect")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func colorForTag(_ tag: String) -> Color {
        switch tag {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        default: return .blue
        }
    }
}

// MARK: - Connection Detail View

private struct ConnectionDetailView: View {
    let connection: SSHConnection
    let onConnect: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack {
                Image(systemName: "server.rack")
                    .font(.system(size: 32))
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading) {
                    Text(connection.displayName)
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text(connection.host)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Connect") {
                    onConnect()
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            // Details
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Host:")
                        .foregroundColor(.secondary)
                    Text(connection.host)
                        .textSelection(.enabled)
                }

                GridRow {
                    Text("Port:")
                        .foregroundColor(.secondary)
                    Text("\(connection.port)")
                }

                if !connection.user.isEmpty {
                    GridRow {
                        Text("User:")
                            .foregroundColor(.secondary)
                        Text(connection.user)
                            .textSelection(.enabled)
                    }
                }

                if !connection.identityFile.isEmpty {
                    GridRow {
                        Text("Identity:")
                            .foregroundColor(.secondary)
                        Text(connection.identityFile)
                            .textSelection(.enabled)
                    }
                }

                if !connection.jumpHost.isEmpty {
                    GridRow {
                        Text("Jump Host:")
                            .foregroundColor(.secondary)
                        Text(connection.jumpHost)
                            .textSelection(.enabled)
                    }
                }

                if let lastConnected = connection.lastConnected {
                    GridRow {
                        Text("Last Connected:")
                            .foregroundColor(.secondary)
                        Text(lastConnected, style: .relative)
                    }
                }
            }
            .font(.system(size: 13))

            Divider()

            // Command preview
            VStack(alignment: .leading, spacing: 8) {
                Text("SSH Command")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                Text(connection.sshCommand)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
            }

            Spacer()

            // Footer
            HStack {
                Button("Edit...") {
                    onEdit()
                }

                Spacer()
            }
        }
        .padding(20)
    }
}

// MARK: - Connection Editor View

private struct ConnectionEditorView: View {
    @State var connection: SSHConnection
    let isNew: Bool
    let onSave: (SSHConnection) -> Void
    let onCancel: () -> Void

    private let colorOptions = ["blue", "green", "orange", "red", "purple", "pink", "yellow"]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isNew ? "New Connection" : "Edit Connection")
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Form
            Form {
                Section("Connection") {
                    TextField("Name (optional)", text: $connection.name)
                    TextField("Host", text: $connection.host)
                    TextField("Port", value: $connection.port, format: .number)
                    TextField("Username", text: $connection.user)
                }

                Section("Authentication") {
                    TextField("Identity File (e.g., ~/.ssh/id_rsa)", text: $connection.identityFile)
                }

                Section("Advanced") {
                    TextField("Jump Host (ProxyJump)", text: $connection.jumpHost)
                    TextField("Extra SSH Options", text: $connection.extraOptions)

                    // Show validation warning for dangerous options
                    if !connection.extraOptions.isEmpty {
                        let validation = connection.extraOptionsValidation
                        if !validation.isValid {
                            Label(validation.reason ?? "Invalid options", systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                        }
                    }
                }

                Section("Appearance") {
                    Picker("Tab Color", selection: $connection.colorTag) {
                        ForEach(colorOptions, id: \.self) { color in
                            HStack {
                                Circle()
                                    .fill(colorForTag(color))
                                    .frame(width: 12, height: 12)
                                Text(color.capitalized)
                            }
                            .tag(color)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            // Footer
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    onSave(connection)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(connection.host.isEmpty)
            }
            .padding()
        }
        .frame(width: 450, height: 500)
    }

    private func colorForTag(_ tag: String) -> Color {
        switch tag {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        default: return .blue
        }
    }
}

// MARK: - SSH Connection Window Controller

final class SSHConnectionWindowController {
    static let shared = SSHConnectionWindowController()

    private var window: NSWindow?
    weak var appDelegate: AppDelegate?

    private init() {}

    func showConnectionManager() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let view = SSHConnectionView { [weak self] connection in
            self?.connect(to: connection)
        }

        let hostingView = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SSH Connections"
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }

    private func connect(to connection: SSHConnection) {
        guard let delegate = appDelegate else { return }

        // Create new tab and run SSH command
        delegate.newTab()

        // Send the SSH command to the terminal
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let model = delegate.overlayModel,
               let session = model.selectedTab?.session {
                session.sendInput(connection.sshCommand + "\n")
                Log.info("SSH: Connecting to \(connection.displayName)")
            }
        }
    }
}
