#!/usr/bin/env python3
from pathlib import Path
import shutil
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: patch_vocaphone_gpt.py <builder-root> <vocaphone-root>")

builder = Path(sys.argv[1]).resolve()
root = Path(sys.argv[2]).resolve()
ios = root / "ios"

def replace_once(path, old, new):
    p = ios / path
    text = p.read_text()
    if old not in text:
        raise RuntimeError(f"expected text not found in {path}: {old[:120]!r}")
    p.write_text(text.replace(old, new, 1))

# Inject the ChatGPT account, transcription and cleanup implementation.
dst = ios / "VocaPhoneApp" / "ChatGPT"
dst.mkdir(parents=True, exist_ok=True)
for src in (builder / "vocaphone-gpt" / "injected").glob("*.swift"):
    shutil.copy2(src, dst / src.name)

for src in (builder / "vocaphone-gpt" / "app").glob("*.swift"):
    shutil.copy2(src, dst / src.name)

shared_dst = ios / "VocaPhoneShared"
for src in (builder / "vocaphone-gpt" / "shared").glob("*.swift"):
    shutil.copy2(src, shared_dst / src.name)

# Reuse VocaPhone's existing writing-style session field as a two-mode GPT
# selector. This means the keyboard and containing app already share/persist the
# choice through the App Group without introducing a second state mechanism.
kp = "VocaPhoneShared/KeyboardPreferences.swift"
replace_once(kp, 'case .raw: "Raw"', 'case .raw: "原文识别"')
replace_once(kp, 'case .clean: "Clean"', 'case .clean: "智能整理"')
replace_once(
    kp,
    'case .raw:\n            "Exactly what the model returned, with nothing changed."',
    'case .raw:\n            "ChatGPT 只做语音转文字，不再改写内容。"'
)
replace_once(
    kp,
    'case .clean:\n            "Spacing tidied and a closing full stop. Random capitals from the model are flattened; names like VocaPhone stay."',
    'case .clean:\n            "ChatGPT 在识别后去掉口头禅和重复内容，修正明显口误并自动断句。"'
)
replace_once(kp, 'case .clean: "eraser"', 'case .clean: "sparkles"')
replace_once(kp, 'else { return .casual }', 'else { return .clean }')
replace_once(kp, '''    static var writingStyle: WritingStyle {
        get {
            guard let rawValue = defaults?.string(forKey: writingStyleKey),
                  let style = WritingStyle(rawValue: rawValue)
            else { return .clean }
            return style
        }
        set {
            defaults?.set(newValue.rawValue, forKey: writingStyleKey)
        }
    }
''', '''    static var writingStyle: WritingStyle {
        get {
            if let rawValue = UserDefaults.standard.string(forKey: "vocaphoneGPTWritingStyle"),
               let style = WritingStyle(rawValue: rawValue) {
                return style
            }
            guard let rawValue = defaults?.string(forKey: writingStyleKey),
                  let style = WritingStyle(rawValue: rawValue)
            else { return .clean }
            return style
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "vocaphoneGPTWritingStyle")
            defaults?.set(newValue.rawValue, forKey: writingStyleKey)
        }
    }
''')

# New sessions should also default to Smart Cleanup even before a preference has
# ever been written.
replace_once(
    "VocaPhoneShared/SessionRecord.swift",
    'style: String = WritingStyle.casual.rawValue,',
    'style: String = WritingStyle.clean.rawValue,'
)

# UIKit fallback bar: show only the two requested modes.
replace_once(
    "VocaPhoneKeyboard/DictationBarView.swift",
    'children: WritingStyle.allCases.map { option in',
    'children: [WritingStyle.clean, WritingStyle.raw].map { option in'
)

# SwiftUI keyboard surface: the style page becomes a two-tile GPT mode page.
replace_once(
    "VocaPhoneKeyboard/DictationSurfaceView.swift",
    '''    private var stylePicker: some View {
        let rows = stride(from: 0, to: WritingStyle.allCases.count, by: 3).map {
            Array(WritingStyle.allCases[$0..<min($0 + 3, WritingStyle.allCases.count)])
        }
''',
    '''    private var stylePicker: some View {
        let modes: [WritingStyle] = [.clean, .raw]
        let rows = stride(from: 0, to: modes.count, by: 2).map {
            Array(modes[$0..<min($0 + 2, modes.count)])
        }
'''
)
replace_once(
    "VocaPhoneKeyboard/DictationSurfaceView.swift",
    'case .style: pickerControlsRow(title: "Writing style")',
    'case .style: pickerControlsRow(title: "ChatGPT 模式")'
)
replace_once(
    "VocaPhoneKeyboard/DictationSurfaceView.swift",
    '.accessibilityLabel("Writing style")',
    '.accessibilityLabel("ChatGPT mode")'
)

# Main app: go straight to the dashboard for this test build and put ChatGPT
# sign-in at the top. The original model/gateway attention cards are hidden;
# Quick Dictation, session state and transcript history remain intact.
cv = "VocaPhoneApp/App/ContentView.swift"
replace_once(
    cv,
    '@Environment(RecordingCoordinator.self) private var coordinator\n',
    '@Environment(RecordingCoordinator.self) private var coordinator\n    @StateObject private var chatGPTAuth = ChatGPTAuthManager.shared\n'
)
replace_once(
    cv,
    '''    private var needsFirstRunOnboarding: Bool {
        OnboardingPresentation.requiresFirstRunCover(setupCompleted: setupCompleted)
    }
''',
    '''    private var needsFirstRunOnboarding: Bool {
        false
    }
'''
)
replace_once(
    cv,
    '''                VStack(alignment: .leading, spacing: VocaMetrics.grouping) {
                    attentionCard
                    modelDownloadCard
                    quickDictationOfferCard
                    sessionCard
                    sourceRow
                    transcriptCard
                }
''',
    '''                VStack(alignment: .leading, spacing: VocaMetrics.grouping) {
                    chatGPTCard
                    quickDictationOfferCard
                    sessionCard
                    transcriptCard
                }
'''
)
marker = '    private var home: some View {\n'
card = '''    private var chatGPTCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("ChatGPT", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.headline)
                Spacer()
                Text(chatGPTAuth.isSignedIn ? "已登录" : "未登录")
                    .font(.subheadline)
                    .foregroundStyle(chatGPTAuth.isSignedIn ? Color.secondary : Color.orange)
            }

            if let email = chatGPTAuth.accountEmail, chatGPTAuth.isSignedIn {
                Text(email)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("登录 ChatGPT 后，VocaPhone 使用你的 ChatGPT 账号进行语音识别；键盘可切换“智能整理”和“原文识别”。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let error = chatGPTAuth.lastError, !error.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if chatGPTAuth.isSignedIn {
                Button("退出 ChatGPT", role: .destructive) {
                    chatGPTAuth.signOut()
                }
            } else {
                Button("登录 ChatGPT") {
                    Task { await chatGPTAuth.signIn() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

'''
p = ios / cv
text = p.read_text()
if marker not in text:
    raise RuntimeError("home marker not found")
p.write_text(text.replace(marker, card + marker, 1))

# Route the completed WAV to ChatGPT. We deliberately leave VocaPhone's
# capture/Quick Dictation/session machinery untouched.
rc = "VocaPhoneApp/Sessions/RecordingCoordinator.swift"
replace_once(
    rc,
    '''        adoptPendingHandoff()
        DiagnosticLog.record(.appStarted)
''',
    '''        adoptPendingHandoff()
        try? altBridgeServer.start { [weak self] request in
            guard let self else {
                return VocaPhoneAltBridgeState(
                    revision: 0,
                    serviceReady: false,
                    status: .error,
                    requestID: request.requestID,
                    text: nil,
                    error: "VocaPhone GPT is unavailable."
                )
            }
            return await self.handleAltBridge(request)
        }
        DiagnosticLog.record(.appStarted)
'''
)

replace_once(rc, '''    private let recorder = AudioRecorder()
''', '''    private let recorder = AudioRecorder()
    private let altBridgeServer = VocaPhoneAltBridgeServer()
    private var altBridgeStatus: VocaPhoneAltBridgeStatus = .idle
    private var altBridgeRequestID: String?
    private var altBridgeMode: VocaPhoneAltBridgeMode = .smart
    private var altBridgeText: String?
    private var altBridgeError: String?
    private var altBridgeRecordingURL: URL?
    private var altBridgeRevision: UInt64 = 0
    private var altBridgeTranscriptionTask: Task<Void, Never>?
''')
replace_once(
    rc,
    '''        captureClaimedTranscriptionSettings()
        try? store.save(record)

        // Local inference deliberately happens before the gateway guard. A
''',
    '''        captureClaimedTranscriptionSettings()
        record.processingLocation = .gateway
        try? store.save(record)

        // This test build keeps VocaPhone's capture and Quick Dictation path,
        // but replaces both local-model and self-hosted-gateway transcription
        // with the signed-in ChatGPT account.
        await streamingBridge.cancel()
        await finalizeWithChatGPT(&record, audioURL: output)

        // Local inference deliberately happens before the gateway guard. A
'''
)

# AltServer can strip or rewrite App Group entitlements. Keep VocaPhone's
# microphone standby, but do not make the standby itself depend on the shared
# container.
p = ios / rc
text = p.read_text()
arm_start = text.index("    private func armQuickDictation() {")
watcher_start = text.index("    private func beginQuickDictationWatcher(", arm_start)
alt_arm = '''    private func armQuickDictation() {
        guard audioSessionAvailable, !recorder.isRecording else { return }

        quickDictationWatcherTask?.cancel()
        quickDictationWatcherTask = nil

        do {
            try recorder.startStandby()
            let duration = KeyboardPreferences.quickDictationDuration
            let activatedAt = Date()
            let expiresAt = duration.renewsLease
                ? activatedAt.addingTimeInterval(24 * 60 * 60)
                : duration.expiry(from: activatedAt)

            quickDictationDuration = duration
            quickDictationExpiresAt = expiresAt
            liveActivity.startStandby(expiresAt: expiresAt)
            message = "VocaPhone GPT 已待命。"

            if !duration.renewsLease {
                quickDictationWatcherTask = Task { [weak self] in
                    let seconds = max(1, expiresAt.timeIntervalSinceNow)
                    try? await Task.sleep(for: .seconds(seconds))
                    guard let self, !Task.isCancelled, !self.recorder.isRecording else { return }
                    self.clearQuickDictationReadiness(deactivateAudioSession: true)
                }
            }
        } catch {
            message = "VocaPhone GPT 无法保持待命：\(error.localizedDescription)"
        }
    }

'''
text = text[:arm_start] + alt_arm + text[watcher_start:]
p.write_text(text)

# Remove the original local-model/gateway body from finalizeAndTranscribe.
p = ios / rc
text = p.read_text()
old_start = text.index("        // Local inference deliberately happens before the gateway guard. A")
next_method = text.index("    private func finalizeLocally(_ record: inout SessionRecord, audioURL: URL) async {")
text = text[:old_start] + "    }\n\n" + text[next_method:]
p.write_text(text)

method_marker = '    private func finalizeLocally(_ record: inout SessionRecord, audioURL: URL) async {\n'
method = '''    private func currentAltBridgeState() -> VocaPhoneAltBridgeState {
        VocaPhoneAltBridgeState(
            revision: altBridgeRevision,
            serviceReady: ChatGPTAuthManager.shared.isSignedIn,
            status: altBridgeStatus,
            requestID: altBridgeRequestID,
            text: altBridgeText,
            error: altBridgeError
        )
    }

    private func markAltBridgeChanged() {
        altBridgeRevision &+= 1
    }

    func handleAltBridge(_ request: VocaPhoneAltBridgeRequest) async -> VocaPhoneAltBridgeState {
        switch request.action {
        case .state:
            break

        case .start:
            await startAltBridgeRecording(
                requestID: request.requestID,
                mode: request.mode ?? .smart
            )

        case .stop:
            stopAltBridgeRecording(requestID: request.requestID)

        case .cancel:
            cancelAltBridgeRecording(requestID: request.requestID)

        case .acknowledge:
            if request.requestID == nil || request.requestID == altBridgeRequestID {
                altBridgeRequestID = nil
                altBridgeText = nil
                altBridgeError = nil
                altBridgeStatus = .idle
                markAltBridgeChanged()
            }
        }
        return currentAltBridgeState()
    }

    private func startAltBridgeRecording(
        requestID: String?,
        mode: VocaPhoneAltBridgeMode
    ) async {
        guard let requestID, !requestID.isEmpty else {
            altBridgeStatus = .error
            altBridgeError = "Invalid keyboard request."
            markAltBridgeChanged()
            return
        }
        guard ChatGPTAuthManager.shared.isSignedIn else {
            altBridgeRequestID = requestID
            altBridgeStatus = .error
            altBridgeError = "请先打开 VocaPhone GPT 登录 ChatGPT。"
            markAltBridgeChanged()
            return
        }
        guard !recorder.isRecording else {
            altBridgeRequestID = requestID
            altBridgeStatus = .error
            altBridgeError = "麦克风正在被另一个 VocaPhone 会话使用。"
            markAltBridgeChanged()
            return
        }

        altBridgeRequestID = requestID
        altBridgeMode = mode
        altBridgeText = nil
        altBridgeError = nil
        altBridgeStatus = .starting
        markAltBridgeChanged()

        do {
            try await recorder.prepareForRecording()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("VocaPhone-GPT-AltBridge", isDirectory: true)
            let sessionID = UUID()
            altBridgeRecordingURL = try recorder.start(
                sessionID: sessionID,
                directory: directory,
                includeLocalModelChunks: false
            )
            altBridgeStatus = .recording
            message = "VocaPhone GPT 正在录音…"
            markAltBridgeChanged()
        } catch {
            altBridgeStatus = .error
            altBridgeError = "无法在后台启动麦克风：\(error.localizedDescription)。请打开 VocaPhone GPT 恢复待命。"
            markAltBridgeChanged()
        }
    }

    private func stopAltBridgeRecording(requestID: String?) {
        guard altBridgeStatus == .recording,
              let activeID = altBridgeRequestID,
              requestID == nil || requestID == activeID
        else { return }

        let output = recorder.stopSession(keepAudioSessionActive: true) ?? altBridgeRecordingURL
        altBridgeRecordingURL = nil
        guard let output else {
            altBridgeStatus = .error
            altBridgeError = "没有取得录音文件。"
            markAltBridgeChanged()
            return
        }

        altBridgeStatus = .transcribing
        altBridgeError = nil
        markAltBridgeChanged()

        let mode = altBridgeMode
        altBridgeTranscriptionTask?.cancel()
        altBridgeTranscriptionTask = Task { [weak self] in
            await self?.finishAltBridgeTranscription(
                audioURL: output,
                requestID: activeID,
                mode: mode
            )
        }
    }

    private func cancelAltBridgeRecording(requestID: String?) {
        guard requestID == nil || requestID == altBridgeRequestID else { return }
        altBridgeTranscriptionTask?.cancel()
        altBridgeTranscriptionTask = nil
        recorder.cancelSession(keepAudioSessionActive: true)
        if let url = altBridgeRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        altBridgeRecordingURL = nil
        altBridgeRequestID = nil
        altBridgeText = nil
        altBridgeError = nil
        altBridgeStatus = .idle
        markAltBridgeChanged()
    }

    private func finishAltBridgeTranscription(
        audioURL: URL,
        requestID: String,
        mode: VocaPhoneAltBridgeMode
    ) async {
        defer { try? FileManager.default.removeItem(at: audioURL) }

        do {
            let credential = try await ChatGPTAuthManager.shared.validCredential()
            let raw = try await ChatGPTTranscriptionService().transcribe(
                audioURL: audioURL,
                credential: credential
            )
            let result: String
            if mode == .smart {
                do {
                    result = try await ChatGPTCleanupService().clean(
                        transcript: raw,
                        credential: credential
                    )
                } catch {
                    result = raw
                }
            } else {
                result = raw
            }

            guard altBridgeRequestID == requestID else { return }
            altBridgeText = result
            altBridgeError = nil
            altBridgeStatus = .completed
            message = mode == .smart ? "智能整理完成。" : "原文识别完成。"
            markAltBridgeChanged()
        } catch {
            guard altBridgeRequestID == requestID else { return }
            altBridgeText = nil
            altBridgeError = error.localizedDescription
            altBridgeStatus = .error
            markAltBridgeChanged()
        }
    }

    private func finalizeWithChatGPT(_ record: inout SessionRecord, audioURL: URL) async {
        do {
            if record.state == .finalizing || record.canRetry {
                try record.transition(to: .uploading)
            }
            try store.save(record)
            activeRecord = record
            message = "正在发送给 ChatGPT…"
            liveActivity.update(status: "Sending to ChatGPT", canFinish: false)

            let credential = try await ChatGPTAuthManager.shared.validCredential()

            try record.transition(to: .transcribing)
            try store.save(record)
            activeRecord = record
            message = "ChatGPT 正在识别…"
            liveActivity.update(status: "ChatGPT transcribing", canFinish: false)

            let rawTranscript = try await ChatGPTTranscriptionService().transcribe(
                audioURL: audioURL,
                credential: credential
            )

            let mode = WritingStyle(rawValue: record.style) ?? .clean
            let finalText: String
            if mode == .raw {
                finalText = rawTranscript
            } else {
                do {
                    finalText = try await ChatGPTCleanupService().clean(
                        transcript: rawTranscript,
                        credential: credential
                    )
                } catch {
                    // A valid transcription is more important than losing the
                    // whole dictation because the optional cleanup call failed.
                    finalText = rawTranscript
                }
            }

            record.transcript = finalText
            record.error = nil
            try record.transition(to: .readyToInsert)
            try store.save(record)
            activeRecord = record
            DiagnosticLog.record(.transcriptReady)
            try? FileManager.default.removeItem(at: audioURL)
            markTranscriptDelivered(for: record)
            liveActivity.end(status: "Transcript ready")
            message = mode == .raw ? "原文识别完成。" : "智能整理完成。"
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            await fail(
                &record,
                state: .transcriptionFailedRecoverable,
                code: "chatgpt_transcription_failed",
                message: error.localizedDescription.isEmpty
                    ? "ChatGPT 语音识别失败。请确认已登录后重试。"
                    : error.localizedDescription
            )
        }
    }

'''
p = ios / rc
text = p.read_text()
if method_marker not in text:
    raise RuntimeError("finalizeLocally marker not found")
p.write_text(text.replace(method_marker, method + method_marker, 1))


# The AltServer build does not use SharedStore for dictation. The keyboard talks
# to the still-running containing app over localhost and receives the final text
# over the same channel.
kb = "VocaPhoneKeyboard/KeyboardViewController.swift"
replace_once(
    kb,
    '''    private let store = SharedStore.shared
''',
    '''    private let store = SharedStore.shared
    private let altBridge = VocaPhoneAltBridgeClient()
    private var altBridgeRequestID: String?
    private var altBridgeTask: Task<Void, Never>?
    private var altBridgePollTask: Task<Void, Never>?
'''
)

replace_once(
    kb,
    '''        case .start: startSession()
        case .finish: finishRecording()
''',
    '''        case .start: startAltBridgeSession()
        case .finish: finishAltBridgeRecording()
'''
)

replace_once(
    kb,
    '''        case .cancel: cancelSession()
''',
    '''        case .cancel:
            if altBridgeRequestID != nil {
                cancelAltBridgeSession()
            } else {
                cancelSession()
            }
'''
)

bridge_keyboard_methods = '''    private func startAltBridgeSession() {
        guard hasFullAccess else {
            dictationSurfaceState.showRecoveryMessage("请先为 vocaphone 打开“允许完全访问”。")
            return
        }

        let requestID = UUID().uuidString
        altBridgeTask?.cancel()
        dictationSurfaceState.showRecoveryMessage("正在连接 VocaPhone GPT…")

        let mode: VocaPhoneAltBridgeMode =
            KeyboardPreferences.writingStyle == .raw ? .verbatim : .smart

        altBridgeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let state = try await altBridge.send(
                    .start,
                    requestID: requestID,
                    mode: mode
                )
                guard state.requestID == requestID else {
                    showAltBridgeFailure("VocaPhone GPT 返回了错误的会话。")
                    return
                }
                if state.status == .recording {
                    altBridgeRequestID = requestID
                    renderAltBridge(state)
                } else if state.status == .error {
                    showAltBridgeFailure(state.error ?? "VocaPhone GPT 无法开始录音。")
                } else {
                    altBridgeRequestID = requestID
                    renderAltBridge(state)
                }
            } catch {
                showAltBridgeFailure("VocaPhone GPT 未在后台待命。正在打开主程序，请返回后再点一次麦克风。")
                openContainingAppAction("ready")
            }
        }
    }

    private func finishAltBridgeRecording() {
        guard let requestID = altBridgeRequestID else { return }
        altBridgeTask?.cancel()
        altBridgeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let state = try await altBridge.send(.stop, requestID: requestID)
                renderAltBridge(state)
                startAltBridgePolling(requestID: requestID)
            } catch {
                showAltBridgeFailure("无法通知 VocaPhone GPT 停止录音：\(error.localizedDescription)")
            }
        }
    }

    private func cancelAltBridgeSession() {
        guard let requestID = altBridgeRequestID else {
            render(nil)
            return
        }
        altBridgePollTask?.cancel()
        altBridgePollTask = nil
        altBridgeRequestID = nil
        Task { [altBridge] in
            _ = try? await altBridge.send(.cancel, requestID: requestID)
        }
        render(nil)
    }

    private func startAltBridgePolling(requestID: String) {
        altBridgePollTask?.cancel()
        altBridgePollTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<240 {
                if Task.isCancelled { return }
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    let state = try await altBridge.fetchState()
                    guard altBridgeRequestID == requestID else { return }
                    renderAltBridge(state)
                    if state.status == .completed || state.status == .error {
                        return
                    }
                } catch {
                    if altBridgeRequestID == requestID {
                        showAltBridgeFailure("与 VocaPhone GPT 的连接中断。")
                    }
                    return
                }
            }
            if altBridgeRequestID == requestID {
                showAltBridgeFailure("ChatGPT 识别等待超时。")
            }
        }
    }

    private func renderAltBridge(_ state: VocaPhoneAltBridgeState) {
        guard state.requestID == nil || state.requestID == altBridgeRequestID else { return }

        switch state.status {
        case .starting:
            dictationSurfaceState.state = .launchingApp
            dictationSurfaceState.centerMessage = "正在启动麦克风…"
            dictationSurfaceState.primaryIsEnabled = false
            showAltBridgeSurface()

        case .recording:
            dictationSurfaceState.state = .recording
            dictationSurfaceState.centerMessage = nil
            dictationSurfaceState.primarySymbol = "checkmark"
            dictationSurfaceState.primaryLabel = "完成"
            dictationSurfaceState.primaryIsEnabled = true
            dictationSurfaceState.onPrimary = { [weak self] in self?.finishAltBridgeRecording() }
            showAltBridgeSurface()

        case .transcribing:
            dictationSurfaceState.state = .transcribing
            dictationSurfaceState.centerMessage = KeyboardPreferences.writingStyle == .raw
                ? "ChatGPT 正在原文识别…"
                : "ChatGPT 正在智能整理…"
            dictationSurfaceState.primaryIsEnabled = false
            showAltBridgeSurface()

        case .completed:
            guard let requestID = altBridgeRequestID,
                  let text = state.text,
                  !text.isEmpty
            else {
                showAltBridgeFailure("识别完成，但没有返回文字。")
                return
            }
            altBridgePollTask?.cancel()
            altBridgePollTask = nil
            textDocumentProxy.insertText(text)
            lastInsertedText = text
            dictationSurfaceState.hasTypedThisSession = true
            altBridgeRequestID = nil
            render(nil)
            Task { [altBridge] in
                _ = try? await altBridge.send(.acknowledge, requestID: requestID)
            }

        case .error:
            showAltBridgeFailure(state.error ?? "VocaPhone GPT 语音输入失败。")

        case .idle:
            if altBridgeRequestID != nil {
                showAltBridgeFailure("VocaPhone GPT 会话已结束，请重试。")
            }
        }
    }

    private func showAltBridgeSurface() {
        surfaceOwnedKeyboard = true
        keyGrid.endActiveInteractions()
        keyGrid.isHidden = true
        emojiPanel?.isHidden = true
        dictationBar.isHidden = true
        dictationSurfaceHosting?.view.isHidden = false
    }

    private func showAltBridgeFailure(_ message: String) {
        altBridgePollTask?.cancel()
        altBridgePollTask = nil
        altBridgeRequestID = nil
        render(nil)
        dictationSurfaceState.showRecoveryMessage(message)
    }

'''
replace_once(
    kb,
    '''    private func finishRecording() {
''',
    bridge_keyboard_methods + '''    private func finishRecording() {
'''
)

# Add a small marker to distinguish this personal test build in the home title.
replace_once(
    cv,
    '.navigationTitle("vocaphone")',
    '.navigationTitle("VocaPhone GPT")'
)

print("VocaPhone GPT patch applied")
