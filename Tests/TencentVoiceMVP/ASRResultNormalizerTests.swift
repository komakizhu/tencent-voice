import XCTest
@testable import TencentVoiceMVP

final class ASRResultNormalizerTests: XCTestCase {
    func testSlicesExposeCurrentSegmentWithoutPretendingItIsTheWholeStream() {
        let normalizer = ASRResultNormalizer()

        let first = normalizer.accept(ASRSlice(sequence: 0, text: "你", isFinal: false))
        let second = normalizer.accept(ASRSlice(sequence: 0, text: "你好", isFinal: true))

        XCTAssertEqual(first.segmentText, "你")
        XCTAssertEqual(first.phase, .partial)
        XCTAssertEqual(second.segmentText, "你好")
        XCTAssertEqual(second.phase, .final)
        XCTAssertEqual(first.segmentID, second.segmentID)
    }

    func testReusedSequenceAfterFinalGetsANewSegmentID() {
        let normalizer = ASRResultNormalizer()

        let first = normalizer.accept(ASRSlice(sequence: 0, text: "前面的文字", isFinal: true))
        let second = normalizer.accept(ASRSlice(sequence: 0, text: "刚才这一段", isFinal: false))

        XCTAssertNotEqual(first.segmentID, second.segmentID)
        XCTAssertTrue(second.isNewSegment)
    }

    func testNewSequenceAfterReuseGetsLaterSegmentOrder() {
        let normalizer = ASRResultNormalizer()

        let first = normalizer.accept(ASRSlice(sequence: 0, text: "前", isFinal: true))
        let second = normalizer.accept(ASRSlice(sequence: 0, text: "中", isFinal: false))
        let third = normalizer.accept(ASRSlice(sequence: 1, text: "后", isFinal: false))

        XCTAssertLessThan(first.segmentOrder, second.segmentOrder)
        XCTAssertLessThan(second.segmentOrder, third.segmentOrder)
    }

    func testSegmentStartEmitsASeparateSegmentEvenIfPreviousWasNotFinal() {
        let normalizer = ASRResultNormalizer()

        let first = normalizer.accept(
            ASRSlice(sequence: 0, text: "前面的文字", isFinal: false, isSegmentStart: true)
        )
        let second = normalizer.accept(
            ASRSlice(sequence: 0, text: "刚才这一段", isFinal: false, isSegmentStart: true)
        )

        XCTAssertEqual(first.segmentText, "前面的文字")
        XCTAssertEqual(second.segmentText, "刚才这一段")
        XCTAssertNotEqual(first.segmentID, second.segmentID)
        XCTAssertTrue(first.isNewSegment)
        XCTAssertTrue(second.isNewSegment)
    }

    func testEmptySegmentStartIsOnlyABoundaryAndDoesNotEraseText() {
        let normalizer = ASRResultNormalizer()

        let first = normalizer.accept(
            ASRSlice(sequence: 0, text: "前文", isFinal: true)
        )
        let boundary = normalizer.accept(
            ASRSlice(sequence: 0, text: "", isFinal: false, isSegmentStart: true)
        )
        let next = normalizer.accept(
            ASRSlice(sequence: 0, text: "后文", isFinal: false)
        )

        XCTAssertEqual(first.segmentText, "前文")
        XCTAssertEqual(boundary.segmentText, "")
        XCTAssertTrue(boundary.isNewSegment)
        XCTAssertEqual(next.segmentID, boundary.segmentID)
        XCTAssertEqual(next.segmentText, "后文")
    }

    func testCarriesStableWordPrefixWithTheActiveSegment() {
        let normalizer = ASRResultNormalizer()

        let update = normalizer.accept(ASRSlice(
            sequence: 0,
            text: "这是一个正在变化的句子",
            isFinal: false,
            stablePrefixText: "这是一个"
        ))

        XCTAssertEqual(update.stablePrefixText, "这是一个")
    }
}
