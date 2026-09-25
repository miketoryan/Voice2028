import AVFoundation
import Foundation
import UIKit

@MainActor
@objc(OpenLessVoiceBootstrap)
final class OpenLessVoiceBootstrap: NSObject {
    @objc static let shared = OpenLessVoiceBootstrap()

    private let auth = ChatGPTAuthManager()
    private var loginRunning = false
    private var bridgeTimer: Timer?

    // No-jump design:
    // keep the main process alive in the background so the keyboard can talk
    // directly to the localhost OpenLess Core bridge without opening the app.
    private let keepAliveEngine = AVAudioEngine()
    private let keepAlivePlayer = AVAudioPlayerNode()
    private var keepAliveConfigured = false

    @objc func start() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioSessionInterrupted(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )

        startBridgePolling()
        startBackgroundKeepAliveIfNeeded()

        Task { @MainActor in
            await self.syncCredentialIfPossible()
        }
    }

    @objc private func applicationDidBecomeActive() {
        startBackgroundKeepAliveIfNeeded()
        Task { @MainActor in
            await syncCredentialIfPossible()
        }
    }

    @objc private func audioSessionInterrupted(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        if type == .ended {
            startBackgroundKeepAliveIfNeeded(forceRestart: true)
        }
    }

    private func startBackgroundKeepAliveIfNeeded(forceRestart: Bool = false) {
        do {
            let session = AVAudioSession.sharedInstance()

            // Silent playback keeps the host process eligible for the existing
            // "audio" background mode while mixing with any user audio.
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers]
            )
            try session.setActive(true)

            if !keepAliveConfigured {
                let format = AVAudioFormat(
                    standardFormatWithSampleRate: 44_100,
                    channels: 1
                )!

                let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: 4_410
                )!
                buffer.frameLength = 4_410
                // AVAudioPCMBuffer is zero-initialized, so this is 100 ms silence.

                keepAliveEngine.attach(keepAlivePlayer)
                keepAliveEngine.connect(
                    keepAlivePlayer,
                    to: keepAliveEngine.mainMixerNode,
                    format: format
                )
                keepAlivePlayer.scheduleBuffer(
                    buffer,
                    at: nil,
                    options: [.loops],
                    completionHandler: nil
                )
                keepAliveConfigured = true
            }

            if forceRestart, keepAliveEngine.isRunning {
                keepAliveEngine.stop()
            }
            if !keepAliveEngine.isRunning {
                try keepAliveEngine.start()
            }
            if !keepAlivePlayer.isPlaying {
                keepAlivePlayer.play()
            }
        } catch {
            NSLog(
                "[OpenLess Background] keep-alive start failed: %@",
                error.localizedDescription
            )
        }
    }

    private func startBridgePolling() {
        bridgeTimer?.invalidate()

        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.consumeLoginRequestIfPresent()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        bridgeTimer = timer

        consumeLoginRequestIfPresent()
    }

    private func consumeLoginRequestIfPresent() {
        guard !loginRunning else { return }

        do {
            let requestURL = try codexDirectory()
                .appendingPathComponent("openless-login-request.json")
            guard FileManager.default.fileExists(atPath: requestURL.path) else { return }

            try? FileManager.default.removeItem(at: requestURL)
            beginLoginFromBridge()
        } catch {
            writeLoginState(
                state: "error",
                message: "无法读取 GPT 登录请求：\(error.localizedDescription)"
            )
        }
    }

    func beginLoginFromBridge() {
        guard !loginRunning else { return }
        loginRunning = true
        writeLoginState(state: "opening", message: nil)

        Task { @MainActor in
            defer { self.loginRunning = false }

            do {
                self.auth.presentationWindow = self.keyWindow()
                if !self.auth.isSignedIn {
                    try await self.auth.signIn()
                }
                try await self.syncCredential()
                self.writeLoginState(state: "signed_in", message: nil)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                self.writeLoginState(state: "error", message: message)
            }
        }
    }

    private func syncCredentialIfPossible() async {
        guard auth.isSignedIn else { return }
        do {
            try await syncCredential()
            writeLoginState(state: "signed_in", message: nil)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            writeLoginState(state: "error", message: message)
        }
    }

    private func syncCredential() async throws {
        let credential = try await auth.validCredential()
        guard let accountId = credential.accountId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accountId.isEmpty else {
            throw NSError(
                domain: "OpenLessGPT",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "ChatGPT 登录成功，但未返回账号 ID。"]
            )
        }

        try writeCodexAuth(
            accessToken: credential.accessToken,
            accountId: accountId
        )
    }

    private func codexDirectory() throws -> URL {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw NSError(
                domain: "OpenLessGPT",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "无法定位 OpenLess 文档目录。"]
            )
        }

        let directory = documents.appendingPathComponent(
            "OpenLessGPT",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func writeCodexAuth(accessToken: String, accountId: String) throws {
        let payload: [String: Any] = [
            "tokens": [
                "access_token": accessToken,
                "account_id": accountId
            ]
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(
            to: try codexDirectory().appendingPathComponent("auth.json"),
            options: .atomic
        )
    }

    private func writeLoginState(state: String, message: String?) {
        do {
            var payload: [String: Any] = [
                "state": state,
                "updatedAt": Date().timeIntervalSince1970
            ]
            if let message, !message.isEmpty {
                payload["message"] = message
            }
            let data = try JSONSerialization.data(withJSONObject: payload)
            try data.write(
                to: try codexDirectory().appendingPathComponent("openless-login-state.json"),
                options: .atomic
            )
        } catch {
            NSLog("[OpenLess GPT] failed to persist login state: %@", error.localizedDescription)
        }
    }

    private func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: { $0.isKeyWindow })
            ?? scenes.flatMap(\.windows).first
    }
}
