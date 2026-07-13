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
            .frame(minWidth: SettingsLayout.sidebarMinWidth)
            .navigationSplitViewColumnWidth(
                min: SettingsLayout.sidebarMinWidth,
                ideal: SettingsLayout.sidebarIdealWidth,
                max: SettingsLayout.sidebarMaxWidth
            )
        } detail: {
            SettingsDetailView(
                selection: selection,
                model: model,
                overlayModel: overlayModel,
                searchQuery: searchQuery
            )
            .frame(
                minWidth: SettingsLayout.detailMinWidth,
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .navigationSplitViewColumnWidth(
                min: SettingsLayout.detailMinWidth,
                ideal: SettingsLayout.detailIdealWidth
            )
        }
        .navigationSplitViewStyle(.balanced)
        .frame(
            minWidth: SettingsLayout.settingsWindowMinWidth,
            maxWidth: .infinity,
            minHeight: SettingsLayout.settingsWindowMinHeight,
            maxHeight: .infinity,
            alignment: .topLeading
        )
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
        HStack(spacing: Chau7Style.Spacing.small) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(L("Search settings...", "Search settings..."), text: $searchQuery)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .accessibilityLabel(L("settings.search.accessibilityLabel", "Search settings"))

            if !searchQuery.isEmpty {
                Button(action: { searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("settings.search.clear", "Clear settings search"))
            }
        }
        .padding(Chau7Style.Spacing.small)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(Chau7Style.Radius.medium)
        .padding(.horizontal, Chau7Style.Settings.searchHorizontalPadding)
        .padding(.vertical, Chau7Style.Settings.searchVerticalPadding)
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
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if matchCount > 0 {
                Spacer()
                Text(matchCount.formatted())
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, Chau7Style.Spacing.xSmall)
                    .padding(.vertical, Chau7Style.Spacing.xxxSmall)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
                    .accessibilityLabel(
                        String(
                            format: L("settings.search.matchCount.accessibility", "%d matching settings"),
                            matchCount
                        )
                    )
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(section.title)
        .accessibilityHint(section.description)
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
                    .padding(.bottom, Chau7Style.Spacing.small)

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
                    case .windows:
                        WindowsSettingsView()
                    case .tabs:
                        TabsSettingsView()
                    case .hoverCard:
                        HoverCardSettingsView()
                    case .repositories:
                        RepositoriesSettingsView()
                    case .minimalMode:
                        MinimalModeSettingsView()
                    // Terminal
                    case .shell:
                        ShellSettingsView()
                    case .scrollbackPerf:
                        ScrollbackPerfSettingsView(model: model)
                    case .dangerousCommands:
                        DangerousCommandSettingsView()
                    case .graphics:
                        GraphicsSettingsView()
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
            .padding(Chau7Style.Settings.contentPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .id(selection)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: Chau7Style.Spacing.xxSmall) {
            Text(selection.title)
                .font(.title2)
                .fontWeight(.semibold)
            Text(selection.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(selection.title)
        .accessibilityHint(selection.description)
        .padding(.bottom, Chau7Style.Spacing.small)
    }
}

// MARK: - Search Results Hint

struct SearchResultsHint: View {
    let matchingSettings: [SearchableSetting]
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: Chau7Style.Spacing.small) {
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
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        searchResultIcon
                        Text(setting.title)
                            .font(.caption)
                            .foregroundColor(.accentColor)
                        Text(String(format: L("settings.searchResultDetail", "– %@"), setting.description))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: Chau7Style.Spacing.xxxSmall) {
                        HStack(alignment: .firstTextBaseline, spacing: Chau7Style.Spacing.xxSmall) {
                            searchResultIcon
                            Text(setting.title)
                                .font(.caption)
                                .foregroundColor(.accentColor)
                        }
                        Text(setting.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(setting.title)
                .accessibilityHint(setting.description)
            }
        }
        .padding(Chau7Style.Settings.hintPadding)
        .background(Color.accentColor.opacity(0.1))
        .cornerRadius(Chau7Style.Radius.medium)
        .padding(.bottom, Chau7Style.Spacing.small)
    }

    private var searchResultIcon: some View {
        Image(systemName: "arrow.right")
            .font(.caption2)
            .foregroundColor(.accentColor)
            .accessibilityHidden(true)
    }
}

// Note: Reusable settings components moved to SettingsComponents.swift
// Note: Individual settings views moved to SettingsViews/ folder
