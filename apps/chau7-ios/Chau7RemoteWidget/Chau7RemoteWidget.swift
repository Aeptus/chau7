import ActivityKit
import SwiftUI
import WidgetKit
import Chau7Core

@main
struct Chau7RemoteWidgetBundle: WidgetBundle {
    var body: some Widget {
        Chau7RemoteWidget()
#if DEBUG
        Chau7RemoteDebugPlaceholderWidget()
#endif
    }
}

struct Chau7RemoteWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: Chau7RemoteActivityAttributes.self) { context in
            LockScreenActivityView(state: context.state)
                .activityBackgroundTint(backgroundTint(for: context.state.status))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.toolName, systemImage: iconName(for: context.state.status))
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.projectName ?? context.state.tabTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedActivityActions(state: context.state)
                }
            } compactLeading: {
                Image(systemName: iconName(for: context.state.status))
            } compactTrailing: {
                Text(shortStatusLabel(for: context.state.status))
            } minimal: {
                Image(systemName: iconName(for: context.state.status))
            }
            .widgetURL(activityURL(host: "open", tabID: context.state.tabID))
            .keylineTint(tint(for: context.state.status))
        }
    }

    private func backgroundTint(for status: RemoteActivityStatus) -> Color {
        switch status {
        case .waitingInput:
            return .orange.opacity(0.18)
        case .failed:
            return .red.opacity(0.18)
        case .completed:
            return .green.opacity(0.18)
        case .running, .idle:
            return .blue.opacity(0.16)
        }
    }

    private func tint(for status: RemoteActivityStatus) -> Color {
        switch status {
        case .waitingInput:
            return .orange
        case .failed:
            return .red
        case .completed:
            return .green
        case .running, .idle:
            return .blue
        }
    }

    private func iconName(for status: RemoteActivityStatus) -> String {
        switch status {
        case .waitingInput:
            return "exclamationmark.bubble.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .completed:
            return "checkmark.circle.fill"
        case .running:
            return "sparkles"
        case .idle:
            return "terminal"
        }
    }

    private func shortStatusLabel(for status: RemoteActivityStatus) -> String {
        switch status {
        case .waitingInput:
            return "Ask"
        case .failed:
            return "Fail"
        case .completed:
            return "Done"
        case .running:
            return "Run"
        case .idle:
            return "Idle"
        }
    }
}

private struct LockScreenActivityView: View {
    let state: Chau7RemoteActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.headline)
                        .font(.headline)
                    Text(state.projectName ?? state.tabTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(state.toolName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.12), in: Capsule())
            }
            ExpandedActivityActions(state: state)
        }
        .padding(.vertical, 6)
    }
}

private struct ExpandedActivityActions: View {
    let state: Chau7RemoteActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let detail = state.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Link(destination: activityURL(host: "open", tabID: state.tabID)) {
                    actionLabel("Open", systemImage: "iphone")
                }

                Link(destination: activityURL(host: "switch", tabID: state.tabID)) {
                    actionLabel("Tab", systemImage: "rectangle.on.rectangle")
                }

                if let requestID = state.approvalRequestID {
                    Link(destination: activityURL(host: "approve", tabID: state.tabID, requestID: requestID)) {
                        actionLabel("Approve", systemImage: "checkmark")
                    }

                    Link(destination: activityURL(host: "deny", tabID: state.tabID, requestID: requestID)) {
                        actionLabel("Deny", systemImage: "xmark")
                    }
                }
            }
        }
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.white.opacity(0.12), in: Capsule())
    }
}

private func activityURL(host: String, tabID: UInt32?, requestID: String? = nil) -> URL {
    var components = URLComponents()
    components.scheme = "chau7remote"
    components.host = host

    var items: [URLQueryItem] = []
    if let tabID {
        items.append(URLQueryItem(name: "tab_id", value: String(tabID)))
    }
    if let requestID {
        items.append(URLQueryItem(name: "request_id", value: requestID))
    }
    components.queryItems = items.isEmpty ? nil : items
    return components.url!
}

#if DEBUG
private struct Chau7RemoteDebugEntry: TimelineEntry {
    let date: Date
}

private struct Chau7RemoteDebugProvider: TimelineProvider {
    func placeholder(in context: Context) -> Chau7RemoteDebugEntry {
        Chau7RemoteDebugEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (Chau7RemoteDebugEntry) -> Void) {
        completion(Chau7RemoteDebugEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Chau7RemoteDebugEntry>) -> Void) {
        completion(Timeline(entries: [Chau7RemoteDebugEntry(date: .now)], policy: .never))
    }
}

private struct Chau7RemoteDebugPlaceholderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "com.chau7.remote.debug-placeholder",
            provider: Chau7RemoteDebugProvider()
        ) { _ in
            VStack(alignment: .leading, spacing: 8) {
                Text("Chau7 Remote")
                    .font(.headline)
                Text("Debug widget placeholder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding()
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Chau7 Remote Debug")
        .description("Debug-only placeholder widget used for Xcode launch integration.")
        .supportedFamilies([.systemSmall])
    }
}
#endif
