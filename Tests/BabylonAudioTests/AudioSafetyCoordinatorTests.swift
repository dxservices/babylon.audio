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

    @Test("Device events and caller configuration use serialized transitions")
    func eventsAndConfigurationAreSerialized() async throws {
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

        let configuration = Task {
            try await coordinator.performConfiguration {
                recorder.actions.append(.configure)
            }
        }
        let secondHandling = Task {
            await coordinator.handle(secondEvent)
        }
        for _ in 0..<10 { await Task.yield() }

        #expect(!recorder.actions.contains(.configure))
        #expect(recorder.actions.filter { $0 == .muteOutput }.count == 3)

        buffers.resumeFirstDiscard()
        await eventSink.waitUntilFirstDeliveryStarts()
        try await configuration.value

        #expect(recorder.actions == [
            .muteOutput,
            .muteOutput,
            .stopCapture,
            .stopPlayback,
            .discardPendingAudio,
            .muteOutput,
            .deactivateSession,
            .deliverEvent(firstEvent),
            .configure,
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
        for _ in 0..<10 { await Task.yield() }

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
        case deliverEvent(AudioDeviceEvent)
    }

    var actions: [Action] = []
}

@MainActor
private final class RecordingHardware: AudioHardwareSafetyControlling {
    private let recorder: SafetyActionRecorder

    init(recorder: SafetyActionRecorder) {
        self.recorder = recorder
    }

    func muteOutput() {
        recorder.actions.append(.muteOutput)
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
