public enum AudioRoutePortKind:
    String,
    CaseIterable,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    case wiredHeadphones
    case headsetMicrophone
    case bluetoothA2DP
    case bluetoothHFP
    case bluetoothLE
    case builtInMicrophone
    case builtInSpeaker
    case receiver
    case airPlay
    case carAudio
    case hdmi
    case other

    public var isBluetooth: Bool {
        switch self {
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            true
        default:
            false
        }
    }

    public var isPotentialPrivateOutput: Bool {
        self == .wiredHeadphones || isBluetooth
    }

    public var isPrivateInputCandidate: Bool {
        switch self {
        case .headsetMicrophone, .bluetoothHFP, .bluetoothLE:
            true
        default:
            false
        }
    }
}

public struct AudioRoutePort: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let kind: AudioRoutePortKind

    public init(id: String, name: String, kind: AudioRoutePortKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

public struct AudioRouteSnapshot: Equatable, Sendable {
    public static let empty = Self(inputs: [], outputs: [], availableInputs: [])

    public let inputs: [AudioRoutePort]
    public let outputs: [AudioRoutePort]
    public let availableInputs: [AudioRoutePort]

    public init(
        inputs: [AudioRoutePort],
        outputs: [AudioRoutePort],
        availableInputs: [AudioRoutePort]
    ) {
        self.inputs = inputs
        self.outputs = outputs
        self.availableInputs = availableInputs
    }

    /// Input discovery alone does not cross the playback safety boundary.
    public func hasSameOutputs(as other: Self) -> Bool {
        outputs == other.outputs
    }
}

/// A caller-owned record. BabylonAudio never persists trusted output choices.
public struct AudioTrustedOutput: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let kind: AudioRoutePortKind

    public init(id: String, name: String, kind: AudioRoutePortKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public init(output: AudioRoutePort) {
        self.init(id: output.id, name: output.name, kind: output.kind)
    }
}

public enum AudioRouteSafetyFailure: Equatable, Sendable {
    case outputUnavailable
    case mixedOrMultipleOutputs
    case nonPrivateOutput
    case hfpForbidden
    case inputPolicyViolation
}

public enum AudioRouteSafetyEvaluation: Equatable, Sendable {
    case safe(output: AudioRoutePort)
    case trustRequired(output: AudioRoutePort)
    case unsafe(reason: AudioRouteSafetyFailure)
}

public enum AudioSessionProfile: Equatable, Sendable {
    case builtInMicrophoneWithPrivateOutput
    case privateAccessoryDuplex

    public var voiceProcessingPolicy: AudioVoiceProcessingPolicy {
        switch self {
        case .builtInMicrophoneWithPrivateOutput:
            .disabled
        case .privateAccessoryDuplex:
            .enabledForPrivateAccessoryDuplex
        }
    }
}

public enum AudioVoiceProcessingPolicy: Equatable, Sendable {
    case disabled
    case enabledForPrivateAccessoryDuplex
}

public enum AudioSessionProfilePolicy {
    public static func activationOrder(
        for inputPolicy: AudioInputPolicy
    ) -> [AudioSessionProfile] {
        switch inputPolicy {
        case .builtInMicrophoneRequired:
            [.builtInMicrophoneWithPrivateOutput]
        case .preferBuiltInAllowPrivateAccessoryDuplex:
            [
                .builtInMicrophoneWithPrivateOutput,
                .privateAccessoryDuplex,
            ]
        }
    }
}

public enum AudioRouteSafetyPolicy {
    public static func evaluate(
        _ route: AudioRouteSnapshot,
        inputPolicy: AudioInputPolicy,
        outputPolicy: DeviceOutputPolicy,
        trustedOutputs: Set<AudioTrustedOutput>
    ) -> AudioRouteSafetyEvaluation {
        guard !route.outputs.isEmpty else {
            return .unsafe(reason: .outputUnavailable)
        }
        guard route.outputs.count == 1, let output = route.outputs.first else {
            return .unsafe(reason: .mixedOrMultipleOutputs)
        }
        if output.kind == .bluetoothHFP,
           inputPolicy == .builtInMicrophoneRequired
        {
            return .unsafe(reason: .hfpForbidden)
        }
        guard inputSatisfiesPolicy(route.inputs, policy: inputPolicy) else {
            return .unsafe(reason: .inputPolicyViolation)
        }
        guard outputSatisfiesPolicy(output, policy: outputPolicy) else {
            return .unsafe(reason: .nonPrivateOutput)
        }
        if output.kind == .wiredHeadphones {
            return .safe(output: output)
        }
        if trustedOutputs.contains(AudioTrustedOutput(output: output)) {
            return .safe(output: output)
        }
        return .trustRequired(output: output)
    }

    private static func outputSatisfiesPolicy(
        _ output: AudioRoutePort,
        policy: DeviceOutputPolicy
    ) -> Bool {
        switch policy {
        case .privateOutputRequired:
            output.kind.isPotentialPrivateOutput
        }
    }

    private static func inputSatisfiesPolicy(
        _ inputs: [AudioRoutePort],
        policy: AudioInputPolicy
    ) -> Bool {
        guard inputs.count == 1, let input = inputs.first else { return false }

        switch policy {
        case .builtInMicrophoneRequired:
            return input.kind == .builtInMicrophone
        case .preferBuiltInAllowPrivateAccessoryDuplex:
            return input.kind == .builtInMicrophone
                || input.kind.isPrivateInputCandidate
        }
    }
}
