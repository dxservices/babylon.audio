@available(iOS 18, macOS 13, *)
public enum AudioPipelineSessionError: Error, Equatable, Sendable {
    case alreadyRunning
    case reusedFlowID
    case notRunning
    case externalFramesNotConfigured
    case frameFlowMismatch
    case deviceRuntimeRequired
}

@available(iOS 18, macOS 13, *)
private struct PendingMicrophoneCaptureStart {
    let generation: AudioFlowGeneration
    let task: Task<AudioDeviceCaptureToken, any Error>
}

@available(iOS 18, macOS 13, *)
public actor AudioPipelineSession {
    private let configuration: AudioPipelineConfiguration
    private let deviceEngine: AudioDeviceEngine?
    private let uplink: BoundedUplinkQueue
    private let downlink: BoundedDownlinkJitterBuffer
    private let eventGate = AudioPipelineSerialGate()
    private let sourceGate = AudioPipelineSerialGate()

    private var activeGeneration: AudioFlowGeneration?
    private var finishingGeneration: AudioFlowGeneration?
    private var sourceTask: Task<Void, Never>?
    private var receiverTask: Task<Void, Never>?
    private var naturalEndDirection: AudioDirection?
    private var observedNaturalEndDirections: Set<AudioDirection> = []
    private var microphoneCaptureToken: AudioDeviceCaptureToken?
    private var pendingMicrophoneCaptureStart:
        PendingMicrophoneCaptureStart?
    private var state: AudioPipelineState = .idle
    private var usedFlowIDs: Set<AudioFlowID> = []
    private var activeLocalMonitorSink: (any AudioFrameSink)?
    private var activeUsesDevicePlayback = false
    private var sourceFormat: AudioStreamFormat?
    private var sourceProcessorChain: AudioFrameProcessorChain?

    public init(
        configuration: AudioPipelineConfiguration,
        deviceEngine: AudioDeviceEngine? = nil,
        uplinkPolicy: BoundedUplinkQueuePolicy = .initial,
        downlinkPolicy: BoundedDownlinkJitterBufferPolicy = .initial
    ) {
        self.configuration = configuration
        self.deviceEngine = deviceEngine
        uplink = BoundedUplinkQueue(
            policy: uplinkPolicy,
            diagnosticSink: configuration.diagnosticSink
        )
        downlink = BoundedDownlinkJitterBuffer(
            policy: downlinkPolicy,
            diagnosticSink: configuration.diagnosticSink
        )
        sourceProcessorChain = configuration.sourceProcessorChain
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

    var naturalEndDirections: Set<AudioDirection> {
        observedNaturalEndDirections
    }

    public func start(flowID: AudioFlowID = AudioFlowID()) async throws {
        guard activeGeneration == nil,
              finishingGeneration == nil,
              pendingMicrophoneCaptureStart == nil
        else {
            throw AudioPipelineSessionError.alreadyRunning
        }
        guard !usedFlowIDs.contains(flowID) else {
            throw AudioPipelineSessionError.reusedFlowID
        }
        let activeSource: (any AudioFrameSource)?
        let microphoneCapture: AudioCaptureSettings?
        switch configuration.source {
        case .external(let source):
            activeSource = source
            microphoneCapture = nil
        case .externalFrames, nil:
            activeSource = nil
            microphoneCapture = nil
        case .microphone(let microphone):
            guard deviceEngine != nil else {
                throw AudioPipelineSessionError.deviceRuntimeRequired
            }
            activeSource = nil
            microphoneCapture = microphone.capture
        }

        let usesDevicePlayback = configurationUsesDevicePlayback
        if usesDevicePlayback {
            try await validateDevicePlaybackRuntime()
        }

        let localMonitorSink: (any AudioFrameSink)?
        switch configuration.localMonitorSink {
        case .external(let sink):
            localMonitorSink = sink
        case .device:
            localMonitorSink = deviceEngine
        case nil:
            localMonitorSink = nil
        }

        let downlinkSink: (any AudioFrameSink)?
        switch configuration.downlinkSink {
        case .external(let sink):
            downlinkSink = sink
        case .device:
            downlinkSink = deviceEngine
        case nil:
            downlinkSink = nil
        }

        let generation = AudioFlowGeneration(flowID: flowID)
        sourceProcessorChain?.reset()
        usedFlowIDs.insert(flowID)
        activeGeneration = generation
        naturalEndDirection = nil
        observedNaturalEndDirections = []
        state = .running
        activeLocalMonitorSink = localMonitorSink
        activeUsesDevicePlayback = usesDevicePlayback
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

        if let activeSource {
            sourceTask = Task { [weak self] in
                do {
                    for try await frame in activeSource.frames(for: flowID) {
                        try Task.checkCancellation()
                        try await self?.deliverSourceFrame(
                            frame,
                            generation: generation
                        )
                    }
                    await self?.sourceEnded(generation: generation)
                } catch is CancellationError {
                    return
                } catch {
                    await self?.sourceFailed(generation: generation)
                }
            }
        }

        if let microphoneCapture {
            try await startMicrophoneCapture(
                microphoneCapture,
                generation: generation
            )
            guard activeGeneration == generation else { return }
        }

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

    private var configurationUsesDevicePlayback: Bool {
        if case .device = configuration.localMonitorSink { return true }
        if case .device = configuration.downlinkSink { return true }
        return false
    }

    private func validateDevicePlaybackRuntime() async throws {
        guard let deviceEngine else {
            throw AudioPipelineSessionError.deviceRuntimeRequired
        }
        guard await deviceEngine.isRunning else {
            throw AudioDeviceEngineError.engineNotRunning
        }
        guard let playbackFormat = await deviceEngine.playbackFormat else {
            throw AudioDeviceEngineError.playbackNotConfigured
        }
        guard case .microphone(let microphone) = configuration.source,
              case .device = configuration.localMonitorSink
        else {
            return
        }
        let sourceOutputFormat = configuration.sourceProcessorChain?.outputFormat(
            for: microphone.capture.format
        ) ?? microphone.capture.format
        guard playbackFormat == sourceOutputFormat else {
            throw AudioDeviceEngineError.playbackFormatMismatch
        }
    }

    private func startMicrophoneCapture(
        _ settings: AudioCaptureSettings,
        generation: AudioFlowGeneration
    ) async throws {
        guard let deviceEngine else {
            throw AudioPipelineSessionError.deviceRuntimeRequired
        }
        let captureConfiguration = settings.resolve(flowID: generation.flowID)
        let task = Task { @MainActor [deviceEngine] in
            try deviceEngine.startCaptureOwned(
                configuration: captureConfiguration,
                onFrame: { [weak self] frame in
                    await self?.receiveCapturedFrame(
                        frame,
                        expectedFormat: settings.format,
                        generation: generation
                    )
                },
                onFailure: { [weak self] _ in
                    await self?.sourceFailed(generation: generation)
                }
            )
        }
        pendingMicrophoneCaptureStart = PendingMicrophoneCaptureStart(
            generation: generation,
            task: task
        )
        do {
            let token = try await task.value
            guard activeGeneration == generation else {
                await deviceEngine.stopCapture(token: token)
                clearPendingMicrophoneCaptureStart(generation: generation)
                return
            }
            microphoneCaptureToken = token
            clearPendingMicrophoneCaptureStart(generation: generation)
        } catch {
            clearPendingMicrophoneCaptureStart(generation: generation)
            guard activeGeneration == generation else { throw error }
            await finish(
                generation: generation,
                reason: .endpointFailure,
                stopDownlink: true,
                endpointDirection: .source
            )
            throw error
        }
    }

    private func clearPendingMicrophoneCaptureStart(
        generation: AudioFlowGeneration
    ) {
        guard pendingMicrophoneCaptureStart?.generation == generation else {
            return
        }
        pendingMicrophoneCaptureStart = nil
    }

    private func receiveCapturedFrame(
        _ frame: AudioFrame,
        expectedFormat: AudioStreamFormat,
        generation: AudioFlowGeneration
    ) async {
        guard activeGeneration == generation else { return }
        guard frame.flowID == generation.flowID,
              frame.format == expectedFormat
        else {
            await sourceFailed(generation: generation)
            return
        }
        do {
            try await deliverSourceFrame(frame, generation: generation)
        } catch is CancellationError {
            return
        } catch {
            await sourceFailed(generation: generation)
        }
    }

    public func submit(_ frame: AudioFrame) async throws {
        guard let generation = activeGeneration else {
            throw AudioPipelineSessionError.notRunning
        }
        guard case .externalFrames = configuration.source else {
            throw AudioPipelineSessionError.externalFramesNotConfigured
        }
        try await deliverSourceFrame(frame, generation: generation)
    }

    private func deliverSourceFrame(
        _ frame: AudioFrame,
        generation: AudioFlowGeneration
    ) async throws {
        await sourceGate.acquire()
        do {
            try Task.checkCancellation()
        } catch {
            await sourceGate.release()
            throw error
        }
        guard activeGeneration == generation else {
            await sourceGate.release()
            throw AudioPipelineSessionError.notRunning
        }
        guard frame.flowID == generation.flowID else {
            await sourceGate.release()
            throw AudioPipelineSessionError.frameFlowMismatch
        }

        let processedFrames: [AudioFrame]
        do {
            processedFrames = try sourceProcessorChain?.process(frame) ?? [frame]
        } catch {
            await planFailed(
                direction: .source,
                generation: generation
            )
            await sourceGate.release()
            throw error
        }

        sourceFormat = frame.format
        let localMonitorSink = activeLocalMonitorSink
        for processedFrame in processedFrames {
            guard activeGeneration == generation else {
                await sourceGate.release()
                throw AudioPipelineSessionError.notRunning
            }
            if configuration.uplinkSender != nil {
                await uplink.enqueue(processedFrame)
            }
            guard let localMonitorSink else { continue }
            do {
                try await localMonitorSink.consume(processedFrame)
            } catch {
                await planFailed(
                    direction: .localMonitor,
                    generation: generation
                )
                await sourceGate.release()
                throw error
            }
        }
        await sourceGate.release()
    }

    private func sourceEnded(generation: AudioFlowGeneration) async {
        guard activeGeneration == generation else { return }
        sourceTask = nil
        observedNaturalEndDirections.insert(.source)
        guard claimNaturalEnd(
            direction: .source,
            generation: generation
        ) else { return }
        await emit(.endpointEnded(
            flowID: generation.flowID,
            direction: .source
        ))
        guard activeGeneration == generation else { return }
        if configuration.uplinkSender != nil {
            let completed = await uplink.finishSource(
                flowID: generation.flowID
            )
            guard completed, activeGeneration == generation else { return }
        }
        await finish(
            generation: generation,
            reason: .sourceEnded,
            stopDownlink: true
        )
    }

    private func sourceFailed(generation: AudioFlowGeneration) async {
        guard activeGeneration == generation else { return }
        sourceTask = nil
        await finish(
            generation: generation,
            reason: .endpointFailure,
            stopDownlink: true,
            endpointDirection: .source
        )
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
        observedNaturalEndDirections.insert(.downlink)
        guard claimNaturalEnd(
            direction: .downlink,
            generation: generation
        ) else { return }
        await emit(.endpointEnded(
            flowID: generation.flowID,
            direction: .downlink
        ))
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

    private func claimNaturalEnd(
        direction: AudioDirection,
        generation: AudioFlowGeneration
    ) -> Bool {
        guard activeGeneration == generation,
              naturalEndDirection == nil
        else {
            return false
        }
        naturalEndDirection = direction
        return true
    }

    private func finish(
        generation: AudioFlowGeneration,
        reason: AudioFlowStopReason,
        stopDownlink: Bool,
        endpointDirection: AudioDirection? = nil
    ) async {
        guard activeGeneration == generation else { return }
        activeGeneration = nil
        finishingGeneration = generation
        naturalEndDirection = nil
        state = .stopped
        let source = sourceTask
        sourceTask = nil
        let task = receiverTask
        receiverTask = nil
        let captureToken = microphoneCaptureToken
        microphoneCaptureToken = nil
        let stopsDevicePlayback = activeUsesDevicePlayback
        activeUsesDevicePlayback = false
        let pendingCaptureStart = pendingMicrophoneCaptureStart.flatMap {
            $0.generation == generation ? $0 : nil
        }
        source?.cancel()
        task?.cancel()
        activeLocalMonitorSink = nil
        if let captureToken {
            await deviceEngine?.stopCapture(token: captureToken)
        }
        if let pendingCaptureStart,
           case .success(let acquiredToken) = await pendingCaptureStart.task.result
        {
            await deviceEngine?.stopCapture(token: acquiredToken)
        }
        clearPendingMicrophoneCaptureStart(generation: generation)
        if stopsDevicePlayback {
            await deviceEngine?.stopPlayback()
        }
        await uplink.stop()
        if stopDownlink {
            await downlink.stop()
        }
        sourceProcessorChain?.reset()
        if let endpointDirection {
            await emit(.endpointFailed(
                flowID: generation.flowID,
                direction: endpointDirection
            ))
        }
        await emit(
            .flowStopped(flowID: generation.flowID, reason: reason)
        )
        if finishingGeneration == generation {
            finishingGeneration = nil
        }
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
