import CryptoKit
import Foundation

struct TencentCloudUsage: Equatable {
    let seconds: Int
    let startDate: String
    let endDate: String
}

struct TencentPackageUsage: Equatable {
    let usedSeconds: Int
    let totalSeconds: Int
    let packageCount: Int
    let isPrepaid: Bool

    init(usedSeconds: Int, totalSeconds: Int, packageCount: Int, isPrepaid: Bool = true) {
        self.usedSeconds = usedSeconds
        self.totalSeconds = totalSeconds
        self.packageCount = packageCount
        self.isPrepaid = isPrepaid
    }
}

enum TencentCloudUsageError: LocalizedError {
    case invalidResponse
    case api(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "腾讯云用量响应格式无效"
        case let .api(code): return "腾讯云用量查询失败（\(code)）"
        }
    }
}

struct TencentCloudUsageClient {
    static let consoleURL = URL(string: "https://console.cloud.tencent.com/asr")!
    static let resourceBundleURL = URL(string: "https://console.cloud.tencent.com/asr/resourcebundle")!
    private static let host = "asr.tencentcloudapi.com"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func currentMonth(
        credentials: TencentCredentials,
        at date: Date = Date()
    ) async throws -> TencentCloudUsage {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "yyyy-MM-dd"
        let endDate = formatter.string(from: date)
        var components = formatter.calendar.dateComponents(in: formatter.timeZone, from: date)
        components.day = 1
        let startDate = formatter.string(from: formatter.calendar.date(from: components)!)
        let payload = Data(
            "{\"BizNameList\":[\"asr_rt\"],\"StartDate\":\"\(startDate)\",\"EndDate\":\"\(endDate)\"}".utf8
        )
        var request = URLRequest(url: URL(string: "https://\(Self.host)/")!)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.timeoutInterval = 15
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.host, forHTTPHeaderField: "Host")
        request.setValue("GetUsageByDate", forHTTPHeaderField: "X-TC-Action")
        request.setValue("2019-06-14", forHTTPHeaderField: "X-TC-Version")
        request.setValue("ap-guangzhou", forHTTPHeaderField: "X-TC-Region")
        request.setValue(String(Int(date.timeIntervalSince1970)), forHTTPHeaderField: "X-TC-Timestamp")
        request.setValue(Self.authorization(
            credentials: credentials,
            payload: payload,
            timestamp: Int(date.timeIntervalSince1970)
        ), forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw TencentCloudUsageError.invalidResponse
        }
        let envelope = try JSONDecoder().decode(UsageEnvelope.self, from: data)
        if let error = envelope.Response.Error {
            throw TencentCloudUsageError.api(error.Code)
        }
        guard let entries = envelope.Response.Data?.UsageByDateInfoList else {
            throw TencentCloudUsageError.invalidResponse
        }
        let seconds = try entries.filter { $0.BizName == "asr_rt" }.reduce(0) { sum, entry in
            guard let duration = entry.Duration, duration >= 0 else {
                throw TencentCloudUsageError.invalidResponse
            }
            return sum + duration
        }
        return TencentCloudUsage(seconds: seconds, startDate: startDate, endDate: endDate)
    }

    func activePackageUsage(
        credentials: TencentCredentials,
        engineModelType: String,
        at date: Date = Date()
    ) async throws -> TencentPackageUsage? {
        let payload = Data("{\"AvailableType\":1}".utf8)
        var request = URLRequest(url: URL(string: "https://\(Self.host)/")!)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.timeoutInterval = 15
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.host, forHTTPHeaderField: "Host")
        request.setValue("DescribePidOrders", forHTTPHeaderField: "X-TC-Action")
        request.setValue("2019-06-14", forHTTPHeaderField: "X-TC-Version")
        request.setValue("ap-guangzhou", forHTTPHeaderField: "X-TC-Region")
        request.setValue(String(Int(date.timeIntervalSince1970)), forHTTPHeaderField: "X-TC-Timestamp")
        request.setValue(Self.authorization(
            credentials: credentials,
            payload: payload,
            timestamp: Int(date.timeIntervalSince1970)
        ), forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw TencentCloudUsageError.invalidResponse
        }
        let envelope = try JSONDecoder().decode(PackageEnvelope.self, from: data)
        if let error = envelope.Response.Error {
            throw TencentCloudUsageError.api(error.Code)
        }
        guard let orders = envelope.Response.PidOrders else {
            throw TencentCloudUsageError.invalidResponse
        }
        let modelOrders = orders.filter { order in
            order.SubProductCode == "sp_asr_realtime_prepay"
                && Self.matchesModel(order.Name, engineModelType: engineModelType)
        }
        let freeOrders = modelOrders.filter(\.FeeMode)
        let paidOrders = modelOrders.filter { !$0.FeeMode }
        let useFree = engineModelType == TencentEnginePreset.standard.rawValue
            && !freeOrders.isEmpty
            && (paidOrders.isEmpty || freeOrders.contains { ($0.RestNumFloat ?? 0) > 0 })
        let matching = useFree ? freeOrders : paidOrders
        guard !matching.isEmpty else { return nil }
        var usedSeconds = 0
        var totalSeconds = 0
        for order in matching {
            guard let total = order.TotalNumFloat, let remaining = order.RestNumFloat,
                  total.isFinite, remaining.isFinite,
                  total > 0, remaining >= 0, remaining <= total,
                  total <= Double(Int.max / 2) else {
                throw TencentCloudUsageError.invalidResponse
            }
            totalSeconds += Int(total.rounded())
            usedSeconds += Int((total - remaining).rounded())
        }
        return TencentPackageUsage(
            usedSeconds: usedSeconds,
            totalSeconds: totalSeconds,
            packageCount: matching.count,
            isPrepaid: !useFree
        )
    }

    private static func matchesModel(_ name: String, engineModelType: String) -> Bool {
        guard name.contains("实时语音识别") else { return false }
        switch engineModelType {
        case "16k_zh_en_2.0": return name.contains("2.0")
        case "16k_zh_en": return name.contains("大模型") && !name.contains("2.0")
        case "16k_zh": return !name.contains("大模型") && !name.contains("2.0")
        default: return false
        }
    }

    private static func authorization(
        credentials: TencentCredentials,
        payload: Data,
        timestamp: Int
    ) -> String {
        let utcDate = DateFormatter()
        utcDate.calendar = Calendar(identifier: .gregorian)
        utcDate.timeZone = TimeZone(secondsFromGMT: 0)
        utcDate.dateFormat = "yyyy-MM-dd"
        let date = utcDate.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
        let scope = "\(date)/asr/tc3_request"
        let canonical = "POST\n/\n\ncontent-type:application/json; charset=utf-8\nhost:\(host)\n\ncontent-type;host\n\(hex(SHA256.hash(data: payload)))"
        let toSign = "TC3-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(hex(SHA256.hash(data: Data(canonical.utf8))))"
        let dateKey = hmac(Data(date.utf8), key: Data("TC3\(credentials.secretKey)".utf8))
        let serviceKey = hmac(Data("asr".utf8), key: dateKey)
        let signingKey = hmac(Data("tc3_request".utf8), key: serviceKey)
        let signature = hex(hmac(Data(toSign.utf8), key: signingKey))
        return "TC3-HMAC-SHA256 Credential=\(credentials.secretID)/\(scope), SignedHeaders=content-type;host, Signature=\(signature)"
    }

    private static func hmac(_ data: Data, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

private struct UsageEnvelope: Decodable {
    let Response: UsageResponse
}

private struct UsageResponse: Decodable {
    let Data: UsageData?
    let Error: UsageAPIError?
}

private struct UsageData: Decodable {
    let UsageByDateInfoList: [UsageEntry]?
}

private struct UsageEntry: Decodable {
    let BizName: String?
    let Duration: Int?
}

private struct UsageAPIError: Decodable {
    let Code: String
}

private struct PackageEnvelope: Decodable {
    let Response: PackageResponse
}

private struct PackageResponse: Decodable {
    let PidOrders: [PackageOrder]?
    let Error: UsageAPIError?
}

private struct PackageOrder: Decodable {
    let Name: String
    let FeeMode: Bool
    let SubProductCode: String
    let TotalNumFloat: Double?
    let RestNumFloat: Double?
}
