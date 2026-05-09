import AppKit
import SwiftUI

/// Settings tab for managing per-repo metadata: descriptions, labels, and
/// favorite files. Stored at `{repo}/.chau7/metadata.json` (see `RepoMetadata`).
struct RepositoriesSettingsView: View {
    @State private var repos: [RepoEntry] = []
    @State private var searchText = ""
    @State private var editingRepo: RepoEntry?

    private var filteredRepos: [RepoEntry] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return repos }
        return repos.filter { repo in
            repo.name.lowercased().contains(needle)
                || (repo.metadata.description?.lowercased().contains(needle) ?? false)
                || repo.metadata.labels.contains { $0.lowercased().contains(needle) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader(
                L("settings.repositories.title", "Repositories"),
                icon: "folder.badge.gearshape"
            )

            Text(L(
                "settings.repositories.help",
                "Add a description, labels, and favorite files to repositories you've opened in Chau7. Stored at .chau7/metadata.json inside each repo."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            if repos.isEmpty {
                emptyState
            } else {
                if repos.count > 5 {
                    searchField
                }

                if filteredRepos.isEmpty {
                    Text(L("settings.repositories.noMatches", "No repositories match your search."))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    repoList
                }
            }
        }
        .onAppear { reload() }
        .sheet(item: $editingRepo) { repo in
            RepositoryEditorSheet(repo: repo) { updated in
                save(updated)
                reload()
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                L("settings.repositories.search", "Search by name, description, or label"),
                text: $searchText
            )
            .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.2))
        )
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "folder.badge.questionmark")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(L("settings.repositories.empty.title", "No repositories tracked yet"))
                .font(.body)
                .foregroundStyle(.secondary)
            Text(L(
                "settings.repositories.empty.help",
                "Open a terminal in a git repository to start tracking it."
            ))
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var repoList: some View {
        VStack(spacing: 0) {
            ForEach(filteredRepos) { repo in
                repoRow(repo)
                if repo.id != filteredRepos.last?.id {
                    Divider()
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.2))
        )
    }

    private func repoRow(_ repo: RepoEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.blue)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(repo.name)
                    .font(.body)
                    .fontWeight(.medium)

                Text((repo.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let desc = repo.metadata.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if !repo.metadata.labels.isEmpty || !repo.metadata.favoriteFiles.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(repo.metadata.labels, id: \.self) { label in
                            Text(label)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                        if !repo.metadata.favoriteFiles.isEmpty {
                            HStack(spacing: 3) {
                                Image(systemName: "star.fill")
                                Text("\(repo.metadata.favoriteFiles.count)")
                            }
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        }
                    }
                }
            }

            Spacer()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path)])
            } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.borderless)
            .help(L("settings.repositories.openFinder", "Reveal in Finder"))

            Button {
                editingRepo = repo
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help(L("settings.repositories.edit", "Edit metadata"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            editingRepo = repo
        }
    }

    private func save(_ repo: RepoEntry) {
        if let model = RepositoryCache.shared.cachedModel(forRoot: repo.path) {
            model.updateMetadata(repo.metadata)
        } else {
            RepoMetadataStore.save(repo.metadata, repoRoot: repo.path)
        }
    }

    private func reload() {
        repos = KnownRepoIdentityStore.shared.allRoots()
            .map { path in
                let metadata = RepositoryCache.shared.cachedModel(forRoot: path)?.metadata
                    ?? RepoMetadataStore.load(repoRoot: path)
                return RepoEntry(
                    path: path,
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    metadata: metadata
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Editor Sheet

private struct RepositoryEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let repo: RepoEntry
    let onSave: (RepoEntry) -> Void

    @State private var descriptionText = ""
    @State private var labelsText = ""
    @State private var favoritesText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.blue)
                Text(repo.name)
                    .font(.headline)
            }

            Text((repo.path as NSString).abbreviatingWithTildeInPath)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text(L("repos.description", "Description"))
                    .font(.subheadline)
                    .fontWeight(.medium)
                TextField(
                    L("placeholder.repoDescription", "What is this repo for?"),
                    text: $descriptionText
                )
                .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L("repos.labels", "Labels"))
                    .font(.subheadline)
                    .fontWeight(.medium)
                TextField(
                    L("placeholder.repoLabels", "backend, rust, api (comma-separated)"),
                    text: $labelsText
                )
                .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L("repos.favoriteFiles", "Favorite Files"))
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(L("repos.favoriteFiles.help", "Relative paths, one per line."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $favoritesText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 100, maxHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2))
                    )
            }

            HStack {
                Spacer()
                Button(L("Cancel", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Save", "Save")) {
                    var updated = repo
                    updated.metadata = RepoMetadata(
                        description: descriptionText.isEmpty ? nil : descriptionText,
                        labels: parseList(labelsText, separator: ","),
                        favoriteFiles: parseList(favoritesText, separator: "\n"),
                        updatedAt: Date()
                    )
                    onSave(updated)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            descriptionText = repo.metadata.description ?? ""
            labelsText = repo.metadata.labels.joined(separator: ", ")
            favoritesText = repo.metadata.favoriteFiles.joined(separator: "\n")
        }
    }

    private func parseList(_ raw: String, separator: Character) -> [String] {
        raw.split(separator: separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Model

private struct RepoEntry: Identifiable {
    let path: String
    let name: String
    var metadata: RepoMetadata

    var id: String {
        path
    }
}
