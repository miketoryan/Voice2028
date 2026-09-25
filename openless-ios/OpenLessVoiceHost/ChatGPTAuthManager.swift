import AuthenticationServices
import CryptoKit
import Combine
import Foundation
import Security
import UIKit

@MainActor
final class ChatGPTAuthManager: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    struct Credential: Codable, Sendable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
        let accountId: String?
        let email: String?

        var isExpiringSoon: Bool {
            Date().addingTimeInterval(300) >= expiresAt
        }
    }

    private enum Config {
        static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
        static let authorizeURL = "https://auth.openai.com/oauth/authorize"
        static let tokenURL = "https://auth.openai.com/oauth/token"
        static let redirectURI = "http://localhost:1455/auth/callback"
        static let scopes = "openid profile email offline_access"
        static let keychainAccount = "voiceking.chatgpt.oauth"
    }

    @Published private(set) var credential: Credential?
    private var authSession: ASWebAuthenticationSession?

    override init() {
        super.init()
        if let data = KeychainStore.load(account: Config.keychainAccount),
           let saved = try? JSONDecoder().decode(Credential.self, from: data) {
            credential = saved
        }
    }

    var isSignedIn: Bool { credential != nil }

    func signOut() {
        credential = nil
        KeychainStore.delete(account: Config.keychainAccount)
    }

    func signIn() async throws {
        let verifier = Self.randomURLSafeString(byteCount: 32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafeString(byteCount: 24)

        guard var components = URLComponents(string: Config.authorizeURL) else {
            throw AuthError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Config.clientID),
            URLQueryItem(name: "redirect_uri", value: Config.redirectURI),
            URLQueryItem(name: "scope", value: Config.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "id_token_add_organizations", value: "true")
        ]

        guard let authorizationURL = components.url else {
            throw AuthError.invalidURL
        }

        let callbackServer = OAuthCallbackServer()
        let listener = try await callbackServer.start()
        defer { listener.cancel() }

        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: "openless"
            ) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: AuthError.missingCallback)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.authSession = session
            session.start()
        }

        authSession = nil

        guard let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw AuthError.invalidCallback
        }
        let params = Dictionary(uniqueKeysWithValues: (callbackComponents.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        guard params["state"] == state else { throw AuthError.stateMismatch }
        guard let code = params["code"] else {
            throw AuthError.authorizationDenied(params["error_description"] ?? params["error"] ?? "Unknown error")
        }

        let newCredential = try await tokenRequest(fields: [
            "grant_type": "authorization_code",
            "client_id": Config.clientID,
            "redirect_uri": Config.redirectURI,
            "code": code,
            "code_verifier": verifier
        ], existingRefreshToken: nil)

        try save(newCredential)
        credential = newCredential
    }

    func validCredential() async throws -> Credential {
        guard var current = credential else { throw AuthError.notSignedIn }
        if current.isExpiringSoon {
            guard !current.refreshToken.isEmpty else { throw AuthError.refreshUnavailable }
            current = try await tokenRequest(fields: [
                "grant_type": "refresh_token",
                "client_id": Config.clientID,
                "refresh_token": current.refreshToken
            ], existingRefreshToken: current.refreshToken)
            try save(current)
            credential = current
        }
        return current
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) {
            return window
        }
        return ASPresentationAnchor()
    }

    private func tokenRequest(fields: [String: String], existingRefreshToken: String?) async throws -> Credential {
        guard let url = URL(string: Config.tokenURL) else { throw AuthError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formEncode(fields).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "Unknown response"
            throw AuthError.tokenExchangeFailed(detail)
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["access_token"] as? String else {
            throw AuthError.invalidTokenResponse
        }

        let refreshToken = (object["refresh_token"] as? String) ?? existingRefreshToken ?? ""
        let expiresIn: TimeInterval = {
            if let value = object["expires_in"] as? TimeInterval { return value }
            if let value = object["expires_in"] as? Int { return TimeInterval(value) }
            return 3600
        }()

        let claims = Self.decodeJWTPayload(accessToken)
        let authClaims = claims?["https://api.openai.com/auth"] as? [String: Any]
        let profileClaims = claims?["https://api.openai.com/profile"] as? [String: Any]

        return Credential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn),
            accountId: (claims?["chatgpt_account_id"] as? String) ?? (authClaims?["chatgpt_account_id"] as? String),
            email: (claims?["email"] as? String) ?? (profileClaims?["email"] as? String)
        )
    }

    private func save(_ credential: Credential) throws {
        let data = try JSONEncoder().encode(credential)
        try KeychainStore.save(data, account: Config.keychainAccount)
    }

    private static func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ values: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return values.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
    }

    enum AuthError: LocalizedError {
        case invalidURL
        case missingCallback
        case invalidCallback
        case stateMismatch
        case authorizationDenied(String)
        case tokenExchangeFailed(String)
        case invalidTokenResponse
        case notSignedIn
        case refreshUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidURL: "Invalid OAuth URL."
            case .missingCallback: "No OAuth callback was received."
            case .invalidCallback: "The OAuth callback was invalid."
            case .stateMismatch: "OAuth state validation failed."
            case .authorizationDenied(let message): "Sign in failed: \(message)"
            case .tokenExchangeFailed(let message): "Token exchange failed: \(message)"
            case .invalidTokenResponse: "OpenAI returned an invalid token response."
            case .notSignedIn: "Sign in with ChatGPT first."
            case .refreshUnavailable: "The ChatGPT session cannot be refreshed. Sign in again."
            }
        }
    }
}
