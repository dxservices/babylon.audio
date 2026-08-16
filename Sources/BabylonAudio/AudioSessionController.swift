#if os(iOS)
import AVFAudio

@available(iOS 18, *)
@MainActor
public final class AudioSessionController {
    public static let shared = AudioSessionController()

    public private(set) var activeProfile: AudioSessionProfile?

    public var routeSnapshot: AudioRouteSnapshot {
        AudioRouteSnapshot(
            inputs: audioSession.currentRoute.inputs.map(Self.snapshot),
            outputs: audioSession.currentRoute.outputs.map(Self.snapshot),
            availableInputs: (audioSession.availableInputs ?? []).map(Self.snapshot)
        )
    }

    private let audioSession: AVAudioSession

    private init(audioSession: AVAudioSession = .sharedInstance()) {
        self.audioSession = audioSession
    }

    public func activate(_ profile: AudioSessionProfile) throws {
        try audioSession.setCategory(
            .playAndRecord,
            mode: profile.mode,
            options: profile.categoryOptions
        )
        try audioSession.setActive(true)
        activeProfile = profile
    }

    public func deactivate() throws {
        try audioSession.setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        activeProfile = nil
    }

    /// Selects an already-discovered private accessory input by opaque port ID.
    /// A successful preference call does not prove that the current route changed.
    @discardableResult
    public func selectPrivateAccessoryInput(id: String) throws -> Bool {
        guard let input = audioSession.availableInputs?.first(where: {
            $0.uid == id && AudioRoutePortKind(portType: $0.portType)
                .isPrivateInputCandidate
        }) else {
            return false
        }
        try audioSession.setPreferredInput(input)
        return true
    }

    private nonisolated static func snapshot(
        _ port: AVAudioSessionPortDescription
    ) -> AudioRoutePort {
        AudioRoutePort(
            id: port.uid,
            name: port.portName,
            kind: AudioRoutePortKind(portType: port.portType)
        )
    }
}

@available(iOS 18, *)
private extension AudioSessionProfile {
    var mode: AVAudioSession.Mode {
        switch self {
        case .builtInMicrophoneWithPrivateOutput:
            .default
        case .privateAccessoryDuplex:
            .voiceChat
        }
    }

    var categoryOptions: AVAudioSession.CategoryOptions {
        switch self {
        case .builtInMicrophoneWithPrivateOutput:
            [.allowBluetoothA2DP]
        case .privateAccessoryDuplex:
            if #available(iOS 26.0, *) {
                [.allowBluetoothHFP, .bluetoothHighQualityRecording]
            } else {
                [.allowBluetoothHFP]
            }
        }
    }
}

@available(iOS 18, *)
private extension AudioRoutePortKind {
    init(portType: AVAudioSession.Port) {
        switch portType {
        case .headphones:
            self = .wiredHeadphones
        case .headsetMic:
            self = .headsetMicrophone
        case .bluetoothA2DP:
            self = .bluetoothA2DP
        case .bluetoothHFP:
            self = .bluetoothHFP
        case .bluetoothLE:
            self = .bluetoothLE
        case .builtInMic:
            self = .builtInMicrophone
        case .builtInSpeaker:
            self = .builtInSpeaker
        case .builtInReceiver:
            self = .receiver
        case .airPlay:
            self = .airPlay
        case .carAudio:
            self = .carAudio
        case .HDMI:
            self = .hdmi
        default:
            self = .other
        }
    }
}
#endif
