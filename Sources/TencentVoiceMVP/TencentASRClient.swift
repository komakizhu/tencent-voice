import Foundation

protocol TencentWebSocket: AnyObject {
    func resume()
    func receive() async throws -> URLSessionWebSocketTask.Message
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: TencentWebSocket {}

final class TencentASRClient: RealtimeASRClient {
    private let stateLock = NSRecursiveLock()
    private var generation: UInt64 = 0
    private var socket: TencentWebSocket?
    private var continuation: AsyncThrowingStream<ASRUpdate, Error>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var normalizer = ASRResultNormalizer()
    private var finished = false
    private let webSocketFactory: (URL) -> TencentWebSocket
    private let handshakeTimeoutNanoseconds: UInt64

    init(
        webSocketFactory: @escaping (URL) -> TencentWebSocket = {
            URLSession.shared.webSocketTask(with: $0)
        },
        handshakeTimeoutNanoseconds: UInt64 = 10 * 1_000_000_000
    ) {
        self.webSocketFactory = webSocketFactory
        self.handshakeTimeoutNanoseconds = handshakeTimeoutNanoseconds
    }

    func start(configuration: TencentSessionConfiguration) async throws -> AsyncThrowingStream<ASRUpdate, Error> {
        cancel()

        let now = Int(Date().timeIntervalSince1970)
        let url = try TencentSigner.makeURL(
            configuration: configuration,
            timestamp: now,
            expired: now + 600,
            nonce: Int.random(in: 1...Int.max)
        )
        let task = webSocketFactory(url)
        let (connectionGeneration, stream) = stateLock.withLock {
            generation &+= 1
            let currentGeneration = generation
            socket = task
            finished = false
            normalizer = ASRResultNormalizer()
            let stream = AsyncThrowingStream<ASRUpdate, Error> { continuation in
                self.continuation = continuation
                continuation.onTermination = { [weak self] termination in
                    // Normal final delivery does not imply that the end-marker
                    // send callback has returned. The coordinator owns cleanup.
                    if case .cancelled = termination {
                        self?.cancel(ifGeneration: currentGeneration)
                    }
                }
            }
            return (currentGeneration, stream)
        }
        task.resume()

        do {
            try await performHandshake(on: task)
            try stateLock.withLock {
                guard generation == connectionGeneration, !Task.isCancelled else {
                    throw CancellationError()
                }
                receiveTask = Task { [weak self, weak task] in
                    guard let self, let task else { return }
                    await self.receiveLoop(task: task, generation: connectionGeneration)
                }
            }
        } catch {
            cancel(ifGeneration: connectionGeneration)
            throw error
        }
        return stream
    }

    func testConnection(configuration: TencentSessionConfiguration) async throws {
        cancel()

        let now = Int(Date().timeIntervalSince1970)
        let url = try TencentSigner.makeURL(
            configuration: configuration,
            timestamp: now,
            expired: now + 600,
            nonce: Int.random(in: 1...Int.max)
        )
        let task = webSocketFactory(url)
        let connectionGeneration = stateLock.withLock {
            generation &+= 1
            socket = task
            finished = false
            return generation
        }
        task.resume()

        do {
            try await performHandshake(on: task)
            try stateLock.withLock {
                guard generation == connectionGeneration, !Task.isCancelled else { throw CancellationError() }
                socket = nil
                finished = true
            }
            task.cancel(with: .normalClosure, reason: Data("connection-test".utf8))
        } catch {
            cancel(ifGeneration: connectionGeneration)
            throw error
        }
    }

    func sendAudio(_ data: Data) async throws {
        let socket = try stateLock.withLock {
            try Task.checkCancellation()
            guard let socket = self.socket else { throw TencentASRError.notStarted }
            guard !finished else { throw TencentASRError.alreadyFinished }
            return socket
        }
        try await socket.send(.data(data))
    }

    func finish() async throws {
        let currentSocket: TencentWebSocket? = try stateLock.withLock {
            try Task.checkCancellation()
            guard let socket else { throw TencentASRError.notStarted }
            guard !finished else { return nil }
            finished = true
            return socket
        }
        guard let socket = currentSocket else { return }
        try await socket.send(.string("{\"type\":\"end\"}"))
    }

    func cancel() {
        cancel(ifGeneration: nil)
    }

    private func cancel(ifGeneration expected: UInt64?) {
        stateLock.lock()
        guard expected == nil || generation == expected else {
            stateLock.unlock()
            return
        }
        generation &+= 1
        let oldTask = receiveTask
        let oldSocket = socket
        let oldContinuation = continuation
        receiveTask = nil
        socket = nil
        continuation = nil
        finished = true
        stateLock.unlock()
        oldTask?.cancel()
        oldSocket?.cancel(with: .goingAway, reason: nil)
        oldContinuation?.finish()
    }

    private func performHandshake(on task: TencentWebSocket) async throws {
        let firstMessage = try await withThrowingTaskGroup(
            of: URLSessionWebSocketTask.Message.self
        ) { group in
            group.addTask {
                try await task.receive()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: self.handshakeTimeoutNanoseconds)
                throw TencentASRError.handshakeTimeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        let data = try firstMessage.dataValue
        let response = try JSONDecoder().decode(TencentWireResponse.self, from: data)
        guard response.code == 0 else {
            throw TencentASRError.server(code: response.code, message: response.message)
        }
    }

    private func receiveLoop(task: TencentWebSocket, generation expected: UInt64) async {
        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                let data = try message.dataValue
                let response = try JSONDecoder().decode(TencentWireResponse.self, from: data)
                let keepReceiving = stateLock.withLock {
                    guard generation == expected, !Task.isCancelled else { return false }
                    guard response.code == 0 else {
                        let error = TencentASRError.server(code: response.code, message: response.message)
                        continuation?.finish(throwing: error)
                        return false
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
                        return false
                    }
                    return true
                }
                if !keepReceiving { return }
            }
        } catch {
            stateLock.withLock {
                guard generation == expected, !Task.isCancelled else { return }
                continuation?.finish(throwing: error)
            }
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
