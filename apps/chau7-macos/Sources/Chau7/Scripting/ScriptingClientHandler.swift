import Foundation

/// Handles a single connected client on the scripting socket.
/// Reads newline-delimited JSON messages, dispatches them to the ScriptingAPI,
/// and writes JSON responses back followed by a newline.
final class ScriptingClientHandler {
    typealias RequestHandler = @Sendable ([String: Any]) async -> [String: Any]
    typealias DisconnectHandler = @Sendable (Int32) -> Void

    private let fd: Int32
    private let queue: DispatchQueue
    private let onRequest: RequestHandler
    private let onDisconnect: DisconnectHandler
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private let maxLineLength = 1_048_576  // 1 MB max per JSON line

    init(
        fd: Int32,
        queue: DispatchQueue,
        onRequest: @escaping RequestHandler,
        onDisconnect: @escaping DisconnectHandler
    ) {
        self.fd = fd
        self.queue = queue
        self.onRequest = onRequest
        self.onDisconnect = onDisconnect
    }

    // MARK: - Lifecycle

    func startReading() {
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource?.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        readSource?.setCancelHandler { [weak self] in
            guard let self = self else { return }
            close(self.fd)
        }
        readSource?.resume()
    }

    func disconnect() {
        readSource?.cancel()
        readSource = nil
    }

    // MARK: - Reading

    private func readAvailable() {
        var readBuffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = read(fd, &readBuffer, readBuffer.count)

        if bytesRead <= 0 {
            // Client disconnected or error
            readSource?.cancel()
            readSource = nil
            onDisconnect(fd)
            return
        }

        buffer.append(contentsOf: readBuffer.prefix(bytesRead))
        processLines()
    }

    private func processLines() {
        // Process all complete newline-delimited JSON messages in the buffer
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]

            // Guard against excessively large lines
            guard lineData.count <= maxLineLength else {
                Log.warn("ScriptingClientHandler: line too long (\(lineData.count) bytes), dropping")
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                let errorResponse: [String: Any] = ["error": "request too large"]
                writeResponse(errorResponse)
                continue
            }

            // Remove the processed line (including newline) from the buffer
            buffer.removeSubrange(buffer.startIndex...newlineIndex)

            guard !lineData.isEmpty else { continue }

            // Parse JSON
            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                Log.warn("ScriptingClientHandler: invalid JSON from client")
                let errorResponse: [String: Any] = ["error": "invalid JSON"]
                writeResponse(errorResponse)
                continue
            }

            // Preserve the request id for JSON-RPC correlation
            let requestID = json["id"]

            // Dispatch to the request handler asynchronously
            let handler = onRequest
            let clientFD = fd
            Task { @MainActor [weak self] in
                let response = await handler(json)

                // Attach the request id to the response if provided
                var finalResponse = response
                if let rid = requestID {
                    finalResponse["id"] = rid
                }

                self?.writeResponse(finalResponse)
                _ = clientFD  // prevent unused variable warning
            }
        }

        // Safety: if the buffer grows beyond the max line length without a newline, discard it
        if buffer.count > maxLineLength {
            Log.warn("ScriptingClientHandler: buffer overflow, clearing")
            buffer.removeAll(keepingCapacity: true)
        }
    }

    // MARK: - Writing

    private func writeResponse(_ response: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) else {
            Log.error("ScriptingClientHandler: failed to serialize response")
            return
        }

        var payload = jsonData
        payload.append(UInt8(ascii: "\n"))

        let clientFD = fd
        queue.async {
            payload.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var totalWritten = 0
                while totalWritten < rawBuffer.count {
                    let written = write(clientFD, base + totalWritten, rawBuffer.count - totalWritten)
                    if written <= 0 {
                        Log.warn("ScriptingClientHandler: write failed to fd=\(clientFD)")
                        return
                    }
                    totalWritten += written
                }
            }
        }
    }
}
