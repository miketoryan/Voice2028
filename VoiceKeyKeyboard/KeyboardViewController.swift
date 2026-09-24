import KeyboardKitHostPlugin
import SwiftUI
import UIKit

@MainActor
private final class KeyboardURLLauncher: ObservableObject {
    struct Request: Equatable {
        let id = UUID()
        let url: URL
    }

    @Published var request: Request?

    func open(_ url: URL) {
        request = Request(url: url)
    }
}

private struct KeyboardURLLauncherView: View {
    @ObservedObject var launcher: KeyboardURLLauncher
    @Environment(\.openURL) private var openURL

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onChange(of: launcher.request) { _, request in
                guard let request else { return }
                openURL(request.url)
                launcher.request = nil
            }
    }
}

final class KeyboardViewController: UIInputViewController {
    private let brandLabel = UILabel()
    private let statusLabel = UILabel()
    private let modeControl = UISegmentedControl(items: ["智能", "原文"])
    private let micButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)
    private let returnButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let bridge = LocalBridgeClient()
    private let urlLauncher = KeyboardURLLauncher()
    private var urlLauncherHost: UIHostingController<KeyboardURLLauncherView>?

    private var latestState = BridgeState.unavailable(
        interfaceLanguage: InterfaceLanguage(
            rawValue: UserDefaults.standard.string(forKey: "voice2028.interface-language") ?? ""
        ) ?? .chinese
    )
    private var currentRequestID: String?
    private var keyboardVisible = false
    private var mayAutoInsert = false
    private var insertionScheduledForRequestID: String?
    private var pendingAutoRecordingAfterLaunch = false
    private var pendingBackgroundStartRequestID: String?
    private var resolvedHostBundleIdentifier: String?
    private var heartbeatTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var hostResolutionTask: Task<Void, Never>?
    private var backgroundStartFallbackTask: Task<Void, Never>?

    private enum Defaults {
        static let transcriptionMode = "voice2028.transcription-mode"
        static let interfaceLanguage = "voice2028.interface-language"
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        refreshUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        keyboardVisible = true
        if currentRequestID != nil { mayAutoInsert = true }
        resolveHostApplicationInAdvance()
        startBridgeTasks()
    }

    override func viewWillDisappear(_ animated: Bool) {
        keyboardVisible = false
        mayAutoInsert = false
        insertionScheduledForRequestID = nil
        stopBridgeTasks()
        super.viewWillDisappear(animated)
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
    }

    deinit {
        heartbeatTask?.cancel()
        pollingTask?.cancel()
        commandTask?.cancel()
        hostResolutionTask?.cancel()
        backgroundStartFallbackTask?.cancel()
    }

    private func configureUI() {
        view.backgroundColor = .secondarySystemBackground

        brandLabel.text = "VK  Voice2028"
        brandLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        brandLabel.textColor = .label

        modeControl.selectedSegmentIndex = selectedMode == .smart ? 0 : 1
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        modeControl.setContentHuggingPriority(.required, for: .horizontal)

        statusLabel.font = .systemFont(ofSize: 13, weight: .regular)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.textColor = .secondaryLabel

        micButton.layer.cornerRadius = 27
        micButton.backgroundColor = .label
        micButton.tintColor = .white
        micButton.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)

        globeButton.setImage(UIImage(systemName: "globe"), for: .normal)
        globeButton.tintColor = .label
        globeButton.addTarget(self, action: #selector(nextKeyboard), for: .touchUpInside)

        returnButton.setTitle("换行", for: .normal)
        returnButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        returnButton.setTitleColor(.label, for: .normal)
        returnButton.backgroundColor = .tertiarySystemFill
        returnButton.layer.cornerRadius = 18
        returnButton.addTarget(self, action: #selector(insertNewline), for: .touchUpInside)

        deleteButton.setImage(UIImage(systemName: "delete.left"), for: .normal)
        deleteButton.tintColor = .label
        deleteButton.addTarget(self, action: #selector(deleteBackward), for: .touchUpInside)

        let topSpacer = UIView()
        topSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let topBar = UIStackView(arrangedSubviews: [brandLabel, topSpacer, modeControl])
        topBar.axis = .horizontal
        topBar.alignment = .center
        topBar.spacing = 8

        let micLeftSpacer = UIView()
        let micRightSpacer = UIView()
        let micRow = UIStackView(arrangedSubviews: [micLeftSpacer, micButton, micRightSpacer])
        micRow.axis = .horizontal
        micRow.alignment = .center
        micRow.distribution = .equalCentering

        let tools = UIStackView(arrangedSubviews: [globeButton, returnButton, deleteButton])
        tools.axis = .horizontal
        tools.alignment = .center
        tools.distribution = .equalCentering

        globeButton.widthAnchor.constraint(equalToConstant: 52).isActive = true
        returnButton.widthAnchor.constraint(equalToConstant: 86).isActive = true
        returnButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        deleteButton.widthAnchor.constraint(equalToConstant: 52).isActive = true
        modeControl.widthAnchor.constraint(equalToConstant: 148).isActive = true

        let stack = UIStackView(arrangedSubviews: [topBar, statusLabel, micRow, tools])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let launcherHost = UIHostingController(
            rootView: KeyboardURLLauncherView(launcher: urlLauncher)
        )
        addChild(launcherHost)
        launcherHost.view.backgroundColor = .clear
        launcherHost.view.isUserInteractionEnabled = false
        launcherHost.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(launcherHost.view)
        launcherHost.didMove(toParent: self)
        urlLauncherHost = launcherHost

        let height = view.heightAnchor.constraint(equalToConstant: 226)
        height.priority = .init(999)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            micButton.widthAnchor.constraint(equalToConstant: 92),
            micButton.heightAnchor.constraint(equalToConstant: 54),
            launcherHost.view.widthAnchor.constraint(equalToConstant: 1),
            launcherHost.view.heightAnchor.constraint(equalToConstant: 1),
            launcherHost.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            launcherHost.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height
        ])
    }

    @objc private func modeChanged() {
        let mode: TranscriptionMode = modeControl.selectedSegmentIndex == 1
            ? .verbatim
            : .smart
        UserDefaults.standard.set(mode.rawValue, forKey: Defaults.transcriptionMode)
    }

    @objc private func toggleRecording() {
        guard hasFullAccess else {
            statusLabel.text = localized(
                chinese: "请在系统设置中开启“允许完全访问”",
                english: "Enable Allow Full Access in Settings"
            )
            return
        }

        if latestState.status == .completed,
           let requestID = latestState.requestID,
           latestState.isFreshResponse(for: requestID) {
            insertLatestTranscription(automatically: false)
            return
        }

        guard latestState.serviceReady else {
            launchVoice2028AndResumeRecording()
            return
        }

        switch latestState.status {
        case .recording:
            mayAutoInsert = true
            sendCommand(.stopRecording, requestID: latestState.requestID ?? currentRequestID)
        case .starting, .transcribing:
            break
        default:
            // Silent standby keeps the app process ready without holding the
            // microphone open. Ask that live service to start capture first;
            // the existing timeout/error path wakes Voice2028 only when iOS
            // rejects the background audio transition.
            startRecordingRequest(allowForegroundFallback: true)
        }
    }

    @objc private func nextKeyboard() {
        keyboardVisible = false
        mayAutoInsert = false
        insertionScheduledForRequestID = nil
        stopBridgeTasks()
        advanceToNextInputMode()
    }

    @objc private func deleteBackward() {
        textDocumentProxy.deleteBackward()
    }

    @objc private func insertNewline() {
        textDocumentProxy.insertText("\n")
    }

    private func startBridgeTasks() {
        stopBridgeTasks()

        heartbeatTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sendHeartbeat()
            while !Task.isCancelled {
                do { try await Task.sleep(for: LocalBridge.keyboardHeartbeatInterval) }
                catch { return }
                await self.sendHeartbeat()
            }
        }

        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.fetchState()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(400)) }
                catch { return }
                await self.fetchState()
            }
        }
    }

    private func stopBridgeTasks() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func sendHeartbeat() async {
        guard keyboardVisible else { return }
        do { apply(try await bridge.send(.heartbeat)) }
        catch { applyConnectionFailure() }
    }

    private func fetchState() async {
        guard keyboardVisible else { return }
        do { apply(try await bridge.fetchState()) }
        catch { applyConnectionFailure() }
    }

    private func sendCommand(
        _ action: BridgeAction,
        requestID: String?,
        mode: TranscriptionMode? = nil
    ) {
        commandTask?.cancel()
        commandTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.apply(
                    try await self.bridge.send(
                        action,
                        requestID: requestID,
                        mode: mode
                    )
                )
            } catch {
                if action == .startRecording,
                   let requestID,
                   self.pendingBackgroundStartRequestID == requestID {
                    self.launchVoice2028AndResumeRecording(requestID: requestID)
                    return
                }
                self.latestState = .unavailable(
                    self.localized(
                        chinese: "Voice2028 未响应，点语音按钮可自动唤醒",
                        english: "Voice2028 did not respond. Tap the microphone to wake it."
                    ),
                    interfaceLanguage: self.latestState.interfaceLanguage
                )
                self.refreshUI()
            }
        }
    }

    private func startRecordingRequest(
        requestID suppliedRequestID: String? = nil,
        allowForegroundFallback: Bool = false
    ) {
        let requestID = suppliedRequestID ?? UUID().uuidString
        currentRequestID = requestID
        mayAutoInsert = true
        insertionScheduledForRequestID = nil
        pendingBackgroundStartRequestID = allowForegroundFallback ? requestID : nil
        latestState = BridgeState(
            serverID: latestState.serverID,
            revision: latestState.revision &+ 1,
            serviceReady: true,
            microphoneReady: latestState.microphoneReady,
            status: .starting,
            requestID: requestID,
            transcribedText: nil,
            resultCreatedAt: nil,
            lastError: nil,
            interfaceLanguage: latestState.interfaceLanguage
        )
        refreshUI()
        sendCommand(
            .startRecording,
            requestID: requestID,
            mode: selectedMode
        )

        guard allowForegroundFallback else { return }
        backgroundStartFallbackTask?.cancel()
        backgroundStartFallbackTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(2_500)) }
            catch { return }
            guard let self,
                  self.pendingBackgroundStartRequestID == requestID,
                  self.latestState.status != .recording else { return }
            self.launchVoice2028AndResumeRecording(requestID: requestID)
        }
    }

    private func apply(_ state: BridgeState) {
        if state.serverID == latestState.serverID,
           state.revision < latestState.revision { return }

        latestState = state
        UserDefaults.standard.set(
            state.interfaceLanguage.rawValue,
            forKey: Defaults.interfaceLanguage
        )

        // Cold-start handoff can cause the keyboard extension to disappear and
        // be recreated. Re-adopt the active request from the app's bridge so
        // the returned keyboard still owns the transcription and may insert it.
        if let requestID = state.requestID,
           state.status == .starting
            || state.status == .recording
            || state.status == .transcribing
            || state.status == .completed {
            if currentRequestID == nil {
                currentRequestID = requestID
            }
            mayAutoInsert = true
        }

        refreshUI()

        if let backgroundRequestID = pendingBackgroundStartRequestID,
           state.requestID == backgroundRequestID {
            if state.status == .recording {
                pendingBackgroundStartRequestID = nil
                backgroundStartFallbackTask?.cancel()
                backgroundStartFallbackTask = nil
                mayAutoInsert = true
            } else if state.status == .error {
                launchVoice2028AndResumeRecording(requestID: backgroundRequestID)
                return
            }
        }

        if pendingAutoRecordingAfterLaunch,
           state.serviceReady {
            if state.status == .recording,
               let requestID = state.requestID,
               requestID == currentRequestID {
                pendingAutoRecordingAfterLaunch = false
                pendingBackgroundStartRequestID = nil
                backgroundStartFallbackTask?.cancel()
                backgroundStartFallbackTask = nil
                mayAutoInsert = true
                return
            }

            if state.status == .idle, state.microphoneReady {
                pendingAutoRecordingAfterLaunch = false
                startRecordingRequest(requestID: currentRequestID)
                return
            }
        }

        if state.status == .completed,
           let requestID = state.requestID,
           insertionScheduledForRequestID != requestID {
            insertionScheduledForRequestID = requestID

            // Let the original host text field regain focus after the app
            // handoff before issuing the one physical insertText call.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self else { return }
                guard self.insertionScheduledForRequestID == requestID else { return }
                self.insertionScheduledForRequestID = nil
                self.insertLatestTranscription()
            }
        }
    }

    private func applyConnectionFailure() {
        guard latestState.status != .recording,
              latestState.status != .transcribing else { return }
        if let requestID = pendingBackgroundStartRequestID {
            launchVoice2028AndResumeRecording(requestID: requestID)
            return
        }
        latestState = .unavailable(
            localized(
                chinese: "服务休眠，点语音按钮可自动唤醒",
                english: "Service is sleeping. Tap the microphone to wake it."
            ),
            interfaceLanguage: latestState.interfaceLanguage
        )
        refreshUI()
    }

    private func refreshUI() {
        modeControl.setTitle(
            localized(chinese: "智能", english: "Smart"),
            forSegmentAt: 0
        )
        modeControl.setTitle(
            localized(chinese: "原文", english: "Verbatim"),
            forSegmentAt: 1
        )
        returnButton.setTitle(
            localized(chinese: "换行", english: "Return"),
            for: .normal
        )

        guard hasFullAccess else {
            statusLabel.text = localized(
                chinese: "需要允许完全访问",
                english: "Full Access is required"
            )
            applyMicStyle(
                title: localized(chinese: "开启完全访问", english: "Enable Full Access"),
                symbol: "mic.slash",
                color: .systemGray
            )
            return
        }

        if latestState.status == .completed,
           let requestID = latestState.requestID,
           latestState.isFreshResponse(for: requestID),
           latestState.transcribedText != nil {
            statusLabel.text = localized(
                chinese: "识别完成，正在自动插入…",
                english: "Transcription complete. Inserting…"
            )
            applyMicStyle(
                title: localized(chinese: "正在自动插入", english: "Inserting automatically"),
                symbol: "text.badge.checkmark",
                color: .systemGreen
            )
            return
        }

        guard latestState.serviceReady else {
            statusLabel.text = latestState.lastError ?? localized(
                chinese: "点击说话 · 自动唤醒 Voice2028",
                english: "Tap to speak · Voice2028 will wake automatically"
            )
            applyMicStyle(
                title: localized(chinese: "唤醒并开始说话", english: "Wake and start speaking"),
                symbol: "mic.fill",
                color: .label
            )
            return
        }

        switch latestState.status {
        case .idle:
            statusLabel.text = latestState.microphoneReady
                ? localized(chinese: "点击说话", english: "Tap to speak")
                : localized(chinese: "点击说话 · 后台直接启动", english: "Tap to speak · starts in background")
            applyMicStyle(
                title: localized(chinese: "开始说话", english: "Start speaking"),
                symbol: "mic.fill",
                color: .label
            )
        case .starting:
            statusLabel.text = localized(chinese: "正在打开麦克风…", english: "Starting microphone…")
            applyMicStyle(
                title: localized(chinese: "正在启动…", english: "Starting…"),
                symbol: "mic",
                color: .systemGray
            )
        case .recording:
            statusLabel.text = localized(
                chinese: "录音中 · 再点一次结束",
                english: "Recording · tap again to stop"
            )
            applyMicStyle(
                title: localized(chinese: "结束录音", english: "Stop recording"),
                symbol: "waveform",
                color: .label
            )
        case .transcribing:
            statusLabel.text = localized(
                chinese: "ChatGPT 正在自动识别语言…",
                english: "ChatGPT is detecting the language…"
            )
            applyMicStyle(
                title: localized(chinese: "正在处理…", english: "Processing…"),
                symbol: "waveform",
                color: .systemGray
            )
        case .completed:
            statusLabel.text = localized(chinese: "识别结果已过期", english: "Transcription expired")
            applyMicStyle(
                title: localized(chinese: "开始说话", english: "Start speaking"),
                symbol: "mic.fill",
                color: .label
            )
        case .error:
            statusLabel.text = latestState.lastError ?? localized(
                chinese: "识别失败",
                english: "Transcription failed"
            )
            applyMicStyle(
                title: localized(chinese: "重试", english: "Retry"),
                symbol: "mic",
                color: .systemOrange
            )
        }
    }

    private func localized(chinese: String, english: String) -> String {
        latestState.interfaceLanguage.text(chinese: chinese, english: english)
    }

    private func applyMicStyle(title: String, symbol: String, color: UIColor) {
        micButton.setTitle(nil, for: .normal)
        micButton.setImage(UIImage(systemName: symbol), for: .normal)
        micButton.backgroundColor = color
        micButton.tintColor = color == .label ? .systemBackground : .white
        micButton.accessibilityLabel = title
    }

    private func insertLatestTranscription(automatically: Bool = true) {
        guard viewIfLoaded?.window != nil else { return }

        guard let requestID = latestState.requestID,
              latestState.isFreshResponse(for: requestID) else {
            refreshUI()
            return
        }

        if automatically {
            guard keyboardVisible,
                  mayAutoInsert,
                  currentRequestID == requestID else {
                refreshUI()
                return
            }
        }

        guard let text = latestState.transcribedText,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            refreshUI()
            return
        }

        let beforeContextCount =
            textDocumentProxy.documentContextBeforeInput?.utf16.count
        let beforeHasText = textDocumentProxy.hasText

        // Exactly one physical insertion call for this completed request.
        textDocumentProxy.insertText(text)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let afterContextCount =
                self.textDocumentProxy.documentContextBeforeInput?.utf16.count
            let afterHasText = self.textDocumentProxy.hasText

            let changedCount: Bool
            if let beforeContextCount, let afterContextCount {
                changedCount = beforeContextCount != afterContextCount
            } else {
                changedCount = true
            }

            let likelySucceeded =
                (!beforeHasText && afterHasText)
                || changedCount
                || beforeContextCount == nil
                || afterContextCount == nil

            if likelySucceeded {
                self.currentRequestID = nil
                self.mayAutoInsert = false
                self.insertionScheduledForRequestID = nil

                self.latestState = BridgeState(
                    serverID: self.latestState.serverID,
                    revision: self.latestState.revision &+ 1,
                    serviceReady: self.latestState.serviceReady,
                    microphoneReady: self.latestState.microphoneReady,
                    status: .idle,
                    requestID: nil,
                    transcribedText: nil,
                    resultCreatedAt: nil,
                    lastError: nil,
                    interfaceLanguage: self.latestState.interfaceLanguage
                )

                self.statusLabel.text = self.localized(
                    chinese: "已自动插入",
                    english: "Inserted"
                )
                self.sendCommand(.acknowledgeResult, requestID: requestID)
            } else {
                // Keep the completed result in the bridge. The microphone
                // button can retry insertion manually instead of losing text.
                self.statusLabel.text = self.localized(
                    chinese: "自动插入失败 · 点麦克风可再试",
                    english: "Auto-insert failed · tap the microphone to retry"
                )
            }
        }
    }

    private var selectedMode: TranscriptionMode {
        guard let rawValue = UserDefaults.standard.string(forKey: Defaults.transcriptionMode),
              let mode = TranscriptionMode(rawValue: rawValue) else { return .smart }
        return mode
    }

    private func resolveHostApplicationInAdvance() {
        guard resolvedHostBundleIdentifier == nil else { return }
        hostResolutionTask?.cancel()
        hostResolutionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let bundleIdentifier = await self.resolveHostBundleIdentifier()
            guard !Task.isCancelled else { return }
            self.resolvedHostBundleIdentifier = bundleIdentifier
        }
    }

    private func launchVoice2028AndResumeRecording(requestID suppliedRequestID: String? = nil) {
        guard !pendingAutoRecordingAfterLaunch else { return }

        let requestID = suppliedRequestID ?? UUID().uuidString
        pendingBackgroundStartRequestID = nil
        backgroundStartFallbackTask?.cancel()
        backgroundStartFallbackTask = nil
        currentRequestID = requestID
        mayAutoInsert = true
        pendingAutoRecordingAfterLaunch = true
        statusLabel.text = localized(
            chinese: "后台启动失败，正在唤醒 Voice2028…",
            english: "Background start failed. Waking Voice2028…"
        )
        applyMicStyle(
            title: localized(chinese: "正在打开 App…", english: "Opening app…"),
            symbol: "mic",
            color: .systemGray
        )

        if let resolvedHostBundleIdentifier {
            openVoice2028(
                returningTo: resolvedHostBundleIdentifier,
                requestID: requestID
            )
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let hostBundleIdentifier = await self.resolveHostBundleIdentifier()
            self.resolvedHostBundleIdentifier = hostBundleIdentifier
            self.openVoice2028(
                returningTo: hostBundleIdentifier,
                requestID: requestID
            )
        }
    }

    private func openVoice2028(
        returningTo hostBundleIdentifier: String?,
        requestID: String
    ) {
        var components = URLComponents()
        components.scheme = "voice2028"
        components.host = "start-recording"
        components.queryItems = [
            URLQueryItem(name: "requestID", value: requestID),
            URLQueryItem(name: "mode", value: selectedMode.rawValue)
        ]
        if let hostBundleIdentifier {
            components.queryItems?.append(
                URLQueryItem(name: "returnBundleIdentifier", value: hostBundleIdentifier)
            )
        }

        guard let url = components.url else {
            pendingAutoRecordingAfterLaunch = false
            return
        }

        // SwiftUI's openURL environment is the supported URL handoff path from
        // a custom keyboard. UIKit's NSExtensionContext.open is not reliable
        // for UIInputViewController on recent iOS releases.
        urlLauncher.open(url)

        // Personal-sideload fallback. If SwiftUI has already opened Voice2028,
        // viewWillDisappear clears keyboardVisible and this path is skipped.
        Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) }
            catch { return }
            guard let self,
                  self.keyboardVisible,
                  self.pendingAutoRecordingAfterLaunch else { return }

            if !self.openURLViaResponderChain(url) {
                self.pendingAutoRecordingAfterLaunch = false
                self.statusLabel.text = self.localized(
                    chinese: "无法自动打开 Voice2028，请手动启动服务",
                    english: "Could not open Voice2028. Start the service manually."
                )
                self.refreshUI()
            }
        }
    }

    private func resolveHostBundleIdentifier() async -> String? {
        try? await pluginHostApplicationResolver(
            controller: self,
            pollingInterval: 0.08,
            timeout: 1.2
        )
    }

    @discardableResult
    private func openURLViaResponderChain(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self

        while let current = responder {
            if current.responds(to: selector) {
                current.perform(selector, with: url)
                return true
            }
            responder = current.next
        }
        return false
    }
}

