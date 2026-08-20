import Foundation
import Testing
@testable import BabylonAudio

@Suite("Audio safety coordinator")
@MainActor
struct AudioSafetyCoordinatorTests {
    @Test("Safety events quiesce hardware and buffers before consumer delivery")
    func safetyEventsQuiesceBeforeDelivery() async {
        let events: [AudioDeviceEvent] = [
            .routeChanged(.empty),
            .interruptionBegan,
        ]

        for event in events {
            let recorder = SafetyActionRecorder()
            let coordinator = AudioSafetyCoordinator(
                hardware: RecordingHardware(recorder: recorder),
                buffers: RecordingBuffers(recorder: recorder),
                session: RecordingSafetySession(recorder: recorder),
                eventSink: RecordingDeviceEventSink(recorder: recorder)
            )

            let result = await coordinator.handle(event)

            #expect(result == AudioSafetyHandlingResult(
                engagedSafetyBoundary: true,
                sessionDeactivated: true
            ))
            #expect(recorder.actions == [
                .muteOutput,
                .muteOutput,
                .stopCapture,
                .stopPlayback,
                .discardPendingAudio,
                .deactivateSession,
                .deliverEvent(event),
            ])
        }
    }

    @Test("Pipeline cleanup completes before deactivation and device delivery")
    func pipelineCleanupPrecedesDeactivationAndDelivery() async throws {
        let recorder = SafetyActionRecorder()
        let flowID = AudioFlowID()
        let sender = SafetySuspendedSender()
        let receiver = SafetyControlledReceiver()
        let pipeline = AudioPipelineSession(configuration: try AudioPipelineConfiguration(
            source: .externalFrames,
            uplinkSender: sender,
            downlinkReceiver: receiver,
            downlinkSink: .external(SafetyRecordingSink()),
            eventSink: SafetyPipelineEventSink(recorder: recorder)
        ), uplinkPolicy: try BoundedUplinkQueuePolicy(
            maximumPendingAudioDuration: .seconds(1),
            maximumFrameAge: .seconds(2)
        ), downlinkPolicy: try BoundedDownlinkJitterBufferPolicy(
            targetBufferedAudioDuration: .milliseconds(200),
            maximumBufferedAudioDuration: .seconds(1),
            maximumFrameAge: .seconds(2)
        ))
        try await pipeline.start(flowID: flowID)
        #expect(await eventuallySafety { receiver.isReady() })
        try await pipeline.submit(
            makeSafetyFrame(flowID: flowID, sequence: 0)
        )
        try await pipeline.submit(
            makeSafetyFrame(flowID: flowID, sequence: 1)
        )
        receiver.yield(try makeSafetyFrame(flowID: flowID, sequence: 2))
        #expect(await eventuallySafety {
            let uplink = await pipeline.uplinkSnapshot
            let downlink = await pipeline.downlinkSnapshot
            return uplink.pending.frameCount == 1
                && downlink.pending.frameCount == 1
        })
        recorder.actions.removeAll()
        let coordinator = AudioSafetyCoordinator(
            hardware: RecordingHardware(recorder: recorder),
            buffers: AudioPipelineSafetyBufferController(session: pipeline),
            session: RecordingSafetySession(recorder: recorder),
            eventSink: RecordingDeviceEventSink(recorder: recorder)
        )

        let result = await coordinator.handle(.interruptionBegan)

        #expect(result == AudioSafetyHandlingResult(
            engagedSafetyBoundary: true,
            sessionDeactivated: true
        ))
        #expect(recorder.actions == [
            .muteOutput,
            .muteOutput,
            .stopCapture,
            .stopPlayback,
            .pipelineEvent(.flowStopped(
                flowID: flowID,
                reason: .safetyBoundary
            )),
            .deactivateSession,
            .deliverEvent(.interruptionBegan),
        ])
        #expect(await pipeline.snapshot.state == .stopped)
        #expect(await pipeline.uplinkSnapshot.pending == .zero)
        #expect(await pipeline.downlinkSnapshot.pending == .zero)
        await sender.complete()
    }

    @Test("Media reset rebuilds before delivery even if deactivation fails")
    func mediaResetRebuildsBeforeDelivery() async {
        let recorder = SafetyActionRecorder()
        let event = AudioDeviceEvent.mediaServicesReset
        let coordinator = AudioSafetyCoordinator(
            hardware: RecordingHardware(recorder: recorder),
            buffers: RecordingBuffers(recorder: recorder),
            session: RecordingSafetySession(
                recorder: recorder,
                deactivationFails: true
            ),
            eventSink: RecordingDeviceEventSink(recorder: recorder)
        )

        let result = await coordinator.handle(event)

        #expect(result == AudioSafetyHandlingResult(
            engagedSafetyBoundary: true,
            sessionDeactivated: false
        ))
        #expect(recorder.actions == [
            .muteOutput,
            .muteOutput,
            .stopCapture,
            .stopPlayback,
            .discardPendingAudio,
            .deactivateSession,
            .rebuildMediaServicesGraph,
            .deliverEvent(event),
        ])
    }

    @Test("A deactivation failure cannot skip consumer delivery")
    func deactivationFailureStillDeliversEvent() async {
        let recorder = SafetyActionRecorder()
        let event = AudioDeviceEvent.interruptionBegan
        let coordinator = AudioSafetyCoordinator(
            hardware: RecordingHardware(recorder: recorder),
            buffers: RecordingBuffers(recorder: recorder),
            session: RecordingSafetySession(
                recorder: recorder,
                deactivationFails: true
            ),
            eventSink: RecordingDeviceEventSink(recorder: recorder)
        )

        let result = await coordinator.handle(event)

        #expect(result == AudioSafetyHandlingResult(
            engagedSafetyBoundary: true,
            sessionDeactivated: false
        ))
        #expect(recorder.actions.last == .deliverEvent(event))
    }

    @Test("Interruption end only reports a fact and never resumes hardware")
    func interruptionEndDoesNotResumeHardware() async {
        let recorder = SafetyActionRecorder()
        let event = AudioDeviceEvent.interruptionEnded(shouldResume: true)
        let coordinator = AudioSafetyCoordinator(
            hardware: RecordingHardware(recorder: recorder),
            buffers: RecordingBuffers(recorder: recorder),
            session: RecordingSafetySession(recorder: recorder),
            eventSink: RecordingDeviceEventSink(recorder: recorder)
        )

        let result = await coordinator.handle(event)

        #expect(result == AudioSafetyHandlingResult(
            engagedSafetyBoundary: false,
            sessionDeactivated: false
        ))
        #expect(recorder.actions == [.deliverEvent(event)])
    }

    @Test("A newer boundary rejects queued configuration until recovery opens")
    func newerBoundaryRejectsQueuedConfiguration() async {
        let recorder = SafetyActionRecorder()
        let buffers = SuspendedFirstBuffers(recorder: recorder)
        let eventSink = SuspendedFirstDeviceEventSink(recorder: recorder)
        let coordinator = AudioSafetyCoordinator(
            hardware: RecordingHardware(recorder: recorder),
            buffers: buffers,
            session: RecordingSafetySession(recorder: recorder),
            eventSink: eventSink
        )
        let firstEvent = AudioDeviceEvent.interruptionBegan
        let secondEvent = AudioDeviceEvent.mediaServicesReset

        let firstHandling = Task {
            await coordinator.handle(firstEvent)
        }
        await buffers.waitUntilFirstDiscardStarts()

        let configuration = Task { @MainActor in
            do {
                try await coordinator.performConfiguration {
                    recorder.actions.append(.configure)
                }
                return nil as AudioSafetyCoordinatorError?
            } catch let error as AudioSafetyCoordinatorError {
                return error
            } catch {
                Issue.record("Unexpected configuration error")
                return nil
            }
        }
        let secondHandling = Task {
            await coordinator.handle(secondEvent)
        }
        await recorder.waitUntilMuteCount(3)

        #expect(!recorder.actions.contains(.configure))
        #expect(recorder.actions.filter { $0 == .muteOutput }.count == 3)

        buffers.resumeFirstDiscard()
        await eventSink.waitUntilFirstDeliveryStarts()
        #expect(await configuration.value == .recoveryClosed)

        #expect(recorder.actions == [
            .muteOutput,
            .muteOutput,
            .stopCapture,
            .stopPlayback,
            .discardPendingAudio,
            .muteOutput,
            .deactivateSession,
            .deliverEvent(firstEvent),
        ])

        eventSink.resumeFirstDelivery()
        _ = await firstHandling.value
        _ = await secondHandling.value

        #expect(recorder.actions.suffix(7) == [
            .muteOutput,
            .stopCapture,
            .stopPlayback,
            .discardPendingAudio,
            .deactivateSession,
            .rebuildMediaServicesGraph,
            .deliverEvent(secondEvent),
        ])

        do {
            try await coordinator.performConfiguration {
                recorder.actions.append(.configure)
            }
        } catch {
            Issue.record("Expected recovery to reopen after the latest boundary")
        }
        #expect(recorder.actions.last == .configure)
    }

    @Test("Event sink can await configuration while the next event stays queued")
    func eventSinkCanAwaitConfiguration() async {
        let recorder = SafetyActionRecorder()
        let eventSink = ConfiguringFirstDeviceEventSink(recorder: recorder)
        let coordinator = AudioSafetyCoordinator(
            hardware: RecordingHardware(recorder: recorder),
            buffers: RecordingBuffers(recorder: recorder),
            session: RecordingSafetySession(recorder: recorder),
            eventSink: eventSink
        )
        eventSink.coordinator = coordinator

        let firstHandling = Task {
            await coordinator.handle(.interruptionBegan)
        }
        await eventSink.waitUntilConfigurationStarts()

        let secondHandling = Task {
            await coordinator.handle(.mediaServicesReset)
        }
        await recorder.waitUntilMuteCount(3)

        #expect(recorder.actions.last == .muteOutput)
        #expect(recorder.actions.filter { $0 == .stopCapture }.count == 1)
        #expect(!recorder.actions.contains(.rebuildMediaServicesGraph))

        eventSink.resumeConfiguration()
        _ = await firstHandling.value
        _ = await secondHandling.value

        #expect(!eventSink.configurationFailed)
        #expect(recorder.actions.filter { $0 == .stopCapture }.count == 2)
        #expect(recorder.actions.contains(.rebuildMediaServicesGraph))
    }

    @Test("A configuration permit can unmute only inside its operation")
    func configurationPermitUnmutesInsideOperation() async throws {
        let recorder = SafetyActionRecorder()
        let backend = PermitEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)
        let coordinator = AudioSafetyCoordinator(
            hardware: RecordingHardware(recorder: recorder),
            buffers: RecordingBuffers(recorder: recorder),
            session: RecordingSafetySession(recorder: recorder),
            eventSink: RecordingDeviceEventSink(recorder: recorder)
        )

        try await coordinator.performConfiguration { permit in
            try engine.unmuteOutput(
                after: .safe(output: Self.safeOutput),
                permit: permit
            )
        }

        #expect(!engine.isOutputMuted)
        #expect(backend.unmuteCount == 1)
    }

    @Test("A configuration permit is revoked when its operation returns")
    func escapedConfigurationPermitCannotUnmute() async throws {
        let recorder = SafetyActionRecorder()
        let backend = PermitEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)
        let coordinator = AudioSafetyCoordinator(
            hardware: RecordingHardware(recorder: recorder),
            buffers: RecordingBuffers(recorder: recorder),
            session: RecordingSafetySession(recorder: recorder),
            eventSink: RecordingDeviceEventSink(recorder: recorder)
        )
        let permit = try await coordinator.performConfiguration { permit in
            permit
        }

        #expect(throws: AudioSafetyCoordinatorError.invalidConfigurationPermit) {
            try engine.unmuteOutput(
                after: .safe(output: Self.safeOutput),
                permit: permit
            )
        }
        #expect(engine.isOutputMuted)
        #expect(backend.unmuteCount == 0)
    }

    @Test("A boundary invalidates a suspended configuration permit before unmute")
    func boundaryInvalidatesSuspendedUnmute() async {
        let recorder = SafetyActionRecorder()
        let backend = PermitEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)
        let gate = SafetyConfigurationGate()
        let coordinator = AudioSafetyCoordinator(
            hardware: RecordingHardware(recorder: recorder),
            buffers: RecordingBuffers(recorder: recorder),
            session: RecordingSafetySession(recorder: recorder),
            eventSink: RecordingDeviceEventSink(recorder: recorder)
        )

        let configuration = Task { @MainActor in
            do {
                try await coordinator.performConfiguration { permit in
                    await gate.suspend()
                    try engine.unmuteOutput(
                        after: .safe(output: Self.safeOutput),
                        permit: permit
                    )
                }
                return nil as AudioSafetyCoordinatorError?
            } catch let error as AudioSafetyCoordinatorError {
                return error
            } catch {
                Issue.record("Unexpected unmute error")
                return nil
            }
        }
        await gate.waitUntilSuspended()

        let boundary = Task { @MainActor in
            await coordinator.handle(.interruptionBegan)
        }
        await recorder.waitUntilMuteCount(1)
        gate.resume()

        #expect(await configuration.value == .invalidConfigurationPermit)
        _ = await boundary.value
        #expect(engine.isOutputMuted)
        #expect(backend.unmuteCount == 0)
    }

    @Test("A second boundary invalidates the previous recovery permit")
    func secondBoundaryInvalidatesRecoveryPermit() async {
        let recorder = SafetyActionRecorder()
        let backend = PermitEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)
        let gate = SafetyConfigurationGate()
        let coordinator = AudioSafetyCoordinator(
            hardware: RecordingHardware(recorder: recorder),
            buffers: RecordingBuffers(recorder: recorder),
            session: RecordingSafetySession(recorder: recorder),
            eventSink: RecordingDeviceEventSink(recorder: recorder)
        )
        _ = await coordinator.handle(.interruptionBegan)

        let recovery = Task { @MainActor in
            do {
                try await coordinator.performConfiguration { permit in
                    await gate.suspend()
                    try engine.unmuteOutput(
                        after: .safe(output: Self.safeOutput),
                        permit: permit
                    )
                }
                return nil as AudioSafetyCoordinatorError?
            } catch let error as AudioSafetyCoordinatorError {
                return error
            } catch {
                Issue.record("Unexpected recovery error")
                return nil
            }
        }
        await gate.waitUntilSuspended()

        let secondBoundary = Task { @MainActor in
            await coordinator.handle(.mediaServicesReset)
        }
        await recorder.waitUntilMuteCount(3)
        gate.resume()

        #expect(await recovery.value == .invalidConfigurationPermit)
        _ = await secondBoundary.value
        #expect(engine.isOutputMuted)
        #expect(backend.unmuteCount == 0)
    }

    @Test("The streaming buffer adapter stops both flow generations")
    func streamingBuffersStopTogether() async throws {
        let sender = SuspendedSafetySender()
        let sink = SuspendedSafetySink()
        let uplink = BoundedUplinkQueue(
            policy: try BoundedUplinkQueuePolicy(
                maximumPendingAudioDuration: .seconds(1),
                maximumFrameAge: .seconds(2)
            )
        )
        let downlink = BoundedDownlinkJitterBuffer(
            policy: try BoundedDownlinkJitterBufferPolicy(
                targetBufferedAudioDuration: .milliseconds(20),
                maximumBufferedAudioDuration: .seconds(1),
                maximumFrameAge: .seconds(2)
            )
        )
        let flowID = AudioFlowID()
        await uplink.start(flowID: flowID, sender: sender)
        await downlink.start(flowID: flowID, sink: sink)
        await uplink.enqueue(try makeSafetyFrame(flowID: flowID, sequence: 0))
        await uplink.enqueue(try makeSafetyFrame(flowID: flowID, sequence: 1))
        await downlink.enqueue(try makeSafetyFrame(flowID: flowID, sequence: 0))
        await downlink.enqueue(try makeSafetyFrame(flowID: flowID, sequence: 1))
        for _ in 0..<10 { await Task.yield() }

        let buffers = AudioStreamingSafetyBufferController(
            uplink: uplink,
            downlink: downlink
        )
        await buffers.discardPendingAudio()

        #expect(!(await uplink.snapshot.isRunning))
        #expect(await uplink.snapshot.pending == .zero)
        #expect(!(await downlink.snapshot.isRunning))
        #expect(await downlink.snapshot.pending == .zero)
        await sender.completeAll()
        await sink.completeAll()
    }

    private func makeSafetyFrame(
        flowID: AudioFlowID,
        sequence: UInt64
    ) throws -> AudioFrame {
        try AudioFrame(
            flowID: flowID,
            sequence: sequence,
            timestamp: .milliseconds(Int64(sequence * 20)),
            format: .monoPCM16(sampleRate: 16_000),
            payload: Data(count: 640),
            duration: .milliseconds(20)
        )
    }

    private static let safeOutput = AudioRoutePort(
        id: "wired",
        name: "Wired Headphones",
        kind: .wiredHeadphones
    )
}

@MainActor
private final class SafetyActionRecorder {
    enum Action: Equatable {
        case muteOutput
        case stopCapture
        case stopPlayback
        case discardPendingAudio
        case deactivateSession
        case rebuildMediaServicesGraph
        case configure
        case pipelineEvent(AudioEvent)
        case deliverEvent(AudioDeviceEvent)
    }

    var actions: [Action] = []
    private var muteCountWaiters:
        [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record(_ action: Action) {
        actions.append(action)
        guard action == .muteOutput else { return }
        let muteCount = actions.filter { $0 == .muteOutput }.count
        let ready = muteCountWaiters.filter { $0.target <= muteCount }
        muteCountWaiters.removeAll { $0.target <= muteCount }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func waitUntilMuteCount(_ target: Int) async {
        let muteCount = actions.filter { $0 == .muteOutput }.count
        guard muteCount < target else { return }
        await withCheckedContinuation { continuation in
            muteCountWaiters.append((target, continuation))
        }
    }
}

private actor SafetyRecordingSink: AudioFrameSink {
    func consume(_ frame: AudioFrame) async throws {}
}

private actor SafetySuspendedSender: AudioFrameSender {
    private var continuation: CheckedContinuation<Void, Never>?

    func send(_ frame: AudioFrame) async throws {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func complete() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

private final class SafetyControlledReceiver:
    AudioFrameReceiver,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var continuation:
        AsyncThrowingStream<AudioFrame, any Error>.Continuation?

    func frames(
        for flowID: AudioFlowID
    ) -> AsyncThrowingStream<AudioFrame, any Error> {
        AsyncThrowingStream { continuation in
            lock.withLock {
                self.continuation = continuation
            }
        }
    }

    func isReady() -> Bool {
        lock.withLock { continuation != nil }
    }

    func yield(_ frame: AudioFrame) {
        let current = lock.withLock { continuation }
        current?.yield(frame)
    }
}

private struct SafetyPipelineEventSink: AudioEventSink {
    let recorder: SafetyActionRecorder

    func receive(_ event: AudioEvent) async {
        await recorder.record(.pipelineEvent(event))
    }
}

private func eventuallySafety(
    _ predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<1_000 {
        if await predicate() { return true }
        await Task.yield()
    }
    return false
}

@MainActor
private final class RecordingHardware: AudioHardwareSafetyControlling {
    private let recorder: SafetyActionRecorder

    init(recorder: SafetyActionRecorder) {
        self.recorder = recorder
    }

    func muteOutput() {
        recorder.record(.muteOutput)
    }

    func stopCapture() {
        recorder.actions.append(.stopCapture)
    }

    func stopPlayback() {
        recorder.actions.append(.stopPlayback)
    }

    func rebuildAfterMediaServicesReset() {
        recorder.actions.append(.rebuildMediaServicesGraph)
    }
}

@MainActor
private final class RecordingBuffers: AudioPendingAudioDiscarding {
    private let recorder: SafetyActionRecorder

    init(recorder: SafetyActionRecorder) {
        self.recorder = recorder
    }

    func discardPendingAudio() async {
        recorder.actions.append(.discardPendingAudio)
    }
}

@MainActor
private final class SuspendedFirstBuffers: AudioPendingAudioDiscarding {
    private let recorder: SafetyActionRecorder
    private var discardCount = 0
    private var firstDiscardStarted = false
    private var firstDiscardStartedWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var firstDiscardContinuation: CheckedContinuation<Void, Never>?

    init(recorder: SafetyActionRecorder) {
        self.recorder = recorder
    }

    func discardPendingAudio() async {
        recorder.actions.append(.discardPendingAudio)
        discardCount += 1
        guard discardCount == 1 else { return }

        firstDiscardStarted = true
        let waiters = firstDiscardStartedWaiters
        firstDiscardStartedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            firstDiscardContinuation = continuation
        }
    }

    func waitUntilFirstDiscardStarts() async {
        guard !firstDiscardStarted else { return }
        await withCheckedContinuation { continuation in
            firstDiscardStartedWaiters.append(continuation)
        }
    }

    func resumeFirstDiscard() {
        firstDiscardContinuation?.resume()
        firstDiscardContinuation = nil
    }
}

@MainActor
private final class RecordingDeviceEventSink: AudioDeviceEventSink {
    private let recorder: SafetyActionRecorder

    init(recorder: SafetyActionRecorder) {
        self.recorder = recorder
    }

    func receive(_ event: AudioDeviceEvent) async {
        recorder.actions.append(.deliverEvent(event))
    }
}

@MainActor
private final class SuspendedFirstDeviceEventSink: AudioDeviceEventSink {
    private let recorder: SafetyActionRecorder
    private var deliveryCount = 0
    private var firstDeliveryStarted = false
    private var firstDeliveryStartedWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var firstDeliveryContinuation: CheckedContinuation<Void, Never>?

    init(recorder: SafetyActionRecorder) {
        self.recorder = recorder
    }

    func receive(_ event: AudioDeviceEvent) async {
        recorder.actions.append(.deliverEvent(event))
        deliveryCount += 1
        guard deliveryCount == 1 else { return }

        firstDeliveryStarted = true
        let waiters = firstDeliveryStartedWaiters
        firstDeliveryStartedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            firstDeliveryContinuation = continuation
        }
    }

    func waitUntilFirstDeliveryStarts() async {
        guard !firstDeliveryStarted else { return }
        await withCheckedContinuation { continuation in
            firstDeliveryStartedWaiters.append(continuation)
        }
    }

    func resumeFirstDelivery() {
        firstDeliveryContinuation?.resume()
        firstDeliveryContinuation = nil
    }
}

@MainActor
private final class ConfiguringFirstDeviceEventSink: AudioDeviceEventSink {
    weak var coordinator: AudioSafetyCoordinator?
    private(set) var configurationFailed = false

    private let recorder: SafetyActionRecorder
    private var deliveryCount = 0
    private var configurationStarted = false
    private var configurationStartedWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var configurationContinuation: CheckedContinuation<Void, Never>?

    init(recorder: SafetyActionRecorder) {
        self.recorder = recorder
    }

    func receive(_ event: AudioDeviceEvent) async {
        recorder.actions.append(.deliverEvent(event))
        deliveryCount += 1
        guard deliveryCount == 1, let coordinator else { return }

        do {
            try await coordinator.performConfiguration {
                self.recorder.actions.append(.configure)
                self.configurationStarted = true
                let waiters = self.configurationStartedWaiters
                self.configurationStartedWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
                await withCheckedContinuation { continuation in
                    self.configurationContinuation = continuation
                }
            }
        } catch {
            configurationFailed = true
        }
    }

    func waitUntilConfigurationStarts() async {
        guard !configurationStarted else { return }
        await withCheckedContinuation { continuation in
            configurationStartedWaiters.append(continuation)
        }
    }

    func resumeConfiguration() {
        configurationContinuation?.resume()
        configurationContinuation = nil
    }
}

@MainActor
private final class SafetyConfigurationGate {
    private var isSuspended = false
    private var suspendedWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        let waiters = suspendedWaiters
        suspendedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            suspendedWaiters.append(continuation)
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class PermitEngineBackend: AudioDeviceEngineBackend {
    private(set) var unmuteCount = 0

    func start() throws {}
    func stop() {}
    func configurePlayback(format: AudioStreamFormat) throws {}
    func configureVoiceProcessing(
        _ policy: AudioVoiceProcessingPolicy
    ) throws {}
    func schedulePlayback(_ frame: AudioFrame) async throws {}
    func setOutputMuted(_ muted: Bool) {
        if !muted {
            unmuteCount += 1
        }
    }
    func startCapture(
        configuration: AudioCaptureConfiguration,
        onFrame: @escaping AudioCaptureFrameHandler,
        onFailure: AudioCaptureFailureHandler?
    ) throws {}
    func stopCapture() {}
    func stopPlayback() {}
    func rebuildAfterMediaServicesReset() {}
}

@MainActor
private final class RecordingSafetySession: AudioSessionControlling {
    let routeSnapshot = AudioRouteSnapshot.empty

    private let recorder: SafetyActionRecorder
    private let deactivationFails: Bool

    init(
        recorder: SafetyActionRecorder,
        deactivationFails: Bool = false
    ) {
        self.recorder = recorder
        self.deactivationFails = deactivationFails
    }

    func activate(_ profile: AudioSessionProfile) throws {}

    func deactivate() throws {
        recorder.actions.append(.deactivateSession)
        if deactivationFails {
            throw SafetyCoordinatorTestError.deactivationFailed
        }
    }

    func selectPrivateAccessoryInput(id: String) throws -> Bool { false }
}

private enum SafetyCoordinatorTestError: Error {
    case deactivationFailed
}

private actor SuspendedSafetySender: AudioFrameSender {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func send(_ frame: AudioFrame) async throws {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func completeAll() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor SuspendedSafetySink: AudioFrameSink {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func consume(_ frame: AudioFrame) async throws {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func completeAll() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
