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
                    Text("v0.5.2 · build 20")
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
                        "这里只控制 Voice2028 软件和键盘提示文字。语音输入语言由 ChatGPT 自动识别，可直接混合使用中英文。",
                        "This only changes Voice2028's app and keyboard text. ChatGPT detects the spoken language automatically, including mixed Chinese and English."
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
                        "Voice2028 在后台仍可响应时，键盘优先直接启动录音；如果系统已挂起主程序，则自动唤醒主程序恢复。录音结束后停止写入文件，但键盘仍显示时麦克风引擎继续待命；退出输入界面约10秒后关闭麦克风。后台不播放静音音频。",
                        "When Voice2028 is still responsive in the background, the keyboard starts recording directly. If iOS has suspended the app, Voice2028 wakes automatically for recovery. After recording stops, file writing ends while the microphone engine remains ready as long as the keyboard is visible. The microphone closes about 10 seconds after leaving the input screen. No silent audio is played in the background."
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
                        "ChatGPT 自动判断输入语言；键盘顶部只保留智能/原文模式切换。",
                        "ChatGPT detects the spoken language automatically. The keyboard only shows Smart/Verbatim mode selection."
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
                    LabeledContent("Voice2028", value: "0.5.2 · build 20")
                }
            }
            .navigationTitle(t("说明", "Help"))
        }
    }
}
