import SwiftUI

/// Step-by-step wizard for importing profiles from Terminal.app and iTerm2.
struct TerminalMigrationWizardView: View {
    @StateObject private var wizard = TerminalMigrationWizard()
    @State private var currentStep: WizardStep = .welcome
    @State private var selectedProfileIDs: Set<UUID> = []
    @Environment(\.dismiss) private var dismiss

    enum WizardStep {
        case welcome, scanning, selection, importing, complete
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .padding(.bottom, 16)

            Divider()

            // Content
            Group {
                switch currentStep {
                case .welcome:
                    welcomeStepView
                case .scanning:
                    scanningStepView
                case .selection:
                    selectionStepView
                case .importing:
                    importingStepView
                case .complete:
                    completeStepView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.3), value: currentStep)

            Divider()

            // Footer buttons
            footerView
                .padding(.top, 16)
        }
        .padding(24)
        .frame(width: 520, height: 480)
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 8) {
            Text(L("Import Terminal Profiles", "Import Terminal Profiles"))
                .font(.title2)
                .fontWeight(.semibold)
            Text(stepDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var stepDescription: String {
        switch currentStep {
        case .welcome: return "Bring your existing settings into Chau7"
        case .scanning: return "Looking for terminal profiles..."
        case .selection: return "Select profiles to import"
        case .importing: return "Importing selected profiles..."
        case .complete: return "Import finished"
        }
    }

    // MARK: - Welcome Step

    private var welcomeStepView: some View {
        VStack(spacing: 24) {
            Spacer()
            HStack(spacing: 32) {
                sourceCard(name: "Terminal.app", icon: "terminal", color: .blue)
                sourceCard(name: "iTerm2", icon: "rectangle.split.3x1", color: .purple)
            }
            Text(L("Chau7 can import font, color, cursor, and shell settings from your existing terminal apps.", "Chau7 can import font, color, cursor, and shell settings from your existing terminal apps."))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Spacer()
        }
    }

    private func sourceCard(name: String, icon: String, color: Color) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(color)
            Text(name)
                .font(.headline)
        }
        .frame(width: 140, height: 120)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel(String(format: L("accessibility.importFrom", "Import from %@"), name))
    }

    // MARK: - Scanning Step

    private var scanningStepView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text(L("Scanning for profiles...", "Scanning for profiles..."))
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .onAppear {
            wizard.scanForProfiles()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if wizard.detectedProfiles.isEmpty {
                    currentStep = .complete
                } else {
                    selectedProfileIDs = Set(wizard.detectedProfiles.map { $0.id })
                    currentStep = .selection
                }
            }
        }
        .accessibilityLabel(L("Scanning for terminal profiles", "Scanning for terminal profiles"))
    }

    // MARK: - Selection Step

    private var selectionStepView: some View {
        VStack(spacing: 12) {
            Text(String(format: L("migration.foundProfiles", "Found %d profiles"), wizard.detectedProfiles.count))
                .font(.headline)
                .padding(.top, 8)

            List {
                ForEach(wizard.detectedProfiles) { profile in
                    profileRow(profile)
                }
            }
            .listStyle(.bordered)
            .frame(maxHeight: .infinity)

            HStack {
                Button(L("Select All", "Select All")) {
                    selectedProfileIDs = Set(wizard.detectedProfiles.map { $0.id })
                }
                .buttonStyle(.link)
                Button(L("Deselect All", "Deselect All")) {
                    selectedProfileIDs.removeAll()
                }
                .buttonStyle(.link)
                Spacer()
                Text(String(format: L("migration.selectedCount", "%d selected"), selectedProfileIDs.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func profileRow(_ profile: ImportableProfile) -> some View {
        let isSelected = selectedProfileIDs.contains(profile.id)
        return HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.body)
                    .fontWeight(.medium)
                Text(profile.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: profile.source.icon)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected {
                selectedProfileIDs.remove(profile.id)
            } else {
                selectedProfileIDs.insert(profile.id)
            }
        }
        .accessibilityLabel(
            String(
                format: L("accessibility.profileSource", "%@ from %@"),
                profile.name,
                profile.source.displayName
            )
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Importing Step

    private var importingStepView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text(String(format: L("migration.importing", "Importing %d profiles..."), selectedProfileIDs.count))
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .onAppear {
            let selected = wizard.detectedProfiles.filter { selectedProfileIDs.contains($0.id) }
            wizard.importProfiles(selected)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                currentStep = .complete
            }
        }
        .accessibilityLabel(L("Importing selected profiles", "Importing selected profiles"))
    }

    // MARK: - Complete Step

    private var completeStepView: some View {
        VStack(spacing: 16) {
            Spacer()
            if wizard.importStatus == .complete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text(L("Import Complete", "Import Complete"))
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(L("Your profiles are now available in Chau7 settings.", "Your profiles are now available in Chau7 settings."))
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.yellow)
                Text(L("No Profiles Found", "No Profiles Found"))
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(L("No Terminal.app or iTerm2 profiles were detected on this system.", "No Terminal.app or iTerm2 profiles were detected on this system."))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            if !wizard.importErrors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(wizard.importErrors, id: \.self) { error in
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.top, 8)
            }
            Spacer()
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Button(L("Cancel", "Cancel")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(L("Cancel import wizard", "Cancel import wizard"))

            Spacer()

            switch currentStep {
            case .welcome:
                Button(L("Scan for Profiles", "Scan for Profiles")) {
                    currentStep = .scanning
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(L("Begin scanning for terminal profiles", "Begin scanning for terminal profiles"))
            case .scanning:
                EmptyView()
            case .selection:
                Button(String(format: L("migration.importButton", "Import %d Profiles"), selectedProfileIDs.count)) {
                    currentStep = .importing
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedProfileIDs.isEmpty)
                .accessibilityLabel(L("Import selected profiles", "Import selected profiles"))
            case .importing:
                EmptyView()
            case .complete:
                Button(L("Done", "Done")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(L("Close import wizard", "Close import wizard"))
            }
        }
    }
}
