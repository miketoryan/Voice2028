import Foundation
import Network

final class OVTLocalBridgeServer: @unchecked Sendable {
    typealias Handler = @Sendable (OVTLocalRequest) async -> OVTLocalState

    private let queue = DispatchQueue(label: "com.miketoryan.openvoicetypergpt.localbridge")
    private var listener: NWListener?
    private var handler: Handler?

    func start(handler: @escaping Handler) throws {
        stop()
        self.handler = handler
        guard let port = NWEndpoint.Port(rawValue: OVTLocalBridge.port) else {
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
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
                    let payload = (try? JSONEncoder().encode(state)) ?? Data()
                    self.send(status: 200, data: payload, on: connection)
                }
            case .incomplete:
                if complete || error != nil {
                    self.send(status: 400, data: Data(), on: connection)
                } else {
                    self.receive(on: connection, buffer: accumulated)
                }
            case .invalid:
                self.send(status: 400, data: Data(), on: connection)
            }
        }
    }

    private enum ParseResult {
        case request(OVTLocalRequest)
        case incomplete
        case invalid
    }

    private func parse(_ data: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else { return .incomplete }
        guard let header = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first else { return .invalid }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return .invalid }
        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            headers[String(pair[0]).lowercased()] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        guard headers["x-ovt-gpt-protocol"] == OVTLocalBridge.protocolVersion else { return .invalid }

        if method == "GET", path == "/state" {
            return .request(OVTLocalRequest(action: .state))
        }
        guard method == "POST", path == "/command" else { return .invalid }
        let length = Int(headers["content-length"] ?? "") ?? 0
        let start = headerRange.upperBound
        guard length > 0, data.count >= start + length else { return .incomplete }
        let body = Data(data[start..<(start + length)])
        guard let request = try? JSONDecoder().decode(OVTLocalRequest.self, from: body) else { return .invalid }
        return .request(request)
    }

    private func send(status: Int, data: Data, on connection: NWConnection) {
        let reason = switch status {
        case 200: "OK"
        case 413: "Payload Too Large"
        case 503: "Service Unavailable"
        default: "Bad Request"
        }
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
