import AVFoundation
import Foundation

@_silgen_name("openless_ios_audio_pcm")
private func openlessIOSAudioPCM(_ bytes: UnsafePointer<UInt8>, _ length: Int)

/// Adds microphone capture to the AVAudioEngine that already owns OpenLess'
/// background keep-alive graph. iOS only permits one active RemoteIO graph per
/// process, so the keyboard bridge must not create a second CPAL/CoreAudio
/// input stream while the keep-alive engine is running.
final class OpenLessNativeAudioCapture: @unchecked Sendable {
    private let engine: AVAudioEngine
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var tapInstalled = false
    private var forwardingPCM = false

    init(engine: AVAudioEngine) {
        self.engine = engine
    }

    var isArmed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tapInstalled
    }

    var isCapturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tapInstalled && forwardingPCM
    }

    /// Arm the input graph while the host app is in the foreground. iOS may
    /// reject creation of a new recording input after the app has already
    /// moved to the background, so the tap is installed once here and kept
    /// alive. Keyboard presses later only toggle PCM forwarding.
    func arm() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !tapInstalled else { return }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noInput
        }
        guard let speechFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: speechFormat) else {
            throw CaptureError.converterUnavailable
        }

        self.converter = converter
        outputFormat = speechFormat
        forwardingPCM = false
        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        tapInstalled = true
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard tapInstalled else { throw CaptureError.notArmed }
        forwardingPCM = true
    }

    func stop() {
        lock.lock()
        forwardingPCM = false
        lock.unlock()
    }

    func disarm() {
        lock.lock()
        guard tapInstalled else {
            forwardingPCM = false
            lock.unlock()
            return
        }
        forwardingPCM = false
        tapInstalled = false
        lock.unlock()

        engine.inputNode.removeTap(onBus: 0)

        lock.lock()
        converter = nil
        outputFormat = nil
        lock.unlock()
    }

    private func consume(_ input: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard tapInstalled,
              forwardingPCM,
              let converter,
              let outputFormat else { return }

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = max(
            AVAudioFrameCount(256),
            AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 64
        )
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else { return }

        var suppliedInput = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            if suppliedInput {
                status.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return input
        }

        guard conversionError == nil,
              converted.frameLength > 0,
              let samples = converted.int16ChannelData?.pointee else { return }

        let byteCount = Int(converted.frameLength) * MemoryLayout<Int16>.size
        let bytes = UnsafeRawPointer(samples).assumingMemoryBound(to: UInt8.self)
        openlessIOSAudioPCM(bytes, byteCount)
    }

    enum CaptureError: LocalizedError {
        case noInput
        case converterUnavailable
        case notArmed

        var errorDescription: String? {
            switch self {
            case .noInput:
                return "OpenLess could not access the microphone input."
            case .converterUnavailable:
                return "OpenLess could not prepare 16 kHz speech audio."
            case .notArmed:
                return "OpenLess microphone input is not armed. Open the main app once before using the keyboard."
            }
        }
    }
}
