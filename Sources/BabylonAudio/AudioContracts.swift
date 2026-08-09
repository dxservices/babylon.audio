import Foundation

public struct AudioFlowID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum SampleEncoding: Equatable, Sendable {
    case signedPCM16LittleEndian
    case float32
}

public enum Interleaving: Equatable, Sendable {
    case interleaved
    case nonInterleaved
}

@available(iOS 18, macOS 13, *)
public struct AudioStreamFormat: Equatable, Sendable {
    public let sampleRate: Double
    public let channelCount: Int
    public let sampleEncoding: SampleEncoding
    public let interleaving: Interleaving

    public var bytesPerSample: Int {
        switch sampleEncoding {
        case .signedPCM16LittleEndian:
            2
        case .float32:
            4
        }
    }

    public var bytesPerFrame: Int {
        bytesPerSample * channelCount
    }

    public init(
        sampleRate: Double,
        channelCount: Int,
        sampleEncoding: SampleEncoding,
        interleaving: Interleaving
    ) throws {
        guard Self.isSupported(sampleRate: sampleRate) else {
            throw AudioContractError.unsupportedSampleRate(sampleRate)
        }
        guard (1...2).contains(channelCount) else {
            throw AudioContractError.unsupportedChannelCount(channelCount)
        }

        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.sampleEncoding = sampleEncoding
        self.interleaving = interleaving
    }

    public static func monoPCM16(sampleRate: Double) throws -> Self {
        try Self(
            sampleRate: sampleRate,
            channelCount: 1,
            sampleEncoding: .signedPCM16LittleEndian,
            interleaving: .interleaved
        )
    }

    public func duration(forPayloadByteCount byteCount: Int) throws -> Duration {
        guard byteCount > 0 else {
            throw AudioContractError.emptyPayload
        }
        guard byteCount.isMultiple(of: bytesPerFrame) else {
            throw AudioContractError.payloadNotFrameAligned(
                byteCount: byteCount,
                bytesPerFrame: bytesPerFrame
            )
        }

        let sampleFrameCount = byteCount / bytesPerFrame
        return .seconds(Double(sampleFrameCount) / sampleRate)
    }

    private static func isSupported(sampleRate: Double) -> Bool {
        switch sampleRate {
        case 16_000, 24_000, 44_100, 48_000:
            true
        default:
            false
        }
    }
}

@available(iOS 18, macOS 13, *)
public struct AudioFrame: Equatable, Sendable {
    public let flowID: AudioFlowID
    public let sequence: UInt64
    /// Monotonic time relative to the start of this frame's flow.
    public let timestamp: Duration
    public let format: AudioStreamFormat
    /// Immutable frame bytes. Planar channel payloads store complete planes in channel order.
    public let payload: Data
    public let duration: Duration

    public init(
        flowID: AudioFlowID,
        sequence: UInt64,
        timestamp: Duration,
        format: AudioStreamFormat,
        payload: Data,
        duration: Duration
    ) throws {
        guard timestamp >= .zero else {
            throw AudioContractError.negativeTimestamp(timestamp)
        }

        let expectedDuration = try format.duration(forPayloadByteCount: payload.count)
        guard duration == expectedDuration else {
            throw AudioContractError.durationMismatch(
                expected: expectedDuration,
                actual: duration
            )
        }

        self.flowID = flowID
        self.sequence = sequence
        self.timestamp = timestamp
        self.format = format
        self.payload = payload
        self.duration = duration
    }
}

@available(iOS 18, macOS 13, *)
public enum AudioContractError: Error, Equatable, Sendable {
    case unsupportedSampleRate(Double)
    case unsupportedChannelCount(Int)
    case emptyPayload
    case payloadNotFrameAligned(byteCount: Int, bytesPerFrame: Int)
    case durationMismatch(expected: Duration, actual: Duration)
    case negativeTimestamp(Duration)
    case noPipelineDirection
    case sourceRequired
    case unusedSource
    case incompleteDownlink
    case invalidMicrophoneInputPolicy
    case invalidDeviceOutputPolicy
}
