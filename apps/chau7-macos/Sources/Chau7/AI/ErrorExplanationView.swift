import SwiftUI
import Chau7Core

/// SwiftUI view that displays an LLM-generated explanation of a terminal error.
/// Shows a summary, detailed explanation, confidence indicator, and suggested fixes.
struct ErrorExplanationView: View {
    @ObservedObject var explainer: ErrorExplainer
    let onApplyFix: ((String) -> Void)?
    let onDismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if explainer.isLoading {
                loadingView
            } else if let error = explainer.lastError {
                errorView(error)
            } else if let explanation = explainer.lastExplanation {
                explanationContent(explanation)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Loading

    private var loadingView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(L("Analyzing error...", "Analyzing error..."))
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Error

    private func errorView(_ error: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.yellow)
            Text(error)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
            Spacer()
            dismissButton
        }
    }

    // MARK: - Explanation

    private func explanationContent(_ explanation: ErrorExplanation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with confidence badge
            HStack {
                confidenceBadge(explanation.confidence)
                Text(explanation.summary)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                Spacer()
                dismissButton
            }

            // Details
            Text(explanation.details)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Suggested fixes
            if !explainer.lastFixes.isEmpty {
                Divider()
                ForEach(Array(explainer.lastFixes.enumerated()), id: \.offset) { _, fix in
                    fixRow(fix)
                }
            }
        }
    }

    // MARK: - Fix Row

    private func fixRow(_ fix: FixSuggestion) -> some View {
        HStack(spacing: 8) {
            riskBadge(fix.riskLevel)

            VStack(alignment: .leading, spacing: 2) {
                Text(fix.description)
                    .font(.system(.caption, design: .monospaced))
                Text(fix.command)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.blue)
            }

            Spacer()

            if fix.riskLevel != .dangerous {
                Button(L("Apply", "Apply")) {
                    onApplyFix?(fix.command)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button(L("Copy", "Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fix.command, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Badges

    private func confidenceBadge(_ confidence: ExplanationConfidence) -> some View {
        let (color, text): (Color, String) = {
            switch confidence {
            case .high: return (.green, "HIGH")
            case .medium: return (.orange, "MED")
            case .low: return (.red, "LOW")
            }
        }()
        return Text(text)
            .font(.system(.caption2, design: .monospaced))
            .fontWeight(.bold)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(3)
    }

    private func riskBadge(_ risk: FixRiskLevel) -> some View {
        let (color, icon): (Color, String) = {
            switch risk {
            case .safe: return (.green, "checkmark.shield")
            case .moderate: return (.orange, "exclamationmark.shield")
            case .dangerous: return (.red, "xmark.shield")
            }
        }()
        return Image(systemName: icon)
            .foregroundColor(color)
            .font(.caption)
    }

    private var dismissButton: some View {
        Button {
            onDismiss?()
            explainer.clear()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
    }
}
