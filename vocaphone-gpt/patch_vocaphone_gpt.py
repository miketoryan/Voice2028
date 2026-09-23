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
                    .foregroundStyle(chatGPTAuth.isSignedIn ? .secondary : .orange)
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
        return

        // Local inference deliberately happens before the gateway guard. A
'''
)

method_marker = '    private func finalizeLocally(_ record: inout SessionRecord, audioURL: URL) async {\n'
method = '''    private func finalizeWithChatGPT(_ record: inout SessionRecord, audioURL: URL) async {
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

# Add a small marker to distinguish this personal test build in the home title.
replace_once(
    cv,
    '.navigationTitle("vocaphone")',
    '.navigationTitle("VocaPhone GPT")'
)

print("VocaPhone GPT patch applied")
