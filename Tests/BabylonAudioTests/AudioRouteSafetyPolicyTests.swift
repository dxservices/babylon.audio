import Testing
@testable import BabylonAudio

@Suite("Audio route safety policy")
struct AudioRouteSafetyPolicyTests {
    @Test("Wired headphones are safe without stored trust")
    func wiredHeadphonesAreSafe() {
        let output = port("wired", kind: .wiredHeadphones)
        let route = route(
            input: port("mic", kind: .builtInMicrophone),
            output: output
        )

        #expect(AudioRouteSafetyPolicy.evaluate(
            route,
            inputPolicy: .builtInMicrophoneRequired,
            trustedOutputs: []
        ) == .safe(output: output))
    }

    @Test("Bluetooth output requires an exact caller-owned trust record")
    func bluetoothRequiresExactTrust() {
        let output = port("airpods", name: "AirPods", kind: .bluetoothA2DP)
        let route = route(
            input: port("mic", kind: .builtInMicrophone),
            output: output
        )

        #expect(AudioRouteSafetyPolicy.evaluate(
            route,
            inputPolicy: .builtInMicrophoneRequired,
            trustedOutputs: []
        ) == .trustRequired(output: output))
        #expect(AudioRouteSafetyPolicy.evaluate(
            route,
            inputPolicy: .builtInMicrophoneRequired,
            trustedOutputs: [AudioTrustedOutput(output: output)]
        ) == .safe(output: output))
        #expect(AudioRouteSafetyPolicy.evaluate(
            route,
            inputPolicy: .builtInMicrophoneRequired,
            trustedOutputs: [AudioTrustedOutput(
                id: output.id,
                name: "Renamed Device",
                kind: output.kind
            )]
        ) == .trustRequired(output: output))
    }

    @Test("Bluetooth LE follows the same caller-owned trust boundary")
    func bluetoothLERequiresTrust() {
        let output = port("le-headset", kind: .bluetoothLE)
        let route = route(
            input: port("mic", kind: .builtInMicrophone),
            output: output
        )

        #expect(AudioRouteSafetyPolicy.evaluate(
            route,
            inputPolicy: .builtInMicrophoneRequired,
            trustedOutputs: []
        ) == .trustRequired(output: output))
        #expect(AudioRouteSafetyPolicy.evaluate(
            route,
            inputPolicy: .builtInMicrophoneRequired,
            trustedOutputs: [AudioTrustedOutput(output: output)]
        ) == .safe(output: output))
    }

    @Test("HFP is rejected when the input policy forbids accessory duplex")
    func hfpMustBeExplicitlyAllowed() {
        let input = port("headset-mic", kind: .bluetoothHFP)
        let output = port("headset", kind: .bluetoothHFP)
        let route = route(input: input, output: output)

        #expect(AudioRouteSafetyPolicy.evaluate(
            route,
            inputPolicy: .builtInMicrophoneRequired,
            trustedOutputs: [AudioTrustedOutput(output: output)]
        ) == .unsafe(reason: .hfpForbidden))
    }

    @Test("Only the explicit duplex policy includes an HFP activation profile")
    func activationProfilesMakeHFPExplicit() {
        #expect(AudioSessionProfilePolicy.activationOrder(
            for: .builtInMicrophoneRequired
        ) == [.builtInMicrophoneWithPrivateOutput])
        #expect(AudioSessionProfilePolicy.activationOrder(
            for: .preferBuiltInAllowPrivateAccessoryDuplex
        ) == [
            .builtInMicrophoneWithPrivateOutput,
            .privateAccessoryDuplex,
        ])
    }

    @Test("An explicitly allowed trusted HFP duplex route is safe")
    func allowedHFPIsSafe() {
        let input = port("headset-mic", kind: .bluetoothHFP)
        let output = port("headset", kind: .bluetoothHFP)
        let route = route(input: input, output: output)

        #expect(AudioRouteSafetyPolicy.evaluate(
            route,
            inputPolicy: .preferBuiltInAllowPrivateAccessoryDuplex,
            trustedOutputs: [AudioTrustedOutput(output: output)]
        ) == .safe(output: output))
    }

    @Test("The actual input must satisfy the selected input policy")
    func actualInputIsValidated() {
        let output = port("wired", kind: .wiredHeadphones)
        let route = route(
            input: port("headset-mic", kind: .headsetMicrophone),
            output: output
        )

        #expect(AudioRouteSafetyPolicy.evaluate(
            route,
            inputPolicy: .builtInMicrophoneRequired,
            trustedOutputs: []
        ) == .unsafe(reason: .inputPolicyViolation))
        #expect(AudioRouteSafetyPolicy.evaluate(
            route,
            inputPolicy: .preferBuiltInAllowPrivateAccessoryDuplex,
            trustedOutputs: []
        ) == .safe(output: output))
    }

    @Test("Missing or multiple current inputs fail closed")
    func missingOrMultipleInputsFailClosed() {
        let output = port("wired", kind: .wiredHeadphones)
        let builtIn = port("mic", kind: .builtInMicrophone)
        let accessory = port("headset-mic", kind: .headsetMicrophone)
        let missing = AudioRouteSnapshot(
            inputs: [],
            outputs: [output],
            availableInputs: []
        )
        let multiple = AudioRouteSnapshot(
            inputs: [builtIn, accessory],
            outputs: [output],
            availableInputs: []
        )

        #expect(AudioRouteSafetyPolicy.evaluate(
            missing,
            inputPolicy: .builtInMicrophoneRequired,
            trustedOutputs: []
        ) == .unsafe(reason: .inputPolicyViolation))
        #expect(AudioRouteSafetyPolicy.evaluate(
            multiple,
            inputPolicy: .preferBuiltInAllowPrivateAccessoryDuplex,
            trustedOutputs: []
        ) == .unsafe(reason: .inputPolicyViolation))
    }

    @Test("Mixed or multiple outputs fail closed")
    func mixedOutputsFailClosed() {
        let headphones = port("wired", kind: .wiredHeadphones)
        let speaker = port("speaker", kind: .builtInSpeaker)
        let route = AudioRouteSnapshot(
            inputs: [port("mic", kind: .builtInMicrophone)],
            outputs: [headphones, speaker],
            availableInputs: []
        )

        #expect(AudioRouteSafetyPolicy.evaluate(
            route,
            inputPolicy: .builtInMicrophoneRequired,
            trustedOutputs: []
        ) == .unsafe(reason: .mixedOrMultipleOutputs))
    }

    @Test("Public and missing outputs fail closed")
    func publicAndMissingOutputsFailClosed() {
        let input = port("mic", kind: .builtInMicrophone)
        let speakerRoute = route(
            input: input,
            output: port("speaker", kind: .builtInSpeaker)
        )
        let emptyRoute = AudioRouteSnapshot(
            inputs: [input],
            outputs: [],
            availableInputs: []
        )

        #expect(AudioRouteSafetyPolicy.evaluate(
            speakerRoute,
            inputPolicy: .builtInMicrophoneRequired,
            trustedOutputs: []
        ) == .unsafe(reason: .nonPrivateOutput))
        #expect(AudioRouteSafetyPolicy.evaluate(
            emptyRoute,
            inputPolicy: .builtInMicrophoneRequired,
            trustedOutputs: []
        ) == .unsafe(reason: .outputUnavailable))
    }

    @Test("Only current output changes cross the playback safety boundary")
    func outputComparisonIgnoresInputDiscovery() {
        let output = port("wired", kind: .wiredHeadphones)
        let first = AudioRouteSnapshot(
            inputs: [port("mic", kind: .builtInMicrophone)],
            outputs: [output],
            availableInputs: []
        )
        let discoveredInput = AudioRouteSnapshot(
            inputs: first.inputs,
            outputs: first.outputs,
            availableInputs: [port("candidate", kind: .bluetoothHFP)]
        )

        #expect(first.hasSameOutputs(as: discoveredInput))
    }

    private func port(
        _ id: String,
        name: String = "Test Port",
        kind: AudioRoutePortKind
    ) -> AudioRoutePort {
        AudioRoutePort(id: id, name: name, kind: kind)
    }

    private func route(
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
