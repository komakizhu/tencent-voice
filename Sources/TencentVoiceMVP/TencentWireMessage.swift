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
    let wordList: [TencentWireWord]?

    enum CodingKeys: String, CodingKey {
        case sliceType = "slice_type"
        case index
        case voiceText = "voice_text_str"
        case wordList = "word_list"
    }

    var stablePrefixText: String? {
        guard let wordList else { return nil }
        // Some engines accept word_info but still return an empty list. Treat
        // that as unavailable metadata so the injector can use its existing
        // partial-prefix fallback instead of waiting for final forever.
        guard !wordList.isEmpty else {
            return voiceText.isEmpty ? "" : nil
        }
        var prefix = ""
        for word in wordList {
            guard word.stableFlag == 1 else { break }
            prefix += word.word
        }
        guard voiceText.hasPrefix(prefix) else { return nil }
        return prefix
    }
}

struct TencentWireWord: Decodable {
    let word: String
    let stableFlag: Int

    enum CodingKeys: String, CodingKey {
        case word
        case stableFlag = "stable_flag"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        word = try container.decode(String.self, forKey: .word)
        stableFlag = try container.decodeIfPresent(Int.self, forKey: .stableFlag) ?? 0
    }
}
