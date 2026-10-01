import Foundation
import XCTest
@testable import TencentVoiceMVP

final class TencentCloudUsageClientTests: XCTestCase {
    func testReadsActiveFreeRealtimePackageForStandardModel() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UsageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        UsageURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-TC-Action"), "DescribePidOrders")
            return Data("""
            {"Response":{"PidOrders":[
              {"Name":"实时语音识别免费包5小时","FeeMode":true,
               "SubProductCode":"sp_asr_realtime_prepay","TotalNumFloat":18000,"RestNumFloat":17983.815},
              {"Name":"实时语音识别预付费包30小时","FeeMode":false,
               "SubProductCode":"sp_asr_realtime_prepay","TotalNumFloat":108000,"RestNumFloat":108000},
              {"Name":"语音识别大模型-实时语音识别_2.0-预付费包-60小时","FeeMode":false,
               "SubProductCode":"sp_asr_realtime_prepay","TotalNumFloat":216000,"RestNumFloat":173047.753}
            ],"RequestId":"test"}}
            """.utf8)
        }
        let usage = try await TencentCloudUsageClient(session: session).activePackageUsage(
            credentials: TencentCredentials(appID: "app", secretID: "id", secretKey: "key"),
            engineModelType: "16k_zh"
        )
        XCTAssertEqual(usage?.usedSeconds, 16)
        XCTAssertEqual(usage?.totalSeconds, 18_000)
        XCTAssertEqual(usage?.isPrepaid, false)
    }

    func testUsesPaidStandardPackageAfterFreePackageIsExhausted() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UsageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        UsageURLProtocol.handler = { _ in Data("""
            {"Response":{"PidOrders":[
              {"Name":"实时语音识别免费包5小时","FeeMode":true,
               "SubProductCode":"sp_asr_realtime_prepay","TotalNumFloat":18000,"RestNumFloat":0},
              {"Name":"实时语音识别预付费包30小时","FeeMode":false,
               "SubProductCode":"sp_asr_realtime_prepay","TotalNumFloat":108000,"RestNumFloat":104400}
            ],"RequestId":"test"}}
            """.utf8) }
        let usage = try await TencentCloudUsageClient(session: session).activePackageUsage(
            credentials: TencentCredentials(appID: "app", secretID: "id", secretKey: "key"),
            engineModelType: "16k_zh"
        )
        XCTAssertEqual(usage, TencentPackageUsage(usedSeconds: 3_600, totalSeconds: 108_000, packageCount: 1))
    }

    func testReadsMatchingPaidRealtimePackage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UsageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        UsageURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-TC-Action"), "DescribePidOrders")
            XCTAssertTrue((request.value(forHTTPHeaderField: "Authorization") ?? "")
                .hasPrefix("TC3-HMAC-SHA256 Credential=id/"))
            let body = try Self.requestBody(request)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Int])
            XCTAssertEqual(payload["AvailableType"], 1)
            return Data("""
            {"Response":{"PidOrders":[
              {"Name":"语音识别大模型-实时语音识别_2.0-预付费包-60小时","FeeMode":false,
               "SubProductCode":"sp_asr_realtime_prepay","TotalNumFloat":216000,"RestNumFloat":173047.753},
              {"Name":"语音识别大模型-实时语音识别_2.0-免费包","FeeMode":true,
               "SubProductCode":"sp_asr_realtime_prepay","TotalNumFloat":36000,"RestNumFloat":0},
              {"Name":"语音识别大模型-实时语音识别_1.0-预付费包","FeeMode":false,
               "SubProductCode":"sp_asr_realtime_prepay","TotalNumFloat":36000,"RestNumFloat":0}
            ],"RequestId":"test"}}
            """.utf8)
        }
        let usage = try await TencentCloudUsageClient(session: session).activePackageUsage(
            credentials: TencentCredentials(appID: "app", secretID: "id", secretKey: "key"),
            engineModelType: "16k_zh_en_2.0"
        )
        XCTAssertEqual(usage, TencentPackageUsage(usedSeconds: 42_952, totalSeconds: 216_000, packageCount: 1))
        let largeV1 = try await TencentCloudUsageClient(session: session).activePackageUsage(
            credentials: TencentCredentials(appID: "app", secretID: "id", secretKey: "key"),
            engineModelType: "16k_zh_en"
        )
        XCTAssertEqual(largeV1, TencentPackageUsage(usedSeconds: 36_000, totalSeconds: 36_000, packageCount: 1))
    }

    private static func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = stream.read(&bytes, maxLength: bytes.count)
        XCTAssertGreaterThan(count, 0)
        return Data(bytes.prefix(max(0, count)))
    }

    func testReadsCurrentMonthRealtimeUsageAndSignsRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UsageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        UsageURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "asr.tencentcloudapi.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-TC-Action"), "GetUsageByDate")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-TC-Version"), "2019-06-14")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-TC-Region"), "ap-guangzhou")
            XCTAssertTrue((request.value(forHTTPHeaderField: "Authorization") ?? "")
                .hasPrefix("TC3-HMAC-SHA256 Credential=id/"))
            let body: Data
            if let directBody = request.httpBody {
                body = directBody
            } else {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = stream.read(&bytes, maxLength: bytes.count)
                XCTAssertGreaterThan(count, 0)
                body = Data(bytes.prefix(max(0, count)))
            }
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["BizNameList"] as? [String], ["asr_rt"])
            XCTAssertEqual(payload["StartDate"] as? String, "2026-09-01")
            XCTAssertEqual(payload["EndDate"] as? String, "2026-09-30")
            return Data("""
            {"Response":{"Data":{"UsageByDateInfoList":[{"BizName":"asr_rt","Duration":68400},
              {"BizName":"asr_rec","Duration":3600}]},"RequestId":"test"}}
            """.utf8)
        }
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z"))
        let usage = try await TencentCloudUsageClient(session: session).currentMonth(
            credentials: TencentCredentials(appID: "app", secretID: "id", secretKey: "key"),
            at: date
        )
        XCTAssertEqual(usage, TencentCloudUsage(seconds: 68_400, startDate: "2026-09-01", endDate: "2026-09-30"))
    }
}

private final class UsageURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let data = try Self.handler?(request) ?? Data()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
