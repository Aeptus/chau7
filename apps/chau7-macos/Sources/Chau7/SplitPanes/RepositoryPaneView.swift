import Chau7Core
import SwiftUI

/// Full git operations pane — status, stage, commit, branches, stash, history.
///
/// Follows the same header-bar + content pattern as `DiffViewerPaneView`.
/// Each section is collapsible. File clicks call `onFileClicked` to open
/// in a diff viewer or file preview pane.
struct RepositoryPaneView: View {
    let id: UUID
    @Bindable var repo: RepositoryPaneModel
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
    @State private var draftPersistWork: DispatchWorkItem?

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if repo.isLoading, repo.commits.isEmpty {
                loadingView
            } else if repo.isSessionMode {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        errorBanner
                        progressBanner
                        sessionChangesSection
                        commitSection
                        turnSummarySection
                        if repo.otherChangeCount > 0 {
                            otherChangesSection
                        }
                    }
                    .padding(10)
                }
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
        .onChange(of: repo.commitMessage) {
            draftPersistWork?.cancel()
            let work = DispatchWorkItem { [weak repo] in repo?.persistDraft() }
            draftPersistWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
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
                    .help(L("repo.aheadBehind.help", "↑ commits ahead of remote, ↓ commits behind"))
                }
            }

            if repo.isSessionMode, let summary = repo.turnSummary {
                HStack(spacing: 3) {
                    Circle()
                        .fill(sessionStateColor(summary.sessionState))
                        .frame(width: 6, height: 6)
                    Text(summary.backendName.capitalized)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(repo.repoName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Session/Git mode toggle
            if repo.turnSummary != nil {
                Button {
                    repo.forceGitMode.toggle()
                    repo.isSessionMode = !repo.forceGitMode
                } label: {
                    Text(repo.isSessionMode ? L("repo.switchToGit", "Git") : L("repo.switchToSession", "Session"))
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .help(repo.isSessionMode ? L("repo.switchToGit.help", "Switch to full git view") : L("repo.switchToSession.help", "Switch to session view"))
            }

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
            Text(L("repo.loading", "Loading repository..."))
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
        collapsibleSection(title: L("repo.section.changes", "Changes"), count: changeCount, isExpanded: $changesExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                if !repo.conflictedFiles.isEmpty {
                    sectionLabel(L("repo.section.conflicts", "CONFLICTS"), color: .red)
                    ForEach(repo.conflictedFiles, id: \.self) { file in
                        conflictRow(file)
                    }
                }

                if !repo.stagedFiles.isEmpty {
                    sectionLabel(L("repo.section.staged", "STAGED"), color: .green)
                    ForEach(repo.stagedFiles) { file in
                        fileRow(file, staged: true)
                    }
                }

                if !repo.unstagedFiles.isEmpty {
                    sectionLabel(L("repo.section.modified", "MODIFIED"), color: .orange)
                    ForEach(repo.unstagedFiles) { file in
                        fileRow(file, staged: false)
                    }
                }

                if !repo.untrackedFiles.isEmpty {
                    sectionLabel(L("repo.section.untracked", "UNTRACKED"), color: .secondary)
                    ForEach(repo.untrackedFiles, id: \.self) { file in
                        untrackedRow(file)
                    }
                }

                if changeCount > 0 {
                    HStack(spacing: 8) {
                        Button(L("repo.stageAll", "Stage All")) { repo.stageAll() }
                            .font(.system(size: 10))
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)

                        if !repo.stagedFiles.isEmpty {
                            Button(L("repo.unstageAll", "Unstage All")) { repo.unstageAll() }
                                .font(.system(size: 10))
                                .buttonStyle(.plain)
                                .foregroundStyle(.blue)
                        }
                    }
                    .padding(.top, 4)
                }

                if changeCount == 0 {
                    Text(L("repo.workingTreeClean", "Working tree clean"))
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

    // MARK: - Session Changes Section

    @State private var sessionChangesExpanded = true
    @State private var otherChangesExpanded = false
    @State private var turnSummaryExpanded = false

    private var sessionChangesSection: some View {
        collapsibleSection(title: L("repo.section.sessionChanges", "Session Changes"), count: repo.sessionChangeCount, isExpanded: $sessionChangesExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                if !repo.sessionStagedFiles.isEmpty {
                    sectionLabel(L("repo.section.staged", "STAGED"), color: .green)
                    ForEach(repo.sessionStagedFiles) { file in
                        sessionFileRow(file, staged: true)
                    }
                }

                if !repo.sessionUnstagedFiles.isEmpty {
                    sectionLabel(L("repo.section.modified", "MODIFIED"), color: .orange)
                    ForEach(repo.sessionUnstagedFiles) { file in
                        sessionFileRow(file, staged: false)
                    }
                }

                if !repo.sessionUntrackedFiles.isEmpty {
                    sectionLabel(L("repo.section.new", "NEW"), color: .green)
                    ForEach(repo.sessionUntrackedFiles, id: \.self) { file in
                        untrackedRow(file)
                    }
                }

                if repo.sessionChangeCount > 0 {
                    Button(L("repo.stageAllSession", "Stage All Session Changes")) {
                        repo.stageSessionChanges()
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .padding(.top, 4)
                }

                if repo.sessionChangeCount == 0 {
                    Text(L("repo.noSessionChanges", "No changes from this session"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }
        }
    }

    private var otherChangesSection: some View {
        collapsibleSection(title: L("repo.section.otherChanges", "Other Changes"), count: repo.otherChangeCount, isExpanded: $otherChangesExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(repo.otherStagedFiles) { file in
                    fileRow(file, staged: true)
                }
                ForEach(repo.otherUnstagedFiles) { file in
                    fileRow(file, staged: false)
                }
                ForEach(repo.otherUntrackedFiles, id: \.self) { file in
                    untrackedRow(file)
                }
            }
            .opacity(0.7)
        }
    }

    // MARK: - Turn Summary Section

    private var turnSummarySection: some View {
        collapsibleSection(title: L("repo.section.turnSummary", "Turn Summary"), isExpanded: $turnSummaryExpanded) {
            if let summary = repo.turnSummary {
                VStack(alignment: .leading, spacing: 4) {
                    // Tools used
                    if !summary.toolsUsed.isEmpty {
                        HStack(spacing: 4) {
                            Text(L("repo.tools", "Tools:"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(summary.toolsUsed.map { "\($0.key)(\($0.value))" }.joined(separator: " "))
                                .font(.system(size: 9, design: .monospaced))
                        }
                    }

                    // Tokens
                    HStack(spacing: 8) {
                        Text(L("repo.tokens", "Tokens:"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("\(formatTokenCount(summary.inputTokens)) in")
                            .font(.system(size: 9, design: .monospaced))
                        Text("\(formatTokenCount(summary.outputTokens)) out")
                            .font(.system(size: 9, design: .monospaced))
                    }

                    // Duration + exit
                    HStack(spacing: 8) {
                        if let duration = summary.formattedDuration {
                            Text(String(format: L("repo.duration", "Duration: %@"), duration))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        if let exit = summary.exitReason {
                            Text(String(format: L("repo.exit", "Exit: %@"), exit.rawValue))
                                .font(.system(size: 10))
                                .foregroundStyle(exit == .success ? .green : .orange)
                        }
                    }

                    // Turn count
                    Text(String(format: L("repo.turnCount", "Turns: %d"), summary.turnCount))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Session File Row (enhanced with diff stats)

    private func sessionFileRow(_ file: FileStatus, staged: Bool) -> some View {
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

            // Diff stats
            if let stat = repo.diffStats[file.path] {
                HStack(spacing: 2) {
                    if stat.additions > 0 {
                        Text("+\(stat.additions)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.green)
                    }
                    if stat.deletions > 0 {
                        Text("-\(stat.deletions)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.red)
                    }
                }
            }

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

    private func formatTokenCount(_ count: Int) -> String {
        if count > 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    private func sessionStateColor(_ state: RuntimeSessionStateMachine.State) -> Color {
        switch state {
        case .ready: return .green
        case .busy: return .orange
        case .awaitingApproval, .waitingInput: return .yellow
        case .interrupted: return .orange
        case .failed: return .red
        case .stopped: return .gray
        case .starting: return .blue
        }
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
                            Text(L("placeholder.commitMessage", "Commit message..."))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }

                HStack {
                    Toggle(L("repo.amend", "Amend"), isOn: $repo.isAmend)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 10))

                    if repo.isSessionMode {
                        Button {
                            repo.askAgentForCommitMessage()
                        } label: {
                            Label(L("repo.askAgent", "Ask Agent"), systemImage: "bubble.left.and.text.bubble.right")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help(L("repo.askAgent.help", "Ask the AI agent to suggest a commit message"))
                    }

                    Spacer()

                    Button {
                        repo.commit()
                    } label: {
                        Text(repo.stagedFiles.isEmpty
                            ? L("repo.commit", "Commit")
                            : String(format: L("repo.commitStaged", "Commit (%d staged)"), repo.stagedFiles.count))
                            .font(.system(size: 10, weight: .medium))
                    }
                    .disabled(repo.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || (repo.stagedFiles.isEmpty && !repo.isAmend))
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help(L("repo.commit.help", "⌘Return to commit"))
                }
            }
        }
    }

    // MARK: - History Section

    private var historySection: some View {
        collapsibleSection(title: L("repo.section.history", "History"), count: repo.commits.count, isExpanded: $historyExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                // Search bar
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    TextField(L("placeholder.searchCommits", "Search commits..."), text: $repo.historySearchText)
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
                    Text(L("repo.copied", "Copied"))
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
                            .help(L("repo.hash.help", "Click to copy full hash"))

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
                        Button(L("repo.copyHash", "Copy Hash")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(commit.hash, forType: .string)
                        }
                        Button(L("repo.copyMessage", "Copy Message")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(commit.message, forType: .string)
                        }
                        Button(L("repo.copyFull", "Copy Full")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(commit.shortHash) \(commit.message)", forType: .string)
                        }
                    }
                }

                Button(L("repo.loadMore", "Load More")) {
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
        collapsibleSection(title: L("repo.section.stash", "Stash"), count: repo.stashes.count, isExpanded: $stashExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    TextField(L("placeholder.stashMessage", "Stash message (optional)"), text: $stashMessage)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))

                    Button(L("repo.save", "Save")) {
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

                        Button(L("repo.pop", "Pop")) { repo.stashPop(index: stash.index) }
                            .font(.system(size: 9))
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)

                        Button(L("repo.drop", "Drop")) { repo.stashDrop(index: stash.index) }
                            .font(.system(size: 9))
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                    }
                    .padding(.vertical, 1)
                    .help(stash.hoverText)
                }

                if repo.stashes.isEmpty {
                    Text(L("repo.noStashes", "No stashes"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }
        }
    }

    // MARK: - Branches Section

    private var branchesSection: some View {
        collapsibleSection(title: L("repo.section.branches", "Branches"), count: repo.branches.count, isExpanded: $branchesExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                // Create branch
                HStack(spacing: 4) {
                    TextField(L("placeholder.newBranchName", "New branch name"), text: $newBranchName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))

                    Button(L("repo.createBranch", "Create")) {
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
                            Button(L("repo.switchBranch", "Switch")) { repo.switchBranch(branch) }
                                .font(.system(size: 9))
                                .buttonStyle(.plain)
                                .foregroundStyle(.blue)

                            Button(L("repo.deleteBranch", "Delete")) { repo.deleteBranch(branch) }
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
                        Label(L("repo.push", "Push"), systemImage: "arrow.up")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        repo.pull()
                    } label: {
                        Label(L("repo.pull", "Pull"), systemImage: "arrow.down")
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
            Text(L("repo.switchBranchTitle", "Switch Branch"))
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

            Button(L("repo.ours", "Ours")) { repo.acceptOurs(file: path) }
                .font(.system(size: 9))
                .buttonStyle(.plain)
                .foregroundStyle(.blue)

            Button(L("repo.theirs", "Theirs")) { repo.acceptTheirs(file: path) }
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
