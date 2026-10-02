import Foundation

/// Counters only: no PCM or recognized text is retained here.
/// Capture runs on the audio queue; upload and recognition run asynchronously.
final class AudioPipelineProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedChunks = 0
    private var uploadedChunks = 0
    private var capturedBytes = 0
    private var uploadedBytes = 0
    private var recognitionUpdates = 0
    private var lastCapture: UInt64?
    private var lastUpload: UInt64?
    private var lastRecognitionUpdate: UInt64?

    func captured(byteCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        capturedChunks += 1
        capturedBytes += byteCount
        lastCapture = DispatchTime.now().uptimeNanoseconds
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
