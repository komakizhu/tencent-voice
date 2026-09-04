import Foundation

final class TencentASRClient: RealtimeASRClient {
    private var socket: URLSessionWebSocketTask?
    private var continuation: AsyncThrowingStream<ASRUpdate, Error>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var normalizer = ASRResultNormalizer()
    private var finished = false

    func start(configuration: TencentSessionConfiguration) async throws -> AsyncThrowingStream<ASRUpdate, Error> {
        cancel()
        finished = false
        normalizer = ASRResultNormalizer()

        let now = Int(Date().timeIntervalSince1970)
        let url = try TencentSigner.makeURL(
            configuration: configuration,
            timestamp: now,
            expired: now + 600,
            nonce: Int.random(in: 1...Int.max)
        )
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task

        let stream = AsyncThrowingStream<ASRUpdate, Error> { [weak self] continuation in
            self?.continuation = continuation
            continuation.onTermination = { [weak self] _ in self?.cancel() }
        }
        task.resume()

        do {
            let firstMessage = try await task.receive()
            try validateHandshake(firstMessage)
        } catch {
            cancel()
            throw error
        }

        receiveTask = Task { [weak self, weak task] in
            guard let self, let task else { return }
            await self.receiveLoop(task: task)
        }
        return stream
    }

    func sendAudio(_ data: Data) async throws {
        guard let socket else { throw TencentASRError.notStarted }
        guard !finished else { throw TencentASRError.alreadyFinished }
        try await socket.send(.data(data))
    }

    func finish() async throws {
        guard let socket else { throw TencentASRError.notStarted }
        guard !finished else { return }
        finished = true
        try await socket.send(.string("{\"type\":\"end\"}"))
    }

    func cancel() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        continuation?.finish()
        continuation = nil
        finished = true
    }

    private func validateHandshake(_ message: URLSessionWebSocketTask.Message) throws {
        let data = try message.dataValue
        let response = try JSONDecoder().decode(TencentWireResponse.self, from: data)
        guard response.code == 0 else {
            throw TencentASRError.server(code: response.code, message: response.message)
        }
    }

    private func receiveLoop(task: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                let data = try message.dataValue
                let response = try JSONDecoder().decode(TencentWireResponse.self, from: data)

                guard response.code == 0 else {
                    let error = TencentASRError.server(code: response.code, message: response.message)
                    continuation?.finish(throwing: error)
                    return
                }

                if let result = response.result {
                    let update = normalizer.accept(ASRSlice(
                        sequence: result.index,
                        text: result.voiceText,
                        isFinal: response.isFinal == 1 || result.sliceType == 2,
                        isSegmentStart: result.sliceType == 0,
                        sliceType: result.sliceType,
                        wireFinal: response.isFinal == 1,
                        stablePrefixText: result.stablePrefixText
                    ))
                    continuation?.yield(update)
                }

                if response.isFinal == 1 {
                    continuation?.yield(.streamEnded)
                    continuation?.finish()
                    return
                }
            }
        } catch is CancellationError {
            return
        } catch {
            continuation?.finish(throwing: error)
        }
    }
}

private extension URLSessionWebSocketTask.Message {
    var dataValue: Data {
        get throws {
            switch self {
            case let .data(data): return data
            case let .string(string): return Data(string.utf8)
            @unknown default: throw TencentASRError.invalidURL
            }
        }
    }
}
