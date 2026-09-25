import Foundation
import UIKit
import ObjectiveC.runtime

@MainActor
@objc(OpenLessVoiceBootstrap)
final class OpenLessVoiceBootstrap: NSObject {
    @objc static let shared = OpenLessVoiceBootstrap()

    private let model = AppModel()
    private var loginButton: UIButton?
    private var hookInstalled = false
    private var originalOpenURLIMP: IMP?

    @objc func start() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.installURLHookIfPossible()
            self.ensureLoginButton()
            if self.model.signedIn {
                Task { @MainActor in
                    await self.model.startService()
                    self.refreshLoginButton()
                }
            }
        }
    }

    @objc private func applicationDidBecomeActive() {
        installURLHookIfPossible()
        ensureLoginButton()
        refreshLoginButton()
    }

    private func installURLHookIfPossible() {
        guard !hookInstalled,
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
            guard let self else { return false }
            let url = nsURL as URL
            let scheme = url.scheme?.lowercased() ?? ""

            if scheme == "voiceking" {
                Task { @MainActor in
                    await self.model.handleIncomingURL(url)
                    self.refreshLoginButton()
                }
                return true
            }

            if let original = self.originalOpenURLIMP {
                typealias Original = @convention(c) (
                    AnyObject,
                    Selector,
                    UIApplication,
                    NSURL,
                    NSDictionary
                ) -> Bool
                let fn = unsafeBitCast(original, to: Original.self)
                return fn(object, selector, application, nsURL, options)
            }
            return false
        }

        let imp = imp_implementationWithBlock(block)
        if let method = class_getInstanceMethod(cls, selector) {
            method_setImplementation(method, imp)
        } else {
            class_addMethod(cls, selector, imp, "B@:@@@")
        }
        hookInstalled = true
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
        button.addTarget(self, action: #selector(loginTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false

        window.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: window.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            button.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 8),
            button.heightAnchor.constraint(equalToConstant: 30),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 72)
        ])

        loginButton = button
        refreshLoginButton()
    }

    private func refreshLoginButton() {
        if model.signedIn {
            loginButton?.setTitle("GPT 已登录", for: .normal)
            loginButton?.accessibilityLabel = "ChatGPT 已登录"
        } else {
            loginButton?.setTitle("登录 GPT", for: .normal)
            loginButton?.accessibilityLabel = "登录 ChatGPT"
        }
    }

    @objc private func loginTapped() {
        if model.signedIn {
            Task { @MainActor in
                await model.startService()
                refreshLoginButton()
            }
            return
        }

        Task { @MainActor in
            await model.signIn()
            refreshLoginButton()
        }
    }

    private func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: { $0.isKeyWindow })
            ?? scenes.flatMap(\.windows).first
    }
}
