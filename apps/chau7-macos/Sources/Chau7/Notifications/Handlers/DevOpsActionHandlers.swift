import Foundation
import Chau7Core

// MARK: - dockerBump

@MainActor
struct DockerBumpActionHandler: NotificationActionHandler {
    let supportedActionTypes: [NotificationActionType] = [.dockerBump]

    func execute(payload: ActionPayload, environment _: ActionEnvironment) -> NotificationActionExecutor.ExecutionReport {
        guard let container = payload.configValue("container"), !container.isEmpty else {
            Log.warn("Action dockerBump: No container specified")
            var report = NotificationActionExecutor.ExecutionReport()
            report.recordFailure("dockerBump missing container")
            return report
        }

        let operation = payload.configValue("operation") ?? "restart"
        let dockerPath = payload.configValue("dockerPath") ?? "/usr/local/bin/docker"

        switch operation {
        case "restart":
            runProcessAsync(executable: dockerPath, arguments: ["restart", container], label: "dockerBump")
        case "stop":
            runProcessAsync(executable: dockerPath, arguments: ["stop", container], label: "dockerBump")
        case "start":
            runProcessAsync(executable: dockerPath, arguments: ["start", container], label: "dockerBump")
        case "rebuild":
            DispatchQueue.global(qos: .userInitiated).async {
                let steps: [(args: [String], desc: String)] = [
                    (["stop", container], "stop"),
                    (["rm", container], "remove"),
                    (["build", "-t", container, "."], "build"),
                    (["run", "-d", "--name", container, container], "run")
                ]
                for step in steps {
                    guard runProcessSync(
                        executable: dockerPath,
                        arguments: step.args,
                        label: "dockerBump(\(step.desc))"
                    ) else { return }
                }
                Log.info("Action dockerBump: Rebuild completed successfully")
            }
        default:
            Log.warn("Action dockerBump: Unknown operation: \(operation)")
            var report = NotificationActionExecutor.ExecutionReport()
            report.recordFailure("dockerBump unknown operation: \(operation)")
            return report
        }
        var report = NotificationActionExecutor.ExecutionReport()
        report.recordSuccess(.dockerBump)
        return report
    }
}

// MARK: - dockerCompose

@MainActor
struct DockerComposeActionHandler: NotificationActionHandler {
    let supportedActionTypes: [NotificationActionType] = [.dockerCompose]

    func execute(payload: ActionPayload, environment _: ActionEnvironment) -> NotificationActionExecutor.ExecutionReport {
        guard let composePath = payload.configValue("composePath"), !composePath.isEmpty else {
            Log.warn("Action dockerCompose: No compose file path specified")
            var report = NotificationActionExecutor.ExecutionReport()
            report.recordFailure("dockerCompose missing composePath")
            return report
        }

        let operation = payload.configValue("operation") ?? "restart"
        let services = payload.configValue("services") ?? ""
        let dockerComposePath = payload.configValue("dockerComposePath") ?? "/usr/local/bin/docker-compose"

        let expandedPath = RuntimeIsolation.expandTilde(in: composePath)
        let serviceArgs = services.isEmpty ? [] : services.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        var args = ["-f", expandedPath]

        switch operation {
        case "up":
            args += ["up", "-d"] + serviceArgs
        case "down":
            args += ["down"] + serviceArgs
        case "restart":
            args += ["restart"] + serviceArgs
        case "build":
            args += ["build"] + serviceArgs
        case "pull":
            args += ["pull"] + serviceArgs
        default:
            Log.warn("Action dockerCompose: Unknown operation: \(operation)")
            var report = NotificationActionExecutor.ExecutionReport()
            report.recordFailure("dockerCompose unknown operation: \(operation)")
            return report
        }

        runProcessAsync(executable: dockerComposePath, arguments: args, label: "dockerCompose")
        var report = NotificationActionExecutor.ExecutionReport()
        report.recordSuccess(.dockerCompose)
        return report
    }
}

// MARK: - kubernetesRollout

@MainActor
struct KubernetesRolloutActionHandler: NotificationActionHandler {
    let supportedActionTypes: [NotificationActionType] = [.kubernetesRollout]

    func execute(payload: ActionPayload, environment _: ActionEnvironment) -> NotificationActionExecutor.ExecutionReport {
        guard let deployment = payload.configValue("deployment"), !deployment.isEmpty else {
            Log.warn("Action kubernetesRollout: No deployment specified")
            var report = NotificationActionExecutor.ExecutionReport()
            report.recordFailure("kubernetesRollout missing deployment")
            return report
        }

        let namespace = payload.configValue("namespace") ?? "default"
        let kubectlContext = payload.configValue("context")
        let operation = payload.configValue("operation") ?? "restart"
        let replicas = payload.configValue("replicas")
        let kubectlPath = payload.configValue("kubectlPath") ?? "/usr/local/bin/kubectl"

        var args: [String] = []
        if let kctx = kubectlContext, !kctx.isEmpty {
            args += ["--context", kctx]
        }
        args += ["-n", namespace]

        switch operation {
        case "restart":
            args += ["rollout", "restart", "deployment/\(deployment)"]
        case "scale":
            let replicaCount = replicas ?? "1"
            args += ["scale", "deployment/\(deployment)", "--replicas=\(replicaCount)"]
        case "status":
            args += ["rollout", "status", "deployment/\(deployment)"]
        default:
            Log.warn("Action kubernetesRollout: Unknown operation: \(operation)")
            var report = NotificationActionExecutor.ExecutionReport()
            report.recordFailure("kubernetesRollout unknown operation: \(operation)")
            return report
        }

        runProcessAsync(executable: kubectlPath, arguments: args, label: "kubernetesRollout")
        var report = NotificationActionExecutor.ExecutionReport()
        report.recordSuccess(.kubernetesRollout)
        return report
    }
}
