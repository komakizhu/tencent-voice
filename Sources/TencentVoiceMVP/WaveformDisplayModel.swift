import Foundation

enum RecordingDurationFormatter {
    static func string(from duration: Double) -> String {
        let seconds = max(0, Int(duration))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

enum StatusButtonImageStyle: Equatable {
    case application
    case symbol(String)
    case waveform
    case none
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
        let detail: String
        switch state {
        case .idle: detail = "已就绪"
        case .connecting: detail = "正在连接语音识别"
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

        switch mode {
        case .timer:
            switch state {
            case .idle, .error:
                return Self(
                    title: "",
                    imageStyle: .application,
                    toolTip: failureText.map { "Rime Voice · \($0)" } ?? "Rime Voice · \(detail)",
                    accessibilityLabel: failureText.map { "Rime Voice，\($0)" } ?? "Rime Voice，\(detail)"
                )
            case .connecting, .listening, .recovering, .stopping:
                return Self(
                    title: time,
                    imageStyle: .none,
                    toolTip: "\(detail) · 已录 \(time)",
                    accessibilityLabel: "\(detail)，已录 \(time)"
                )
            }
        case .icon:
            let activelyCapturing = isCapturing && {
                switch state {
                case .connecting, .listening, .recovering, .stopping: return true
                case .idle, .error: return false
                }
            }()
            return Self(
                title: "",
                imageStyle: activelyCapturing ? .symbol("record.circle.fill") : .application,
                toolTip: failureText.map { "Rime Voice · \($0)" } ?? "Rime Voice · \(detail)",
                accessibilityLabel: "Rime Voice，\(failureText ?? detail)"
            )
        case .waveform:
            let style: StatusButtonImageStyle
            switch state {
            case .idle:
                style = statusFeedback == nil ? .application : .symbol("exclamationmark.triangle.fill")
            case .connecting:
                style = .symbol("mic.waiting")
            case .listening:
                style = isCapturing ? .waveform : .application
            case .recovering:
                style = .symbol("mic.slash.fill")
            case .stopping:
                style = .symbol("hourglass")
            case .error:
                style = .symbol("exclamationmark.triangle.fill")
            }
            let tooltip: String
            let label: String
            if case .listening = state, isCapturing {
                tooltip = "正在录音，波形显示麦克风输入音量"
                label = "正在录音，显示麦克风输入音量"
            } else if let failureText {
                tooltip = "Rime Voice · \(failureText)"
                label = "Rime Voice，\(failureText)"
            } else {
                tooltip = "Rime Voice · \(detail)"
                label = "Rime Voice，\(detail)"
            }
            return Self(title: "", imageStyle: style, toolTip: tooltip, accessibilityLabel: label)
        }
    }
}

/// Converts only numeric microphone levels into a single display envelope.
/// It never retains audio or a rolling history of past sound.
struct WaveformDisplayModel {
    static let openThreshold = 0.008
    static let closeThreshold = 0.006
    static let attackTimeConstant: TimeInterval = 0.020
    static let releaseTimeConstant: TimeInterval = 0.050
    static let silenceResetNanoseconds: UInt64 = 120_000_000
    static let staleMinimumNanoseconds: UInt64 = 300_000_000
    static let barWeights = [0.55, 0.8, 1.0, 0.8, 0.55]

    private(set) var amplitude = 0.0
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
        Self.barWeights.map { amplitude * $0 }
    }

    mutating func update(
        snapshot: RecordingDisplaySnapshot,
        now: UInt64
    ) -> [Double] {
        guard snapshot.state == .listening, snapshot.isCapturing else {
            reset()
            return barLevels
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
            amplitude = 0
        } else if let lastTickAt {
            let elapsed = Double(now >= lastTickAt ? now - lastTickAt : 0) / 1_000_000_000
            amplitude = Self.smoothedLevel(
                current: amplitude,
                target: targetAmplitude,
                elapsed: elapsed
            )
        }
        lastTickAt = now
        return barLevels
    }

    mutating func reset() {
        amplitude = 0
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
                gateClosedSince = timestamp
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
        amplitude = 0
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
        return sqrt(linear)
    }

    static func smoothedLevel(current: Double, target: Double, elapsed: TimeInterval) -> Double {
        let current = min(1, max(0, current))
        let target = min(1, max(0, target))
        let delta = min(0.25, max(0, elapsed))
        guard delta > 0 else { return current }
        let timeConstant = target > current ? attackTimeConstant : releaseTimeConstant
        return current + (target - current) * (1 - exp(-delta / timeConstant))
    }
}
