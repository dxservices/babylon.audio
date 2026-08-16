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

    @Test("Stable unsafe routes use the configured confirmation threshold")
    func stableUnsafeRoutesExitEarly() async throws {
        let waitCounter = RouteWaitCounter()
        let backend = RecordingAudioSessionBackend(
            builtInRoute: makeRoute(
                input: port("mic", kind: .builtInMicrophone),
                output: port("speaker", kind: .builtInSpeaker)
            ),
            duplexRoute: .empty
        )
        let controller = AudioRouteController(
            session: backend,
            observationAttempts: 30,
            stableUnsafeConfirmations: 2,
            waitForRouteUpdate: {
                waitCounter.count += 1
            }
        )

        let result = try await controller.configure(
            inputPolicy: .preferBuiltInAllowPrivateAccessoryDuplex,
            outputPolicy: .privateOutputRequired,
            trustedOutputs: []
        )

        #expect(result.safety == .unsafe(reason: .outputUnavailable))
        #expect(waitCounter.count == 6)
        #expect(backend.actions == [
            .activate(.builtInMicrophoneWithPrivateOutput),
            .deactivate,
            .activate(.privateAccessoryDuplex),
            .deactivate,
        ])
    }

    @Test("Selected duplex input gets the full route-change observation window")
    func selectedDuplexInputDisablesEarlyExit() async throws {
        let waitCounter = RouteWaitCounter()
        let hfpInput = port("headset-mic", kind: .bluetoothHFP)
        let hfpOutput = port("headset", kind: .bluetoothHFP)
        let settlingRoute = AudioRouteSnapshot(
            inputs: [port("mic", kind: .builtInMicrophone)],
            outputs: [port("speaker", kind: .builtInSpeaker)],
            availableInputs: [hfpInput]
        )
        let backend = RecordingAudioSessionBackend(
            builtInRoute: makeRoute(
                input: port("mic", kind: .builtInMicrophone),
                output: port("speaker", kind: .builtInSpeaker)
            ),
            duplexRoute: settlingRoute
        )
        let controller = AudioRouteController(
            session: backend,
            observationAttempts: 10,
            stableUnsafeConfirmations: 1,
            waitForRouteUpdate: {
                waitCounter.count += 1
                if waitCounter.count == 5 {
                    backend.setRouteSnapshot(AudioRouteSnapshot(
                        inputs: [hfpInput],
                        outputs: [hfpOutput],
                        availableInputs: [hfpInput]
                    ))
                }
            }
        )

        let result = try await controller.configure(
            inputPolicy: .preferBuiltInAllowPrivateAccessoryDuplex,
            outputPolicy: .privateOutputRequired,
            trustedOutputs: [AudioTrustedOutput(output: hfpOutput)]
        )

        #expect(result.safety == .safe(output: hfpOutput))
        #expect(waitCounter.count == 5)
        #expect(backend.actions == [
            .activate(.builtInMicrophoneWithPrivateOutput),
            .deactivate,
            .activate(.privateAccessoryDuplex),
            .selectInput(id: hfpInput.id),
        ])
    }

    @Test("A changed route continues observation and may become safe")
    func changedRouteContinuesObservation() async throws {
        let waitCounter = RouteWaitCounter()
        let safeOutput = port("wired", kind: .wiredHeadphones)
        let backend = RecordingAudioSessionBackend(
            builtInRoute: makeRoute(
                input: port("mic", kind: .builtInMicrophone),
                output: port("speaker", kind: .builtInSpeaker)
            ),
            duplexRoute: .empty
        )
        let controller = AudioRouteController(
            session: backend,
            observationAttempts: 30,
            waitForRouteUpdate: {
                waitCounter.count += 1
                backend.setRouteSnapshot(AudioRouteSnapshot(
                    inputs: [self.port("mic", kind: .builtInMicrophone)],
                    outputs: [safeOutput],
                    availableInputs: []
                ))
            }
        )

        let result = try await controller.configure(
            inputPolicy: .builtInMicrophoneRequired,
            outputPolicy: .privateOutputRequired,
            trustedOutputs: []
        )

        #expect(result.safety == .safe(output: safeOutput))
        #expect(waitCounter.count == 1)
        #expect(backend.actions == [
            .activate(.builtInMicrophoneWithPrivateOutput),
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
private final class RouteWaitCounter {
    var count = 0
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

    func setRouteSnapshot(_ route: AudioRouteSnapshot) {
        routeSnapshot = route
    }
}

private enum AudioRouteControllerTestError: Error {
    case activationFailed
}
