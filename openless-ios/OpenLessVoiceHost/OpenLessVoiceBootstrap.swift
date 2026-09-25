import Foundation
import UIKit

@MainActor
@objc(OpenLessVoiceBootstrap)
final class OpenLessVoiceBootstrap: NSObject {
    @objc static let shared = OpenLessVoiceBootstrap()

    private let auth = ChatGPTAuthManager()
    private var loginButton: UIButton?
    private var syncing = false

    @objc func start() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.ensureLoginButton()
            Task { @MainActor in
                await self.syncCredentialIfPossible()
            }
        }
    }

    @objc private func applicationDidBecomeActive() {
        ensureLoginButton()
        Task { @MainActor in
            await syncCredentialIfPossible()
        }
    }

    private func ensureLoginButton() {
        guard loginButton == nil,
              let window = keyWindow() else { return }

        let button = UIButton(type: .system)
        button.tag = 0x4F4C4750
        button.layer.cornerRadius = 14
        button.layer.masksToBounds = true
        button.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.94)
        button.setTitleColor(.label, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        button.layer.borderWidth = 0.5
        button.layer.borderColor = UIColor.separator.cgColor
        button.addAction(
            UIAction { [weak self] _ in
                self?.beginLogin()
            },
            for: .touchUpInside
        )
        button.translatesAutoresizingMaskIntoConstraints = false

        window.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: window.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            button.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 8),
            button.heightAnchor.constraint(equalToConstant: 30),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 72)
        ])

        loginButton = button
        auth.presentationWindow = window
        refreshLoginButton(ready: auth.isSignedIn)
    }

    private func beginLogin() {
        guard !syncing else { return }

        // Change the title synchronously before starting any async work.
        // If this text does not appear, the control event itself did not fire.
        loginButton?.setTitle("正在打开 GPT…", for: .normal)
        loginButton?.isEnabled = false

        Task { @MainActor in
            defer {
                self.loginButton?.isEnabled = true
            }

            do {
                auth.presentationWindow = loginButton?.window ?? keyWindow()
                if !auth.isSignedIn {
                    try await auth.signIn()
                }
                await syncCredentialIfPossible()
            } catch {
                loginButton?.setTitle("登录 GPT", for: .normal)
                presentLoginError(error)
            }
        }
    }

    private func syncCredentialIfPossible() async {
        guard auth.isSignedIn, !syncing else {
            refreshLoginButton(ready: false)
            return
        }

        syncing = true
        defer { syncing = false }

        do {
            let credential = try await auth.validCredential()
            guard let accountId = credential.accountId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !accountId.isEmpty else {
                refreshLoginButton(ready: false)
                return
            }

            try writeCodexAuth(
                accessToken: credential.accessToken,
                accountId: accountId
            )
            refreshLoginButton(ready: true)
        } catch {
            refreshLoginButton(ready: false)
        }
    }

    private func writeCodexAuth(accessToken: String, accountId: String) throws {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let directory = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

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
            to: directory.appendingPathComponent("auth.json"),
            options: .atomic
        )
    }

    private func presentLoginError(_ error: Error) {
        guard let window = keyWindow(),
              let root = window.rootViewController else { return }

        var presenter = root
        while let presented = presenter.presentedViewController {
            presenter = presented
        }

        let message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        let alert = UIAlertController(
            title: "GPT 登录失败",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "好", style: .default))
        presenter.present(alert, animated: true)
    }

    private func refreshLoginButton(ready: Bool) {
        if ready {
            loginButton?.setTitle("GPT 已登录", for: .normal)
            loginButton?.accessibilityLabel = "ChatGPT 已登录"
        } else {
            loginButton?.setTitle("登录 GPT", for: .normal)
            loginButton?.accessibilityLabel = "登录 ChatGPT"
        }
    }

    private func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: { $0.isKeyWindow })
            ?? scenes.flatMap(\.windows).first
    }
}
