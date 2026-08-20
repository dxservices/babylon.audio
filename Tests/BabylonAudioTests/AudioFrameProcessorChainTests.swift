import Foundation
import Testing
@testable import BabylonAudio

@Suite("Synchronous processor chain")
struct AudioFrameProcessorChainTests {
    @Test("Processors run in order and can emit zero, one, or many frames")
    func processorsRunInOrder() throws {
        let frame = try makeFrame(firstByte: 1)
        var ordered = try makeChain([
            IncrementProcessor(amount: 2),
            IncrementProcessor(amount: 4),
        ])
        var dropping = try makeChain([DropProcessor()])
        var duplicating = try makeChain([DuplicateProcessor()])

        let orderedOutput = try ordered.process(frame)
        let droppedOutput = try dropping.process(frame)
        let duplicatedOutput = try duplicating.process(frame)

        #expect(orderedOutput.count == 1)
        #expect(orderedOutput[0].payload.first == 7)
        #expect(droppedOutput.isEmpty)
        #expect(duplicatedOutput.count == 2)
    }

    @Test("Caller budget rejects oversized processor declarations")
    func callerBudgetRejectsOversizedDeclaration() {
        #expect(throws: AudioProcessingError.processorExceedsBudget(index: 0)) {
            try AudioFrameProcessorChain(
                processors: [WideWindowProcessor()],
                budget: .init(
                    maximumAlgorithmicWindow: .milliseconds(20),
                    maximumInternalBufferDuration: .milliseconds(40),
                    maximumOutputFrameCountPerInput: 4,
                    maximumProcessingDuration: .milliseconds(5)
                )
            )
        }
    }

    @Test("Processor failure and timeout discard staged output")
    func failureAndTimeoutDiscardOutput() throws {
        let frame = try makeFrame(firstByte: 1)
        var failing = try makeChain([EmitThenFailProcessor()])
        let timeSource = ScriptedProcessorTimeSource([.zero, .milliseconds(6)])
        let timeoutBudget = AudioProcessorBudget(
            maximumAlgorithmicWindow: .milliseconds(40),
            maximumInternalBufferDuration: .milliseconds(80),
            maximumOutputFrameCountPerInput: 4,
            maximumProcessingDuration: .milliseconds(5)
        )
        var timingOut = try AudioFrameProcessorChain(
            processors: [IncrementProcessor(amount: 1)],
            budget: timeoutBudget,
            clock: AudioMonotonicClock(now: { timeSource.next() })
        )

        do {
            _ = try failing.process(frame)
            Issue.record("Expected the processor to fail")
        } catch let failure as AudioProcessorFailure {
            #expect(failure.index == 0)
            #expect(failure.underlyingError is ProcessorTestError)
        } catch {
            Issue.record("Expected AudioProcessorFailure, got \(type(of: error))")
        }
        #expect(throws: AudioProcessingError.processingTimedOut(
            index: 0,
            elapsed: .milliseconds(6),
            budget: .milliseconds(5)
        )) {
            try timingOut.process(frame)
        }
    }

    @Test("Output count and declared format changes are enforced")
    func outputAndFormatContractsAreEnforced() throws {
        let frame = try makeFrame(firstByte: 1)
        var tooMany = try makeChain([TooManyOutputsProcessor()])
        var formatLiar = try makeChain([UndeclaredFormatChangeProcessor()])
        var formatChanger = try makeChain([DeclaredFormatChangeProcessor()])

        #expect(throws: AudioProcessingError.outputLimitExceeded(
            index: 0,
            maximum: 4
        )) {
            try tooMany.process(frame)
        }
        #expect(throws: AudioProcessingError.unexpectedOutputFormat(index: 0)) {
            try formatLiar.process(frame)
        }
        #expect(
            formatChanger.outputFormat(for: frame.format).sampleRate == 16_000
        )
        #expect(try formatChanger.process(frame).first?.format.sampleRate == 16_000)
    }

    @Test("Reset clears processor state")
    func resetClearsProcessorState() throws {
        let frame = try makeFrame(firstByte: 1)
        var chain = try makeChain([PairBufferProcessor()])

        #expect(try chain.process(frame).isEmpty)
        #expect(try chain.process(frame).count == 1)
        chain.reset()
        #expect(try chain.process(frame).isEmpty)
    }

    private var standardBudget: AudioProcessorBudget {
        .init(
            maximumAlgorithmicWindow: .milliseconds(40),
            maximumInternalBufferDuration: .milliseconds(80),
            maximumOutputFrameCountPerInput: 4,
            maximumProcessingDuration: .seconds(1)
        )
    }

    private func makeChain(
        _ processors: [any AudioFrameProcessor]
    ) throws -> AudioFrameProcessorChain {
        try AudioFrameProcessorChain(processors: processors, budget: standardBudget)
    }

    private func makeFrame(firstByte: UInt8) throws -> AudioFrame {
        var payload = Data(count: 960)
        payload[0] = firstByte
        return try AudioFrame(
            flowID: AudioFlowID(),
            sequence: 0,
            timestamp: .zero,
            format: .monoPCM16(sampleRate: 24_000),
            payload: payload,
            duration: .milliseconds(20)
        )
    }
}

private let preservingDeclaration = AudioFrameProcessorDeclaration(
    algorithmicWindow: .zero,
    maximumInternalBufferDuration: .zero,
    maximumOutputFrameCount: 1,
    formatBehavior: .preservesInput,
    retainsSensitiveState: false
)

private struct IncrementProcessor: AudioFrameProcessor {
    let amount: UInt8
    let declaration = preservingDeclaration

    mutating func process(
        _ frame: AudioFrame,
        emit: @Sendable (AudioFrame) -> Void
    ) throws {
        var payload = frame.payload
        payload[0] += amount
        emit(try AudioFrame(
            flowID: frame.flowID,
            sequence: frame.sequence,
            timestamp: frame.timestamp,
            format: frame.format,
            payload: payload,
            duration: frame.duration
        ))
    }

    mutating func reset() {}
}

private struct DropProcessor: AudioFrameProcessor {
    let declaration = AudioFrameProcessorDeclaration(
        algorithmicWindow: .zero,
        maximumInternalBufferDuration: .zero,
        maximumOutputFrameCount: 0,
        formatBehavior: .preservesInput,
        retainsSensitiveState: false
    )

    mutating func process(
        _ frame: AudioFrame,
        emit: @Sendable (AudioFrame) -> Void
    ) throws {}

    mutating func reset() {}
}

private struct DuplicateProcessor: AudioFrameProcessor {
    let declaration = AudioFrameProcessorDeclaration(
        algorithmicWindow: .zero,
        maximumInternalBufferDuration: .zero,
        maximumOutputFrameCount: 2,
        formatBehavior: .preservesInput,
        retainsSensitiveState: false
    )

    mutating func process(
        _ frame: AudioFrame,
        emit: @Sendable (AudioFrame) -> Void
    ) throws {
        emit(frame)
        emit(frame)
    }

    mutating func reset() {}
}

private struct WideWindowProcessor: AudioFrameProcessor {
    let declaration = AudioFrameProcessorDeclaration(
        algorithmicWindow: .milliseconds(21),
        maximumInternalBufferDuration: .zero,
        maximumOutputFrameCount: 1,
        formatBehavior: .preservesInput,
        retainsSensitiveState: false
    )

    mutating func process(
        _ frame: AudioFrame,
        emit: @Sendable (AudioFrame) -> Void
    ) throws { emit(frame) }

    mutating func reset() {}
}

private struct EmitThenFailProcessor: AudioFrameProcessor {
    let declaration = preservingDeclaration

    mutating func process(
        _ frame: AudioFrame,
        emit: @Sendable (AudioFrame) -> Void
    ) throws {
        emit(frame)
        throw ProcessorTestError.expected
    }

    mutating func reset() {}
}

private struct TooManyOutputsProcessor: AudioFrameProcessor {
    let declaration = AudioFrameProcessorDeclaration(
        algorithmicWindow: .zero,
        maximumInternalBufferDuration: .zero,
        maximumOutputFrameCount: 4,
        formatBehavior: .preservesInput,
        retainsSensitiveState: false
    )

    mutating func process(
        _ frame: AudioFrame,
        emit: @Sendable (AudioFrame) -> Void
    ) throws {
        for _ in 0..<5 { emit(frame) }
    }

    mutating func reset() {}
}

private struct UndeclaredFormatChangeProcessor: AudioFrameProcessor {
    let declaration = preservingDeclaration

    mutating func process(
        _ frame: AudioFrame,
        emit: @Sendable (AudioFrame) -> Void
    ) throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 16_000)
        emit(try AudioFrame(
            flowID: frame.flowID,
            sequence: frame.sequence,
            timestamp: frame.timestamp,
            format: format,
            payload: Data(count: 640),
            duration: .milliseconds(20)
        ))
    }

    mutating func reset() {}
}

private struct DeclaredFormatChangeProcessor: AudioFrameProcessor {
    let declaration: AudioFrameProcessorDeclaration

    init() throws {
        declaration = AudioFrameProcessorDeclaration(
            algorithmicWindow: .zero,
            maximumInternalBufferDuration: .zero,
            maximumOutputFrameCount: 1,
            formatBehavior: .changesTo(
                try AudioStreamFormat.monoPCM16(sampleRate: 16_000)
            ),
            retainsSensitiveState: false
        )
    }

    mutating func process(
        _ frame: AudioFrame,
        emit: @Sendable (AudioFrame) -> Void
    ) throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 16_000)
        emit(try AudioFrame(
            flowID: frame.flowID,
            sequence: frame.sequence,
            timestamp: frame.timestamp,
            format: format,
            payload: Data(count: 640),
            duration: .milliseconds(20)
        ))
    }

    mutating func reset() {}
}

private struct PairBufferProcessor: AudioFrameProcessor {
    let declaration = AudioFrameProcessorDeclaration(
        algorithmicWindow: .milliseconds(40),
        maximumInternalBufferDuration: .milliseconds(20),
        maximumOutputFrameCount: 1,
        formatBehavior: .preservesInput,
        retainsSensitiveState: false
    )
    private var bufferedFrame: AudioFrame?

    mutating func process(
        _ frame: AudioFrame,
        emit: @Sendable (AudioFrame) -> Void
    ) throws {
        if bufferedFrame == nil {
            bufferedFrame = frame
        } else {
            bufferedFrame = nil
            emit(frame)
        }
    }

    mutating func reset() {
        bufferedFrame = nil
    }
}

private enum ProcessorTestError: Error {
    case expected
}

private final class ScriptedProcessorTimeSource: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Duration]

    init(_ values: [Duration]) {
        self.values = values
    }

    func next() -> Duration {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty ? .zero : values.removeFirst()
    }
}
