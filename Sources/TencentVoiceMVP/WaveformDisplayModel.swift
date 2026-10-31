import Foundation

enum RecordingDurationFormatter {
    static func string(from duration: Double) -> String {
        let seconds = max(0, Int(duration))
        return "\(seconds)s"
    }
}

enum StatusButtonImageStyle: Equatable {
    case application
    case recording
    case timer
    case waveform
}

struct StatusButtonPresentation: Equatable {
    let title: String
    let imageStyle: StatusButtonImageStyle
    let toolTip: String
    let accessibilityLabel: String

    static func make(
        mode: MenuBarDisplayMode,
        state: SessionState,
        isCapturing: Bool,
        duration: Double,
        statusFeedback: String? = nil
    ) -> Self {
        let time = RecordingDurationFormatter.string(from: duration)
        let spokenTime = "\(max(0, Int(duration))) 秒"
        let activelyCapturing = isCapturing && {
            switch state {
            case .connecting, .listening, .recovering, .stopping: return true
            case .idle, .error: return false
            }
        }()
        let detail: String
        switch state {
        case .idle: detail = "已就绪"
        case .connecting: detail = isCapturing ? "正在连接语音识别" : "准备录音中"
        case .listening: detail = isCapturing ? "正在录音" : "录音已暂停"
        case .recovering: detail = "麦克风恢复中"
        case .stopping: detail = "语音收尾中"
        case let .error(message): detail = "发生错误：\(message)"
        }

        let failureText: String?
        if case let .error(message) = state {
            failureText = "错误：\(message)"
        } else {
            failureText = statusFeedback
        }

        // The menu bar has exactly two visual states. Finalization, recovery
        // and failures remain available in the tooltip without another icon.
        guard activelyCapturing else {
            return Self(
                title: "", imageStyle: .application,
                toolTip: "Rime Voice · \(failureText ?? detail)",
                accessibilityLabel: "Rime Voice，\(failureText ?? detail)"
            )
        }
        switch mode {
        case .timer:
            return Self(
                title: time, imageStyle: .timer,
                toolTip: "\(detail) · 已录 \(spokenTime)",
                accessibilityLabel: "\(detail)，已录 \(spokenTime)"
            )
        case .icon:
            return Self(
                title: "",
                imageStyle: .recording,
                toolTip: failureText.map { "Rime Voice · \($0)" } ?? "Rime Voice · \(detail)",
                accessibilityLabel: "Rime Voice，\(failureText ?? detail)"
            )
        case .waveform:
            return Self(
                title: "", imageStyle: .waveform,
                toolTip: "\(detail)，波形显示麦克风输入音量；静音时保留基线",
                accessibilityLabel: "\(detail)，显示麦克风输入音量"
            )
        }
    }
}

/// Converts numeric microphone levels into five fixed-position display envelopes.
/// It never retains audio or a rolling history of past sound.
struct WaveformDisplayModel {
    static let openThreshold = 0.004
    static let closeThreshold = 0.0025
    static let attackTimeConstant: TimeInterval = 0.018
    static let releaseTimeConstant: TimeInterval = 0.045
    static let silenceResetNanoseconds: UInt64 = 120_000_000
    static let staleMinimumNanoseconds: UInt64 = 300_000_000
    static let barWeights = [0.38, 0.74, 1.0, 0.74, 0.38]

    private var envelopes = Array(repeating: 0.0, count: 5)
    private var targetAmplitude = 0.0
    private var isGateOpen = false
    private var belowOpenSince: UInt64?
    private var gateClosedSince: UInt64?
    private var lastSampleAt: UInt64?
    private var latestBlockDuration: TimeInterval = 0
    private var lastSequence: UInt64?
    private var lastSessionID: UUID?
    private var lastTickAt: UInt64?

    var barLevels: [Double] {
        zip(envelopes, Self.barWeights).map { $0.0 * $0.1 }
    }

    mutating func update(
        snapshot: RecordingDisplaySnapshot,
        now: UInt64
    ) -> [Double] {
        guard snapshot.isCapturing else {
            reset()
            return barLevels
        }
        switch snapshot.state {
        case .idle, .error:
            reset()
            return barLevels
        case .connecting, .listening, .recovering, .stopping:
            break
        }
        if lastSessionID != snapshot.sessionID {
            reset()
            lastSessionID = snapshot.sessionID
        }

        let audio = snapshot.audio
        if lastSequence != audio.sampleSequence {
            lastSequence = audio.sampleSequence
            receiveLevel(
                rms: audio.latestRMS,
                blockDuration: audio.latestLevelDurationSeconds,
                timestamp: audio.latestLevelAtUptimeNanoseconds ?? now
            )
        }

        if let belowOpenSince,
           now >= belowOpenSince,
           now - belowOpenSince >= Self.silenceResetNanoseconds {
            isGateOpen = false
            targetAmplitude = 0
            gateClosedSince = belowOpenSince
        }

        if isStale(now: now) {
            clearEnvelope()
            lastTickAt = now
            return barLevels
        }

        if let gateClosedSince,
           now >= gateClosedSince,
           now - gateClosedSince >= Self.silenceResetNanoseconds {
            envelopes = Array(repeating: 0, count: 5)
        } else if let lastTickAt {
            let elapsed = Double(now >= lastTickAt ? now - lastTickAt : 0) / 1_000_000_000
            for index in envelopes.indices {
                // The outer bars follow the same current input more gently;
                // these are smoothing states, not a rolling audio history.
                envelopes[index] = Self.smoothedLevel(
                    current: envelopes[index],
                    target: targetAmplitude,
                    elapsed: elapsed,
                    responseScale: 1 + Double(abs(index - 2)) * 0.22
                )
            }
        } else {
            // The first microphone sample is already measured. Show it on this
            // frame instead of waiting for another display refresh to attack.
            envelopes = Array(repeating: targetAmplitude, count: 5)
        }
        lastTickAt = now
        return barLevels
    }

    mutating func reset() {
        envelopes = Array(repeating: 0, count: 5)
        targetAmplitude = 0
        isGateOpen = false
        belowOpenSince = nil
        gateClosedSince = nil
        lastSampleAt = nil
        latestBlockDuration = 0
        lastSequence = nil
        lastSessionID = nil
        lastTickAt = nil
    }

    private mutating func receiveLevel(rms: Double, blockDuration: TimeInterval, timestamp: UInt64) {
        lastSampleAt = timestamp
        latestBlockDuration = max(0, blockDuration)
        guard rms.isFinite else {
            isGateOpen = false
            belowOpenSince = timestamp
            gateClosedSince = timestamp
            targetAmplitude = 0
            return
        }

        let level = max(0, rms)
        if level >= Self.openThreshold {
            isGateOpen = true
            belowOpenSince = nil
            gateClosedSince = nil
            targetAmplitude = Self.amplitude(forRMS: level)
        } else {
            if level <= Self.closeThreshold {
                isGateOpen = false
                belowOpenSince = nil
                gateClosedSince = gateClosedSince ?? timestamp
            } else if isGateOpen {
                belowOpenSince = belowOpenSince ?? timestamp
            }
            // The hysteresis gate may stay open briefly, while the displayed
            // envelope releases as soon as the signal falls below its opening
            // threshold.
            targetAmplitude = 0
        }
    }

    private mutating func clearEnvelope() {
        envelopes = Array(repeating: 0, count: 5)
        targetAmplitude = 0
        isGateOpen = false
        belowOpenSince = nil
        gateClosedSince = nil
    }

    private func isStale(now: UInt64) -> Bool {
        guard let lastSampleAt else { return true }
        let blockNanoseconds = UInt64(max(0, latestBlockDuration) * 1_000_000_000)
        let doubledBlock = blockNanoseconds.multipliedReportingOverflow(by: 2)
        let blockTimeout = doubledBlock.overflow ? UInt64.max : doubledBlock.partialValue
        let timeout = max(Self.staleMinimumNanoseconds, blockTimeout)
        return now >= lastSampleAt && now - lastSampleAt > timeout
    }

    static func amplitude(forRMS rms: Double) -> Double {
        guard rms.isFinite, rms >= openThreshold else { return 0 }
        let floorDB = 20 * log10(closeThreshold)
        let ceilingDB = -18.0
        let decibels = 20 * log10(min(1, max(closeThreshold, rms)))
        let linear = min(1, max(0, (decibels - floorDB) / (ceilingDB - floorDB)))
        return pow(linear, 0.52)
    }

    static func smoothedLevel(current: Double, target: Double, elapsed: TimeInterval, responseScale: Double = 1) -> Double {
        let current = min(1, max(0, current))
        let target = min(1, max(0, target))
        let delta = min(0.25, max(0, elapsed))
        guard delta > 0 else { return current }
        let timeConstant = (target > current ? attackTimeConstant : releaseTimeConstant) * responseScale
        return current + (target - current) * (1 - exp(-delta / timeConstant))
    }
}
