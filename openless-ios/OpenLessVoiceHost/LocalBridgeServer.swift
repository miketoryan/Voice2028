import Foundation
import Network

final class LocalBridgeServer: @unchecked Sendable {
    typealias Handler = @Sendable (BridgeRequest) async -> BridgeState

    private let queue = DispatchQueue(label: "com.miketoryan.OpenLess.local-bridge")
    private var listener: NWListener?
    private var handler: Handler?
    private var shouldRun = false

    func start(handler: @escaping Handler) throws {
        stop()
        self.handler = handler
        shouldRun = true
        try startListener()
    }

    private func startListener() throws {

        guard let port = NWEndpoint.Port(rawValue: UInt16(LocalBridge.port)) else {
            throw ServerError.invalidPort
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.receiveRequest(on: connection, buffer: Data())
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            if case .failed = state {
                listener.cancel()
                if self.listener === listener {
                    self.listener = nil
                }
                self.scheduleRestart()
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        shouldRun = false
        listener?.cancel()
        listener = nil
        handler = nil
    }

    private func scheduleRestart() {
        guard shouldRun else { return }
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.shouldRun, self.listener == nil else { return }
            do {
                try self.startListener()
            } catch {
                self.scheduleRestart()
            }
        }
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.start(queue: queue)
        receiveMore(on: connection, buffer: buffer)
    }

    private func receiveMore(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }

            if accumulated.count > 65_536 {
                self.send(status: 413, data: Data(), on: connection)
                return
            }

            switch self.parse(accumulated) {
            case .request(let request):
                guard let handler = self.handler else {
                    self.send(status: 503, data: Data(), on: connection)
                    return
                }

                Task {
                    let state = await handler(request)
                    let data = (try? JSONEncoder().encode(state)) ?? Data()
                    self.send(status: 200, data: data, on: connection)
                }

            case .incomplete:
                if isComplete || error != nil {
                    self.send(status: 400, data: Data(), on: connection)
                } else {
                    self.receiveMore(on: connection, buffer: accumulated)
                }

            case .invalid:
                self.send(status: 400, data: Data(), on: connection)
            }
        }
    }

    private func parse(_ data: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else { return .incomplete }

        let headerData = data[..<headerRange.lowerBound]
        guard let header = String(data: headerData, encoding: .utf8) else { return .invalid }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .invalid }

        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else { return .invalid }
        let method = String(requestParts[0])
        let path = String(requestParts[1])

        let headerPairs = lines.dropFirst().compactMap { line -> (String, String)? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (
                parts[0].trimmingCharacters(in: .whitespaces).lowercased(),
                parts[1].trimmingCharacters(in: .whitespaces)
            )
        }
        let headers = headerPairs.reduce(into: [String: String]()) { result, pair in
            result[pair.0] = pair.1
        }
        guard headers["x-voiceking-protocol"] == LocalBridge.protocolVersion else {
            return .invalid
        }

        let contentLength = Int(headers["content-length"] ?? "") ?? 0

        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return .incomplete }

        if method == "GET", path == "/state" {
            return .request(BridgeRequest(action: .state))
        }

        guard method == "POST", path == "/command", contentLength > 0 else {
            return .invalid
        }

        let body = Data(data[bodyStart..<(bodyStart + contentLength)])
        guard let request = try? JSONDecoder().decode(BridgeRequest.self, from: body) else {
            return .invalid
        }
        return .request(request)
    }

    private func send(status: Int, data: Data, on connection: NWConnection) {
        let reason = switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 413: "Payload Too Large"
        case 503: "Service Unavailable"
        default: "Error"
        }

        let header = "HTTP/1.1 \(status) \(reason)\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(data.count)\r\n" +
            "Connection: close\r\n\r\n"

        var response = Data(header.utf8)
        response.append(data)
        connection.send(
            content: response,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    enum ServerError: LocalizedError {
        case invalidPort

        var errorDescription: String? {
            "OpenLess local communication port is invalid."
        }
    }

    private enum ParseResult {
        case request(BridgeRequest)
        case incomplete
        case invalid
    }
}
