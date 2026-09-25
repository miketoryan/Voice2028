import Foundation
import UIKit

@objc(OpenLessVoiceRuntime)
@MainActor
final class OpenLessVoiceRuntime: NSObject {
    static let shared = OpenLessVoiceRuntime()

    private let auth = ChatGPTAuthManager()
    private let audio = AudioService()
    private let transcriber = ChatGPTTranscriptionService()
    private let cleanup = ChatGPTCleanupService()
    private let bridge = LocalBridgeServer()

    private var didBootstrap = false
    private var serviceReady = false
    private var status: BridgeStatus = .idle
    private var revision: UInt64 = 0
    private var serverID = UUID().uuidString
    private var activeRequestID: String?
    private var activeMode: TranscriptionMode = .smart
    private var recordingURL: URL?
    private var resultText: String?
    private var resultCreatedAt: Date?
    private var lastError: String?
    private var lastHeartbeat: Date?
    private var monitorTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var loginPromptVisible = false

    @objc static func startShared() {
        shared.bootstrap()
    }

    private func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true

        do {
            try bridge.start { [weak self] request in
                guard let self else {
                    return BridgeState.unavailable("OpenLess voice service is not running.")
                }
                return await self.handle(request)
            }
        } catch {
            lastError = error.localizedDescription
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        Task { [weak self] in
            await self?.prepareIfPossible()
        }
    }

    @objc private func applicationDidBecomeActive() {
        Task { [weak self] in
            await self?.prepareIfPossible()
        }
    }

    private func prepareIfPossible() async {
        guard auth.isSignedIn else {
            serviceReady = false
            status = .idle
            bump()
            scheduleLoginPrompt()
            return
        }

        guard !serviceReady else { return }
        let granted = await AudioService.requestPermission()
        guard granted else {
            publishError("请允许 OpenLess 使用麦克风。")
            return
        }

        do {
            try audio.enterStandby()
            serviceReady = true
            status = .idle
            lastError = nil
            bump()
        } catch {
            publishError(error.localizedDescription)
        }
    }

    private func scheduleLoginPrompt() {
        guard !loginPromptVisible else { return }
        loginPromptVisible = true

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self else { return }
            guard !self.auth.isSignedIn else {
                self.loginPromptVisible = false
                return
            }

            guard let presenter = Self.topViewController() else {
                self.loginPromptVisible = false
                return
            }

            let alert = UIAlertController(
                title: "GPT 语音识别",
                message: "登录 ChatGPT 后，OpenLess 可直接使用 GPT 语音识别，不需要填写 API Key。",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "稍后", style: .cancel) { [weak self] _ in
                self?.loginPromptVisible = false
            })
            alert.addAction(UIAlertAction(title: "登录 ChatGPT", style: .default) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    defer { self.loginPromptVisible = false }
                    do {
                        try await self.auth.signIn()
                        await self.prepareIfPossible()
                    } catch {
                        self.publishError(error.localizedDescription)
                    }
                }
            })
            presenter.present(alert, animated: true)
        }
    }

    private func handle(_ request: BridgeRequest) async -> BridgeState {
        switch request.action {
        case .state:
            break

        case .heartbeat:
            lastHeartbeat = Date()
            startMonitorIfNeeded()

        case .startRecording:
            lastHeartbeat = Date()
            await startRecording(
                requestID: request.requestID,
                mode: request.mode ?? .smart
            )

        case .stopRecording:
            lastHeartbeat = Date()
            beginFinish(expectedRequestID: request.requestID)

        case .acknowledgeResult:
            if request.requestID == nil || request.requestID == activeRequestID {
                activeRequestID = nil
                resultText = nil
                resultCreatedAt = nil
                lastError = nil
                if status == .completed || status == .error {
                    status = .idle
                }
                bump()
            }
        }

        return currentState()
    }

    private func startRecording(requestID: String?, mode: TranscriptionMode) async {
        guard auth.isSignedIn else {
            publishError("请先打开 OpenLess 并登录 ChatGPT。", requestID: requestID)
            return
        }

        if !serviceReady {
            await prepareIfPossible()
        }
        guard serviceReady else { return }

        guard let requestID, !requestID.isEmpty else {
            publishError("录音请求无效。")
            return
        }

        guard status != .recording && status != .transcribing && status != .starting else {
            return
        }

        activeRequestID = requestID
        activeMode = mode
        resultText = nil
        resultCreatedAt = nil
        lastError = nil
        status = .starting
        bump()

        do {
            if !audio.isRunning {
                try await performAudioOperationWithRetry {
                    try self.audio.arm()
                }
            }
            recordingURL = try audio.beginCapture()
            status = .recording
            startMonitorIfNeeded()
            bump()
        } catch {
            publishError(error.localizedDescription, requestID: requestID)
            do {
                try audio.enterStandby()
                serviceReady = true
            } catch {
                audio.disarm()
                serviceReady = false
            }
        }
    }

    private func beginFinish(expectedRequestID: String?) {
        guard status == .recording else { return }
        guard let requestID = activeRequestID,
              expectedRequestID == nil || expectedRequestID == requestID else { return }

        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in
            await self?.finishRecording(requestID: requestID)
        }
    }

    private func finishRecording(requestID: String) async {
        let url = audio.endCapture() ?? recordingURL
        recordingURL = nil

        guard let url else {
            publishError("没有录到有效音频。", requestID: requestID)
            return
        }

        status = .transcribing
        bump()

        defer {
            try? FileManager.default.removeItem(at: url)
        }

        do {
            let credential = try await auth.validCredential()
            let raw = try await transcriber.transcribe(
                audioURL: url,
                credential: credential,
                language: "zh"
            )

            let finalText: String
            if activeMode == .smart {
                do {
                    finalText = try await cleanup.clean(
                        transcript: raw,
                        credential: credential
                    )
                } catch {
                    finalText = raw
                }
            } else {
                finalText = raw
            }

            resultText = finalText
            resultCreatedAt = Date()
            lastError = nil
            status = .completed
            bump()
        } catch {
            publishError(error.localizedDescription, requestID: requestID)
        }
    }

    private func startMonitorIfNeeded() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }

                guard let self else { return }
                guard self.serviceReady else { return }

                if let heartbeat = self.lastHeartbeat,
                   Date().timeIntervalSince(heartbeat) < LocalBridge.keyboardExitGracePeriod {
                    continue
                }

                if self.status == .recording,
                   let requestID = self.activeRequestID {
                    self.beginFinish(expectedRequestID: requestID)
                }

                do {
                    try self.audio.enterStandby()
                    self.serviceReady = true
                } catch {
                    self.audio.disarm()
                    self.serviceReady = false
                }

                self.lastHeartbeat = nil
                self.monitorTask = nil
                self.bump()
                return
            }
        }
    }

    private func performAudioOperationWithRetry(
        _ operation: () throws -> Void
    ) async throws {
        var retry = 0
        while true {
            do {
                try operation()
                return
            } catch {
                let code = (error as NSError).code
                guard (code == 560_557_684 || code == 2_003_329_396), retry < 4 else {
                    throw error
                }
                retry += 1
                try await Task.sleep(for: .milliseconds(150 * retry))
            }
        }
    }

    private func publishError(_ message: String, requestID: String? = nil) {
        if let requestID {
            activeRequestID = requestID
        }
        resultText = nil
        resultCreatedAt = Date()
        lastError = message
        status = .error
        bump()
    }

    private func bump() {
        revision &+= 1
    }

    private func currentState() -> BridgeState {
        BridgeState(
            serverID: serverID,
            revision: revision,
            serviceReady: serviceReady,
            microphoneReady: audio.isRunning,
            status: status,
            requestID: activeRequestID,
            transcribedText: resultText,
            resultCreatedAt: resultCreatedAt,
            lastError: lastError,
            interfaceLanguage: .chinese
        )
    }

    private static func topViewController(
        base: UIViewController? = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?
            .rootViewController
    ) -> UIViewController? {
        if let nav = base as? UINavigationController {
            return topViewController(base: nav.visibleViewController)
        }
        if let tab = base as? UITabBarController {
            return topViewController(base: tab.selectedViewController)
        }
        if let presented = base?.presentedViewController {
            return topViewController(base: presented)
        }
        return base
    }
}
