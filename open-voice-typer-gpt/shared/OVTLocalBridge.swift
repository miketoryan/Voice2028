import Foundation

enum OVTLocalBridge {
    static let port: UInt16 = 14559
    static let protocolVersion = "1"
    static let stateURL = URL(string: "http://127.0.0.1:\(port)/state")!
    static let commandURL = URL(string: "http://127.0.0.1:\(port)/command")!
}

enum OVTLocalAction: String, Codable, Sendable {
    case state
    case start
    case stop
    case cancel
    case acknowledge
}

enum OVTLocalPhase: String, Codable, Sendable {
    case idle
    case recording
    case transcribing
    case polishing
    case completed
    case error
}

struct OVTLocalRequest: Codable, Sendable {
    let action: OVTLocalAction
    let requestID: UUID?
    let styleID: String?

    init(action: OVTLocalAction, requestID: UUID? = nil, styleID: String? = nil) {
        self.action = action
        self.requestID = requestID
        self.styleID = styleID
    }
}

struct OVTLocalState: Codable, Sendable {
    let revision: UInt64
    let serviceReady: Bool
    let phase: OVTLocalPhase
    let requestID: UUID?
    let audioLevel: Float
    let text: String?
    let error: String?

    static let unavailable = OVTLocalState(
        revision: 0,
        serviceReady: false,
        phase: .idle,
        requestID: nil,
        audioLevel: 0,
        text: nil,
        error: nil
    )
}

struct OVTLocalBridgeClient: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchState() async throws -> OVTLocalState {
        var request = URLRequest(url: OVTLocalBridge.stateURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 1.5
        request.setValue(OVTLocalBridge.protocolVersion, forHTTPHeaderField: "X-OVT-GPT-Protocol")
        return try await perform(request)
    }

    func send(_ action: OVTLocalAction, requestID: UUID? = nil, styleID: String? = nil) async throws -> OVTLocalState {
        var request = URLRequest(url: OVTLocalBridge.commandURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(OVTLocalBridge.protocolVersion, forHTTPHeaderField: "X-OVT-GPT-Protocol")
        request.httpBody = try JSONEncoder().encode(
            OVTLocalRequest(action: action, requestID: requestID, styleID: styleID)
        )
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> OVTLocalState {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(OVTLocalState.self, from: data)
    }
}
