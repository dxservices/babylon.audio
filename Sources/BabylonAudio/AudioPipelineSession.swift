import Foundation

@available(iOS 18, macOS 13, *)
public enum AudioPipelineSessionError: Error, Equatable, Sendable {
    case alreadyRunning
    case reusedFlowID
    case notRunning
    case externalFramesNotConfigured
    case frameFlowMismatch
    case deviceRuntimeRequired
    case startCancelledBySafetyBoundary
}

@available(iOS 18, macOS 13, *)
private struct PendingMicrophoneCaptureStart {
    let generation: AudioFlowGeneration
    let task: Task<AudioDeviceCaptureToken, any Error>
}

@available(iOS 18, macOS 13, *)
private struct PendingPipelineStartAttempt {
    let generation: AudioFlowGeneration
    let safetyRevision: UInt64
}

@available(iOS 18, macOS 13, *)
private struct AudioDeviceOwnedPlaybackSink: AudioFrameSink {
    let engine: AudioDeviceEngine
    let token: AudioDevicePlaybackToken

    func consume(_ frame: AudioFrame) async throws {
        try await engine.consume(frame, token: token)
    }
}

@available(iOS 18, macOS 13, *)
public actor AudioPipelineSession {
    private let configuration: AudioPipelineConfiguration
    private let deviceEngine: AudioDeviceEngine?
    private let uplink: BoundedUplinkQueue
    private let downlink: BoundedDownlinkJitterBuffer
    private let eventGate = AudioPipelineSerialGate()
    private let sourceGate = AudioPipelineSerialGate()
    private let safetyBoundaryLatch = AudioPipelineSafetyBoundaryLatch()
    private let startAttemptSuspension: (@Sendable () async -> Void)?
    private let sourcePostUplinkSuspension: (@Sendable () async -> Void)?
    private let stopWaitObservation: (@Sendable () -> Void)?

    private var activeGeneration: AudioFlowGeneration?
    private var activeSafetyRevision: UInt64?
    private var activeFlowHasStarted = false
    private var finishingGeneration: AudioFlowGeneration?
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingStartAttempt: PendingPipelineStartAttempt?
    private var pendingStartWaiters: [CheckedContinuation<Void, Never>] = []
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
    private var activePlaybackToken: AudioDevicePlaybackToken?
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
        startAttemptSuspension = nil
        sourcePostUplinkSuspension = nil
        stopWaitObservation = nil
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

    init(
        configuration: AudioPipelineConfiguration,
        deviceEngine: AudioDeviceEngine? = nil,
        uplinkPolicy: BoundedUplinkQueuePolicy = .initial,
        downlinkPolicy: BoundedDownlinkJitterBufferPolicy = .initial,
        startAttemptSuspension: @escaping @Sendable () async -> Void,
        sourcePostUplinkSuspension: (@Sendable () async -> Void)? = nil,
        stopWaitObservation: (@Sendable () -> Void)? = nil
    ) {
        self.configuration = configuration
        self.deviceEngine = deviceEngine
        self.startAttemptSuspension = startAttemptSuspension
        self.sourcePostUplinkSuspension = sourcePostUplinkSuspension
        self.stopWaitObservation = stopWaitObservation
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
              pendingStartAttempt == nil,
              pendingMicrophoneCaptureStart == nil
        else {
            throw AudioPipelineSessionError.alreadyRunning
        }
        guard !usedFlowIDs.contains(flowID) else {
            throw AudioPipelineSessionError.reusedFlowID
        }
        guard let safetyRevision = safetyBoundaryLatch.registerStartAttempt()
        else {
            throw AudioPipelineSessionError.startCancelledBySafetyBoundary
        }
        let generation = AudioFlowGeneration(flowID: flowID)
        pendingStartAttempt = PendingPipelineStartAttempt(
            generation: generation,
            safetyRevision: safetyRevision
        )

        do {
            try await beginStart(
                flowID: flowID,
                generation: generation,
                safetyRevision: safetyRevision
            )
        } catch {
            clearPendingStartAttempt(generation: generation)
            if safetyBoundaryLatch.wasInvalidated(since: safetyRevision) {
                if activeGeneration == generation {
                    await finish(
                        generation: generation,
                        reason: .safetyBoundary,
                        stopDownlink: true
                    )
                }
                throw AudioPipelineSessionError.startCancelledBySafetyBoundary
            }
            throw error
        }
    }

    private func beginStart(
        flowID: AudioFlowID,
        generation: AudioFlowGeneration,
        safetyRevision: UInt64
    ) async throws {
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

        await startAttemptSuspension?()
        try Task.checkCancellation()

        let usesDevicePlayback = configurationUsesDevicePlayback
        if usesDevicePlayback {
            try await validateDevicePlaybackRuntime()
        }
        try ensurePendingStartIsCurrent(
            generation: generation,
            safetyRevision: safetyRevision
        )

        let playbackToken = usesDevicePlayback
            ? await deviceEngine?.makePlaybackToken()
            : nil
        let devicePlaybackSink: (any AudioFrameSink)? = playbackToken.map {
            AudioDeviceOwnedPlaybackSink(engine: deviceEngine!, token: $0)
        }

        let localMonitorSink: (any AudioFrameSink)?
        switch configuration.localMonitorSink {
        case .external(let sink):
            localMonitorSink = sink
        case .device:
            localMonitorSink = devicePlaybackSink
        case nil:
            localMonitorSink = nil
        }

        let downlinkSink: (any AudioFrameSink)?
        switch configuration.downlinkSink {
        case .external(let sink):
            downlinkSink = sink
        case .device:
            downlinkSink = devicePlaybackSink
        case nil:
            downlinkSink = nil
        }

        guard safetyBoundaryLatch.activateStart(
            revision: safetyRevision,
            operation: {
                clearPendingStartAttempt(generation: generation)
                sourceProcessorChain?.reset()
                activeGeneration = generation
                activeSafetyRevision = safetyRevision
                activeFlowHasStarted = false
                naturalEndDirection = nil
                observedNaturalEndDirections = []
                state = .running
                activeLocalMonitorSink = localMonitorSink
                activePlaybackToken = playbackToken
                sourceFormat = nil
            }
        ) else {
            clearPendingStartAttempt(generation: generation)
            throw AudioPipelineSessionError.startCancelledBySafetyBoundary
        }
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
            guard try await startCanContinue(
                generation: generation,
                safetyRevision: safetyRevision
            ) else { return }
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
            guard try await startCanContinue(
                generation: generation,
                safetyRevision: safetyRevision
            ) else { return }
        }
        guard safetyBoundaryLatch.activateStart(
            revision: safetyRevision,
            operation: {
                guard activeGeneration == generation else { return }
                activeFlowHasStarted = true
                usedFlowIDs.insert(flowID)
            }
        ), activeGeneration == generation, activeFlowHasStarted else {
            if safetyBoundaryLatch.wasInvalidated(since: safetyRevision) {
                await finish(
                    generation: generation,
                    reason: .safetyBoundary,
                    stopDownlink: true
                )
                throw AudioPipelineSessionError.startCancelledBySafetyBoundary
            }
            return
        }
        await emit(.flowStarted(flowID: flowID))
        guard try await startCanContinue(
            generation: generation,
            safetyRevision: safetyRevision
        ) else { return }

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
            guard try await startCanContinue(
                generation: generation,
                safetyRevision: safetyRevision
            ) else { return }
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

    private func ensurePendingStartIsCurrent(
        generation: AudioFlowGeneration,
        safetyRevision: UInt64
    ) throws {
        guard pendingStartAttempt?.generation == generation,
              !safetyBoundaryLatch.wasInvalidated(since: safetyRevision)
        else {
            throw AudioPipelineSessionError.startCancelledBySafetyBoundary
        }
    }

    private func startCanContinue(
        generation: AudioFlowGeneration,
        safetyRevision: UInt64
    ) async throws -> Bool {
        guard safetyBoundaryLatch.wasInvalidated(since: safetyRevision) else {
            return activeGeneration == generation
        }
        if activeGeneration == generation {
            await finish(
                generation: generation,
                reason: .safetyBoundary,
                stopDownlink: true
            )
        }
        throw AudioPipelineSessionError.startCancelledBySafetyBoundary
    }

    private func clearPendingStartAttempt(generation: AudioFlowGeneration) {
        guard pendingStartAttempt?.generation == generation else { return }
        pendingStartAttempt = nil
        let waiters = pendingStartWaiters
        pendingStartWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
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
        for processedFrame in processedFrames {
            guard activeGeneration == generation else {
                await sourceGate.release()
                throw AudioPipelineSessionError.notRunning
            }
            if configuration.uplinkSender != nil {
                await uplink.enqueue(processedFrame)
                await sourcePostUplinkSuspension?()
            }
            guard activeGeneration == generation else {
                await sourceGate.release()
                throw AudioPipelineSessionError.notRunning
            }
            guard let localMonitorSink = activeLocalMonitorSink else {
                continue
            }
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
        if safetyBoundaryOwnsTerminal(generation: generation) {
            await finish(
                generation: generation,
                reason: .safetyBoundary,
                stopDownlink: true
            )
            return
        }
        sourceTask = nil
        observedNaturalEndDirections.insert(.source)
        guard claimNaturalEnd(
            direction: .source,
            generation: generation
        ) else { return }
        if safetyBoundaryOwnsTerminal(generation: generation) {
            await finish(
                generation: generation,
                reason: .safetyBoundary,
                stopDownlink: true
            )
            return
        }
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
        while true {
            if let generation = activeGeneration {
                await finish(
                    generation: generation,
                    reason: .consumerRequested,
                    stopDownlink: true
                )
                continue
            }
            if pendingStartAttempt != nil {
                await waitForPendingStartAttempt(
                    onWait: stopWaitObservation
                )
                continue
            }
            if finishingGeneration != nil {
                await waitForFinishingGeneration(
                    onWait: stopWaitObservation
                )
                continue
            }
            return
        }
    }

    nonisolated func latchSafetyBoundary() -> UInt64 {
        safetyBoundaryLatch.latch()
    }

    nonisolated func completeSafetyBoundary(revision: UInt64) {
        safetyBoundaryLatch.complete(revision: revision)
    }

    func stopForSafetyBoundary() async {
        while true {
            if let generation = activeGeneration {
                await finish(
                    generation: generation,
                    reason: .safetyBoundary,
                    stopDownlink: true
                )
                return
            }
            if pendingStartAttempt != nil {
                await waitForPendingStartAttempt()
                continue
            }
            if finishingGeneration != nil {
                await waitForFinishingGeneration()
                continue
            }
            return
        }
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
        if safetyBoundaryOwnsTerminal(generation: generation) {
            await finish(
                generation: generation,
                reason: .safetyBoundary,
                stopDownlink: true
            )
            return
        }
        receiverTask = nil
        observedNaturalEndDirections.insert(.downlink)
        guard claimNaturalEnd(
            direction: .downlink,
            generation: generation
        ) else { return }
        if safetyBoundaryOwnsTerminal(generation: generation) {
            await finish(
                generation: generation,
                reason: .safetyBoundary,
                stopDownlink: true
            )
            return
        }
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

    private func safetyBoundaryOwnsTerminal(
        generation: AudioFlowGeneration
    ) -> Bool {
        guard activeGeneration == generation,
              let activeSafetyRevision
        else {
            return false
        }
        return safetyBoundaryLatch.wasInvalidated(
            since: activeSafetyRevision
        )
    }

    private func finish(
        generation: AudioFlowGeneration,
        reason: AudioFlowStopReason,
        stopDownlink: Bool,
        endpointDirection: AudioDirection? = nil
    ) async {
        guard activeGeneration == generation else { return }
        let safetyOwnsTerminal = activeSafetyRevision.map {
            safetyBoundaryLatch.wasInvalidated(since: $0)
        } ?? false
        let finalReason: AudioFlowStopReason = safetyOwnsTerminal
            ? .safetyBoundary
            : reason
        let finalStopDownlink = safetyOwnsTerminal ? true : stopDownlink
        let finalEndpointDirection = safetyOwnsTerminal
            ? nil
            : endpointDirection
        let emitsTerminalEvent = activeFlowHasStarted
        activeGeneration = nil
        activeSafetyRevision = nil
        activeFlowHasStarted = false
        finishingGeneration = generation
        naturalEndDirection = nil
        state = .stopped
        let source = sourceTask
        sourceTask = nil
        let task = receiverTask
        receiverTask = nil
        let captureToken = microphoneCaptureToken
        microphoneCaptureToken = nil
        let playbackToken = activePlaybackToken
        activePlaybackToken = nil
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
        if let playbackToken {
            await deviceEngine?.stopPlayback(token: playbackToken)
        }
        await uplink.stop()
        if finalStopDownlink {
            await downlink.stop()
        }
        sourceProcessorChain?.reset()
        if emitsTerminalEvent, let finalEndpointDirection {
            await emit(.endpointFailed(
                flowID: generation.flowID,
                direction: finalEndpointDirection
            ))
        }
        if emitsTerminalEvent {
            await emit(
                .flowStopped(flowID: generation.flowID, reason: finalReason)
            )
        }
        if finishingGeneration == generation {
            finishingGeneration = nil
            let waiters = finishWaiters
            finishWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    private func waitForFinishingGeneration(
        onWait: (@Sendable () -> Void)? = nil
    ) async {
        guard finishingGeneration != nil else { return }
        await withCheckedContinuation { continuation in
            finishWaiters.append(continuation)
            onWait?()
        }
    }

    private func waitForPendingStartAttempt(
        onWait: (@Sendable () -> Void)? = nil
    ) async {
        guard pendingStartAttempt != nil else { return }
        await withCheckedContinuation { continuation in
            pendingStartWaiters.append(continuation)
            onWait?()
        }
    }

    private func emit(_ event: AudioEvent) async {
        guard let eventSink = configuration.eventSink else { return }
        await eventGate.acquire()
        let deliveryToken = AudioPipelineEventDeliveryToken()
        await AudioPipelineEventDeliveryContext.$token.withValue(
            deliveryToken
        ) {
            await eventSink.receive(event)
        }
        deliveryToken.deactivate()
        await eventGate.release()
    }
}

@available(iOS 18, macOS 13, *)
private final class AudioPipelineSafetyBoundaryLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var isBoundaryActive = false

    func registerStartAttempt() -> UInt64? {
        lock.withLock {
            guard !isBoundaryActive else { return nil }
            return revision
        }
    }

    func activateStart(
        revision expectedRevision: UInt64,
        operation: () -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isBoundaryActive, revision == expectedRevision else {
            return false
        }
        operation()
        return true
    }

    func latch() -> UInt64 {
        lock.withLock {
            precondition(revision < UInt64.max)
            revision += 1
            isBoundaryActive = true
            return revision
        }
    }

    func complete(revision completedRevision: UInt64) {
        lock.withLock {
            guard revision == completedRevision else { return }
            isBoundaryActive = false
        }
    }

    func wasInvalidated(since expectedRevision: UInt64) -> Bool {
        lock.withLock { revision != expectedRevision }
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
