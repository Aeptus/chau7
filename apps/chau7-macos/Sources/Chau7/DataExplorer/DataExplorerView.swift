import SwiftUI
import Chau7Core

struct DataExplorerView: View {
    enum Tab: String, CaseIterable {
        case repos = "By Repo"
        case runs = "All Runs"
        case history = "Commands"
    }

    @State private var selectedTab: Tab = .repos

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
            case .repos:
                SessionsExplorerView()
            case .runs:
                RunsExplorerView()
            case .history:
                HistoryExplorerView()
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}
