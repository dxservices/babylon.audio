import Foundation

@available(iOS 18, macOS 13, *)
final class AudioPipelineEventDeliveryToken: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    var isActive: Bool {
        lock.withLock { active }
    }

    func deactivate() {
        lock.withLock { active = false }
    }
}

@available(iOS 18, macOS 13, *)
enum AudioPipelineEventDeliveryContext {
    @TaskLocal static var token: AudioPipelineEventDeliveryToken?

    static var isDirectDelivery: Bool {
        token?.isActive == true
    }
}

public enum AudioFlowStopReason: Equatable, Sendable {
    case consumerRequested
    case replaced
    case sourceEnded
    case safetyBoundary
    case endpointFailure
}

@available(iOS 18, macOS 13, *)
public enum AudioEvent: Equatable, Sendable {
    case flowStarted(flowID: AudioFlowID)
    case flowStopped(flowID: AudioFlowID, reason: AudioFlowStopReason)
    case endpointEnded(flowID: AudioFlowID, direction: AudioDirection)
    case endpointFailed(flowID: AudioFlowID, direction: AudioDirection)
}

@available(iOS 18, macOS 13, *)
public protocol AudioEventSink: Sendable {
    func receive(_ event: AudioEvent) async
}

public enum AudioDirection: Equatable, Sendable {
    case source
    case localMonitor
    case uplink
    case downlink
}

public enum AudioDiscardReason: Equatable, Sendable {
    case overflow
    case expired
    case staleFlow
    case outOfOrder
    case sourceEnded
    case stopped
    case endpointFailure
    case processingFailure
}

@available(iOS 18, macOS 13, *)
public enum AudioDiagnosticEvent: Equatable, Sendable {
    case queueDiscarded(
        flowID: AudioFlowID,
        direction: AudioDirection,
        reason: AudioDiscardReason,
        frameCount: Int,
        duration: Duration
    )
    case latency(
        flowID: AudioFlowID,
        direction: AudioDirection,
        duration: Duration
    )
    case formatConverted(
        flowID: AudioFlowID,
        input: AudioStreamFormat,
        output: AudioStreamFormat
    )
    case rebuffered(flowID: AudioFlowID, bufferedDuration: Duration)
}

@available(iOS 18, macOS 13, *)
public protocol AudioDiagnosticSink: Sendable {
    /// Receives structured metrics that never include audio or application content.
    func record(_ event: AudioDiagnosticEvent) async
}

public enum AudioPipelineState: Equatable, Sendable {
    case idle
    case running
    case stopped
}

@available(iOS 18, macOS 13, *)
public struct AudioQueueSnapshot: Equatable, Sendable {
    public static let zero = Self(frameCount: 0, duration: .zero)

    public let frameCount: Int
    public let duration: Duration

    public init(frameCount: Int, duration: Duration) {
        self.frameCount = frameCount
        self.duration = duration
    }
}

@available(iOS 18, macOS 13, *)
public struct AudioPipelineSnapshot: Equatable, Sendable {
    public let flowID: AudioFlowID?
    public let state: AudioPipelineState
    public let sourceFormat: AudioStreamFormat?
    public let uplink: AudioQueueSnapshot
    public let downlink: AudioQueueSnapshot
    public let discardedFrameCount: UInt64

    public init(
        flowID: AudioFlowID?,
        state: AudioPipelineState,
        sourceFormat: AudioStreamFormat?,
        uplink: AudioQueueSnapshot,
        downlink: AudioQueueSnapshot,
        discardedFrameCount: UInt64
    ) {
        self.flowID = flowID
        self.state = state
        self.sourceFormat = sourceFormat
        self.uplink = uplink
        self.downlink = downlink
        self.discardedFrameCount = discardedFrameCount
    }
}
