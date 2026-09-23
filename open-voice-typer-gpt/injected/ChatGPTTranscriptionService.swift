import Foundation

struct ChatGPTTranscriptionService {
    private let endpoint = URL(string: "https://chatgpt.com/backend-api/transcribe")!

    func transcribe(wavData: Data, credential: ChatGPTAuthManager.Credential) async throws -> String {
        let boundary = "OpenVoiceTyperGPT-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(wavData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue("OpenVoiceTyper-GPT/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        if let accountId = credential.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 600

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Error.invalidResponse }
        guard http.statusCode == 200 else {
            let detail = String(data: Data(data.prefix(1000)), encoding: .utf8) ?? ""
            switch http.statusCode {
            case 401, 403: throw Error.authenticationExpired
            case 429: throw Error.rateLimited
            default: throw Error.http(http.statusCode, detail)
            }
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.noText
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum Error: LocalizedError {
        case invalidResponse, authenticationExpired, rateLimited, noText
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: "ChatGPT 返回了无效的语音识别响应。"
            case .authenticationExpired: "ChatGPT 登录已失效，请重新登录。"
            case .rateLimited: "ChatGPT 语音识别暂时达到频率限制。"
            case .http(let status, let detail):
                detail.isEmpty ? "语音识别失败（HTTP \(status)）。" : "语音识别失败（HTTP \(status)）：\(detail)"
            case .noText: "没有识别到语音。"
            }
        }
    }
}
