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
                .activityBackgroundTint(Color(red: 0.10, green: 0.09, blue: 0.08))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(activityURL(host: "open", tabID: context.state.tabID))
        } dynamicIsland: { context in
            let style = context.state.status.widgetStyle
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityLogo(size: 24)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Label(style.label, systemImage: style.icon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(style.tint)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        ActivityHeading(state: context.state)
                        ActivityDetail(state: context.state)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                ActivityLogo(size: 18)
            } compactTrailing: {
                Image(systemName: style.icon)
                    .foregroundStyle(style.tint)
                    .accessibilityLabel(Text(style.label))
            } minimal: {
                Image(systemName: style.icon)
                    .foregroundStyle(style.tint)
                    .accessibilityLabel(Text(style.label))
            }
            .widgetURL(activityURL(host: "open", tabID: context.state.tabID))
            .keylineTint(style.tint)
        }
    }
}

private struct ActivityStatusStyle {
    let tint: Color
    let icon: String
    let label: LocalizedStringKey
}

private extension RemoteActivityStatus {
    var widgetStyle: ActivityStatusStyle {
        switch self {
        case .approvalRequired:
            ActivityStatusStyle(tint: .orange, icon: "lock.shield.fill", label: "Approval")
        case .waitingInput:
            ActivityStatusStyle(tint: .orange, icon: "bubble.left.fill", label: "Needs input")
        case .failed:
            ActivityStatusStyle(tint: Color(red: 1, green: 0.42, blue: 0.38), icon: "exclamationmark.circle.fill", label: "Failed")
        case .completed:
            ActivityStatusStyle(tint: .green, icon: "checkmark.circle.fill", label: "Finished")
        case .running:
            ActivityStatusStyle(tint: .cyan, icon: "ellipsis", label: "Running")
        case .idle:
            ActivityStatusStyle(tint: .gray, icon: "terminal", label: "Idle")
        }
    }
}

private struct ActivityLogo: View {
    let size: CGFloat

    var body: some View {
        Image(.activityLogo)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct LockScreenActivityView: View {
    let state: Chau7RemoteActivityAttributes.ContentState

    var body: some View {
        let style = state.status.widgetStyle

        HStack(alignment: .top, spacing: 10) {
            ActivityLogo(size: 28)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                ActivityHeading(state: state)
                ActivityDetail(state: state)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: style.icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(style.tint)
                .frame(width: 26, height: 26)
                .background(style.tint.opacity(0.13), in: Circle())
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

private struct ActivityHeading: View {
    let state: Chau7RemoteActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.headline)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Text(state.projectName ?? state.tabTitle)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ActivityDetail: View {
    let state: Chau7RemoteActivityAttributes.ContentState

    var body: some View {
        if let detail = state.detail, !detail.isEmpty {
            Text(detail)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.84))
                .lineLimit(2)
        }

        // Review opens the approval card so protected commands retain their
        // in-app confirmation step.
        if let requestID = state.approvalRequestID {
            Link(destination: activityURL(host: "review", tabID: nil, requestID: requestID)) {
                Label("Review", systemImage: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.13), in: Capsule())
            }
        }
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
