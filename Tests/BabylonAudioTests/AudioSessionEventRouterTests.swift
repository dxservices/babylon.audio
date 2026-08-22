import Foundation
import Testing
@testable import BabylonAudio

@Suite("Audio session route attribution")
struct AudioSessionRouteAttributionTests {
    @Test("Category and configuration changes are managed inside a window")
    func windowOwnsConfigurationReasons() {
        var attribution = makeAttribution(now: { ContinuousClock().now })
        let route = identity(id: "a2dp", output: .bluetoothA2DP)

        attribution.beginWindow()
        attribution.noteMutation(.activate)

        #expect(attribution.classify(
            reason: .categoryChange,
            currentRoute: route
        ) == .managedConfiguration(.activate))
        #expect(attribution.classify(
            reason: .routeConfigurationChange,
            currentRoute: route
        ) == .managedConfiguration(.activate))
    }

    @Test("A window with no session mutation still owns configuration reasons")
    func zeroMutationWindowStillOwnsConfigurationReasons() {
        var attribution = makeAttribution(now: { ContinuousClock().now })
        let route = identity(id: "a2dp", output: .bluetoothA2DP)

        // Engine start / voice-processing configuration inside a managed
        // window posts routeConfigurationChange without any session call.
        attribution.beginWindow()

        #expect(attribution.classify(
            reason: .routeConfigurationChange,
            currentRoute: route
        ) == .managedConfiguration(nil))
    }

    @Test("Nested windows stay managed until the outermost window ends")
    func nestedWindowsCountDepth() {
        var attribution = makeAttribution(now: { ContinuousClock().now })
        let route = identity(id: "hfp", output: .bluetoothHFP)

        attribution.beginWindow()
        attribution.beginWindow()
        attribution.noteMutation(.deactivate)
        attribution.endWindow(settledRoute: route)

        #expect(attribution.classify(
            reason: .categoryChange,
            currentRoute: route
        ) == .managedConfiguration(.deactivate))
    }

    @Test("An identity-equal echo within the grace interval is managed")
    func sealedEchoWithinGraceIsManaged() {
        let clock = ManualAttributionClock()
        var attribution = makeAttribution(now: { clock.now })
        let route = identity(id: "a2dp", output: .bluetoothA2DP)

        attribution.beginWindow()
        attribution.noteMutation(.activate)
        attribution.endWindow(settledRoute: route)
        clock.advance(by: .seconds(1))

        #expect(attribution.classify(
            reason: .routeConfigurationChange,
            currentRoute: route
        ) == .managedConfiguration(.activate))
        // Multiple echoes within grace stay managed.
        #expect(attribution.classify(
            reason: .categoryChange,
            currentRoute: route
        ) == .managedConfiguration(.activate))
    }

    @Test("An identity-equal change after the grace interval is external")
    func sealedEchoAfterGraceIsExternal() {
        let clock = ManualAttributionClock()
        var attribution = makeAttribution(now: { clock.now })
        let route = identity(id: "a2dp", output: .bluetoothA2DP)

        attribution.beginWindow()
        attribution.endWindow(settledRoute: route)
        clock.advance(
            by: AudioSessionRouteAttribution.managedEchoGrace + .seconds(1)
        )

        #expect(attribution.classify(
            reason: .routeConfigurationChange,
            currentRoute: route
        ) == .external)
    }

    @Test("A different route identity during grace is external")
    func differentIdentityDuringGraceIsExternal() {
        var attribution = makeAttribution(now: { ContinuousClock().now })
        let sealed = identity(id: "a2dp", output: .bluetoothA2DP)
        let moved = identity(id: "speaker", output: .builtInSpeaker)

        attribution.beginWindow()
        attribution.endWindow(settledRoute: sealed)

        #expect(attribution.classify(
            reason: .routeConfigurationChange,
            currentRoute: moved
        ) == .external)
        // The external classification invalidates the seal: a later
        // identity-equal change is no longer treated as an echo.
        #expect(attribution.classify(
            reason: .routeConfigurationChange,
            currentRoute: sealed
        ) == .external)
    }

    @Test("Device arrivals and departures are always external")
    func deviceReasonsAreAlwaysExternal() {
        var attribution = makeAttribution(now: { ContinuousClock().now })
        let route = identity(id: "a2dp", output: .bluetoothA2DP)
        attribution.beginWindow()
        attribution.noteMutation(.activate)

        for reason in [AudioRouteChangeReason.newDeviceAvailable,
                       .oldDeviceUnavailable,
                       .override,
                       .wakeFromSleep,
                       .noSuitableRouteForCategory,
                       .unknown]
        {
            #expect(attribution.classify(
                reason: reason,
                currentRoute: route
            ) == .external)
        }
    }

    @Test("An external device fact invalidates a pending seal")
    func externalDeviceFactInvalidatesSeal() {
        var attribution = makeAttribution(now: { ContinuousClock().now })
        let route = identity(id: "a2dp", output: .bluetoothA2DP)

        attribution.beginWindow()
        attribution.endWindow(settledRoute: route)
        #expect(attribution.classify(
            reason: .oldDeviceUnavailable,
            currentRoute: route
        ) == .external)

        // The echo that follows real device removal must not be swallowed
        // by the stale seal even when the route identity matches again.
        #expect(attribution.classify(
            reason: .routeConfigurationChange,
            currentRoute: route
        ) == .external)
    }

    @Test("A new window keeps the previous seal for its own delayed echoes")
    func newWindowKeepsPreviousSeal() {
        let clock = ManualAttributionClock()
        var attribution = makeAttribution(now: { clock.now })
        let first = identity(id: "a2dp", output: .bluetoothA2DP)

        attribution.beginWindow()
        attribution.noteMutation(.activate)
        attribution.endWindow(settledRoute: first)
        clock.advance(by: .milliseconds(100))

        // The next configuration begins; a delayed echo of the first
        // configuration arrives while its window is open.
        attribution.beginWindow()
        #expect(attribution.classify(
            reason: .routeConfigurationChange,
            currentRoute: first
        ) == .managedConfiguration(nil))
        attribution.endWindow(settledRoute: first)

        // After the second window seals, first-window echoes still match by
        // identity through the second seal.
        #expect(attribution.classify(
            reason: .categoryChange,
            currentRoute: first
        ) == .managedConfiguration(nil))
    }

    @Test("Reset clears the seal so later echoes are external")
    func resetClearsSeal() {
        var attribution = makeAttribution(now: { ContinuousClock().now })
        let route = identity(id: "a2dp", output: .bluetoothA2DP)

        attribution.beginWindow()
        attribution.endWindow(settledRoute: route)
        attribution.reset()

        #expect(attribution.classify(
            reason: .routeConfigurationChange,
            currentRoute: route
        ) == .external)
    }

    @Test("Reset during an open window keeps the window's ownership")
    func resetKeepsOpenWindowDepth() {
        var attribution = makeAttribution(now: { ContinuousClock().now })
        let route = identity(id: "a2dp", output: .bluetoothA2DP)

        attribution.beginWindow()
        attribution.reset()

        #expect(attribution.isWindowOpen)
        #expect(attribution.classify(
            reason: .categoryChange,
            currentRoute: route
        ) == .managedConfiguration(nil))
    }

    private func makeAttribution(
        now: @escaping @Sendable () -> ContinuousClock.Instant
    ) -> AudioSessionRouteAttribution {
        AudioSessionRouteAttribution(now: now)
    }

    private func identity(
        id: String,
        output: AudioRoutePortKind
    ) -> AudioSessionRouteAttribution.RouteIdentity {
        AudioSessionRouteAttribution.RouteIdentity(AudioRouteSnapshot(
            inputs: [AudioRoutePort(
                id: "input-\(id)",
                name: "Input \(id)",
                kind: .builtInMicrophone
            )],
            outputs: [AudioRoutePort(
                id: "output-\(id)",
                name: "Output \(id)",
                kind: output
            )],
            availableInputs: []
        ))
    }
}

@Suite("Audio session event router")
@MainActor
struct AudioSessionEventRouterTests {
    @Test("Managed changes are observations, not safety deliveries")
    func managedChangeDoesNotReachSafetyHandler() async {
        let recorder = AudioSessionEventRouterRecorder()
        let router = AudioSessionEventRouter(
            eventHandler: { event in
                recorder.events.append(event)
            },
            observationHandler: { observation in
                recorder.observations.append(observation)
            }
        )
        let route = route(output: .bluetoothA2DP)

        await router.deliverRouteChange(
            origin: .managedConfiguration(.activate),
            reason: .categoryChange,
            route: route
        )

        #expect(recorder.events.isEmpty)
        #expect(recorder.observations == [AudioRouteChangeObservation(
            reason: .categoryChange,
            origin: .managedConfiguration(.activate),
            inputKinds: [.builtInMicrophone],
            outputKinds: [.bluetoothA2DP]
        )])
    }

    @Test("External changes reach safety before the observation")
    func externalSafetyPrecedesObservation() async {
        let recorder = AudioSessionEventRouterRecorder()
        let router = AudioSessionEventRouter(
            eventHandler: { event in
                recorder.events.append(event)
                recorder.deliveryOrder.append("safety")
            },
            observationHandler: { observation in
                recorder.observations.append(observation)
                recorder.deliveryOrder.append("observation")
            }
        )
        let route = route(output: .builtInSpeaker)

        await router.deliverRouteChange(
            origin: .external,
            reason: .oldDeviceUnavailable,
            route: route
        )

        #expect(recorder.events == [.routeChanged(route)])
        #expect(recorder.deliveryOrder == ["safety", "observation"])
        #expect(recorder.observations == [AudioRouteChangeObservation(
            reason: .oldDeviceUnavailable,
            origin: .external,
            inputKinds: [.builtInMicrophone],
            outputKinds: [.builtInSpeaker]
        )])
    }

    @Test("Interruption and media reset always reach safety")
    func interruptionAndResetAlwaysReachSafetyHandler() async {
        let recorder = AudioSessionEventRouterRecorder()
        let router = AudioSessionEventRouter(
            eventHandler: { event in
                recorder.events.append(event)
            }
        )

        await router.deliverInterruptionBegan()
        await router.deliverInterruptionEnded(shouldResume: true)
        await router.deliverMediaServicesReset()

        #expect(recorder.events == [
            .interruptionBegan,
            .interruptionEnded(shouldResume: true),
            .mediaServicesReset,
        ])
    }

    private func route(output: AudioRoutePortKind) -> AudioRouteSnapshot {
        AudioRouteSnapshot(
            inputs: [AudioRoutePort(
                id: "input-secret-id",
                name: "Input Secret Name",
                kind: .builtInMicrophone
            )],
            outputs: [AudioRoutePort(
                id: "output-secret-id",
                name: "Output Secret Name",
                kind: output
            )],
            availableInputs: []
        )
    }
}

private final class ManualAttributionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock().now

    var now: ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    func advance(by duration: Duration) {
        lock.lock()
        defer { lock.unlock() }
        instant = instant.advanced(by: duration)
    }
}

@MainActor
private final class AudioSessionEventRouterRecorder {
    var events: [AudioDeviceEvent] = []
    var observations: [AudioRouteChangeObservation] = []
    var deliveryOrder: [String] = []
}
