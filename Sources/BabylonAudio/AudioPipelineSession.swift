@available(iOS 18, macOS 13, *)
public enum AudioPipelineSessionError: Error, Equatable, Sendable {
    case alreadyRunning
    case reusedFlowID
    case sourceDrivenPlanNotAvailable
    case deviceRuntimeRequired
}

@available(iOS 18, macOS 13, *)
public actor AudioPipelineSession {
    private let configuration: AudioPipelineConfiguration
    private let downlink: BoundedDownlinkJitterBuffer
    private let eventGate = AudioPipelineEventGate()

    private var activeGeneration: AudioFlowGeneration?
    private var receiverTask: Task<Void, Never>?
    private var state: AudioPipelineState = .idle
    private var usedFlowIDs: Set<AudioFlowID> = []

    public init(
        configuration: AudioPipelineConfiguration,
        downlinkPolicy: BoundedDownlinkJitterBufferPolicy = .initial
    ) {
        self.configuration = configuration
        downlink = BoundedDownlinkJitterBuffer(
            policy: downlinkPolicy,
            diagnosticSink: configuration.diagnosticSink
        )
    }

    public var snapshot: AudioPipelineSnapshot {
        get async {
            let downlinkSnapshot = await downlink.snapshot
            return AudioPipelineSnapshot(
                flowID: activeGeneration?.flowID,
                state: state,
                sourceFormat: nil,
                uplink: .zero,
                downlink: downlinkSnapshot.pending,
                discardedFrameCount: downlinkSnapshot.discardedFrameCount
            )
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
        guard configuration.source == nil,
              configuration.localMonitorSink == nil,
              configuration.uplinkSender == nil
        else {
            throw AudioPipelineSessionError.sourceDrivenPlanNotAvailable
        }
        guard let receiver = configuration.downlinkReceiver,
              let sinkConfiguration = configuration.downlinkSink
        else {
            preconditionFailure("AudioPipelineConfiguration guarantees a complete downlink")
        }
        guard case .external(let sink) = sinkConfiguration else {
            throw AudioPipelineSessionError.deviceRuntimeRequired
        }

        let generation = AudioFlowGeneration(flowID: flowID)
        usedFlowIDs.insert(flowID)
        activeGeneration = generation
        state = .running
        await downlink.start(
            flowID: flowID,
            sink: sink,
            onFailure: { [weak self] _ in
                await self?.downlinkFailed(generation: generation)
            }
        )
        await emit(.flowStarted(flowID: flowID))
        guard activeGeneration == generation else { return }

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

    private func downlinkFailed(generation: AudioFlowGeneration) async {
        guard activeGeneration == generation else { return }
        receiverTask?.cancel()
        receiverTask = nil
        await emit(
            .endpointFailed(flowID: generation.flowID, direction: .downlink)
        )
        guard activeGeneration == generation else { return }
        await finish(
            generation: generation,
            reason: .endpointFailure,
            stopDownlink: true
        )
    }

    private func finish(
        generation: AudioFlowGeneration,
        reason: AudioFlowStopReason,
        stopDownlink: Bool
    ) async {
        guard activeGeneration == generation else { return }
        activeGeneration = nil
        state = .stopped
        let task = receiverTask
        receiverTask = nil
        task?.cancel()
        if stopDownlink {
            await downlink.stop()
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
private actor AudioPipelineEventGate {
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
