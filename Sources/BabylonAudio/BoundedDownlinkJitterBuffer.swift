import Foundation

@available(iOS 18, macOS 13, *)
public struct BoundedDownlinkJitterBufferPolicy: Equatable, Sendable {
    public static let initial = Self(
        targetBufferedAudioDuration: .milliseconds(200),
        maximumBufferedAudioDuration: .seconds(1),
        maximumFrameAge: .milliseconds(1_500),
        unchecked: ()
    )

    public let targetBufferedAudioDuration: Duration
    public let maximumBufferedAudioDuration: Duration
    public let maximumFrameAge: Duration

    public init(
        targetBufferedAudioDuration: Duration,
        maximumBufferedAudioDuration: Duration,
        maximumFrameAge: Duration
    ) throws {
        guard targetBufferedAudioDuration > .zero,
              maximumBufferedAudioDuration > .zero,
              maximumFrameAge > .zero,
              targetBufferedAudioDuration <= maximumBufferedAudioDuration
        else {
            throw AudioStreamingError.invalidPolicy
        }
        self.targetBufferedAudioDuration = targetBufferedAudioDuration
        self.maximumBufferedAudioDuration = maximumBufferedAudioDuration
        self.maximumFrameAge = maximumFrameAge
    }

    private init(
        targetBufferedAudioDuration: Duration,
        maximumBufferedAudioDuration: Duration,
        maximumFrameAge: Duration,
        unchecked: Void
    ) {
        self.targetBufferedAudioDuration = targetBufferedAudioDuration
        self.maximumBufferedAudioDuration = maximumBufferedAudioDuration
        self.maximumFrameAge = maximumFrameAge
    }
}

@available(iOS 18, macOS 13, *)
public struct BoundedDownlinkJitterBufferSnapshot: Equatable, Sendable {
    public let flowID: AudioFlowID?
    public let isRunning: Bool
    public let isBuffering: Bool
    public let isDelivering: Bool
    public let pending: AudioQueueSnapshot
    public let bufferedAudioDuration: Duration
    public let droppedOverflowFrameCount: UInt64
    public let droppedExpiredFrameCount: UInt64
    public let droppedOutOfOrderFrameCount: UInt64
    public let discardedFrameCount: UInt64
    public let rebufferCount: UInt64
    public let maximumBufferedAudioDuration: Duration
    public let maximumReceiveToSinkLatency: Duration

    public init(
        flowID: AudioFlowID?,
        isRunning: Bool,
        isBuffering: Bool,
        isDelivering: Bool,
        pending: AudioQueueSnapshot,
        bufferedAudioDuration: Duration,
        droppedOverflowFrameCount: UInt64,
        droppedExpiredFrameCount: UInt64,
        droppedOutOfOrderFrameCount: UInt64,
        discardedFrameCount: UInt64,
        rebufferCount: UInt64,
        maximumBufferedAudioDuration: Duration,
        maximumReceiveToSinkLatency: Duration
    ) {
        self.flowID = flowID
        self.isRunning = isRunning
        self.isBuffering = isBuffering
        self.isDelivering = isDelivering
        self.pending = pending
        self.bufferedAudioDuration = bufferedAudioDuration
        self.droppedOverflowFrameCount = droppedOverflowFrameCount
        self.droppedExpiredFrameCount = droppedExpiredFrameCount
        self.droppedOutOfOrderFrameCount = droppedOutOfOrderFrameCount
        self.discardedFrameCount = discardedFrameCount
        self.rebufferCount = rebufferCount
        self.maximumBufferedAudioDuration = maximumBufferedAudioDuration
        self.maximumReceiveToSinkLatency = maximumReceiveToSinkLatency
    }
}

@available(iOS 18, macOS 13, *)
public actor BoundedDownlinkJitterBuffer {
    private struct PendingFrame: Sendable {
        let frame: AudioFrame
        let receivedAt: Duration
    }

    public let policy: BoundedDownlinkJitterBufferPolicy

    private let clock: AudioMonotonicClock
    private let diagnosticSink: (any AudioDiagnosticSink)?
    private var activeGeneration: AudioFlowGeneration?
    private var sink: (any AudioFrameSink)?
    private var failureHandler: AudioStreamingFailureHandler?
    private var receiverTask: Task<Void, Never>?
    private var pendingFrames: [PendingFrame] = []
    private var pendingAudioDuration: Duration = .zero
    private var inFlightAudioDuration: Duration = .zero
    private var lastDeliveredSequence: UInt64?
    private var isRunning = false
    private var isDelivering = false
    private var requiresTargetBuffer = true
    private var sourceHasEnded = false
    private var isAwaitingRebufferRecovery = false
    private var sourceEndWaiters: [CheckedContinuation<Bool, Never>] = []
    private var droppedOverflowFrameCount: UInt64 = 0
    private var droppedExpiredFrameCount: UInt64 = 0
    private var droppedOutOfOrderFrameCount: UInt64 = 0
    private var discardedFrameCount: UInt64 = 0
    private var rebufferCount: UInt64 = 0
    private var observedMaximumBufferedAudioDuration: Duration = .zero
    private var maximumReceiveToSinkLatency: Duration = .zero

    public init(
        policy: BoundedDownlinkJitterBufferPolicy = .initial,
        clock: AudioMonotonicClock = .continuous(),
        diagnosticSink: (any AudioDiagnosticSink)? = nil
    ) {
        self.policy = policy
        self.clock = clock
        self.diagnosticSink = diagnosticSink
    }

    public var snapshot: BoundedDownlinkJitterBufferSnapshot {
        BoundedDownlinkJitterBufferSnapshot(
            flowID: activeGeneration?.flowID,
            isRunning: isRunning,
            isBuffering: isRunning && requiresTargetBuffer,
            isDelivering: isDelivering,
            pending: AudioQueueSnapshot(
                frameCount: pendingFrames.count,
                duration: pendingAudioDuration
            ),
            bufferedAudioDuration: bufferedAudioDuration,
            droppedOverflowFrameCount: droppedOverflowFrameCount,
            droppedExpiredFrameCount: droppedExpiredFrameCount,
            droppedOutOfOrderFrameCount: droppedOutOfOrderFrameCount,
            discardedFrameCount: discardedFrameCount,
            rebufferCount: rebufferCount,
            maximumBufferedAudioDuration: observedMaximumBufferedAudioDuration,
            maximumReceiveToSinkLatency: maximumReceiveToSinkLatency
        )
    }

    public func start(
        flowID: AudioFlowID,
        sink: any AudioFrameSink,
        onFailure: AudioStreamingFailureHandler? = nil
    ) {
        begin(flowID: flowID, sink: sink, onFailure: onFailure)
    }

    public func start(
        flowID: AudioFlowID,
        receiver: any AudioFrameReceiver,
        sink: any AudioFrameSink,
        onFailure: AudioStreamingFailureHandler? = nil
    ) {
        begin(flowID: flowID, sink: sink, onFailure: onFailure)
        guard let generation = activeGeneration else { return }
        receiverTask = Task { [weak self] in
            do {
                for try await frame in receiver.frames(for: flowID) {
                    guard !Task.isCancelled else { return }
                    await self?.enqueue(frame, generation: generation)
                }
                await self?.receiverFinished(generation: generation)
            } catch is CancellationError {
                return
            } catch {
                await self?.endpointFailed(error, generation: generation)
            }
        }
    }

    public func enqueue(_ frame: AudioFrame) {
        guard let generation = activeGeneration else {
            discardedFrameCount += 1
            recordDiscard(frame: frame, reason: .stopped)
            return
        }
        enqueue(frame, generation: generation)
    }

    /// Marks the receiver stream complete and drains any tail below the normal
    /// prebuffer target. Returns only after all accepted frames are consumed,
    /// or `false` if the flow is stopped, replaced, or fails first.
    public func finishSource(flowID: AudioFlowID) async -> Bool {
        guard let generation = activeGeneration,
              generation.flowID == flowID,
              isRunning
        else {
            return false
        }

        markSourceEnded(generation: generation)
        guard activeGeneration == generation, isRunning else {
            return true
        }
        return await withCheckedContinuation { continuation in
            sourceEndWaiters.append(continuation)
        }
    }

    /// Fails the active receiver side and discards pending audio as an endpoint
    /// failure. The configured failure handler is invoked exactly once.
    public func failSource(flowID: AudioFlowID, error: any Error) {
        guard let generation = activeGeneration,
              generation.flowID == flowID,
              isRunning
        else {
            return
        }
        endpointFailed(error, generation: generation)
    }

    public func stop() {
        receiverTask?.cancel()
        receiverTask = nil
        activeGeneration = nil
        isRunning = false
        isDelivering = false
        requiresTargetBuffer = true
        sink = nil
        failureHandler = nil
        inFlightAudioDuration = .zero
        sourceHasEnded = false
        isAwaitingRebufferRecovery = false
        discardPending(reason: .stopped)
        resumeSourceEndWaiters(completed: false)
    }

    private var bufferedAudioDuration: Duration {
        pendingAudioDuration + inFlightAudioDuration
    }

    private func begin(
        flowID: AudioFlowID,
        sink: any AudioFrameSink,
        onFailure: AudioStreamingFailureHandler?
    ) {
        resumeSourceEndWaiters(completed: false)
        receiverTask?.cancel()
        receiverTask = nil
        activeGeneration = AudioFlowGeneration(flowID: flowID)
        pendingFrames.removeAll(keepingCapacity: true)
        pendingAudioDuration = .zero
        inFlightAudioDuration = .zero
        lastDeliveredSequence = nil
        self.sink = sink
        failureHandler = onFailure
        isRunning = true
        isDelivering = false
        requiresTargetBuffer = true
        sourceHasEnded = false
        isAwaitingRebufferRecovery = false
        droppedOverflowFrameCount = 0
        droppedExpiredFrameCount = 0
        droppedOutOfOrderFrameCount = 0
        discardedFrameCount = 0
        rebufferCount = 0
        observedMaximumBufferedAudioDuration = .zero
        maximumReceiveToSinkLatency = .zero
    }

    private func enqueue(
        _ frame: AudioFrame,
        generation: AudioFlowGeneration
    ) {
        guard activeGeneration == generation, isRunning else { return }
        guard !sourceHasEnded else {
            discardedFrameCount += 1
            recordDiscard(frame: frame, reason: .stopped)
            return
        }
        guard frame.flowID == generation.flowID else {
            discardedFrameCount += 1
            recordDiscard(frame: frame, reason: .staleFlow)
            return
        }
        guard lastDeliveredSequence.map({ frame.sequence > $0 }) ?? true,
              !pendingFrames.contains(where: {
                  $0.frame.sequence == frame.sequence
              })
        else {
            droppedOutOfOrderFrameCount += 1
            recordDiscard(frame: frame, reason: .outOfOrder)
            return
        }

        let currentTime = clock.now()
        discardExpiredFrames(at: currentTime)
        guard frame.duration <= policy.maximumBufferedAudioDuration else {
            droppedOverflowFrameCount += 1
            recordDiscard(frame: frame, reason: .overflow)
            return
        }
        while bufferedAudioDuration + frame.duration
            > policy.maximumBufferedAudioDuration,
            !pendingFrames.isEmpty
        {
            dropOldestPendingFrame(reason: .overflow)
        }
        guard bufferedAudioDuration + frame.duration
            <= policy.maximumBufferedAudioDuration
        else {
            droppedOverflowFrameCount += 1
            recordDiscard(frame: frame, reason: .overflow)
            return
        }

        let pending = PendingFrame(frame: frame, receivedAt: currentTime)
        if isAwaitingRebufferRecovery {
            isAwaitingRebufferRecovery = false
            rebufferCount += 1
            record(.rebuffered(
                flowID: generation.flowID,
                bufferedDuration: .zero
            ))
        }
        if let index = pendingFrames.firstIndex(where: {
            $0.frame.sequence > frame.sequence
        }) {
            pendingFrames.insert(pending, at: index)
        } else {
            pendingFrames.append(pending)
        }
        pendingAudioDuration += frame.duration
        observedMaximumBufferedAudioDuration = max(
            observedMaximumBufferedAudioDuration,
            bufferedAudioDuration
        )
        drainIfReady()
    }

    private func drainIfReady() {
        guard isRunning,
              !isDelivering,
              let generation = activeGeneration,
              let sink
        else {
            return
        }
        let currentTime = clock.now()
        discardExpiredFrames(at: currentTime)
        guard !pendingFrames.isEmpty else { return }
        if requiresTargetBuffer {
            guard pendingAudioDuration >= policy.targetBufferedAudioDuration else {
                return
            }
            requiresTargetBuffer = false
        }

        let pending = pendingFrames.removeFirst()
        pendingAudioDuration -= pending.frame.duration
        inFlightAudioDuration = pending.frame.duration
        lastDeliveredSequence = pending.frame.sequence
        isDelivering = true
        let latency = max(.zero, currentTime - pending.receivedAt)
        maximumReceiveToSinkLatency = max(maximumReceiveToSinkLatency, latency)
        record(.latency(
            flowID: pending.frame.flowID,
            direction: .downlink,
            duration: latency
        ))

        Task { [weak self] in
            do {
                try await sink.consume(pending.frame)
                await self?.deliveryCompleted(generation: generation, error: nil)
            } catch {
                await self?.deliveryCompleted(generation: generation, error: error)
            }
        }
    }

    private func deliveryCompleted(
        generation: AudioFlowGeneration,
        error: (any Error)?
    ) {
        guard activeGeneration == generation, isRunning else { return }
        isDelivering = false
        inFlightAudioDuration = .zero
        if let error {
            endpointFailed(error, generation: generation)
            return
        }

        discardExpiredFrames(at: clock.now())
        if pendingFrames.isEmpty {
            if sourceHasEnded {
                completeSourceEnd(generation: generation)
                return
            }
            requiresTargetBuffer = true
            isAwaitingRebufferRecovery = true
            return
        }
        drainIfReady()
    }

    private func endpointFailed(
        _ error: any Error,
        generation: AudioFlowGeneration
    ) {
        guard activeGeneration == generation, isRunning else { return }
        let handler = failureHandler
        receiverTask?.cancel()
        receiverTask = nil
        activeGeneration = nil
        isRunning = false
        isDelivering = false
        requiresTargetBuffer = true
        sink = nil
        failureHandler = nil
        inFlightAudioDuration = .zero
        sourceHasEnded = false
        isAwaitingRebufferRecovery = false
        discardPending(reason: .endpointFailure)
        resumeSourceEndWaiters(completed: false)
        if let handler {
            Task { await handler(error) }
        }
    }

    private func receiverFinished(generation: AudioFlowGeneration) {
        guard activeGeneration == generation else { return }
        receiverTask = nil
        markSourceEnded(generation: generation)
    }

    private func markSourceEnded(generation: AudioFlowGeneration) {
        guard activeGeneration == generation, isRunning else { return }
        sourceHasEnded = true
        requiresTargetBuffer = false
        isAwaitingRebufferRecovery = false
        drainIfReady()
        if !isDelivering, pendingFrames.isEmpty {
            completeSourceEnd(generation: generation)
        }
    }

    private func completeSourceEnd(generation: AudioFlowGeneration) {
        guard activeGeneration == generation, isRunning else { return }
        activeGeneration = nil
        isRunning = false
        isDelivering = false
        requiresTargetBuffer = true
        sourceHasEnded = false
        isAwaitingRebufferRecovery = false
        sink = nil
        failureHandler = nil
        inFlightAudioDuration = .zero
        resumeSourceEndWaiters(completed: true)
    }

    private func resumeSourceEndWaiters(completed: Bool) {
        let waiters = sourceEndWaiters
        sourceEndWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume(returning: completed)
        }
    }

    private func discardExpiredFrames(at currentTime: Duration) {
        var expiredIndices: [Int] = []
        for index in pendingFrames.indices where
            currentTime - pendingFrames[index].receivedAt > policy.maximumFrameAge
        {
            expiredIndices.append(index)
        }
        for index in expiredIndices.reversed() {
            let pending = pendingFrames.remove(at: index)
            pendingAudioDuration -= pending.frame.duration
            droppedExpiredFrameCount += 1
            recordDiscard(frame: pending.frame, reason: .expired)
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
        case .outOfOrder:
            droppedOutOfOrderFrameCount += 1
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
            direction: .downlink,
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
            direction: .downlink,
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
