import Foundation
import Testing
@testable import BabylonAudio

@Suite("Audio pipeline session")
struct AudioPipelineSessionTests {
    @Test("Local monitor, uplink, and downlink share one session flow")
    func allThreePlansShareOneFlow() async throws {
        let flowID = AudioFlowID()
        let sourceFrame = try makeSessionFrame(flowID: flowID, sequence: 0)
        let downlinkFrame = try makeSessionFrame(flowID: flowID, sequence: 1)
        let monitor = SessionRecordingSink()
        let sender = SessionRecordingSender()
        let receiver = SessionControlledReceiver()
        let downlinkSink = SessionRecordingSink()
        let events = SessionRecordingEventSink()
        let configuration = try AudioPipelineConfiguration(
            source: .externalFrames,
            localMonitorSink: .external(monitor),
            uplinkSender: sender,
            downlinkReceiver: receiver,
            downlinkSink: .external(downlinkSink),
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
        #expect(await eventuallySession { receiver.isReady() })
        try await session.submit(sourceFrame)
        #expect(await eventuallySession {
            await monitor.values() == [sourceFrame]
                && sender.values() == [sourceFrame]
        })

        receiver.yield(downlinkFrame)
        receiver.finish()

        #expect(await eventuallySession {
            let receivedFrames = await downlinkSink.values()
            let receivedEvents = await events.values()
            return receivedFrames == [downlinkFrame]
                && receivedEvents == [
                    .flowStarted(flowID: flowID),
                    .endpointEnded(flowID: flowID, direction: .downlink),
                    .flowStopped(flowID: flowID, reason: .sourceEnded),
                ]
        })
        #expect(await session.snapshot.state == .stopped)
        #expect(!(await session.uplinkSnapshot.isRunning))
        await #expect(throws: AudioPipelineSessionError.notRunning) {
            try await session.submit(sourceFrame)
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(await events.values().count == 3)
    }

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

    @Test("An external source drives monitor and uplink through source end")
    func externalSourceDrivesSourcePlans() async throws {
        let flowID = AudioFlowID()
        let frames = try (0..<2).map {
            try makeSessionFrame(flowID: flowID, sequence: UInt64($0))
        }
        let monitor = SessionRecordingSink()
        let sender = SessionRecordingSender()
        let events = SessionRecordingEventSink()
        let configuration = try AudioPipelineConfiguration(
            source: .external(SessionFixedSource(frames: frames)),
            localMonitorSink: .external(monitor),
            uplinkSender: sender,
            eventSink: events
        )
        let session = AudioPipelineSession(configuration: configuration)

        try await session.start(flowID: flowID)

        #expect(await eventuallySession {
            let monitoredFrames = await monitor.values()
            let receivedEvents = await events.values()
            return monitoredFrames == frames
                && sender.values() == frames
                && receivedEvents == [
                    .flowStarted(flowID: flowID),
                    .endpointEnded(flowID: flowID, direction: .source),
                    .flowStopped(flowID: flowID, reason: .sourceEnded),
                ]
        })
        let snapshot = await session.snapshot
        #expect(snapshot.state == .stopped)
        #expect(snapshot.sourceFormat == frames.last?.format)
        #expect(!(await session.uplinkSnapshot.isRunning))
    }

    @Test("An external source failure reports the source endpoint")
    func externalSourceFailureStopsSharedFlow() async throws {
        let flowID = AudioFlowID()
        let events = SessionRecordingEventSink()
        let configuration = try AudioPipelineConfiguration(
            source: .external(SessionFailingSource()),
            uplinkSender: SessionRecordingSender(),
            eventSink: events
        )
        let session = AudioPipelineSession(configuration: configuration)

        try await session.start(flowID: flowID)

        #expect(await eventuallySession {
            await events.values() == [
                .flowStarted(flowID: flowID),
                .endpointFailed(flowID: flowID, direction: .source),
                .flowStopped(flowID: flowID, reason: .endpointFailure),
            ]
        })
        #expect(await session.snapshot.state == .stopped)
    }

    @Test("Microphone capture drives the requested normalized format into uplink")
    @MainActor
    func microphoneCaptureDrivesNormalizedUplink() async throws {
        let firstFlowID = AudioFlowID()
        let replacementFlowID = AudioFlowID()
        let settings = try makeSessionCaptureSettings()
        let firstFrame = try makeSessionFrame(flowID: firstFlowID, sequence: 0)
        let replacementFrame = try makeSessionFrame(
            flowID: replacementFlowID,
            sequence: 0
        )
        let backend = SessionDeviceEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)
        let sender = SessionRecordingSender()
        let events = SessionRecordingEventSink()
        let configuration = try AudioPipelineConfiguration(
            source: .microphone(AudioMicrophoneSourceConfiguration(
                inputPolicy: .builtInMicrophoneRequired,
                capture: settings
            )),
            uplinkSender: sender,
            eventSink: events
        )
        let session = AudioPipelineSession(
            configuration: configuration,
            deviceEngine: engine
        )
        try engine.start()

        try await session.start(flowID: firstFlowID)
        #expect(backend.captureConfigurations == [
            AudioCaptureConfiguration(flowID: firstFlowID, settings: settings),
        ])
        try await backend.deliverCapture(firstFrame, at: 0)
        #expect(await eventuallySession {
            sender.values() == [firstFrame]
        })
        #expect(await session.snapshot.sourceFormat == settings.format)

        await session.stop()
        try await session.start(flowID: replacementFlowID)
        #expect(engine.isCapturing)
        try await backend.deliverCapture(firstFrame, at: 0)
        await backend.failCapture(at: 0, error: SessionCaptureError.failed)
        #expect(engine.isCapturing)
        try await backend.deliverCapture(replacementFrame, at: 1)
        #expect(await eventuallySession {
            sender.values() == [firstFrame, replacementFrame]
        })
        #expect(engine.isCapturing)

        await session.stop()
        #expect(!engine.isCapturing)
        #expect(backend.captureConfigurations == [
            AudioCaptureConfiguration(flowID: firstFlowID, settings: settings),
            AudioCaptureConfiguration(flowID: replacementFlowID, settings: settings),
        ])
        #expect(backend.stopCaptureCount == 2)
        #expect(await events.values() == [
            .flowStarted(flowID: firstFlowID),
            .flowStopped(flowID: firstFlowID, reason: .consumerRequested),
            .flowStarted(flowID: replacementFlowID),
            .flowStopped(flowID: replacementFlowID, reason: .consumerRequested),
        ])
    }

    @Test("Microphone start requires an injected running device engine")
    @MainActor
    func microphoneStartRequiresRunningDeviceEngine() async throws {
        let settings = try makeSessionCaptureSettings()
        let configuration = try AudioPipelineConfiguration(
            source: .microphone(AudioMicrophoneSourceConfiguration(
                inputPolicy: .builtInMicrophoneRequired,
                capture: settings
            )),
            uplinkSender: SessionRecordingSender()
        )
        let missingRuntimeSession = AudioPipelineSession(
            configuration: configuration
        )
        await #expect(throws: AudioPipelineSessionError.deviceRuntimeRequired) {
            try await missingRuntimeSession.start()
        }

        let engine = AudioDeviceEngine(backend: SessionDeviceEngineBackend())
        let stoppedEngineSession = AudioPipelineSession(
            configuration: configuration,
            deviceEngine: engine
        )
        await #expect(throws: AudioDeviceEngineError.engineNotRunning) {
            try await stoppedEngineSession.start()
        }
        #expect(await stoppedEngineSession.snapshot.state == .stopped)
    }

    @Test("Microphone capture failure reports the source endpoint")
    @MainActor
    func microphoneCaptureFailureStopsSharedFlow() async throws {
        let flowID = AudioFlowID()
        let backend = SessionDeviceEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)
        let events = SessionRecordingEventSink()
        let configuration = try AudioPipelineConfiguration(
            source: .microphone(AudioMicrophoneSourceConfiguration(
                inputPolicy: .builtInMicrophoneRequired,
                capture: makeSessionCaptureSettings()
            )),
            uplinkSender: SessionRecordingSender(),
            eventSink: events
        )
        let session = AudioPipelineSession(
            configuration: configuration,
            deviceEngine: engine
        )
        try engine.start()
        try await session.start(flowID: flowID)

        await backend.failCapture(at: 0, error: SessionCaptureError.failed)

        #expect(await eventuallySession {
            await events.values() == [
                .flowStarted(flowID: flowID),
                .endpointFailed(flowID: flowID, direction: .source),
                .flowStopped(flowID: flowID, reason: .endpointFailure),
            ]
        })
        #expect(!engine.isCapturing)
        #expect(!(await session.uplinkSnapshot.isRunning))
    }

    @Test("Stop waits for an overlapping microphone capture acquisition")
    func stopWaitsForOverlappingMicrophoneStart() async throws {
        let firstFlowID = AudioFlowID()
        let replacementFlowID = AudioFlowID()
        let settings = try makeSessionCaptureSettings()
        let configuration = try AudioPipelineConfiguration(
            source: .microphone(AudioMicrophoneSourceConfiguration(
                inputPolicy: .builtInMicrophoneRequired,
                capture: settings
            )),
            uplinkSender: SessionRecordingSender()
        )
        let (backend, engine) = try await MainActor.run {
            let backend = SessionBlockingStartDeviceEngineBackend()
            let engine = AudioDeviceEngine(backend: backend)
            try engine.start()
            return (backend, engine)
        }
        let session = AudioPipelineSession(
            configuration: configuration,
            deviceEngine: engine
        )
        let firstStart = Task {
            try await session.start(flowID: firstFlowID)
        }
        #expect(await backend.waitUntilFirstStartIsBlocked())

        let stopping = Task { await session.stop() }
        #expect(await eventuallySession {
            await session.snapshot.state == .stopped
        })
        await #expect(throws: AudioPipelineSessionError.alreadyRunning) {
            try await session.start(flowID: replacementFlowID)
        }

        backend.releaseFirstStart()
        try await firstStart.value
        await stopping.value
        #expect(await backend.stopCaptureCount == 1)
        #expect(!(await engine.isCapturing))

        try await session.start(flowID: replacementFlowID)
        #expect(await engine.isCapturing)
        #expect(await backend.captureConfigurations == [
            AudioCaptureConfiguration(flowID: firstFlowID, settings: settings),
            AudioCaptureConfiguration(flowID: replacementFlowID, settings: settings),
        ])
        await session.stop()
        #expect(await backend.stopCaptureCount == 2)
    }

    @Test("Microphone, local monitor, and downlink share one device engine")
    @MainActor
    func devicePlansShareInjectedEngine() async throws {
        let flowID = AudioFlowID()
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let settings = try makeSessionCaptureSettings()
        let sourceFrame = try makeSessionFrame(flowID: flowID, sequence: 0)
        let downlinkFrame = try makeSessionFrame(flowID: flowID, sequence: 1)
        let backend = SessionDeviceEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)
        let sender = SessionRecordingSender()
        let receiver = SessionControlledReceiver()
        let events = SessionRecordingEventSink()
        try engine.configurePlayback(format: format)
        try engine.start()
        let configuration = try AudioPipelineConfiguration(
            source: .microphone(AudioMicrophoneSourceConfiguration(
                inputPolicy: .builtInMicrophoneRequired,
                capture: settings
            )),
            localMonitorSink: .device(policy: .privateOutputRequired),
            uplinkSender: sender,
            downlinkReceiver: receiver,
            downlinkSink: .device(policy: .privateOutputRequired),
            eventSink: events
        )
        let session = AudioPipelineSession(
            configuration: configuration,
            deviceEngine: engine
        )

        try await session.start(flowID: flowID)
        #expect(await eventuallySession { receiver.isReady() })
        try await backend.deliverCapture(sourceFrame, at: 0)
        #expect(await eventuallySession {
            let playbackSequences = await backend.playbackSequences
            return sender.values() == [sourceFrame]
                && playbackSequences == [sourceFrame.sequence]
        })

        receiver.yield(downlinkFrame)
        receiver.finish()
        #expect(await eventuallySession {
            await events.values() == [
                .flowStarted(flowID: flowID),
                .endpointEnded(flowID: flowID, direction: .downlink),
                .flowStopped(flowID: flowID, reason: .sourceEnded),
            ]
        })
        #expect(backend.playbackSequences == [
            sourceFrame.sequence,
            downlinkFrame.sequence,
        ])
        #expect(backend.stopCaptureCount == 1)
        #expect(backend.stopPlaybackCount == 1)
        #expect(engine.isRunning)
        #expect(!engine.isCapturing)
    }

    @Test("Device sinks require one running playback-configured engine")
    @MainActor
    func deviceSinksRequireReadyEngine() async throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let configuration = try AudioPipelineConfiguration(
            source: .externalFrames,
            localMonitorSink: .device(policy: .privateOutputRequired)
        )
        await #expect(throws: AudioPipelineSessionError.deviceRuntimeRequired) {
            try await AudioPipelineSession(
                configuration: configuration
            ).start()
        }

        let stoppedEngine = AudioDeviceEngine(
            backend: SessionDeviceEngineBackend()
        )
        try stoppedEngine.configurePlayback(format: format)
        await #expect(throws: AudioDeviceEngineError.engineNotRunning) {
            try await AudioPipelineSession(
                configuration: configuration,
                deviceEngine: stoppedEngine
            ).start()
        }

        let unconfiguredEngine = AudioDeviceEngine(
            backend: SessionDeviceEngineBackend()
        )
        try unconfiguredEngine.start()
        await #expect(throws: AudioDeviceEngineError.playbackNotConfigured) {
            try await AudioPipelineSession(
                configuration: configuration,
                deviceEngine: unconfiguredEngine
            ).start()
        }

        let mismatchEngine = AudioDeviceEngine(
            backend: SessionDeviceEngineBackend()
        )
        try mismatchEngine.configurePlayback(
            format: .monoPCM16(sampleRate: 16_000)
        )
        try mismatchEngine.start()
        let microphoneMonitor = try AudioPipelineConfiguration(
            source: .microphone(AudioMicrophoneSourceConfiguration(
                inputPolicy: .builtInMicrophoneRequired,
                capture: makeSessionCaptureSettings()
            )),
            localMonitorSink: .device(policy: .privateOutputRequired)
        )
        await #expect(throws: AudioDeviceEngineError.playbackFormatMismatch) {
            try await AudioPipelineSession(
                configuration: microphoneMonitor,
                deviceEngine: mismatchEngine
            ).start()
        }
    }

    @Test("Consumer stop terminates pending device playback")
    @MainActor
    func consumerStopTerminatesDevicePlayback() async throws {
        let flowID = AudioFlowID()
        let frame = try makeSessionFrame(flowID: flowID, sequence: 7)
        let backend = SessionDeviceEngineBackend(suspendsPlayback: true)
        let engine = AudioDeviceEngine(backend: backend)
        try engine.configurePlayback(format: frame.format)
        try engine.start()
        let configuration = try AudioPipelineConfiguration(
            source: .externalFrames,
            localMonitorSink: .device(policy: .privateOutputRequired)
        )
        let session = AudioPipelineSession(
            configuration: configuration,
            deviceEngine: engine
        )
        try await session.start(flowID: flowID)
        let submission = Task {
            try await session.submit(frame)
        }
        #expect(await eventuallySession {
            await backend.pendingPlaybackSequences == [frame.sequence]
        })

        await session.stop()

        do {
            try await submission.value
            Issue.record("Expected device playback stop to fail submission")
        } catch {
            #expect(error as? AudioDeviceEngineError == .playbackStopped)
        }
        #expect(backend.stopPlaybackCount == 1)
        #expect(engine.isRunning)
        #expect(await session.snapshot.state == .stopped)
    }

    @Test("The first naturally ended endpoint owns shared-flow termination")
    func firstEndedEndpointOwnsTermination() async throws {
        let flowID = AudioFlowID()
        let sourceFrame = try makeSessionFrame(flowID: flowID, sequence: 0)
        let downlinkFrame = try makeSessionFrame(flowID: flowID, sequence: 1)
        let source = SessionControlledSource()
        let sender = SessionControlledSender()
        let receiver = SessionControlledReceiver()
        let downlinkSink = SessionRecordingSink()
        let events = SessionRecordingEventSink()
        let configuration = try AudioPipelineConfiguration(
            source: .external(source),
            uplinkSender: sender,
            downlinkReceiver: receiver,
            downlinkSink: .external(downlinkSink),
            eventSink: events
        )
        let session = AudioPipelineSession(configuration: configuration)

        try await session.start(flowID: flowID)
        #expect(await eventuallySession {
            source.isReady() && receiver.isReady()
        })
        source.yield(sourceFrame)
        #expect(await eventuallySession {
            await sender.values() == [sourceFrame]
        })
        source.finish()
        #expect(await eventuallySession {
            let receivedEvents = await events.values()
            let uplinkSnapshot = await session.uplinkSnapshot
            return receivedEvents == [
                .flowStarted(flowID: flowID),
                .endpointEnded(flowID: flowID, direction: .source),
            ] && uplinkSnapshot.isSourceEnded
        })

        receiver.yield(downlinkFrame)
        #expect(await eventuallySession {
            await session.downlinkSnapshot.pending.frameCount == 1
        })
        receiver.finish()
        #expect(await eventuallySession {
            await session.naturalEndDirections == [.source, .downlink]
        })
        #expect(await session.snapshot.state == .running)
        #expect(await events.values() == [
            .flowStarted(flowID: flowID),
            .endpointEnded(flowID: flowID, direction: .source),
        ])
        #expect(await downlinkSink.values().isEmpty)

        await sender.complete()
        #expect(await eventuallySession {
            let receivedEvents = await events.values()
            let snapshot = await session.snapshot
            return receivedEvents == [
                .flowStarted(flowID: flowID),
                .endpointEnded(flowID: flowID, direction: .source),
                .flowStopped(flowID: flowID, reason: .sourceEnded),
            ] && snapshot.state == .stopped
        })
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
                .endpointEnded(flowID: flowID, direction: .downlink),
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
                    .endpointEnded(flowID: flowID, direction: .downlink),
                ]
        })

        await session.stop()
        await sink.complete()
        for _ in 0..<10 { await Task.yield() }

        #expect(await events.values() == [
            .flowStarted(flowID: flowID),
            .endpointEnded(flowID: flowID, direction: .downlink),
            .flowStopped(flowID: flowID, reason: .consumerRequested),
        ])
        #expect(await session.snapshot.state == .stopped)
    }

    @Test("Event delivery remains serial when stop overlaps a suspended event sink")
    func eventDeliveryIsSerialized() async throws {
        let flowID = AudioFlowID()
        let replacementFlowID = AudioFlowID()
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
        #expect(await eventuallySession {
            await session.snapshot.state == .stopped
        })
        #expect(events.values() == [.flowStarted(flowID: flowID)])
        await #expect(throws: AudioPipelineSessionError.alreadyRunning) {
            try await session.start(flowID: replacementFlowID)
        }

        events.resumeSuspendedDelivery()
        try await startTask.value
        await stopTask.value
        #expect(events.values() == [
            .flowStarted(flowID: flowID),
            .flowStopped(flowID: flowID, reason: .consumerRequested),
        ])

        try await session.start(flowID: replacementFlowID)
        #expect(await eventuallySession {
            await session.snapshot.state == .stopped
        })
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

private struct SessionFixedSource: AudioFrameSource {
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

private final class SessionControlledSource: AudioFrameSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation:
        AsyncThrowingStream<AudioFrame, any Error>.Continuation?

    func frames(
        for flowID: AudioFlowID
    ) -> AsyncThrowingStream<AudioFrame, any Error> {
        AsyncThrowingStream { continuation in
            lock.withLock {
                self.continuation = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.clearContinuation()
            }
        }
    }

    func isReady() -> Bool {
        lock.withLock { continuation != nil }
    }

    func yield(_ frame: AudioFrame) {
        let current: AsyncThrowingStream<AudioFrame, any Error>.Continuation? =
            lock.withLock { continuation }
        current?.yield(frame)
    }

    func finish() {
        let current: AsyncThrowingStream<AudioFrame, any Error>.Continuation? =
            lock.withLock { continuation }
        current?.finish()
    }

    private func clearContinuation() {
        lock.withLock {
            continuation = nil
        }
    }
}

private struct SessionFailingSource: AudioFrameSource {
    func frames(
        for flowID: AudioFlowID
    ) -> AsyncThrowingStream<AudioFrame, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: SessionSourceError.failed)
        }
    }
}

private enum SessionSourceError: Error {
    case failed
}

private enum SessionCaptureError: Error {
    case failed
}

@MainActor
private final class SessionDeviceEngineBackend: AudioDeviceEngineBackend {
    private(set) var captureConfigurations: [AudioCaptureConfiguration] = []
    private(set) var stopCaptureCount = 0
    private(set) var playbackFormats: [AudioStreamFormat] = []
    private(set) var playbackSequences: [UInt64] = []
    private(set) var stopPlaybackCount = 0
    private var captureHandlers: [AudioCaptureFrameHandler] = []
    private var captureFailureHandlers: [AudioCaptureFailureHandler?] = []
    private var playbackContinuations:
        [UInt64: CheckedContinuation<Void, any Error>] = [:]
    private let suspendsPlayback: Bool

    init(suspendsPlayback: Bool = false) {
        self.suspendsPlayback = suspendsPlayback
    }

    func start() throws {}
    func stop() {}
    func configurePlayback(format: AudioStreamFormat) throws {
        playbackFormats.append(format)
    }
    func configureVoiceProcessing(
        _ policy: AudioVoiceProcessingPolicy
    ) throws {}
    func schedulePlayback(_ frame: AudioFrame) async throws {
        playbackSequences.append(frame.sequence)
        guard suspendsPlayback else { return }
        try await withCheckedThrowingContinuation { continuation in
            playbackContinuations[frame.sequence] = continuation
        }
    }
    func setOutputMuted(_ muted: Bool) {}

    func startCapture(
        configuration: AudioCaptureConfiguration,
        onFrame: @escaping AudioCaptureFrameHandler,
        onFailure: AudioCaptureFailureHandler?
    ) throws {
        captureConfigurations.append(configuration)
        captureHandlers.append(onFrame)
        captureFailureHandlers.append(onFailure)
    }

    func stopCapture() {
        stopCaptureCount += 1
    }

    func stopPlayback() {
        stopPlaybackCount += 1
        let continuations = Array(playbackContinuations.values)
        playbackContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(
                throwing: AudioDeviceEngineError.playbackStopped
            )
        }
    }
    func rebuildAfterMediaServicesReset() {}

    func deliverCapture(_ frame: AudioFrame, at index: Int) async throws {
        try await captureHandlers[index](frame)
    }

    func failCapture(at index: Int, error: any Error) async {
        await captureFailureHandlers[index]?(error)
    }

    var pendingPlaybackSequences: [UInt64] {
        playbackContinuations.keys.sorted()
    }
}

@MainActor
private final class SessionBlockingStartDeviceEngineBackend:
    AudioDeviceEngineBackend
{
    nonisolated let startGate = SessionBlockingCaptureStartGate()
    private(set) var captureConfigurations: [AudioCaptureConfiguration] = []
    private(set) var stopCaptureCount = 0

    func start() throws {}
    func stop() {}
    func configurePlayback(format: AudioStreamFormat) throws {}
    func configureVoiceProcessing(
        _ policy: AudioVoiceProcessingPolicy
    ) throws {}
    func schedulePlayback(_ frame: AudioFrame) async throws {}
    func setOutputMuted(_ muted: Bool) {}

    func startCapture(
        configuration: AudioCaptureConfiguration,
        onFrame: @escaping AudioCaptureFrameHandler,
        onFailure: AudioCaptureFailureHandler?
    ) throws {
        captureConfigurations.append(configuration)
        startGate.blockFirstStart()
    }

    func stopCapture() {
        stopCaptureCount += 1
    }

    func stopPlayback() {}
    func rebuildAfterMediaServicesReset() {}

    nonisolated func waitUntilFirstStartIsBlocked() async -> Bool {
        await startGate.waitUntilFirstStartIsBlocked()
    }

    nonisolated func releaseFirstStart() {
        startGate.releaseFirstStart()
    }
}

private final class SessionBlockingCaptureStartGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var startCount = 0
    private var firstStartIsBlocked = false
    private var firstStartIsReleased = false

    func blockFirstStart() {
        condition.lock()
        startCount += 1
        guard startCount == 1 else {
            condition.unlock()
            return
        }
        firstStartIsBlocked = true
        condition.broadcast()
        while !firstStartIsReleased {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilFirstStartIsBlocked() async -> Bool {
        for _ in 0..<1_000 {
            if isFirstStartBlocked() { return true }
            await Task.yield()
        }
        return false
    }

    private func isFirstStartBlocked() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return firstStartIsBlocked
    }

    func releaseFirstStart() {
        condition.lock()
        firstStartIsReleased = true
        condition.broadcast()
        condition.unlock()
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

private final class SessionControlledReceiver: AudioFrameReceiver, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation:
        AsyncThrowingStream<AudioFrame, any Error>.Continuation?

    func frames(
        for flowID: AudioFlowID
    ) -> AsyncThrowingStream<AudioFrame, any Error> {
        AsyncThrowingStream { continuation in
            lock.withLock {
                self.continuation = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.clearContinuation()
            }
        }
    }

    func isReady() -> Bool {
        lock.withLock { continuation != nil }
    }

    func yield(_ frame: AudioFrame) {
        let current: AsyncThrowingStream<AudioFrame, any Error>.Continuation? =
            lock.withLock { self.continuation }
        current?.yield(frame)
    }

    func finish() {
        let current: AsyncThrowingStream<AudioFrame, any Error>.Continuation? =
            lock.withLock { self.continuation }
        current?.finish()
    }

    private func clearContinuation() {
        lock.withLock {
            continuation = nil
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

private actor SessionControlledSender: AudioFrameSender {
    private var frames: [AudioFrame] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func send(_ frame: AudioFrame) async throws {
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

private func makeSessionCaptureSettings() throws -> AudioCaptureSettings {
    try AudioCaptureSettings(
        format: .monoPCM16(sampleRate: 24_000),
        frameDuration: .milliseconds(20),
        maximumBufferedDuration: .milliseconds(100),
        maximumFramesPerCallback: 8,
        maximumPendingCallbackCount: 4
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
