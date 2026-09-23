#!/usr/bin/env python3
from pathlib import Path
import re
import shutil
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: patch_open_voice_typer_gpt.py <builder-root> <source-root>")

builder = Path(sys.argv[1]).resolve()
root = Path(sys.argv[2]).resolve()

def replace_once(path, old, new):
    p = root / path
    text = p.read_text()
    if old not in text:
        raise RuntimeError(f"expected text not found in {path}: {old[:120]!r}")
    p.write_text(text.replace(old, new, 1))

# Inject ChatGPT account services into the main app target.
chatgpt_dir = root / "App" / "ChatGPT"
chatgpt_dir.mkdir(parents=True, exist_ok=True)
for src in (builder / "open-voice-typer-gpt" / "injected").glob("*.swift"):
    shutil.copy2(src, chatgpt_dir / src.name)

# Localhost bridge is shared by app + keyboard; the server is app-only.
for src in (builder / "open-voice-typer-gpt" / "shared").glob("*.swift"):
    shutil.copy2(src, root / "Shared" / src.name)
for src in (builder / "open-voice-typer-gpt" / "app").glob("*.swift"):
    shutil.copy2(src, root / "App" / "Session" / src.name)

# AltServer-friendly build: no App Group entitlements. Keyboard/app communication
# is localhost, and each process keeps only its own harmless UI preferences.
project = root / "project.yml"
text = project.read_text()
text = text.replace("bundleIdPrefix: com.shuaiwang", "bundleIdPrefix: com.miketoryan.openvoicetypergpt")
text = text.replace("PRODUCT_BUNDLE_IDENTIFIER: com.shuaiwang.openvoicetyper.keyboard",
                    "PRODUCT_BUNDLE_IDENTIFIER: com.miketoryan.openvoicetypergpt.keyboard")
text = text.replace("PRODUCT_BUNDLE_IDENTIFIER: com.shuaiwang.openvoicetyper",
                    "PRODUCT_BUNDLE_IDENTIFIER: com.miketoryan.openvoicetypergpt")
text = text.replace("CFBundleDisplayName: Open Voice Typer", "CFBundleDisplayName: Open Voice Typer GPT")
text = text.replace("CFBundleDisplayName: Voice Typer", "CFBundleDisplayName: Voice Typer GPT")
text = text.replace(
'''    entitlements:
      path: App/OpenVoiceTyper.entitlements
      properties:
        com.apple.security.application-groups:
          - group.com.shuaiwang.openvoicetyper
''', '')
text = text.replace(
'''    entitlements:
      path: Keyboard/VoiceKeyboard.entitlements
      properties:
        com.apple.security.application-groups:
          - group.com.shuaiwang.openvoicetyper
''', '')
keyboard_marker = '''        CFBundleDisplayName: Voice Typer GPT
'''
if keyboard_marker not in text:
    raise RuntimeError("keyboard display-name marker not found")
text = text.replace(
    keyboard_marker,
    keyboard_marker + '''        NSAppTransportSecurity:
          NSAllowsLocalNetworking: true
''',
    1
)
project.write_text(text)

# Settings no longer need cross-process App Group storage. Keyboard style is sent
# with each localhost request, so app and keyboard need not share defaults.
replace_once(
    "Shared/ProviderSettings.swift",
'''enum SettingsStore {
    private static let key = "settings.providers"

    static func load() -> ProviderSettings {
        guard let data = AppGroup.defaults?.data(forKey: key),
              let settings = try? JSONDecoder().decode(ProviderSettings.self, from: data)
        else { return ProviderSettings() }
        return settings
    }

    static func save(_ settings: ProviderSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        AppGroup.defaults?.set(data, forKey: key)
    }
}
''',
'''enum SettingsStore {
    private static let key = "settings.providers.gpt"

    static func load() -> ProviderSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(ProviderSettings.self, from: data)
        else { return ProviderSettings() }
        return settings
    }

    static func save(_ settings: ProviderSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
'''
)

# ChatGPT is now the only transcription/polish backend.
(root / "App" / "Session" / "DictationPipeline.swift").write_text(r'''import Foundation

struct DictationPipeline: Sendable {
    struct Outcome: Sendable {
        var rawText: String
        var polishedText: String
        var engineName: String
        var audioSeconds: Double
        var totalMilliseconds: Int = 0
        var asrMilliseconds: Int = 0
        var polishMilliseconds: Int = 0
    }

    var settings: ProviderSettings

    static func audioSeconds(ofWAV wavData: Data) -> Double {
        Double(max(0, wavData.count - 44)) / 32_000
    }

    var asrEngineName: String { "ChatGPT transcription" }
    var polishEngineName: String { "gpt-5.6-luna" }

    func prewarm(style: Style) async {
        // OAuth credential refresh is intentionally left to the real request.
        // Keeping prewarm side-effect-free avoids a login refresh racing the
        // background audio handoff.
    }

    func run(wavData: Data, style: Style) async throws -> Outcome {
        let totalStart = Date()
        let seconds = Self.audioSeconds(ofWAV: wavData)
        let credential = try await ChatGPTAuthManager.shared.validCredential()

        let asrStart = Date()
        let raw = try await ChatGPTTranscriptionService().transcribe(
            wavData: wavData,
            credential: credential
        )
        let asrMS = Int(Date().timeIntervalSince(asrStart) * 1000)

        let polished: String
        var polishMS = 0
        if style.id == Style.raw.id {
            polished = raw
        } else {
            let polishStart = Date()
            polished = try await ChatGPTPolishService().polish(
                transcript: raw,
                style: style,
                targetLanguage: settings.targetLanguage,
                dictionary: SharedCatalog.loadDictionary().map(\.term),
                credential: credential
            )
            polishMS = Int(Date().timeIntervalSince(polishStart) * 1000)
        }

        return Outcome(
            rawText: raw,
            polishedText: polished,
            engineName: style.id == Style.raw.id ? "ChatGPT transcription" : "gpt-5.6-luna",
            audioSeconds: seconds,
            totalMilliseconds: Int(Date().timeIntervalSince(totalStart) * 1000),
            asrMilliseconds: asrMS,
            polishMilliseconds: polishMS
        )
    }

    func polishOnly(rawText: String, style: Style) async throws -> String {
        guard style.id != Style.raw.id else { return rawText }
        let credential = try await ChatGPTAuthManager.shared.validCredential()
        return try await ChatGPTPolishService().polish(
            transcript: rawText,
            style: style,
            targetLanguage: settings.targetLanguage,
            dictionary: SharedCatalog.loadDictionary().map(\.term),
            credential: credential
        )
    }
}

extension Duration {
    var milliseconds: Int {
        Int(components.seconds) * 1_000
            + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}
''')

# Keyboard state machine: no App Group or Darwin notifications. It talks directly
# to the live main app over 127.0.0.1 and inserts only the result for its own UUID.
(root / "Shared" / "VoicePanelModel.swift").write_text(r'''import Foundation
import SwiftUI

@MainActor
@Observable
final class VoicePanelModel {
    enum Phase: Equatable {
        case noFullAccess
        case noSession
        case idle
        case recording
        case processing
        case error(String)

        var isError: Bool {
            if case .error = self { return true }
            return false
        }
    }

    static let startAckTimeout: TimeInterval = 4
    static let resultTimeout: TimeInterval = 130
    static let minRecordingSeconds: TimeInterval = 0.6
    static let insertionStepMS = 6
    static let maxInsertionSteps = 66

    enum Mode: Equatable {
        case dictate
        case translate
    }

    var phase: Phase = .idle
    var audioLevel: Float = 0
    var styles: [Style] = Style.builtIns
    var selectedStyleID: String = Style.light.id {
        didSet {
            UserDefaults.standard.set(selectedStyleID, forKey: "ovt.gpt.keyboardStyle")
        }
    }
    private(set) var targetLanguage = "English"

    let needsInputModeSwitchKey: Bool
    var onGlobe: () -> Void = {}
    var insertTextHandler: (String) -> Void = { _ in }
    var deleteBackwardHandler: () -> Void = {}
    var dismissKeyboardHandler: () -> Void = {}
    var hasFullAccessProvider: () -> Bool = { true }

    static let openAppURL = URL(string: "openvoicetyper://open")!

    private let bridge = OVTLocalBridgeClient()
    private var awaitingCommandID: UUID?
    private var startAcknowledged = false
    private var recordingStartedAt: Date?
    private var timeoutTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var insertionTask: Task<Void, Never>?
    private var lastInsertedText = ""

    init(needsInputModeSwitchKey: Bool) {
        self.needsInputModeSwitchKey = needsInputModeSwitchKey
    }

    var canDictate: Bool {
        switch phase {
        case .idle, .error: true
        default: false
        }
    }

    var canUndo: Bool {
        !lastInsertedText.isEmpty && phase != .recording && phase != .processing
    }

    var selectedStyleName: String {
        styles.first { $0.id == selectedStyleID }?.name ?? "Style"
    }

    var mode: Mode {
        selectedStyleID == Style.translate.id ? .translate : .dictate
    }

    var dictateStyles: [Style] {
        styles.filter { $0.id != Style.translate.id }
    }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        switch newMode {
        case .translate:
            UserDefaults.standard.set(selectedStyleID, forKey: "ovt.gpt.lastDictateStyle")
            selectedStyleID = Style.translate.id
        case .dictate:
            selectedStyleID = UserDefaults.standard.string(forKey: "ovt.gpt.lastDictateStyle")
                ?? Style.light.id
        }
    }

    var statusText: String {
        switch phase {
        case .recording: "Listening… tap to finish"
        case .processing: "ChatGPT is working…"
        case .error(let message): message
        default: "Tap to speak"
        }
    }

    func activate() {
        guard hasFullAccessProvider() else {
            phase = .noFullAccess
            return
        }
        styles = Style.builtIns
        selectedStyleID = UserDefaults.standard.string(forKey: "ovt.gpt.keyboardStyle")
            ?? Style.light.id
        pollingTask?.cancel()
        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshFromBridge()
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    func deactivate() {
        if phase == .recording, let id = awaitingCommandID {
            Task { [bridge] in
                _ = try? await bridge.send(.cancel, requestID: id, styleID: nil)
            }
        }
        pollingTask?.cancel()
        pollingTask = nil
        commandTask?.cancel()
        commandTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        insertionTask?.cancel()
        insertionTask = nil
        awaitingCommandID = nil
        recordingStartedAt = nil
        if phase == .recording || phase == .processing {
            phase = .idle
        }
    }

    func toggleDictation() {
        switch phase {
        case .idle, .error:
            startDictation()
        case .recording:
            finishDictation()
        default:
            break
        }
    }

    private func startDictation() {
        guard hasFullAccessProvider() else {
            phase = .noFullAccess
            return
        }
        let id = UUID()
        awaitingCommandID = id
        startAcknowledged = false
        recordingStartedAt = Date()
        audioLevel = 0
        phase = .recording

        commandTask?.cancel()
        commandTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let state = try await bridge.send(.start, requestID: id, styleID: selectedStyleID)
                self.apply(state)
            } catch {
                self.awaitingCommandID = nil
                self.phase = .noSession
            }
        }

        scheduleTimeout(after: Self.startAckTimeout, ifStillAwaiting: id) { [weak self] in
            guard let self, !self.startAcknowledged, self.phase == .recording else { return }
            Task { [bridge] in _ = try? await bridge.send(.cancel, requestID: id, styleID: nil) }
            self.fail("Open Open Voice Typer GPT once, then return and try again.")
        }
    }

    private func finishDictation() {
        guard let id = awaitingCommandID else {
            phase = .idle
            return
        }
        if let started = recordingStartedAt,
           Date().timeIntervalSince(started) < Self.minRecordingSeconds {
            Task { [bridge] in _ = try? await bridge.send(.cancel, requestID: id, styleID: nil) }
            awaitingCommandID = nil
            recordingStartedAt = nil
            phase = .error("Hold the button while you speak.")
            return
        }

        recordingStartedAt = nil
        phase = .processing
        commandTask?.cancel()
        commandTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let state = try await bridge.send(.stop, requestID: id, styleID: selectedStyleID)
                self.apply(state)
            } catch {
                self.fail("Lost connection to Open Voice Typer GPT.")
            }
        }
        scheduleTimeout(after: Self.resultTimeout, ifStillAwaiting: id) { [weak self] in
            self?.fail("Timed out waiting for ChatGPT. Try again.")
        }
    }

    private func refreshFromBridge() async {
        guard hasFullAccessProvider() else {
            phase = .noFullAccess
            return
        }
        do {
            apply(try await bridge.fetchState())
        } catch {
            switch phase {
            case .recording, .processing:
                break
            default:
                phase = .noSession
            }
        }
    }

    private func apply(_ state: OVTLocalState) {
        if !state.serviceReady {
            if let message = state.error, !message.isEmpty {
                phase = .error(message)
            } else if awaitingCommandID == nil {
                phase = .noSession
            }
        }

        guard let awaited = awaitingCommandID else {
            if state.serviceReady, phase == .noSession {
                phase = .idle
            }
            return
        }
        guard state.requestID == awaited else { return }

        switch state.phase {
        case .idle:
            break
        case .recording:
            startAcknowledged = true
            timeoutTask?.cancel()
            timeoutTask = nil
            phase = .recording
            audioLevel = state.audioLevel
        case .transcribing, .polishing:
            phase = .processing
        case .completed:
            guard let text = state.text, !text.isEmpty else {
                fail("ChatGPT returned no text.")
                return
            }
            awaitingCommandID = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            Task { [bridge] in _ = try? await bridge.send(.acknowledge, requestID: awaited, styleID: nil) }
            insert(text)
        case .error:
            fail(state.error ?? "Voice input failed.")
        }
    }

    private func scheduleTimeout(
        after seconds: TimeInterval,
        ifStillAwaiting id: UUID?,
        onTimeout: @escaping @MainActor () -> Void
    ) {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, self.awaitingCommandID == id, id != nil else { return }
            onTimeout()
        }
    }

    private func fail(_ message: String) {
        awaitingCommandID = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        phase = .error(message)
    }

    func insertText(_ text: String) { insertTextHandler(text) }
    func deleteBackward() { deleteBackwardHandler() }
    func switchToNextKeyboard() { onGlobe() }
    func dismissKeyboard() { dismissKeyboardHandler() }

    private func insert(_ text: String) {
        guard !text.isEmpty else {
            phase = .idle
            return
        }
        let chunkSize = max(1, Int((Double(text.count) / Double(Self.maxInsertionSteps)).rounded(.up)))
        phase = .processing
        lastInsertedText = ""
        insertionTask?.cancel()
        insertionTask = Task { @MainActor in
            var index = text.startIndex
            while index < text.endIndex {
                guard !Task.isCancelled else { break }
                let end = text.index(index, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
                let chunk = String(text[index..<end])
                insertTextHandler(chunk)
                lastInsertedText.append(chunk)
                index = end
                try? await Task.sleep(for: .milliseconds(Self.insertionStepMS))
            }
            insertionTask = nil
            if phase == .processing { phase = .idle }
        }
    }

    func undoLastInsert() {
        guard !lastInsertedText.isEmpty else { return }
        for _ in 0..<lastInsertedText.count { deleteBackwardHandler() }
        lastInsertedText = ""
    }
}
''')

replace_once(
    "Keyboard/KeyboardViewController.swift",
'''        let model = VoicePanelModel(needsInputModeSwitchKey: needsInputModeSwitchKey)
        model.onGlobe = { [weak self] in self?.advanceToNextInputMode() }
''',
'''        let model = VoicePanelModel(needsInputModeSwitchKey: needsInputModeSwitchKey)
        model.hasFullAccessProvider = { [weak self] in self?.hasFullAccess ?? false }
        model.onGlobe = { [weak self] in self?.advanceToNextInputMode() }
'''
)

# Main session gains a localhost server and mirrors its existing pipeline status
# into the local bridge. App Group publishing is retained as a harmless no-op
# fallback for upstream code paths but is no longer required by the keyboard.
sc_path = root / "App" / "Session" / "SessionController.swift"
sc = sc_path.read_text()
prop_marker = '''    private var unhealthySince: Date?
'''
if prop_marker not in sc:
    raise RuntimeError("SessionController property marker not found")
sc = sc.replace(prop_marker, prop_marker + '''
    private let localBridgeServer = OVTLocalBridgeServer()
    private var localRevision: UInt64 = 0
    private var localPhase: OVTLocalPhase = .idle
    private var localRequestID: UUID?
    private var localAudioLevel: Float = 0
    private var localText: String?
    private var localBridgeError: String?
''', 1)

init_marker = '''        recorder.onLevel = { [weak self] level in
            MainActor.assumeIsolated {
                self?.publishLevel(level)
                self?.onUILevel?(level)
            }
        }
'''
if init_marker not in sc:
    raise RuntimeError("SessionController init marker not found")
sc = sc.replace(init_marker, init_marker + '''
        try? localBridgeServer.start { request in
            await MainActor.run {
                SessionController.shared.handleLocalBridge(request)
            }
        }
''', 1)

# Mirror state/result writes into localhost-visible state.
sc = sc.replace("DictationBridge.publish(PipelineState(", "publishPipelineState(PipelineState(")
sc = sc.replace("DictationBridge.publish(DictationResult(", "publishDictationResult(DictationResult(")

insert_marker = '''    // MARK: Level metering
'''
if insert_marker not in sc:
    raise RuntimeError("SessionController level marker not found")
local_methods = r'''    // MARK: AltServer localhost bridge

    private func currentLocalBridgeState() -> OVTLocalState {
        OVTLocalState(
            revision: localRevision,
            serviceReady: isActive && recorder.isEngineHealthy && ChatGPTAuthManager.shared.isSignedIn,
            phase: localPhase,
            requestID: localRequestID,
            audioLevel: localAudioLevel,
            text: localText,
            error: localBridgeError
        )
    }

    private func markLocalChanged() {
        localRevision &+= 1
    }

    private func publishPipelineState(_ state: PipelineState) {
        DictationBridge.publish(state)

        // The original bridge had separate state and result slots. Preserve
        // that behaviour here: the pipeline's final .idle must not erase a
        // completed result before the keyboard polls it.
        if state.phase == .idle, localText != nil || localBridgeError != nil {
            return
        }

        localRequestID = state.commandID ?? localRequestID
        localAudioLevel = state.audioLevel
        switch state.phase {
        case .idle:
            localPhase = .idle
            if state.commandID == nil { localRequestID = nil }
        case .recording:
            localPhase = .recording
            localText = nil
            localBridgeError = nil
        case .transcribing:
            localPhase = .transcribing
        case .polishing:
            localPhase = .polishing
        }
        markLocalChanged()
    }

    private func publishDictationResult(_ result: DictationResult) {
        DictationBridge.publish(result)
        localRequestID = result.commandID
        localAudioLevel = 0
        if let error = result.errorMessage {
            localPhase = .error
            localText = nil
            localBridgeError = error
        } else {
            localPhase = .completed
            localText = result.polishedText
            localBridgeError = nil
        }
        markLocalChanged()
    }

    private func handleLocalBridge(_ request: OVTLocalRequest) -> OVTLocalState {
        switch request.action {
        case .state:
            break

        case .start:
            guard ChatGPTAuthManager.shared.isSignedIn else {
                localRequestID = request.requestID
                localPhase = .error
                localBridgeError = "请先打开 Open Voice Typer GPT，在 Settings 登录 ChatGPT。"
                localText = nil
                markLocalChanged()
                return currentLocalBridgeState()
            }
            guard isActive, recorder.isEngineHealthy else {
                localRequestID = request.requestID
                localPhase = .error
                localBridgeError = "主程序没有在后台待命。请先打开 Open Voice Typer GPT。"
                localText = nil
                markLocalChanged()
                return currentLocalBridgeState()
            }
            guard let id = request.requestID else { return currentLocalBridgeState() }
            guard activeCommand == nil else {
                localRequestID = id
                localPhase = .error
                localBridgeError = "已有录音正在进行。"
                markLocalChanged()
                return currentLocalBridgeState()
            }
            localRequestID = id
            localText = nil
            localBridgeError = nil
            localAudioLevel = 0
            markLocalChanged()
            execute(KeyboardCommand(
                id: id,
                kind: .startDictation,
                styleID: request.styleID ?? Style.light.id
            ))

        case .stop:
            guard let id = request.requestID,
                  activeCommand?.id == id
            else { return currentLocalBridgeState() }
            execute(KeyboardCommand(
                kind: .stopDictation,
                styleID: request.styleID ?? activeCommand?.styleID ?? Style.light.id
            ))

        case .cancel:
            if let id = request.requestID,
               activeCommand?.id == id {
                execute(KeyboardCommand(
                    kind: .cancelDictation,
                    styleID: activeCommand?.styleID ?? Style.light.id
                ))
            }
            localRequestID = nil
            localText = nil
            localBridgeError = nil
            localAudioLevel = 0
            localPhase = .idle
            markLocalChanged()

        case .acknowledge:
            if request.requestID == nil || request.requestID == localRequestID {
                localRequestID = nil
                localText = nil
                localBridgeError = nil
                localAudioLevel = 0
                localPhase = .idle
                markLocalChanged()
            }
        }
        return currentLocalBridgeState()
    }

'''
sc = sc.replace(insert_marker, local_methods + insert_marker, 1)
sc_path.write_text(sc)

# Settings page is account-based only — no API keys or provider URLs.
(root / "App" / "Views" / "ConfigurationView.swift").write_text(r'''import SwiftUI

struct ConfigurationView: View {
    @StateObject private var auth = ChatGPTAuthManager.shared
    @State private var settings = SettingsStore.load()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Label("ChatGPT", systemImage: "person.crop.circle")
                        Spacer()
                        Text(auth.isSignedIn ? "已登录" : "未登录")
                            .foregroundStyle(auth.isSignedIn ? Color.secondary : Color.orange)
                    }

                    if let email = auth.accountEmail, auth.isSignedIn {
                        LabeledContent("账号") { Text(email) }
                    }

                    if let error = auth.lastError, !error.isEmpty {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    if auth.isSignedIn {
                        Button("退出 ChatGPT", role: .destructive) {
                            auth.signOut()
                        }
                    } else {
                        Button("登录 ChatGPT") {
                            Task { await auth.signIn() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } header: {
                    Text("ChatGPT account")
                } footer: {
                    Text("直接登录你的 ChatGPT 账号进行语音识别和文本整理，不需要 API Key。")
                }

                Section {
                    Picker("Turn off after", selection: $settings.sessionAutoEndMinutes) {
                        ForEach(ProviderSettings.autoEndChoices, id: \.minutes) { choice in
                            Text(choice.label).tag(choice.minutes)
                        }
                    }
                } header: {
                    Text("Microphone")
                } footer: {
                    Text("主程序保持后台音频会话，键盘通过本机 localhost 发送录音命令。")
                }

                Section("Translate template") {
                    Picker("Target language", selection: $settings.targetLanguage) {
                        ForEach(ProviderSettings.targetLanguages, id: \.self) { language in
                            Text(language).tag(language)
                        }
                    }
                }

                Section("Diagnostics") {
                    Toggle("Show timings in History", isOn: $settings.showsTimings)
                }

                Section("About") {
                    LabeledContent("识别") { Text("ChatGPT account") }
                    LabeledContent("API Key") { Text("不需要") }
                    LabeledContent("Keyboard bridge") { Text("localhost") }
                    LabeledContent("Version") {
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                    }
                }
            }
            .navigationTitle("Settings")
            .onChange(of: settings) { SettingsStore.save(settings) }
        }
    }
}

#Preview {
    ConfigurationView()
}
''')

# This personal test build skips the upstream API/provider onboarding. The
# Settings tab is the single setup surface: ChatGPT login + mic/session options.
replace_once(
    "App/Views/RootView.swift",
'''                showOnboarding = !hasCompletedOnboarding
''',
'''                hasCompletedOnboarding = true
                showOnboarding = false
'''
)

print("Open Voice Typer GPT patch applied")
