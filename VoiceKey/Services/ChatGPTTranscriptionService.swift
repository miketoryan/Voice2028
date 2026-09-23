import Foundation

struct ChatGPTTranscriptionService {
    private let endpoint = URL(string: "https://chatgpt.com/backend-api/transcribe")!

    func transcribe(
        audioURL: URL,
        credential: ChatGPTAuthManager.Credential
    ) async throws -> String {
        let boundary = "Voice2028-\(UUID().uuidString)"
        let multipartURL = try makeMultipartBodyFile(
            audioURL: audioURL,
            boundary: boundary
        )
        defer { try? FileManager.default.removeItem(at: multipartURL) }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue("Codex Desktop/26.707.8479.0 (Windows; x64)", forHTTPHeaderField: "User-Agent")
        if let accountId = credential.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: multipartURL)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }

        guard http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            switch http.statusCode {
            case 401, 403:
                throw TranscriptionError.authenticationExpired
            case 429:
                throw TranscriptionError.rateLimited
            default:
                throw TranscriptionError.http(http.statusCode, detail)
            }
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptionError.noText
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeMultipartBodyFile(
        audioURL: URL,
        boundary: String
    ) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice2028-upload-\(UUID().uuidString)")
            .appendingPathExtension("multipart")

        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            let output = try FileHandle(forWritingTo: bodyURL)
            defer { try? output.close() }

            try output.write(contentsOf: Data(
                ("--\(boundary)\r\n" +
                 "Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\n" +
                 "Content-Type: audio/wav\r\n\r\n").utf8
            ))

            let input = try FileHandle(forReadingFrom: audioURL)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }

            try output.write(contentsOf: Data(
                "\r\n--\(boundary)--\r\n".utf8
            ))
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw error
        }

        return bodyURL
    }

    enum TranscriptionError: LocalizedError {
        case invalidResponse
        case authenticationExpired
        case rateLimited
        case http(Int, String)
        case noText

        var errorDescription: String? {
            switch self {
            case .invalidResponse: "Invalid transcription response."
            case .authenticationExpired: "ChatGPT authorization expired. Open Voice2028 and sign in again."
            case .rateLimited: "ChatGPT transcription is temporarily rate limited."
            case .http(let status, let detail):
                detail.isEmpty ? "Transcription failed (HTTP \(status))." : "Transcription failed (HTTP \(status)): \(detail)"
            case .noText: "No speech was recognized."
            }
        }
    }
}
