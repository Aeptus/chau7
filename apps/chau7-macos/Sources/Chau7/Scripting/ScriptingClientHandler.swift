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
    private let maxLineLength = 1_048_576 // 1 MB max per JSON line
    private let writeQueue: DispatchQueue

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
        self.writeQueue = DispatchQueue(label: "com.chau7.scripting.client.\(fd).write", qos: .userInitiated)
    }

    // MARK: - Lifecycle

    func startReading() {
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource?.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        readSource?.setCancelHandler { [weak self] in
            guard let self = self else { return }
            close(fd)
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
            let lineData = buffer[buffer.startIndex ..< newlineIndex]

            // Guard against excessively large lines
            guard lineData.count <= maxLineLength else {
                Log.warn("ScriptingClientHandler: line too long (\(lineData.count) bytes), dropping")
                buffer.removeSubrange(buffer.startIndex ... newlineIndex)
                let errorResponse: [String: Any] = ["error": "request too large"]
                writeResponse(errorResponse, method: "(decode)")
                continue
            }

            // Remove the processed line (including newline) from the buffer
            buffer.removeSubrange(buffer.startIndex ... newlineIndex)

            guard !lineData.isEmpty else { continue }

            // Parse JSON
            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                Log.warn("ScriptingClientHandler: invalid JSON from client")
                let errorResponse: [String: Any] = ["error": "invalid JSON"]
                writeResponse(errorResponse, method: "(decode)")
                continue
            }

            // Preserve the request id for JSON-RPC correlation
            let requestID = json["id"]

            // Dispatch to the request handler asynchronously
            let handler = onRequest
            let clientFD = fd
            let method = json["method"] as? String ?? "(unknown)"
            Task { @MainActor [weak self] in
                let response = await handler(json)

                // Attach the request id to the response if provided
                var finalResponse = response
                if let rid = requestID {
                    finalResponse["id"] = rid
                }

                self?.writeResponse(finalResponse, method: method)
                _ = clientFD // prevent unused variable warning
            }
        }

        // Safety: if the buffer grows beyond the max line length without a newline, discard it
        if buffer.count > maxLineLength {
            Log.warn("ScriptingClientHandler: buffer overflow, clearing")
            buffer.removeAll(keepingCapacity: true)
        }
    }

    // MARK: - Writing

    private func writeResponse(_ response: [String: Any], method: String) {
        guard let normalized = normalizeJSONObject(response) else {
            let valueTypes = response.map { key, value in
                "\(key)=\(String(describing: type(of: value)))"
            }.sorted().joined(separator: ", ")
            Log.error("ScriptingClientHandler: failed to normalize response for method=\(method) keys=[\(valueTypes)]")
            let errorResponse: [String: Any] = ["error": "response_normalization_failed", "method": method]
            writeRawResponse(errorResponse, method: method)
            return
        }
        writeRawResponse(normalized, method: method)
    }

    private func writeRawResponse(_ response: [String: Any], method: String) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) else {
            Log.error("ScriptingClientHandler: failed to serialize response for method=\(method)")
            return
        }
        var payload = jsonData
        payload.append(UInt8(ascii: "\n"))

        let clientFD = fd
        Log.trace("ScriptingClientHandler: writing response for method=\(method) bytes=\(payload.count)")
        writeQueue.async {
            payload.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var totalWritten = 0
                while totalWritten < rawBuffer.count {
                    let written = write(clientFD, base + totalWritten, rawBuffer.count - totalWritten)
                    if written <= 0 {
                        Log.warn("ScriptingClientHandler: write failed to fd=\(clientFD) method=\(method)")
                        return
                    }
                    totalWritten += written
                }
            }
            Log.trace("ScriptingClientHandler: wrote response for method=\(method)")
        }
    }

    private func normalizeJSONObject(_ object: [String: Any]) -> [String: Any]? {
        var normalized: [String: Any] = [:]
        normalized.reserveCapacity(object.count)
        for (key, value) in object {
            guard let safeValue = normalizeJSONValue(value) else {
                return nil
            }
            normalized[key] = safeValue
        }
        return normalized
    }

    private func normalizeJSONValue(_ value: Any) -> Any? {
        switch value {
        case let object as [String: Any]:
            return normalizeJSONObject(object)
        case let array as [Any]:
            var normalized: [Any] = []
            normalized.reserveCapacity(array.count)
            for item in array {
                guard let safeItem = normalizeJSONValue(item) else {
                    return nil
                }
                normalized.append(safeItem)
            }
            return normalized
        case let string as String:
            return string
        case let int as Int:
            return NSNumber(value: int)
        case let int8 as Int8:
            return NSNumber(value: int8)
        case let int16 as Int16:
            return NSNumber(value: int16)
        case let int32 as Int32:
            return NSNumber(value: int32)
        case let int64 as Int64:
            return NSNumber(value: int64)
        case let uint as UInt:
            if uint <= UInt(Int64.max) {
                return NSNumber(value: Int64(uint))
            }
            return String(uint)
        case let uint8 as UInt8:
            return NSNumber(value: uint8)
        case let uint16 as UInt16:
            return NSNumber(value: uint16)
        case let uint32 as UInt32:
            return NSNumber(value: uint32)
        case let uint64 as UInt64:
            if uint64 <= UInt64(Int64.max) {
                return NSNumber(value: Int64(uint64))
            }
            return String(uint64)
        case let float as Float:
            guard float.isFinite else { return nil }
            return NSNumber(value: float)
        case let double as Double:
            guard double.isFinite else { return nil }
            return NSNumber(value: double)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            return number
        case let bool as Bool:
            return bool
        case _ as NSNull:
            return NSNull()
        default:
            return nil
        }
    }
}
