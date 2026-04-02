import SwiftUI

/// Full git operations pane — status, stage, commit, branches, stash, history.
///
/// Follows the same header-bar + content pattern as `DiffViewerPaneView`.
/// Each section is collapsible. File clicks call `onFileClicked` to open
/// in a diff viewer or file preview pane.
struct RepositoryPaneView: View {
    let id: UUID
    @ObservedObject var repo: RepositoryPaneModel
    let onFocus: () -> Void
    let onClose: () -> Void
    var onFileClicked: ((String, String) -> Void)? // (path, directory)

    @State private var changesExpanded = true
    @State private var commitExpanded = true
    @State private var historyExpanded = false
    @State private var stashExpanded = false
    @State private var branchesExpanded = false

    @State private var newBranchName = ""
    @State private var stashMessage = ""
    @State private var showBranchPicker = false
    @State private var showCopiedToast = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if repo.isLoading, repo.commits.isEmpty {
                loadingView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        errorBanner
                        progressBanner
                        changesSection
                        commitSection
                        historySection
                        stashSection
                        branchesSection
                    }
                    .padding(10)
                }
            }
        }
        .onTapGesture { onFocus() }
        .onAppear {
            if repo.shouldAutoRefresh() {
                repo.refreshAll()
            }
        }
        .onChange(of: repo.commitMessage) { _ in
            repo.persistDraft()
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if let branch = repo.currentBranch {
                Button {
                    showBranchPicker.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Text(branch)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                    }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showBranchPicker) {
                    branchPickerPopover
                }

                if let ab = repo.aheadBehind, ab.ahead > 0 || ab.behind > 0 {
                    HStack(spacing: 2) {
                        if ab.ahead > 0 {
                            Text("↑\(ab.ahead)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.green)
                        }
                        if ab.behind > 0 {
                            Text("↓\(ab.behind)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.orange)
                        }
                    }
                    .help("↑ commits ahead of remote, ↓ commits behind")
                }
            }

            Text(repo.repoName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Button {
                repo.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .disabled(repo.isLoading)
            .help(L("Refresh", "Refresh"))

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help(L("Close Pane", "Close Pane"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text("Loading repository...")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Error & Progress Banners

    @ViewBuilder
    private var errorBanner: some View {
        if let error = repo.lastError {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    repo.lastError = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
            }
            .padding(6)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private var progressBanner: some View {
        if let op = repo.operationInProgress {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(op)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    // MARK: - Changes Section

    private var changesSection: some View {
        collapsibleSection(title: "Changes", count: changeCount, isExpanded: $changesExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                if !repo.conflictedFiles.isEmpty {
                    sectionLabel("CONFLICTS", color: .red)
                    ForEach(repo.conflictedFiles, id: \.self) { file in
                        conflictRow(file)
                    }
                }

                if !repo.stagedFiles.isEmpty {
                    sectionLabel("STAGED", color: .green)
                    ForEach(repo.stagedFiles) { file in
                        fileRow(file, staged: true)
                    }
                }

                if !repo.unstagedFiles.isEmpty {
                    sectionLabel("MODIFIED", color: .orange)
                    ForEach(repo.unstagedFiles) { file in
                        fileRow(file, staged: false)
                    }
                }

                if !repo.untrackedFiles.isEmpty {
                    sectionLabel("UNTRACKED", color: .secondary)
                    ForEach(repo.untrackedFiles, id: \.self) { file in
                        untrackedRow(file)
                    }
                }

                if changeCount > 0 {
                    HStack(spacing: 8) {
                        Button("Stage All") { repo.stageAll() }
                            .font(.system(size: 10))
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)

                        if !repo.stagedFiles.isEmpty {
                            Button("Unstage All") { repo.unstageAll() }
                                .font(.system(size: 10))
                                .buttonStyle(.plain)
                                .foregroundStyle(.blue)
                        }
                    }
                    .padding(.top, 4)
                }

                if changeCount == 0 {
                    Text("Working tree clean")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }
        }
    }

    private var changeCount: Int {
        repo.stagedFiles.count + repo.unstagedFiles.count + repo.untrackedFiles.count + repo.conflictedFiles.count
    }

    // MARK: - Commit Section

    private var commitSection: some View {
        collapsibleSection(title: "Commit", isExpanded: $commitExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                // Conventional commit prefix chips
                if !repo.hasConventionalPrefix {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 3) {
                            ForEach(RepositoryPaneModel.commitPrefixes, id: \.self) { prefix in
                                Button(prefix) {
                                    repo.applyPrefix(prefix)
                                }
                                .font(.system(size: 9))
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }
                    }
                }

                TextEditor(text: $repo.commitMessage)
                    .font(.system(size: 11))
                    .frame(minHeight: 40, maxHeight: 80)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading) {
                        if repo.commitMessage.isEmpty {
                            Text("Commit message...")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }

                HStack {
                    Toggle("Amend", isOn: $repo.isAmend)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 10))

                    Spacer()

                    Button {
                        repo.commit()
                    } label: {
                        Text(repo.stagedFiles.isEmpty
                            ? "Commit"
                            : "Commit (\(repo.stagedFiles.count) staged)")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .disabled(repo.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || (repo.stagedFiles.isEmpty && !repo.isAmend))
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("⌘Return to commit")
                }
            }
        }
    }

    // MARK: - History Section

    private var historySection: some View {
        collapsibleSection(title: "History", count: repo.commits.count, isExpanded: $historyExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                // Search bar
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    TextField("Search commits...", text: $repo.historySearchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10))
                    if !repo.historySearchText.isEmpty {
                        Button {
                            repo.historySearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))

                // Copied toast
                if showCopiedToast {
                    Text("Copied")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }

                ForEach(repo.filteredCommits) { commit in
                    HStack(spacing: 6) {
                        Text(commit.shortHash)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .leading)
                            .onTapGesture {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(commit.hash, forType: .string)
                                withAnimation(.easeInOut(duration: 0.15)) { showCopiedToast = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                    withAnimation(.easeInOut(duration: 0.3)) { showCopiedToast = false }
                                }
                            }
                            .help("Click to copy full hash")

                        Text(commit.message)
                            .font(.system(size: 10))
                            .lineLimit(1)

                        Spacer()

                        Text(commit.dateString)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Copy Hash") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(commit.hash, forType: .string)
                        }
                        Button("Copy Message") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(commit.message, forType: .string)
                        }
                        Button("Copy Full") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(commit.shortHash) \(commit.message)", forType: .string)
                        }
                    }
                }

                Button("Load More") {
                    repo.loadMoreCommits()
                }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Stash Section

    private var stashSection: some View {
        collapsibleSection(title: "Stash", count: repo.stashes.count, isExpanded: $stashExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    TextField("Stash message (optional)", text: $stashMessage)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))

                    Button("Save") {
                        repo.stashSave(message: stashMessage.isEmpty ? nil : stashMessage)
                        stashMessage = ""
                    }
                    .font(.system(size: 10))
                    .controlSize(.small)
                }

                ForEach(repo.stashes) { stash in
                    HStack(spacing: 6) {
                        Text("stash@{\(stash.index)}")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Text(stash.description)
                            .font(.system(size: 10))
                            .lineLimit(1)

                        Spacer()

                        Button("Pop") { repo.stashPop(index: stash.index) }
                            .font(.system(size: 9))
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)

                        Button("Drop") { repo.stashDrop(index: stash.index) }
                            .font(.system(size: 9))
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                    }
                    .padding(.vertical, 1)
                    .help(stash.hoverText)
                }

                if repo.stashes.isEmpty {
                    Text("No stashes")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }
        }
    }

    // MARK: - Branches Section

    private var branchesSection: some View {
        collapsibleSection(title: "Branches", count: repo.branches.count, isExpanded: $branchesExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                // Create branch
                HStack(spacing: 4) {
                    TextField("New branch name", text: $newBranchName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))

                    Button("Create") {
                        repo.createBranch(newBranchName)
                        newBranchName = ""
                    }
                    .font(.system(size: 10))
                    .controlSize(.small)
                    .disabled(newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                // Branch list
                ForEach(repo.branches, id: \.self) { branch in
                    HStack(spacing: 6) {
                        Image(systemName: branch == repo.currentBranch ? "circle.fill" : "circle")
                            .font(.system(size: 6))
                            .foregroundStyle(branch == repo.currentBranch ? .green : .secondary)

                        Text(branch)
                            .font(.system(size: 10, weight: branch == repo.currentBranch ? .semibold : .regular))
                            .lineLimit(1)

                        Spacer()

                        if branch != repo.currentBranch {
                            Button("Switch") { repo.switchBranch(branch) }
                                .font(.system(size: 9))
                                .buttonStyle(.plain)
                                .foregroundStyle(.blue)

                            Button("Delete") { repo.deleteBranch(branch) }
                                .font(.system(size: 9))
                                .buttonStyle(.plain)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 1)
                    .help(repo.branchDetails[branch]?.hoverText ?? branch)
                }

                Divider().padding(.vertical, 4)

                // Push / Pull
                HStack(spacing: 8) {
                    Button {
                        repo.push()
                    } label: {
                        Label("Push", systemImage: "arrow.up")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        repo.pull()
                    } label: {
                        Label("Pull", systemImage: "arrow.down")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Branch Picker Popover

    private var branchPickerPopover: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Switch Branch")
                .font(.system(size: 11, weight: .semibold))
                .padding(.bottom, 4)

            ForEach(repo.branches, id: \.self) { branch in
                Button {
                    repo.switchBranch(branch)
                    showBranchPicker = false
                } label: {
                    HStack {
                        Text(branch)
                            .font(.system(size: 11))
                        Spacer()
                        if branch == repo.currentBranch {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10))
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(minWidth: 180)
    }

    // MARK: - File Rows

    private func fileRow(_ file: FileStatus, staged: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                if staged {
                    repo.unstageFile(file.path)
                } else {
                    repo.stageFile(file.path)
                }
            } label: {
                Image(systemName: staged ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11))
                    .foregroundStyle(staged ? .green : .secondary)
            }
            .buttonStyle(.plain)

            Image(systemName: file.changeType.icon)
                .font(.system(size: 9))
                .foregroundStyle(colorForType(file.changeType))
                .frame(width: 12)

            Text(file.path)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(file.changeType.rawValue)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if let dir = repo.directory {
                onFileClicked?(file.path, dir)
            }
        }
    }

    private func untrackedRow(_ path: String) -> some View {
        HStack(spacing: 6) {
            Button {
                repo.stageFile(path)
            } label: {
                Image(systemName: "plus.square")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)

            Image(systemName: "doc.badge.plus")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 12)

            Text(path)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text("?")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    private func conflictRow(_ path: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)

            Text(path)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button("Ours") { repo.acceptOurs(file: path) }
                .font(.system(size: 9))
                .buttonStyle(.plain)
                .foregroundStyle(.blue)

            Button("Theirs") { repo.acceptTheirs(file: path) }
                .font(.system(size: 9))
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
        }
        .padding(.vertical, 1)
    }

    // MARK: - Reusable Components

    private func collapsibleSection(
        title: String,
        count: Int? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)

                    Text(title)
                        .font(.system(size: 11, weight: .semibold))

                    if let count, count > 0 {
                        Text("\(count)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(Capsule())
                    }

                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                content()
                    .padding(.leading, 14)
            }
        }
    }

    private func sectionLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.top, 4)
    }

    private func colorForType(_ type: FileChangeType) -> Color {
        switch type {
        case .modified: return .orange
        case .added: return .green
        case .deleted: return .red
        case .renamed: return .blue
        case .copied: return .purple
        case .unmerged: return .red
        }
    }
}
