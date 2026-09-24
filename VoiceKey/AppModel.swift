import Combine
import Foundation
import UIKit

enum RecognitionLanguage: String, CaseIterable, Identifiable {
    case chinese = "zh"
    case automatic = "auto"
    case english = "en"

    var id: String { rawValue }

    var apiValue: String? {
        self == .automatic ? nil : rawValue
    }

    func displayName(interfaceLanguage: InterfaceLanguage) -> String {
        switch self {
        case .chinese:
            interfaceLanguage.text(chinese: "中文", english: "Chinese")
        case .automatic:
            interfaceLanguage.text(chinese: "自动", english: "Auto")
        case .english:
            "English"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var signedIn: Bool
    @Published private(set) var accountEmail: String?
    @Published private(set) var serviceReady = false
    @Published private(set) var statusText = "Idle"
    @Published private(set) var handoffActive = false
    @Published var lastError: String?
    @Published var interfaceLanguage: InterfaceLanguage {
        didSet {
            UserDefaults.standard.set(
                interfaceLanguage.rawValue,
                forKey: Defaults.interfaceLanguage
            )
            refreshStatusText()
            markStateChanged()
        }
    }

    @Published var recognitionLanguage: RecognitionLanguage {
        didSet {
            UserDefaults.standard.set(
                recognitionLanguage.rawValue,
                forKey: Defaults.recognitionLanguage
            )
        }
    }

    private let auth: ChatGPTAuthManager
    private let audio = AudioService()
    private let transcriber = ChatGPTTranscriptionService()
    private let cleanupService = ChatGPTCleanupService()
    private let localBridge = LocalBridgeServer()
    private var serverID = UUID().uuidString

    private var stateRevision: UInt64 = 0
    private var activeRecordingURL: URL?
    private var activeRequestID: String?
    private var activeTranscriptionMode: TranscriptionMode = .smart
    private var bridgeStatus: BridgeStatus = .idle
    private var responseText: String?
    private var resultCreatedAt: Date?
    private var bridgeError: String?
    private var lastKeyboardHeartbeat: Date?
    private var keyboardHasConnected = false
    private var keyboardMonitorTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var audioActivationTask: Task<Bool, Never>?

    private enum Defaults {
        static let interfaceLanguage = "voice2028.interface-language"
        static let recognitionLanguage = "voice2028.recognition-language"
    }

    init() {
        interfaceLanguage = InterfaceLanguage(
            rawValue: UserDefaults.standard.string(forKey: Defaults.interfaceLanguage) ?? ""
        ) ?? .chinese

        recognitionLanguage = RecognitionLanguage(
            rawValue: UserDefaults.standard.string(forKey: Defaults.recognitionLanguage) ?? ""
        ) ?? .chinese

        let auth = ChatGPTAuthManager()
        self.auth = auth
        self.signedIn = auth.isSignedIn
        self.accountEmail = auth.credential?.email
        self.statusText = interfaceLanguage.text(chinese: "空闲", english: "Idle")


        do {
            try localBridge.start { [weak self] request in
                guard let self else {
                    return BridgeState.unavailable("Voice2028 is not running.")
                }
                return await self.handleBridgeRequest(request)
            }
        } catch {
            lastError = error.localizedDescription
            statusText = ui("键盘本地连接失败", "Local keyboard connection failed")
        }
    }

    deinit {
        keyboardMonitorTask?.cancel()
        transcriptionTask?.cancel()
        audioActivationTask?.cancel()
        localBridge.stop()
    }

    func signIn() async {
        lastError = nil
        do {
            try await auth.signIn()
            signedIn = true
            accountEmail = auth.credential?.email
            await startService()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut() {
        stopService()
        auth.signOut()
        signedIn = false
        accountEmail = nil
    }

    func startService() async {
        // Keep the local bridge available with the microphone off. When the
        // keyboard needs audio, Voice2028 briefly wakes in the foreground,
        // starts capture, and immediately returns to the previous app.
        await startService(armingMicrophoneBeforeReturn: false)
    }


    private func startService(armingMicrophoneBeforeReturn: Bool) async {
        lastError = nil
        guard signedIn else {
            lastError = "Sign in with ChatGPT first."
            return
        }

        let granted = await AudioService.requestPermission()
        guard granted else {
            lastError = "Microphone permission is required."
            return
        }

        do {
            transcriptionTask?.cancel()
            transcriptionTask = nil
            keyboardMonitorTask?.cancel()
            keyboardMonitorTask = nil
            audioActivationTask?.cancel()
            audioActivationTask = nil

            // A previous request can be abandoned if the keyboard extension is
            // killed during an app handoff. Always clear that capture before a
            // foreground recovery so the new request starts from a clean file.
            if let staleURL = audio.endCapture() ?? activeRecordingURL {
                try? FileManager.default.removeItem(at: staleURL)
            }
            audio.disarm()

            try await performAudioOperationWithRetry {
                if armingMicrophoneBeforeReturn {
                    try audio.arm()
                } else {
                    try prepareStandbyAudio()
                }
            }
            serviceReady = true
            statusText = armingMicrophoneBeforeReturn
                ? ui("已准备好语音输入", "Ready for keyboard dictation")
                : ui("等待 Voice2028 键盘", "Waiting for Voice2028 keyboard")
            activeRecordingURL = nil
            activeRequestID = nil
            bridgeStatus = .idle
            bridgeError = nil
            clearResult()
            lastKeyboardHeartbeat = nil
            keyboardHasConnected = false
            markStateChanged()
        } catch {
            publishError(error.localizedDescription)
        }
    }

    func handleIncomingURL(_ url: URL) async {
        guard url.scheme?.lowercased() == "voice2028",
              url.host?.lowercased() == "start-recording" else {
            return
        }
        handoffActive = true

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let returnBundleIdentifier = queryItems.first(where: {
            $0.name == "returnBundleIdentifier"
        })?.value
        let requestID = queryItems.first(where: {
            $0.name == "requestID"
        })?.value
        let mode = queryItems.first(where: {
            $0.name == "mode"
        })?.value.flatMap(TranscriptionMode.init(rawValue:)) ?? .smart

        // A long-lived background instance can keep its audio process alive
        // while the localhost listener has become unreachable to the keyboard.
        // Rebuild the listener during the foreground handoff and publish a new
        // server ID so the returned keyboard adopts the fresh bridge exactly
        // as it would after a clean app launch.
        guard await restartLocalBridgeForForegroundHandoff() else {
            handoffActive = false
            return
        }

        // Fallback path: start the *actual recording file* while Voice2028 is
        // in the foreground, then return to the host app. This avoids the real-
        // device failure where AVAudioEngine reported "recording" after the
        // app switch but delivered only silence, followed by CoreAudio
        // 2003329396 on retry.
        await startService(armingMicrophoneBeforeReturn: true)
        guard serviceReady else {
            handoffActive = false
            return
        }

        guard let requestID, !requestID.isEmpty,
              startRecordingFromKeyboard(
                  requestID: requestID,
                  mode: mode
              ),
              bridgeStatus == .recording else {
            // Never jump back with a half-activated microphone. If capture did
            // not really start, the failure path has already returned audio to
            // safe standby and the user remains in Voice2028 instead.
            handoffActive = false
            return
        }

        // Return as soon as capture is confirmed. A long artificial delay makes
        // the app flash much more visibly than Typeless.
        try? await Task.sleep(for: .milliseconds(120))
        if let returnBundleIdentifier,
           openHostApplication(bundleIdentifier: returnBundleIdentifier) {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.handoffActive = false
            }
            return
        }

        handoffActive = false
        statusText = returnBundleIdentifier == nil
            ? ui("未识别原输入 App，请手动返回", "Could not identify the previous app. Return manually.")
            : ui("系统未允许自动返回，请手动返回", "iOS blocked automatic return. Return manually.")
        markStateChanged()
    }

    func stopService() {
        keyboardMonitorTask?.cancel()
        keyboardMonitorTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        audioActivationTask?.cancel()
        audioActivationTask = nil

        if let url = audio.endCapture() ?? activeRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        activeRecordingURL = nil
        activeRequestID = nil
        audio.disarm()
        handoffActive = false
        serviceReady = false
        statusText = ui("空闲", "Idle")
        bridgeStatus = .idle
        clearResult()
        lastKeyboardHeartbeat = nil
        keyboardHasConnected = false
        markStateChanged()
    }

    private func handleBridgeRequest(_ request: BridgeRequest) async -> BridgeState {
        switch request.action {
        case .state:
            break

        case .heartbeat:
            noteKeyboardHeartbeat()

        case .startRecording:
            noteKeyboardHeartbeat()
            if await activateMicrophoneForRecording() {
                startRecordingFromKeyboard(
                    requestID: request.requestID,
                    mode: request.mode ?? .smart
                )
            }

        case .stopRecording:
            noteKeyboardHeartbeat()
            beginFinishingRecording(
                expectedRequestID: request.requestID,
                deactivateMicrophoneAfterCapture: false
            )

        case .acknowledgeResult:
            acknowledgeResult(requestID: request.requestID)

        }

        return currentBridgeState()
    }

    private func noteKeyboardHeartbeat() {
        guard serviceReady else { return }
        lastKeyboardHeartbeat = Date()
        keyboardHasConnected = true
    }

    private func activateMicrophoneForRecording() async -> Bool {
        guard serviceReady else { return false }

        if audio.isRunning {
            startKeyboardMonitor()
            return true
        }

        if let audioActivationTask {
            return await audioActivationTask.value
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            do {
                try await self.performAudioOperationWithRetry {
                    try self.audio.arm()
                }
                guard self.serviceReady else {
                    self.audio.disarm()
                    return false
                }
                self.statusText = self.ui("已准备好语音输入", "Ready for keyboard dictation")
                self.lastError = nil
                self.bridgeError = nil
                self.markStateChanged()
                self.startKeyboardMonitor()
                return true
            } catch {
                guard !Task.isCancelled else { return false }
                self.publishError(error.localizedDescription)
                return false
            }
        }
        audioActivationTask = task
        let activated = await task.value
        audioActivationTask = nil
        return activated
    }

    private func restartLocalBridgeForForegroundHandoff() async -> Bool {
        localBridge.stop()
        try? await Task.sleep(for: .milliseconds(80))

        serverID = UUID().uuidString
        do {
            try localBridge.start { [weak self] request in
                guard let self else {
                    return BridgeState.unavailable("Voice2028 is not running.")
                }
                return await self.handleBridgeRequest(request)
            }
            markStateChanged()
            return true
        } catch {
            serviceReady = false
            lastError = error.localizedDescription
            bridgeError = error.localizedDescription
            statusText = ui("键盘本地连接重启失败", "Local keyboard connection restart failed")
            markStateChanged()
            return false
        }
    }

    private func recoverAudioAfterFailedRecordingStart() {
        if let url = audio.endCapture() ?? activeRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        activeRecordingURL = nil
        keyboardMonitorTask?.cancel()
        keyboardMonitorTask = nil
        lastKeyboardHeartbeat = nil
        keyboardHasConnected = false

        do {
            try prepareStandbyAudio()
            serviceReady = true
        } catch {
            audio.disarm()
            serviceReady = false
        }
        markStateChanged()
    }

    private func abortOrphanedRecordingToStandby() {
        if let url = audio.endCapture() ?? activeRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        activeRecordingURL = nil
        activeRequestID = nil
        responseText = nil
        resultCreatedAt = nil
        bridgeStatus = .error
        bridgeError = ui(
            "键盘未重新连接，已自动关闭麦克风",
            "Keyboard did not reconnect. Microphone was closed automatically."
        )
        lastError = bridgeError
        lastKeyboardHeartbeat = nil
        keyboardHasConnected = false

        do {
            try prepareStandbyAudio()
            serviceReady = true
        } catch {
            audio.disarm()
            serviceReady = false
        }
        markStateChanged()
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
                guard Self.isTransientAudioSessionError(error), retry < 4 else {
                    throw error
                }
                retry += 1
                statusText = ui("正在等待麦克风…", "Waiting for the microphone…")
                try await Task.sleep(for: .milliseconds(150 * retry))
            }
        }
    }

    private static func isTransientAudioSessionError(_ error: Error) -> Bool {
        // iOS can briefly reject an audio transition while moving between the
        // host app and keyboard extension. Retry the known transient
        // "cannot interrupt others" error and CoreAudio's unspecified 'what'
        // error seen on real-device background microphone startup.
        let code = (error as NSError).code
        return code == 560_557_684 || code == 2_003_329_396
    }

    @discardableResult
    private func startRecordingFromKeyboard(
        requestID: String?,
        mode: TranscriptionMode
    ) -> Bool {
        guard serviceReady, audio.isRunning else {
            publishError(
                "Open Voice2028 and start Keyboard Service first.",
                requestID: requestID
            )
            recoverAudioAfterFailedRecordingStart()
            return false
        }
        guard let requestID, !requestID.isEmpty else {
            publishError("Voice2028 received an invalid recording request.")
            recoverAudioAfterFailedRecordingStart()
            return false
        }
        guard bridgeStatus != .recording,
              bridgeStatus != .starting,
              bridgeStatus != .transcribing else {
            return bridgeStatus == .recording
        }

        bridgeStatus = .starting
        activeRequestID = requestID
        activeTranscriptionMode = mode
        clearResult(keepingRequest: true)
        markStateChanged()

        do {
            activeRecordingURL = try audio.beginCapture()
            bridgeStatus = .recording
            statusText = ui("录音中…", "Recording…")
            startKeyboardMonitor()
            markStateChanged()
            return true
        } catch {
            publishError(error.localizedDescription, requestID: requestID)
            recoverAudioAfterFailedRecordingStart()
            return false
        }
    }

    private func finishRecordingFromKeyboard(
        expectedRequestID: String?,
        deactivateMicrophoneAfterCapture: Bool
    ) async {
        guard bridgeStatus == .recording else { return }
        guard let requestID = activeRequestID,
              expectedRequestID == nil || expectedRequestID == requestID else { return }

        let capturedURL = audio.endCapture() ?? activeRecordingURL
        activeRecordingURL = nil

        guard let url = capturedURL else {
            publishError("No recording was captured.", requestID: requestID)
            return
        }

        bridgeStatus = .transcribing
        statusText = activeTranscriptionMode == .smart
            ? ui("正在识别并智能整理…", "Transcribing and organizing…")
            : ui("正在识别…", "Transcribing…")
        markStateChanged()

        if deactivateMicrophoneAfterCapture {
            do {
                try prepareStandbyAudio()
            } catch {
                publishError(error.localizedDescription, requestID: requestID)
                try? FileManager.default.removeItem(at: url)
                return
            }
        }

        defer {
            try? FileManager.default.removeItem(at: url)
        }

        do {
            let credential = try await auth.validCredential()
            let rawText = try await transcriber.transcribe(
                audioURL: url,
                credential: credential,
                language: recognitionLanguage.apiValue
            )
            let text: String
            if activeTranscriptionMode == .smart {
                do {
                    text = try await cleanupService.clean(
                        transcript: rawText,
                        credential: credential
                    )
                } catch {
                    // Never lose a valid transcription because the optional
                    // cleanup pass is temporarily unavailable.
                    text = rawText
                }
            } else {
                text = rawText
            }
            responseText = text
            resultCreatedAt = Date()
            bridgeError = nil
            bridgeStatus = .completed
            statusText = audio.isRunning
                ? ui("已准备好语音输入", "Ready for keyboard dictation")
                : ui("键盘已关闭，识别结果已就绪", "Keyboard closed. Transcription is ready.")
            signedIn = true
            accountEmail = credential.email
            markStateChanged()
        } catch {
            guard !Task.isCancelled else { return }
            publishError(error.localizedDescription, requestID: requestID)
            statusText = ui("识别失败", "Transcription failed")
        }
    }

    private func beginFinishingRecording(
        expectedRequestID: String?,
        deactivateMicrophoneAfterCapture: Bool
    ) {
        guard bridgeStatus == .recording else { return }
        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in
            await self?.finishRecordingFromKeyboard(
                expectedRequestID: expectedRequestID,
                deactivateMicrophoneAfterCapture: deactivateMicrophoneAfterCapture
            )
        }
    }

    private func startKeyboardMonitor() {
        keyboardMonitorTask?.cancel()
        let monitorStartedAt = Date()
        keyboardMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }

                guard let self, self.serviceReady else { return }
                guard self.audio.isRunning else { return }

                // Foreground handoff temporarily destroys/recreates the keyboard
                // extension. A healthy return reconnects quickly. If it never
                // reconnects, do not leave AVAudioEngine holding the microphone
                // forever: abandon the orphaned capture and return to standby.
                if !self.keyboardHasConnected {
                    if Date().timeIntervalSince(monitorStartedAt) >= 5 {
                        self.abortOrphanedRecordingToStandby()
                        return
                    }
                    continue
                }

                guard let heartbeat = self.lastKeyboardHeartbeat,
                      Date().timeIntervalSince(heartbeat) >= LocalBridge.keyboardExitGracePeriod else {
                    continue
                }

                if self.bridgeStatus == .recording {
                    self.beginFinishingRecording(
                        expectedRequestID: self.activeRequestID,
                        deactivateMicrophoneAfterCapture: true
                    )
                } else {
                    self.deactivateMicrophonePreservingResponse()
                }
                return
            }
        }
    }

    private func deactivateMicrophonePreservingResponse() {
        keyboardMonitorTask?.cancel()
        keyboardMonitorTask = nil
        do {
            try prepareStandbyAudio()
        } catch {
            publishError(error.localizedDescription)
            stopService()
            return
        }
        lastKeyboardHeartbeat = nil
        keyboardHasConnected = false
        markStateChanged()

        switch bridgeStatus {
        case .starting, .idle:
            activeRequestID = nil
            bridgeStatus = .idle
            statusText = ui("等待 Voice2028 键盘", "Waiting for Voice2028 keyboard")
        case .recording:
            break
        case .transcribing:
            statusText = ui("键盘已关闭，正在完成识别…", "Keyboard closed. Finishing transcription…")
        case .completed:
            statusText = ui("键盘已关闭，识别结果已就绪", "Keyboard closed. Transcription is ready.")
        case .error:
            statusText = ui("等待 Voice2028 键盘", "Waiting for Voice2028 keyboard")
        }
    }

    private func acknowledgeResult(requestID: String?) {
        guard requestID == nil || requestID == activeRequestID else { return }
        activeRequestID = nil
        clearResult()
        if bridgeStatus == .completed || bridgeStatus == .error {
            bridgeStatus = .idle
        }
        if serviceReady {
            statusText = audio.isRunning
                ? ui("已准备好语音输入", "Ready for keyboard dictation")
                : ui("等待 Voice2028 键盘", "Waiting for Voice2028 keyboard")
        }
        markStateChanged()
    }

    private func clearResult(keepingRequest: Bool = false) {
        responseText = nil
        resultCreatedAt = nil
        bridgeError = nil
        if !keepingRequest {
            activeRequestID = nil
        }
    }

    private func publishError(_ message: String, requestID: String? = nil) {
        if let requestID {
            activeRequestID = requestID
        }
        responseText = nil
        resultCreatedAt = Date()
        bridgeError = message
        bridgeStatus = .error
        lastError = message
        markStateChanged()
    }

    private func currentBridgeState() -> BridgeState {
        BridgeState(
            serverID: serverID,
            revision: stateRevision,
            serviceReady: serviceReady,
            microphoneReady: audio.isRunning,
            status: bridgeStatus,
            requestID: activeRequestID,
            transcribedText: responseText,
            resultCreatedAt: resultCreatedAt,
            lastError: bridgeError,
            interfaceLanguage: interfaceLanguage
        )
    }

    private func prepareStandbyAudio() throws {
        try audio.enterStandby()
    }

    private func ui(_ chinese: String, _ english: String) -> String {
        interfaceLanguage.text(chinese: chinese, english: english)
    }

    private func refreshStatusText() {
        guard serviceReady else {
            statusText = ui("空闲", "Idle")
            return
        }

        switch bridgeStatus {
        case .idle:
            statusText = audio.isRunning
                ? ui("已准备好语音输入", "Ready for keyboard dictation")
                : ui("等待 Voice2028 键盘", "Waiting for Voice2028 keyboard")
        case .starting:
            statusText = ui("正在打开麦克风…", "Starting microphone…")
        case .recording:
            statusText = ui("录音中…", "Recording…")
        case .transcribing:
            statusText = activeTranscriptionMode == .smart
                ? ui("正在识别并智能整理…", "Transcribing and organizing…")
                : ui("正在识别…", "Transcribing…")
        case .completed:
            statusText = ui("识别结果已就绪", "Transcription is ready")
        case .error:
            statusText = bridgeError ?? ui("识别失败", "Transcription failed")
        }
    }

    private func markStateChanged() {
        stateRevision &+= 1
    }

    private func openHostApplication(bundleIdentifier: String) -> Bool {
        guard !bundleIdentifier.isEmpty,
              bundleIdentifier != Bundle.main.bundleIdentifier,
              let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else {
            return false
        }

        let defaultWorkspaceSelector = NSSelectorFromString("defaultWorkspace")
        guard workspaceClass.responds(to: defaultWorkspaceSelector),
              let workspaceValue = workspaceClass.perform(defaultWorkspaceSelector),
              let workspace = workspaceValue.takeUnretainedValue() as? NSObject else {
            return false
        }

        let legacySelector = NSSelectorFromString("openApplicationWithBundleID:")
        if workspace.responds(to: legacySelector) {
            typealias LegacyOpenApplication = @convention(c) (
                AnyObject,
                Selector,
                NSString
            ) -> Bool
            let implementation = workspace.method(for: legacySelector)
            let openApplication = unsafeBitCast(
                implementation,
                to: LegacyOpenApplication.self
            )
            if openApplication(workspace, legacySelector, bundleIdentifier as NSString) {
                return true
            }
        }

        // iOS 26 also exposes a newer LaunchServices selector. It is used as a
        // personal-sideload fallback when the legacy call refuses the launch.
        let modernSelector = NSSelectorFromString(
            "openApplicationWithBundleIdentifier:configuration:completionHandler:"
        )
        guard workspace.responds(to: modernSelector) else { return false }

        typealias Completion = @convention(block) (Bool, NSError?) -> Void
        typealias ModernOpenApplication = @convention(c) (
            AnyObject,
            Selector,
            NSString,
            AnyObject?,
            Completion
        ) -> Void

        let completion: Completion = { [weak self] success, error in
            guard !success else { return }
            Task { @MainActor in
                self?.handoffActive = false
                self?.statusText = self?.ui(
                    "系统未允许自动返回，请手动返回",
                    "iOS blocked automatic return. Return manually."
                ) ?? "iOS blocked automatic return. Return manually."
                self?.lastError = error?.localizedDescription
                self?.markStateChanged()
            }
        }

        let implementation = workspace.method(for: modernSelector)
        let openApplication = unsafeBitCast(
            implementation,
            to: ModernOpenApplication.self
        )
        openApplication(
            workspace,
            modernSelector,
            bundleIdentifier as NSString,
            nil,
            completion
        )
        return true
    }
}
