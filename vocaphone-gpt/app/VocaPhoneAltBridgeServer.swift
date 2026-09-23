import Foundation
import Network

final class VocaPhoneAltBridgeServer: @unchecked Sendable {
    typealias Handler = @Sendable (VocaPhoneAltBridgeRequest) async -> VocaPhoneAltBridgeState

    private let queue = DispatchQueue(label: "com.vocahq.vocaphone.gpt.altbridge")
    private var listener: NWListener?
    private var handler: Handler?

    func start(handler: @escaping Handler) throws {
        stop()
        self.handler = handler
        guard let port = NWEndpoint.Port(rawValue: VocaPhoneAltBridge.port) else {
            throw URLError(.badURL)
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.receive(on: connection, buffer: Data())
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        handler = nil
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if let request = self.parse(accumulated) {
                guard let handler = self.handler else {
                    self.send(status: 503, data: Data(), on: connection)
                    return
                }
                Task {
                    let state = await handler(request)
                    let payload = (try? JSONEncoder().encode(state)) ?? Data()
                    self.send(status: 200, data: payload, on: connection)
                }
            } else if complete || error != nil {
                self.send(status: 400, data: Data(), on: connection)
            } else {
                self.receive(on: connection, buffer: accumulated)
            }
        }
    }

    private func parse(_ data: Data) -> VocaPhoneAltBridgeRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator),
              let header = String(data: data[..<headerRange.lowerBound], encoding: .utf8)
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
            guard pair.count == 2 else { continue }
            headers[String(pair[0]).lowercased()] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        guard headers["x-vocaphone-gpt-protocol"] == VocaPhoneAltBridge.protocolVersion else { return nil }

        if method == "GET", path == "/state" {
            return VocaPhoneAltBridgeRequest(action: .state)
        }

        guard method == "POST", path == "/command" else { return nil }
        let length = Int(headers["content-length"] ?? "") ?? 0
        let start = headerRange.upperBound
        guard data.count >= start + length, length > 0 else { return nil }
        let body = Data(data[start..<(start + length)])
        return try? JSONDecoder().decode(VocaPhoneAltBridgeRequest.self, from: body)
    }

    private func send(status: Int, data: Data, on connection: NWConnection) {
        let reason = status == 200 ? "OK" : status == 503 ? "Service Unavailable" : "Bad Request"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(data)
        connection.send(
            content: response,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }
}
