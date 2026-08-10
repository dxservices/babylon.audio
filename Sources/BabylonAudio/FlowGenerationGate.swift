import Foundation

public struct AudioFlowGeneration: Hashable, Sendable {
    public let flowID: AudioFlowID
    public let rawValue: UUID

    public init(flowID: AudioFlowID, rawValue: UUID = UUID()) {
        self.flowID = flowID
        self.rawValue = rawValue
    }
}

@available(iOS 18, macOS 13, *)
/// Coordinates flow callbacks after they have left the real-time audio thread.
public final class FlowGenerationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeGeneration: AudioFlowGeneration?

    public init() {}

    @discardableResult
    public func activate(flowID: AudioFlowID) -> AudioFlowGeneration {
        lock.lock()
        defer { lock.unlock() }
        let generation = AudioFlowGeneration(flowID: flowID)
        activeGeneration = generation
        return generation
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        activeGeneration = nil
    }

    public func accepts(
        _ frame: AudioFrame,
        generation: AudioFlowGeneration
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeGeneration == generation && frame.flowID == generation.flowID
    }

    public func acceptsCompletion(generation: AudioFlowGeneration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeGeneration == generation
    }
}
