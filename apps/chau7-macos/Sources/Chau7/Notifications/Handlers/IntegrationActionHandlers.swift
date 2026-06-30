import Foundation
import Chau7Core

// MARK: - webhook

@MainActor
struct WebhookActionHandler: NotificationActionHandler {
    let supportedActionTypes: [NotificationActionType] = [.webhook]

    func execute(payload: ActionPayload, environment _: ActionEnvironment) -> NotificationActionExecutor.ExecutionReport {
        guard let urlString = payload.configValue("url"), let url = URL(string: urlString) else {
            Log.warn("Action webhook: Invalid URL")
            return .failure("webhook invalid URL")
        }

        let method = payload.configValue("method") ?? "POST"

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Chau7/1.0", forHTTPHeaderField: "User-Agent")

        if let headersJson = payload.configValue("headers"),
           let headersData = headersJson.data(using: .utf8),
           let headers = try? JSONSerialization.jsonObject(with: headersData) as? [String: String] {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        let webhookPayload: [String: Any]
        if let customPayload = payload.configValue("customPayload"), !customPayload.isEmpty,
           let customData = customPayload.data(using: .utf8),
           let custom = try? JSONSerialization.jsonObject(with: customData) as? [String: Any] {
            webhookPayload = custom
        } else {
            webhookPayload = payload.eventJSON()
        }

        if method != "GET" {
            request.httpBody = try? JSONSerialization.data(withJSONObject: webhookPayload)
        }

        NotificationActionHTTP.session.dataTask(with: request) { _, response, error in
            if let error = error {
                Log.error("Action webhook: Failed: \(error.localizedDescription)")
            } else if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode >= 200, httpResponse.statusCode < 300 {
                    Log.info("Action webhook: Success (\(httpResponse.statusCode))")
                } else {
                    Log.warn("Action webhook: HTTP \(httpResponse.statusCode)")
                }
            }
        }.resume()
        return .success(.webhook)
    }
}

// MARK: - sendSlack

@MainActor
struct SendSlackActionHandler: NotificationActionHandler {
    let supportedActionTypes: [NotificationActionType] = [.sendSlack]

    func execute(payload: ActionPayload, environment _: ActionEnvironment) -> NotificationActionExecutor.ExecutionReport {
        guard let webhookUrl = payload.configValue("webhookUrl"), let url = URL(string: webhookUrl) else {
            Log.warn("Action sendSlack: Invalid webhook URL")
            return .failure("sendSlack invalid webhook URL")
        }

        let username = payload.configValue("username") ?? "Chau7"
        let emoji = payload.configValue("emoji") ?? ":computer:"
        let channel = payload.configValue("channel")

        var slackPayload: [String: Any] = [
            "username": username,
            "icon_emoji": emoji,
            "text": payload.interpolate("*\(payload.event.type.capitalized)*: \(payload.event.message)")
        ]

        if let channel, !channel.isEmpty {
            slackPayload["channel"] = channel
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: slackPayload)

        NotificationActionHTTP.session.dataTask(with: request) { _, _, error in
            if let error = error {
                Log.error("Action sendSlack: Failed: \(error.localizedDescription)")
            } else {
                Log.info("Action sendSlack: Message sent")
            }
        }.resume()
        return .success(.sendSlack)
    }
}

// MARK: - sendDiscord

@MainActor
struct SendDiscordActionHandler: NotificationActionHandler {
    let supportedActionTypes: [NotificationActionType] = [.sendDiscord]

    func execute(payload: ActionPayload, environment _: ActionEnvironment) -> NotificationActionExecutor.ExecutionReport {
        guard let webhookUrl = payload.configValue("webhookUrl"), let url = URL(string: webhookUrl) else {
            Log.warn("Action sendDiscord: Invalid webhook URL")
            return .failure("sendDiscord invalid webhook URL")
        }

        let username = payload.configValue("username") ?? "Chau7"
        let avatarUrl = payload.configValue("avatarUrl")

        var discordPayload: [String: Any] = [
            "username": username,
            "content": payload.interpolate("**\(payload.event.type.capitalized)**: \(payload.event.message)")
        ]

        if let avatarUrl, !avatarUrl.isEmpty {
            discordPayload["avatar_url"] = avatarUrl
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: discordPayload)

        NotificationActionHTTP.session.dataTask(with: request) { _, _, error in
            if let error = error {
                Log.error("Action sendDiscord: Failed: \(error.localizedDescription)")
            } else {
                Log.info("Action sendDiscord: Message sent")
            }
        }.resume()
        return .success(.sendDiscord)
    }
}
