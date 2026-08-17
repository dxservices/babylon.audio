@available(iOS 18, macOS 13, *)
public enum AudioPipelineSessionError: Error, Equatable, Sendable {
    case alreadyRunning
    case reusedFlowID
    case notRunning
    case externalFramesNotConfigured
    case frameFlowMismatch
    case sourceDrivenPlanNotAvailable
    case deviceRuntimeRequired
}

@available(iOS 18, macOS 13, *)
public actor AudioPipelineSession {
    private let configuration: AudioPipelineConfiguration
    private let uplink: BoundedUplinkQueue
    private let downlink: BoundedDownlinkJitterBuffer
    private let eventGate = AudioPipelineSerialGate()
    private let sourceGate = AudioPipelineSerialGate()

    private var activeGeneration: AudioFlowGeneration?
    private var receiverTask: Task<Void, Never>?
    private var state: AudioPipelineState = .idle
    private var usedFlowIDs: Set<AudioFlowID> = []
    private var activeLocalMonitorSink: (any AudioFrameSink)?
    private var sourceFormat: AudioStreamFormat?

    public init(
        configuration: AudioPipelineConfiguration,
        uplinkPolicy: BoundedUplinkQueuePolicy = .initial,
        downlinkPolicy: BoundedDownlinkJitterBufferPolicy = .initial
    ) {
        self.configuration = configuration
        uplink = BoundedUplinkQueue(
            policy: uplinkPolicy,
            diagnosticSink: configuration.diagnosticSink
        )
        downlink = BoundedDownlinkJitterBuffer(
            policy: downlinkPolicy,
            diagnosticSink: configuration.diagnosticSink
        )
    }

    public var snapshot: AudioPipelineSnapshot {
        get async {
            let uplinkSnapshot = await uplink.snapshot
            let downlinkSnapshot = await downlink.snapshot
            return AudioPipelineSnapshot(
                flowID: activeGeneration?.flowID,
                state: state,
                sourceFormat: sourceFormat,
                uplink: uplinkSnapshot.pending,
                downlink: downlinkSnapshot.pending,
                discardedFrameCount: uplinkSnapshot.discardedFrameCount
                    &+ downlinkSnapshot.discardedFrameCount
            )
        }
    }

    public var uplinkSnapshot: BoundedUplinkQueueSnapshot {
        get async {
            await uplink.snapshot
        }
    }

    public var downlinkSnapshot: BoundedDownlinkJitterBufferSnapshot {
        get async {
            await downlink.snapshot
        }
    }

    public func start(flowID: AudioFlowID = AudioFlowID()) async throws {
        guard activeGeneration == nil else {
            throw AudioPipelineSessionError.alreadyRunning
        }
        guard !usedFlowIDs.contains(flowID) else {
            throw AudioPipelineSessionError.reusedFlowID
        }
        if let source = configuration.source {
            guard case .externalFrames = source else {
                throw AudioPipelineSessionError.sourceDrivenPlanNotAvailable
            }
        }

        let localMonitorSink: (any AudioFrameSink)?
        switch configuration.localMonitorSink {
        case .external(let sink):
            localMonitorSink = sink
        case .device:
            throw AudioPipelineSessionError.deviceRuntimeRequired
        case nil:
            localMonitorSink = nil
        }

        let downlinkSink: (any AudioFrameSink)?
        switch configuration.downlinkSink {
        case .external(let sink):
            downlinkSink = sink
        case .device:
            throw AudioPipelineSessionError.deviceRuntimeRequired
        case nil:
            downlinkSink = nil
        }

        let generation = AudioFlowGeneration(flowID: flowID)
        usedFlowIDs.insert(flowID)
        activeGeneration = generation
        state = .running
        activeLocalMonitorSink = localMonitorSink
        sourceFormat = nil
        if let sender = configuration.uplinkSender {
            await uplink.start(
                flowID: flowID,
                sender: sender,
                onFailure: { [weak self] _ in
                    await self?.planFailed(
                        direction: .uplink,
                        generation: generation
                    )
                }
            )
        }
        if let downlinkSink {
            await downlink.start(
                flowID: flowID,
                sink: downlinkSink,
                onFailure: { [weak self] _ in
                    await self?.planFailed(
                        direction: .downlink,
                        generation: generation
                    )
                }
            )
        }
        await emit(.flowStarted(flowID: flowID))
        guard activeGeneration == generation else { return }

        guard let receiver = configuration.downlinkReceiver else { return }
        receiverTask = Task { [weak self] in
            do {
                for try await frame in receiver.frames(for: flowID) {
                    guard !Task.isCancelled else { return }
                    await self?.receive(frame, generation: generation)
                }
                await self?.receiverEnded(generation: generation)
            } catch is CancellationError {
                return
            } catch {
                await self?.receiverFailed(error, generation: generation)
            }
        }
    }

    public func submit(_ frame: AudioFrame) async throws {
        await sourceGate.acquire()
        do {
            try Task.checkCancellation()
        } catch {
            await sourceGate.release()
            throw error
        }
        guard let generation = activeGeneration else {
            await sourceGate.release()
            throw AudioPipelineSessionError.notRunning
        }
        guard case .externalFrames = configuration.source else {
            await sourceGate.release()
            throw AudioPipelineSessionError.externalFramesNotConfigured
        }
        guard frame.flowID == generation.flowID else {
            await sourceGate.release()
            throw AudioPipelineSessionError.frameFlowMismatch
        }

        sourceFormat = frame.format
        if configuration.uplinkSender != nil {
            await uplink.enqueue(frame)
        }
        guard let localMonitorSink = activeLocalMonitorSink else {
            await sourceGate.release()
            return
        }
        do {
            try await localMonitorSink.consume(frame)
            await sourceGate.release()
        } catch {
            await sourceGate.release()
            await planFailed(
                direction: .localMonitor,
                generation: generation
            )
            throw error
        }
    }

    public func stop() async {
        guard let generation = activeGeneration else { return }
        await finish(
            generation: generation,
            reason: .consumerRequested,
            stopDownlink: true
        )
    }

    private func receive(
        _ frame: AudioFrame,
        generation: AudioFlowGeneration
    ) async {
        guard activeGeneration == generation else { return }
        await downlink.enqueue(frame)
    }

    private func receiverEnded(generation: AudioFlowGeneration) async {
        guard activeGeneration == generation else { return }
        receiverTask = nil
        await emit(.sourceEnded(flowID: generation.flowID))
        guard activeGeneration == generation else { return }
        let completed = await downlink.finishSource(flowID: generation.flowID)
        guard completed, activeGeneration == generation else { return }
        await finish(
            generation: generation,
            reason: .sourceEnded,
            stopDownlink: false
        )
    }

    private func receiverFailed(
        _ error: any Error,
        generation: AudioFlowGeneration
    ) async {
        guard activeGeneration == generation else { return }
        receiverTask = nil
        await downlink.failSource(flowID: generation.flowID, error: error)
    }

    private func planFailed(
        direction: AudioDirection,
        generation: AudioFlowGeneration
    ) async {
        await finish(
            generation: generation,
            reason: .endpointFailure,
            stopDownlink: true,
            endpointDirection: direction
        )
    }

    private func finish(
        generation: AudioFlowGeneration,
        reason: AudioFlowStopReason,
        stopDownlink: Bool,
        endpointDirection: AudioDirection? = nil
    ) async {
        guard activeGeneration == generation else { return }
        activeGeneration = nil
        state = .stopped
        let task = receiverTask
        receiverTask = nil
        task?.cancel()
        activeLocalMonitorSink = nil
        await uplink.stop()
        if stopDownlink {
            await downlink.stop()
        }
        if let endpointDirection {
            await emit(.endpointFailed(
                flowID: generation.flowID,
                direction: endpointDirection
            ))
        }
        await emit(
            .flowStopped(flowID: generation.flowID, reason: reason)
        )
    }

    private func emit(_ event: AudioEvent) async {
        guard let eventSink = configuration.eventSink else { return }
        await eventGate.acquire()
        await eventSink.receive(event)
        await eventGate.release()
    }
}

@available(iOS 18, macOS 13, *)
private actor AudioPipelineSerialGate {
    private var isAcquired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isAcquired else {
            isAcquired = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isAcquired = false
            return
        }
        waiters.removeFirst().resume()
    }
}
