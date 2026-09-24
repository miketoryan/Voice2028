import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    private var language: InterfaceLanguage { model.interfaceLanguage }

    var body: some View {
        Group {
            if model.handoffActive {
                HandoffView(language: language)
            } else {
                TabView {
                    HomeView(model: model)
                        .tabItem {
                            Label(language.text(chinese: "首页", english: "Home"), systemImage: "house.fill")
                        }

                    SettingsView(model: model)
                        .tabItem {
                            Label(language.text(chinese: "设置", english: "Settings"), systemImage: "gearshape.fill")
                        }

                    HelpView(language: language)
                        .tabItem {
                            Label(language.text(chinese: "说明", english: "Help"), systemImage: "book.closed.fill")
                        }
                }
            }
        }
    }
}

private struct HandoffView: View {
    let language: InterfaceLanguage

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.indigo, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 88, height: 88)
                Text("VK")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }

            Text("Voice2028")
                .font(.title2.bold())

            Text(language.text(chinese: "正在启动语音输入…", english: "Starting voice input…"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

private struct HomeView: View {
    @ObservedObject var model: AppModel

    private func t(_ chinese: String, _ english: String) -> String {
        model.interfaceLanguage.text(chinese: chinese, english: english)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(t("GPT 账号", "GPT Account")) {
                    LabeledContent(t("账号", "Account")) {
                        Text(model.signedIn
                             ? (model.accountEmail ?? t("已登录", "Signed in"))
                             : t("未登录", "Not signed in"))
                            .foregroundStyle(.secondary)
                    }

                    if model.signedIn {
                        Button(t("退出登录", "Sign Out"), role: .destructive) {
                            model.signOut()
                        }
                    } else {
                        Button(t("登录 ChatGPT", "Sign in to ChatGPT")) {
                            Task { await model.signIn() }
                        }
                    }
                }

                Section(t("软件状态", "Status")) {
                    LabeledContent(t("键盘服务", "Keyboard Service")) {
                        Label(
                            model.serviceReady ? t("运行中", "Running") : t("已停止", "Stopped"),
                            systemImage: model.serviceReady ? "checkmark.circle.fill" : "pause.circle"
                        )
                        .foregroundStyle(model.serviceReady ? Color.green : Color.secondary)
                    }

                    Text(model.statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let error = model.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    if model.serviceReady {
                        Button(t("停止键盘服务", "Stop Keyboard Service"), role: .destructive) {
                            model.stopService()
                        }
                    } else {
                        Button(t("启动键盘服务", "Start Keyboard Service")) {
                            Task { await model.startService() }
                        }
                        .disabled(!model.signedIn)
                    }
                }
            }
            .navigationTitle("Voice2028")
            .safeAreaInset(edge: .top) {
                HStack {
                    Spacer()
                    Text("v0.4.10 · build 35")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 16)
                }
                .background(.clear)
            }
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel

    private func t(_ chinese: String, _ english: String) -> String {
        model.interfaceLanguage.text(chinese: chinese, english: english)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(t("界面语言", "Interface Language")) {
                    Picker(t("界面语言", "Interface Language"), selection: $model.interfaceLanguage) {
                        Text("中文").tag(InterfaceLanguage.chinese)
                        Text("English").tag(InterfaceLanguage.english)
                    }
                    .pickerStyle(.segmented)

                    Text(t(
                        "这里只控制 Voice2028 软件和键盘提示文字。",
                        "This only changes Voice2028's app and keyboard text."
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section(t("识别语言", "Recognition Language")) {
                    Picker(t("默认识别语言", "Default Recognition Language"), selection: $model.recognitionLanguage) {
                        ForEach(RecognitionLanguage.allCases) { language in
                            Text(language.displayName(interfaceLanguage: model.interfaceLanguage))
                                .tag(language)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(t(
                        "默认使用中文可减少每次自动判断语言的开销；整段英文时可切换为 English，中英混合较多时可选“自动”。",
                        "Chinese is the default to avoid automatic language detection on every request. Choose English for English-only dictation or Auto for heavily mixed speech."
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section(t("语音模式", "Voice Mode")) {
                    LabeledContent(t("默认模式", "Default"), value: t("智能整理", "Smart Cleanup"))
                    Text(t(
                        "也可以直接在键盘顶部切换为“原文模式”。",
                        "You can switch to Verbatim directly from the keyboard."
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section(t("麦克风", "Microphone")) {
                    Text(t(
                        "Voice2028 在后台运行时，键盘优先直接启动录音，不再切换到主程序；只有后台服务失效时才会自动唤醒主程序恢复。退出输入界面10秒后关闭麦克风。",
                        "When Voice2028 is running in the background, the keyboard starts recording directly without switching apps. It wakes the main app only if background recovery is required. The microphone closes 10 seconds after leaving the input screen."
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(t("设置", "Settings"))
        }
    }
}

private struct HelpView: View {
    let language: InterfaceLanguage

    private func t(_ chinese: String, _ english: String) -> String {
        language.text(chinese: chinese, english: english)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(t("首次设置", "Initial Setup")) {
                    Text(t(
                        "1. 在首页登录 ChatGPT。登录成功后会自动启动键盘服务。",
                        "1. Sign in to ChatGPT on the Home screen. The keyboard service starts automatically."
                    ))
                    Text(t(
                        "2. 打开 iPhone 设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → Voice2028。",
                        "2. Open iPhone Settings → General → Keyboard → Keyboards → Add New Keyboard → Voice2028."
                    ))
                    Text(t(
                        "3. 打开 Voice2028 的“允许完全访问”。",
                        "3. Enable Allow Full Access for Voice2028."
                    ))
                }

                Section(t("键盘使用", "Using the Keyboard")) {
                    Text(t(
                        "Voice2028 是纯语音键盘，不提供拼音或英文按键输入。",
                        "Voice2028 is voice-only and does not include Pinyin or QWERTY typing."
                    ))
                    Text(t(
                        "后台服务正常时，点击麦克风会直接开始录音；服务失效时才短暂唤醒 Voice2028 并自动返回。",
                        "When the background service is available, tapping the microphone starts recording directly. Voice2028 briefly wakes and returns only when recovery is needed."
                    ))
                    Text(t(
                        "再次点击结束录音；识别完成后文字直接插入当前输入框，不需要确认。",
                        "Tap again to stop. The result is inserted automatically without confirmation."
                    ))
                    Text(t(
                        "默认识别语言为中文，可在设置中切换为“自动”或 English；键盘顶部只保留智能/原文模式切换。",
                        "The default recognition language is Chinese. You can switch to Auto or English in Settings; the keyboard only shows Smart/Verbatim mode selection."
                    ))
                }

                Section(t("语音模式", "Voice Modes")) {
                    Text(t(
                        "智能整理（默认）：添加标点和分段，删除无意义口头语与重复内容，修正明显语病，但不改变原意、不新增信息。",
                        "Smart Cleanup (default): adds punctuation and paragraphs, removes meaningless filler and repetition, and fixes obvious grammar without changing meaning or adding information."
                    ))
                    Text(t(
                        "原文模式：只转录，尽量保留原话，适合会议和原始记录。",
                        "Verbatim: transcription only, preserving the original wording for meetings and records."
                    ))
                }

                Section(t("注意事项", "Notes")) {
                    Text(t(
                        "语音转录和智能整理需要连接 ChatGPT；普通文字输入请切换到苹果自带键盘。",
                        "Transcription and Smart Cleanup require ChatGPT. Use Apple's keyboard for regular typing."
                    ))
                    Text(t(
                        "Voice2028 不使用画中画或悬浮视频。",
                        "Voice2028 does not use Picture in Picture or floating video."
                    ))
                }

                Section(t("版本", "Version")) {
                    LabeledContent("Voice2028", value: "0.4.10 · build 35")
                }
            }
            .navigationTitle(t("说明", "Help"))
        }
    }
}
