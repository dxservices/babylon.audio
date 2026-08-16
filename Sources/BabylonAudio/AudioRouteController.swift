@available(iOS 18, macOS 13, *)
public struct AudioRouteConfigurationResult: Equatable, Sendable {
    public let activeProfile: AudioSessionProfile?
    public let route: AudioRouteSnapshot
    public let safety: AudioRouteSafetyEvaluation

    public init(
        activeProfile: AudioSessionProfile?,
        route: AudioRouteSnapshot,
        safety: AudioRouteSafetyEvaluation
    ) {
        self.activeProfile = activeProfile
        self.route = route
        self.safety = safety
    }
}

@available(iOS 18, macOS 13, *)
@MainActor
protocol AudioSessionControlling: AnyObject {
    var routeSnapshot: AudioRouteSnapshot { get }

    func activate(_ profile: AudioSessionProfile) throws
    func deactivate() throws
    func selectPrivateAccessoryInput(id: String) throws -> Bool
}

@available(iOS 18, macOS 13, *)
@MainActor
public final class AudioRouteController {
    public private(set) var lastResult: AudioRouteConfigurationResult?

    private let session: any AudioSessionControlling
    private let observationAttempts: Int
    private let stableUnsafeConfirmations: Int
    private let waitForRouteUpdate: @MainActor @Sendable () async throws -> Void

    init(
        session: any AudioSessionControlling,
        observationAttempts: Int,
        stableUnsafeConfirmations: Int = 5,
        waitForRouteUpdate: @escaping @MainActor @Sendable () async throws -> Void
    ) {
        precondition(observationAttempts > 0)
        precondition(stableUnsafeConfirmations > 0)
        self.session = session
        self.observationAttempts = observationAttempts
        self.stableUnsafeConfirmations = stableUnsafeConfirmations
        self.waitForRouteUpdate = waitForRouteUpdate
    }

    public func configure(
        inputPolicy: AudioInputPolicy,
        outputPolicy: DeviceOutputPolicy,
        trustedOutputs: Set<AudioTrustedOutput>
    ) async throws -> AudioRouteConfigurationResult {
        let profiles = AudioSessionProfilePolicy.activationOrder(for: inputPolicy)
        var lastRoute = AudioRouteSnapshot.empty
        var lastSafety = AudioRouteSafetyEvaluation.unsafe(
            reason: .outputUnavailable
        )

        do {
            for (index, profile) in profiles.enumerated() {
                if index > 0 {
                    try session.deactivate()
                }
                try session.activate(profile)

                let selectedPrivateAccessoryInput: Bool
                if profile == .privateAccessoryDuplex {
                    selectedPrivateAccessoryInput =
                        try await selectDiscoveredPrivateAccessoryInput()
                } else {
                    selectedPrivateAccessoryInput = false
                }

                var previousUnsafeRoute: AudioRouteSnapshot?
                var unchangedUnsafeConfirmations = 0
                observation: for attempt in 0..<observationAttempts {
                    let route = session.routeSnapshot
                    let safety = AudioRouteSafetyPolicy.evaluate(
                        route,
                        inputPolicy: inputPolicy,
                        outputPolicy: outputPolicy,
                        trustedOutputs: trustedOutputs
                    )
                    lastRoute = route
                    lastSafety = safety

                    switch safety {
                    case .safe:
                        let result = AudioRouteConfigurationResult(
                            activeProfile: profile,
                            route: route,
                            safety: safety
                        )
                        lastResult = result
                        return result
                    case .trustRequired:
                        try session.deactivate()
                        let result = AudioRouteConfigurationResult(
                            activeProfile: nil,
                            route: route,
                            safety: safety
                        )
                        lastResult = result
                        return result
                    case .unsafe:
                        if route == previousUnsafeRoute {
                            unchangedUnsafeConfirmations += 1
                            if !selectedPrivateAccessoryInput,
                               unchangedUnsafeConfirmations
                                >= stableUnsafeConfirmations
                            {
                                break observation
                            }
                        } else {
                            previousUnsafeRoute = route
                            unchangedUnsafeConfirmations = 0
                        }
                    }

                    if attempt + 1 < observationAttempts {
                        try await waitForRouteUpdate()
                    }
                }
            }

            try session.deactivate()
            let result = AudioRouteConfigurationResult(
                activeProfile: nil,
                route: lastRoute,
                safety: lastSafety
            )
            lastResult = result
            return result
        } catch {
            try? session.deactivate()
            throw error
        }
    }

    private func selectDiscoveredPrivateAccessoryInput() async throws -> Bool {
        var previousSnapshot: AudioRouteSnapshot?
        var unchangedConfirmations = 0
        for attempt in 0..<observationAttempts {
            // AVAudioSession does not pair available inputs with outputs here.
            // Preserve system discovery order, then verify the resulting route.
            let snapshot = session.routeSnapshot
            if let input = snapshot.availableInputs.first(where: {
                $0.kind.isPrivateInputCandidate
            }) {
                return try session.selectPrivateAccessoryInput(id: input.id)
            }
            if snapshot == previousSnapshot {
                unchangedConfirmations += 1
                if unchangedConfirmations >= stableUnsafeConfirmations {
                    return false
                }
            } else {
                previousSnapshot = snapshot
                unchangedConfirmations = 0
            }
            if attempt + 1 < observationAttempts {
                try await waitForRouteUpdate()
            }
        }
        return false
    }
}

#if os(iOS)
@available(iOS 18, *)
extension AudioSessionController: AudioSessionControlling {}

@available(iOS 18, *)
public extension AudioRouteController {
    convenience init(session: AudioSessionController = .shared) {
        self.init(
            session: session,
            observationAttempts: 30,
            stableUnsafeConfirmations: 5,
            waitForRouteUpdate: {
                try await Task.sleep(for: .milliseconds(100))
            }
        )
    }
}
#endif
