import SwiftUI
import AppKit

// MARK: - F02: Native Split Panes

/// Direction for splitting a pane
enum SplitDirection {
    case horizontal  // Side by side
    case vertical    // Stacked
}

/// Represents a node in the split pane tree
indirect enum SplitNode: Identifiable {
    case terminal(id: UUID, session: TerminalSessionModel)
    case split(id: UUID, direction: SplitDirection, first: SplitNode, second: SplitNode, ratio: CGFloat)

    var id: UUID {
        switch self {
        case .terminal(let id, _):
            return id
        case .split(let id, _, _, _, _):
            return id
        }
    }

    /// Gets all terminal IDs in this subtree
    var allTerminalIDs: [UUID] {
        switch self {
        case .terminal(let id, _):
            return [id]
        case .split(_, _, let first, let second, _):
            return first.allTerminalIDs + second.allTerminalIDs
        }
    }

    /// Finds a terminal session by ID
    func findSession(id: UUID) -> TerminalSessionModel? {
        switch self {
        case .terminal(let termId, let session):
            return termId == id ? session : nil
        case .split(_, _, let first, let second, _):
            return first.findSession(id: id) ?? second.findSession(id: id)
        }
    }
}

/// Manages split pane layout for a tab
final class SplitPaneController: ObservableObject {
    @Published var root: SplitNode
    @Published var focusedPaneID: UUID

    private weak var appModel: AppModel?

    init(appModel: AppModel) {
        self.appModel = appModel
        let session = TerminalSessionModel(appModel: appModel)
        let id = UUID()
        self.root = .terminal(id: id, session: session)
        self.focusedPaneID = id
    }

    // MARK: - Split Operations

    /// Splits the focused pane in the given direction
    func split(direction: SplitDirection) {
        guard FeatureSettings.shared.isSplitPanesEnabled else { return }
        guard let appModel else { return }

        root = splitNode(root, targetID: focusedPaneID, direction: direction, appModel: appModel)
    }

    private func splitNode(_ node: SplitNode, targetID: UUID, direction: SplitDirection, appModel: AppModel) -> SplitNode {
        switch node {
        case .terminal(let id, let session):
            if id == targetID {
                // Create new session for the split
                let newSession = TerminalSessionModel(appModel: appModel)
                let newID = UUID()

                // Create split node
                let newTerminal = SplitNode.terminal(id: newID, session: newSession)
                let oldTerminal = SplitNode.terminal(id: id, session: session)

                // Focus the new pane
                focusedPaneID = newID

                return .split(
                    id: UUID(),
                    direction: direction,
                    first: oldTerminal,
                    second: newTerminal,
                    ratio: 0.5
                )
            }
            return node

        case .split(let id, let dir, let first, let second, let ratio):
            return .split(
                id: id,
                direction: dir,
                first: splitNode(first, targetID: targetID, direction: direction, appModel: appModel),
                second: splitNode(second, targetID: targetID, direction: direction, appModel: appModel),
                ratio: ratio
            )
        }
    }

    /// Closes the focused pane
    func closeFocusedPane() {
        let result = removeNode(root, targetID: focusedPaneID)
        if let newRoot = result.node {
            root = newRoot
            // Focus the sibling or first available
            if let newFocus = result.siblingID ?? root.allTerminalIDs.first {
                focusedPaneID = newFocus
            }
        }
    }

    private func removeNode(_ node: SplitNode, targetID: UUID) -> (node: SplitNode?, siblingID: UUID?) {
        switch node {
        case .terminal(let id, let session):
            if id == targetID {
                session.closeSession()
                return (nil, nil)
            }
            return (node, nil)

        case .split(let id, let dir, let first, let second, let ratio):
            // Check if first child is the target
            if case .terminal(let firstID, _) = first, firstID == targetID {
                let result = removeNode(first, targetID: targetID)
                if result.node == nil {
                    return (second, second.allTerminalIDs.first)
                }
            }

            // Check if second child is the target
            if case .terminal(let secondID, _) = second, secondID == targetID {
                let result = removeNode(second, targetID: targetID)
                if result.node == nil {
                    return (first, first.allTerminalIDs.first)
                }
            }

            // Recurse into children
            let firstResult = removeNode(first, targetID: targetID)
            let secondResult = removeNode(second, targetID: targetID)

            if let newFirst = firstResult.node, let newSecond = secondResult.node {
                return (.split(id: id, direction: dir, first: newFirst, second: newSecond, ratio: ratio),
                        firstResult.siblingID ?? secondResult.siblingID)
            } else if let newFirst = firstResult.node {
                return (newFirst, firstResult.siblingID)
            } else if let newSecond = secondResult.node {
                return (newSecond, secondResult.siblingID)
            } else {
                return (nil, nil)
            }
        }
    }

    // MARK: - Navigation

    /// Focuses the next pane in order
    func focusNextPane() {
        let ids = root.allTerminalIDs
        guard ids.count > 1,
              let currentIndex = ids.firstIndex(of: focusedPaneID) else { return }
        let nextIndex = (currentIndex + 1) % ids.count
        focusedPaneID = ids[nextIndex]
    }

    /// Focuses the previous pane in order
    func focusPreviousPane() {
        let ids = root.allTerminalIDs
        guard ids.count > 1,
              let currentIndex = ids.firstIndex(of: focusedPaneID) else { return }
        let prevIndex = (currentIndex - 1 + ids.count) % ids.count
        focusedPaneID = ids[prevIndex]
    }

    /// Gets the focused session
    var focusedSession: TerminalSessionModel? {
        root.findSession(id: focusedPaneID)
    }

    // MARK: - Resize

    /// Adjusts the split ratio for the parent of the focused pane
    func adjustRatio(delta: CGFloat) {
        root = adjustRatioInNode(root, targetID: focusedPaneID, delta: delta)
    }

    private func adjustRatioInNode(_ node: SplitNode, targetID: UUID, delta: CGFloat) -> SplitNode {
        switch node {
        case .terminal:
            return node

        case .split(let id, let dir, let first, let second, var ratio):
            // Check if target is in first or second
            let firstIDs = first.allTerminalIDs
            let secondIDs = second.allTerminalIDs

            if firstIDs.contains(targetID) || secondIDs.contains(targetID) {
                // Adjust ratio at this level
                ratio = max(0.1, min(0.9, ratio + delta))
            }

            return .split(
                id: id,
                direction: dir,
                first: adjustRatioInNode(first, targetID: targetID, delta: delta),
                second: adjustRatioInNode(second, targetID: targetID, delta: delta),
                ratio: ratio
            )
        }
    }
}

// MARK: - Split Pane View

struct SplitPaneView: View {
    @ObservedObject var controller: SplitPaneController

    var body: some View {
        SplitNodeView(node: controller.root, focusedID: controller.focusedPaneID)
    }
}

struct SplitNodeView: View {
    let node: SplitNode
    let focusedID: UUID

    var body: some View {
        switch node {
        case .terminal(let id, let session):
            TerminalViewRepresentable(model: session, isSuspended: false)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(id == focusedID ? Color.accentColor : Color.clear, lineWidth: 2)
                        .padding(1)
                )

        case .split(_, let direction, let first, let second, let ratio):
            GeometryReader { geometry in
                if direction == .horizontal {
                    HStack(spacing: 2) {
                        SplitNodeView(node: first, focusedID: focusedID)
                            .frame(width: geometry.size.width * ratio)
                        Divider()
                        SplitNodeView(node: second, focusedID: focusedID)
                    }
                } else {
                    VStack(spacing: 2) {
                        SplitNodeView(node: first, focusedID: focusedID)
                            .frame(height: geometry.size.height * ratio)
                        Divider()
                        SplitNodeView(node: second, focusedID: focusedID)
                    }
                }
            }
        }
    }
}

// MARK: - Menu Commands Extension

extension AppDelegate {
    func splitHorizontally() {
        // Find the active split pane controller
        // This would need to be integrated with the tab model
        Log.info("F02: Split horizontal requested")
    }

    func splitVertically() {
        Log.info("F02: Split vertical requested")
    }
}
