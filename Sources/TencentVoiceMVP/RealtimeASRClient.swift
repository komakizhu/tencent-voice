import Foundation

protocol RealtimeASRClient: AnyObject {
    func start(configuration: TencentSessionConfiguration) async throws -> AsyncThrowingStream<ASRUpdate, Error>
    func sendAudio(_ data: Data) async throws
    func finish() async throws
    func cancel()
}
