import Foundation

struct KeyboardPacingConfiguration: Equatable, Sendable {
    let firstCharacterDelayNanoseconds: UInt64
    let reservoirDelayNanoseconds: UInt64
    let initialCharacterIntervalNanoseconds: UInt64
    let minimumCharacterIntervalNanoseconds: UInt64
    let maximumCharacterIntervalNanoseconds: UInt64
    let normalMaximumLagNanoseconds: UInt64
    let defaultPartialCadenceNanoseconds: UInt64
    let cadenceFillRatio: Double
    let velocityChangeLimit: Double
    let continuityMinimumNanoseconds: UInt64
    let continuityMaximumNanoseconds: UInt64
    let finalFlushMaximumDurationNanoseconds: UInt64
    let frameIntervalNanoseconds: UInt64
    let ewmaAlpha: Double
    let easeOutExponent: Double

    static let immediate = KeyboardPacingConfiguration(
        firstCharacterDelayNanoseconds: 0,
        reservoirDelayNanoseconds: 0,
        initialCharacterIntervalNanoseconds: 0,
        minimumCharacterIntervalNanoseconds: 0,
        maximumCharacterIntervalNanoseconds: 0,
        normalMaximumLagNanoseconds: 0,
        defaultPartialCadenceNanoseconds: 0,
        cadenceFillRatio: 0,
        velocityChangeLimit: 0,
        continuityMinimumNanoseconds: 0,
        continuityMaximumNanoseconds: 0,
        finalFlushMaximumDurationNanoseconds: 0,
        frameIntervalNanoseconds: 0,
        ewmaAlpha: 0,
        easeOutExponent: 1
    )

    static let balanced = KeyboardPacingConfiguration(
        firstCharacterDelayNanoseconds: 0,
        reservoirDelayNanoseconds: 40_000_000,
        initialCharacterIntervalNanoseconds: 20_000_000,
        minimumCharacterIntervalNanoseconds: 16_000_000,
        maximumCharacterIntervalNanoseconds: 60_000_000,
        normalMaximumLagNanoseconds: 250_000_000,
        defaultPartialCadenceNanoseconds: 600_000_000,
        cadenceFillRatio: 0.75,
        velocityChangeLimit: 0.12,
        continuityMinimumNanoseconds: 250_000_000,
        continuityMaximumNanoseconds: 900_000_000,
        finalFlushMaximumDurationNanoseconds: 120_000_000,
        frameIntervalNanoseconds: 16_000_000,
        ewmaAlpha: 0.25,
        easeOutExponent: 1.6
    )

    static let responsive = KeyboardPacingConfiguration(
        firstCharacterDelayNanoseconds: 0,
        reservoirDelayNanoseconds: 20_000_000,
        initialCharacterIntervalNanoseconds: 18_000_000,
        minimumCharacterIntervalNanoseconds: 16_000_000,
        maximumCharacterIntervalNanoseconds: 52_000_000,
        normalMaximumLagNanoseconds: 250_000_000,
        defaultPartialCadenceNanoseconds: 600_000_000,
        cadenceFillRatio: 0.65,
        velocityChangeLimit: 0.12,
        continuityMinimumNanoseconds: 250_000_000,
        continuityMaximumNanoseconds: 900_000_000,
        finalFlushMaximumDurationNanoseconds: 120_000_000,
        frameIntervalNanoseconds: 16_000_000,
        ewmaAlpha: 0.25,
        easeOutExponent: 1.6
    )

    static let silky = KeyboardPacingConfiguration(
        firstCharacterDelayNanoseconds: 0,
        reservoirDelayNanoseconds: 55_000_000,
        initialCharacterIntervalNanoseconds: 24_000_000,
        minimumCharacterIntervalNanoseconds: 20_000_000,
        maximumCharacterIntervalNanoseconds: 60_000_000,
        normalMaximumLagNanoseconds: 250_000_000,
        defaultPartialCadenceNanoseconds: 600_000_000,
        cadenceFillRatio: 0.85,
        velocityChangeLimit: 0.08,
        continuityMinimumNanoseconds: 250_000_000,
        continuityMaximumNanoseconds: 900_000_000,
        finalFlushMaximumDurationNanoseconds: 120_000_000,
        frameIntervalNanoseconds: 16_000_000,
        ewmaAlpha: 0.25,
        easeOutExponent: 1.8
    )

    static let flowing = KeyboardPacingConfiguration(
        firstCharacterDelayNanoseconds: 0,
        reservoirDelayNanoseconds: 30_000_000,
        initialCharacterIntervalNanoseconds: 20_000_000,
        minimumCharacterIntervalNanoseconds: 16_000_000,
        maximumCharacterIntervalNanoseconds: 56_000_000,
        normalMaximumLagNanoseconds: 250_000_000,
        defaultPartialCadenceNanoseconds: 600_000_000,
        cadenceFillRatio: 0.75,
        velocityChangeLimit: 0.06,
        continuityMinimumNanoseconds: 250_000_000,
        continuityMaximumNanoseconds: 900_000_000,
        finalFlushMaximumDurationNanoseconds: 120_000_000,
        frameIntervalNanoseconds: 16_000_000,
        ewmaAlpha: 0.25,
        easeOutExponent: 1.6
    )

    static let flowingA = flowing

    static let flowingB = makeLiveVariant(
        reservoirDelayNanoseconds: 80_000_000,
        initialCharacterIntervalNanoseconds: 28_000_000,
        minimumCharacterIntervalNanoseconds: 24_000_000,
        maximumCharacterIntervalNanoseconds: 60_000_000,
        cadenceFillRatio: 0.95,
        velocityChangeLimit: 0.06,
        easeOutExponent: 1.6
    )

    static let flowingC = makeLiveVariant(
        reservoirDelayNanoseconds: 120_000_000,
        initialCharacterIntervalNanoseconds: 34_000_000,
        minimumCharacterIntervalNanoseconds: 30_000_000,
        maximumCharacterIntervalNanoseconds: 60_000_000,
        cadenceFillRatio: 1.0,
        velocityChangeLimit: 0.05,
        easeOutExponent: 1.6
    )

    static let silkyA = silky

    static let silkyB = makeLiveVariant(
        reservoirDelayNanoseconds: 90_000_000,
        initialCharacterIntervalNanoseconds: 30_000_000,
        minimumCharacterIntervalNanoseconds: 26_000_000,
        maximumCharacterIntervalNanoseconds: 60_000_000,
        cadenceFillRatio: 1.0,
        velocityChangeLimit: 0.08,
        easeOutExponent: 1.8
    )

    static let silkyC = makeLiveVariant(
        reservoirDelayNanoseconds: 120_000_000,
        initialCharacterIntervalNanoseconds: 36_000_000,
        minimumCharacterIntervalNanoseconds: 32_000_000,
        maximumCharacterIntervalNanoseconds: 60_000_000,
        cadenceFillRatio: 1.0,
        velocityChangeLimit: 0.06,
        easeOutExponent: 1.9
    )

    // Deliberately opaque trial profiles: one is the original flowing profile,
    // while the other two make the reservoir and cadence smoothing obvious in a blind test.
    static let blindOne = makeLiveVariant(
        reservoirDelayNanoseconds: 150_000_000,
        initialCharacterIntervalNanoseconds: 32_000_000,
        minimumCharacterIntervalNanoseconds: 28_000_000,
        maximumCharacterIntervalNanoseconds: 60_000_000,
        cadenceFillRatio: 1.0,
        velocityChangeLimit: 0.03,
        easeOutExponent: 2.0
    )

    static let blindTwo = flowing

    static let blindThree = makeLiveVariant(
        reservoirDelayNanoseconds: 200_000_000,
        initialCharacterIntervalNanoseconds: 42_000_000,
        minimumCharacterIntervalNanoseconds: 36_000_000,
        maximumCharacterIntervalNanoseconds: 60_000_000,
        cadenceFillRatio: 1.0,
        velocityChangeLimit: 0.02,
        easeOutExponent: 2.4
    )

    static let live: KeyboardPacingConfiguration = {
#if TVMVP_PACING_RESPONSIVE
        .responsive
#elseif TVMVP_PACING_SILKY
        .silky
#elseif TVMVP_PACING_FLOWING_A
        .flowingA
#elseif TVMVP_PACING_FLOWING_B
        .flowingB
#elseif TVMVP_PACING_FLOWING_C
        .flowingC
#elseif TVMVP_PACING_SILKY_A
        .silkyA
#elseif TVMVP_PACING_SILKY_B
        .silkyB
#elseif TVMVP_PACING_SILKY_C
        .silkyC
#elseif TVMVP_PACING_BLIND_1
        .blindOne
#elseif TVMVP_PACING_BLIND_2
        .blindTwo
#elseif TVMVP_PACING_BLIND_3
        .blindThree
#elseif TVMVP_PACING_FLOWING
        .flowing
#else
        .balanced
#endif
    }()

    static let previewPresets: [KeyboardPacingConfiguration] = [
        .responsive,
        .balanced,
        .silky,
        .flowing
    ]

    static let trialPresets: [KeyboardPacingConfiguration] = [
        .flowingA,
        .flowingB,
        .flowingC,
        .silkyA,
        .silkyB,
        .silkyC
    ]

    static let blindPresets: [KeyboardPacingConfiguration] = [
        .blindOne,
        .blindTwo,
        .blindThree
    ]

    private static func makeLiveVariant(
        reservoirDelayNanoseconds: UInt64,
        initialCharacterIntervalNanoseconds: UInt64,
        minimumCharacterIntervalNanoseconds: UInt64,
        maximumCharacterIntervalNanoseconds: UInt64,
        cadenceFillRatio: Double,
        velocityChangeLimit: Double,
        easeOutExponent: Double
    ) -> KeyboardPacingConfiguration {
        KeyboardPacingConfiguration(
            firstCharacterDelayNanoseconds: 0,
            reservoirDelayNanoseconds: reservoirDelayNanoseconds,
            initialCharacterIntervalNanoseconds: initialCharacterIntervalNanoseconds,
            minimumCharacterIntervalNanoseconds: minimumCharacterIntervalNanoseconds,
            maximumCharacterIntervalNanoseconds: maximumCharacterIntervalNanoseconds,
            normalMaximumLagNanoseconds: 250_000_000,
            defaultPartialCadenceNanoseconds: 600_000_000,
            cadenceFillRatio: cadenceFillRatio,
            velocityChangeLimit: velocityChangeLimit,
            continuityMinimumNanoseconds: 250_000_000,
            continuityMaximumNanoseconds: 900_000_000,
            finalFlushMaximumDurationNanoseconds: 120_000_000,
            frameIntervalNanoseconds: 16_000_000,
            ewmaAlpha: 0.25,
            easeOutExponent: easeOutExponent
        )
    }

    var isEnabled: Bool {
        initialCharacterIntervalNanoseconds > 0
            && minimumCharacterIntervalNanoseconds > 0
            && maximumCharacterIntervalNanoseconds > 0
            && finalFlushMaximumDurationNanoseconds > 0
            && frameIntervalNanoseconds > 0
    }
}

typealias KeyboardSmoothingConfiguration = KeyboardPacingConfiguration

@MainActor
protocol KeyboardPacingClock: AnyObject {
    var nowNanoseconds: UInt64 { get }
    func sleep(nanoseconds: UInt64) async throws
}

@MainActor
final class ContinuousKeyboardPacingClock: KeyboardPacingClock {
    var nowNanoseconds: UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

@MainActor
final class KeyboardCharacterPacer {
    enum Trigger: Equatable {
        case partial
        case segmentFinal
        case streamEnd
    }

    private enum RunnerKind {
        case normal
        case flush
    }

    private struct PendingCharacter {
        let character: Character
        let arrivalNanoseconds: UInt64
    }

    private let configuration: KeyboardPacingConfiguration
    private let clock: KeyboardPacingClock
    private let append: (String) throws -> Void
    private let replaceTrailingText: (String, String) throws -> Void
    private let onFailure: (Error) -> Void

    private var runnerTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var desiredText = ""
    private var visibleText = ""
    private var pending: [PendingCharacter] = []
    private var hasSubmittedCharacter = false
    private var stopping = false
    private var isFlushing = false
    private var queueEmptySinceNanoseconds: UInt64?
    private var currentIntervalNanoseconds: UInt64
    private var partialCadenceNanoseconds: Double
    private var lastPartialArrivalNanoseconds: UInt64?
    private var lastError: Error?

    init(
        configuration: KeyboardPacingConfiguration,
        clock: KeyboardPacingClock,
        append: @escaping (String) throws -> Void,
        replaceTrailingText: @escaping (String, String) throws -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        self.configuration = configuration
        self.clock = clock
        self.append = append
        self.replaceTrailingText = replaceTrailingText
        self.onFailure = onFailure
        currentIntervalNanoseconds = configuration.initialCharacterIntervalNanoseconds
        partialCadenceNanoseconds = Double(configuration.defaultPartialCadenceNanoseconds)
    }

    func beginSession() {
        invalidateRunner()
        desiredText = ""
        visibleText = ""
        pending = []
        hasSubmittedCharacter = false
        stopping = false
        isFlushing = false
        queueEmptySinceNanoseconds = nil
        currentIntervalNanoseconds = configuration.initialCharacterIntervalNanoseconds
        partialCadenceNanoseconds = Double(configuration.defaultPartialCadenceNanoseconds)
        lastPartialArrivalNanoseconds = nil
        lastError = nil
    }

    func accept(candidate: String, trigger: Trigger) throws {
        guard lastError == nil else { return }
        let now = clock.nowNanoseconds
        let candidateChanged = candidate != desiredText
        let wasPureGrowth = candidate.hasPrefix(desiredText)
        if trigger == .partial, candidateChanged, wasPureGrowth {
            updatePartialCadence(at: now)
        }

        try reconcile(candidate: candidate, now: now)

        switch trigger {
        case .partial:
            if stopping {
                if candidateChanged {
                    try startFlush()
                }
            } else {
                ensureNormalRunner(at: now)
            }
        case .segmentFinal, .streamEnd:
            if !isFlushing || candidateChanged {
                try startFlush()
            }
        }
    }

    func beginStopping() throws {
        stopping = true
        try startFlush()
    }

    func finish(candidate: String) async throws {
        stopping = true
        try accept(candidate: candidate, trigger: .streamEnd)
        while true {
            if let runnerTask {
                await runnerTask.value
                continue
            }
            guard !pending.isEmpty else { break }
            try startFlush()
        }
        if let lastError {
            throw lastError
        }
    }

    func finishImmediately(candidate: String) throws {
        stopping = true
        invalidateRunner()
        try reconcile(candidate: candidate, now: clock.nowNanoseconds)
        if !pending.isEmpty {
            try emitPending(count: pending.count)
            hasSubmittedCharacter = true
        }
        isFlushing = false
        queueEmptySinceNanoseconds = pending.isEmpty ? clock.nowNanoseconds : nil
        if let lastError {
            throw lastError
        }
    }

    func cancel() {
        invalidateRunner()
        pending = []
        desiredText = ""
        visibleText = ""
        queueEmptySinceNanoseconds = nil
        isFlushing = false
        lastError = nil
    }

    private func reconcile(candidate: String, now: UInt64) throws {
        guard candidate != desiredText else {
            if !hasSubmittedCharacter, !pending.isEmpty {
                try emitFirstCharacter(now: now)
            }
            return
        }

        if candidate.hasPrefix(visibleText) {
            desiredText = candidate
            rebuildPending(for: candidate, now: now)
        } else {
            invalidateRunner()
            let previousVisibleCharacters = Array(visibleText)
            let candidateCharacters = Array(candidate)
            let newVisibleCount = min(previousVisibleCharacters.count, candidateCharacters.count)
            let newVisibleText = String(candidateCharacters.prefix(newVisibleCount))
            let commonPrefix = sharedTextPrefix(visibleText, newVisibleText)
            let previousTail = String(visibleText.dropFirst(commonPrefix.count))
            let replacementTail = String(newVisibleText.dropFirst(commonPrefix.count))
            if previousTail != replacementTail {
                try replaceTrailingText(previousTail, replacementTail)
            }
            visibleText = newVisibleText
            desiredText = candidate
            pending = candidateCharacters.dropFirst(newVisibleCount).map {
                PendingCharacter(character: $0, arrivalNanoseconds: now)
            }
        }

        if !hasSubmittedCharacter, !pending.isEmpty {
            try emitFirstCharacter(now: now)
        }
    }

    private func rebuildPending(for candidate: String, now: UInt64) {
        let newCharacters = Array(candidate.dropFirst(visibleText.count))
        let oldPending = pending
        pending = newCharacters.enumerated().map { index, character in
            if index < oldPending.count, oldPending[index].character == character {
                return oldPending[index]
            }
            return PendingCharacter(character: character, arrivalNanoseconds: now)
        }
    }

    private func emitFirstCharacter(now: UInt64) throws {
        guard !pending.isEmpty else { return }
        if configuration.firstCharacterDelayNanoseconds > 0 {
            guard runnerTask == nil else { return }
            launchRunner(
                kind: .normal,
                initialDelayNanoseconds: configuration.firstCharacterDelayNanoseconds,
                flushTotalCount: 0,
                flushEmittedCount: 0,
                flushStartNanoseconds: 0
            )
            return
        }
        try emitPending(count: 1)
        hasSubmittedCharacter = true
        if pending.isEmpty {
            queueEmptySinceNanoseconds = now
        }
    }

    private func emitPending(count: Int) throws {
        let emitCount = min(count, pending.count)
        guard emitCount > 0 else { return }
        let text = String(pending.prefix(emitCount).map(\.character))
        try append(text)
        pending.removeFirst(emitCount)
        visibleText.append(contentsOf: text)
    }

    private func startFlush() throws {
        guard !pending.isEmpty else {
            isFlushing = false
            queueEmptySinceNanoseconds = clock.nowNanoseconds
            return
        }
        invalidateRunner()
        isFlushing = true
        queueEmptySinceNanoseconds = nil
        let totalCount = pending.count
        let startNanoseconds = clock.nowNanoseconds
        try emitPending(count: 1)
        hasSubmittedCharacter = true
        guard !pending.isEmpty else {
            isFlushing = false
            queueEmptySinceNanoseconds = clock.nowNanoseconds
            return
        }
        launchRunner(
            kind: .flush,
            initialDelayNanoseconds: 0,
            flushTotalCount: totalCount,
            flushEmittedCount: 1,
            flushStartNanoseconds: startNanoseconds
        )
    }

    private func ensureNormalRunner(at now: UInt64) {
        guard !stopping, !pending.isEmpty, runnerTask == nil else { return }
        if let queueEmptySinceNanoseconds {
            let continuityWindow = continuityWindowNanoseconds
            if now >= queueEmptySinceNanoseconds,
               now - queueEmptySinceNanoseconds > continuityWindow {
                currentIntervalNanoseconds = configuration.initialCharacterIntervalNanoseconds
            }
        }
        let reservoirDelay: UInt64 = queueEmptySinceNanoseconds == nil
            ? 0
            : min(configuration.reservoirDelayNanoseconds, timeUntilOldestDeadline(at: now))
        queueEmptySinceNanoseconds = nil
        launchRunner(
            kind: .normal,
            initialDelayNanoseconds: reservoirDelay,
            flushTotalCount: 0,
            flushEmittedCount: 0,
            flushStartNanoseconds: 0
        )
    }

    private func launchRunner(
        kind: RunnerKind,
        initialDelayNanoseconds: UInt64,
        flushTotalCount: Int,
        flushEmittedCount: Int,
        flushStartNanoseconds: UInt64
    ) {
        generation &+= 1
        let token = generation
        runnerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run(
                kind: kind,
                token: token,
                initialDelayNanoseconds: initialDelayNanoseconds,
                flushTotalCount: flushTotalCount,
                flushEmittedCount: flushEmittedCount,
                flushStartNanoseconds: flushStartNanoseconds
            )
        }
    }

    private func run(
        kind: RunnerKind,
        token: UInt64,
        initialDelayNanoseconds: UInt64,
        flushTotalCount: Int,
        flushEmittedCount: Int,
        flushStartNanoseconds: UInt64
    ) async {
        defer {
            if generation == token {
                runnerTask = nil
                let now = clock.nowNanoseconds
                if pending.isEmpty {
                    queueEmptySinceNanoseconds = now
                    isFlushing = false
                } else if kind == .flush {
                    isFlushing = false
                    queueEmptySinceNanoseconds = now
                    ensureNormalRunner(at: now)
                }
            }
        }

        do {
            if initialDelayNanoseconds > 0 {
                try await clock.sleep(nanoseconds: initialDelayNanoseconds)
            }
            guard generation == token, !Task.isCancelled else { return }
            switch kind {
            case .normal:
                try await runNormal(token: token)
            case .flush:
                try await runFlush(
                    token: token,
                    totalCount: flushTotalCount,
                    emittedCount: flushEmittedCount,
                    startNanoseconds: flushStartNanoseconds
                )
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == token else { return }
            lastError = error
            runnerTask = nil
            isFlushing = false
            onFailure(error)
        }
    }

    private func runNormal(token: UInt64) async throws {
        if !hasSubmittedCharacter, !pending.isEmpty {
            try emitPending(count: 1)
            hasSubmittedCharacter = true
            if pending.isEmpty {
                queueEmptySinceNanoseconds = clock.nowNanoseconds
            }
        }

        while generation == token, !Task.isCancelled, !pending.isEmpty {
            let now = clock.nowNanoseconds
            let waitNanoseconds = normalWaitNanoseconds(at: now)
            if waitNanoseconds > 0 {
                try await clock.sleep(nanoseconds: waitNanoseconds)
            }
            guard generation == token, !Task.isCancelled else { return }
            let emitCount = normalEmitCount(at: clock.nowNanoseconds)
            try emitPending(count: emitCount)
        }
    }

    private func runFlush(
        token: UInt64,
        totalCount: Int,
        emittedCount: Int,
        startNanoseconds: UInt64
    ) async throws {
        var emitted = emittedCount
        let duration = min(
            configuration.finalFlushMaximumDurationNanoseconds,
            max(
                configuration.frameIntervalNanoseconds,
                currentIntervalNanoseconds * UInt64(max(totalCount, 1))
            )
        )

        if emitted < totalCount {
            try await clock.sleep(
                nanoseconds: min(
                    configuration.frameIntervalNanoseconds,
                    duration
                )
            )
        }

        while generation == token, !Task.isCancelled, emitted < totalCount {
            let now = clock.nowNanoseconds
            let elapsed = now >= startNanoseconds ? now - startNanoseconds : 0
            if elapsed >= duration {
                try emitPending(count: pending.count)
                return
            }
            let progress = Double(elapsed) / Double(duration)
            let easedProgress = 1 - pow(1 - progress, configuration.easeOutExponent)
            let targetCount = min(
                totalCount,
                max(emitted + 1, Int(ceil(Double(totalCount) * easedProgress)))
            )
            let dueCount = targetCount - emitted
            if dueCount > 0 {
                try emitPending(count: dueCount)
                emitted += dueCount
                guard emitted < totalCount else { return }
                let remaining = duration - elapsed
                try await clock.sleep(
                    nanoseconds: min(
                        configuration.frameIntervalNanoseconds,
                        remaining
                    )
                )
                continue
            }
            try await clock.sleep(
                nanoseconds: min(
                    configuration.frameIntervalNanoseconds,
                    duration - elapsed
                )
            )
        }
    }

    private func normalWaitNanoseconds(at now: UInt64) -> UInt64 {
        let targetInterval = targetIntervalNanoseconds(at: now)
        currentIntervalNanoseconds = moveInterval(
            currentIntervalNanoseconds,
            toward: targetInterval
        )
        let deadlineRemaining = timeUntilOldestDeadline(at: now)
        return min(currentIntervalNanoseconds, deadlineRemaining)
    }

    private func normalEmitCount(at now: UInt64) -> Int {
        guard !pending.isEmpty else { return 0 }
        let deadlineRemaining = timeUntilOldestDeadline(at: now)
        guard deadlineRemaining > 0 else { return pending.count }
        let perCharacterDeadline = max(1, deadlineRemaining / UInt64(pending.count))
        guard perCharacterDeadline < configuration.minimumCharacterIntervalNanoseconds else {
            return 1
        }
        let count = Int(ceil(
            Double(configuration.minimumCharacterIntervalNanoseconds)
                / Double(perCharacterDeadline)
        ))
        return min(max(count, 1), pending.count)
    }

    private func targetIntervalNanoseconds(at now: UInt64) -> UInt64 {
        guard !pending.isEmpty else {
            return configuration.initialCharacterIntervalNanoseconds
        }
        let count = UInt64(pending.count)
        let cadenceHorizon = min(
            configuration.normalMaximumLagNanoseconds,
            UInt64(partialCadenceNanoseconds * configuration.cadenceFillRatio)
        )
        let cadenceInterval = max(1, cadenceHorizon / count)
        let deadlineInterval = max(1, timeUntilOldestDeadline(at: now) / count)
        return min(
            max(configuration.minimumCharacterIntervalNanoseconds, min(cadenceInterval, deadlineInterval)),
            configuration.maximumCharacterIntervalNanoseconds
        )
    }

    private func timeUntilOldestDeadline(at now: UInt64) -> UInt64 {
        guard let oldest = pending.first else { return 0 }
        let deadline = oldest.arrivalNanoseconds + configuration.normalMaximumLagNanoseconds
        return deadline > now ? deadline - now : 0
    }

    private var continuityWindowNanoseconds: UInt64 {
        let proposed = UInt64(partialCadenceNanoseconds * 1.25)
        return min(
            configuration.continuityMaximumNanoseconds,
            max(configuration.continuityMinimumNanoseconds, proposed)
        )
    }

    private func moveInterval(_ current: UInt64, toward target: UInt64) -> UInt64 {
        guard current > 0 else { return target }
        let maximumStep = max(1, UInt64(Double(current) * configuration.velocityChangeLimit))
        if target > current {
            return min(target, current + maximumStep)
        }
        return max(target, current > maximumStep ? current - maximumStep : 0)
    }

    private func updatePartialCadence(at now: UInt64) {
        if let lastPartialArrivalNanoseconds,
           now > lastPartialArrivalNanoseconds {
            let interval = Double(now - lastPartialArrivalNanoseconds)
            let alpha = configuration.ewmaAlpha
            partialCadenceNanoseconds = alpha * interval
                + (1 - alpha) * partialCadenceNanoseconds
        }
        lastPartialArrivalNanoseconds = now
    }

    private func invalidateRunner() {
        generation &+= 1
        runnerTask?.cancel()
        runnerTask = nil
    }

    private func sharedTextPrefix(_ lhs: String, _ rhs: String) -> String {
        var prefix = ""
        for (lhsCharacter, rhsCharacter) in zip(lhs, rhs) {
            guard lhsCharacter == rhsCharacter else { break }
            prefix.append(lhsCharacter)
        }
        return prefix
    }
}
