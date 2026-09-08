import AVFoundation
import AudioCaptureSupport
import Foundation

struct AudioCaptureFormat: Equatable, Sendable {
    let sampleRate: Double
    let channelCount: UInt32

    init(sampleRate: Double, channelCount: UInt32) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    init(_ format: AVAudioFormat) {
        self.init(sampleRate: format.sampleRate, channelCount: format.channelCount)
    }

    var isValid: Bool {
        sampleRate.isFinite && sampleRate > 0 && channelCount > 0
    }

    var metadata: [String: String] {
        [
            "sample_rate": String(format: "%.0f", sampleRate),
            "channels": String(channelCount)
        ]
    }
}

enum AudioCaptureError: Error, LocalizedError, @unchecked Sendable {
    case inputUnavailable
    case converterUnavailable
    case invalidInputFormat(AudioCaptureFormat)
    case tapInstallationFailed(String)
    case engineStartFailed(Error)
    case conversionFailed
    case recoveryTimedOut

    var errorDescription: String? {
        switch self {
        case .inputUnavailable: return "没有可用的麦克风输入"
        case .converterUnavailable: return "无法把麦克风转换为 16 kHz PCM"
        case .invalidInputFormat: return "麦克风音频格式暂时不可用"
        case .tapInstallationFailed: return "麦克风音频采集安装失败"
        case let .engineStartFailed(error): return "麦克风启动失败：\(error.localizedDescription)"
        case .conversionFailed: return "麦克风音频转换失败"
        case .recoveryTimedOut: return "麦克风设备切换后未能恢复"
        }
    }

    var diagnosticCode: String {
        switch self {
        case .inputUnavailable: return "microphone_input_unavailable"
        case .converterUnavailable: return "microphone_converter_unavailable"
        case .invalidInputFormat: return "microphone_invalid_input_format"
        case .tapInstallationFailed: return "microphone_tap_installation_failed"
        case .engineStartFailed: return "microphone_engine_start_failed"
        case .conversionFailed: return "microphone_conversion_failed"
        case .recoveryTimedOut: return "microphone_recovery_timed_out"
        }
    }
}

struct AudioCaptureEvent: @unchecked Sendable {
    enum Kind: @unchecked Sendable {
        case interrupted(previousFormat: AudioCaptureFormat?)
        case recovering(attempt: Int)
        case recovered(format: AudioCaptureFormat, durationNanoseconds: UInt64)
        case failed(AudioCaptureError)
    }

    let sessionID: UUID
    let kind: Kind
}

protocol AudioCapture: AnyObject {
    func start(
        sessionID: UUID,
        onChunk: @escaping @Sendable (Data) -> Void,
        onEvent: @escaping @Sendable (AudioCaptureEvent) -> Void
    ) async throws
    func stop()
}

protocol AudioEngineAdapter: AnyObject {
    var isRunning: Bool { get }
    var inputFormat: AVAudioFormat { get }
    var onConfigurationChange: (() -> Void)? { get set }
    func installTap(
        format: AVAudioFormat?,
        bufferSize: AVAudioFrameCount,
        handler: @escaping (AVAudioPCMBuffer) -> Void
    ) throws
    func removeTap()
    func prepare()
    func start() throws
    func stop()
}

private final class SystemAudioEngineAdapter: AudioEngineAdapter {
    var isRunning: Bool { engine.isRunning }
    private let engine: AVAudioEngine
    private var configurationObserver: NSObjectProtocol?
    private var tapInstalled = false

    var onConfigurationChange: (() -> Void)?

    init() {
        let engine = AVAudioEngine()
        self.engine = engine
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    var inputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    func installTap(
        format: AVAudioFormat?,
        bufferSize: AVAudioFrameCount,
        handler: @escaping (AVAudioPCMBuffer) -> Void
    ) throws {
        var error: NSError?
        let installed = RimeAudioInstallInputTap(
            engine.inputNode,
            bufferSize,
            format,
            { buffer, _ in handler(buffer) },
            &error
        )
        guard installed else {
            throw AudioCaptureError.tapInstallationFailed(
                error?.localizedDescription ?? "unknown tap installation error"
            )
        }
        tapInstalled = true
    }

    func removeTap() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    func prepare() {
        engine.prepare()
    }

    func start() throws {
        try engine.start()
    }

    func stop() {
        engine.stop()
    }
}

protocol AudioRecoverySchedule: AnyObject {
    func cancel()
}

protocol AudioRecoveryScheduler: AnyObject {
    func nowNanoseconds() -> UInt64
    @discardableResult
    func schedule(
        afterNanoseconds: UInt64,
        _ operation: @escaping @Sendable () -> Void
    ) -> AudioRecoverySchedule
}

private final class DispatchRecoverySchedule: AudioRecoverySchedule {
    private let workItem: DispatchWorkItem

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}

private final class DispatchAudioRecoveryScheduler: AudioRecoveryScheduler {
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    @discardableResult
    func schedule(
        afterNanoseconds: UInt64,
        _ operation: @escaping @Sendable () -> Void
    ) -> AudioRecoverySchedule {
        let workItem = DispatchWorkItem(block: operation)
        let delay = DispatchTimeInterval.nanoseconds(Int(min(afterNanoseconds, UInt64(Int.max))))
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
        return DispatchRecoverySchedule(workItem: workItem)
    }
}

final class SystemAudioCapture: AudioCapture, @unchecked Sendable {
    private enum Phase {
        case idle
        case starting
        case running
        case recovering
    }

    private let engineFactory: () -> AudioEngineAdapter
    private let queue = DispatchQueue(label: "local.tencent-voice-mvp.audio")
    private let scheduler: AudioRecoveryScheduler
    private let outputFormat: AVAudioFormat
    private let recoveryRetryNanoseconds: UInt64
    private let recoveryTimeoutNanoseconds: UInt64

    private var engine: AudioEngineAdapter?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AudioCaptureFormat?
    private var chunker = PCMChunker()
    private var onChunk: (@Sendable (Data) -> Void)?
    private var onEvent: (@Sendable (AudioCaptureEvent) -> Void)?
    private var sessionID: UUID?
    private var generation: UInt64 = 0
    private var phase: Phase = .idle
    private var currentInputFormat: AudioCaptureFormat?
    private var recoveryStartedAt: UInt64?
    private var recoveryDeadline: UInt64?
    private var recoveryAttempt = 0
    private var recoverySchedule: AudioRecoverySchedule?
    private var recoveryScheduleID = UUID()

    init(
        engineFactory: @escaping () -> AudioEngineAdapter = { SystemAudioEngineAdapter() },
        scheduler: AudioRecoveryScheduler? = nil,
        recoveryRetryNanoseconds: UInt64 = 250_000_000,
        recoveryTimeoutNanoseconds: UInt64 = 3_000_000_000
    ) {
        self.engineFactory = engineFactory
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
        self.recoveryRetryNanoseconds = recoveryRetryNanoseconds
        self.recoveryTimeoutNanoseconds = recoveryTimeoutNanoseconds
        if let scheduler {
            self.scheduler = scheduler
        } else {
            self.scheduler = DispatchAudioRecoveryScheduler(queue: queue)
        }
    }

    func start(
        sessionID: UUID,
        onChunk: @escaping @Sendable (Data) -> Void,
        onEvent: @escaping @Sendable (AudioCaptureEvent) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.phase == .idle else {
                    continuation.resume()
                    return
                }
                self.sessionID = sessionID
                self.onChunk = onChunk
                self.onEvent = onEvent
                self.generation &+= 1
                do {
                    try self.installAndStart(generation: self.generation, recovering: false)
                    continuation.resume()
                } catch {
                    self.stopSynchronously(flush: false)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.sync {
            self.stopSynchronously(flush: true)
        }
    }

    private func installAndStart(generation: UInt64, recovering: Bool) throws {
        let newEngine = engineFactory()
        let inputFormat = AudioCaptureFormat(newEngine.inputFormat)
        guard inputFormat.isValid else {
            throw AudioCaptureError.invalidInputFormat(inputFormat)
        }

        engine = newEngine
        phase = .starting
        newEngine.onConfigurationChange = { [weak self, weak newEngine] in
            guard let self, let newEngine else { return }
            self.queue.async {
                guard self.generation == generation, self.engine === newEngine else { return }
                self.handleConfigurationChange()
            }
        }
        try newEngine.installTap(format: nil, bufferSize: 4096) { [weak self] buffer in
            guard let self else { return }
            guard let copiedBuffer = Self.copyBuffer(buffer) else { return }
            self.queue.async {
                guard self.generation == generation else { return }
                self.convertAndEmit(copiedBuffer, generation: generation)
            }
        }
        newEngine.prepare()
        do {
            try newEngine.start()
        } catch {
            newEngine.removeTap()
            newEngine.stop()
            throw AudioCaptureError.engineStartFailed(error)
        }

        engine = newEngine
        currentInputFormat = inputFormat
        converter = nil
        converterInputFormat = nil
        phase = recovering ? .recovering : .running
    }

    private func handleConfigurationChange() {
        guard phase != .idle else { return }
        // Delayed/duplicate notifications are not evidence of an interruption.
        if let engine, engine.isRunning,
           AudioCaptureFormat(engine.inputFormat) == currentInputFormat { return }
        generation &+= 1
        if phase == .recovering {
            tearDownEngine(flush: true)
            scheduleRecoveryAttempt(afterNanoseconds: recoveryRetryNanoseconds)
            return
        }

        let previousFormat = currentInputFormat
        phase = .recovering
        recoveryStartedAt = scheduler.nowNanoseconds()
        recoveryDeadline = recoveryStartedAt.map { $0 + recoveryTimeoutNanoseconds }
        recoveryAttempt = 0
        emit(.interrupted(previousFormat: previousFormat))
        tearDownEngine(flush: true)
        scheduleRecoveryAttempt(afterNanoseconds: 0)
    }

    private func scheduleRecoveryAttempt(afterNanoseconds delay: UInt64) {
        recoverySchedule?.cancel()
        let scheduleID = UUID()
        recoveryScheduleID = scheduleID
        let scheduledGeneration = generation
        let now = scheduler.nowNanoseconds()
        let remaining = recoveryDeadline.map { $0 > now ? $0 - now : 0 } ?? 0
        recoverySchedule = scheduler.schedule(afterNanoseconds: min(delay, remaining)) { [weak self] in
            self?.queue.async {
                guard let self, self.recoveryScheduleID == scheduleID,
                      self.generation == scheduledGeneration else { return }
                self.attemptRecovery()
            }
        }
    }

    private func attemptRecovery() {
        guard phase == .recovering else { return }
        let now = scheduler.nowNanoseconds()
        guard let deadline = recoveryDeadline, now < deadline else {
            failRecovery(with: .recoveryTimedOut)
            return
        }

        // A started engine gets the remaining recovery window to deliver audio.
        // Retrying its start every 250 ms can prevent Bluetooth from settling.
        if engine?.isRunning == true {
            scheduleRecoveryAttempt(afterNanoseconds: deadline - now)
            return
        }

        recoveryAttempt += 1
        emit(.recovering(attempt: recoveryAttempt))
        generation &+= 1
        tearDownEngine(flush: false)
        let attemptGeneration = generation
        do {
            try installAndStart(generation: attemptGeneration, recovering: true)
            let completedAt = scheduler.nowNanoseconds()
            scheduleRecoveryAttempt(afterNanoseconds: deadline > completedAt ? deadline - completedAt : 0)
        } catch {
            tearDownEngine(flush: false)
            phase = .recovering
            let completedAt = scheduler.nowNanoseconds()
            let remaining = deadline > completedAt ? deadline - completedAt : 0
            if remaining == 0 {
                failRecovery(with: .recoveryTimedOut)
            } else {
                scheduleRecoveryAttempt(afterNanoseconds: min(recoveryRetryNanoseconds, remaining))
            }
        }
    }

    private func convertAndEmit(_ inputBuffer: AVAudioPCMBuffer, generation: UInt64) {
        guard self.generation == generation, phase != .idle, inputBuffer.frameLength > 0 else { return }
        if phase == .recovering, let deadline = recoveryDeadline,
           scheduler.nowNanoseconds() >= deadline {
            failRecovery(with: .recoveryTimedOut)
            return
        }
        let inputFormat = AudioCaptureFormat(inputBuffer.format)
        guard inputFormat.isValid else {
            if phase == .recovering {
                failRecovery(with: .invalidInputFormat(inputFormat))
            } else {
                handleConfigurationChange()
            }
            return
        }

        if converterInputFormat != inputFormat {
            guard let newConverter = AVAudioConverter(from: inputBuffer.format, to: outputFormat) else {
                failRecovery(with: .converterUnavailable)
                return
            }
            converter = newConverter
            converterInputFormat = inputFormat
        }
        guard let converter else { return }
        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(max(1, ceil(Double(inputBuffer.frameLength) * ratio)))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            failRecovery(with: .conversionFailed)
            return
        }

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
              outputBuffer.frameLength > 0,
              let samples = outputBuffer.int16ChannelData?[0] else {
            failRecovery(with: .conversionFailed)
            return
        }

        if phase == .recovering {
            phase = .running
            recoverySchedule?.cancel()
            recoverySchedule = nil
            let duration = recoveryStartedAt.map { scheduler.nowNanoseconds() - $0 } ?? 0
            emit(.recovered(format: inputFormat, durationNanoseconds: duration))
        }

        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        let data = Data(bytes: samples, count: byteCount)
        for chunk in chunker.append(data) {
            onChunk?(chunk)
        }
    }

    private func failRecovery(with error: AudioCaptureError) {
        guard phase != .idle else { return }
        generation &+= 1
        recoverySchedule?.cancel()
        recoverySchedule = nil
        tearDownEngine(flush: true)
        phase = .idle
        emit(.failed(error))
        onChunk = nil
        onEvent = nil
        sessionID = nil
    }

    private func tearDownEngine(flush: Bool) {
        engine?.removeTap()
        engine?.stop()
        engine = nil
        converter = nil
        converterInputFormat = nil
        currentInputFormat = nil
        if flush, let remainder = chunker.flush() {
            onChunk?(remainder)
        }
    }

    private func stopSynchronously(flush: Bool) {
        generation &+= 1
        recoverySchedule?.cancel()
        recoverySchedule = nil
        tearDownEngine(flush: flush)
        phase = .idle
        onChunk = nil
        onEvent = nil
        sessionID = nil
        recoveryStartedAt = nil
        recoveryDeadline = nil
        recoveryAttempt = 0
    }

    private func emit(_ kind: AudioCaptureEvent.Kind) {
        guard let sessionID else { return }
        onEvent?(AudioCaptureEvent(sessionID: sessionID, kind: kind))
    }

    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(
                pcmFormat: buffer.format,
                frameCapacity: buffer.frameLength
              ) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in source.indices {
            let sourceBuffer = source[index]
            var destinationBuffer = destination[index]
            guard sourceBuffer.mDataByteSize <= destinationBuffer.mDataByteSize else { return nil }
            guard sourceBuffer.mData != nil, destinationBuffer.mData != nil else { return nil }
            memcpy(
                destinationBuffer.mData!,
                sourceBuffer.mData!,
                Int(sourceBuffer.mDataByteSize)
            )
            destinationBuffer.mDataByteSize = sourceBuffer.mDataByteSize
            destination[index] = destinationBuffer
        }
        return copy
    }
}
