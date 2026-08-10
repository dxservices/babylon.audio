import Foundation

@available(iOS 18, macOS 13, *)
public enum AudioProcessorFormatBehavior: Equatable, Sendable {
    case preservesInput
    case changesTo(AudioStreamFormat)
}

@available(iOS 18, macOS 13, *)
public struct AudioFrameProcessorDeclaration: Equatable, Sendable {
    public let algorithmicWindow: Duration
    public let maximumInternalBufferDuration: Duration
    public let maximumOutputFrameCount: Int
    public let formatBehavior: AudioProcessorFormatBehavior
    public let retainsSensitiveState: Bool

    public init(
        algorithmicWindow: Duration,
        maximumInternalBufferDuration: Duration,
        maximumOutputFrameCount: Int,
        formatBehavior: AudioProcessorFormatBehavior,
        retainsSensitiveState: Bool
    ) {
        self.algorithmicWindow = algorithmicWindow
        self.maximumInternalBufferDuration = maximumInternalBufferDuration
        self.maximumOutputFrameCount = maximumOutputFrameCount
        self.formatBehavior = formatBehavior
        self.retainsSensitiveState = retainsSensitiveState
    }
}

@available(iOS 18, macOS 13, *)
public struct AudioProcessorBudget: Equatable, Sendable {
    public let maximumAlgorithmicWindow: Duration
    public let maximumInternalBufferDuration: Duration
    public let maximumOutputFrameCountPerInput: Int
    /// A post-return limit check; it cannot interrupt a blocking synchronous processor.
    public let maximumProcessingDuration: Duration

    public init(
        maximumAlgorithmicWindow: Duration,
        maximumInternalBufferDuration: Duration,
        maximumOutputFrameCountPerInput: Int,
        maximumProcessingDuration: Duration
    ) {
        self.maximumAlgorithmicWindow = maximumAlgorithmicWindow
        self.maximumInternalBufferDuration = maximumInternalBufferDuration
        self.maximumOutputFrameCountPerInput = maximumOutputFrameCountPerInput
        self.maximumProcessingDuration = maximumProcessingDuration
    }
}

@available(iOS 18, macOS 13, *)
public protocol AudioFrameProcessor: Sendable {
    var declaration: AudioFrameProcessorDeclaration { get }

    mutating func process(
        _ frame: AudioFrame,
        emit: @Sendable (AudioFrame) -> Void
    ) throws

    mutating func reset()
}

@available(iOS 18, macOS 13, *)
/// Runs synchronously on the caller's dedicated serial processing executor.
/// Processing-duration overruns are detected only after a processor returns.
public struct AudioFrameProcessorChain: Sendable {
    public let budget: AudioProcessorBudget

    private var processors: [any AudioFrameProcessor]
    private let clock: AudioMonotonicClock

    public init(
        processors: [any AudioFrameProcessor],
        budget: AudioProcessorBudget,
        clock: AudioMonotonicClock = .continuous()
    ) throws {
        guard budget.maximumAlgorithmicWindow >= .zero,
              budget.maximumInternalBufferDuration >= .zero,
              budget.maximumOutputFrameCountPerInput >= 0,
              budget.maximumProcessingDuration >= .zero
        else {
            throw AudioProcessingError.invalidBudget
        }

        for (index, processor) in processors.enumerated() {
            let declaration = processor.declaration
            guard declaration.algorithmicWindow >= .zero,
                  declaration.maximumInternalBufferDuration >= .zero,
                  declaration.maximumOutputFrameCount >= 0
            else {
                throw AudioProcessingError.invalidDeclaration(index: index)
            }
            guard declaration.algorithmicWindow <= budget.maximumAlgorithmicWindow,
                  declaration.maximumInternalBufferDuration
                    <= budget.maximumInternalBufferDuration,
                  declaration.maximumOutputFrameCount
                    <= budget.maximumOutputFrameCountPerInput
            else {
                throw AudioProcessingError.processorExceedsBudget(index: index)
            }
        }

        self.processors = processors
        self.budget = budget
        self.clock = clock
    }

    public mutating func process(_ frame: AudioFrame) throws -> [AudioFrame] {
        var stageInput = [frame]

        for index in processors.indices {
            var stageOutput: [AudioFrame] = []
            stageOutput.reserveCapacity(min(
                budget.maximumOutputFrameCountPerInput,
                processors[index].declaration.maximumOutputFrameCount
            ))

            for input in stageInput {
                let declaration = processors[index].declaration
                let collector = ProcessorOutputCollector(
                    maximumFrameCount: declaration.maximumOutputFrameCount
                )
                let start = clock.now()
                do {
                    try processors[index].process(input) { output in
                        collector.append(output)
                    }
                } catch {
                    throw AudioProcessingError.processorFailed(index: index)
                }
                let elapsed = max(Duration.zero, clock.now() - start)

                if elapsed > budget.maximumProcessingDuration {
                    throw AudioProcessingError.processingTimedOut(
                        index: index,
                        elapsed: elapsed,
                        budget: budget.maximumProcessingDuration
                    )
                }
                if collector.didOverflow {
                    throw AudioProcessingError.outputLimitExceeded(
                        index: index,
                        maximum: declaration.maximumOutputFrameCount
                    )
                }

                let emittedFrames = collector.frames
                for output in emittedFrames {
                    guard output.flowID == input.flowID else {
                        throw AudioProcessingError.unexpectedOutputFlow(index: index)
                    }
                    guard Self.matches(
                        output.format,
                        inputFormat: input.format,
                        behavior: declaration.formatBehavior
                    ) else {
                        throw AudioProcessingError.unexpectedOutputFormat(index: index)
                    }
                    guard stageOutput.count < budget.maximumOutputFrameCountPerInput else {
                        throw AudioProcessingError.outputLimitExceeded(
                            index: index,
                            maximum: budget.maximumOutputFrameCountPerInput
                        )
                    }
                    stageOutput.append(output)
                }
            }

            stageInput = stageOutput
            if stageInput.isEmpty {
                break
            }
        }

        return stageInput
    }

    public mutating func reset() {
        for index in processors.indices {
            processors[index].reset()
        }
    }

    private static func matches(
        _ outputFormat: AudioStreamFormat,
        inputFormat: AudioStreamFormat,
        behavior: AudioProcessorFormatBehavior
    ) -> Bool {
        switch behavior {
        case .preservesInput:
            outputFormat == inputFormat
        case let .changesTo(expectedFormat):
            outputFormat == expectedFormat
        }
    }
}

@available(iOS 18, macOS 13, *)
public enum AudioProcessingError: Error, Equatable, Sendable {
    case invalidBudget
    case invalidDeclaration(index: Int)
    case processorExceedsBudget(index: Int)
    case processorFailed(index: Int)
    case processingTimedOut(index: Int, elapsed: Duration, budget: Duration)
    case outputLimitExceeded(index: Int, maximum: Int)
    case unexpectedOutputFlow(index: Int)
    case unexpectedOutputFormat(index: Int)
}

@available(iOS 18, macOS 13, *)
private final class ProcessorOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumFrameCount: Int
    private var storedFrames: [AudioFrame] = []
    private var overflow = false

    var frames: [AudioFrame] {
        lock.lock()
        defer { lock.unlock() }
        return storedFrames
    }

    var didOverflow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return overflow
    }

    init(maximumFrameCount: Int) {
        self.maximumFrameCount = maximumFrameCount
        storedFrames.reserveCapacity(maximumFrameCount)
    }

    func append(_ frame: AudioFrame) {
        lock.lock()
        defer { lock.unlock() }
        guard storedFrames.count < maximumFrameCount else {
            overflow = true
            return
        }
        storedFrames.append(frame)
    }
}
