#if os(iOS)
import AVFAudio
import Foundation

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
    private let eventRouter = AudioSessionEventRouter()
    private var routeAttribution = AudioSessionRouteAttribution()
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    private init(audioSession: AVAudioSession = .sharedInstance()) {
        self.audioSession = audioSession
        observeRouteChanges()
        observeInterruptions()
        observeMediaServicesReset()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Installs the sole device-event handler for the process audio authority.
    /// Use `AudioSafetyCoordinator.handle` so safety shutdown precedes delivery.
    public func setEventHandler(
        _ handler: (@MainActor @Sendable (AudioDeviceEvent) async -> Void)?
    ) {
        eventRouter.setEventHandler(handler)
    }

    /// Installs an optional content-free route observer. Observations contain
    /// only route reasons, ownership classification, and port kinds.
    public func setRouteObservationHandler(
        _ handler: (@MainActor @Sendable (AudioRouteChangeObservation) -> Void)?
    ) {
        eventRouter.setObservationHandler(handler)
    }

    func beginManagedRouteConfiguration() {
        routeAttribution.beginWindow()
    }

    func endManagedRouteConfiguration() {
        routeAttribution.endWindow(
            settledRoute: AudioSessionRouteAttribution.RouteIdentity(
                currentRouteOnly
            )
        )
    }

    public func activate(_ profile: AudioSessionProfile) throws {
        beginManagedRouteConfiguration()
        defer { endManagedRouteConfiguration() }
        routeAttribution.noteMutation(.activate)
        try audioSession.setCategory(
            .playAndRecord,
            mode: profile.mode,
            options: profile.categoryOptions
        )
        try audioSession.setActive(true)
        activeProfile = profile
    }

    public func deactivate() throws {
        beginManagedRouteConfiguration()
        defer { endManagedRouteConfiguration() }
        routeAttribution.noteMutation(.deactivate)
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
        beginManagedRouteConfiguration()
        defer { endManagedRouteConfiguration() }
        routeAttribution.noteMutation(.selectPrivateAccessoryInput)
        try audioSession.setPreferredInput(input)
        return true
    }

    private func observeRouteChanges() {
        let observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            // No session IPC in the notification callback: classification and
            // route reads run later on the MainActor so a notification burst
            // during Bluetooth renegotiation cannot stall the main thread.
            let reasonValue = notification.userInfo?[
                AVAudioSessionRouteChangeReasonKey
            ] as? UInt
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.handleRouteChange(
                    reason: AudioRouteChangeReason(avReasonValue: reasonValue)
                )
            }
        }
        observers.append(observer)
    }

    private func handleRouteChange(reason: AudioRouteChangeReason) async {
        let currentRoute = currentRouteOnly
        let origin = routeAttribution.classify(
            reason: reason,
            currentRoute: AudioSessionRouteAttribution.RouteIdentity(
                currentRoute
            )
        )
        // The delivered snapshot includes available inputs; that extra read
        // happens only for external deliveries, off the suppression path.
        let route = origin == .external ? routeSnapshot : currentRoute
        await eventRouter.deliverRouteChange(
            origin: origin,
            reason: reason,
            route: route
        )
    }

    private var currentRouteOnly: AudioRouteSnapshot {
        AudioRouteSnapshot(
            inputs: audioSession.currentRoute.inputs.map(Self.snapshot),
            outputs: audioSession.currentRoute.outputs.map(Self.snapshot),
            availableInputs: []
        )
    }

    private func observeInterruptions() {
        let observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            let typeValue = notification.userInfo?[
                AVAudioSessionInterruptionTypeKey
            ] as? UInt
            let optionsValue = notification.userInfo?[
                AVAudioSessionInterruptionOptionKey
            ] as? UInt ?? 0

            Task { @MainActor [weak self] in
                guard let self,
                      let typeValue,
                      let type = AVAudioSession.InterruptionType(
                        rawValue: typeValue
                      )
                else {
                    return
                }

                switch type {
                case .began:
                    self.routeAttribution.reset()
                    await self.eventRouter.deliverInterruptionBegan()
                case .ended:
                    let options = AVAudioSession.InterruptionOptions(
                        rawValue: optionsValue
                    )
                    await self.eventRouter.deliverInterruptionEnded(
                        shouldResume: options.contains(.shouldResume)
                    )
                @unknown default:
                    self.routeAttribution.reset()
                    await self.eventRouter.deliverInterruptionBegan()
                }
            }
        }
        observers.append(observer)
    }

    private func observeMediaServicesReset() {
        let observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activeProfile = nil
                self.routeAttribution.reset()
                await self.eventRouter.deliverMediaServicesReset()
            }
        }
        observers.append(observer)
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
        switch voiceProcessingPolicy {
        case .disabled:
            .default
        case .enabledForPrivateAccessoryDuplex:
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
private extension AudioRouteChangeReason {
    init(avReasonValue: UInt?) {
        guard let avReasonValue,
              let reason = AVAudioSession.RouteChangeReason(
                rawValue: avReasonValue
              )
        else {
            self = .unknown
            return
        }
        switch reason {
        case .unknown: self = .unknown
        case .newDeviceAvailable: self = .newDeviceAvailable
        case .oldDeviceUnavailable: self = .oldDeviceUnavailable
        case .categoryChange: self = .categoryChange
        case .override: self = .override
        case .wakeFromSleep: self = .wakeFromSleep
        case .noSuitableRouteForCategory:
            self = .noSuitableRouteForCategory
        case .routeConfigurationChange:
            self = .routeConfigurationChange
        @unknown default: self = .unknown
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
