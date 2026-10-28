import Foundation

struct AudioCaptureMetricsSnapshot: Equatable, Sendable {
    let durationSeconds: Double
    let latestRMS: Double
    let sampleSequence: UInt64
    let latestLevelAtUptimeNanoseconds: UInt64?
    let latestLevelDurationSeconds: TimeInterval

    static let empty = Self(
        durationSeconds: 0,
        latestRMS: 0,
        sampleSequence: 0,
        latestLevelAtUptimeNanoseconds: nil,
        latestLevelDurationSeconds: 0
    )
}

struct RecordingDisplaySnapshot: Equatable, Sendable {
    let sessionID: UUID?
    let state: SessionState
    let audio: AudioCaptureMetricsSnapshot
    let isCapturing: Bool

    init(
        sessionID: UUID?,
        state: SessionState,
        audio: AudioCaptureMetricsSnapshot,
        isCapturing: Bool = false
    ) {
        self.sessionID = sessionID
        self.state = state
        self.audio = audio
        self.isCapturing = isCapturing
    }
}

/// Counters only: no PCM or recognized text is retained here.
/// Capture runs on the audio queue; upload and recognition run asynchronously.
final class AudioPipelineProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedChunks = 0
    private var uploadedChunks = 0
    private var capturedBytes = 0
    private var capturedSamples = 0
    private var isCapturing = false
    private var uploadedBytes = 0
    private var recognitionUpdates = 0
    private var lastCapture: UInt64?
    private var latestLevelAt: UInt64?
    private var latestRMS = 0.0
    private var latestLevelDuration = 0.0
    private var sampleSequence: UInt64 = 0
    private var lastUpload: UInt64?
    private var lastRecognitionUpdate: UInt64?

    func captured(byteCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        capturedChunks += 1
        capturedBytes += byteCount
        lastCapture = DispatchTime.now().uptimeNanoseconds
    }

    func captured(pcm: Data) {
        let sampleCount = pcm.count / MemoryLayout<Int16>.size
        lock.lock()
        defer { lock.unlock() }
        capturedChunks += 1
        capturedBytes += pcm.count
        capturedSamples += sampleCount
        lastCapture = DispatchTime.now().uptimeNanoseconds
    }

    func observed(level: AudioCaptureLevel) {
        lock.lock()
        defer { lock.unlock() }
        latestRMS = level.rms.isFinite ? max(0, level.rms) : 0
        latestLevelAt = level.timestampUptimeNanoseconds
        latestLevelDuration = max(0, level.durationSeconds)
        sampleSequence &+= 1
    }

    func setCapturing(_ isCapturing: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.isCapturing = isCapturing
    }

    func resetWaveformWindow() {
        lock.lock()
        defer { lock.unlock() }
        latestRMS = 0
        latestLevelAt = nil
        latestLevelDuration = 0
        sampleSequence &+= 1
    }

    func captureMetrics() -> AudioCaptureMetricsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return AudioCaptureMetricsSnapshot(
            durationSeconds: Double(capturedSamples) / 16_000,
            latestRMS: latestRMS,
            sampleSequence: sampleSequence,
            latestLevelAtUptimeNanoseconds: latestLevelAt,
            latestLevelDurationSeconds: latestLevelDuration
        )
    }

    func captureState() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCapturing
    }

    func uploaded(byteCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        uploadedChunks += 1
        uploadedBytes += byteCount
        lastUpload = DispatchTime.now().uptimeNanoseconds
    }

    func receivedRecognitionUpdate() {
        lock.lock()
        defer { lock.unlock() }
        recognitionUpdates += 1
        lastRecognitionUpdate = DispatchTime.now().uptimeNanoseconds
    }

    func metadata() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        func age(_ timestamp: UInt64?) -> String {
            timestamp.map { String((now - $0) / 1_000_000) } ?? "unknown"
        }
        // The stream is 16 kHz, mono, signed 16-bit PCM: 32 bytes per ms.
        return [
            "capturedChunkCount": String(capturedChunks),
            "uploadedChunkCount": String(uploadedChunks),
            "capturedDurationMilliseconds": String(capturedBytes / 32),
            "uploadedDurationMilliseconds": String(uploadedBytes / 32),
            "recognitionUpdateCount": String(recognitionUpdates),
            "lastCaptureAgeMilliseconds": age(lastCapture),
            "lastUploadAgeMilliseconds": age(lastUpload),
            "lastRecognitionUpdateAgeMilliseconds": age(lastRecognitionUpdate)
        ]
    }

}
