import Foundation
import Testing
@testable import BabylonAudio

@Suite("Audio session route attribution")
struct AudioSessionRouteAttributionTests {
    @Test("Synchronous causality handles an echo without a previous route")
    func synchronousEchoWithoutPreviousRouteIsManaged() {
        let attribution = makeAttribution()
        let initial = identity(id: "speaker", output: .builtInSpeaker)
        let settled = identity(id: "a2dp", output: .bluetoothA2DP)

        attribution.beginWindow(initialRoute: initial)
        let token = attribution.beginMutation(.activate)
        let capture = attribution.captureNotification(
            reason: .categoryChange,
            previousRoute: nil
        )
        attribution.endMutation(token, settledRoute: settled)
        attribution.endWindow(settledRoute: settled)

        #expect(attribution.resolve(
            capture,
            currentRoute: settled
        ) == .managedConfiguration(.activate))
    }

    @Test("A delayed callback without a previous route fails closed")
    func delayedEchoWithoutPreviousRouteIsExternal() {
        let attribution = makeAttribution()
        let route = identity(id: "a2dp", output: .bluetoothA2DP)
        attribution.updateKnownRoute(route)
        let token = attribution.beginMutation(.activate)
        attribution.endMutation(token, settledRoute: route)

        let capture = attribution.captureNotification(
            reason: .routeConfigurationChange,
            previousRoute: nil
        )

        #expect(attribution.resolve(
            capture,
            currentRoute: route
        ) == .external)
    }

    @Test("An exact same-route callback captured after mutation end is external")
    func callbackAfterMutationEndIsExternal() {
        let attribution = makeAttribution()
        let initial = identity(id: "speaker", output: .builtInSpeaker)
        let settled = identity(id: "hfp", output: .bluetoothHFP)

        attribution.updateKnownRoute(initial)
        let token = attribution.beginMutation(.selectPrivateAccessoryInput)
        attribution.endMutation(token, settledRoute: settled)
        let capture = attribution.captureNotification(
            reason: .routeConfigurationChange,
            previousRoute: initial
        )

        #expect(attribution.resolve(
            capture,
            currentRoute: settled
        ) == .external)
    }

    @Test("Multiple synchronous callbacks can claim one active revision")
    func multipleCallbacksCanClaimActiveRevision() {
        let attribution = makeAttribution()
        let route = identity(id: "a2dp", output: .bluetoothA2DP)
        attribution.updateKnownRoute(route)
        let token = attribution.beginMutation(.activate)
        let captures = [AudioRouteChangeReason.routeConfigurationChange,
                        .routeConfigurationChange].map { reason in
            attribution.captureNotification(
                reason: reason,
                previousRoute: route
            )
        }
        attribution.endMutation(token, settledRoute: route)

        for capture in captures {
            #expect(attribution.resolve(
                capture,
                currentRoute: route
            ) == .managedConfiguration(.activate))
        }
        let replay = attribution.captureNotification(
            reason: .routeConfigurationChange,
            previousRoute: route
        )
        #expect(attribution.resolve(
            replay,
            currentRoute: route
        ) == .external)
    }

    @Test("An async window without an exact mutation cannot own an event")
    func openWindowDoesNotOwnExternalEvent() {
        let attribution = makeAttribution()
        let initial = identity(id: "a2dp", output: .bluetoothA2DP)
        let external = identity(id: "speaker", output: .builtInSpeaker)
        attribution.beginWindow(initialRoute: initial)

        let capture = attribution.captureNotification(
            reason: .routeConfigurationChange,
            previousRoute: initial
        )

        #expect(attribution.resolve(
            capture,
            currentRoute: external
        ) == .external)
        #expect(attribution.isWindowOpen)
    }

    @Test("A notification with an unrelated previous route is external")
    func unrelatedPreviousRouteIsExternal() {
        let attribution = makeAttribution()
        let initial = identity(id: "a2dp", output: .bluetoothA2DP)
        let unrelated = identity(id: "wired", output: .wiredHeadphones)
        attribution.updateKnownRoute(initial)
        let token = attribution.beginMutation(.activate)
        let capture = attribution.captureNotification(
            reason: .routeConfigurationChange,
            previousRoute: unrelated
        )
        attribution.endMutation(token, settledRoute: initial)
        #expect(attribution.resolve(
            capture,
            currentRoute: initial
        ) == .external)
    }

    @Test("A current route mismatch invalidates a captured revision")
    func currentRouteMismatchIsExternal() {
        let attribution = makeAttribution()
        let initial = identity(id: "speaker", output: .builtInSpeaker)
        let settled = identity(id: "a2dp", output: .bluetoothA2DP)
        let external = identity(id: "hfp", output: .bluetoothHFP)
        attribution.updateKnownRoute(initial)
        let token = attribution.beginMutation(.activate)
        let capture = attribution.captureNotification(
            reason: .routeConfigurationChange,
            previousRoute: initial
        )
        attribution.endMutation(token, settledRoute: settled)

        #expect(attribution.resolve(
            capture,
            currentRoute: external
        ) == .external)
    }

    @Test("Name participates in exact route identity")
    func routeNameParticipatesInIdentity() {
        let attribution = makeAttribution()
        let initial = identity(
            id: "headset",
            name: "Headset A",
            output: .bluetoothHFP
        )
        let renamed = identity(
            id: "headset",
            name: "Headset B",
            output: .bluetoothHFP
        )
        attribution.updateKnownRoute(initial)
        let token = attribution.beginMutation(.activate)
        let capture = attribution.captureNotification(
            reason: .routeConfigurationChange,
            previousRoute: initial
        )
        attribution.endMutation(token, settledRoute: initial)

        #expect(attribution.resolve(
            capture,
            currentRoute: renamed
        ) == .external)
    }

    @Test("A callback-time revision survives a later managed transaction")
    func callbackCaptureIsFrozenAcrossNewTransaction() {
        let attribution = makeAttribution()
        let route = identity(id: "a2dp", output: .bluetoothA2DP)
        attribution.updateKnownRoute(route)
        let first = attribution.beginMutation(.activate)
        let capture = attribution.captureNotification(
            reason: .categoryChange,
            previousRoute: route
        )
        attribution.endMutation(first, settledRoute: route)

        let second = attribution.beginMutation(.deactivate)
        attribution.endMutation(second, settledRoute: route)

        #expect(attribution.resolve(
            capture,
            currentRoute: route
        ) == .managedConfiguration(.activate))
    }

    @Test("Interruption or reset invalidates callback-time captures")
    func resetInvalidatesCapturedRevision() {
        let attribution = makeAttribution()
        let route = identity(id: "hfp", output: .bluetoothHFP)
        attribution.updateKnownRoute(route)
        let token = attribution.beginMutation(.deactivate)
        let capture = attribution.captureNotification(
            reason: .categoryChange,
            previousRoute: route
        )
        attribution.endMutation(token, settledRoute: route)

        attribution.reset()

        #expect(attribution.resolve(
            capture,
            currentRoute: route
        ) == .external)
    }

    @Test("External reasons invalidate captured managed expectations")
    func externalReasonInvalidatesExpectations() {
        let attribution = makeAttribution()
        let route = identity(id: "a2dp", output: .bluetoothA2DP)
        attribution.updateKnownRoute(route)
        let token = attribution.beginMutation(.activate)
        let echo = attribution.captureNotification(
            reason: .routeConfigurationChange,
            previousRoute: route
        )

        let external = attribution.captureNotification(
            reason: .oldDeviceUnavailable,
            previousRoute: route
        )
        attribution.endMutation(token, settledRoute: route)
        #expect(attribution.resolve(
            external,
            currentRoute: route
        ) == .external)
        #expect(attribution.resolve(
            echo,
            currentRoute: route
        ) == .external)
    }

    @Test("Expectation overflow fails closed and a later transaction recovers")
    func boundedExpectationLifecycle() {
        let attribution = makeAttribution()
        let route = identity(id: "a2dp", output: .bluetoothA2DP)
        attribution.updateKnownRoute(route)

        attribution.beginWindow(initialRoute: route)
        var tokens: [AudioSessionRouteAttribution.MutationToken] = []
        for _ in 0...AudioSessionRouteAttribution.maximumExpectations {
            tokens.append(attribution.beginMutation(.activate))
        }
        let overflow = attribution.captureNotification(
            reason: .routeConfigurationChange,
            previousRoute: route
        )
        #expect(attribution.resolve(
            overflow,
            currentRoute: route
        ) == .external)
        for token in tokens.reversed() {
            attribution.endMutation(token, settledRoute: route)
        }
        attribution.endWindow(settledRoute: route)

        attribution.beginWindow(initialRoute: route)
        let recovered = attribution.beginMutation(.activate)
        let echo = attribution.captureNotification(
            reason: .routeConfigurationChange,
            previousRoute: route
        )
        attribution.endMutation(recovered, settledRoute: route)
        attribution.endWindow(settledRoute: route)
        #expect(attribution.resolve(
            echo,
            currentRoute: route
        ) == .managedConfiguration(.activate))
    }

    @Test("Callback overflow invalidates the active revision")
    func boundedCallbackLifecycle() {
        let attribution = makeAttribution()
        let route = identity(id: "a2dp", output: .bluetoothA2DP)
        attribution.updateKnownRoute(route)
        let token = attribution.beginMutation(.activate)
        let maximumCaptures = AudioSessionRouteAttribution
            .maximumCapturesPerExpectation
        let captures = (0..<maximumCaptures).map { _ in
            attribution.captureNotification(
                reason: .routeConfigurationChange,
                previousRoute: route
            )
        }
        let overflow = attribution.captureNotification(
            reason: .routeConfigurationChange,
            previousRoute: route
        )
        attribution.endMutation(token, settledRoute: route)

        #expect(attribution.resolve(
            overflow,
            currentRoute: route
        ) == .external)
        for capture in captures {
            #expect(attribution.resolve(
                capture,
                currentRoute: route
            ) == .external)
        }
    }

    private func makeAttribution() -> AudioSessionRouteAttribution {
        AudioSessionRouteAttribution()
    }

    private func identity(
        id: String,
        name: String? = nil,
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
                name: name ?? "Output \(id)",
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

@MainActor
private final class AudioSessionEventRouterRecorder {
    var events: [AudioDeviceEvent] = []
    var observations: [AudioRouteChangeObservation] = []
    var deliveryOrder: [String] = []
}
