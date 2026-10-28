import Foundation
import XCTest
@testable import TencentVoiceMVP

final class AudioPipelineProgressTests: XCTestCase {
    func testCapturedPCMCountsDurationAndLevelObservationStoresOnlyNumbers() {
        let progress = AudioPipelineProgress()
        let pcm = makePCM(samples: Array(repeating: Int16(16_384), count: 1_600))

        progress.captured(pcm: pcm)
        progress.observed(level: AudioCaptureLevel(
            rms: 0.5,
            durationSeconds: 0.1,
            timestampUptimeNanoseconds: 123
        ))

        let snapshot = progress.captureMetrics()
        XCTAssertEqual(snapshot.durationSeconds, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.latestRMS, 0.5, accuracy: 0.000_01)
        XCTAssertEqual(snapshot.sampleSequence, 1)
        XCTAssertEqual(snapshot.latestLevelDurationSeconds, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.latestLevelAtUptimeNanoseconds, 123)
        XCTAssertEqual(progress.metadata()["capturedDurationMilliseconds"], "100")
    }

    func testMeterKeepsOnlyLatestLevelAndResetPreservesDuration() {
        let progress = AudioPipelineProgress()
        for amplitude in [Int16(0), 4_000, 8_000, 12_000, 16_000, 20_000] {
            progress.captured(pcm: makePCM(samples: Array(repeating: amplitude, count: 1_600)))
            progress.observed(level: AudioCaptureLevel(
                rms: Double(amplitude) / 32_768,
                durationSeconds: 0.1,
                timestampUptimeNanoseconds: UInt64(progress.captureMetrics().sampleSequence + 1)
            ))
        }

        let beforeReset = progress.captureMetrics()
        XCTAssertEqual(beforeReset.sampleSequence, 6)
        XCTAssertEqual(beforeReset.latestRMS, 20_000.0 / 32_768, accuracy: 0.000_01)

        progress.resetWaveformWindow()

        let afterReset = progress.captureMetrics()
        XCTAssertEqual(afterReset.durationSeconds, beforeReset.durationSeconds)
        XCTAssertEqual(afterReset.sampleSequence, beforeReset.sampleSequence + 1)
        XCTAssertEqual(afterReset.latestRMS, 0)
        XCTAssertNil(afterReset.latestLevelAtUptimeNanoseconds)
    }

    private func makePCM(samples: [Int16]) -> Data {
        var bytes = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let value = UInt16(bitPattern: sample)
            bytes.append(UInt8(truncatingIfNeeded: value))
            bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        return bytes
    }
}
