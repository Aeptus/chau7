import SwiftUI

/// Settings tab for managing per-repo metadata: descriptions, labels, and favorite files.
struct RepositoriesSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var repos: [RepoEntry] = []
    @State private var selectedRepo: String?
    @State private var editDescription = ""
    @State private var editLabels = ""
    @State private var editFavorites = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(L("settings.repositories.recent", "Recent Repositories"), icon: "folder.badge.gearshape")
                .padding(.bottom, 8)

            if repos.isEmpty {
                VStack {
                    Spacer()
                    Text("No repositories discovered yet")
                        .foregroundStyle(.secondary)
                    Text("Open a terminal in a git repository to get started")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                HSplitView {
                    // Repo list
                    List(repos, selection: $selectedRepo) { repo in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.blue)
                                Text(repo.name)
                                    .font(.system(size: 12, weight: .medium))
                            }
                            if let desc = repo.metadata.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if !repo.metadata.labels.isEmpty {
                                HStack(spacing: 4) {
                                    ForEach(repo.metadata.labels, id: \.self) { label in
                                        Text(label)
                                            .font(.system(size: 9, weight: .medium))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color.blue.opacity(0.15))
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
                                            .foregroundStyle(.blue)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                        .tag(repo.path)
                    }
                    .listStyle(.plain)
                    .frame(minWidth: 200)

                    // Edit panel
                    if let path = selectedRepo, let repo = repos.first(where: { $0.path == path }) {
                        editPanel(repo: repo)
                            .frame(minWidth: 300)
                    } else {
                        VStack {
                            Spacer()
                            Text("Select a repository to edit")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .frame(minWidth: 300)
                    }
                }
                .frame(minHeight: 300)
            }
        }
        .onAppear { reload() }
        .onChange(of: selectedRepo) { newPath in
            guard let path = newPath,
                  let repo = repos.first(where: { $0.path == path }) else { return }
            editDescription = repo.metadata.description ?? ""
            editLabels = repo.metadata.labels.joined(separator: ", ")
            editFavorites = repo.metadata.favoriteFiles.joined(separator: "\n")
        }
    }

    @ViewBuilder
    private func editPanel(repo: RepoEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.blue)
                    Text(repo.name)
                        .font(.system(size: 14, weight: .semibold))
                }

                Text(repo.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)

                Divider()

                // Description
                VStack(alignment: .leading, spacing: 4) {
                    Text("Description")
                        .font(.system(size: 12, weight: .medium))
                    TextField("What is this repo for?", text: $editDescription)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveMetadata(for: repo.path) }
                }

                // Labels
                VStack(alignment: .leading, spacing: 4) {
                    Text("Labels")
                        .font(.system(size: 12, weight: .medium))
                    TextField("backend, rust, api (comma-separated)", text: $editLabels)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveMetadata(for: repo.path) }
                }

                // Favorite files
                VStack(alignment: .leading, spacing: 4) {
                    Text("Favorite Files")
                        .font(.system(size: 12, weight: .medium))
                    Text("Relative paths, one per line")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    TextEditor(text: $editFavorites)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 80)
                        .border(Color.gray.opacity(0.3), width: 1)
                }

                // Save button
                HStack {
                    Spacer()
                    Button("Save") {
                        saveMetadata(for: repo.path)
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding()
        }
    }

    private func saveMetadata(for path: String) {
        let labels = editLabels
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let favorites = editFavorites
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let metadata = RepoMetadata(
            description: editDescription.isEmpty ? nil : editDescription,
            labels: labels,
            favoriteFiles: favorites,
            updatedAt: Date()
        )

        // Update live model if cached
        if let model = RepositoryCache.shared.cachedModel(forRoot: path) {
            model.updateMetadata(metadata)
        } else {
            RepoMetadataStore.save(metadata, repoRoot: path)
        }

        reload()
    }

    private func reload() {
        repos = settings.recentRepoRoots.map { path in
            let metadata = RepositoryCache.shared.cachedModel(forRoot: path)?.metadata
                ?? RepoMetadataStore.load(repoRoot: path)
            return RepoEntry(
                path: path,
                name: URL(fileURLWithPath: path).lastPathComponent,
                metadata: metadata
            )
        }
    }
}

private struct RepoEntry: Identifiable, Hashable {
    let path: String
    var id: String { path }
    let name: String
    let metadata: RepoMetadata

    func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }

    static func == (lhs: RepoEntry, rhs: RepoEntry) -> Bool {
        lhs.path == rhs.path
    }
}
