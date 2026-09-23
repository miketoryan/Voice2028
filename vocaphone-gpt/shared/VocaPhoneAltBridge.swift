import Foundation

enum VocaPhoneAltBridge {
    static let port: UInt16 = 14558
    static let protocolVersion = "1"
    static let commandURL = URL(string: "http://127.0.0.1:\(port)/command")!
    static let stateURL = URL(string: "http://127.0.0.1:\(port)/state")!
}

enum VocaPhoneAltBridgeAction: String, Codable, Sendable {
    case state
    case start
    case stop
    case cancel
    case acknowledge
}

enum VocaPhoneAltBridgeMode: String, Codable, Sendable {
    case smart
    case verbatim
}

enum VocaPhoneAltBridgeStatus: String, Codable, Sendable {
    case idle
    case starting
    case recording
    case transcribing
    case completed
    case error
}

struct VocaPhoneAltBridgeRequest: Codable, Sendable {
    let action: VocaPhoneAltBridgeAction
    let requestID: String?
    let mode: VocaPhoneAltBridgeMode?

    init(action: VocaPhoneAltBridgeAction, requestID: String? = nil, mode: VocaPhoneAltBridgeMode? = nil) {
        self.action = action
        self.requestID = requestID
        self.mode = mode
    }
}

struct VocaPhoneAltBridgeState: Codable, Sendable {
    let revision: UInt64
    let serviceReady: Bool
    let status: VocaPhoneAltBridgeStatus
    let requestID: String?
    let text: String?
    let error: String?
}

struct VocaPhoneAltBridgeClient: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchState() async throws -> VocaPhoneAltBridgeState {
        var request = URLRequest(url: VocaPhoneAltBridge.stateURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 1.5
        request.setValue(VocaPhoneAltBridge.protocolVersion, forHTTPHeaderField: "X-VocaPhone-GPT-Protocol")
        return try await perform(request)
    }

    func send(
        _ action: VocaPhoneAltBridgeAction,
        requestID: String? = nil,
        mode: VocaPhoneAltBridgeMode? = nil
    ) async throws -> VocaPhoneAltBridgeState {
        var request = URLRequest(url: VocaPhoneAltBridge.commandURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(VocaPhoneAltBridge.protocolVersion, forHTTPHeaderField: "X-VocaPhone-GPT-Protocol")
        request.httpBody = try JSONEncoder().encode(
            VocaPhoneAltBridgeRequest(action: action, requestID: requestID, mode: mode)
        )
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> VocaPhoneAltBridgeState {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(VocaPhoneAltBridgeState.self, from: data)
    }
}
