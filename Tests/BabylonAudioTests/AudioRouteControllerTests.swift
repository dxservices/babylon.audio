import Testing
@testable import BabylonAudio

@Suite("Audio route controller")
@MainActor
struct AudioRouteControllerTests {
    @Test("Built-in microphone policy never activates the HFP profile")
    func builtInPolicyNeverActivatesHFP() async throws {
        let backend = RecordingAudioSessionBackend(
            builtInRoute: makeRoute(
                input: port("mic", kind: .builtInMicrophone),
                output: port("speaker", kind: .builtInSpeaker)
            ),
            duplexRoute: .empty
        )
        let controller = AudioRouteController(
            session: backend,
            observationAttempts: 1,
            waitForRouteUpdate: {}
        )

        let result = try await controller.configure(
            inputPolicy: .builtInMicrophoneRequired,
            outputPolicy: .privateOutputRequired,
            trustedOutputs: []
        )

        #expect(result.safety == .unsafe(reason: .nonPrivateOutput))
        #expect(backend.actions == [
            .activate(.builtInMicrophoneWithPrivateOutput),
            .deactivate,
        ])
    }

    @Test("Explicit duplex policy falls back from A2DP profile to HFP")
    func explicitPolicyFallsBackToHFP() async throws {
        let hfpInput = port("headset-mic", kind: .bluetoothHFP)
        let hfpOutput = port("headset", kind: .bluetoothHFP)
        let backend = RecordingAudioSessionBackend(
            builtInRoute: makeRoute(
                input: port("mic", kind: .builtInMicrophone),
                output: port("speaker", kind: .builtInSpeaker)
            ),
            duplexRoute: AudioRouteSnapshot(
                inputs: [hfpInput],
                outputs: [hfpOutput],
                availableInputs: [hfpInput]
            )
        )
        let controller = AudioRouteController(
            session: backend,
            observationAttempts: 1,
            waitForRouteUpdate: {}
        )

        let result = try await controller.configure(
            inputPolicy: .preferBuiltInAllowPrivateAccessoryDuplex,
            outputPolicy: .privateOutputRequired,
            trustedOutputs: [AudioTrustedOutput(output: hfpOutput)]
        )

        #expect(result.activeProfile == .privateAccessoryDuplex)
        #expect(result.safety == .safe(output: hfpOutput))
        #expect(backend.actions == [
            .activate(.builtInMicrophoneWithPrivateOutput),
            .deactivate,
            .activate(.privateAccessoryDuplex),
            .selectInput(id: hfpInput.id),
        ])
    }

    @Test("An untrusted Bluetooth route deactivates before caller confirmation")
    func bluetoothRouteRequiresTrust() async throws {
        let output = port("airpods", kind: .bluetoothA2DP)
        let backend = RecordingAudioSessionBackend(
            builtInRoute: makeRoute(
                input: port("mic", kind: .builtInMicrophone),
                output: output
            ),
            duplexRoute: .empty
        )
        let controller = AudioRouteController(
            session: backend,
            observationAttempts: 1,
            waitForRouteUpdate: {}
        )

        let result = try await controller.configure(
            inputPolicy: .builtInMicrophoneRequired,
            outputPolicy: .privateOutputRequired,
            trustedOutputs: []
        )

        #expect(result.activeProfile == nil)
        #expect(result.safety == .trustRequired(output: output))
        #expect(backend.actions == [
            .activate(.builtInMicrophoneWithPrivateOutput),
            .deactivate,
        ])
    }

    @Test("Activation failure deactivates and rethrows the original error")
    func activationFailureCleansUp() async {
        let backend = RecordingAudioSessionBackend(
            builtInRoute: .empty,
            duplexRoute: .empty,
            activationError: .activationFailed
        )
        let controller = AudioRouteController(
            session: backend,
            observationAttempts: 1,
            waitForRouteUpdate: {}
        )

        do {
            _ = try await controller.configure(
                inputPolicy: .builtInMicrophoneRequired,
                outputPolicy: .privateOutputRequired,
                trustedOutputs: []
            )
            Issue.record("Expected activation to fail")
        } catch {
            #expect(error is AudioRouteControllerTestError)
        }
        #expect(backend.actions == [
            .activate(.builtInMicrophoneWithPrivateOutput),
            .deactivate,
        ])
    }

    private func port(
        _ id: String,
        kind: AudioRoutePortKind
    ) -> AudioRoutePort {
        AudioRoutePort(id: id, name: "Test Port", kind: kind)
    }

    private func makeRoute(
        input: AudioRoutePort,
        output: AudioRoutePort
    ) -> AudioRouteSnapshot {
        AudioRouteSnapshot(
            inputs: [input],
            outputs: [output],
            availableInputs: []
        )
    }
}

@MainActor
private final class RecordingAudioSessionBackend: AudioSessionControlling {
    enum Action: Equatable {
        case activate(AudioSessionProfile)
        case deactivate
        case selectInput(id: String)
    }

    private(set) var routeSnapshot: AudioRouteSnapshot = .empty
    private(set) var actions: [Action] = []

    private let builtInRoute: AudioRouteSnapshot
    private let duplexRoute: AudioRouteSnapshot
    private let activationError: AudioRouteControllerTestError?

    init(
        builtInRoute: AudioRouteSnapshot,
        duplexRoute: AudioRouteSnapshot,
        activationError: AudioRouteControllerTestError? = nil
    ) {
        self.builtInRoute = builtInRoute
        self.duplexRoute = duplexRoute
        self.activationError = activationError
    }

    func activate(_ profile: AudioSessionProfile) throws {
        actions.append(.activate(profile))
        if let activationError {
            throw activationError
        }
        switch profile {
        case .builtInMicrophoneWithPrivateOutput:
            routeSnapshot = builtInRoute
        case .privateAccessoryDuplex:
            routeSnapshot = duplexRoute
        }
    }

    func deactivate() throws {
        actions.append(.deactivate)
    }

    func selectPrivateAccessoryInput(id: String) throws -> Bool {
        actions.append(.selectInput(id: id))
        return true
    }
}

private enum AudioRouteControllerTestError: Error {
    case activationFailed
}
