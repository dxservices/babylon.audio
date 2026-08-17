import Foundation
import Testing
@testable import BabylonAudio

@Suite("Audio pipeline session")
struct AudioPipelineSessionTests {
    @Test("External frames share one flow across local monitor and bounded uplink")
    func externalFramesFanOutAcrossSourcePlans() async throws {
        let flowID = AudioFlowID()
        let frame = try makeSessionFrame(flowID: flowID, sequence: 0)
        let localSink = SessionRecordingSink()
        let sender = SessionRecordingSender()
        let events = SessionRecordingEventSink()
        let configuration = try AudioPipelineConfiguration(
            source: .externalFrames,
            localMonitorSink: .external(localSink),
            uplinkSender: sender,
            eventSink: events
        )
        let session = AudioPipelineSession(
            configuration: configuration,
            uplinkPolicy: try BoundedUplinkQueuePolicy(
                maximumPendingAudioDuration: .seconds(1),
                maximumFrameAge: .seconds(2)
            )
        )

        try await session.start(flowID: flowID)
        try await session.submit(frame)

        #expect(await eventuallySession {
            await localSink.values() == [frame]
                && sender.values() == [frame]
        })
        let snapshot = await session.snapshot
        #expect(snapshot.flowID == flowID)
        #expect(snapshot.state == .running)
        #expect(snapshot.sourceFormat == frame.format)

        await session.stop()
        #expect(await events.values() == [
            .flowStarted(flowID: flowID),
            .flowStopped(flowID: flowID, reason: .consumerRequested),
        ])
    }

    @Test("Concurrent submissions reach monitor and sender in source order")
    func concurrentSubmissionsRemainSerial() async throws {
        let flowID = AudioFlowID()
        let firstFrame = try makeSessionFrame(flowID: flowID, sequence: 0)
        let secondFrame = try makeSessionFrame(flowID: flowID, sequence: 1)
        let monitor = SessionControlledSink()
        let sender = SessionRecordingSender()
        let configuration = try AudioPipelineConfiguration(
            source: .externalFrames,
            localMonitorSink: .external(monitor),
            uplinkSender: sender
        )
        let session = AudioPipelineSession(configuration: configuration)
        try await session.start(flowID: flowID)

        let firstSubmit = Task { try await session.submit(firstFrame) }
        #expect(await eventuallySession {
            await monitor.values() == [firstFrame]
                && sender.values() == [firstFrame]
        })
        let secondSubmit = Task { try await session.submit(secondFrame) }
        for _ in 0..<20 { await Task.yield() }
        #expect(await monitor.values() == [firstFrame])
        #expect(sender.values() == [firstFrame])

        await monitor.complete()
        #expect(await eventuallySession {
            await monitor.values() == [firstFrame, secondFrame]
                && sender.values() == [firstFrame, secondFrame]
        })
        await monitor.complete()
        try await firstSubmit.value
        try await secondSubmit.value
        await session.stop()
    }

    @Test("A cancelled submission waiting for serialization never reaches an endpoint")
    func cancelledQueuedSubmissionIsNotDelivered() async throws {
        let flowID = AudioFlowID()
        let firstFrame = try makeSessionFrame(flowID: flowID, sequence: 0)
        let cancelledFrame = try makeSessionFrame(flowID: flowID, sequence: 1)
        let monitor = SessionControlledSink()
        let sender = SessionRecordingSender()
        let configuration = try AudioPipelineConfiguration(
            source: .externalFrames,
            localMonitorSink: .external(monitor),
            uplinkSender: sender
        )
        let session = AudioPipelineSession(configuration: configuration)
        try await session.start(flowID: flowID)

        let firstSubmit = Task { try await session.submit(firstFrame) }
        #expect(await eventuallySession {
            await monitor.values() == [firstFrame]
        })
        let cancelledSubmit = Task {
            try await session.submit(cancelledFrame)
        }
        cancelledSubmit.cancel()
        await monitor.complete()
        try await firstSubmit.value

        await #expect(throws: CancellationError.self) {
            try await cancelledSubmit.value
        }
        #expect(await monitor.values() == [firstFrame])
        #expect(sender.values() == [firstFrame])
        await session.stop()
    }

    @Test("An uplink sender failure stops the shared flow")
    func uplinkFailureStopsSharedFlow() async throws {
        let flowID = AudioFlowID()
        let events = SessionRecordingEventSink()
        let configuration = try AudioPipelineConfiguration(
            source: .externalFrames,
            uplinkSender: SessionFailingSender(),
            eventSink: events
        )
        let session = AudioPipelineSession(configuration: configuration)
        try await session.start(flowID: flowID)

        try await session.submit(try makeSessionFrame(
            flowID: flowID,
            sequence: 0
        ))

        #expect(await eventuallySession {
            await events.values() == [
                .flowStarted(flowID: flowID),
                .endpointFailed(flowID: flowID, direction: .uplink),
                .flowStopped(flowID: flowID, reason: .endpointFailure),
            ]
        })
        #expect(await session.snapshot.state == .stopped)
    }

    @Test("Caller stop cannot rewrite an uplink failure after terminal ownership")
    func concurrentStopDoesNotRewriteUplinkFailure() async throws {
        let flowID = AudioFlowID()
        let events = SessionSuspendingEventSink(suspendingAt: 2)
        let configuration = try AudioPipelineConfiguration(
            source: .externalFrames,
            uplinkSender: SessionFailingSender(),
            eventSink: events
        )
        let session = AudioPipelineSession(configuration: configuration)
        try await session.start(flowID: flowID)
        try await session.submit(try makeSessionFrame(
            flowID: flowID,
            sequence: 0
        ))
        #expect(await eventuallySession {
            events.values() == [
                .flowStarted(flowID: flowID),
                .endpointFailed(flowID: flowID, direction: .uplink),
            ] && events.isSuspended()
        })

        await session.stop()
        #expect(events.values() == [
            .flowStarted(flowID: flowID),
            .endpointFailed(flowID: flowID, direction: .uplink),
        ])
        events.resumeSuspendedDelivery()
        #expect(await eventuallySession {
            events.values() == [
                .flowStarted(flowID: flowID),
                .endpointFailed(flowID: flowID, direction: .uplink),
                .flowStopped(flowID: flowID, reason: .endpointFailure),
            ]
        })
    }

    @Test("A local-monitor failure stops the shared flow and reaches the caller")
    func localMonitorFailureStopsSharedFlow() async throws {
        let flowID = AudioFlowID()
        let events = SessionRecordingEventSink()
        let configuration = try AudioPipelineConfiguration(
            source: .externalFrames,
            localMonitorSink: .external(SessionFailingSink()),
            eventSink: events
        )
        let session = AudioPipelineSession(configuration: configuration)
        try await session.start(flowID: flowID)
        let frame = try makeSessionFrame(flowID: flowID, sequence: 0)

        await #expect(throws: SessionSinkError.failed) {
            try await session.submit(frame)
        }

        #expect(await events.values() == [
            .flowStarted(flowID: flowID),
            .endpointFailed(flowID: flowID, direction: .localMonitor),
            .flowStopped(flowID: flowID, reason: .endpointFailure),
        ])
        #expect(await session.snapshot.state == .stopped)
    }

    @Test("External submission rejects a frame from another flow")
    func externalSubmissionRejectsAnotherFlow() async throws {
        let flowID = AudioFlowID()
        let sender = SessionRecordingSender()
        let configuration = try AudioPipelineConfiguration(
            source: .externalFrames,
            uplinkSender: sender
        )
        let session = AudioPipelineSession(configuration: configuration)
        try await session.start(flowID: flowID)

        await #expect(throws: AudioPipelineSessionError.frameFlowMismatch) {
            try await session.submit(try makeSessionFrame(
                flowID: AudioFlowID(),
                sequence: 0
            ))
        }

        #expect(sender.values().isEmpty)
        #expect(await session.snapshot.state == .running)
        await session.stop()
    }

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
            downlinkReceiver: SessionOpenReceiver(frames: frames),
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
        let events = SessionSuspendingEventSink(suspendingAt: 1)
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
                && events.isSuspended()
        })

        let stopTask = Task { await session.stop() }
        for _ in 0..<20 { await Task.yield() }
        #expect(events.values() == [.flowStarted(flowID: flowID)])

        events.resumeSuspendedDelivery()
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

private struct SessionOpenReceiver: AudioFrameReceiver {
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

private final class SessionRecordingSender: AudioFrameSender, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [AudioFrame] = []

    func send(_ frame: AudioFrame) async throws {
        lock.withLock {
            frames.append(frame)
        }
    }

    func values() -> [AudioFrame] {
        lock.withLock { frames }
    }
}

private struct SessionFailingSender: AudioFrameSender {
    func send(_ frame: AudioFrame) async throws {
        throw SessionSenderError.failed
    }
}

private enum SessionSenderError: Error {
    case failed
}

private struct SessionFailingSink: AudioFrameSink {
    func consume(_ frame: AudioFrame) async throws {
        throw SessionSinkError.failed
    }
}

private enum SessionSinkError: Error, Equatable {
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
    private let suspendingAt: Int
    private var events: [AudioEvent] = []
    private var suspendedDelivery: CheckedContinuation<Void, Never>?

    init(suspendingAt: Int) {
        self.suspendingAt = suspendingAt
    }

    func receive(_ event: AudioEvent) async {
        let shouldSuspend: Bool = lock.withLock {
            events.append(event)
            return events.count == suspendingAt
        }
        if shouldSuspend {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    suspendedDelivery = continuation
                }
            }
        }
    }

    func values() -> [AudioEvent] {
        lock.withLock { events }
    }

    func isSuspended() -> Bool {
        lock.withLock { suspendedDelivery != nil }
    }

    func resumeSuspendedDelivery() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            let continuation = suspendedDelivery
            suspendedDelivery = nil
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
