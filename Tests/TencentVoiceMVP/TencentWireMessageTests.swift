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

    func testDecodeLeadingStableWordPrefix() throws {
        let data = Data("""
        {"code":0,"message":"success","result":{"slice_type":1,"index":0,"voice_text_str":"这是一个正在变化的句子","word_list":[{"word":"这是","stable_flag":1},{"word":"一个","stable_flag":1},{"word":"正在变化的","stable_flag":0},{"word":"句子","stable_flag":0}]}}
        """.utf8)

        let response = try JSONDecoder().decode(TencentWireResponse.self, from: data)

        XCTAssertEqual(response.result?.stablePrefixText, "这是一个")
    }

    func testEmptyWordListLeavesStablePrefixUnavailableForFallback() throws {
        let data = Data("""
        {"code":0,"message":"success","result":{"slice_type":1,"index":0,"voice_text_str":"实时结果","word_list":[]}}
        """.utf8)

        let response = try JSONDecoder().decode(TencentWireResponse.self, from: data)

        XCTAssertNil(response.result?.stablePrefixText)
    }
}
