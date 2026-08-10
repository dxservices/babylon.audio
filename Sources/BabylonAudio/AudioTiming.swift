import Foundation

@available(iOS 18, macOS 13, *)
public struct AudioMonotonicClock: Sendable {
    private let nowImplementation: @Sendable () -> Duration

    public init(now: @escaping @Sendable () -> Duration) {
        nowImplementation = now
    }

    public static func continuous() -> Self {
        let clock = ContinuousClock()
        let origin = clock.now
        return Self {
            origin.duration(to: clock.now)
        }
    }

    public func now() -> Duration {
        nowImplementation()
    }
}

@available(iOS 18, macOS 13, *)
public actor AudioFrameSequencer {
    public let flowID: AudioFlowID

    private let clock: AudioMonotonicClock
    private var nextSequence: UInt64 = 0
    private var lastTimestamp: Duration = .zero

    public init(
        flowID: AudioFlowID,
        clock: AudioMonotonicClock = .continuous()
    ) {
        self.flowID = flowID
        self.clock = clock
    }

    public func makeFrame(
        format: AudioStreamFormat,
        payload: Data
    ) throws -> AudioFrame {
        guard nextSequence < UInt64.max else {
            throw AudioCoreError.sequenceExhausted
        }

        let timestamp = max(lastTimestamp, clock.now())
        let duration = try format.duration(forPayloadByteCount: payload.count)
        let frame = try AudioFrame(
            flowID: flowID,
            sequence: nextSequence,
            timestamp: timestamp,
            format: format,
            payload: payload,
            duration: duration
        )
        nextSequence += 1
        lastTimestamp = timestamp
        return frame
    }
}

public enum AudioCoreError: Error, Equatable, Sendable {
    case sequenceExhausted
}
