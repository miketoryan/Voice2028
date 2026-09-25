import UIKit

private enum InputMode: Int, CaseIterable {
    case voice
    case stroke
    case clipboard
    case english

    var title: String {
        switch self {
        case .voice: return "语音"
        case .stroke: return "笔画"
        case .clipboard: return "剪贴"
        case .english: return "英文"
        }
    }
}

private enum ShiftState {
    case off
    case once
    case caps
}

private final class ActionButton: UIButton {
    private var action: (() -> Void)?

    func setAction(_ action: @escaping () -> Void) {
        self.action = action
        addTarget(self, action: #selector(runAction), for: .touchUpInside)
    }

    @objc private func runAction() {
        action?()
    }
}

private struct StrokeEntry {
    let text: String
    let code: String
}

private final class StrokeRepository: @unchecked Sendable {
    static let shared = StrokeRepository()

    private let queue = DispatchQueue(label: "com.openless.ios.stroke", qos: .userInitiated)
    private var buckets: [String: [StrokeEntry]] = [:]
    private var frequency: [String: Int64] = [:]
    private var loaded = false
    private var loading = false

    private let fallback: [StrokeEntry] = [
        .init(text: "你", code: "psh"), .init(text: "好", code: "ny"),
        .init(text: "我", code: "psh"), .init(text: "是", code: "hs"),
        .init(text: "的", code: "p"), .init(text: "不", code: "h"),
        .init(text: "了", code: "z"), .init(text: "在", code: "sh"),
        .init(text: "人", code: "p"), .init(text: "有", code: "h"),
        .init(text: "这", code: "z"), .init(text: "个", code: "p"),
        .init(text: "中", code: "s"), .init(text: "国", code: "s"),
        .init(text: "就", code: "nhszhspnhpzn")
    ]

    func preload() {
        queue.async { [weak self] in
            self?.ensureLoaded()
        }
    }

    func search(_ pattern: String) async -> [String] {
        guard !pattern.isEmpty else { return [] }

        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: [])
                    return
                }
                self.ensureLoaded()

                let prefix = String(pattern.prefix { $0 != "*" }.prefix(4))
                let source = self.buckets[prefix] ?? []
                var seen = Set<String>()
                var result: [String] = []

                let sorted = source
                    .filter { self.matches(pattern, $0.code) }
                    .sorted {
                        (self.frequency[$0.text] ?? 0) > (self.frequency[$1.text] ?? 0)
                    }

                for entry in sorted where !seen.contains(entry.text) {
                    seen.insert(entry.text)
                    result.append(entry.text)
                    if result.count >= 36 { break }
                }

                continuation.resume(returning: result)
            }
        }
    }

    private func ensureLoaded() {
        if loaded || loading { return }
        loading = true
        defer {
            loaded = true
            loading = false
        }

        let entries = loadStrokeEntries()
        frequency = loadFrequency()

        var map: [String: [StrokeEntry]] = [:]
        for entry in entries {
            let code = entry.code
            let maxPrefix = min(4, code.count)
            for length in 1...maxPrefix {
                let key = String(code.prefix(length))
                map[key, default: []].append(entry)
            }
        }
        buckets = map
    }

    private func loadStrokeEntries() -> [StrokeEntry] {
        guard let url = Bundle.main.url(forResource: "stroke.dict", withExtension: "tsv"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return fallback
        }

        return raw.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  !parts[0].isEmpty,
                  !parts[1].isEmpty,
                  parts[1].allSatisfy({ "hspnz".contains($0) }) else {
                return nil
            }
            return StrokeEntry(text: parts[0], code: parts[1])
        }
    }

    private func loadFrequency() -> [String: Int64] {
        guard let url = Bundle.main.url(forResource: "stroke-frequency", withExtension: "tsv"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }

        var result: [String: Int64] = [:]
        for line in raw.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            if parts.count == 2, let value = Int64(parts[1]), !parts[0].isEmpty {
                result[parts[0]] = value
            }
        }
        return result
    }

    private func matches(_ pattern: String, _ code: String) -> Bool {
        let p = Array(pattern)
        let c = Array(code)
        if p.count > c.count { return false }
        for index in p.indices {
            if p[index] != "*" && p[index] != c[index] { return false }
        }
        return true
    }
}

final class KeyboardViewController: UIInputViewController {
    private var inputMode: InputMode = .voice
    private var symbolMode = false
    private var shiftState: ShiftState = .off
    private var traditionalOutput = false
    private var strokeCode = ""
    private var strokeCandidates: [String] = []
    private var clipboardHistory: [String] = []
    private var voiceState = "idle"

    private let panelHeight: CGFloat = 300
    private let sideInset: CGFloat = 12
    private var heightConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = panelBackground
        heightConstraint = view.heightAnchor.constraint(equalToConstant: panelHeight)
        heightConstraint?.priority = .defaultHigh
        heightConstraint?.isActive = true

        StrokeRepository.shared.preload()
        restorePreferences()
        installSwipeGestures()
        rebuild()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshClipboardHistory()
    }

    private var isDark: Bool {
        traitCollection.userInterfaceStyle == .dark
    }

    private var panelBackground: UIColor {
        isDark ? UIColor(red: 48/255, green: 48/255, blue: 48/255, alpha: 1) :
            UIColor(red: 242/255, green: 242/255, blue: 246/255, alpha: 1)
    }

    private var keyBackground: UIColor {
        isDark ? UIColor(red: 62/255, green: 62/255, blue: 64/255, alpha: 1) :
            UIColor(red: 225/255, green: 225/255, blue: 228/255, alpha: 1)
    }

    private var textColor: UIColor {
        isDark ? .white : UIColor(red: 30/255, green: 30/255, blue: 34/255, alpha: 1)
    }

    private var secondaryTextColor: UIColor {
        isDark ? UIColor(white: 0.74, alpha: 1) : UIColor(white: 0.42, alpha: 1)
    }

    private func restorePreferences() {
        let defaults = UserDefaults.standard
        if let raw = defaults.object(forKey: "openless_ios_mode") as? Int,
           let mode = InputMode(rawValue: raw) {
            inputMode = mode
        }
        traditionalOutput = defaults.bool(forKey: "openless_ios_traditional")
    }

    private func saveMode() {
        UserDefaults.standard.set(inputMode.rawValue, forKey: "openless_ios_mode")
    }

    private func installSwipeGestures() {
        let left = UISwipeGestureRecognizer(target: self, action: #selector(swipedLeft))
        left.direction = .left
        view.addGestureRecognizer(left)

        let right = UISwipeGestureRecognizer(target: self, action: #selector(swipedRight))
        right.direction = .right
        view.addGestureRecognizer(right)
    }

    @objc private func swipedLeft() {
        stepMode(+1)
    }

    @objc private func swipedRight() {
        stepMode(-1)
    }

    private func stepMode(_ delta: Int) {
        let next = max(0, min(InputMode.allCases.count - 1, inputMode.rawValue + delta))
        guard let mode = InputMode(rawValue: next), mode != inputMode else { return }
        selectMode(mode)
    }

    private func selectMode(_ mode: InputMode) {
        inputMode = mode
        symbolMode = false
        shiftState = .off
        strokeCode = ""
        strokeCandidates = []
        saveMode()
        rebuild()
    }

    private func rebuild() {
        view.subviews.forEach { $0.removeFromSuperview() }
        view.backgroundColor = panelBackground

        let root = UIStackView()
        root.axis = .vertical
        root.spacing = inputMode == .stroke ? 4 : 8
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inputMode == .stroke ? 4 : sideInset),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: inputMode == .stroke ? -4 : -sideInset),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6)
        ])

        root.addArrangedSubview(buildHeader())

        switch inputMode {
        case .voice:
            buildVoice(into: root)
        case .stroke:
            buildStroke(into: root)
        case .clipboard:
            buildClipboard(into: root)
        case .english:
            buildEnglish(into: root)
        }
    }

    private func buildHeader() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.heightAnchor.constraint(equalToConstant: 38).isActive = true

        let brand = UIControl()
        let brandRow = UIStackView()
        brandRow.axis = .horizontal
        brandRow.alignment = .center
        brandRow.spacing = 6
        brandRow.isUserInteractionEnabled = false
        brandRow.translatesAutoresizingMaskIntoConstraints = false

        if let path = Bundle.main.path(forResource: "openless_wordmark", ofType: "png"),
           let image = UIImage(contentsOfFile: path)?.withRenderingMode(.alwaysTemplate) {
            let imageView = UIImageView(image: image)
            imageView.tintColor = textColor
            imageView.contentMode = .scaleAspectFit
            imageView.widthAnchor.constraint(lessThanOrEqualToConstant: 92).isActive = true
            imageView.heightAnchor.constraint(equalToConstant: 19).isActive = true
            brandRow.addArrangedSubview(imageView)
        } else {
            let label = UILabel()
            label.text = "OpenLess"
            label.font = .systemFont(ofSize: 18, weight: .bold)
            label.textColor = textColor
            brandRow.addArrangedSubview(label)
        }

        brand.addSubview(brandRow)
        NSLayoutConstraint.activate([
            brandRow.leadingAnchor.constraint(equalTo: brand.leadingAnchor),
            brandRow.trailingAnchor.constraint(lessThanOrEqualTo: brand.trailingAnchor),
            brandRow.centerYAnchor.constraint(equalTo: brand.centerYAnchor)
        ])
        brand.setContentHuggingPriority(.defaultLow, for: .horizontal)
        brand.addTarget(self, action: #selector(openHostApp), for: .touchUpInside)

        let segmented = UISegmentedControl(items: InputMode.allCases.map(\.title))
        segmented.selectedSegmentIndex = inputMode.rawValue
        segmented.addTarget(self, action: #selector(modeChanged(_:)), for: .valueChanged)
        segmented.widthAnchor.constraint(equalToConstant: 188).isActive = true
        segmented.heightAnchor.constraint(equalToConstant: 34).isActive = true

        row.addArrangedSubview(brand)
        row.addArrangedSubview(segmented)
        return row
    }

    @objc private func modeChanged(_ sender: UISegmentedControl) {
        guard let mode = InputMode(rawValue: sender.selectedSegmentIndex) else { return }
        selectMode(mode)
    }

    @objc private func openHostApp() {
        openHost(action: "settings")
    }

    private func buildVoice(into root: UIStackView) {
        let status = UILabel()
        status.textAlignment = .center
        status.textColor = secondaryTextColor
        status.font = .systemFont(ofSize: 16)
        status.heightAnchor.constraint(equalToConstant: 38).isActive = true
        status.text = voiceStatusText
        root.addArrangedSubview(status)

        let holder = UIView()
        let mic = ActionButton(type: .system)
        mic.translatesAutoresizingMaskIntoConstraints = false
        mic.layer.cornerRadius = 36
        mic.backgroundColor = voiceState == "recording" ? .systemRed :
            (isDark ? UIColor(white: 0.23, alpha: 1) : .white)
        mic.setTitleColor(voiceState == "recording" ? .white : textColor, for: .normal)
        mic.titleLabel?.font = .systemFont(ofSize: 21, weight: .semibold)
        mic.setTitle(voiceState == "recording" ? "⏹ 结束听写" : "🎙 点击开始说话", for: .normal)
        mic.setAction { [weak self] in self?.toggleVoice() }
        holder.addSubview(mic)

        NSLayoutConstraint.activate([
            mic.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            mic.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            mic.widthAnchor.constraint(equalToConstant: 176),
            mic.heightAnchor.constraint(equalToConstant: 72)
        ])
        root.addArrangedSubview(holder)

        let footer = UIStackView()
        footer.axis = .horizontal
        footer.distribution = .equalSpacing
        footer.alignment = .center
        footer.heightAnchor.constraint(equalToConstant: 78).isActive = true

        footer.addArrangedSubview(makeKey("@", width: 84) { [weak self] in
            self?.insertText("@")
        })
        footer.addArrangedSubview(makeKey("换行", width: 120) { [weak self] in
            self?.insertText("\n")
        })
        footer.addArrangedSubview(makeKey("⌫", width: 84) { [weak self] in
            self?.textDocumentProxy.deleteBackward()
        })
        root.addArrangedSubview(footer)
    }

    private var voiceStatusText: String {
        switch voiceState {
        case "recording": return "再次点击结束"
        case "processing": return "正在思考"
        case "opening": return "正在打开 OpenLess…"
        default: return "点击开始说话"
        }
    }

    private func toggleVoice() {
        guard hasFullAccess else {
            voiceState = "idle"
            showTransientStatus("请在设置中允许“完全访问”")
            return
        }

        if voiceState == "recording" {
            voiceState = "processing"
            rebuild()
            openHost(action: "stop")
        } else {
            voiceState = "opening"
            rebuild()
            openHost(action: "start")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.voiceState = "recording"
                self?.rebuild()
            }
        }
    }

    private func openHost(action: String) {
        guard let url = URL(string: "openless://keyboard?action=\(action)") else { return }
        extensionContext?.open(url, completionHandler: nil)
    }

    private func buildEnglish(into root: UIStackView) {
        addKeyRow(["1","2","3","4","5","6","7","8","9","0"], to: root)

        if symbolMode {
            addKeyRow(["-","/",":",";","(",")","$","&","@","\""], to: root)
            addKeyRow([".",",","?","!","'","#","%","*","+","="], to: root)
            addKeyRow(["[","]","{","}","_","\\","|","~","<",">"], to: root)
        } else {
            addKeyRow(["q","w","e","r","t","y","u","i","o","p"], to: root)
            addKeyRow(["a","s","d","f","g","h","j","k","l"], to: root)
            addKeyRow(["⇧","z","x","c","v","b","n","m","⌫"], to: root)
        }

        let bottom = UIStackView()
        bottom.axis = .horizontal
        bottom.spacing = 6
        bottom.distribution = .fill
        bottom.addArrangedSubview(makeFlexibleKey(symbolMode ? "ABC" : "符号", weight: 1) { [weak self] in
            self?.symbolMode.toggle()
            self?.shiftState = .off
            self?.rebuild()
        })
        bottom.addArrangedSubview(makeFlexibleKey("空格", weight: 2.7) { [weak self] in
            self?.insertText(" ")
        })
        bottom.addArrangedSubview(makeFlexibleKey("Return", weight: 1.35) { [weak self] in
            self?.insertText("\n")
        })
        root.addArrangedSubview(bottom)
    }

    private func addKeyRow(_ labels: [String], to root: UIStackView) {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 5
        row.distribution = .fillEqually
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true

        for label in labels {
            row.addArrangedSubview(makeKey(label) { [weak self] in
                self?.handleEnglishKey(label)
            })
        }
        root.addArrangedSubview(row)
    }

    private func handleEnglishKey(_ key: String) {
        if key == "⌫" {
            textDocumentProxy.deleteBackward()
            return
        }
        if key == "⇧" {
            switch shiftState {
            case .off: shiftState = .once
            case .once: shiftState = .caps
            case .caps: shiftState = .off
            }
            rebuild()
            return
        }

        var output = key
        if !symbolMode && (shiftState == .once || shiftState == .caps) {
            output = output.uppercased()
        }
        insertText(output)
        if shiftState == .once {
            shiftState = .off
            rebuild()
        }
    }

    private func buildStroke(into root: UIStackView) {
        let encode = UIStackView()
        encode.axis = .horizontal
        encode.alignment = .center
        encode.spacing = 4
        encode.backgroundColor = isDark ? UIColor(white: 0.20, alpha: 1) : .white
        encode.layer.cornerRadius = 8
        encode.isLayoutMarginsRelativeArrangement = true
        encode.layoutMargins = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 4)
        encode.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let preview = UILabel()
        preview.text = strokeDisplay(strokeCode)
        preview.textColor = .systemBlue
        preview.font = .systemFont(ofSize: 16.5)
        encode.addArrangedSubview(preview)

        let clear = makeKey("✕", width: 40) { [weak self] in
            self?.strokeCode = ""
            self?.strokeCandidates = []
            self?.rebuild()
        }
        clear.backgroundColor = .clear
        encode.addArrangedSubview(clear)
        root.addArrangedSubview(encode)

        let candidates = UIScrollView()
        candidates.showsHorizontalScrollIndicator = false
        candidates.heightAnchor.constraint(equalToConstant: 38).isActive = true
        let candidateRow = UIStackView()
        candidateRow.axis = .horizontal
        candidateRow.spacing = 5
        candidateRow.translatesAutoresizingMaskIntoConstraints = false
        candidates.addSubview(candidateRow)
        NSLayoutConstraint.activate([
            candidateRow.leadingAnchor.constraint(equalTo: candidates.contentLayoutGuide.leadingAnchor),
            candidateRow.trailingAnchor.constraint(equalTo: candidates.contentLayoutGuide.trailingAnchor),
            candidateRow.topAnchor.constraint(equalTo: candidates.contentLayoutGuide.topAnchor),
            candidateRow.bottomAnchor.constraint(equalTo: candidates.contentLayoutGuide.bottomAnchor),
            candidateRow.heightAnchor.constraint(equalTo: candidates.frameLayoutGuide.heightAnchor)
        ])

        if strokeCandidates.isEmpty {
            let hint = UILabel()
            hint.text = "输入笔画后显示候选字"
            hint.textColor = secondaryTextColor
            hint.font = .systemFont(ofSize: 13)
            candidateRow.addArrangedSubview(hint)
        } else {
            for candidate in strokeCandidates {
                candidateRow.addArrangedSubview(makeKey(candidate, width: 42) { [weak self] in
                    self?.commitStrokeCandidate(candidate)
                })
            }
        }
        root.addArrangedSubview(candidates)

        let strokeRow = UIStackView()
        strokeRow.axis = .horizontal
        strokeRow.spacing = 5
        strokeRow.distribution = .fillEqually
        let strokes: [(String,String)] = [("一","h"),("丨","s"),("丿","p"),("丶","n"),("乛","z"),("＊","*")]
        for (label, code) in strokes {
            strokeRow.addArrangedSubview(makeKey(label) { [weak self] in
                self?.appendStroke(code)
            })
        }
        root.addArrangedSubview(strokeRow)

        let actionRow = UIStackView()
        actionRow.axis = .horizontal
        actionRow.spacing = 5
        actionRow.distribution = .fillEqually
        actionRow.addArrangedSubview(makeKey(traditionalOutput ? "简" : "繁") { [weak self] in
            guard let self else { return }
            self.traditionalOutput.toggle()
            UserDefaults.standard.set(self.traditionalOutput, forKey: "openless_ios_traditional")
            self.rebuild()
        })
        actionRow.addArrangedSubview(makeKey("通配") { [weak self] in self?.appendStroke("*") })
        actionRow.addArrangedSubview(makeKey("空格") { [weak self] in self?.insertText(" ") })
        actionRow.addArrangedSubview(makeKey("换行") { [weak self] in self?.insertText("\n") })
        actionRow.addArrangedSubview(makeKey("⌫") { [weak self] in
            guard let self else { return }
            if !self.strokeCode.isEmpty {
                self.strokeCode.removeLast()
                self.refreshStrokeCandidates()
            } else {
                self.textDocumentProxy.deleteBackward()
            }
        })
        root.addArrangedSubview(actionRow)

        let punctuation = UIStackView()
        punctuation.axis = .horizontal
        punctuation.spacing = 5
        punctuation.distribution = .fillEqually
        for p in ["，","。","？","！","、","；","：","“","”"] {
            punctuation.addArrangedSubview(makeKey(p) { [weak self] in self?.insertText(p) })
        }
        root.addArrangedSubview(punctuation)
    }

    private func appendStroke(_ code: String) {
        strokeCode.append(contentsOf: code)
        refreshStrokeCandidates()
    }

    private func refreshStrokeCandidates() {
        if strokeCode.isEmpty {
            strokeCandidates = []
            rebuild()
            return
        }

        let current = strokeCode
        Task { @MainActor [weak self] in
            let result = await StrokeRepository.shared.search(current)
            guard let self, self.strokeCode == current else { return }
            self.strokeCandidates = result
            self.rebuild()
        }
    }

    private func commitStrokeCandidate(_ candidate: String) {
        insertText(transformScript(candidate))
        strokeCode = ""
        strokeCandidates = []
        rebuild()
    }

    private func strokeDisplay(_ code: String) -> String {
        code.map {
            switch $0 {
            case "h": return "一"
            case "s": return "丨"
            case "p": return "丿"
            case "n": return "丶"
            case "z": return "乛"
            case "*": return "＊"
            default: return String($0)
            }
        }.joined()
    }

    private func transformScript(_ text: String) -> String {
        guard traditionalOutput else { return text }
        let transform = StringTransform("Hans-Hant")
        return text.applyingTransform(transform, reverse: false) ?? text
    }

    private func buildClipboard(into root: UIStackView) {
        let note = UILabel()
        note.text = "剪贴板"
        note.font = .systemFont(ofSize: 15, weight: .medium)
        note.textColor = secondaryTextColor
        note.textAlignment = .center
        root.addArrangedSubview(note)

        let row1 = UIStackView()
        row1.axis = .horizontal
        row1.spacing = 6
        row1.distribution = .fillEqually
        row1.addArrangedSubview(makeKey("选择") { [weak self] in self?.showTransientStatus("iOS 键盘扩展不开放跨 App 选区控制") })
        row1.addArrangedSubview(makeKey("←") { [weak self] in self?.textDocumentProxy.adjustTextPosition(byCharacterOffset: -1) })
        row1.addArrangedSubview(makeKey("→") { [weak self] in self?.textDocumentProxy.adjustTextPosition(byCharacterOffset: 1) })
        row1.addArrangedSubview(makeKey("↑") { [weak self] in self?.textDocumentProxy.adjustTextPosition(byCharacterOffset: -10) })
        row1.addArrangedSubview(makeKey("↓") { [weak self] in self?.textDocumentProxy.adjustTextPosition(byCharacterOffset: 10) })
        root.addArrangedSubview(row1)

        let row2 = UIStackView()
        row2.axis = .horizontal
        row2.spacing = 6
        row2.distribution = .fillEqually
        row2.addArrangedSubview(makeKey("全选") { [weak self] in self?.showTransientStatus("iOS 不向第三方键盘提供“全选”接口") })
        row2.addArrangedSubview(makeKey("复制") { [weak self] in self?.copyContextBeforeCursor() })
        row2.addArrangedSubview(makeKey("粘贴") { [weak self] in self?.pasteClipboard() })
        row2.addArrangedSubview(makeKey("刷新") { [weak self] in
            self?.refreshClipboardHistory()
            self?.rebuild()
        })
        row2.addArrangedSubview(makeKey("⌫") { [weak self] in self?.textDocumentProxy.deleteBackward() })
        root.addArrangedSubview(row2)

        let scroll = UIScrollView()
        scroll.showsVerticalScrollIndicator = false
        let list = UIStackView()
        list.axis = .vertical
        list.spacing = 5
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            list.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            list.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            list.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])

        if clipboardHistory.isEmpty {
            let empty = UILabel()
            empty.text = "暂无剪贴板内容"
            empty.textColor = secondaryTextColor
            empty.textAlignment = .center
            list.addArrangedSubview(empty)
        } else {
            for item in clipboardHistory.prefix(8) {
                let button = makeKey(item, height: 34) { [weak self] in self?.insertText(item) }
                button.contentHorizontalAlignment = .left
                button.titleLabel?.lineBreakMode = .byTruncatingTail
                list.addArrangedSubview(button)
            }
        }
        root.addArrangedSubview(scroll)
    }

    private func refreshClipboardHistory() {
        guard hasFullAccess else { return }
        if let text = UIPasteboard.general.string, !text.isEmpty {
            clipboardHistory.removeAll { $0 == text }
            clipboardHistory.insert(text, at: 0)
            if clipboardHistory.count > 20 {
                clipboardHistory = Array(clipboardHistory.prefix(20))
            }
        }
    }

    private func pasteClipboard() {
        guard hasFullAccess else {
            showTransientStatus("请允许完全访问后使用剪贴板")
            return
        }
        refreshClipboardHistory()
        if let text = UIPasteboard.general.string, !text.isEmpty {
            insertText(text)
        }
    }

    private func copyContextBeforeCursor() {
        guard hasFullAccess else {
            showTransientStatus("请允许完全访问后使用剪贴板")
            return
        }
        guard let text = textDocumentProxy.documentContextBeforeInput, !text.isEmpty else {
            showTransientStatus("光标前没有可复制文本")
            return
        }
        let fragment = String(text.suffix(200))
        UIPasteboard.general.string = fragment
        refreshClipboardHistory()
        showTransientStatus("已复制光标前文本")
    }

    private func makeKey(_ title: String, width: CGFloat? = nil, height: CGFloat = 42, action: @escaping () -> Void) -> ActionButton {
        let button = ActionButton(type: .system)
        button.backgroundColor = keyBackground
        button.setTitleColor(textColor, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        button.layer.cornerRadius = 8
        button.clipsToBounds = true
        button.heightAnchor.constraint(equalToConstant: height).isActive = true
        if let width {
            button.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        button.setTitle(title, for: .normal)
        button.setAction(action)
        return button
    }

    private func makeFlexibleKey(_ title: String, weight: CGFloat, action: @escaping () -> Void) -> UIView {
        let holder = UIView()
        let key = makeKey(title, action: action)
        key.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(key)
        NSLayoutConstraint.activate([
            key.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            key.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            key.topAnchor.constraint(equalTo: holder.topAnchor),
            key.bottomAnchor.constraint(equalTo: holder.bottomAnchor)
        ])
        holder.setContentHuggingPriority(.defaultLow, for: .horizontal)
        holder.widthAnchor.constraint(greaterThanOrEqualToConstant: 44 * weight).isActive = true
        return holder
    }

    private func insertText(_ text: String) {
        textDocumentProxy.insertText(transformScript(text))
    }

    private func showTransientStatus(_ text: String) {
        let banner = UILabel()
        banner.text = text
        banner.textAlignment = .center
        banner.textColor = .white
        banner.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        banner.font = .systemFont(ofSize: 13, weight: .medium)
        banner.numberOfLines = 2
        banner.layer.cornerRadius = 10
        banner.clipsToBounds = true
        banner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            banner.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            banner.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.92),
            banner.heightAnchor.constraint(greaterThanOrEqualToConstant: 36)
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            banner.removeFromSuperview()
        }
    }
}
