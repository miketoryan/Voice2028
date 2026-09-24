import AVFoundation
import Foundation

final class AudioService: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var keepAlivePlayer: AVAudioPlayer?
    private var outputFile: AVAudioFile?
    private var captureConverter: AVAudioConverter?
    private var captureOutputFormat: AVAudioFormat?
    private var currentURL: URL?
    private var tapInstalled = false
    private var audioSessionIsActive = false
    private var captureIsActive = false

    private(set) var isArmed = false

    var isRunning: Bool {
        isArmed && engine.isRunning
    }

    var isKeepingAlive: Bool {
        keepAlivePlayer?.isPlaying == true
    }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func arm() throws {
        guard !isRunning else { return }

        stopKeepAlive()

        let session = AVAudioSession.sharedInstance()
        // Keep one stable, mixable play-and-record category across standby and
        // capture. Only the input engine changes state, which keeps the privacy
        // indicator tied to an actual recording attempt.
        try prepareCaptureSession(session)

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioError.noInput
        }

        if !tapInstalled {
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.consume(buffer)
            }
            tapInstalled = true
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            audioSessionIsActive = false
            throw error
        }
        isArmed = true
    }

    func enterStandby() throws {
        stopCaptureEngine()

        let session = AVAudioSession.sharedInstance()
        // Keep the already-authorized play-and-record session active while
        // only playing silence. The input engine is stopped, so the privacy
        // indicator turns off, but the app can resume input from the keyboard
        // without changing audio categories in the background.
        try prepareCaptureSession(session)

        if keepAlivePlayer == nil {
            let player = try AVAudioPlayer(data: Self.silentWAVData)
            player.numberOfLoops = -1
            player.volume = 1
            player.prepareToPlay()
            keepAlivePlayer = player
        }

        guard keepAlivePlayer?.play() == true else {
            throw AudioError.keepAliveFailed
        }
    }

    func beginCapture() throws -> URL {
        guard isArmed, engine.isRunning else { throw AudioError.notArmed }

        // AudioSession was configured before AVAudioEngine started.
        // Starting capture only creates the file; no category/options change
        // occurs here, matching the stable v0.4.2 lifecycle.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice2028-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioError.noInput
        }

        let speechFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )

        let file: AVAudioFile
        let converter: AVAudioConverter?
        let outputFormat: AVAudioFormat?

        if let speechFormat,
           let speechConverter = AVAudioConverter(
               from: inputFormat,
               to: speechFormat
           ) {
            file = try AVAudioFile(
                forWriting: url,
                settings: speechFormat.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: false
            )
            converter = speechConverter
            outputFormat = speechFormat
        } else {
            // Keep a safe fallback for unusual audio routes. Recognition still
            // works even if a device cannot create the 16 kHz speech converter.
            file = try AVAudioFile(
                forWriting: url,
                settings: inputFormat.settings
            )
            converter = nil
            outputFormat = nil
        }

        lock.lock()
        outputFile = file
        captureConverter = converter
        captureOutputFormat = outputFormat
        currentURL = url
        captureIsActive = true
        lock.unlock()

        return url
    }

    func endCapture() -> URL? {
        lock.lock()
        outputFile = nil
        captureConverter = nil
        captureOutputFormat = nil
        let url = currentURL
        currentURL = nil
        captureIsActive = false
        lock.unlock()

        // The input engine belongs to one capture only. Keeping the audio
        // session ready is handled by enterStandby(), which uses output-only
        // silent playback and does not hold the microphone open.
        stopCaptureEngine()
        return url
    }

    func disarm() {
        stopCaptureEngine()
        stopKeepAlive()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioSessionIsActive = false
    }

    func suspendStandbyForInterruption() {
        guard !hasActiveCapture() else { return }
        stopCaptureEngine()
        stopKeepAlive()
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        audioSessionIsActive = false
    }

    func resetAfterMediaServicesReset() {
        stopCaptureEngine()
        stopKeepAlive()
        engine = AVAudioEngine()
        keepAlivePlayer = nil
        audioSessionIsActive = false
    }

    private func hasActiveCapture() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return captureIsActive
    }

    private func prepareCaptureSession(_ session: AVAudioSession) throws {
        let options: AVAudioSession.CategoryOptions = [
            .mixWithOthers,
            .allowBluetoothHFP
        ]
        let categoryChanged =
            session.category != .playAndRecord
            || session.mode != .measurement
            || session.categoryOptions != options

        if categoryChanged {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: options
            )
        }
        if !audioSessionIsActive || categoryChanged {
            try session.setActive(true)
            audioSessionIsActive = true
        }
    }

    private func stopCaptureEngine() {
        lock.lock()
        outputFile = nil
        captureConverter = nil
        captureOutputFormat = nil
        currentURL = nil
        captureIsActive = false
        lock.unlock()

        if engine.isRunning {
            engine.stop()
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        isArmed = false
    }

    private func stopKeepAlive() {
        keepAlivePlayer?.stop()
        keepAlivePlayer?.currentTime = 0
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard let file = outputFile else { return }

        guard let converter = captureConverter,
              let outputFormat = captureOutputFormat else {
            try? file.write(from: buffer)
            return
        }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = max(
            AVAudioFrameCount(256),
            AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 64
        )
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else { return }

        var suppliedInput = false
        var conversionError: NSError?
        _ = converter.convert(
            to: converted,
            error: &conversionError
        ) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard conversionError == nil, converted.frameLength > 0 else { return }
        try? file.write(from: converted)
    }

    private static let silentWAVData: Data = {
        let sampleRate: UInt32 = 8_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let seconds: UInt32 = 1
        let bytesPerSample = UInt32(bitsPerSample / 8)
        let dataSize = sampleRate * UInt32(channels) * bytesPerSample * seconds
        let byteRate = sampleRate * UInt32(channels) * bytesPerSample
        let blockAlign = channels * (bitsPerSample / 8)

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }()

    enum AudioError: LocalizedError {
        case noInput
        case notArmed
        case keepAliveFailed

        var errorDescription: String? {
            switch self {
            case .noInput: "No microphone input is available."
            case .notArmed: "Start the Voice2028 keyboard service first."
            case .keepAliveFailed: "Voice2028 could not keep its background service active."
            }
        }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}

