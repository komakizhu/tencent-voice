import Foundation

struct TencentWireResponse: Decodable {
    let code: Int
    let message: String
    let isFinal: Int?
    let result: TencentWireResult?

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case isFinal = "final"
        case result
    }
}

struct TencentWireResult: Decodable {
    let sliceType: Int
    let index: Int
    let voiceText: String

    enum CodingKeys: String, CodingKey {
        case sliceType = "slice_type"
        case index
        case voiceText = "voice_text_str"
    }
}
