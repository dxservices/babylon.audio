import Foundation
import Testing
@testable import BabylonAudio

@Suite("Audio device engine")
@MainActor
struct AudioDeviceEngineTests {
    @Test("Capture callback overflow becomes a visible bounded failure")
    func captureCallbackOverflowIsVisible() async {
        let bridge = BoundedAudioCaptureBridge(capacity: 2)

        bridge.offer(AudioCaptureChunk(payload: Data([0])))
        bridge.offer(AudioCaptureChunk(payload: Data([1])))
        bridge.offer(AudioCaptureChunk(payload: Data([2])))
        bridge.offer(AudioCaptureChunk(payload: Data([3])))

        var received: [AudioCaptureHandoffEvent] = []
        for await event in bridge.stream {
            received.append(event)
        }
        #expect(received == [
            .chunk(AudioCaptureChunk(payload: Data([2]))),
            .failure(.captureHandoffOverflow),
        ])
    }

    @Test("Hardware callbacks may use the configured buffered-duration bound")
    func hardwareCallbackUsesBufferedDurationBound() throws {
        let configuration = try makeCaptureConfiguration()

        #expect(configuration.tapBufferFrameCapacity(sampleRate: 48_000) == 960)
        #expect(configuration.maximumCallbackFrameCapacity(
            sampleRate: 48_000
        ) == 4_800)
    }

    @Test("Capture requires a running engine and has one active tap")
    func captureLifecycleIsExclusive() throws {
        let backend = RecordingDeviceEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)
        let configuration = try makeCaptureConfiguration()

        #expect(throws: AudioDeviceEngineError.engineNotRunning) {
            try engine.startCapture(configuration: configuration) { _ in }
        }

        try engine.start()
        try engine.startCapture(configuration: configuration) { _ in }
        #expect(engine.isCapturing)
        #expect(throws: AudioDeviceEngineError.captureAlreadyRunning) {
            try engine.startCapture(configuration: configuration) { _ in }
        }

        engine.stopCapture()
        #expect(!engine.isCapturing)
        #expect(backend.actions == [
            .start,
            .startCapture(configuration),
            .stopCapture,
        ])
    }

    @Test("Capture delivery failure clears the public capture state")
    func captureFailureClearsState() async throws {
        let backend = RecordingDeviceEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)
        try engine.start()
        try engine.startCapture(
            configuration: makeCaptureConfiguration(),
            onFrame: { _ in },
            onFailure: { _ in }
        )

        await backend.failCapture()

        #expect(!engine.isCapturing)
    }

    @Test("Output can only unmute after a safe route evaluation")
    func unmuteRequiresSafeRoute() throws {
        let backend = RecordingDeviceEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)
        let output = AudioRoutePort(
            id: "wired",
            name: "Wired Headphones",
            kind: .wiredHeadphones
        )

        #expect(throws: AudioDeviceEngineError.unsafeRoute) {
            try engine.unmuteOutput(
                after: .trustRequired(output: output)
            )
        }
        #expect(backend.actions.isEmpty)

        try engine.unmuteOutput(after: .safe(output: output))
        #expect(!engine.isOutputMuted)
        #expect(backend.actions == [.setOutputMuted(false)])
    }

    @Test("Safety controls mute and stop both sides of the shared engine")
    func safetyControlsStopSharedEngineSides() throws {
        let backend = RecordingDeviceEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)
        let output = AudioRoutePort(
            id: "wired",
            name: "Wired Headphones",
            kind: .wiredHeadphones
        )
        try engine.start()
        try engine.unmuteOutput(after: .safe(output: output))

        engine.muteOutput()
        engine.stopCapture()
        engine.stopPlayback()
        engine.stop()

        #expect(engine.isOutputMuted)
        #expect(!engine.isRunning)
        #expect(backend.actions == [
            .start,
            .setOutputMuted(false),
            .setOutputMuted(true),
            .stopCapture,
            .stopPlayback,
            .stop,
        ])
    }

    private func makeCaptureConfiguration() throws -> AudioCaptureConfiguration {
        try AudioCaptureConfiguration(
            flowID: AudioFlowID(),
            format: .monoPCM16(sampleRate: 16_000),
            frameDuration: .milliseconds(20),
            maximumBufferedDuration: .milliseconds(100),
            maximumFramesPerCallback: 8,
            maximumPendingCallbackCount: 4
        )
    }
}

@MainActor
private final class RecordingDeviceEngineBackend: AudioDeviceEngineBackend {
    enum Action: Equatable {
        case start
        case stop
        case setOutputMuted(Bool)
        case startCapture(AudioCaptureConfiguration)
        case stopCapture
        case stopPlayback
    }

    private(set) var actions: [Action] = []
    private var captureFailureHandler: AudioCaptureFailureHandler?

    func start() throws {
        actions.append(.start)
    }

    func stop() {
        actions.append(.stop)
    }

    func setOutputMuted(_ muted: Bool) {
        actions.append(.setOutputMuted(muted))
    }

    func startCapture(
        configuration: AudioCaptureConfiguration,
        onFrame: @escaping AudioCaptureFrameHandler,
        onFailure: AudioCaptureFailureHandler?
    ) throws {
        actions.append(.startCapture(configuration))
        captureFailureHandler = onFailure
    }

    func failCapture() async {
        await captureFailureHandler?(DeviceEngineTestError.captureFailed)
    }

    func stopCapture() {
        actions.append(.stopCapture)
    }

    func stopPlayback() {
        actions.append(.stopPlayback)
    }
}

private enum DeviceEngineTestError: Error {
    case captureFailed
}
