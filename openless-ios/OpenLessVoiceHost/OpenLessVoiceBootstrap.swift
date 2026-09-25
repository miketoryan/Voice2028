import Foundation
import ObjectiveC.runtime
import UIKit

@MainActor
@objc(OpenLessVoiceBootstrap)
final class OpenLessVoiceBootstrap: NSObject {
    @objc static let shared = OpenLessVoiceBootstrap()

    private let auth = ChatGPTAuthManager()
    private var loginRunning = false
    private var bridgeTimer: Timer?
    private var urlHookInstalled = false
    private var originalOpenURLIMP: IMP?

    @objc func start() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        startBridgePolling()
        installURLHookIfPossible()

        Task { @MainActor in
            await self.syncCredentialIfPossible()
        }
    }

    @objc private func applicationDidBecomeActive() {
        installURLHookIfPossible()
        Task { @MainActor in
            await syncCredentialIfPossible()
        }
    }

    private func installURLHookIfPossible() {
        guard !urlHookInstalled,
              let delegate = UIApplication.shared.delegate else { return }

        let cls: AnyClass = type(of: delegate)
        let selector = NSSelectorFromString("application:openURL:options:")
        originalOpenURLIMP = class_getMethodImplementation(cls, selector)

        typealias OpenBlock = @convention(block) (
            AnyObject,
            UIApplication,
            NSURL,
            NSDictionary
        ) -> Bool

        let block: OpenBlock = { [weak self] object, application, nsURL, options in
            let url = nsURL as URL
            if url.scheme?.lowercased() == "openless",
               url.host?.lowercased() == "keyboard" {
                Task { @MainActor [weak self] in
                    self?.handleKeyboardURL(url)
                }
                return true
            }

            if let original = self?.originalOpenURLIMP {
                typealias Original = @convention(c) (
                    AnyObject,
                    Selector,
                    UIApplication,
                    NSURL,
                    NSDictionary
                ) -> Bool
                let function = unsafeBitCast(original, to: Original.self)
                return function(object, selector, application, nsURL, options)
            }
            return false
        }

        let implementation = imp_implementationWithBlock(block)
        if let method = class_getInstanceMethod(cls, selector) {
            method_setImplementation(method, implementation)
        } else {
            class_addMethod(cls, selector, implementation, "B@:@@@")
        }
        urlHookInstalled = true
    }

    private func handleKeyboardURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.first(where: { $0.name == "action" })?.value == "start",
              let requestID = components.queryItems?.first(where: { $0.name == "requestID" })?.value,
              !requestID.isEmpty else {
            return
        }

        let mode = components.queryItems?
            .first(where: { $0.name == "mode" })?
            .value ?? "smart"

        Task {
            await sendKeyboardStartCommand(
                requestID: requestID,
                mode: mode
            )
        }
    }

    private func sendKeyboardStartCommand(
        requestID: String,
        mode: String
    ) async {
        guard let url = URL(string: "http://127.0.0.1:14557/command") else { return }

        let payload: [String: Any] = [
            "action": "startRecording",
            "requestID": requestID,
            "mode": mode
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        for _ in 0..<24 {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.timeoutInterval = 1
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("7", forHTTPHeaderField: "X-VoiceKing-Protocol")

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    return
                }
            } catch {
                // The Rust listener may still be resuming after app wake.
            }

            try? await Task.sleep(for: .milliseconds(120))
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

