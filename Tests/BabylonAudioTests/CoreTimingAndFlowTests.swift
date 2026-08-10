import Foundation
import Testing
@testable import BabylonAudio

@Suite("Core timing and flow isolation")
struct CoreTimingAndFlowTests {
    @Test("Frame sequencing is monotonic and flow-bound")
    func frameSequencingIsMonotonic() async throws {
        let source = ScriptedTimeSource([
            .milliseconds(10),
            .milliseconds(5),
            .milliseconds(30),
        ])
        let flowID = AudioFlowID()
        let sequencer = AudioFrameSequencer(
            flowID: flowID,
            clock: AudioMonotonicClock(now: { source.next() })
        )
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)

        let first = try await sequencer.makeFrame(format: format, payload: Data(count: 960))
        let second = try await sequencer.makeFrame(format: format, payload: Data(count: 960))
        let third = try await sequencer.makeFrame(format: format, payload: Data(count: 960))

        #expect([first.sequence, second.sequence, third.sequence] == [0, 1, 2])
        #expect([first.timestamp, second.timestamp, third.timestamp] == [
            .milliseconds(10), .milliseconds(10), .milliseconds(30),
        ])
        #expect([first.flowID, second.flowID, third.flowID].allSatisfy { $0 == flowID })
    }

    @Test("Stopped and replaced generations reject late work")
    func generationsRejectLateWork() throws {
        let gate = FlowGenerationGate()
        let firstFlow = AudioFlowID()
        let secondFlow = AudioFlowID()
        let firstGeneration = gate.activate(flowID: firstFlow)
        let firstFrame = try makeFrame(flowID: firstFlow)

        #expect(gate.accepts(firstFrame, generation: firstGeneration))
        #expect(gate.acceptsCompletion(generation: firstGeneration))

        let secondGeneration = gate.activate(flowID: secondFlow)
        let secondFrame = try makeFrame(flowID: secondFlow)

        #expect(!gate.accepts(firstFrame, generation: firstGeneration))
        #expect(!gate.acceptsCompletion(generation: firstGeneration))
        #expect(gate.accepts(secondFrame, generation: secondGeneration))

        gate.stop()
        #expect(!gate.accepts(secondFrame, generation: secondGeneration))
        #expect(!gate.acceptsCompletion(generation: secondGeneration))
    }

    private func makeFrame(flowID: AudioFlowID) throws -> AudioFrame {
        try AudioFrame(
            flowID: flowID,
            sequence: 0,
            timestamp: .zero,
            format: .monoPCM16(sampleRate: 24_000),
            payload: Data(count: 960),
            duration: .milliseconds(20)
        )
    }
}

private final class ScriptedTimeSource: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Duration]

    init(_ values: [Duration]) {
        self.values = values
    }

    func next() -> Duration {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty ? .zero : values.removeFirst()
    }
}
