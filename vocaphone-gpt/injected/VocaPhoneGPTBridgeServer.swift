import Foundation
import Network

final class VocaPhoneGPTBridgeServer: @unchecked Sendable {
    typealias Handler = @Sendable (VocaPhoneGPTBridgeRequest) async -> VocaPhoneGPTBridgeState

    private let queue = DispatchQueue(label: "com.miketoryan.vocaphone-gpt.bridge")
    private var listener: NWListener?
    private var handler: Handler?

    func start(handler: @escaping Handler) {
        guard listener == nil else {
            self.handler = handler
            return
        }
        self.handler = handler
        guard let port = NWEndpoint.Port(rawValue: UInt16(VocaPhoneGPTBridge.port)) else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.receive(on: connection, buffer: Data())
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else { return }
                if case .failed = state {
                    listener.cancel()
                    if self.listener === listener { self.listener = nil }
                    self.queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        guard let self, self.listener == nil, let handler = self.handler else { return }
                        self.start(handler: handler)
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            listener = nil
        }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            guard let parsed = self.parse(accumulated) else {
                if complete || error != nil {
                    self.send(status: 400, data: Data(), on: connection)
                } else {
                    self.receive(on: connection, buffer: accumulated)
                }
                return
            }
            Task {
                let state = await self.handler?(parsed) ?? VocaPhoneGPTBridgeState(
                    ready: false, status: .error, requestID: parsed.requestID,
                    text: nil, error: "Bridge handler unavailable."
                )
                let encoded = (try? JSONEncoder().encode(state)) ?? Data()
                self.send(status: 200, data: encoded, on: connection)
            }
        }
    }

    private func parse(_ data: Data) -> VocaPhoneGPTBridgeRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator),
              let header = String(data: data[..<range.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2 {
                headers[String(pair[0]).lowercased()] = String(pair[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        guard headers["x-vocaphone-gpt-protocol"] == VocaPhoneGPTBridge.protocolVersion else { return nil }

        if method == "GET", path == "/state" {
            return VocaPhoneGPTBridgeRequest(action: .state)
        }
        guard method == "POST", path == "/command" else { return nil }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let start = range.upperBound
        guard data.count >= start + length else { return nil }
        return try? JSONDecoder().decode(
            VocaPhoneGPTBridgeRequest.self,
            from: Data(data[start..<(start + length)])
        )
    }

    private func send(status: Int, data: Data, on connection: NWConnection) {
        let reason = status == 200 ? "OK" : "Bad Request"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(data)
        connection.send(
            content: response,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }
}
