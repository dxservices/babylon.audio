import Foundation
import Testing
@testable import BabylonAudio

@Suite("Bounded downlink jitter buffer")
struct BoundedDownlinkJitterBufferTests {
    @Test("A receiver burst is reordered during target prebuffering and delivered serially")
    func receiverBurstIsReorderedAndSerialized() async throws {
        let flowID = AudioFlowID()
        let receiver = FixedDownlinkReceiver(frames: [
            try makeDownlinkFrame(flowID: flowID, sequence: 1),
            try makeDownlinkFrame(flowID: flowID, sequence: 0),
        ])
        let sink = ControlledDownlinkSink()
        let buffer = BoundedDownlinkJitterBuffer(
            policy: try BoundedDownlinkJitterBufferPolicy(
                targetBufferedAudioDuration: .milliseconds(40),
                maximumBufferedAudioDuration: .seconds(1),
                maximumFrameAge: .seconds(2)
            )
        )

        await buffer.start(flowID: flowID, receiver: receiver, sink: sink)

        #expect(await eventuallyDownlink { await sink.consumedSequences() == [0] })
        #expect(await buffer.snapshot.pending.frameCount == 1)
        await sink.completeNext()
        #expect(await eventuallyDownlink { await sink.consumedSequences() == [0, 1] })
        await sink.completeNext()
        #expect(await eventuallyDownlink { !(await buffer.snapshot.isDelivering) })
    }

    @Test("The total duration bound includes in-flight audio and drops oldest pending")
    func totalBoundIncludesInFlightAudio() async throws {
        let flowID = AudioFlowID()
        let sink = ControlledDownlinkSink()
        let buffer = BoundedDownlinkJitterBuffer(
            policy: try BoundedDownlinkJitterBufferPolicy(
                targetBufferedAudioDuration: .milliseconds(100),
                maximumBufferedAudioDuration: .milliseconds(200),
                maximumFrameAge: .seconds(2)
            )
        )
        let pcm16 = try AudioStreamFormat.monoPCM16(sampleRate: 16_000)
        let floatStereo = try AudioStreamFormat(
            sampleRate: 48_000,
            channelCount: 2,
            sampleEncoding: .float32,
            interleaving: .interleaved
        )
        await buffer.start(flowID: flowID, sink: sink)

        await buffer.enqueue(try makeDownlinkFrame(
            flowID: flowID,
            sequence: 0,
            duration: .milliseconds(100),
            format: pcm16
        ))
        #expect(await eventuallyDownlink { await sink.consumedSequences() == [0] })
        await buffer.enqueue(try makeDownlinkFrame(
            flowID: flowID,
            sequence: 1,
            duration: .milliseconds(100),
            format: pcm16
        ))
        await buffer.enqueue(try makeDownlinkFrame(
            flowID: flowID,
            sequence: 2,
            duration: .milliseconds(100),
            format: floatStereo
        ))

        let snapshot = await buffer.snapshot
        #expect(snapshot.pending == AudioQueueSnapshot(
            frameCount: 1,
            duration: .milliseconds(100)
        ))
        #expect(snapshot.bufferedAudioDuration == .milliseconds(200))
        #expect(snapshot.droppedOverflowFrameCount == 1)

        await sink.completeNext()
        #expect(await eventuallyDownlink { await sink.consumedSequences() == [0, 2] })
        await sink.completeNext()
    }

    @Test("Maximum age uses local receive time instead of media timestamp")
    func expiresUsingLocalReceiveTime() async throws {
        let time = MutableDownlinkTime()
        let flowID = AudioFlowID()
        let sink = ControlledDownlinkSink()
        let buffer = BoundedDownlinkJitterBuffer(
            policy: try BoundedDownlinkJitterBufferPolicy(
                targetBufferedAudioDuration: .milliseconds(20),
                maximumBufferedAudioDuration: .seconds(1),
                maximumFrameAge: .seconds(1)
            ),
            clock: AudioMonotonicClock(now: { time.now() })
        )
        await buffer.start(flowID: flowID, sink: sink)
        await buffer.enqueue(try makeDownlinkFrame(flowID: flowID, sequence: 0))
        #expect(await eventuallyDownlink { await sink.consumedSequences() == [0] })
        await buffer.enqueue(try makeDownlinkFrame(
            flowID: flowID,
            sequence: 1,
            timestamp: .seconds(700)
        ))

        time.advance(by: .milliseconds(1_001))
        await sink.completeNext()

        #expect(await eventuallyDownlink {
            await buffer.snapshot.droppedExpiredFrameCount == 1
        })
        #expect(await sink.consumedSequences() == [0])
        #expect(await buffer.snapshot.pending == .zero)
    }

    @Test("Starvation requires the target duration again before delivery resumes")
    func rebuffersAfterStarvation() async throws {
        let flowID = AudioFlowID()
        let sink = ControlledDownlinkSink()
        let diagnostics = RecordingDownlinkDiagnostics()
        let buffer = BoundedDownlinkJitterBuffer(
            policy: try BoundedDownlinkJitterBufferPolicy(
                targetBufferedAudioDuration: .milliseconds(40),
                maximumBufferedAudioDuration: .seconds(1),
                maximumFrameAge: .seconds(2)
            ),
            diagnosticSink: diagnostics
        )
        await buffer.start(flowID: flowID, sink: sink)
        await buffer.enqueue(try makeDownlinkFrame(flowID: flowID, sequence: 0))
        await buffer.enqueue(try makeDownlinkFrame(flowID: flowID, sequence: 1))
        #expect(await eventuallyDownlink { await sink.consumedSequences() == [0] })
        await sink.completeNext()
        #expect(await eventuallyDownlink { await sink.consumedSequences() == [0, 1] })
        await sink.completeNext()
        #expect(await eventuallyDownlink { !(await buffer.snapshot.isDelivering) })
        #expect(await buffer.snapshot.rebufferCount == 0)

        await buffer.enqueue(try makeDownlinkFrame(flowID: flowID, sequence: 2))
        #expect(await eventuallyDownlink { await buffer.snapshot.rebufferCount == 1 })
        for _ in 0..<10 { await Task.yield() }
        #expect(await sink.consumedSequences() == [0, 1])
        await buffer.enqueue(try makeDownlinkFrame(flowID: flowID, sequence: 3))
        #expect(await eventuallyDownlink { await sink.consumedSequences() == [0, 1, 2] })
        #expect(await eventuallyDownlink {
            await diagnostics.events().contains(.rebuffered(
                flowID: flowID,
                bufferedDuration: .zero
            ))
        })
        await sink.completeNext()
        #expect(await eventuallyDownlink { await sink.consumedSequences() == [0, 1, 2, 3] })
        await sink.completeNext()
    }

    @Test("Source end after a natural drain does not count as rebuffering")
    func sourceEndAfterNaturalDrainIsNotRebuffering() async throws {
        let flowID = AudioFlowID()
        let sink = ControlledDownlinkSink()
        let buffer = BoundedDownlinkJitterBuffer(
            policy: try BoundedDownlinkJitterBufferPolicy(
                targetBufferedAudioDuration: .milliseconds(20),
                maximumBufferedAudioDuration: .seconds(1),
                maximumFrameAge: .seconds(2)
            )
        )
        await buffer.start(flowID: flowID, sink: sink)
        await buffer.enqueue(try makeDownlinkFrame(flowID: flowID, sequence: 0))
        #expect(await eventuallyDownlink { await sink.consumedSequences() == [0] })

        await sink.completeNext()
        #expect(await eventuallyDownlink { !(await buffer.snapshot.isDelivering) })
        #expect(await buffer.finishSource(flowID: flowID))

        #expect(await buffer.snapshot.rebufferCount == 0)
        #expect(!(await buffer.snapshot.isRunning))
    }

    @Test("Stop clears pending work and late sink completion cannot resume delivery")
    func stopIsolatesLateCompletion() async throws {
        let flowID = AudioFlowID()
        let sink = ControlledDownlinkSink()
        let buffer = BoundedDownlinkJitterBuffer(
            policy: try BoundedDownlinkJitterBufferPolicy(
                targetBufferedAudioDuration: .milliseconds(20),
                maximumBufferedAudioDuration: .seconds(1),
                maximumFrameAge: .seconds(2)
            )
        )
        await buffer.start(flowID: flowID, sink: sink)
        await buffer.enqueue(try makeDownlinkFrame(flowID: flowID, sequence: 0))
        await buffer.enqueue(try makeDownlinkFrame(flowID: flowID, sequence: 1))
        #expect(await eventuallyDownlink { await sink.consumedSequences() == [0] })

        await buffer.stop()
        await sink.completeNext()
        for _ in 0..<10 { await Task.yield() }

        #expect(await sink.consumedSequences() == [0])
        #expect(!(await buffer.snapshot.isRunning))
        #expect(await buffer.snapshot.pending == .zero)
        #expect(await buffer.snapshot.discardedFrameCount == 1)
    }

    @Test("Frames enqueued while stopped count as discarded")
    func stoppedEnqueueCountsAsDiscarded() async throws {
        let buffer = BoundedDownlinkJitterBuffer(
            policy: try BoundedDownlinkJitterBufferPolicy(
                targetBufferedAudioDuration: .milliseconds(20),
                maximumBufferedAudioDuration: .seconds(1),
                maximumFrameAge: .seconds(2)
            )
        )

        await buffer.enqueue(try makeDownlinkFrame(
            flowID: AudioFlowID(),
            sequence: 0
        ))

        #expect(await buffer.snapshot.discardedFrameCount == 1)
    }

    @Test("Duplicate and already-delivered sequences are discarded")
    func discardsDuplicateAndLateSequences() async throws {
        let flowID = AudioFlowID()
        let sink = ControlledDownlinkSink()
        let buffer = BoundedDownlinkJitterBuffer(
            policy: try BoundedDownlinkJitterBufferPolicy(
                targetBufferedAudioDuration: .milliseconds(20),
                maximumBufferedAudioDuration: .seconds(1),
                maximumFrameAge: .seconds(2)
            )
        )
        await buffer.start(flowID: flowID, sink: sink)
        await buffer.enqueue(try makeDownlinkFrame(flowID: flowID, sequence: 1))
        #expect(await eventuallyDownlink { await sink.consumedSequences() == [1] })
        await buffer.enqueue(try makeDownlinkFrame(flowID: flowID, sequence: 1))
        await buffer.enqueue(try makeDownlinkFrame(flowID: flowID, sequence: 0))

        #expect(await buffer.snapshot.droppedOutOfOrderFrameCount == 2)
        await sink.completeNext()
    }

    @Test("Policy rejects a target larger than the total duration bound")
    func rejectsInvalidPolicy() {
        #expect(throws: AudioStreamingError.invalidPolicy) {
            try BoundedDownlinkJitterBufferPolicy(
                targetBufferedAudioDuration: .seconds(2),
                maximumBufferedAudioDuration: .seconds(1),
                maximumFrameAge: .seconds(1)
            )
        }
    }

    @Test("A sustained tiny-frame burst bounds pending plus in-flight duration")
    func burstRemainsBounded() async throws {
        let flowID = AudioFlowID()
        let sink = ControlledDownlinkSink()
        let buffer = BoundedDownlinkJitterBuffer(
            policy: try BoundedDownlinkJitterBufferPolicy(
                targetBufferedAudioDuration: .milliseconds(100),
                maximumBufferedAudioDuration: .milliseconds(100),
                maximumFrameAge: .seconds(10)
            )
        )
        let format = try AudioStreamFormat(
            sampleRate: 48_000,
            channelCount: 2,
            sampleEncoding: .float32,
            interleaving: .interleaved
        )
        await buffer.start(flowID: flowID, sink: sink)

        for sequence in 0..<1_000 {
            await buffer.enqueue(try makeDownlinkFrame(
                flowID: flowID,
                sequence: UInt64(sequence),
                duration: .milliseconds(1),
                format: format
            ))
        }

        #expect(await eventuallyDownlink { await sink.consumedSequences() == [0] })
        let snapshot = await buffer.snapshot
        #expect(snapshot.pending.frameCount == 99)
        #expect(snapshot.pending.duration == .milliseconds(99))
        #expect(snapshot.bufferedAudioDuration == .milliseconds(100))
        #expect(snapshot.maximumBufferedAudioDuration == .milliseconds(100))
        #expect(snapshot.droppedOverflowFrameCount == 900)

        await buffer.stop()
        await sink.completeNext()
    }

    @Test("Flow replacement isolates an old sink completion")
    func replacementIsolatesLateCompletion() async throws {
        let oldFlow = AudioFlowID()
        let newFlow = AudioFlowID()
        let oldSink = ControlledDownlinkSink()
        let newSink = ControlledDownlinkSink()
        let buffer = BoundedDownlinkJitterBuffer(
            policy: try BoundedDownlinkJitterBufferPolicy(
                targetBufferedAudioDuration: .milliseconds(20),
                maximumBufferedAudioDuration: .seconds(1),
                maximumFrameAge: .seconds(2)
            )
        )
        await buffer.start(flowID: oldFlow, sink: oldSink)
        await buffer.enqueue(try makeDownlinkFrame(flowID: oldFlow, sequence: 0))
        #expect(await eventuallyDownlink { await oldSink.consumedSequences() == [0] })

        await buffer.start(flowID: newFlow, sink: newSink)
        await buffer.enqueue(try makeDownlinkFrame(flowID: newFlow, sequence: 0))
        #expect(await eventuallyDownlink { await newSink.consumedSequences() == [0] })
        await oldSink.completeNext()
        for _ in 0..<10 { await Task.yield() }

        #expect(await buffer.snapshot.flowID == newFlow)
        #expect(await buffer.snapshot.isRunning)
        #expect(await buffer.snapshot.isDelivering)
        await newSink.completeNext()
    }

    @Test("A sink failure stops once and discards pending frames")
    func sinkFailureStopsAndReportsOnce() async throws {
        let flowID = AudioFlowID()
        let sink = ControlledDownlinkSink()
        let failures = DownlinkFailureRecorder()
        let buffer = BoundedDownlinkJitterBuffer(
            policy: try BoundedDownlinkJitterBufferPolicy(
                targetBufferedAudioDuration: .milliseconds(20),
                maximumBufferedAudioDuration: .seconds(1),
                maximumFrameAge: .seconds(2)
            )
        )
        await buffer.start(flowID: flowID, sink: sink) { error in
            await failures.record(error)
        }
        await buffer.enqueue(try makeDownlinkFrame(flowID: flowID, sequence: 0))
        await buffer.enqueue(try makeDownlinkFrame(flowID: flowID, sequence: 1))
        #expect(await eventuallyDownlink { await sink.consumedSequences() == [0] })

        await sink.completeNext(throwing: DownlinkTestError.rejected)

        #expect(await eventuallyDownlink { await failures.errors() == [.rejected] })
        #expect(!(await buffer.snapshot.isRunning))
        #expect(await buffer.snapshot.pending == .zero)
        #expect(await buffer.snapshot.discardedFrameCount == 1)
    }
}

private struct FixedDownlinkReceiver: AudioFrameReceiver {
    let storedFrames: [AudioFrame]

    init(frames: [AudioFrame]) {
        storedFrames = frames
    }

    func frames(
        for flowID: AudioFlowID
    ) -> AsyncThrowingStream<AudioFrame, any Error> {
        AsyncThrowingStream { continuation in
            for frame in storedFrames where frame.flowID == flowID {
                continuation.yield(frame)
            }
            continuation.finish()
        }
    }
}

private actor ControlledDownlinkSink: AudioFrameSink {
    private var frames: [AudioFrame] = []
    private var continuations: [CheckedContinuation<Void, any Error>] = []

    func consume(_ frame: AudioFrame) async throws {
        frames.append(frame)
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func consumedSequences() -> [UInt64] {
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

private actor RecordingDownlinkDiagnostics: AudioDiagnosticSink {
    private var recordedEvents: [AudioDiagnosticEvent] = []

    func record(_ event: AudioDiagnosticEvent) {
        recordedEvents.append(event)
    }

    func events() -> [AudioDiagnosticEvent] {
        recordedEvents
    }
}

private actor DownlinkFailureRecorder {
    private var recordedErrors: [any Error] = []

    func record(_ error: any Error) {
        recordedErrors.append(error)
    }

    func errors() -> [DownlinkTestError] {
        recordedErrors.compactMap { $0 as? DownlinkTestError }
    }
}

private final class MutableDownlinkTime: @unchecked Sendable {
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

private enum DownlinkTestError: Error, Equatable {
    case rejected
}

private func makeDownlinkFrame(
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

private func eventuallyDownlink(
    _ predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<1_000 {
        if await predicate() { return true }
        await Task.yield()
    }
    return false
}
