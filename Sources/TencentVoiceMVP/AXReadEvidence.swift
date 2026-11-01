import ApplicationServices
import Foundation

struct AXReadEvidenceSample: Codable, Equatable, Sendable {
    let source: String
    let attribute: String
    let processID: Int32?
    let targetBound: Bool
    let sessionID: UUID?
    let operationID: Int?
    let targetGeneration: UInt64?
    let startedAtMonotonicNanoseconds: UInt64
    let endedAtMonotonicNanoseconds: UInt64
    let status: Int32

    init(
        source: String,
        attribute: String,
        processID: Int32?,
        targetBound: Bool,
        sessionID: UUID? = nil,
        operationID: Int? = nil,
        targetGeneration: UInt64? = nil,
        startedAtMonotonicNanoseconds: UInt64,
        endedAtMonotonicNanoseconds: UInt64,
        status: Int32
    ) {
        self.source = source
        self.attribute = attribute
        self.processID = processID
        self.targetBound = targetBound
        self.sessionID = sessionID
        self.operationID = operationID
        self.targetGeneration = targetGeneration
        self.startedAtMonotonicNanoseconds = startedAtMonotonicNanoseconds
        self.endedAtMonotonicNanoseconds = endedAtMonotonicNanoseconds
        self.status = status
    }

    var elapsedNanoseconds: UInt64 {
        endedAtMonotonicNanoseconds >= startedAtMonotonicNanoseconds
            ? endedAtMonotonicNanoseconds - startedAtMonotonicNanoseconds
            : 0
    }
}

struct AXReadEvidenceReport: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let enabled: Bool
    let permission: String
    let capturedAt: Date
    let windowStart: Date
    let retentionSeconds: Int
    let maxSampleCount: Int
    let sampleCount: Int
    let droppedSampleCount: Int
    let scope: String
    let samples: [AXReadEvidenceSample]

    static func disabled(at date: Date) -> Self {
        Self(
            schemaVersion: 1,
            enabled: false,
            permission: "existing_accessibility_permission",
            capturedAt: date,
            windowStart: date.addingTimeInterval(-60),
            retentionSeconds: 60,
            maxSampleCount: AXReadEvidenceCollector.maxSampleCount,
            sampleCount: 0,
            droppedSampleCount: 0,
            scope: "disabled; no AX values,正文、标题、地址或音频 retained",
            samples: []
        )
    }
}

final class AXReadEvidenceCollector: @unchecked Sendable {
    static let retentionSeconds = 60
    static let maxSampleCount = 16_384

    private let lock = NSLock()
    private var enabled = false
    private var samples: [AXReadEvidenceSample] = []
    private var droppedSampleCount = 0
    private var sessionID: UUID?
    private var targetProcessID: Int32?
    private var targetGeneration: UInt64 = 0

    @discardableResult
    func beginTarget(sessionID: UUID?, processID: Int32?) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let changed = self.sessionID != sessionID || targetProcessID != processID
        if changed {
            samples.removeAll(keepingCapacity: false)
            droppedSampleCount = 0
            targetGeneration &+= 1
        }
        self.sessionID = sessionID
        self.targetProcessID = processID
        return targetGeneration
    }

    func endTarget() {
        lock.lock()
        defer { lock.unlock() }
        sessionID = nil
        targetProcessID = nil
        samples.removeAll(keepingCapacity: false)
        droppedSampleCount = 0
        targetGeneration &+= 1
    }

    var currentTargetGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return targetGeneration
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.enabled = enabled
        if !enabled {
            samples.removeAll(keepingCapacity: false)
            droppedSampleCount = 0
            sessionID = nil
            targetProcessID = nil
            targetGeneration &+= 1
        }
    }

    func record(_ sample: AXReadEvidenceSample) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        guard let targetProcessID else {
            droppedSampleCount += 1
            return
        }
        if let processID = sample.processID, processID != targetProcessID {
            droppedSampleCount += 1
            return
        }
        if let sampleGeneration = sample.targetGeneration, sampleGeneration != targetGeneration {
            droppedSampleCount += 1
            return
        }
        let enrichedSample = AXReadEvidenceSample(
            source: sample.source,
            attribute: sample.attribute,
            processID: sample.processID ?? targetProcessID,
            targetBound: true,
            sessionID: sample.sessionID ?? sessionID,
            operationID: sample.operationID,
            targetGeneration: sample.targetGeneration ?? targetGeneration,
            startedAtMonotonicNanoseconds: sample.startedAtMonotonicNanoseconds,
            endedAtMonotonicNanoseconds: sample.endedAtMonotonicNanoseconds,
            status: sample.status
        )
        let now = DispatchTime.now().uptimeNanoseconds
        pruneExpired(now: now)
        samples.append(enrichedSample)
        if samples.count > Self.maxSampleCount {
            let overflow = samples.count - Self.maxSampleCount
            samples.removeFirst(overflow)
            droppedSampleCount += overflow
        }
    }

    func snapshot(at date: Date, permission: String) -> AXReadEvidenceReport {
        lock.lock()
        defer { lock.unlock() }
        let start = date.addingTimeInterval(-TimeInterval(Self.retentionSeconds))
        let now = DispatchTime.now().uptimeNanoseconds
        pruneExpired(now: now)
        return AXReadEvidenceReport(
            schemaVersion: 1,
            enabled: enabled,
            permission: permission,
            capturedAt: date,
            windowStart: start,
            retentionSeconds: Self.retentionSeconds,
            maxSampleCount: Self.maxSampleCount,
            sampleCount: samples.count,
            droppedSampleCount: droppedSampleCount,
            scope: "bound to sampled target process; input, periodic, operation and window_monitor sources; call source, attribute, timing, return code, session, operation and target generation only",
            samples: samples
        )
    }

    private func pruneExpired(now: UInt64) {
        guard !samples.isEmpty else { return }
        let retentionNanoseconds = UInt64(Self.retentionSeconds) * 1_000_000_000
        let cutoff = now > retentionNanoseconds ? now - retentionNanoseconds : 0
        guard let firstLiveIndex = samples.firstIndex(where: {
            $0.endedAtMonotonicNanoseconds >= cutoff
        }) else {
            samples.removeAll(keepingCapacity: false)
            return
        }
        guard firstLiveIndex > 0 else { return }
        samples.removeFirst(firstLiveIndex)
    }
}

final class AXReadEvidenceRuntime: @unchecked Sendable {
    static let shared = AXReadEvidenceRuntime()

    private let lock = NSLock()
    private var observer: (@Sendable (AXReadEvidenceSample) -> Void)?

    func setObserver(_ observer: (@Sendable (AXReadEvidenceSample) -> Void)?) {
        lock.lock()
        self.observer = observer
        lock.unlock()
    }

    func record(_ sample: AXReadEvidenceSample) {
        lock.lock()
        let observer = self.observer
        lock.unlock()
        observer?(sample)
    }

    static func sample(
        source: String,
        attribute: String,
        element: AXUIElement,
        startedAt: UInt64,
        status: AXError,
        targetBound: Bool = true,
        sessionID: UUID? = nil,
        operationID: Int? = nil,
        targetGeneration: UInt64? = nil
    ) -> AXReadEvidenceSample {
        var processID: pid_t = 0
        let pid = AXUIElementGetPid(element, &processID) == .success && processID != 0
            ? Int32(processID) : nil
        return AXReadEvidenceSample(
            source: source,
            attribute: attribute,
            processID: pid,
            targetBound: targetBound,
            sessionID: sessionID,
            operationID: operationID,
            targetGeneration: targetGeneration,
            startedAtMonotonicNanoseconds: startedAt,
            endedAtMonotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            status: status.rawValue
        )
    }
}
