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
    func discardPendingAudio() async
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

@available(iOS 18, macOS 13, *)
@MainActor
public final class AudioSafetyCoordinator {
    private let hardware: any AudioHardwareSafetyControlling
    private let buffers: any AudioPendingAudioDiscarding
    private let session: any AudioSessionControlling
    private let eventSink: any AudioDeviceEventSink
    private let eventGate = AudioSerialGate()
    private let transitionGate = AudioSerialGate()

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
        switch event {
        case .routeChanged, .interruptionBegan, .mediaServicesReset:
            // This idempotent latch must not wait behind serialized work.
            hardware.muteOutput()
        case .interruptionEnded:
            break
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
            let sessionDeactivated = await engageSafetyBoundary(for: event)
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
    /// this method directly. Do not nest `performConfiguration` calls, call it
    /// from `discardPendingAudio`, or await `handle` from an event sink.
    public func performConfiguration<T>(
        _ operation: @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        await transitionGate.acquire()
        defer { transitionGate.release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func engageSafetyBoundary(
        for event: AudioDeviceEvent
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
