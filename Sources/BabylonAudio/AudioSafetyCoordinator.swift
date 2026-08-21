@available(iOS 18, macOS 13, *)
public enum AudioDeviceEvent: Equatable, Sendable {
    case routeChanged(AudioRouteSnapshot)
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case mediaServicesReset
}

@available(iOS 18, macOS 13, *)
public struct AudioSafetyHandlingResult: Equatable, Sendable {
    public let engagedSafetyBoundary: Bool
    public let sessionDeactivated: Bool

    public init(
        engagedSafetyBoundary: Bool,
        sessionDeactivated: Bool
    ) {
        self.engagedSafetyBoundary = engagedSafetyBoundary
        self.sessionDeactivated = sessionDeactivated
    }
}

@available(iOS 18, macOS 13, *)
@MainActor
public protocol AudioHardwareSafetyControlling: AnyObject {
    /// Latches output closed before any other shutdown work begins.
    func muteOutput()
    func stopCapture()
    func stopPlayback()
    /// Replaces audio objects invalidated by a media-services reset.
    func rebuildAfterMediaServicesReset()
}

@available(iOS 18, macOS 13, *)
@MainActor
public protocol AudioPendingAudioDiscarding: AnyObject {
    /// Synchronously claims terminal ownership before hardware stop callbacks run.
    func latchSafetyBoundary()
    func discardPendingAudio() async
}

@available(iOS 18, macOS 13, *)
public extension AudioPendingAudioDiscarding {
    func latchSafetyBoundary() {}
}

@available(iOS 18, macOS 13, *)
public enum AudioSafetyCoordinatorError: Error, Equatable, Sendable {
    case recoveryClosed
    case invalidConfigurationPermit
    case configurationDuringPipelineEventDelivery
}

@available(iOS 18, macOS 13, *)
public enum AudioPipelineSafetyBufferControllerError:
    Error,
    Equatable,
    Sendable
{
    case replacementDuringSafetyBoundary
    case replacementDuringPipelineEventDelivery
    case supersededReplacement
}

@available(iOS 18, macOS 13, *)
@MainActor
public final class AudioSafetyConfigurationPermit {
    fileprivate weak var coordinator: AudioSafetyCoordinator?
    fileprivate let revision: UInt64
    fileprivate var isRevoked = false

    fileprivate init(
        coordinator: AudioSafetyCoordinator,
        revision: UInt64
    ) {
        self.coordinator = coordinator
        self.revision = revision
    }

    func validate() throws {
        guard let coordinator,
              coordinator.validateConfigurationPermit(self)
        else {
            throw AudioSafetyCoordinatorError.invalidConfigurationPermit
        }
    }

    fileprivate func revoke() {
        isRevoked = true
    }
}

@available(iOS 18, macOS 13, *)
@MainActor
public protocol AudioDeviceEventSink: AnyObject {
    func receive(_ event: AudioDeviceEvent) async
}

@available(iOS 18, macOS 13, *)
@MainActor
public final class AudioStreamingSafetyBufferController:
    AudioPendingAudioDiscarding
{
    private let uplink: BoundedUplinkQueue?
    private let downlink: BoundedDownlinkJitterBuffer?

    public init(
        uplink: BoundedUplinkQueue? = nil,
        downlink: BoundedDownlinkJitterBuffer? = nil
    ) {
        self.uplink = uplink
        self.downlink = downlink
    }

    public func discardPendingAudio() async {
        await uplink?.stop()
        await downlink?.stop()
    }
}

/// Adapts one pipeline session to the safety coordinator's pending-audio hook.
///
/// The coordinator calls the synchronous latch before stopping shared hardware.
/// Async discard then owns queue cleanup, processor reset, and terminal event
/// completion before session deactivation and device-event delivery continue.
@available(iOS 18, macOS 13, *)
@MainActor
public final class AudioPipelineSafetyBufferController:
    AudioPendingAudioDiscarding
{
    private struct SafetyClaim {
        let session: AudioPipelineSession
        let revision: UInt64
    }

    private var session: AudioPipelineSession
    private var sessionRevision: UInt64 = 0
    private var boundaryClaimRevision: UInt64 = 0
    private var activeDiscardCount = 0
    private var latchedClaims: [SafetyClaim] = []

    public init(session: AudioPipelineSession) {
        self.session = session
    }

    /// Rebinds one retained coordinator to a replacement pipeline session.
    ///
    /// Replacement first awaits the old session's complete stop barrier. A
    /// safety claim arriving while that barrier is suspended wins and causes
    /// replacement to fail closed. Its later cleanup remains paired with the
    /// exact old session and cannot stop or complete a newer session.
    public func replaceSession(
        _ replacement: AudioPipelineSession
    ) async throws {
        guard !AudioPipelineEventDeliveryContext.isDirectDelivery else {
            throw AudioPipelineSafetyBufferControllerError
                .replacementDuringPipelineEventDelivery
        }
        try Task.checkCancellation()
        guard replacement !== session else { return }
        guard activeDiscardCount == 0, latchedClaims.isEmpty else {
            throw AudioPipelineSafetyBufferControllerError
                .replacementDuringSafetyBoundary
        }
        let expectedSessionRevision = sessionRevision
        let expectedBoundaryRevision = boundaryClaimRevision
        let oldSession = session
        await oldSession.stop()
        try Task.checkCancellation()
        guard activeDiscardCount == 0,
              latchedClaims.isEmpty,
              boundaryClaimRevision == expectedBoundaryRevision
        else {
            throw AudioPipelineSafetyBufferControllerError
                .replacementDuringSafetyBoundary
        }
        guard sessionRevision == expectedSessionRevision,
              session === oldSession
        else {
            throw AudioPipelineSafetyBufferControllerError
                .supersededReplacement
        }
        session = replacement
        precondition(sessionRevision < UInt64.max)
        sessionRevision += 1
    }

    public func latchSafetyBoundary() {
        precondition(boundaryClaimRevision < UInt64.max)
        boundaryClaimRevision += 1
        latchedClaims.append(SafetyClaim(
            session: session,
            revision: session.latchSafetyBoundary()
        ))
    }

    public func discardPendingAudio() async {
        if latchedClaims.isEmpty {
            latchSafetyBoundary()
        }
        let claim = latchedClaims.removeFirst()
        activeDiscardCount += 1
        defer { activeDiscardCount -= 1 }
        await claim.session.stopForSafetyBoundary()
        claim.session.completeSafetyBoundary(revision: claim.revision)
    }
}

@available(iOS 18, macOS 13, *)
@MainActor
public final class AudioSafetyCoordinator {
    private let hardware: any AudioHardwareSafetyControlling
    private let buffers: any AudioPendingAudioDiscarding
    private let session: any AudioSessionControlling
    private let eventSink: any AudioDeviceEventSink
    private let eventGate = AudioSerialGate()
    private let transitionGate = AudioSerialGate()
    private var boundaryRevision: UInt64 = 0
    private var isRecoveryOpen = true
    private var activeConfigurationPermit: AudioSafetyConfigurationPermit?

    init(
        hardware: any AudioHardwareSafetyControlling,
        buffers: any AudioPendingAudioDiscarding,
        session: any AudioSessionControlling,
        eventSink: any AudioDeviceEventSink
    ) {
        self.hardware = hardware
        self.buffers = buffers
        self.session = session
        self.eventSink = eventSink
    }

    @discardableResult
    public func handle(
        _ event: AudioDeviceEvent
    ) async -> AudioSafetyHandlingResult {
        let eventBoundaryRevision: UInt64?
        switch event {
        case .routeChanged, .interruptionBegan, .mediaServicesReset:
            // This idempotent latch must not wait behind serialized work.
            hardware.muteOutput()
            eventBoundaryRevision = beginSafetyBoundary()
        case .interruptionEnded:
            eventBoundaryRevision = nil
        }

        await eventGate.acquire()
        defer { eventGate.release() }

        switch event {
        case .interruptionEnded:
            await eventSink.receive(event)
            return AudioSafetyHandlingResult(
                engagedSafetyBoundary: false,
                sessionDeactivated: false
            )

        case .routeChanged, .interruptionBegan, .mediaServicesReset:
            guard let eventBoundaryRevision else {
                preconditionFailure("Safety event is missing its boundary revision")
            }
            let sessionDeactivated = await engageSafetyBoundary(
                for: event,
                revision: eventBoundaryRevision
            )
            await eventSink.receive(event)
            return AudioSafetyHandlingResult(
                engagedSafetyBoundary: true,
                sessionDeactivated: sessionDeactivated
            )
        }
    }

    /// Serializes caller configuration against fail-closed hardware/session work.
    ///
    /// Device-event delivery does not hold this gate, so an event sink may call
    /// this method directly. Pipeline-event delivery is rejected before gate
    /// acquisition; hand recovery to a task that first waits for the pipeline's
    /// terminal barrier. Do not nest `performConfiguration` calls, call it from
    /// `discardPendingAudio`, or await `handle` from an event sink.
    public func performConfiguration<T>(
        _ operation: @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        guard !AudioPipelineEventDeliveryContext.isDirectDelivery else {
            throw AudioSafetyCoordinatorError
                .configurationDuringPipelineEventDelivery
        }
        await transitionGate.acquire()
        defer { transitionGate.release() }
        try Task.checkCancellation()
        guard isRecoveryOpen else {
            throw AudioSafetyCoordinatorError.recoveryClosed
        }
        return try await operation()
    }

    /// Runs configuration with a permit required for public output unmute.
    ///
    /// The permit is scoped to `operation` and is revoked before this method
    /// returns or throws; callers cannot retain it for later output unmute.
    /// The permit becomes invalid synchronously when any newer safety boundary
    /// arrives, including while `operation` is suspended.
    public func performConfiguration<T>(
        _ operation: @MainActor @Sendable (
            AudioSafetyConfigurationPermit
        ) async throws -> T
    ) async throws -> T {
        guard !AudioPipelineEventDeliveryContext.isDirectDelivery else {
            throw AudioSafetyCoordinatorError
                .configurationDuringPipelineEventDelivery
        }
        await transitionGate.acquire()
        defer { transitionGate.release() }
        try Task.checkCancellation()
        guard isRecoveryOpen else {
            throw AudioSafetyCoordinatorError.recoveryClosed
        }
        let permit = AudioSafetyConfigurationPermit(
            coordinator: self,
            revision: boundaryRevision
        )
        precondition(activeConfigurationPermit == nil)
        activeConfigurationPermit = permit
        defer {
            permit.revoke()
            if activeConfigurationPermit === permit {
                activeConfigurationPermit = nil
            }
        }
        return try await operation(permit)
    }

    private func beginSafetyBoundary() -> UInt64 {
        precondition(boundaryRevision < UInt64.max)
        boundaryRevision += 1
        isRecoveryOpen = false
        activeConfigurationPermit?.revoke()
        buffers.latchSafetyBoundary()
        return boundaryRevision
    }

    fileprivate func validateConfigurationPermit(
        _ permit: AudioSafetyConfigurationPermit
    ) -> Bool {
        permit.coordinator === self
            && permit.revision == boundaryRevision
            && isRecoveryOpen
            && !permit.isRevoked
            && activeConfigurationPermit === permit
    }

    private func engageSafetyBoundary(
        for event: AudioDeviceEvent,
        revision: UInt64
    ) async -> Bool {
        await transitionGate.acquire()
        defer { transitionGate.release() }

        hardware.muteOutput()
        hardware.stopCapture()
        hardware.stopPlayback()
        await buffers.discardPendingAudio()

        let sessionDeactivated: Bool
        do {
            try session.deactivate()
            sessionDeactivated = true
        } catch {
            sessionDeactivated = false
        }

        if case .mediaServicesReset = event {
            hardware.rebuildAfterMediaServicesReset()
        }
        if boundaryRevision == revision {
            isRecoveryOpen = true
        }
        return sessionDeactivated
    }
}

@available(iOS 18, macOS 13, *)
@MainActor
private final class AudioSerialGate {
    private var isAcquired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isAcquired else {
            isAcquired = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isAcquired = false
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }
}

#if os(iOS)
@available(iOS 18, *)
public extension AudioSafetyCoordinator {
    convenience init(
        hardware: any AudioHardwareSafetyControlling,
        buffers: any AudioPendingAudioDiscarding,
        eventSink: any AudioDeviceEventSink,
        session: AudioSessionController = .shared
    ) {
        self.init(
            hardware: hardware,
            buffers: buffers,
            session: session,
            eventSink: eventSink
        )
        session.setEventHandler { [weak self] event in
            guard let self else { return }
            await self.handle(event)
        }
    }
}
#endif
