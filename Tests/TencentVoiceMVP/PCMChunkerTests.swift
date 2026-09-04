import Foundation
import XCTest
@testable import TencentVoiceMVP

final class PCMChunkerTests: XCTestCase {
    func testSplits16kMonoPCMInto6400ByteChunks() {
        var chunker = PCMChunker(chunkByteCount: 6_400)
        let chunks = chunker.append(Data(repeating: 1, count: 12_800))
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks.allSatisfy { $0.count == 6_400 })
        XCTAssertNil(chunker.flush())
    }

    func testFlushReturnsRemainder() {
        var chunker = PCMChunker(chunkByteCount: 6_400)
        _ = chunker.append(Data(repeating: 1, count: 100))
        XCTAssertEqual(chunker.flush()?.count, 100)
        XCTAssertNil(chunker.flush())
    }
}
