import Foundation

enum ASRSegmentPhase: String, Equatable, Sendable {
    case started
    case partial
    case final
}

struct ASRSlice: Equatable, Sendable {
    let sequence: Int
    let text: String
    let phase: ASRSegmentPhase
    let sliceType: Int
    let wireFinal: Bool

    var isFinal: Bool { phase == .final }
    var isSegmentStart: Bool { phase == .started }

    init(
        sequence: Int,
        text: String,
        isFinal: Bool,
        isSegmentStart: Bool = false,
        sliceType: Int? = nil,
        wireFinal: Bool = false
    ) {
        self.sequence = sequence
        self.text = text
        self.phase = isFinal ? .final : (isSegmentStart ? .started : .partial)
        self.sliceType = sliceType ?? (isFinal ? 2 : (isSegmentStart ? 0 : 1))
        self.wireFinal = wireFinal
    }
}

struct ASRUpdate: Equatable, Sendable {
    let segmentID: Int
    let segmentOrder: Int
    let sequence: Int
    let segmentText: String
    let phase: ASRSegmentPhase
    let isNewSegment: Bool
    let sliceType: Int?
    let wireFinal: Bool
    let isStreamEnded: Bool

    var text: String { segmentText }
    var isFinal: Bool { phase == .final }

    init(
        segmentID: Int,
        segmentOrder: Int,
        sequence: Int,
        segmentText: String,
        phase: ASRSegmentPhase,
        isNewSegment: Bool = false,
        sliceType: Int? = nil,
        wireFinal: Bool = false,
        isStreamEnded: Bool = false
    ) {
        self.segmentID = segmentID
        self.segmentOrder = segmentOrder
        self.sequence = sequence
        self.segmentText = segmentText
        self.phase = phase
        self.isNewSegment = isNewSegment
        self.sliceType = sliceType
        self.wireFinal = wireFinal
        self.isStreamEnded = isStreamEnded
    }

    init(
        text: String,
        isFinal: Bool,
        sequence: Int,
        stablePrefixLength: Int = 0,
        segmentText: String? = nil,
        isNewSegment: Bool = false,
        isStreamEnded: Bool = false
    ) {
        self.segmentID = sequence
        self.segmentOrder = sequence
        self.sequence = sequence
        self.segmentText = segmentText ?? text
        self.phase = isFinal ? .final : (isNewSegment ? .started : .partial)
        self.isNewSegment = isNewSegment
        self.sliceType = isFinal ? 2 : (isNewSegment ? 0 : 1)
        self.wireFinal = false
        self.isStreamEnded = isStreamEnded
    }

    static let streamEnded = ASRUpdate(
        segmentID: -1,
        segmentOrder: -1,
        sequence: -1,
        segmentText: "",
        phase: .partial,
        isNewSegment: false,
        isStreamEnded: true
    )
}

struct ASRProjection: Equatable, Sendable {
    let committedText: String
    let activeSegmentText: String
    let activeSegmentID: Int?
    let activeIsFinal: Bool
    let revision: UInt64
    let changed: Bool
    let isFinal: Bool
    let isStreamEnded: Bool

    var text: String { committedText + activeSegmentText }
    var segmentText: String? { activeSegmentID == nil ? nil : activeSegmentText }
    var stablePrefixLength: Int { committedText.count }

    init(
        committedText: String,
        activeSegmentText: String,
        activeSegmentID: Int?,
        activeIsFinal: Bool,
        revision: UInt64,
        changed: Bool,
        isFinal: Bool,
        isStreamEnded: Bool = false
    ) {
        self.committedText = committedText
        self.activeSegmentText = activeSegmentText
        self.activeSegmentID = activeSegmentID
        self.activeIsFinal = activeIsFinal
        self.revision = revision
        self.changed = changed
        self.isFinal = isFinal
        self.isStreamEnded = isStreamEnded
    }
}
