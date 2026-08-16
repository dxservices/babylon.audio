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
    private let waitForRouteUpdate: @MainActor @Sendable () async throws -> Void

    init(
        session: any AudioSessionControlling,
        observationAttempts: Int,
        waitForRouteUpdate: @escaping @MainActor @Sendable () async throws -> Void
    ) {
        precondition(observationAttempts > 0)
        self.session = session
        self.observationAttempts = observationAttempts
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

                if profile == .privateAccessoryDuplex {
                    try await selectDiscoveredPrivateAccessoryInput()
                }

                for attempt in 0..<observationAttempts {
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
                        break
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

    private func selectDiscoveredPrivateAccessoryInput() async throws {
        for attempt in 0..<observationAttempts {
            // AVAudioSession does not pair available inputs with outputs here.
            // Preserve system discovery order, then verify the resulting route.
            if let input = session.routeSnapshot.availableInputs.first(where: {
                $0.kind.isPrivateInputCandidate
            }) {
                _ = try session.selectPrivateAccessoryInput(id: input.id)
                return
            }
            if attempt + 1 < observationAttempts {
                try await waitForRouteUpdate()
            }
        }
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
            waitForRouteUpdate: {
                try await Task.sleep(for: .milliseconds(100))
            }
        )
    }
}
#endif
