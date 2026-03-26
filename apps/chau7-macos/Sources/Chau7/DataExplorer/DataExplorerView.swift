import SwiftUI
import Chau7Core

struct DataExplorerView: View {
    enum Tab: String, CaseIterable {
        case history = "History"
        case runs = "AI Runs"
        case sessions = "Sessions"
    }

    @State private var selectedTab: Tab = .runs

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            // Content
            switch selectedTab {
            case .history:
                HistoryExplorerView()
            case .runs:
                RunsExplorerView()
            case .sessions:
                SessionsExplorerView()
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}
