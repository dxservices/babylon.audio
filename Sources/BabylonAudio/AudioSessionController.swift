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
    private let routeAttribution: AudioSessionRouteAttribution
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    private init(
        audioSession: AVAudioSession = .sharedInstance(),
        routeAttribution: AudioSessionRouteAttribution = .shared
    ) {
        self.audioSession = audioSession
        self.routeAttribution = routeAttribution
        routeAttribution.updateKnownRoute(
            AudioSessionRouteAttribution.RouteIdentity(currentRouteOnly)
        )
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
        routeAttribution.beginWindow(
            initialRoute: AudioSessionRouteAttribution.RouteIdentity(
                currentRouteOnly
            )
        )
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
        try performManagedRouteMutation(.activate) {
            try audioSession.setCategory(
                .playAndRecord,
                mode: profile.mode,
                options: profile.categoryOptions
            )
            try audioSession.setActive(true)
        }
        activeProfile = profile
    }

    public func deactivate() throws {
        beginManagedRouteConfiguration()
        defer { endManagedRouteConfiguration() }
        try performManagedRouteMutation(.deactivate) {
            try audioSession.setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
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
        try performManagedRouteMutation(.selectPrivateAccessoryInput) {
            try audioSession.setPreferredInput(input)
        }
        return true
    }

    private func observeRouteChanges() {
        let routeAttribution = routeAttribution
        let observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            let reasonValue = notification.userInfo?[
                AVAudioSessionRouteChangeReasonKey
            ] as? UInt
            let reason = AudioRouteChangeReason(avReasonValue: reasonValue)
            let previousRoute = (
                notification.userInfo?[
                    AVAudioSessionRouteChangePreviousRouteKey
                ] as? AVAudioSessionRouteDescription
            ).map {
                AudioSessionRouteAttribution.RouteIdentity(
                    Self.snapshot($0)
                )
            }
            // Callback-time work is content-free and reads no AVAudioSession
            // state. Freezing the revision here prevents a later async window
            // from adopting an external notification.
            let capture = routeAttribution.captureNotification(
                reason: reason,
                previousRoute: previousRoute
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.handleRouteChange(
                    reason: reason,
                    capture: capture
                )
            }
        }
        observers.append(observer)
    }

    private func handleRouteChange(
        reason: AudioRouteChangeReason,
        capture: AudioSessionRouteAttribution.NotificationCapture
    ) async {
        let currentRoute = currentRouteOnly
        let origin = routeAttribution.resolve(
            capture,
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
        let routeAttribution = routeAttribution
        let observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            // Invalidate captured managed revisions in callback order before
            // any later route notification can reuse them.
            routeAttribution.reset()
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
                    await self.eventRouter.deliverInterruptionBegan()
                case .ended:
                    let options = AVAudioSession.InterruptionOptions(
                        rawValue: optionsValue
                    )
                    await self.eventRouter.deliverInterruptionEnded(
                        shouldResume: options.contains(.shouldResume)
                    )
                @unknown default:
                    await self.eventRouter.deliverInterruptionBegan()
                }
            }
        }
        observers.append(observer)
    }

    private func observeMediaServicesReset() {
        let routeAttribution = routeAttribution
        let observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] _ in
            routeAttribution.reset()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activeProfile = nil
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

    private nonisolated static func snapshot(
        _ route: AVAudioSessionRouteDescription
    ) -> AudioRouteSnapshot {
        AudioRouteSnapshot(
            inputs: route.inputs.map(Self.snapshot),
            outputs: route.outputs.map(Self.snapshot),
            availableInputs: []
        )
    }

    private func performManagedRouteMutation<T>(
        _ operation: AudioSessionManagedRouteOperation,
        _ body: () throws -> T
    ) rethrows -> T {
        let token = routeAttribution.beginMutation(
            operation,
            initialRoute: AudioSessionRouteAttribution.RouteIdentity(
                currentRouteOnly
            )
        )
        defer {
            routeAttribution.endMutation(
                token,
                settledRoute: AudioSessionRouteAttribution.RouteIdentity(
                    currentRouteOnly
                )
            )
        }
        return try body()
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
