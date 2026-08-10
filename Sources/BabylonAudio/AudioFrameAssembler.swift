import Foundation

@available(iOS 18, macOS 13, *)
public struct AudioFrameAssembler: Sendable {
    public let flowID: AudioFlowID
    public let format: AudioStreamFormat
    public let frameDuration: Duration
    /// Maximum total staged audio accepted by one append, including pending bytes.
    public let maximumBufferedDuration: Duration
    public let maximumFramesPerAppend: Int

    public private(set) var nextSequence: UInt64 = 0
    public var bufferedByteCount: Int { bufferedBytes.count }

    private let frameByteCount: Int
    private let maximumBufferedByteCount: Int
    private var nextTimestamp: Duration = .zero
    private var bufferedBytes = Data()

    public init(
        flowID: AudioFlowID,
        format: AudioStreamFormat,
        frameDuration: Duration,
        maximumBufferedDuration: Duration,
        maximumFramesPerAppend: Int
    ) throws {
        let sampleFrameCount = try Self.sampleFrameCount(
            for: frameDuration,
            sampleRate: format.sampleRate
        )
        let (frameByteCount, didOverflow) = sampleFrameCount.multipliedReportingOverflow(
            by: format.bytesPerFrame
        )
        guard !didOverflow else {
            throw AudioAssemblerError.invalidConfiguration
        }
        let maximumBufferedSampleFrameCount = try Self.sampleFrameCount(
            for: maximumBufferedDuration,
            sampleRate: format.sampleRate
        )
        let (maximumBufferedByteCount, maximumDidOverflow) =
            maximumBufferedSampleFrameCount.multipliedReportingOverflow(
                by: format.bytesPerFrame
            )
        guard !maximumDidOverflow else {
            throw AudioAssemblerError.invalidConfiguration
        }
        let validatedDuration = try format.duration(forPayloadByteCount: frameByteCount)
        guard validatedDuration == frameDuration,
              maximumBufferedSampleFrameCount >= sampleFrameCount,
              maximumFramesPerAppend > 0
        else {
            throw AudioAssemblerError.invalidConfiguration
        }

        self.flowID = flowID
        self.format = format
        self.frameDuration = frameDuration
        self.maximumBufferedDuration = maximumBufferedDuration
        self.maximumFramesPerAppend = maximumFramesPerAppend
        self.frameByteCount = frameByteCount
        self.maximumBufferedByteCount = maximumBufferedByteCount
        bufferedBytes.reserveCapacity(frameByteCount)
    }

    public mutating func append(_ bytes: Data) throws -> [AudioFrame] {
        let (totalByteCount, didOverflow) = bufferedBytes.count.addingReportingOverflow(
            bytes.count
        )
        guard !didOverflow else {
            throw AudioAssemblerError.bufferDurationLimitExceeded(
                maximum: maximumBufferedDuration
            )
        }
        guard totalByteCount <= maximumBufferedByteCount else {
            throw AudioAssemblerError.bufferDurationLimitExceeded(
                maximum: maximumBufferedDuration
            )
        }
        let outputFrameCount = totalByteCount / frameByteCount
        guard outputFrameCount <= maximumFramesPerAppend else {
            throw AudioAssemblerError.appendLimitExceeded(
                maximumFrames: maximumFramesPerAppend
            )
        }
        guard UInt64(outputFrameCount) <= UInt64.max - nextSequence else {
            throw AudioAssemblerError.sequenceExhausted
        }

        var combined = bufferedBytes
        combined.append(bytes)
        var frames: [AudioFrame] = []
        frames.reserveCapacity(outputFrameCount)

        for index in 0..<outputFrameCount {
            let lowerBound = index * frameByteCount
            let upperBound = lowerBound + frameByteCount
            let payload = Data(combined[lowerBound..<upperBound])
            frames.append(try AudioFrame(
                flowID: flowID,
                sequence: nextSequence + UInt64(index),
                timestamp: nextTimestamp + frameDuration * index,
                format: format,
                payload: payload,
                duration: frameDuration
            ))
        }

        let consumedByteCount = outputFrameCount * frameByteCount
        bufferedBytes = Data(combined.dropFirst(consumedByteCount))
        nextSequence += UInt64(outputFrameCount)
        nextTimestamp += frameDuration * outputFrameCount
        return frames
    }

    public mutating func reset() {
        bufferedBytes.removeAll(keepingCapacity: true)
    }

    private static func sampleFrameCount(
        for duration: Duration,
        sampleRate: Double
    ) throws -> Int {
        guard duration > .zero else {
            throw AudioAssemblerError.invalidConfiguration
        }
        let components = duration.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1e18
        let exactCount = seconds * sampleRate
        let roundedCount = exactCount.rounded()
        guard roundedCount > 0,
              abs(exactCount - roundedCount) < 1e-7,
              roundedCount <= Double(Int.max)
        else {
            throw AudioAssemblerError.invalidConfiguration
        }
        return Int(roundedCount)
    }
}

@available(iOS 18, macOS 13, *)
public enum AudioAssemblerError: Error, Equatable, Sendable {
    case invalidConfiguration
    case bufferDurationLimitExceeded(maximum: Duration)
    case appendLimitExceeded(maximumFrames: Int)
    case sequenceExhausted
}
