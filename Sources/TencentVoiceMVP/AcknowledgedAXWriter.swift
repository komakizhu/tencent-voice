import Foundation

@MainActor
final class AcknowledgedAXWriter {
    struct OperationContext {
        let diagnostic: TextInputDiagnosticContext
        let onDispatch: () -> Void
        let onFinish: (_ status: String, _ error: Error?) -> Void
    }

    private let target: any AXAcknowledgingTarget
    private let snapshot: TextSnapshot
    private let onCommit: (String, String, TextRange, String, AXTextWriteReceipt) -> Void
    private let onFailure: (Error) -> Void
    private let operationContextProvider: ((String, String, String, TextRange) -> OperationContext?)?
    private var confirmedDocument: String
    private var confirmedRange: TextRange
    private var confirmedProjection = ""
    private var desiredProjection = ""
    private var runner: Task<Void, Never>?
    private var runnerGeneration: UInt64 = 0
    private var failure: Error?
    private var cancelled = false

    var hasPendingWork: Bool {
        runner != nil || desiredProjection != confirmedProjection
    }

    init(
        target: any AXAcknowledgingTarget,
        snapshot: TextSnapshot,
        onCommit: @escaping (String, String, TextRange, String, AXTextWriteReceipt) -> Void,
        onFailure: @escaping (Error) -> Void,
        operationContextProvider: ((String, String, String, TextRange) -> OperationContext?)? = nil
    ) {
        self.target = target
        self.snapshot = snapshot
        self.confirmedDocument = snapshot.text
        self.confirmedRange = snapshot.selection
        self.onCommit = onCommit
        self.onFailure = onFailure
        self.operationContextProvider = operationContextProvider
    }

    func accept(_ candidate: String) throws {
        guard !cancelled else { throw CancellationError() }
        if let failure { throw failure }
        desiredProjection = candidate
        guard runner == nil, desiredProjection != confirmedProjection else { return }

        runnerGeneration &+= 1
        let generation = runnerGeneration
        runner = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.runnerGeneration == generation {
                    self.runner = nil
                }
            }
            do {
                while self.runnerGeneration == generation,
                      self.desiredProjection != self.confirmedProjection {
                    try Task.checkCancellation()
                    let submittedProjection = self.desiredProjection
                    let previousProjection = self.confirmedProjection
                    let previousDocument = self.confirmedDocument
                    let previousRange = self.confirmedRange
                    let operation = self.operationContextProvider?(
                        self.confirmedProjection,
                        submittedProjection,
                        previousDocument,
                        previousRange
                    )
                    if let operation {
                        self.target.setDiagnosticOperation(operation.diagnostic)
                        operation.onDispatch()
                    }
                    do {
                        let receipt = try await self.target.writeAXText(
                            snapshot: self.snapshot,
                            range: previousRange,
                            expectedText: previousDocument,
                            with: submittedProjection
                        )
                        operation?.onFinish("acknowledged", nil)
                        if operation != nil { self.target.setDiagnosticOperation(nil) }
                        try Task.checkCancellation()
                        guard self.runnerGeneration == generation else { throw CancellationError() }
                        self.confirmedDocument = receipt.text
                        self.confirmedRange = receipt.writtenRange
                        self.confirmedProjection = submittedProjection
                        self.onCommit(
                            previousProjection,
                            previousDocument,
                            previousRange,
                            submittedProjection,
                            receipt
                        )
                    } catch is CancellationError {
                        operation?.onFinish("cancelled", nil)
                        if operation != nil { self.target.setDiagnosticOperation(nil) }
                        throw CancellationError()
                    } catch {
                        operation?.onFinish("unconfirmed", error)
                        if operation != nil { self.target.setDiagnosticOperation(nil) }
                        throw error
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.runnerGeneration == generation else { return }
                self.failure = error
                self.onFailure(error)
            }
        }
    }

    func finish(_ candidate: String) async throws {
        try accept(candidate)
        while let task = runner { await task.value }
        if let failure { throw failure }
        guard !cancelled else { throw CancellationError() }
    }

    func cancel() {
        cancelled = true
        runnerGeneration &+= 1
        runner?.cancel()
        runner = nil
        target.cancelAXWrite()
    }
}
