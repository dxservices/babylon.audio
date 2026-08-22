@available(iOS 18, macOS 13, *)
public enum AudioRouteChangeReason: Equatable, Sendable {
    case unknown
    case newDeviceAvailable
    case oldDeviceUnavailable
    case categoryChange
    case override
    case wakeFromSleep
    case noSuitableRouteForCategory
    case routeConfigurationChange
}

public enum AudioSessionManagedRouteOperation: Equatable, Sendable {
    case activate
    case deactivate
    case selectPrivateAccessoryInput
}

@available(iOS 18, macOS 13, *)
public enum AudioRouteChangeOrigin: Equatable, Sendable {
    /// The change was caused by this process's own session or engine
    /// configuration. The operation is a best-effort diagnostic label; a
    /// window that mutated only engine state carries `nil`.
    case managedConfiguration(AudioSessionManagedRouteOperation?)
    case external
}

/// A content-free route observation. Port identifiers and names never cross
/// this boundary.
@available(iOS 18, macOS 13, *)
public struct AudioRouteChangeObservation: Equatable, Sendable {
    public let reason: AudioRouteChangeReason
    public let origin: AudioRouteChangeOrigin
    public let inputKinds: [AudioRoutePortKind]
    public let outputKinds: [AudioRoutePortKind]

    public init(
        reason: AudioRouteChangeReason,
        origin: AudioRouteChangeOrigin,
        inputKinds: [AudioRoutePortKind],
        outputKinds: [AudioRoutePortKind]
    ) {
        self.reason = reason
        self.origin = origin
        self.inputKinds = inputKinds
        self.outputKinds = outputKinds
    }
}

/// Attributes route-change notifications to this process's own configuration
/// work using time-boxed ownership instead of route-content matching.
///
/// While a managed window is open, every `categoryChange` /
/// `routeConfigurationChange` is owned by that window, including changes
/// produced by engine or voice-processing mutations that never touch the
/// session API. After the outermost window seals, only notifications that
/// arrive within a short grace interval AND still describe the sealed route
/// identity are treated as delayed echoes. Everything else is external:
/// ambiguity fails open toward safety delivery, never toward silence.
@available(iOS 18, macOS 13, *)
struct AudioSessionRouteAttribution {
    /// Echoes of our own mutations are posted on the main queue almost
    /// immediately; Bluetooth stacks can settle a managed activation up to
    /// roughly a second later. Past this bound a spurious external delivery
    /// costs one idempotent, converging safety rebuild — silent starvation
    /// from a swallowed real event is the failure mode this bound prevents.
    static let managedEchoGrace: Duration = .seconds(2)

    struct RouteIdentity: Equatable, Sendable {
        private struct Port: Equatable, Sendable {
            let id: String
            let kind: AudioRoutePortKind
        }

        private let inputs: [Port]
        private let outputs: [Port]

        init(_ route: AudioRouteSnapshot) {
            inputs = route.inputs.map { Port(id: $0.id, kind: $0.kind) }
            outputs = route.outputs.map { Port(id: $0.id, kind: $0.kind) }
        }
    }

    private struct Seal {
        let route: RouteIdentity
        let operation: AudioSessionManagedRouteOperation?
        let sealedAt: ContinuousClock.Instant
    }

    private let now: @Sendable () -> ContinuousClock.Instant
    private var windowDepth = 0
    private var windowOperation: AudioSessionManagedRouteOperation?
    private var seal: Seal?

    init(
        now: @escaping @Sendable () -> ContinuousClock.Instant = {
            ContinuousClock().now
        }
    ) {
        self.now = now
    }

    var isWindowOpen: Bool { windowDepth > 0 }

    /// Opens a managed window. A previous window's seal stays valid for its
    /// own grace interval so delayed echoes of the previous configuration
    /// are not orphaned into external deliveries by the next configuration.
    mutating func beginWindow() {
        if windowDepth == 0 {
            windowOperation = nil
        }
        windowDepth += 1
    }

    mutating func endWindow(settledRoute: @autoclosure () -> RouteIdentity) {
        guard windowDepth > 0 else { return }
        windowDepth -= 1
        guard windowDepth == 0 else { return }
        seal = Seal(
            route: settledRoute(),
            operation: windowOperation,
            sealedAt: now()
        )
        windowOperation = nil
    }

    mutating func noteMutation(_ operation: AudioSessionManagedRouteOperation) {
        windowOperation = operation
    }

    mutating func classify(
        reason: AudioRouteChangeReason,
        currentRoute: RouteIdentity
    ) -> AudioRouteChangeOrigin {
        guard reason == .categoryChange
                || reason == .routeConfigurationChange
        else {
            // Device arrivals, departures, and overrides are external
            // reality; they also invalidate any pending echo attribution.
            seal = nil
            return .external
        }
        if windowDepth > 0 {
            return .managedConfiguration(windowOperation)
        }
        if let seal,
           now() - seal.sealedAt <= Self.managedEchoGrace,
           seal.route == currentRoute
        {
            return .managedConfiguration(seal.operation)
        }
        seal = nil
        return .external
    }

    /// Interruptions and media-services resets replace any pending
    /// attribution: whatever follows them is a new external reality.
    mutating func reset() {
        seal = nil
        if windowDepth == 0 {
            windowOperation = nil
        }
    }
}

@available(iOS 18, macOS 13, *)
@MainActor
final class AudioSessionEventRouter {
    typealias EventHandler = @MainActor @Sendable (AudioDeviceEvent) async -> Void
    typealias ObservationHandler = @MainActor @Sendable
        (AudioRouteChangeObservation) -> Void

    private var eventHandler: EventHandler?
    private var observationHandler: ObservationHandler?

    init(
        eventHandler: EventHandler? = nil,
        observationHandler: ObservationHandler? = nil
    ) {
        self.eventHandler = eventHandler
        self.observationHandler = observationHandler
    }

    func setEventHandler(_ handler: EventHandler?) {
        eventHandler = handler
    }

    func setObservationHandler(_ handler: ObservationHandler?) {
        observationHandler = handler
    }

    /// Safety delivery precedes the diagnostic observation so an observer
    /// can never act on a route fact the safety authority has not seen.
    func deliverRouteChange(
        origin: AudioRouteChangeOrigin,
        reason: AudioRouteChangeReason,
        route: AudioRouteSnapshot
    ) async {
        if origin == .external {
            await eventHandler?(.routeChanged(route))
        }
        observationHandler?(AudioRouteChangeObservation(
            reason: reason,
            origin: origin,
            inputKinds: route.inputs.map(\.kind),
            outputKinds: route.outputs.map(\.kind)
        ))
    }

    func deliverInterruptionBegan() async {
        await eventHandler?(.interruptionBegan)
    }

    func deliverInterruptionEnded(shouldResume: Bool) async {
        await eventHandler?(.interruptionEnded(shouldResume: shouldResume))
    }

    func deliverMediaServicesReset() async {
        await eventHandler?(.mediaServicesReset)
    }
}
