import Foundation
import Testing
@testable import BabylonAudio

@Suite("Bounded uplink queue")
struct BoundedUplinkQueueTests {
    @Test("Only one send is in flight and pending frames preserve order")
    func serializesSends() async throws {
        let sender = ControlledUplinkSender()
        let queue = BoundedUplinkQueue(
            policy: try BoundedUplinkQueuePolicy(
                maximumPendingAudioDuration: .seconds(1),
                maximumFrameAge: .seconds(2)
            )
        )
        let flowID = AudioFlowID()
        await queue.start(flowID: flowID, sender: sender)

        await queue.enqueue(try makeUplinkFrame(flowID: flowID, sequence: 0))
        await queue.enqueue(try makeUplinkFrame(flowID: flowID, sequence: 1))
        await queue.enqueue(try makeUplinkFrame(flowID: flowID, sequence: 2))

        #expect(await eventually { await sender.sentSequences() == [0] })
        #expect(await queue.snapshot.pending.frameCount == 2)

        await sender.completeNext()
        #expect(await eventually { await sender.sentSequences() == [0, 1] })
        await sender.completeNext()
        #expect(await eventually { await sender.sentSequences() == [0, 1, 2] })
        await sender.completeNext()
        #expect(await eventually { !(await queue.snapshot.isSending) })
    }

    @Test("Source end waits for every accepted send before completing")
    func sourceEndDrainsAcceptedTail() async throws {
        let sender = ControlledUplinkSender()
        let queue = BoundedUplinkQueue(
            policy: try BoundedUplinkQueuePolicy(
                maximumPendingAudioDuration: .seconds(1),
                maximumFrameAge: .seconds(2)
            )
        )
        let flowID = AudioFlowID()
        await queue.start(flowID: flowID, sender: sender)
        await queue.enqueue(try makeUplinkFrame(flowID: flowID, sequence: 0))
        await queue.enqueue(try makeUplinkFrame(flowID: flowID, sequence: 1))
        #expect(await eventually { await sender.sentSequences() == [0] })

        let completion = Task {
            await queue.finishSource(flowID: flowID)
        }
        await sender.completeNext()
        #expect(await eventually { await sender.sentSequences() == [0, 1] })
        #expect(await queue.snapshot.isRunning)
        await sender.completeNext()

        #expect(await completion.value)
        let snapshot = await queue.snapshot
        #expect(!snapshot.isRunning)
        #expect(snapshot.pending == .zero)
        #expect(snapshot.discardedFrameCount == 0)
    }

    @Test("Frames arriving during source-end drain have a distinct discard reason")
    func sourceEndRejectsLateFramesDistinctly() async throws {
        let sender = ControlledUplinkSender()
        let diagnostics = RecordingUplinkDiagnostics()
        let queue = BoundedUplinkQueue(diagnosticSink: diagnostics)
        let flowID = AudioFlowID()
        await queue.start(flowID: flowID, sender: sender)
        let inFlight = try makeUplinkFrame(flowID: flowID, sequence: 0)
        let late = try makeUplinkFrame(flowID: flowID, sequence: 1)
        await queue.enqueue(inFlight)
        #expect(await eventually { await sender.sentSequences() == [0] })

        let completion = Task {
            await queue.finishSource(flowID: flowID)
        }
        #expect(await eventually { await queue.snapshot.isSourceEnded })
        await queue.enqueue(late)

        #expect(await eventually {
            await diagnostics.events().contains(.queueDiscarded(
                flowID: flowID,
                direction: .uplink,
                reason: .sourceEnded,
                frameCount: 1,
                duration: late.duration
            ))
        })
        await sender.completeNext()
        #expect(await completion.value)
    }

    @Test("Stop interrupts a pending source-end drain")
    func stopInterruptsSourceEndDrain() async throws {
        let sender = ControlledUplinkSender()
        let queue = BoundedUplinkQueue()
        let flowID = AudioFlowID()
        await queue.start(flowID: flowID, sender: sender)
        await queue.enqueue(try makeUplinkFrame(flowID: flowID, sequence: 0))
        #expect(await eventually { await sender.sentSequences() == [0] })

        let completion = Task {
            await queue.finishSource(flowID: flowID)
        }
        for _ in 0..<10 { await Task.yield() }
        await queue.stop()

        #expect(!(await completion.value))
        await sender.completeNext()
        for _ in 0..<10 { await Task.yield() }
        #expect(!(await queue.snapshot.isRunning))
        #expect(await sender.sentSequences() == [0])
    }

    @Test("Overflow drops the oldest pending frame using format-derived duration")
    func dropsOldestPendingFrame() async throws {
        let sender = ControlledUplinkSender()
        let queue = BoundedUplinkQueue(
            policy: try BoundedUplinkQueuePolicy(
                maximumPendingAudioDuration: .milliseconds(100),
                maximumFrameAge: .seconds(2)
            )
        )
        let flowID = AudioFlowID()
        let pcm16 = try AudioStreamFormat.monoPCM16(sampleRate: 16_000)
        let floatStereo = try AudioStreamFormat(
            sampleRate: 48_000,
            channelCount: 2,
            sampleEncoding: .float32,
            interleaving: .interleaved
        )
        await queue.start(flowID: flowID, sender: sender)

        await queue.enqueue(try makeUplinkFrame(
            flowID: flowID,
            sequence: 0,
            duration: .milliseconds(20),
            format: pcm16
        ))
        #expect(await eventually { await sender.sentSequences() == [0] })
        await queue.enqueue(try makeUplinkFrame(
            flowID: flowID,
            sequence: 1,
            duration: .milliseconds(100),
            format: pcm16
        ))
        await queue.enqueue(try makeUplinkFrame(
            flowID: flowID,
            sequence: 2,
            duration: .milliseconds(100),
            format: floatStereo
        ))

        let snapshot = await queue.snapshot
        #expect(snapshot.pending == AudioQueueSnapshot(
            frameCount: 1,
            duration: .milliseconds(100)
        ))
        #expect(snapshot.droppedOverflowFrameCount == 1)

        await sender.completeNext()
        #expect(await eventually { await sender.sentSequences() == [0, 2] })
        await sender.completeNext()
    }

    @Test("Maximum age uses local enqueue time instead of media timestamp")
    func expiresUsingLocalEnqueueTime() async throws {
        let time = MutableAudioTime()
        let sender = ControlledUplinkSender()
        let queue = BoundedUplinkQueue(
            policy: try BoundedUplinkQueuePolicy(
                maximumPendingAudioDuration: .seconds(1),
                maximumFrameAge: .seconds(1)
            ),
            clock: AudioMonotonicClock(now: { time.now() })
        )
        let flowID = AudioFlowID()
        await queue.start(flowID: flowID, sender: sender)
        await queue.enqueue(try makeUplinkFrame(flowID: flowID, sequence: 0))
        #expect(await eventually { await sender.sentSequences() == [0] })
        await queue.enqueue(try makeUplinkFrame(
            flowID: flowID,
            sequence: 1,
            timestamp: .seconds(900)
        ))

        time.advance(by: .milliseconds(1_001))
        await sender.completeNext()

        #expect(await eventually { await queue.snapshot.droppedExpiredFrameCount == 1 })
        #expect(await sender.sentSequences() == [0])
        #expect(await queue.snapshot.pending == .zero)
    }

    @Test("Snapshot reports frame age without expiring pending audio")
    func snapshotAgeReadDoesNotMutateQueue() async throws {
        let time = MutableAudioTime()
        let sender = ControlledUplinkSender()
        let policy = try BoundedUplinkQueuePolicy(
            maximumPendingAudioDuration: .seconds(1),
            maximumFrameAge: .seconds(1)
        )
        let queue = BoundedUplinkQueue(
            policy: policy,
            clock: AudioMonotonicClock(now: { time.now() })
        )
        let flowID = AudioFlowID()
        await queue.start(flowID: flowID, sender: sender)
        await queue.enqueue(try makeUplinkFrame(flowID: flowID, sequence: 0))
        #expect(await eventually { await sender.sentSequences() == [0] })
        await queue.enqueue(try makeUplinkFrame(flowID: flowID, sequence: 1))
        time.advance(by: .milliseconds(1_100))

        let firstRead = await queue.snapshot
        let secondRead = await queue.snapshot
        #expect(firstRead.maximumFrameAge == policy.maximumFrameAge)
        #expect(firstRead.oldestPendingFrameAge == .milliseconds(1_100))
        #expect(firstRead.pending.frameCount == 1)
        #expect(secondRead.pending.frameCount == 1)
        #expect(secondRead.discardReasonCounts.expired == 0)

        await queue.stop()
        await sender.completeNext()
    }

    @Test("Stop clears pending work and late completion cannot restart draining")
    func stopIsolatesLateCompletion() async throws {
        let sender = ControlledUplinkSender()
        let queue = BoundedUplinkQueue(
            policy: try BoundedUplinkQueuePolicy(
                maximumPendingAudioDuration: .seconds(1),
                maximumFrameAge: .seconds(2)
            )
        )
        let flowID = AudioFlowID()
        await queue.start(flowID: flowID, sender: sender)
        await queue.enqueue(try makeUplinkFrame(flowID: flowID, sequence: 0))
        await queue.enqueue(try makeUplinkFrame(flowID: flowID, sequence: 1))
        #expect(await eventually { await sender.sentSequences() == [0] })

        await queue.stop()
        await sender.completeNext()
        for _ in 0..<10 { await Task.yield() }

        #expect(await sender.sentSequences() == [0])
        #expect(!(await queue.snapshot.isRunning))
        #expect(await queue.snapshot.pending == .zero)
        #expect(await queue.snapshot.discardedFrameCount == 1)
    }

    @Test("Frames enqueued while stopped count as discarded")
    func stoppedEnqueueCountsAsDiscarded() async throws {
        let queue = BoundedUplinkQueue(
            policy: try BoundedUplinkQueuePolicy(
                maximumPendingAudioDuration: .seconds(1),
                maximumFrameAge: .seconds(2)
            )
        )

        await queue.enqueue(try makeUplinkFrame(
            flowID: AudioFlowID(),
            sequence: 0
        ))

        #expect(await queue.snapshot.discardedFrameCount == 1)
    }

    @Test("A send failure stops once, clears pending work, and reports the original error")
    func failureStopsAndReportsOnce() async throws {
        let sender = ControlledUplinkSender()
        let failures = UplinkFailureRecorder()
        let queue = BoundedUplinkQueue(
            policy: try BoundedUplinkQueuePolicy(
                maximumPendingAudioDuration: .seconds(1),
                maximumFrameAge: .seconds(2)
            )
        )
        let flowID = AudioFlowID()
        await queue.start(flowID: flowID, sender: sender) { error in
            await failures.record(error)
        }
        await queue.enqueue(try makeUplinkFrame(flowID: flowID, sequence: 0))
        await queue.enqueue(try makeUplinkFrame(flowID: flowID, sequence: 1))
        #expect(await eventually { await sender.sentSequences() == [0] })

        await sender.completeNext(throwing: UplinkTestError.rejected)

        #expect(await eventually { await failures.errors() == [.rejected] })
        #expect(!(await queue.snapshot.isRunning))
        #expect(await queue.snapshot.pending == .zero)
        #expect(await queue.snapshot.discardedFrameCount == 1)
    }

    @Test("Stale-flow frames are rejected with content-free diagnostics")
    func rejectsStaleFlow() async throws {
        let sender = ControlledUplinkSender()
        let diagnostics = RecordingUplinkDiagnostics()
        let queue = BoundedUplinkQueue(
            policy: try BoundedUplinkQueuePolicy(
                maximumPendingAudioDuration: .seconds(1),
                maximumFrameAge: .seconds(2)
            ),
            diagnosticSink: diagnostics
        )
        let activeFlow = AudioFlowID()
        let staleFlow = AudioFlowID()
        await queue.start(flowID: activeFlow, sender: sender)

        await queue.enqueue(try makeUplinkFrame(flowID: staleFlow, sequence: 0))

        #expect(await sender.sentSequences().isEmpty)
        #expect(await eventually {
            await diagnostics.events().contains(.queueDiscarded(
                flowID: staleFlow,
                direction: .uplink,
                reason: .staleFlow,
                frameCount: 1,
                duration: .milliseconds(20)
            ))
        })
    }

    @Test("A sustained tiny-frame burst remains within the duration bound")
    func burstRemainsBounded() async throws {
        let sender = ControlledUplinkSender()
        let queue = BoundedUplinkQueue(
            policy: try BoundedUplinkQueuePolicy(
                maximumPendingAudioDuration: .milliseconds(100),
                maximumFrameAge: .seconds(10)
            )
        )
        let flowID = AudioFlowID()
        let format = try AudioStreamFormat(
            sampleRate: 48_000,
            channelCount: 2,
            sampleEncoding: .float32,
            interleaving: .interleaved
        )
        await queue.start(flowID: flowID, sender: sender)
        await queue.enqueue(try makeUplinkFrame(
            flowID: flowID,
            sequence: 0,
            duration: .milliseconds(1),
            format: format
        ))
        #expect(await eventually { await sender.sentSequences() == [0] })

        for sequence in 1...1_000 {
            await queue.enqueue(try makeUplinkFrame(
                flowID: flowID,
                sequence: UInt64(sequence),
                duration: .milliseconds(1),
                format: format
            ))
        }

        let snapshot = await queue.snapshot
        #expect(snapshot.pending.frameCount == 100)
        #expect(snapshot.pending.duration == .milliseconds(100))
        #expect(snapshot.maximumPendingAudioDuration == .milliseconds(100))
        #expect(snapshot.droppedOverflowFrameCount == 900)

        await queue.stop()
        await sender.completeNext()
    }

    @Test("Flow replacement isolates an old sender completion")
    func replacementIsolatesLateCompletion() async throws {
        let oldSender = ControlledUplinkSender()
        let newSender = ControlledUplinkSender()
        let failures = UplinkFailureRecorder()
        let queue = BoundedUplinkQueue(
            policy: try BoundedUplinkQueuePolicy(
                maximumPendingAudioDuration: .seconds(1),
                maximumFrameAge: .seconds(2)
            )
        )
        let oldFlow = AudioFlowID()
        let newFlow = AudioFlowID()
        await queue.start(flowID: oldFlow, sender: oldSender) { error in
            await failures.record(error)
        }
        await queue.enqueue(try makeUplinkFrame(flowID: oldFlow, sequence: 0))
        #expect(await eventually { await oldSender.sentSequences() == [0] })

        await queue.start(flowID: newFlow, sender: newSender)
        await queue.enqueue(try makeUplinkFrame(flowID: newFlow, sequence: 0))
        #expect(await eventually { await newSender.sentSequences() == [0] })
        await oldSender.completeNext(throwing: UplinkTestError.rejected)
        for _ in 0..<10 { await Task.yield() }

        #expect(await failures.errors().isEmpty)
        #expect(await queue.snapshot.flowID == newFlow)
        #expect(await queue.snapshot.isRunning)
        await newSender.completeNext()
    }

    @Test("Policy rejects nonpositive duration bounds")
    func rejectsInvalidPolicy() {
        #expect(throws: AudioStreamingError.invalidPolicy) {
            try BoundedUplinkQueuePolicy(
                maximumPendingAudioDuration: .zero,
                maximumFrameAge: .seconds(1)
            )
        }
    }
}

private actor ControlledUplinkSender: AudioFrameSender {
    private var frames: [AudioFrame] = []
    private var continuations: [CheckedContinuation<Void, any Error>] = []

    func send(_ frame: AudioFrame) async throws {
        frames.append(frame)
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func sentSequences() -> [UInt64] {
        frames.map(\.sequence)
    }

    func completeNext(throwing error: (any Error)? = nil) {
        guard !continuations.isEmpty else { return }
        let continuation = continuations.removeFirst()
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

private actor UplinkFailureRecorder {
    private var recordedErrors: [any Error] = []

    func record(_ error: any Error) {
        recordedErrors.append(error)
    }

    func errors() -> [UplinkTestError] {
        recordedErrors.compactMap { $0 as? UplinkTestError }
    }
}

private actor RecordingUplinkDiagnostics: AudioDiagnosticSink {
    private var recordedEvents: [AudioDiagnosticEvent] = []

    func record(_ event: AudioDiagnosticEvent) {
        recordedEvents.append(event)
    }

    func events() -> [AudioDiagnosticEvent] {
        recordedEvents
    }
}

private final class MutableAudioTime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero

    func now() -> Duration {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by duration: Duration) {
        lock.lock()
        defer { lock.unlock() }
        value += duration
    }
}

private enum UplinkTestError: Error, Equatable {
    case rejected
}

private func makeUplinkFrame(
    flowID: AudioFlowID,
    sequence: UInt64,
    timestamp: Duration = .zero,
    duration: Duration = .milliseconds(20),
    format: AudioStreamFormat? = nil
) throws -> AudioFrame {
    let resolvedFormat = try format ?? .monoPCM16(sampleRate: 24_000)
    let components = duration.components
    let seconds = Double(components.seconds)
        + Double(components.attoseconds) / 1e18
    let sampleFrameCount = Int((seconds * resolvedFormat.sampleRate).rounded())
    let payload = Data(
        repeating: UInt8(truncatingIfNeeded: sequence),
        count: sampleFrameCount * resolvedFormat.bytesPerFrame
    )
    return try AudioFrame(
        flowID: flowID,
        sequence: sequence,
        timestamp: timestamp,
        format: resolvedFormat,
        payload: payload,
        duration: try resolvedFormat.duration(forPayloadByteCount: payload.count)
    )
}

private func eventually(
    _ predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<1_000 {
        if await predicate() { return true }
        await Task.yield()
    }
    return false
}
