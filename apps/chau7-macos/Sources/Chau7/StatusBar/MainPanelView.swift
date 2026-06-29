import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Chau7Core

// MARK: - Settings Window Wrapper

/// Wrapper view for the standalone settings window (opened via Cmd+,)
struct SettingsWindowView: View {
    var model: AppModel
    let overlayModel: OverlayTabsModel?

    var body: some View {
        SettingsRootView(model: model, overlayModel: overlayModel)
    }
}

// MARK: - Settings Root View (SettingsSection is now in SettingsSearch.swift)

struct SettingsRootView: View {
    var model: AppModel
    let overlayModel: OverlayTabsModel?
    @State private var selection: SettingsSection = .general
    @State private var searchQuery = ""

    private var matchingSections: Set<SettingsSection> {
        FeatureSettings.sectionsMatching(query: searchQuery)
    }

    private var isSearching: Bool {
        !searchQuery.isEmpty
    }

    private var filteredSections: [SettingsSection] {
        if searchQuery.isEmpty {
            return SettingsSection.allCases
        }
        return SettingsSection.allCases.filter { matchingSections.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ProfileSelectorBar(overlayModel: overlayModel)

            NavigationSplitView {
                VStack(spacing: 0) {
                    // Search Bar
                    SettingsSearchBar(searchQuery: $searchQuery)

                    // Section List — grouped when browsing, flat when searching
                    List(selection: $selection) {
                        if isSearching {
                            ForEach(filteredSections) { section in
                                sidebarRow(for: section)
                            }
                        } else {
                            ForEach(SettingsSectionGroup.allCases) { group in
                                Section(header: Text(group.title)) {
                                    ForEach(group.sections, id: \.self) { section in
                                        sidebarRow(for: section)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
                .frame(minWidth: 220)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
            } detail: {
                SettingsDetailView(
                    selection: selection,
                    model: model,
                    overlayModel: overlayModel,
                    searchQuery: searchQuery
                )
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationSplitViewColumnWidth(min: 560, ideal: 700)
            }
        }
        .frame(minWidth: 860, maxWidth: .infinity, minHeight: 650, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: searchQuery) {
            // Auto-select first matching section when searching
            if !searchQuery.isEmpty, let firstMatch = filteredSections.first {
                selection = firstMatch
            }
        }
    }

    private func sidebarRow(for section: SettingsSection) -> some View {
        SettingsSidebarRow(
            section: section,
            isHighlighted: isSearching && matchingSections.contains(section),
            matchCount: isSearching ? FeatureSettings.searchableSettings.filter { $0.section == section && $0.matches(searchQuery) }.count : 0
        )
        .tag(section)
    }
}

// MARK: - Settings Search Bar

struct SettingsSearchBar: View {
    @Binding var searchQuery: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(L("Search settings...", "Search settings..."), text: $searchQuery)
                .textFieldStyle(.plain)
                .focused($isFocused)

            if !searchQuery.isEmpty {
                Button(action: { searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Settings Sidebar Row

struct SettingsSidebarRow: View {
    let section: SettingsSection
    let isHighlighted: Bool
    let matchCount: Int

    var body: some View {
        HStack {
            Label(section.title, systemImage: section.systemImage)
                .foregroundColor(isHighlighted ? .accentColor : .primary)

            if matchCount > 0 {
                Spacer()
                Text(matchCount.formatted())
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
            }
        }
    }
}

// MARK: - Settings Detail View

struct SettingsDetailView: View {
    let selection: SettingsSection
    var model: AppModel
    let overlayModel: OverlayTabsModel?
    var searchQuery = ""

    private var matchingSettings: [SearchableSetting] {
        guard !searchQuery.isEmpty else { return [] }
        return FeatureSettings.searchableSettings.filter {
            $0.section == selection && $0.matches(searchQuery)
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                // Section header with description
                sectionHeader

                // Search results hint
                if !searchQuery.isEmpty, !matchingSettings.isEmpty {
                    SearchResultsHint(matchingSettings: matchingSettings, query: searchQuery)
                }

                Divider()
                    .padding(.bottom, 16)

                // Section content
                Group {
                    switch selection {
                    // Essentials
                    case .general:
                        GeneralSettingsView(model: model)
                    case .profilesBackup:
                        ProfilesBackupSettingsView()
                    case .about:
                        AboutSettingsView(model: model)
                    // Look & Feel
                    case .fontColors:
                        FontColorsSettingsView()
                    case .display:
                        DisplaySettingsView()
                    case .tabs:
                        TabsSettingsView()
                    case .hoverCard:
                        HoverCardSettingsView()
                    case .repositories:
                        RepositoriesSettingsView()
                    // Terminal
                    case .shell:
                        ShellSettingsView()
                    case .scrollbackPerf:
                        ScrollbackPerfSettingsView(model: model)
                    case .dangerousCommands:
                        DangerousCommandSettingsView()
                    case .graphics:
                        GraphicsSettingsView()
                    case .minimalMode:
                        MinimalModeSettingsView()
                    // Input & Productivity
                    case .keyboardMouse:
                        InputSettingsView()
                    case .snippetsTools:
                        ProductivitySettingsView()
                    case .editor:
                        EditorSettingsView()
                    // Integrations
                    case .aiDetection:
                        AIIntegrationSettingsView()
                    case .tokenOptimization:
                        TokenOptimizationSettingsView(overlayModel: overlayModel)
                    case .mcpControl:
                        MCPSettingsView()
                    case .remoteControl:
                        RemoteSettingsView()
                    case .apiProxy:
                        ProxySettingsView()
                    case .promptInjection:
                        PromptInjectionSettingsView()
                    // Monitoring
                    case .notifications:
                        NotificationsSettingsView(model: model)
                    case .logsHistory:
                        LogsSettingsView(model: model)
                    }
                }
            }
            .padding(24)
        }
        .id(selection)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selection.title)
                .font(.title2)
                .fontWeight(.semibold)
            Text(selection.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 12)
    }
}

// MARK: - Search Results Hint

struct SearchResultsHint: View {
    let matchingSettings: [SearchableSetting]
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text(
                    String(
                        format: L("settings.searchResults", "Found %d matching settings for \"%@\""),
                        matchingSettings.count,
                        query
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            ForEach(matchingSettings) { setting in
                HStack {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                    Text(setting.title)
                        .font(.caption)
                        .foregroundColor(.accentColor)
                    Text(String(format: L("settings.searchResultDetail", "– %@"), setting.description))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.1))
        .cornerRadius(8)
        .padding(.bottom, 8)
    }
}

// Note: Reusable settings components moved to SettingsComponents.swift
// Note: Individual settings views moved to SettingsViews/ folder
