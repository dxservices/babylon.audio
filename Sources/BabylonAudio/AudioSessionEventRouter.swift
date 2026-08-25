import Foundation

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

/// Correlates route notifications with exact, synchronous audio mutations.
///
/// A broad async configuration window is only a transaction boundary. It is
/// never proof that a notification is ours. Each session or engine mutation
/// records a bounded active revision and exact before/settled route identities.
/// The notification callback claims a revision either while the synchronous
/// mutation is still active, or — because AVFoundation delivers route
/// notifications asynchronously on the main queue, always after the mutation
/// returned — within a bounded delayed-echo grace after mutation end, and
/// then only when the notification's own previous-route payload matches that
/// mutation's exact before/settled identity chain. Delivery later verifies
/// the exact settled identity. Missing, stale, expired, ambiguous, or
/// overflowed evidence delivers as an external event: ambiguity costs one
/// idempotent safety rebuild, never a silently swallowed external fact.
@available(iOS 18, macOS 13, *)
final class AudioSessionRouteAttribution: @unchecked Sendable {
    static let maximumExpectations = 16
    static let maximumCapturesPerExpectation = 16
    /// Echoes of our own mutations reach the main queue almost immediately;
    /// Bluetooth stacks can settle a managed activation up to roughly a
    /// second later. Past this bound an expectation loses its credential and
    /// matching notifications deliver as external.
    static let delayedEchoGrace: Duration = .seconds(2)
    static let shared = AudioSessionRouteAttribution()

    struct RouteIdentity: Equatable, Sendable {
        private struct Port: Equatable, Sendable {
            let id: String
            let name: String
            let kind: AudioRoutePortKind
        }

        private let inputs: [Port]
        private let outputs: [Port]

        init(_ route: AudioRouteSnapshot) {
            inputs = route.inputs.map {
                Port(id: $0.id, name: $0.name, kind: $0.kind)
            }
            outputs = route.outputs.map {
                Port(id: $0.id, name: $0.name, kind: $0.kind)
            }
        }
    }

    struct MutationToken: Equatable, Sendable {
        fileprivate let generation: UInt64
        fileprivate let revision: UInt64?
    }

    struct NotificationCapture: Equatable, Sendable {
        fileprivate let generation: UInt64
        fileprivate let revision: UInt64?
        fileprivate let reason: AudioRouteChangeReason
        fileprivate let operation: AudioSessionManagedRouteOperation?
        fileprivate var claimedDelayed = false
    }

    private struct Expectation {
        let generation: UInt64
        let revision: UInt64
        let initialRoute: RouteIdentity
        var settledRoute: RouteIdentity
        let operation: AudioSessionManagedRouteOperation?
        var capturedReasons: [AudioRouteChangeReason] = []
        var retiredAt: ContinuousClock.Instant?
    }

    private let lock = NSLock()
    private let now: @Sendable () -> ContinuousClock.Instant
    private var generation: UInt64 = 0
    private var nextRevision: UInt64 = 0
    private var nextTransaction: UInt64 = 0
    private var windowDepth = 0
    private var activeTransaction: UInt64?
    private var failClosedTransaction: UInt64?
    private var knownRoute: RouteIdentity?
    private var expectations: [Expectation] = []
    private var activeMutationRevisions: [UInt64] = []

    init(
        now: @escaping @Sendable () -> ContinuousClock.Instant = {
            ContinuousClock().now
        }
    ) {
        self.now = now
    }

    var isWindowOpen: Bool {
        withLock { windowDepth > 0 }
    }

    func updateKnownRoute(_ route: RouteIdentity) {
        withLock {
            knownRoute = route
        }
    }

    func beginWindow(initialRoute: RouteIdentity? = nil) {
        withLock {
            if let initialRoute {
                knownRoute = initialRoute
            }
            if windowDepth == 0 {
                precondition(nextTransaction < UInt64.max)
                nextTransaction += 1
                activeTransaction = nextTransaction
                failClosedTransaction = nil
            }
            windowDepth += 1
        }
    }

    func endWindow(settledRoute: @autoclosure () -> RouteIdentity) {
        let route = settledRoute()
        withLock {
            guard windowDepth > 0 else { return }
            knownRoute = route
            windowDepth -= 1
            guard windowDepth == 0 else { return }
            activeTransaction = nil
            failClosedTransaction = nil
        }
    }

    func beginMutation(
        _ operation: AudioSessionManagedRouteOperation?,
        initialRoute: RouteIdentity? = nil
    ) -> MutationToken {
        withLock {
            if let initialRoute {
                knownRoute = initialRoute
            }
            guard let route = knownRoute else {
                return MutationToken(generation: generation, revision: nil)
            }
            let transaction: UInt64
            if let activeTransaction {
                transaction = activeTransaction
            } else {
                precondition(nextTransaction < UInt64.max)
                nextTransaction += 1
                transaction = nextTransaction
            }
            guard failClosedTransaction != transaction else {
                return MutationToken(generation: generation, revision: nil)
            }
            pruneExpiredLocked()
            guard expectations.count < Self.maximumExpectations else {
                invalidateLocked(failClosedTransaction: transaction)
                return MutationToken(generation: generation, revision: nil)
            }
            precondition(nextRevision < UInt64.max)
            nextRevision += 1
            let revision = nextRevision
            expectations.append(Expectation(
                generation: generation,
                revision: revision,
                initialRoute: route,
                settledRoute: route,
                operation: operation
            ))
            activeMutationRevisions.append(revision)
            return MutationToken(generation: generation, revision: revision)
        }
    }

    func endMutation(
        _ token: MutationToken,
        settledRoute: RouteIdentity? = nil
    ) {
        withLock {
            if let revision = token.revision {
                activeMutationRevisions.removeAll { $0 == revision }
            }
            if let settledRoute {
                knownRoute = settledRoute
            }
            guard token.generation == generation,
                  let revision = token.revision,
                  let index = expectations.firstIndex(where: {
                      $0.generation == token.generation
                          && $0.revision == revision
                  })
            else { return }
            let route = settledRoute ?? knownRoute
            guard let route else { return }
            expectations[index].settledRoute = route
            // The expectation retires instead of vanishing: AVFoundation
            // delivers this mutation's echoes on the main queue after the
            // mutation has already returned, so the credential must survive
            // for the bounded delayed-echo grace.
            expectations[index].retiredAt = now()
        }
    }

    /// Called synchronously by the notification observer. This method only
    /// examines already-cached tracker state and the notification payload.
    func captureNotification(
        reason: AudioRouteChangeReason,
        previousRoute: RouteIdentity?
    ) -> NotificationCapture {
        withLock {
            guard reason == .categoryChange
                    || reason == .routeConfigurationChange
            else {
                // Device arrivals, departures, and overrides are external
                // reality; they invalidate every pending echo credential.
                invalidateLocked(failClosedTransaction: activeTransaction)
                return NotificationCapture(
                    generation: generation,
                    revision: nil,
                    reason: reason,
                    operation: nil
                )
            }
            pruneExpiredLocked()
            let activeRevision = activeMutationRevisions.last
            let activeIndex = activeRevision.flatMap { revision in
                expectations.indices.reversed().first(where: {
                    expectations[$0].generation == generation
                        && expectations[$0].revision == revision
                        && expectations[$0].capturedReasons.count
                            < Self.maximumCapturesPerExpectation
                        && (previousRoute == nil
                            || expectations[$0].initialRoute == previousRoute)
                })
            }
            // A retired expectation keeps its credential for the delayed-echo
            // grace, and only for notifications whose own previous-route
            // payload matches that mutation's exact identity chain. A delayed
            // notification with no payload has no credential.
            let delayedIndex = activeIndex ?? previousRoute.flatMap { chain in
                expectations.indices.reversed().first(where: {
                    expectations[$0].generation == generation
                        && expectations[$0].retiredAt != nil
                        && expectations[$0].capturedReasons.count
                            < Self.maximumCapturesPerExpectation
                        && (expectations[$0].initialRoute == chain
                            || expectations[$0].settledRoute == chain)
                })
            }
            guard let index = delayedIndex else {
                // An unmatched configuration-reason notification delivers as
                // external on its own; wiping the remaining credentials here
                // would turn every later echo external and cascade rebuilds.
                return NotificationCapture(
                    generation: generation,
                    revision: nil,
                    reason: reason,
                    operation: nil
                )
            }
            expectations[index].capturedReasons.append(reason)
            return NotificationCapture(
                generation: generation,
                revision: expectations[index].revision,
                reason: reason,
                operation: expectations[index].operation,
                claimedDelayed: activeIndex == nil
            )
        }
    }

    func resolve(
        _ capture: NotificationCapture,
        currentRoute: RouteIdentity
    ) -> AudioRouteChangeOrigin {
        withLock {
            knownRoute = currentRoute
            guard capture.generation == generation,
                  let revision = capture.revision,
                  let index = expectations.firstIndex(where: {
                      $0.generation == capture.generation
                          && $0.revision == revision
                  })
            else {
                return .external
            }
            guard let reasonIndex = expectations[index]
                .capturedReasons.firstIndex(of: capture.reason)
            else {
                return .external
            }
            expectations[index].capturedReasons.remove(at: reasonIndex)
            if expectations[index].settledRoute == currentRoute {
                return .managedConfiguration(capture.operation)
            }
            // A delayed echo frequently IS the late Bluetooth settle of its
            // own mutation: the recorded settled identity was read
            // synchronously before the OS finished moving the route. The
            // claim already verified the notification's payload chain, so
            // adopt the delivered route as this mutation's settled identity.
            guard capture.claimedDelayed else {
                // The world moved between an in-mutation capture and its
                // delivery: this event delivers as external, but the other
                // expectations keep their credentials for their own echoes.
                return .external
            }
            expectations[index].settledRoute = currentRoute
            return .managedConfiguration(capture.operation)
        }
    }

    /// Interruptions and media-services resets replace any pending
    /// attribution: whatever follows them is a new external reality.
    func reset(currentRoute: RouteIdentity? = nil) {
        withLock {
            if let currentRoute {
                knownRoute = currentRoute
            }
            invalidateLocked(failClosedTransaction: activeTransaction)
        }
    }

    private func pruneExpiredLocked() {
        let currentInstant = now()
        expectations.removeAll { expectation in
            guard let retiredAt = expectation.retiredAt else { return false }
            return currentInstant - retiredAt > Self.delayedEchoGrace
        }
    }

    private func invalidateLocked(failClosedTransaction transaction: UInt64?) {
        precondition(generation < UInt64.max)
        generation += 1
        expectations.removeAll(keepingCapacity: true)
        activeMutationRevisions.removeAll(keepingCapacity: true)
        if let transaction {
            failClosedTransaction = transaction
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
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
