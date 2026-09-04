import Foundation

struct ASRProjectionAccumulator: Sendable {
    private var committedText = ""
    private var activeSegmentID: Int?
    private var activeSegmentOrder = Int.min
    private var activeSegmentText = ""
    private var activeIsFinal = false
    private var activeStablePrefixText: String?
    private var revision: UInt64 = 0
    private var latestVisibleText = ""

    mutating func apply(_ update: ASRUpdate) -> ASRProjection? {
        let previousVisibleText = committedText + activeSegmentText

        if update.isStreamEnded {
            guard activeSegmentID != nil else { return nil }
            committedText += activeSegmentText
            activeSegmentID = nil
            activeSegmentOrder = Int.min
            activeSegmentText = ""
            activeIsFinal = false
            activeStablePrefixText = nil
            latestVisibleText = committedText
            revision += 1
            return ASRProjection(
                committedText: committedText,
                activeSegmentText: "",
                activeSegmentID: nil,
                activeIsFinal: false,
                revision: revision,
                changed: false,
                isFinal: false,
                isStreamEnded: true
            )
        }

        if update.isFinal && update.segmentText.isEmpty {
            return nil
        }

        if let activeSegmentID {
            if update.segmentID == activeSegmentID {
                activeSegmentText = update.segmentText
                activeIsFinal = update.isFinal
                activeStablePrefixText = update.stablePrefixText
            } else {
                guard update.segmentOrder >= activeSegmentOrder else { return nil }
                committedText += activeSegmentText
                self.activeSegmentID = update.segmentID
                activeSegmentOrder = update.segmentOrder
                activeSegmentText = update.segmentText
                activeIsFinal = update.isFinal
                activeStablePrefixText = update.stablePrefixText
            }
        } else {
            guard update.segmentOrder >= activeSegmentOrder else { return nil }
            activeSegmentID = update.segmentID
            activeSegmentOrder = update.segmentOrder
            activeSegmentText = update.segmentText
            activeIsFinal = update.isFinal
            activeStablePrefixText = update.stablePrefixText
        }

        let visibleText = committedText + activeSegmentText
        let changed = visibleText != previousVisibleText
        guard changed || update.isFinal || update.isNewSegment else { return nil }
        latestVisibleText = visibleText
        revision += 1
        return ASRProjection(
            committedText: committedText,
            activeSegmentText: activeSegmentText,
            activeSegmentID: activeSegmentID,
            activeIsFinal: activeIsFinal,
            revision: revision,
            changed: changed,
            isFinal: update.isFinal,
            isStreamEnded: false,
            activeStablePrefixText: activeStablePrefixText
        )
    }

    var renderedText: String { latestVisibleText }
}
