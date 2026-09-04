import XCTest
@testable import TencentVoiceMVP

final class ASRProjectionAccumulatorTests: XCTestCase {
    func testProjectionKeepsCommittedPrefixAndMutableActiveSegmentSeparate() {
        var accumulator = ASRProjectionAccumulator()

        let first = accumulator.apply(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "你好",
            phase: .partial
        ))
        let second = accumulator.apply(ASRUpdate(
            segmentID: 2,
            segmentOrder: 1,
            sequence: 0,
            segmentText: "世界",
            phase: .started
        ))

        XCTAssertEqual(first?.committedText, "")
        XCTAssertEqual(first?.activeSegmentText, "你好")
        XCTAssertEqual(second?.committedText, "你好")
        XCTAssertEqual(second?.activeSegmentText, "世界")
        XCTAssertEqual(second?.text, "你好世界")
    }

    func testFinalResultKeepsTheFinalSegmentVisibleUntilStreamFinishes() {
        var accumulator = ASRProjectionAccumulator()
        _ = accumulator.apply(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "完成",
            phase: .partial
        ))

        let final = accumulator.apply(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "完成",
            phase: .final
        ))

        XCTAssertEqual(final?.text, "完成")
        XCTAssertEqual(final?.activeSegmentText, "完成")
        XCTAssertTrue(final?.activeIsFinal == true)
    }

    func testLateOlderSegmentCannotRewriteCurrentProjection() {
        var accumulator = ASRProjectionAccumulator()

        _ = accumulator.apply(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "前",
            phase: .final
        ))
        _ = accumulator.apply(ASRUpdate(
            segmentID: 2,
            segmentOrder: 1,
            sequence: 1,
            segmentText: "后",
            phase: .partial
        ))

        XCTAssertNil(accumulator.apply(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "被迟到结果改写",
            phase: .partial
        )))
        XCTAssertEqual(accumulator.renderedText, "前后")
    }

    func testEmptyBoundaryDoesNotClearCommittedText() {
        var accumulator = ASRProjectionAccumulator()

        _ = accumulator.apply(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "前文",
            phase: .final
        ))
        let boundary = accumulator.apply(ASRUpdate(
            segmentID: 2,
            segmentOrder: 1,
            sequence: 0,
            segmentText: "",
            phase: .started,
            isNewSegment: true
        ))

        XCTAssertEqual(boundary?.committedText, "前文")
        XCTAssertEqual(boundary?.activeSegmentText, "")
        XCTAssertEqual(boundary?.text, "前文")
    }

    func testEmptyFinalDoesNotClearActiveSegment() {
        var accumulator = ASRProjectionAccumulator()

        _ = accumulator.apply(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "未完成的一句话",
            phase: .partial
        ))
        XCTAssertNil(accumulator.apply(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 1,
            segmentText: "",
            phase: .final,
            wireFinal: true
        )))
        XCTAssertEqual(accumulator.renderedText, "未完成的一句话")
    }

    func testShorterFinalOnlyEditsCurrentActiveSegment() {
        var accumulator = ASRProjectionAccumulator()

        _ = accumulator.apply(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "前缀",
            phase: .final
        ))
        let updated = accumulator.apply(ASRUpdate(
            segmentID: 2,
            segmentOrder: 1,
            sequence: 0,
            segmentText: "这是一个三十二个字符的句子",
            phase: .partial
        ))
        let shorter = accumulator.apply(ASRUpdate(
            segmentID: 2,
            segmentOrder: 1,
            sequence: 1,
            segmentText: "这是一个三十二个字符",
            phase: .final
        ))

        XCTAssertEqual(updated?.committedText, "前缀")
        XCTAssertEqual(shorter?.committedText, "前缀")
        XCTAssertEqual(shorter?.activeSegmentText, "这是一个三十二个字符")
        XCTAssertEqual(shorter?.text, "前缀这是一个三十二个字符")
        XCTAssertEqual(accumulator.renderedText, "前缀这是一个三十二个字符")
    }

    func testStreamEndCommitsActiveTextWithoutChangingVisibleText() {
        var accumulator = ASRProjectionAccumulator()

        _ = accumulator.apply(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "最后一句",
            phase: .partial
        ))
        let ended = accumulator.apply(.streamEnded)

        XCTAssertTrue(ended?.isStreamEnded == true)
        XCTAssertEqual(ended?.committedText, "最后一句")
        XCTAssertNil(ended?.activeSegmentID)
        XCTAssertEqual(ended?.text, "最后一句")
        XCTAssertEqual(accumulator.renderedText, "最后一句")
    }
}
