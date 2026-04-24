import Foundation

/// Task-lifecycle plumbing (v1.1): observes `ProxyIPCServer`'s pending
/// candidates + active tasks streams, projects them onto the currently
/// selected tab, and drives the confirm / dismiss / assess UI flow.
///
/// Stored state (`currentCandidate`, `currentTask`, `isTaskAssessmentVisible`)
/// lives on the main class; the observers wired in `setupTaskObservers`
/// mutate them on the main queue so SwiftUI observation fires cleanly.
extension OverlayTabsModel {
    func setupTaskObservers() {
        MainActor.assumeIsolated {
            let ipc = ProxyIPCServer.shared

            // Observe pending candidates via didSet callback
            ipc.onPendingCandidatesChange = { [weak self] candidates in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.updateCurrentCandidate(from: candidates)
                }
            }

            // Observe active tasks via didSet callback
            ipc.onActiveTasksChange = { [weak self] tasks in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.updateCurrentTask(from: tasks)
                }
            }
        }
    }

    func updateCurrentCandidate(from candidates: [String: TaskCandidate]) {
        guard let session = selectedTab?.session else {
            currentCandidate = nil
            return
        }
        currentCandidate = candidates[session.tabIdentifier]
    }

    func updateCurrentTask(from tasks: [String: TrackedTask]) {
        guard let session = selectedTab?.session else {
            currentTask = nil
            return
        }
        currentTask = tasks[session.tabIdentifier]
    }

    func confirmTaskCandidate() {
        guard let candidate = currentCandidate,
              let session = selectedTab?.session else { return }

        Task {
            if let task = await ProxyManager.shared.startTask(
                tabId: session.tabIdentifier,
                taskName: nil,
                candidateId: candidate.id
            ) {
                await MainActor.run {
                    self.currentCandidate = nil
                    self.currentTask = task
                    Log.info("Task confirmed: \(task.name)")
                }
            } else {
                await MainActor.run {
                    Log.error("OverlayTabsModel: failed to confirm task candidate \(candidate.id)")
                }
            }
        }
    }

    func dismissTaskCandidate() {
        guard let candidate = currentCandidate,
              let session = selectedTab?.session else { return }

        Task {
            let dismissed = await ProxyManager.shared.dismissCandidate(
                tabId: session.tabIdentifier,
                candidateId: candidate.id
            )
            if dismissed {
                await MainActor.run {
                    self.currentCandidate = nil
                    Log.info("Task candidate dismissed")
                }
            } else {
                Log.error("OverlayTabsModel: failed to dismiss task candidate \(candidate.id)")
            }
        }
    }

    func showTaskAssessment() {
        guard currentTask != nil else { return }
        isTaskAssessmentVisible = true
    }

    func dismissTaskAssessment() {
        isTaskAssessmentVisible = false
    }

    func assessTask(approved: Bool, note: String?) {
        guard let task = currentTask else { return }

        Task {
            let success = await ProxyManager.shared.assessTask(
                taskId: task.id,
                approved: approved,
                note: note
            )
            if success {
                await MainActor.run {
                    self.isTaskAssessmentVisible = false
                    self.currentTask = nil
                    Log.info("Task assessed: \(approved ? "success" : "failed")")
                }
            } else {
                Log.error("OverlayTabsModel: failed to assess task \(task.id)")
            }
        }
    }
}
