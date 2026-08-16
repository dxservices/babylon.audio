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
        case .interruptionEnded:
            await eventSink.receive(event)
            return AudioSafetyHandlingResult(
                engagedSafetyBoundary: false,
                sessionDeactivated: false
            )

        case .routeChanged, .interruptionBegan, .mediaServicesReset:
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

            await eventSink.receive(event)
            return AudioSafetyHandlingResult(
                engagedSafetyBoundary: true,
                sessionDeactivated: sessionDeactivated
            )
        }
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
