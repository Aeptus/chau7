import SwiftUI

/// Settings view for per-repository prompt injection rules.
struct PromptInjectionSettingsView: View {
    @Bindable private var store = InjectionRuleStore.shared

    @State private var globalContent = ""
    @State private var globalPosition: InjectionRuleStore.Rule.Position = .prepend
    @State private var globalEnabled = false

    @State private var editingRule: InjectionRuleStore.Rule?
    @State private var showingAddSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader(
                L("settings.injection.global", "All Repositories"),
                icon: "globe"
            )

            Text(L(
                "settings.injection.global.help",
                "Content injected into every AI request regardless of repository. Repo-specific rules take precedence."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            Toggle(isOn: $globalEnabled) {
                Text(L("settings.injection.global.enable", "Enable global injection"))
            }
            .toggleStyle(.switch)
            .onChange(of: globalEnabled) { _, enabled in
                if enabled {
                    store.setGlobalRule(content: globalContent, position: globalPosition)
                } else {
                    store.removeGlobalRule()
                }
            }

            if globalEnabled {
                Picker(
                    L("settings.injection.position", "Position"),
                    selection: $globalPosition
                ) {
                    ForEach(InjectionRuleStore.Rule.Position.allCases) { pos in
                        Text(pos.label).tag(pos)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 400)
                .onChange(of: globalPosition) { _, newPos in
                    store.setGlobalRule(content: globalContent, position: newPos)
                }

                TextEditor(text: $globalContent)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80, maxHeight: 160)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2))
                    )
                    .onChange(of: globalContent) { _, newContent in
                        store.setGlobalRule(content: newContent, position: globalPosition)
                    }
            }

            Divider()
                .padding(.vertical, 8)

            // MARK: - Per-Repository Rules

            SettingsSectionHeader(
                L("settings.injection.perRepo", "Per Repository"),
                icon: "folder.badge.gearshape"
            )

            Text(L(
                "settings.injection.perRepo.help",
                "Rules targeting specific repositories. Matched by name — portable across machines."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            if store.repoRules.isEmpty && store.localRules.isEmpty {
                Text(L("settings.injection.perRepo.empty", "No repository rules configured."))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.repoRules) { rule in
                        ruleRow(rule, isLocal: false)
                        if rule.id != store.repoRules.last?.id || !store.localRules.isEmpty {
                            Divider()
                        }
                    }

                    ForEach(
                        store.localRules.sorted(by: { $0.key < $1.key }),
                        id: \.key
                    ) { repoRoot, rule in
                        localRuleRow(rule, repoRoot: repoRoot)
                        if repoRoot != store.localRules.keys.sorted().last {
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

            Button {
                showingAddSheet = true
            } label: {
                Label(
                    L("settings.injection.add", "Add Repository Rule"),
                    systemImage: "plus"
                )
            }
            .buttonStyle(.bordered)

            Divider()
                .padding(.vertical, 8)

            // MARK: - Info

            SettingsSectionHeader(
                L("settings.injection.howItWorks", "How It Works"),
                icon: "questionmark.circle"
            )

            VStack(alignment: .leading, spacing: 8) {
                Text(L(
                    "settings.injection.howItWorks.description",
                    "The proxy injects content into AI requests before forwarding them to the provider. Rules are checked in priority order:"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    priorityRow("1", L("settings.injection.priority.local", "Repo-local file (.chau7/injection.json)"))
                    priorityRow("2", L("settings.injection.priority.specific", "Repo-specific rule from Settings"))
                    priorityRow("3", L("settings.injection.priority.global", "Global rule (all repositories)"))
                }

                Text(L(
                    "settings.injection.howItWorks.note",
                    "Repo-local files can be committed to the repository and shared with your team."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
        }
        .onAppear {
            syncGlobalState()
        }
        .sheet(isPresented: $showingAddSheet) {
            RuleEditorSheet(
                rule: InjectionRuleStore.Rule(repository: "", content: "", position: .prepend),
                isNew: true
            ) { newRule in
                store.addRepoRule(newRule)
            }
        }
        .sheet(item: $editingRule) { rule in
            RuleEditorSheet(rule: rule, isNew: false) { updated in
                store.updateRule(updated)
            }
        }
    }

    // MARK: - Subviews

    private func ruleRow(_ rule: InjectionRuleStore.Rule, isLocal: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.repository)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                    Text(rule.position.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
                Text(rule.content.prefix(120) + (rule.content.count > 120 ? "..." : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if !isLocal {
                Button {
                    editingRule = rule
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)

                Button {
                    store.removeRule(id: rule.id)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func localRuleRow(_ rule: InjectionRuleStore.Rule, repoRoot: String) -> some View {
        let repoName = URL(fileURLWithPath: repoRoot).lastPathComponent
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(repoName)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                    Text(rule.position.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                    Text(L("settings.injection.local", "local"))
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .foregroundStyle(.orange)
                        .background(Color.orange.opacity(0.1))
                        .clipShape(Capsule())
                }
                Text(rule.content.prefix(120) + (rule.content.count > 120 ? "..." : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                NSWorkspace.shared.open(
                    URL(fileURLWithPath: repoRoot)
                        .appendingPathComponent(".chau7")
                        .appendingPathComponent("injection.json")
                )
            } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.borderless)
            .help(L("settings.injection.openFile", "Open in editor"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func priorityRow(_ number: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text(number)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.bold)
                .frame(width: 18, height: 18)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(Circle())
            Text(text)
                .font(.caption)
        }
    }

    private func syncGlobalState() {
        if let rule = store.globalRule {
            globalEnabled = true
            globalContent = rule.content
            globalPosition = rule.position
        } else {
            globalEnabled = false
            globalContent = ""
            globalPosition = .prepend
        }
    }
}

// MARK: - Rule Editor Sheet

private struct RuleEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State var rule: InjectionRuleStore.Rule
    let isNew: Bool
    let onSave: (InjectionRuleStore.Rule) -> Void

    private var knownRepos: [String] {
        KnownRepoIdentityStore.shared.allRoots().map {
            URL(fileURLWithPath: $0).lastPathComponent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew
                ? L("settings.injection.editor.addTitle", "Add Repository Rule")
                : L("settings.injection.editor.editTitle", "Edit Repository Rule")
            )
            .font(.headline)

            // Repository picker/field
            VStack(alignment: .leading, spacing: 4) {
                Text(L("settings.injection.editor.repo", "Repository"))
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack {
                    TextField(
                        L("settings.injection.editor.repoPlaceholder", "e.g. my-api"),
                        text: $rule.repository
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                    if isNew, !knownRepos.isEmpty {
                        Menu {
                            ForEach(knownRepos, id: \.self) { name in
                                Button(name) {
                                    rule.repository = name
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 24)
                        .help(L("settings.injection.editor.pickRepo", "Pick from known repositories"))
                    }
                }
            }

            // Position
            VStack(alignment: .leading, spacing: 4) {
                Text(L("settings.injection.editor.position", "Position"))
                    .font(.subheadline)
                    .fontWeight(.medium)

                Picker("", selection: $rule.position) {
                    ForEach(InjectionRuleStore.Rule.Position.allCases) { pos in
                        Text(pos.label).tag(pos)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(L("settings.injection.editor.content", "Content"))
                    .font(.subheadline)
                    .fontWeight(.medium)

                TextEditor(text: $rule.content)
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

            // Buttons
            HStack {
                Spacer()
                Button(L("Cancel", "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(L("Save", "Save")) {
                    onSave(rule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(rule.repository.isEmpty || rule.content.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
