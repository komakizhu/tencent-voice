import Foundation
import XCTest
@testable import TencentVoiceMVP

final class TencentWireMessageTests: XCTestCase {
    func testDecodePartialResult() throws {
        let data = Data("""
        {"code":0,"message":"success","result":{"slice_type":1,"index":0,"voice_text_str":"实时"}}
        """.utf8)
        let response = try JSONDecoder().decode(TencentWireResponse.self, from: data)
        XCTAssertEqual(response.result?.sliceType, 1)
        XCTAssertEqual(response.result?.index, 0)
        XCTAssertEqual(response.result?.voiceText, "实时")
    }

    func testDecodeStreamEnd() throws {
        let data = Data(#"{"code":0,"message":"success","final":1}"#.utf8)
        let response = try JSONDecoder().decode(TencentWireResponse.self, from: data)
        XCTAssertEqual(response.isFinal, 1)
        XCTAssertNil(response.result)
    }
}
