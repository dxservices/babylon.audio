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
            .mediaServicesReset,
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
                .stopCapture,
                .stopPlayback,
                .discardPendingAudio,
                .deactivateSession,
                .deliverEvent(event),
            ])
        }
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
