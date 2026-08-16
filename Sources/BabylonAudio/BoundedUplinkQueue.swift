import Foundation

public enum AudioStreamingError: Error, Equatable, Sendable {
    case invalidPolicy
}

public typealias AudioStreamingFailureHandler =
    @Sendable (_ error: any Error) async -> Void

@available(iOS 18, macOS 13, *)
public struct BoundedUplinkQueuePolicy: Equatable, Sendable {
    public static let initial = Self(
        maximumPendingAudioDuration: .seconds(1),
        maximumFrameAge: .milliseconds(1_500),
        unchecked: ()
    )

    public let maximumPendingAudioDuration: Duration
    public let maximumFrameAge: Duration

    public init(
        maximumPendingAudioDuration: Duration,
        maximumFrameAge: Duration
    ) throws {
        guard maximumPendingAudioDuration > .zero,
              maximumFrameAge > .zero
        else {
            throw AudioStreamingError.invalidPolicy
        }
        self.maximumPendingAudioDuration = maximumPendingAudioDuration
        self.maximumFrameAge = maximumFrameAge
    }

    private init(
        maximumPendingAudioDuration: Duration,
        maximumFrameAge: Duration,
        unchecked: Void
    ) {
        self.maximumPendingAudioDuration = maximumPendingAudioDuration
        self.maximumFrameAge = maximumFrameAge
    }
}

@available(iOS 18, macOS 13, *)
public struct BoundedUplinkQueueSnapshot: Equatable, Sendable {
    public let flowID: AudioFlowID?
    public let isRunning: Bool
    public let isSending: Bool
    public let pending: AudioQueueSnapshot
    public let droppedOverflowFrameCount: UInt64
    public let droppedExpiredFrameCount: UInt64
    public let discardedFrameCount: UInt64
    public let maximumPendingAudioDuration: Duration
    public let maximumEnqueueToSendLatency: Duration

    public init(
        flowID: AudioFlowID?,
        isRunning: Bool,
        isSending: Bool,
        pending: AudioQueueSnapshot,
        droppedOverflowFrameCount: UInt64,
        droppedExpiredFrameCount: UInt64,
        discardedFrameCount: UInt64,
        maximumPendingAudioDuration: Duration,
        maximumEnqueueToSendLatency: Duration
    ) {
        self.flowID = flowID
        self.isRunning = isRunning
        self.isSending = isSending
        self.pending = pending
        self.droppedOverflowFrameCount = droppedOverflowFrameCount
        self.droppedExpiredFrameCount = droppedExpiredFrameCount
        self.discardedFrameCount = discardedFrameCount
        self.maximumPendingAudioDuration = maximumPendingAudioDuration
        self.maximumEnqueueToSendLatency = maximumEnqueueToSendLatency
    }
}

@available(iOS 18, macOS 13, *)
public actor BoundedUplinkQueue {
    private struct PendingFrame: Sendable {
        let frame: AudioFrame
        let enqueuedAt: Duration
    }

    public let policy: BoundedUplinkQueuePolicy

    private let clock: AudioMonotonicClock
    private let diagnosticSink: (any AudioDiagnosticSink)?
    private var activeGeneration: AudioFlowGeneration?
    private var sender: (any AudioFrameSender)?
    private var failureHandler: AudioStreamingFailureHandler?
    private var pendingFrames: [PendingFrame] = []
    private var pendingAudioDuration: Duration = .zero
    private var isRunning = false
    private var isSending = false
    private var droppedOverflowFrameCount: UInt64 = 0
    private var droppedExpiredFrameCount: UInt64 = 0
    private var discardedFrameCount: UInt64 = 0
    private var observedMaximumPendingAudioDuration: Duration = .zero
    private var maximumEnqueueToSendLatency: Duration = .zero

    public init(
        policy: BoundedUplinkQueuePolicy = .initial,
        clock: AudioMonotonicClock = .continuous(),
        diagnosticSink: (any AudioDiagnosticSink)? = nil
    ) {
        self.policy = policy
        self.clock = clock
        self.diagnosticSink = diagnosticSink
    }

    public var snapshot: BoundedUplinkQueueSnapshot {
        BoundedUplinkQueueSnapshot(
            flowID: activeGeneration?.flowID,
            isRunning: isRunning,
            isSending: isSending,
            pending: AudioQueueSnapshot(
                frameCount: pendingFrames.count,
                duration: pendingAudioDuration
            ),
            droppedOverflowFrameCount: droppedOverflowFrameCount,
            droppedExpiredFrameCount: droppedExpiredFrameCount,
            discardedFrameCount: discardedFrameCount,
            maximumPendingAudioDuration: observedMaximumPendingAudioDuration,
            maximumEnqueueToSendLatency: maximumEnqueueToSendLatency
        )
    }

    public func start(
        flowID: AudioFlowID,
        sender: any AudioFrameSender,
        onFailure: AudioStreamingFailureHandler? = nil
    ) {
        activeGeneration = AudioFlowGeneration(flowID: flowID)
        pendingFrames.removeAll(keepingCapacity: true)
        pendingAudioDuration = .zero
        self.sender = sender
        failureHandler = onFailure
        isRunning = true
        isSending = false
        droppedOverflowFrameCount = 0
        droppedExpiredFrameCount = 0
        discardedFrameCount = 0
        observedMaximumPendingAudioDuration = .zero
        maximumEnqueueToSendLatency = .zero
    }

    public func enqueue(_ frame: AudioFrame) {
        guard isRunning, let generation = activeGeneration else {
            discardedFrameCount += 1
            recordDiscard(frame: frame, reason: .stopped)
            return
        }
        guard frame.flowID == generation.flowID else {
            discardedFrameCount += 1
            recordDiscard(frame: frame, reason: .staleFlow)
            return
        }

        let currentTime = clock.now()
        discardExpiredFrames(at: currentTime)
        guard frame.duration <= policy.maximumPendingAudioDuration else {
            droppedOverflowFrameCount += 1
            recordDiscard(frame: frame, reason: .overflow)
            return
        }

        while pendingAudioDuration + frame.duration
            > policy.maximumPendingAudioDuration,
            !pendingFrames.isEmpty
        {
            dropOldestPendingFrame(reason: .overflow)
        }
        guard pendingAudioDuration + frame.duration
            <= policy.maximumPendingAudioDuration
        else {
            droppedOverflowFrameCount += 1
            recordDiscard(frame: frame, reason: .overflow)
            return
        }

        pendingFrames.append(PendingFrame(frame: frame, enqueuedAt: currentTime))
        pendingAudioDuration += frame.duration
        observedMaximumPendingAudioDuration = max(
            observedMaximumPendingAudioDuration,
            pendingAudioDuration
        )
        drainIfPossible()
    }

    public func discardPending() {
        discardPending(reason: .stopped)
    }

    public func stop() {
        activeGeneration = nil
        isRunning = false
        isSending = false
        sender = nil
        failureHandler = nil
        discardPending(reason: .stopped)
    }

    private func drainIfPossible() {
        guard isRunning,
              !isSending,
              let generation = activeGeneration,
              let sender
        else {
            return
        }
        let currentTime = clock.now()
        discardExpiredFrames(at: currentTime)
        guard !pendingFrames.isEmpty else { return }

        let pending = pendingFrames.removeFirst()
        pendingAudioDuration -= pending.frame.duration
        isSending = true
        let latency = max(.zero, currentTime - pending.enqueuedAt)
        maximumEnqueueToSendLatency = max(maximumEnqueueToSendLatency, latency)
        record(.latency(
            flowID: pending.frame.flowID,
            direction: .uplink,
            duration: latency
        ))

        Task { [weak self] in
            do {
                try await sender.send(pending.frame)
                await self?.sendCompleted(generation: generation, error: nil)
            } catch {
                await self?.sendCompleted(generation: generation, error: error)
            }
        }
    }

    private func sendCompleted(
        generation: AudioFlowGeneration,
        error: (any Error)?
    ) {
        guard activeGeneration == generation, isRunning else { return }
        isSending = false

        if let error {
            let handler = failureHandler
            activeGeneration = nil
            isRunning = false
            sender = nil
            failureHandler = nil
            discardPending(reason: .endpointFailure)
            if let handler {
                Task { await handler(error) }
            }
            return
        }
        drainIfPossible()
    }

    private func discardExpiredFrames(at currentTime: Duration) {
        while let pending = pendingFrames.first,
              currentTime - pending.enqueuedAt > policy.maximumFrameAge
        {
            dropOldestPendingFrame(reason: .expired)
        }
    }

    private func dropOldestPendingFrame(reason: AudioDiscardReason) {
        let pending = pendingFrames.removeFirst()
        pendingAudioDuration -= pending.frame.duration
        switch reason {
        case .overflow:
            droppedOverflowFrameCount += 1
        case .expired:
            droppedExpiredFrameCount += 1
        default:
            discardedFrameCount += 1
        }
        recordDiscard(frame: pending.frame, reason: reason)
    }

    private func discardPending(reason: AudioDiscardReason) {
        guard !pendingFrames.isEmpty else {
            pendingAudioDuration = .zero
            return
        }
        let frames = pendingFrames
        let duration = pendingAudioDuration
        discardedFrameCount += UInt64(frames.count)
        pendingFrames.removeAll(keepingCapacity: true)
        pendingAudioDuration = .zero
        record(.queueDiscarded(
            flowID: frames[0].frame.flowID,
            direction: .uplink,
            reason: reason,
            frameCount: frames.count,
            duration: duration
        ))
    }

    private func recordDiscard(
        frame: AudioFrame,
        reason: AudioDiscardReason
    ) {
        record(.queueDiscarded(
            flowID: frame.flowID,
            direction: .uplink,
            reason: reason,
            frameCount: 1,
            duration: frame.duration
        ))
    }

    private func record(_ event: AudioDiagnosticEvent) {
        guard let diagnosticSink else { return }
        Task { await diagnosticSink.record(event) }
    }
}
