import Foundation

enum VocaPhoneGPTBridge {
    static let port = 14558
    static let protocolVersion = "1"
    static let commandURL = URL(string: "http://127.0.0.1:\(port)/command")!
    static let stateURL = URL(string: "http://127.0.0.1:\(port)/state")!
}

enum VocaPhoneGPTBridgeAction: String, Codable, Sendable {
    case state
    case start
    case stop
    case acknowledge
}

struct VocaPhoneGPTBridgeRequest: Codable, Sendable {
    let action: VocaPhoneGPTBridgeAction
    let requestID: String?
    let mode: String?

    init(action: VocaPhoneGPTBridgeAction, requestID: String? = nil, mode: String? = nil) {
        self.action = action
        self.requestID = requestID
        self.mode = mode
    }
}

enum VocaPhoneGPTBridgeStatus: String, Codable, Sendable {
    case idle
    case starting
    case recording
    case transcribing
    case completed
    case error
}

struct VocaPhoneGPTBridgeState: Codable, Sendable {
    let ready: Bool
    let status: VocaPhoneGPTBridgeStatus
    let requestID: String?
    let text: String?
    let error: String?
}

struct VocaPhoneGPTBridgeClient: Sendable {
    private let session = URLSession.shared

    func fetchState() async throws -> VocaPhoneGPTBridgeState {
        var request = URLRequest(url: VocaPhoneGPTBridge.stateURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 1.5
        request.setValue(VocaPhoneGPTBridge.protocolVersion, forHTTPHeaderField: "X-VocaPhone-GPT-Protocol")
        return try await perform(request)
    }

    func send(
        _ action: VocaPhoneGPTBridgeAction,
        requestID: String? = nil,
        mode: String? = nil
    ) async throws -> VocaPhoneGPTBridgeState {
        var request = URLRequest(url: VocaPhoneGPTBridge.commandURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(VocaPhoneGPTBridge.protocolVersion, forHTTPHeaderField: "X-VocaPhone-GPT-Protocol")
        request.httpBody = try JSONEncoder().encode(
            VocaPhoneGPTBridgeRequest(action: action, requestID: requestID, mode: mode)
        )
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> VocaPhoneGPTBridgeState {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.cannotConnectToHost)
        }
        return try JSONDecoder().decode(VocaPhoneGPTBridgeState.self, from: data)
    }
}
