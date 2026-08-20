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

public enum AudioDiscardReason: Equatable, Hashable, Sendable {
    case overflow
    case expired
    case staleFlow
    case outOfOrder
    case sourceEnded
    case stopped
    case endpointFailure
    case processingFailure
}

/// Content-free cumulative discard counts for one queue generation.
public struct AudioDiscardReasonCounts: Equatable, Sendable {
    public private(set) var overflow: UInt64
    public private(set) var expired: UInt64
    public private(set) var staleFlow: UInt64
    public private(set) var outOfOrder: UInt64
    public private(set) var sourceEnded: UInt64
    public private(set) var stopped: UInt64
    public private(set) var endpointFailure: UInt64
    public private(set) var processingFailure: UInt64

    public init(
        overflow: UInt64 = 0,
        expired: UInt64 = 0,
        staleFlow: UInt64 = 0,
        outOfOrder: UInt64 = 0,
        sourceEnded: UInt64 = 0,
        stopped: UInt64 = 0,
        endpointFailure: UInt64 = 0,
        processingFailure: UInt64 = 0
    ) {
        self.overflow = overflow
        self.expired = expired
        self.staleFlow = staleFlow
        self.outOfOrder = outOfOrder
        self.sourceEnded = sourceEnded
        self.stopped = stopped
        self.endpointFailure = endpointFailure
        self.processingFailure = processingFailure
    }

    public var total: UInt64 {
        overflow &+ expired &+ staleFlow &+ outOfOrder &+ sourceEnded
            &+ stopped &+ endpointFailure &+ processingFailure
    }

    mutating func record(_ reason: AudioDiscardReason, count: UInt64 = 1) {
        switch reason {
        case .overflow: overflow &+= count
        case .expired: expired &+= count
        case .staleFlow: staleFlow &+= count
        case .outOfOrder: outOfOrder &+= count
        case .sourceEnded: sourceEnded &+= count
        case .stopped: stopped &+= count
        case .endpointFailure: endpointFailure &+= count
        case .processingFailure: processingFailure &+= count
        }
    }
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

public enum AudioEndpointStatus: Equatable, Sendable {
    case notConfigured
    case starting
    case active
    case naturallyEnded
    case failed
    case stopped
}

public struct AudioEndpointStates: Equatable, Sendable {
    public let source: AudioEndpointStatus
    public let localMonitor: AudioEndpointStatus
    public let uplink: AudioEndpointStatus
    public let downlink: AudioEndpointStatus

    public init(
        source: AudioEndpointStatus,
        localMonitor: AudioEndpointStatus,
        uplink: AudioEndpointStatus,
        downlink: AudioEndpointStatus
    ) {
        self.source = source
        self.localMonitor = localMonitor
        self.uplink = uplink
        self.downlink = downlink
    }

    public subscript(direction: AudioDirection) -> AudioEndpointStatus {
        switch direction {
        case .source: source
        case .localMonitor: localMonitor
        case .uplink: uplink
        case .downlink: downlink
        }
    }
}

public enum AudioPipelineFlowLifecycle: Equatable, Sendable {
    case active
    case terminal(AudioFlowStopReason)
}

/// An exact-flow, content-free observation. A session retains its active flow
/// and at most its most recently completed flow.
@available(iOS 18, macOS 13, *)
public struct AudioPipelineFlowSnapshot: Equatable, Sendable {
    public let flowID: AudioFlowID
    public let lifecycle: AudioPipelineFlowLifecycle
    public let sourceFormat: AudioStreamFormat?
    public let endpoints: AudioEndpointStates
    public let uplink: BoundedUplinkQueueSnapshot
    public let downlink: BoundedDownlinkJitterBufferSnapshot

    public init(
        flowID: AudioFlowID,
        lifecycle: AudioPipelineFlowLifecycle,
        sourceFormat: AudioStreamFormat?,
        endpoints: AudioEndpointStates,
        uplink: BoundedUplinkQueueSnapshot,
        downlink: BoundedDownlinkJitterBufferSnapshot
    ) {
        self.flowID = flowID
        self.lifecycle = lifecycle
        self.sourceFormat = sourceFormat
        self.endpoints = endpoints
        self.uplink = uplink
        self.downlink = downlink
    }
}
