import AVFoundation
import Foundation

protocol AudioCapture: AnyObject {
    func start(onChunk: @escaping @Sendable (Data) -> Void) async throws
    func stop()
}

enum AudioCaptureError: Error, LocalizedError {
    case inputUnavailable
    case converterUnavailable
    case engineStartFailed(Error)

    var errorDescription: String? {
        switch self {
        case .inputUnavailable: return "没有可用的麦克风输入"
        case .converterUnavailable: return "无法把麦克风转换为 16 kHz PCM"
        case let .engineStartFailed(error): return "麦克风启动失败：\(error.localizedDescription)"
        }
    }

    var diagnosticCode: String {
        switch self {
        case .inputUnavailable: return "microphone_input_unavailable"
        case .converterUnavailable: return "microphone_converter_unavailable"
        case .engineStartFailed: return "microphone_engine_start_failed"
        }
    }
}

final class SystemAudioCapture: AudioCapture, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "local.tencent-voice-mvp.audio")
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var chunker = PCMChunker()
    private var onChunk: (@Sendable (Data) -> Void)?
    private var isRunning = false

    init() {
        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
    }

    func start(onChunk: @escaping @Sendable (Data) -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.startSynchronously(onChunk: onChunk)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.sync {
            guard self.isRunning else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            if let remainder = self.chunker.flush() {
                self.onChunk?(remainder)
            }
            self.onChunk = nil
            self.converter = nil
            self.isRunning = false
        }
    }

    private func startSynchronously(onChunk: @escaping @Sendable (Data) -> Void) throws {
        if isRunning { return }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            throw AudioCaptureError.inputUnavailable
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioCaptureError.converterUnavailable
        }
        self.converter = converter
        self.onChunk = onChunk
        self.chunker = PCMChunker()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.queue.async {
                self.convertAndEmit(buffer)
            }
        }

        engine.prepare()
        do {
            try engine.start()
            isRunning = true
        } catch {
            inputNode.removeTap(onBus: 0)
            self.onChunk = nil
            self.converter = nil
            throw AudioCaptureError.engineStartFailed(error)
        }
    }

    private func convertAndEmit(_ inputBuffer: AVAudioPCMBuffer) {
        guard let converter, inputBuffer.frameLength > 0 else { return }
        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(max(1, ceil(Double(inputBuffer.frameLength) * ratio)))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var conversionError: NSError?
        var supplied = false
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, conversionError == nil,
              let samples = outputBuffer.int16ChannelData?[0] else { return }
        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        let data = Data(bytes: samples, count: byteCount)
        for chunk in chunker.append(data) {
            onChunk?(chunk)
        }
    }
}
