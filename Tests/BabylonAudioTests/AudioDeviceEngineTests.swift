import Testing
@testable import BabylonAudio

@Suite("Audio device engine")
@MainActor
struct AudioDeviceEngineTests {
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
}

@MainActor
private final class RecordingDeviceEngineBackend: AudioDeviceEngineBackend {
    enum Action: Equatable {
        case start
        case stop
        case setOutputMuted(Bool)
        case stopCapture
        case stopPlayback
    }

    private(set) var actions: [Action] = []

    func start() throws {
        actions.append(.start)
    }

    func stop() {
        actions.append(.stop)
    }

    func setOutputMuted(_ muted: Bool) {
        actions.append(.setOutputMuted(muted))
    }

    func stopCapture() {
        actions.append(.stopCapture)
    }

    func stopPlayback() {
        actions.append(.stopPlayback)
    }
}
