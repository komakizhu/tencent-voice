import Foundation

final class ASRResultNormalizer: @unchecked Sendable {
    private struct Segment {
        let id: Int
        let sequence: Int
        let order: Int
        var text: String
        var phase: ASRSegmentPhase
        var stablePrefixText: String?
    }

    private var segments: [Int: Segment] = [:]
    private var activeSegmentBySequence: [Int: Int] = [:]
    private var nextSegmentID = 0
    private var sequenceReuseDetected = false

    func accept(_ slice: ASRSlice) -> ASRUpdate {
        let segmentID: Int
        let isNewSegment: Bool
        if let activeID = activeSegmentBySequence[slice.sequence],
           let activeSegment = segments[activeID],
           !shouldStartNewSegment(for: slice, after: activeSegment) {
            segmentID = activeID
            isNewSegment = false
        } else {
            segmentID = createSegment(for: slice)
            isNewSegment = true
        }

        segments[segmentID] = Segment(
            id: segmentID,
            sequence: slice.sequence,
            order: segments[segmentID]?.order ?? nextSegmentID,
            text: slice.text,
            phase: slice.phase,
            stablePrefixText: slice.stablePrefixText
        )
        activeSegmentBySequence[slice.sequence] = segmentID

        return ASRUpdate(
            segmentID: segmentID,
            segmentOrder: segments[segmentID]?.order ?? 0,
            sequence: slice.sequence,
            segmentText: segments[segmentID]?.text ?? slice.text,
            phase: segments[segmentID]?.phase ?? slice.phase,
            isNewSegment: isNewSegment,
            sliceType: slice.sliceType,
            wireFinal: slice.wireFinal,
            stablePrefixText: segments[segmentID]?.stablePrefixText
        )
    }

    private func shouldStartNewSegment(for slice: ASRSlice, after activeSegment: Segment) -> Bool {
        if slice.isSegmentStart && !activeSegment.text.isEmpty {
            return true
        }
        guard activeSegment.phase == .final else { return false }
        return !slice.isFinal || activeSegment.text != slice.text
    }

    private func createSegment(for slice: ASRSlice) -> Int {
        let segmentID = nextSegmentID
        nextSegmentID += 1
        let hasPreviousSegmentWithSequence = segments.values.contains { $0.sequence == slice.sequence }
        let shouldAppendAfterExistingSegments = sequenceReuseDetected || hasPreviousSegmentWithSequence
        if shouldAppendAfterExistingSegments {
            sequenceReuseDetected = true
        }
        let order = shouldAppendAfterExistingSegments
            ? (segments.values.map(\.order).max() ?? -1) + 1
            : slice.sequence
        segments[segmentID] = Segment(
            id: segmentID,
            sequence: slice.sequence,
            order: order,
            text: slice.text,
            phase: slice.phase,
            stablePrefixText: slice.stablePrefixText
        )
        return segmentID
    }
}
