import Foundation
import Testing
@testable import BabylonAudio

@Suite("Audio pipeline session")
struct AudioPipelineSessionTests {
    @Test("A short completed downlink flushes its tail without recording rebuffering")
    func shortCompletedDownlinkFlushesTail() async throws {
        let flowID = AudioFlowID()
        let frame = try makeSessionFrame(flowID: flowID, sequence: 0)
        let receiver = SessionFixedReceiver(frames: [frame])
        let sink = SessionRecordingSink()
        let events = SessionRecordingEventSink()
        let configuration = try AudioPipelineConfiguration(
            downlinkReceiver: receiver,
            downlinkSink: .external(sink),
            eventSink: events
        )
        let session = AudioPipelineSession(
            configuration: configuration,
            downlinkPolicy: try BoundedDownlinkJitterBufferPolicy(
                targetBufferedAudioDuration: .milliseconds(200),
                maximumBufferedAudioDuration: .seconds(1),
                maximumFrameAge: .seconds(2)
            )
        )

        try await session.start(flowID: flowID)

        #expect(await eventuallySession {
            await events.values() == [
                .flowStarted(flowID: flowID),
                .sourceEnded(flowID: flowID),
                .flowStopped(flowID: flowID, reason: .sourceEnded),
            ]
        })
        #expect(await sink.values() == [frame])
        #expect(await session.snapshot.state == .stopped)
        #expect(await session.downlinkSnapshot.rebufferCount == 0)
    }

    @Test("A receiver failure stops only after reporting the downlink endpoint")
    func receiverFailureReportsAndStops() async throws {
        let flowID = AudioFlowID()
        let events = SessionRecordingEventSink()
        let configuration = try AudioPipelineConfiguration(
            downlinkReceiver: SessionFailingReceiver(),
            downlinkSink: .external(SessionRecordingSink()),
            eventSink: events
        )
        let session = AudioPipelineSession(configuration: configuration)

        try await session.start(flowID: flowID)

        #expect(await eventuallySession {
            await events.values() == [
                .flowStarted(flowID: flowID),
                .endpointFailed(flowID: flowID, direction: .downlink),
                .flowStopped(flowID: flowID, reason: .endpointFailure),
            ]
        })
        #expect(await session.snapshot.state == .stopped)
    }

    @Test("A sink failure reports the downlink endpoint and stops the flow")
    func sinkFailureReportsAndStops() async throws {
        let flowID = AudioFlowID()
        let frames = try (0..<20).map {
            try makeSessionFrame(flowID: flowID, sequence: UInt64($0))
        }
        let events = SessionRecordingEventSink()
        let configuration = try AudioPipelineConfiguration(
            downlinkReceiver: SessionFixedReceiver(frames: frames),
            downlinkSink: .external(SessionFailingSink()),
            eventSink: events
        )
        let session = AudioPipelineSession(
            configuration: configuration,
            downlinkPolicy: try BoundedDownlinkJitterBufferPolicy(
                targetBufferedAudioDuration: .milliseconds(20),
                maximumBufferedAudioDuration: .seconds(1),
                maximumFrameAge: .seconds(2)
            )
        )

        try await session.start(flowID: flowID)

        #expect(await eventuallySession {
            await events.values() == [
                .flowStarted(flowID: flowID),
                .endpointFailed(flowID: flowID, direction: .downlink),
                .flowStopped(flowID: flowID, reason: .endpointFailure),
            ]
        })
        #expect(await session.snapshot.state == .stopped)
        #expect(!(await session.downlinkSnapshot.isRunning))
    }

    @Test("Consumer stop interrupts an in-flight tail drain without a late stop event")
    func consumerStopInterruptsTailDrain() async throws {
        let flowID = AudioFlowID()
        let frame = try makeSessionFrame(flowID: flowID, sequence: 0)
        let sink = SessionControlledSink()
        let events = SessionRecordingEventSink()
        let configuration = try AudioPipelineConfiguration(
            downlinkReceiver: SessionFixedReceiver(frames: [frame]),
            downlinkSink: .external(sink),
            eventSink: events
        )
        let session = AudioPipelineSession(
            configuration: configuration,
            downlinkPolicy: try BoundedDownlinkJitterBufferPolicy(
                targetBufferedAudioDuration: .milliseconds(200),
                maximumBufferedAudioDuration: .seconds(1),
                maximumFrameAge: .seconds(2)
            )
        )
        try await session.start(flowID: flowID)
        #expect(await eventuallySession {
            let receivedFrames = await sink.values()
            let receivedEvents = await events.values()
            return receivedFrames == [frame]
                && receivedEvents == [
                    .flowStarted(flowID: flowID),
                    .sourceEnded(flowID: flowID),
                ]
        })

        await session.stop()
        await sink.complete()
        for _ in 0..<10 { await Task.yield() }

        #expect(await events.values() == [
            .flowStarted(flowID: flowID),
            .sourceEnded(flowID: flowID),
            .flowStopped(flowID: flowID, reason: .consumerRequested),
        ])
        #expect(await session.snapshot.state == .stopped)
    }

    @Test("Event delivery remains serial when stop overlaps a suspended event sink")
    func eventDeliveryIsSerialized() async throws {
        let flowID = AudioFlowID()
        let events = SessionSuspendingEventSink()
        let configuration = try AudioPipelineConfiguration(
            downlinkReceiver: SessionFixedReceiver(frames: []),
            downlinkSink: .external(SessionRecordingSink()),
            eventSink: events
        )
        let session = AudioPipelineSession(configuration: configuration)
        let startTask = Task {
            try await session.start(flowID: flowID)
        }
        #expect(await eventuallySession {
            events.values() == [.flowStarted(flowID: flowID)]
        })

        let stopTask = Task { await session.stop() }
        for _ in 0..<20 { await Task.yield() }
        #expect(events.values() == [.flowStarted(flowID: flowID)])

        events.resumeFirstDelivery()
        try await startTask.value
        await stopTask.value
        #expect(events.values() == [
            .flowStarted(flowID: flowID),
            .flowStopped(flowID: flowID, reason: .consumerRequested),
        ])
    }

    @Test("A session rejects reuse of a completed flow identifier")
    func completedFlowIdentifierCannotBeReused() async throws {
        let flowID = AudioFlowID()
        let events = SessionRecordingEventSink()
        let configuration = try AudioPipelineConfiguration(
            downlinkReceiver: SessionFixedReceiver(frames: []),
            downlinkSink: .external(SessionRecordingSink()),
            eventSink: events
        )
        let session = AudioPipelineSession(configuration: configuration)
        try await session.start(flowID: flowID)
        #expect(await eventuallySession {
            await session.snapshot.state == .stopped
        })

        await #expect(throws: AudioPipelineSessionError.reusedFlowID) {
            try await session.start(flowID: flowID)
        }
    }
}

private struct SessionFixedReceiver: AudioFrameReceiver {
    let framesToYield: [AudioFrame]

    init(frames: [AudioFrame]) {
        framesToYield = frames
    }

    func frames(
        for flowID: AudioFlowID
    ) -> AsyncThrowingStream<AudioFrame, any Error> {
        AsyncThrowingStream { continuation in
            for frame in framesToYield where frame.flowID == flowID {
                continuation.yield(frame)
            }
            continuation.finish()
        }
    }
}

private struct SessionFailingReceiver: AudioFrameReceiver {
    func frames(
        for flowID: AudioFlowID
    ) -> AsyncThrowingStream<AudioFrame, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: SessionReceiverError.failed)
        }
    }
}

private enum SessionReceiverError: Error {
    case failed
}

private actor SessionRecordingSink: AudioFrameSink {
    private var frames: [AudioFrame] = []

    func consume(_ frame: AudioFrame) async throws {
        frames.append(frame)
    }

    func values() -> [AudioFrame] {
        frames
    }
}

private struct SessionFailingSink: AudioFrameSink {
    func consume(_ frame: AudioFrame) async throws {
        throw SessionSinkError.failed
    }
}

private enum SessionSinkError: Error {
    case failed
}

private actor SessionControlledSink: AudioFrameSink {
    private var frames: [AudioFrame] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func consume(_ frame: AudioFrame) async throws {
        frames.append(frame)
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func values() -> [AudioFrame] {
        frames
    }

    func complete() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

private actor SessionRecordingEventSink: AudioEventSink {
    private var events: [AudioEvent] = []

    func receive(_ event: AudioEvent) async {
        events.append(event)
    }

    func values() -> [AudioEvent] {
        events
    }
}

private final class SessionSuspendingEventSink: AudioEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AudioEvent] = []
    private var firstDelivery: CheckedContinuation<Void, Never>?

    func receive(_ event: AudioEvent) async {
        let shouldSuspend: Bool = lock.withLock {
            events.append(event)
            return events.count == 1
        }
        if shouldSuspend {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    firstDelivery = continuation
                }
            }
        }
    }

    func values() -> [AudioEvent] {
        lock.withLock { events }
    }

    func resumeFirstDelivery() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            let continuation = firstDelivery
            firstDelivery = nil
            return continuation
        }
        continuation?.resume()
    }
}

private func makeSessionFrame(
    flowID: AudioFlowID,
    sequence: UInt64
) throws -> AudioFrame {
    let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
    return try AudioFrame(
        flowID: flowID,
        sequence: sequence,
        timestamp: .milliseconds(Int64(sequence) * 20),
        format: format,
        payload: Data(repeating: UInt8(truncatingIfNeeded: sequence), count: 960),
        duration: .milliseconds(20)
    )
}

private func eventuallySession(
    _ predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<1_000 {
        if await predicate() { return true }
        await Task.yield()
    }
    return false
}
