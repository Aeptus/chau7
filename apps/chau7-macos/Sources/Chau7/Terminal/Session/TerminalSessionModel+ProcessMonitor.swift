import Foundation
import Chau7Core

// MARK: - Process Resource Monitoring

// Extracted from TerminalSessionModel.swift
// Contains: hover card process info, CPU/memory polling.

extension TerminalSessionModel {
    func startProcessMonitoring() {
        guard let rustView = rustTerminalView else { return }
        let pid = rustView.shellPid
        guard pid > 0 else {
            processGroup = nil
            return
        }
        processGroup = nil // Clear stale data from a previous hover
        processResourceMonitor.onUpdate = { [weak self] snapshot in
            DispatchQueue.main.async { self?.processGroup = snapshot }
        }
        processResourceMonitor.start(shellPID: pid)
    }

    func stopProcessMonitoring() {
        processResourceMonitor.stop()
        processGroup = nil
    }

}
