import Foundation

enum LocalBridge {
    static let port = 14_557
    static let protocolVersion = "7"
    static let keyboardHeartbeatInterval: Duration = .seconds(2)
    static let keyboardExitGracePeriod: TimeInterval = 10
    static let resultValidity: TimeInterval = 300

    static let commandURL = URL(string: "http://127.0.0.1:\(port)/command")!
    static let stateURL = URL(string: "http://127.0.0.1:\(port)/state")!
}

enum TranscriptionMode: String, Codable, CaseIterable, Sendable {
    case smart
    case verbatim

    var displayName: String {
        switch self {
        case .smart: "智能整理"
        case .verbatim: "原文模式"
        }
    }
}

enum InterfaceLanguage: String, Codable, CaseIterable, Sendable {
    case chinese
    case english

    func text(chinese: String, english: String) -> String {
        self == .chinese ? chinese : english
    }
}

enum BridgeAction: String, Codable, Sendable, Equatable {
    case state
    case heartbeat
    case startRecording
    case stopRecording
    case acknowledgeResult
}

struct BridgeRequest: Codable, Sendable {
    let action: BridgeAction
    let requestID: String?
    let mode: TranscriptionMode?

    init(
        action: BridgeAction,
        requestID: String? = nil,
        mode: TranscriptionMode? = nil
    ) {
        self.action = action
        self.requestID = requestID
        self.mode = mode
    }
}

enum BridgeStatus: String, Codable, Sendable {
    case idle
    case starting
    case recording
    case transcribing
    case completed
    case error
}

struct BridgeState: Codable, Sendable {
    let serverID: String?
    let revision: UInt64
    let serviceReady: Bool
    let microphoneReady: Bool
    let status: BridgeStatus
    let requestID: String?
    let transcribedText: String?
    let resultCreatedAt: Date?
    let lastError: String?
    let interfaceLanguage: InterfaceLanguage

    init(
        serverID: String?,
        revision: UInt64,
        serviceReady: Bool,
        microphoneReady: Bool = false,
        status: BridgeStatus,
        requestID: String?,
        transcribedText: String?,
        resultCreatedAt: Date?,
        lastError: String?,
        interfaceLanguage: InterfaceLanguage = .chinese
    ) {
        self.serverID = serverID
        self.revision = revision
        self.serviceReady = serviceReady
        self.microphoneReady = microphoneReady
        self.status = status
        self.requestID = requestID
        self.transcribedText = transcribedText
        self.resultCreatedAt = resultCreatedAt
        self.lastError = lastError
        self.interfaceLanguage = interfaceLanguage
    }

    static func unavailable(
        _ message: String? = nil,
        interfaceLanguage: InterfaceLanguage = .chinese
    ) -> BridgeState {
        BridgeState(
            serverID: nil,
            revision: 0,
            serviceReady: false,
            microphoneReady: false,
            status: .idle,
            requestID: nil,
            transcribedText: nil,
            resultCreatedAt: nil,
            lastError: message,
            interfaceLanguage: interfaceLanguage
        )
    }

    func isFreshResponse(for id: String) -> Bool {
        guard requestID == id, let resultCreatedAt else { return false }
        return Date().timeIntervalSince(resultCreatedAt) <= LocalBridge.resultValidity
    }
}

struct LocalBridgeClient: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchState() async throws -> BridgeState {
        var request = URLRequest(url: LocalBridge.stateURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        request.setValue(LocalBridge.protocolVersion, forHTTPHeaderField: "X-OpenLess-Protocol")
        return try await perform(request)
    }

    func send(
        _ action: BridgeAction,
        requestID: String? = nil,
        mode: TranscriptionMode? = nil
    ) async throws -> BridgeState {
        var request = URLRequest(url: LocalBridge.commandURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(LocalBridge.protocolVersion, forHTTPHeaderField: "X-OpenLess-Protocol")
        request.httpBody = try JSONEncoder().encode(
            BridgeRequest(
                action: action,
                requestID: requestID,
                mode: mode
            )
        )
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> BridgeState {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BridgeClientError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw BridgeClientError.http(http.statusCode)
        }
        return try JSONDecoder().decode(BridgeState.self, from: data)
    }

    enum BridgeClientError: LocalizedError {
        case invalidResponse
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                "OpenLess returned an invalid response."
            case .http(let status):
                "OpenLess communication failed (HTTP \(status))."
            }
        }
    }
}
