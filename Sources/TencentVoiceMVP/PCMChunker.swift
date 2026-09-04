import Foundation

public struct PCMChunker: Sendable {
    private let chunkByteCount: Int
    private var buffer = Data()

    public init(chunkByteCount: Int = 6_400) {
        precondition(chunkByteCount > 0)
        self.chunkByteCount = chunkByteCount
    }

    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var chunks: [Data] = []
        while buffer.count >= chunkByteCount {
            chunks.append(Data(buffer.prefix(chunkByteCount)))
            buffer.removeFirst(chunkByteCount)
        }
        return chunks
    }

    public mutating func flush() -> Data? {
        guard !buffer.isEmpty else { return nil }
        let remainder = buffer
        buffer.removeAll(keepingCapacity: true)
        return remainder
    }
}
