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
        #expect(Set(backend.scheduledPlaybackOwners.values).count == 1)
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

    @Test("Stopping one shared-engine session preserves another playback owner")
    @MainActor
    func sharedEnginePlaybackOwnersAreIsolated() async throws {
        let firstFlowID = AudioFlowID()
        let secondFlowID = AudioFlowID()
        let firstFrame = try makeSessionFrame(
            flowID: firstFlowID,
            sequence: 41
        )
        let secondFrame = try makeSessionFrame(
            flowID: secondFlowID,
            sequence: 42
        )
        let backend = SessionDeviceEngineBackend(suspendsPlayback: true)
        let engine = AudioDeviceEngine(backend: backend)
        try engine.configurePlayback(format: firstFrame.format)
        try engine.start()
        let firstSession = AudioPipelineSession(
            configuration: try AudioPipelineConfiguration(
                source: .externalFrames,
                localMonitorSink: .device(policy: .privateOutputRequired)
            ),
            deviceEngine: engine
        )
        let secondSession = AudioPipelineSession(
            configuration: try AudioPipelineConfiguration(
                source: .externalFrames,
                localMonitorSink: .device(policy: .privateOutputRequired)
            ),
            deviceEngine: engine
        )

        try await firstSession.start(flowID: firstFlowID)
        try await secondSession.start(flowID: secondFlowID)
        let firstSubmission = Task {
            try await firstSession.submit(firstFrame)
        }
        let secondSubmission = Task {
            try await secondSession.submit(secondFrame)
        }
        await backend.waitUntilPendingPlaybackSequences([41, 42])

        await firstSession.stop()

        await #expect(throws: AudioDeviceEngineError.playbackStopped) {
            try await firstSubmission.value
        }
        #expect(backend.pendingPlaybackSequences == [42])
        #expect(Set(backend.scheduledPlaybackOwners.values).count == 2)

        backend.completePlayback(sequence: 42)
        try await secondSubmission.value
        #expect(await secondSession.snapshot.state == .running)
        await secondSession.stop()
        #expect(backend.stopPlaybackCount == 2)
    }

    @Test("Stop after uplink enqueue prevents a stale monitor frame")
    func stopAfterUplinkEnqueueDropsMonitorDelivery() async throws {
        let flowID = AudioFlowID()
        let frame = try makeSessionFrame(flowID: flowID, sequence: 51)
        let monitor = SessionRecordingSink()
        let gate = SessionSourceFanOutGate()
        let session = AudioPipelineSession(
            configuration: try AudioPipelineConfiguration(
                source: .externalFrames,
                localMonitorSink: .external(monitor),
                uplinkSender: SessionRecordingSender()
            ),
            startAttemptSuspension: {},
            sourcePostUplinkSuspension: { await gate.suspend() }
        )
        try await session.start(flowID: flowID)
        let submission = Task { try await session.submit(frame) }
        await gate.waitUntilSuspended()

        await session.stop()
        await gate.resume()

        await #expect(throws: AudioPipelineSessionError.notRunning) {
            try await submission.value
        }
        #expect(await monitor.values().isEmpty)
    }

    @Test("Endpoint failure after uplink enqueue prevents a stale monitor frame")
    @MainActor
    func failureAfterUplinkEnqueueDropsMonitorDelivery() async throws {
        let flowID = AudioFlowID()
        let frame = try makeSessionFrame(flowID: flowID, sequence: 52)
        let backend = SessionDeviceEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)
        try engine.configurePlayback(format: frame.format)
        try engine.start()
        let events = SessionRecordingEventSink()
        let gate = SessionSourceFanOutGate()
        let session = AudioPipelineSession(
            configuration: try AudioPipelineConfiguration(
                source: .externalFrames,
                localMonitorSink: .device(policy: .privateOutputRequired),
                uplinkSender: SessionFailingSender(),
                eventSink: events
            ),
            deviceEngine: engine,
            startAttemptSuspension: {},
            sourcePostUplinkSuspension: { await gate.suspend() }
        )
        try await session.start(flowID: flowID)
        let submission = Task { try await session.submit(frame) }
        await gate.waitUntilSuspended()
        #expect(await eventuallySession {
            await events.values().last == .flowStopped(
                flowID: flowID,
                reason: .endpointFailure
            )
        })

        await gate.resume()

        await #expect(throws: AudioPipelineSessionError.notRunning) {
            try await submission.value
        }
        #expect(backend.playbackSequences.isEmpty)
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

    @Test("Recovery stop waits for endpoint-failure delivery before restart")
    func recoveryStopWaitsForEndpointFailureBarrier() async throws {
        let failedFlowID = AudioFlowID()
        let replacementFlowID = AudioFlowID()
        let sender = SessionFailOnceSender()
        let events = SessionRecoveryStopEventSink()
        let stopWaitObservation = SessionStopWaitObservation()
        let processorResetRecorder = SessionProcessorResetRecorder()
        let configuration = try AudioPipelineConfiguration(
            source: .externalFrames,
            sourceProcessorChain: makeSessionProcessorChain([
                SessionFirstFramePerGenerationProcessor(
                    resetRecorder: processorResetRecorder
                ),
            ]),
            uplinkSender: sender,
            eventSink: events
        )
        let session = AudioPipelineSession(
            configuration: configuration,
            startAttemptSuspension: {},
            stopWaitObservation: {
                stopWaitObservation.record()
            }
        )
        events.attach(session: session)
        try await session.start(flowID: failedFlowID)
        #expect(processorResetRecorder.count == 1)
        try await session.submit(try makeSessionFrame(
            flowID: failedFlowID,
            sequence: 0
        ))
        #expect(await eventuallySession {
            events.values() == [
                .flowStarted(flowID: failedFlowID),
                .endpointFailed(flowID: failedFlowID, direction: .uplink),
                .flowStopped(
                    flowID: failedFlowID,
                    reason: .endpointFailure
                ),
            ] && events.isTerminalDeliverySuspended()
        })

        await stopWaitObservation.waitUntilCount(1)
        #expect(!events.isRecoveryStopComplete())
        events.resumeTerminalDelivery()
        await events.waitForRecoveryStop()
        #expect(events.isRecoveryStopComplete())
        #expect(processorResetRecorder.count == 2)

        try await session.start(flowID: replacementFlowID)
        #expect(processorResetRecorder.count == 3)
        let replacementFrame = try makeSessionFrame(
            flowID: replacementFlowID,
            sequence: 1
        )
        try await session.submit(replacementFrame)
        #expect(await eventuallySession {
            await sender.values() == [replacementFrame]
        })
        #expect(events.values() == [
            .flowStarted(flowID: failedFlowID),
            .endpointFailed(flowID: failedFlowID, direction: .uplink),
            .flowStopped(flowID: failedFlowID, reason: .endpointFailure),
            .flowStarted(flowID: replacementFlowID),
        ])
        await session.stop()
    }

    @Test("Consumer stop waits for a pending start before returning idle")
    func consumerStopWaitsForPendingStart() async throws {
        let pendingFlowID = AudioFlowID()
        let replacementFlowID = AudioFlowID()
        let startGate = SessionFirstStartAttemptGate()
        let stopProbe = SessionCompletionProbe()
        let stopWaitObservation = SessionStopWaitObservation()
        let configuration = try AudioPipelineConfiguration(
            source: .externalFrames,
            localMonitorSink: .external(SessionRecordingSink())
        )
        let session = AudioPipelineSession(
            configuration: configuration,
            startAttemptSuspension: {
                await startGate.suspendFirstAttempt()
            },
            stopWaitObservation: {
                stopWaitObservation.record()
            }
        )
        let pendingStart = Task {
            try await session.start(flowID: pendingFlowID)
        }
        await startGate.waitUntilFirstAttemptIsSuspended()

        let stop = Task {
            await session.stop()
            await stopProbe.complete()
        }
        await stopWaitObservation.waitUntilCount(1)
        #expect(!(await stopProbe.isComplete))

        await startGate.resumeFirstAttempt()
        try await pendingStart.value
        await stop.value
        #expect(await stopProbe.isComplete)

        try await session.start(flowID: replacementFlowID)
        #expect(await session.snapshot.flowID == replacementFlowID)
        await session.stop()
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

    @Test("Safety invalidates and awaits a pre-registration start attempt")
    func safetyCancelsPreRegistrationStartAttempt() async throws {
        let flowID = AudioFlowID()
        let startGate = SessionFirstStartAttemptGate()
        let events = SessionRecordingEventSink()
        let configuration = try AudioPipelineConfiguration(
            source: .externalFrames,
            localMonitorSink: .external(SessionRecordingSink()),
            eventSink: events
        )
        let session = AudioPipelineSession(
            configuration: configuration,
            startAttemptSuspension: {
                await startGate.suspendFirstAttempt()
            }
        )
        let safetyBuffers = await MainActor.run {
            AudioPipelineSafetyBufferController(session: session)
        }
        let starting = Task {
            try await session.start(flowID: flowID)
        }
        await startGate.waitUntilFirstAttemptIsSuspended()

        await MainActor.run {
            safetyBuffers.latchSafetyBoundary()
        }
        let cleanup = Task {
            await safetyBuffers.discardPendingAudio()
        }
        await startGate.resumeFirstAttempt()

        await #expect(
            throws: AudioPipelineSessionError.startCancelledBySafetyBoundary
        ) {
            try await starting.value
        }
        await cleanup.value
        #expect(await events.values().isEmpty)

        try await session.start(flowID: flowID)
        #expect(await events.values() == [.flowStarted(flowID: flowID)])
        await session.stop()
    }

    @Test("Safety buffer replacement stops old session and binds future claims to new session")
    func safetyBufferReplacementMovesExactSessionOwnership() async throws {
        let oldFlowID = AudioFlowID()
        let replacementFlowID = AudioFlowID()
        let oldEvents = SessionRecordingEventSink()
        let replacementEvents = SessionRecordingEventSink()
        let oldSession = AudioPipelineSession(
            configuration: try AudioPipelineConfiguration(
                source: .externalFrames,
                uplinkSender: SessionRecordingSender(),
                eventSink: oldEvents
            )
        )
        let replacementSession = AudioPipelineSession(
            configuration: try AudioPipelineConfiguration(
                source: .externalFrames,
                uplinkSender: SessionRecordingSender(),
                eventSink: replacementEvents
            )
        )
        let safetyBuffers = await MainActor.run {
            AudioPipelineSafetyBufferController(session: oldSession)
        }

        try await oldSession.start(flowID: oldFlowID)
        try await safetyBuffers.replaceSession(replacementSession)
        #expect(await oldSession.snapshot.state == .stopped)
        #expect(await oldEvents.values() == [
            .flowStarted(flowID: oldFlowID),
            .flowStopped(flowID: oldFlowID, reason: .consumerRequested),
        ])

        try await replacementSession.start(flowID: replacementFlowID)
        await safetyBuffers.discardPendingAudio()
        #expect(await replacementSession.snapshot.state == .stopped)
        #expect(await replacementEvents.values() == [
            .flowStarted(flowID: replacementFlowID),
            .flowStopped(flowID: replacementFlowID, reason: .safetyBoundary),
        ])
    }

    @Test("Safety claim racing replacement stays paired with old session and fails replacement closed")
    func safetyClaimWinsSuspendedSessionReplacement() async throws {
        let oldFlowID = AudioFlowID()
        let replacementFlowID = AudioFlowID()
        let oldEvents = SessionSuspendingEventSink(suspendingAt: 2)
        let replacementEvents = SessionRecordingEventSink()
        let oldSession = AudioPipelineSession(
            configuration: try AudioPipelineConfiguration(
                source: .externalFrames,
                uplinkSender: SessionRecordingSender(),
                eventSink: oldEvents
            )
        )
        let replacementSession = AudioPipelineSession(
            configuration: try AudioPipelineConfiguration(
                source: .externalFrames,
                uplinkSender: SessionRecordingSender(),
                eventSink: replacementEvents
            )
        )
        let safetyBuffers = await MainActor.run {
            AudioPipelineSafetyBufferController(session: oldSession)
        }
        try await oldSession.start(flowID: oldFlowID)

        let replacement = Task {
            try await safetyBuffers.replaceSession(replacementSession)
        }
        #expect(await eventuallySession {
            oldEvents.values() == [
                .flowStarted(flowID: oldFlowID),
                .flowStopped(
                    flowID: oldFlowID,
                    reason: .consumerRequested
                ),
            ] && oldEvents.isSuspended()
        })
        await MainActor.run {
            safetyBuffers.latchSafetyBoundary()
        }
        let cleanup = Task {
            await safetyBuffers.discardPendingAudio()
        }
        oldEvents.resumeSuspendedDelivery()

        await #expect(
            throws: AudioPipelineSafetyBufferControllerError
                .replacementDuringSafetyBoundary
        ) {
            try await replacement.value
        }
        await cleanup.value

        try await replacementSession.start(flowID: replacementFlowID)
        await safetyBuffers.discardPendingAudio()
        #expect(await replacementSession.snapshot.state == .running)
        await replacementSession.stop()
    }

    @Test("Concurrent safety-buffer replacements elect one session and supersede the loser")
    func concurrentSafetyBufferReplacementFailsClosed() async throws {
        let oldFlowID = AudioFlowID()
        let firstFlowID = AudioFlowID()
        let secondFlowID = AudioFlowID()
        let oldEvents = SessionSuspendingEventSink(suspendingAt: 2)
        let stopWaitObservation = SessionStopWaitObservation()
        let firstSession = AudioPipelineSession(
            configuration: try AudioPipelineConfiguration(
                source: .externalFrames,
                uplinkSender: SessionRecordingSender()
            )
        )
        let secondSession = AudioPipelineSession(
            configuration: try AudioPipelineConfiguration(
                source: .externalFrames,
                uplinkSender: SessionRecordingSender()
            )
        )
        let oldSession = AudioPipelineSession(
            configuration: try AudioPipelineConfiguration(
                source: .externalFrames,
                uplinkSender: SessionRecordingSender(),
                eventSink: oldEvents
            ),
            startAttemptSuspension: {},
            stopWaitObservation: {
                stopWaitObservation.record()
            }
        )
        let safetyBuffers = await MainActor.run {
            AudioPipelineSafetyBufferController(session: oldSession)
        }
        try await oldSession.start(flowID: oldFlowID)

        let firstReplacement = Task {
            do {
                try await safetyBuffers.replaceSession(firstSession)
                return nil as AudioPipelineSafetyBufferControllerError?
            } catch {
                return error as? AudioPipelineSafetyBufferControllerError
            }
        }
        #expect(await eventuallySession { oldEvents.isSuspended() })
        let secondReplacement = Task {
            do {
                try await safetyBuffers.replaceSession(secondSession)
                return nil as AudioPipelineSafetyBufferControllerError?
            } catch {
                return error as? AudioPipelineSafetyBufferControllerError
            }
        }
        await stopWaitObservation.waitUntilCount(1)
        oldEvents.resumeSuspendedDelivery()

        let results = await [
            firstReplacement.value,
            secondReplacement.value,
        ]
        #expect(results.filter { $0 == nil }.count == 1)
        #expect(results.filter { $0 == .supersededReplacement }.count == 1)

        try await firstSession.start(flowID: firstFlowID)
        try await secondSession.start(flowID: secondFlowID)
        await safetyBuffers.discardPendingAudio()
        let states = await [
            firstSession.snapshot.state,
            secondSession.snapshot.state,
        ]
        #expect(states.filter { $0 == .stopped }.count == 1)
        #expect(states.filter { $0 == .running }.count == 1)
        await firstSession.stop()
        await secondSession.stop()
    }

    @Test("Cancelled replacement waits for old cleanup and never binds the replacement")
    func cancelledSafetyBufferReplacementDoesNotBind() async throws {
        let oldFlowID = AudioFlowID()
        let replacementFlowID = AudioFlowID()
        let oldEvents = SessionSuspendingEventSink(suspendingAt: 2)
        let oldSession = AudioPipelineSession(
            configuration: try AudioPipelineConfiguration(
                source: .externalFrames,
                uplinkSender: SessionRecordingSender(),
                eventSink: oldEvents
            )
        )
        let replacementSession = AudioPipelineSession(
            configuration: try AudioPipelineConfiguration(
                source: .externalFrames,
                uplinkSender: SessionRecordingSender()
            )
        )
        let safetyBuffers = await MainActor.run {
            AudioPipelineSafetyBufferController(session: oldSession)
        }
        try await oldSession.start(flowID: oldFlowID)

        let replacement = Task {
            try await safetyBuffers.replaceSession(replacementSession)
        }
        #expect(await eventuallySession {
            oldEvents.values() == [
                .flowStarted(flowID: oldFlowID),
                .flowStopped(
                    flowID: oldFlowID,
                    reason: .consumerRequested
                ),
            ] && oldEvents.isSuspended()
        })
        replacement.cancel()
        oldEvents.resumeSuspendedDelivery()

        await #expect(throws: CancellationError.self) {
            try await replacement.value
        }

        try await replacementSession.start(flowID: replacementFlowID)
        await safetyBuffers.discardPendingAudio()
        #expect(await replacementSession.snapshot.state == .running)
        await replacementSession.stop()
    }

    @Test("Safety cleanup blocks replacement and resets source processing")
    func safetyCleanupOwnsTerminalBarrierAndProcessorReset() async throws {
        let firstFlowID = AudioFlowID()
        let replacementFlowID = AudioFlowID()
        let outputFormat = try AudioStreamFormat.monoPCM16(sampleRate: 16_000)
        let sender = SessionRecordingSender()
        let events = SessionSuspendingEventSink(suspendingAt: 2)
        let configuration = try AudioPipelineConfiguration(
            source: .externalFrames,
            sourceProcessorChain: makeSessionProcessorChain([
                SessionPairFormatProcessor(outputFormat: outputFormat),
            ]),
            uplinkSender: sender,
            eventSink: events
        )
        let session = AudioPipelineSession(configuration: configuration)
        let safetyBuffers = await MainActor.run {
            AudioPipelineSafetyBufferController(session: session)
        }

        try await session.start(flowID: firstFlowID)
        try await session.submit(
            makeSessionFrame(flowID: firstFlowID, sequence: 0)
        )
        #expect(sender.values().isEmpty)

        let firstCleanupProbe = SessionCompletionProbe()
        let secondCleanupProbe = SessionCompletionProbe()
        let firstSafetyCleanup = Task {
            await safetyBuffers.discardPendingAudio()
            await firstCleanupProbe.complete()
        }
        let secondSafetyCleanup = Task {
            await safetyBuffers.discardPendingAudio()
            await secondCleanupProbe.complete()
        }
        #expect(await eventuallySession {
            events.values() == [
                .flowStarted(flowID: firstFlowID),
                .flowStopped(flowID: firstFlowID, reason: .safetyBoundary),
            ] && events.isSuspended()
        })
        #expect(await session.snapshot.state == .stopped)
        #expect(!(await firstCleanupProbe.isComplete))
        #expect(!(await secondCleanupProbe.isComplete))
        await #expect(throws: AudioPipelineSessionError.alreadyRunning) {
            try await session.start(flowID: replacementFlowID)
        }

        events.resumeSuspendedDelivery()
        await firstSafetyCleanup.value
        await secondSafetyCleanup.value
        #expect(await firstCleanupProbe.isComplete)
        #expect(await secondCleanupProbe.isComplete)
        try await session.start(flowID: replacementFlowID)
        try await session.submit(
            makeSessionFrame(flowID: replacementFlowID, sequence: 0)
        )
        #expect(sender.values().isEmpty)
        try await session.submit(
            makeSessionFrame(flowID: replacementFlowID, sequence: 1)
        )
        #expect(await eventuallySession {
            sender.values().map(\.sequence) == [1]
        })

        await safetyBuffers.discardPendingAudio()
        #expect(await session.uplinkSnapshot.pending == .zero)
        #expect(await session.downlinkSnapshot.pending == .zero)
    }

    @Test("Pending capture and stale callbacks cannot cross safety events")
    func pendingCaptureAndCallbacksStayGenerationIsolated() async throws {
        let firstFlowID = AudioFlowID()
        let replacementFlowID = AudioFlowID()
        let settings = try makeSessionCaptureSettings()
        let sender = SessionRecordingSender()
        let pipelineEvents = SessionRecordingEventSink()
        let configuration = try AudioPipelineConfiguration(
            source: .microphone(AudioMicrophoneSourceConfiguration(
                inputPolicy: .builtInMicrophoneRequired,
                capture: settings
            )),
            localMonitorSink: .device(policy: .privateOutputRequired),
            uplinkSender: sender,
            eventSink: pipelineEvents
        )
        let (backend, engine) = try await MainActor.run {
            let backend = SessionBlockingStartDeviceEngineBackend()
            let engine = AudioDeviceEngine(backend: backend)
            try engine.configurePlayback(format: settings.format)
            try engine.start()
            return (backend, engine)
        }
        let session = AudioPipelineSession(
            configuration: configuration,
            deviceEngine: engine
        )
        let deviceEvents = await MainActor.run {
            SessionSafetyDeviceEventSink()
        }
        let coordinator = await MainActor.run {
            AudioSafetyCoordinator(
                hardware: engine,
                buffers: AudioPipelineSafetyBufferController(session: session),
                session: SessionSafetyAudioSession(),
                eventSink: deviceEvents
            )
        }

        let firstStart = Task {
            try await session.start(flowID: firstFlowID)
        }
        #expect(await backend.waitUntilFirstStartIsBlocked())
        // This manual latch isolates stale capture callbacks while the test
        // backend synchronously blocks the MainActor. Coordinator latch-before-
        // hardware-stop ordering is covered by the pending device-playback test.
        _ = session.latchSafetyBoundary()
        let firstSafety = Task { @MainActor in
            await coordinator.handle(.interruptionBegan)
        }
        backend.releaseFirstStart()
        await backend.waitUntilStopCaptureCount(1)
        await #expect(
            throws: AudioPipelineSessionError.startCancelledBySafetyBoundary
        ) {
            try await firstStart.value
        }
        let firstResult = await firstSafety.value

        #expect(firstResult.engagedSafetyBoundary)
        #expect(await pipelineEvents.values() == [
            .flowStarted(flowID: firstFlowID),
            .flowStopped(flowID: firstFlowID, reason: .safetyBoundary),
        ])
        #expect(!(await engine.isCapturing))
        #expect(await backend.stopCaptureCount == 1)
        #expect(await backend.stopPlaybackCount == 2)
        try await backend.deliverCapture(
            makeSessionFrame(flowID: firstFlowID, sequence: 0),
            at: 0
        )
        await backend.failCapture(at: 0, error: SessionCaptureError.failed)
        #expect(await pipelineEvents.values().count == 2)

        try await session.start(flowID: replacementFlowID)
        try await backend.deliverCapture(
            makeSessionFrame(flowID: firstFlowID, sequence: 1),
            at: 0
        )
        await backend.failCapture(at: 0, error: SessionCaptureError.failed)
        #expect(await session.snapshot.state == .running)
        #expect(await engine.isCapturing)
        let replacementFrame = try makeSessionFrame(
            flowID: replacementFlowID,
            sequence: 0
        )
        try await backend.deliverCapture(replacementFrame, at: 1)
        #expect(await eventuallySession {
            sender.values() == [replacementFrame]
        })

        let resetResult = await coordinator.handle(.mediaServicesReset)
        #expect(resetResult.engagedSafetyBoundary)
        #expect(await pipelineEvents.values() == [
            .flowStarted(flowID: firstFlowID),
            .flowStopped(flowID: firstFlowID, reason: .safetyBoundary),
            .flowStarted(flowID: replacementFlowID),
            .flowStopped(flowID: replacementFlowID, reason: .safetyBoundary),
        ])
        #expect(!(await engine.isRunning))
        #expect(!(await engine.isCapturing))
        #expect(await backend.stopCaptureCount == 2)
        #expect(await backend.stopPlaybackCount == 4)
        #expect(await backend.rebuildCount == 1)
        try await backend.deliverCapture(
            makeSessionFrame(flowID: replacementFlowID, sequence: 1),
            at: 1
        )
        await backend.failCapture(at: 1, error: SessionCaptureError.failed)
        #expect(await pipelineEvents.values().count == 4)
        #expect(await deviceEvents.values() == [
            .interruptionBegan,
            .mediaServicesReset,
        ])
        #expect(await session.uplinkSnapshot.pending == .zero)
        #expect(await session.downlinkSnapshot.pending == .zero)
    }

    @Test("Safety owns terminal reason for pending local and downlink playback")
    @MainActor
    func safetyLatchPrecedesPendingDevicePlaybackFailure() async throws {
        let flowID = AudioFlowID()
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let backend = SessionDeviceEngineBackend(suspendsPlayback: true)
        let engine = AudioDeviceEngine(backend: backend)
        let receiver = SessionControlledReceiver()
        let events = SessionRecordingEventSink()
        try engine.configurePlayback(format: format)
        try engine.start()
        let configuration = try AudioPipelineConfiguration(
            source: .externalFrames,
            localMonitorSink: .device(policy: .privateOutputRequired),
            downlinkReceiver: receiver,
            downlinkSink: .device(policy: .privateOutputRequired),
            eventSink: events
        )
        let session = AudioPipelineSession(
            configuration: configuration,
            deviceEngine: engine,
            downlinkPolicy: try BoundedDownlinkJitterBufferPolicy(
                targetBufferedAudioDuration: .milliseconds(20),
                maximumBufferedAudioDuration: .seconds(1),
                maximumFrameAge: .seconds(2)
            )
        )
        let deviceEvents = SessionSafetyDeviceEventSink()
        let coordinator = AudioSafetyCoordinator(
            hardware: engine,
            buffers: AudioPipelineSafetyBufferController(session: session),
            session: SessionSafetyAudioSession(),
            eventSink: deviceEvents
        )

        try await session.start(flowID: flowID)
        #expect(await eventuallySession { receiver.isReady() })
        let localSubmission = Task {
            try await session.submit(
                makeSessionFrame(flowID: flowID, sequence: 0)
            )
        }
        receiver.yield(try makeSessionFrame(flowID: flowID, sequence: 1))
        await backend.waitUntilPendingPlaybackSequences([0, 1])

        _ = await coordinator.handle(.interruptionBegan)
        _ = try? await localSubmission.value

        #expect(await events.values() == [
            .flowStarted(flowID: flowID),
            .flowStopped(flowID: flowID, reason: .safetyBoundary),
        ])
        #expect(backend.stopPlaybackCount == 2)
        #expect(await session.snapshot.state == .stopped)
    }

    @Test("A processor can drop or expand source frames before fan-out")
    func processorOutputsReachEverySourcePlanInOrder() async throws {
        let flowID = AudioFlowID()
        let dropped = try makeSessionFrame(flowID: flowID, sequence: 0)
        let expanded = try makeSessionFrame(flowID: flowID, sequence: 1)
        let monitor = SessionRecordingSink()
        let sender = SessionRecordingSender()
        let chain = try makeSessionProcessorChain([
            SessionDropOrDuplicateProcessor(),
        ])
        let configuration = try AudioPipelineConfiguration(
            source: .externalFrames,
            sourceProcessorChain: chain,
            localMonitorSink: .external(monitor),
            uplinkSender: sender
        )
        let session = AudioPipelineSession(configuration: configuration)

        try await session.start(flowID: flowID)
        try await session.submit(dropped)
        try await session.submit(expanded)

        #expect(await eventuallySession {
            let expectedSequences: [UInt64] = [1, 101]
            return await monitor.values().map(\.sequence) == expectedSequences
                && sender.values().map(\.sequence) == expectedSequences
        })
        await session.stop()
    }

    @Test("Caller submission preserves processor errors and fails the source endpoint")
    func callerSubmissionPreservesProcessorFailure() async throws {
        let flowID = AudioFlowID()
        let events = SessionRecordingEventSink()
        let chain = try makeSessionProcessorChain([
            SessionFailingProcessor(),
        ])
        let configuration = try AudioPipelineConfiguration(
            source: .externalFrames,
            sourceProcessorChain: chain,
            localMonitorSink: .external(SessionRecordingSink()),
            eventSink: events
        )
        let session = AudioPipelineSession(configuration: configuration)

        try await session.start(flowID: flowID)
        do {
            try await session.submit(
                try makeSessionFrame(flowID: flowID, sequence: 0)
            )
            Issue.record("Expected processor failure")
        } catch let failure as AudioProcessorFailure {
            #expect(failure.index == 0)
            #expect(failure.underlyingError is SessionProcessorError)
        } catch {
            Issue.record("Expected AudioProcessorFailure, got \(type(of: error))")
        }

        #expect(await events.values() == [
            .flowStarted(flowID: flowID),
            .endpointFailed(flowID: flowID, direction: .source),
            .flowStopped(flowID: flowID, reason: .endpointFailure),
        ])
        #expect(await session.snapshot.state == .stopped)
    }

    @Test("Caller submission preserves processor contract errors")
    func callerSubmissionPreservesProcessingError() async throws {
        let flowID = AudioFlowID()
        let events = SessionRecordingEventSink()
        let chain = try makeSessionProcessorChain([
            SessionUndeclaredFormatProcessor(),
        ])
        let configuration = try AudioPipelineConfiguration(
            source: .externalFrames,
            sourceProcessorChain: chain,
            localMonitorSink: .external(SessionRecordingSink()),
            eventSink: events
        )
        let session = AudioPipelineSession(configuration: configuration)

        try await session.start(flowID: flowID)
        await #expect(throws: AudioProcessingError.unexpectedOutputFormat(
            index: 0
        )) {
            try await session.submit(
                try makeSessionFrame(flowID: flowID, sequence: 0)
            )
        }
        #expect(await events.values() == [
            .flowStarted(flowID: flowID),
            .endpointFailed(flowID: flowID, direction: .source),
            .flowStopped(flowID: flowID, reason: .endpointFailure),
        ])
    }

    @Test("Active external-source processing failure stays content-free")
    func externalSourceProcessorFailureUsesSourceLifecycle() async throws {
        let flowID = AudioFlowID()
        let frame = try makeSessionFrame(flowID: flowID, sequence: 0)
        let events = SessionRecordingEventSink()
        let configuration = try AudioPipelineConfiguration(
            source: .external(SessionFixedSource(frames: [frame])),
            sourceProcessorChain: makeSessionProcessorChain([
                SessionFailingProcessor(),
            ]),
            localMonitorSink: .external(SessionRecordingSink()),
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
    }

    @Test("Microphone processing failure stops capture without exposing its error")
    @MainActor
    func microphoneProcessorFailureUsesSourceLifecycle() async throws {
        let flowID = AudioFlowID()
        let backend = SessionDeviceEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)
        let events = SessionRecordingEventSink()
        try engine.start()
        let configuration = try AudioPipelineConfiguration(
            source: .microphone(AudioMicrophoneSourceConfiguration(
                inputPolicy: .builtInMicrophoneRequired,
                capture: makeSessionCaptureSettings()
            )),
            sourceProcessorChain: makeSessionProcessorChain([
                SessionFailingProcessor(),
            ]),
            uplinkSender: SessionRecordingSender(),
            eventSink: events
        )
        let session = AudioPipelineSession(
            configuration: configuration,
            deviceEngine: engine
        )

        try await session.start(flowID: flowID)
        try await backend.deliverCapture(
            makeSessionFrame(flowID: flowID, sequence: 0),
            at: 0
        )
        #expect(await eventuallySession {
            await events.values() == [
                .flowStarted(flowID: flowID),
                .endpointFailed(flowID: flowID, direction: .source),
                .flowStopped(flowID: flowID, reason: .endpointFailure),
            ]
        })
        #expect(backend.stopCaptureCount == 1)
        #expect(engine.isRunning)
    }

    @Test("Microphone processing resets per flow and declares device output format")
    @MainActor
    func microphoneProcessorFeedsSharedDeviceAndResets() async throws {
        let firstFlowID = AudioFlowID()
        let secondFlowID = AudioFlowID()
        let outputFormat = try AudioStreamFormat.monoPCM16(sampleRate: 16_000)
        let backend = SessionDeviceEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)
        try engine.configurePlayback(format: outputFormat)
        try engine.start()
        let chain = try makeSessionProcessorChain([
            SessionPairFormatProcessor(outputFormat: outputFormat),
        ])
        let configuration = try AudioPipelineConfiguration(
            source: .microphone(AudioMicrophoneSourceConfiguration(
                inputPolicy: .builtInMicrophoneRequired,
                capture: makeSessionCaptureSettings()
            )),
            sourceProcessorChain: chain,
            localMonitorSink: .device(policy: .privateOutputRequired)
        )
        let session = AudioPipelineSession(
            configuration: configuration,
            deviceEngine: engine
        )

        try await session.start(flowID: firstFlowID)
        try await backend.deliverCapture(
            makeSessionFrame(flowID: firstFlowID, sequence: 1),
            at: 0
        )
        for _ in 0..<10 { await Task.yield() }
        #expect(backend.playbackSequences.isEmpty)
        await session.stop()

        try await session.start(flowID: secondFlowID)
        try await backend.deliverCapture(
            makeSessionFrame(flowID: secondFlowID, sequence: 2),
            at: 1
        )
        for _ in 0..<10 { await Task.yield() }
        #expect(backend.playbackSequences.isEmpty)
        try await backend.deliverCapture(
            makeSessionFrame(flowID: secondFlowID, sequence: 3),
            at: 1
        )
        #expect(await eventuallySession {
            await backend.playbackSequences == [3]
        })
        await session.stop()
        #expect(backend.stopCaptureCount == 2)
        #expect(backend.stopPlaybackCount == 2)
        #expect(engine.isRunning)
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
        // The observable state can become stopped just before the terminal
        // run-cleanup barrier releases `activeRun`; join that barrier before
        // exercising identifier reuse.
        await session.stop()

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
    private(set) var scheduledPlaybackOwners:
        [UInt64: AudioDevicePlaybackOwner] = [:]
    private(set) var stopPlaybackCount = 0
    private var captureHandlers: [AudioCaptureFrameHandler] = []
    private var captureFailureHandlers: [AudioCaptureFailureHandler?] = []
    private var playbackContinuations:
        [UInt64: CheckedContinuation<Void, any Error>] = [:]
    private var playbackOwners: [UInt64: AudioDevicePlaybackOwner] = [:]
    private var playbackWaiters:
        [(expected: [UInt64], continuation: CheckedContinuation<Void, Never>)] = []
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
    func schedulePlayback(
        _ frame: AudioFrame,
        owner: AudioDevicePlaybackOwner
    ) async throws {
        playbackSequences.append(frame.sequence)
        scheduledPlaybackOwners[frame.sequence] = owner
        guard suspendsPlayback else { return }
        try await withCheckedThrowingContinuation { continuation in
            playbackContinuations[frame.sequence] = continuation
            playbackOwners[frame.sequence] = owner
            resumePlaybackWaitersIfReady()
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

    func stopPlayback(owner: AudioDevicePlaybackOwner?) {
        stopPlaybackCount += 1
        let sequences = playbackContinuations.keys.filter {
            owner == nil || playbackOwners[$0] == owner
        }
        let continuations = sequences.compactMap {
            playbackOwners.removeValue(forKey: $0)
            return playbackContinuations.removeValue(forKey: $0)
        }
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

    func completePlayback(sequence: UInt64) {
        playbackOwners.removeValue(forKey: sequence)
        playbackContinuations.removeValue(forKey: sequence)?.resume()
        resumePlaybackWaitersIfReady()
    }

    func waitUntilPendingPlaybackSequences(_ expected: [UInt64]) async {
        guard pendingPlaybackSequences != expected else { return }
        await withCheckedContinuation { continuation in
            playbackWaiters.append((expected, continuation))
        }
    }

    private func resumePlaybackWaitersIfReady() {
        let pending = pendingPlaybackSequences
        let ready = playbackWaiters.filter { $0.expected == pending }
        playbackWaiters.removeAll { $0.expected == pending }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

@MainActor
private final class SessionBlockingStartDeviceEngineBackend:
    AudioDeviceEngineBackend
{
    nonisolated let startGate = SessionBlockingCaptureStartGate()
    private(set) var captureConfigurations: [AudioCaptureConfiguration] = []
    private(set) var stopCaptureCount = 0
    private(set) var stopPlaybackCount = 0
    private(set) var rebuildCount = 0
    private var captureHandlers: [AudioCaptureFrameHandler] = []
    private var captureFailureHandlers: [AudioCaptureFailureHandler?] = []
    private var stopCaptureWaiters:
        [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func start() throws {}
    func stop() {}
    func configurePlayback(format: AudioStreamFormat) throws {}
    func configureVoiceProcessing(
        _ policy: AudioVoiceProcessingPolicy
    ) throws {}
    func schedulePlayback(
        _ frame: AudioFrame,
        owner: AudioDevicePlaybackOwner
    ) async throws {}
    func setOutputMuted(_ muted: Bool) {}

    func startCapture(
        configuration: AudioCaptureConfiguration,
        onFrame: @escaping AudioCaptureFrameHandler,
        onFailure: AudioCaptureFailureHandler?
    ) throws {
        captureConfigurations.append(configuration)
        captureHandlers.append(onFrame)
        captureFailureHandlers.append(onFailure)
        startGate.blockFirstStart()
    }

    func stopCapture() {
        stopCaptureCount += 1
        let ready = stopCaptureWaiters.filter { $0.target <= stopCaptureCount }
        stopCaptureWaiters.removeAll { $0.target <= stopCaptureCount }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func stopPlayback(owner: AudioDevicePlaybackOwner?) {
        stopPlaybackCount += 1
    }

    func rebuildAfterMediaServicesReset() {
        rebuildCount += 1
    }

    func deliverCapture(_ frame: AudioFrame, at index: Int) async throws {
        try await captureHandlers[index](frame)
    }

    func failCapture(at index: Int, error: any Error) async {
        await captureFailureHandlers[index]?(error)
    }

    func waitUntilStopCaptureCount(_ target: Int) async {
        guard stopCaptureCount < target else { return }
        await withCheckedContinuation { continuation in
            stopCaptureWaiters.append((target, continuation))
        }
    }

    nonisolated func waitUntilFirstStartIsBlocked() async -> Bool {
        await startGate.waitUntilFirstStartIsBlocked()
    }

    nonisolated func releaseFirstStart() {
        startGate.releaseFirstStart()
    }
}

private actor SessionFirstStartAttemptGate {
    private var attemptCount = 0
    private var firstAttemptIsSuspended = false
    private var firstAttemptWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func suspendFirstAttempt() async {
        attemptCount += 1
        guard attemptCount == 1 else { return }
        firstAttemptIsSuspended = true
        let waiters = firstAttemptWaiters
        firstAttemptWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilFirstAttemptIsSuspended() async {
        guard !firstAttemptIsSuspended else { return }
        await withCheckedContinuation { continuation in
            firstAttemptWaiters.append(continuation)
        }
    }

    func resumeFirstAttempt() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SessionCompletionProbe {
    private(set) var isComplete = false

    func complete() {
        isComplete = true
    }
}

private final class SessionStopWaitObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiters: [
        (target: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    func record() {
        let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
            count += 1
            let ready = waiters
                .filter { $0.target <= count }
                .map(\.continuation)
            waiters.removeAll { $0.target <= count }
            return ready
        }
        for continuation in ready {
            continuation.resume()
        }
    }

    func waitUntilCount(_ target: Int) async {
        await withCheckedContinuation { continuation in
            let isAlreadyObserved: Bool = lock.withLock {
                guard count < target else { return true }
                waiters.append((target, continuation))
                return false
            }
            if isAlreadyObserved {
                continuation.resume()
            }
        }
    }
}

private final class SessionProcessorResetRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var resetCount = 0

    var count: Int {
        lock.withLock { resetCount }
    }

    func recordReset() {
        lock.withLock {
            resetCount += 1
        }
    }
}

@MainActor
private final class SessionSafetyAudioSession: AudioSessionControlling {
    let routeSnapshot = AudioRouteSnapshot.empty

    func activate(_ profile: AudioSessionProfile) throws {}
    func deactivate() throws {}
    func selectPrivateAccessoryInput(id: String) throws -> Bool { false }
}

@MainActor
private final class SessionSafetyDeviceEventSink: AudioDeviceEventSink {
    private var events: [AudioDeviceEvent] = []

    func receive(_ event: AudioDeviceEvent) async {
        events.append(event)
    }

    func values() -> [AudioDeviceEvent] {
        events
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

private actor SessionSourceFanOutGate {
    private var isSuspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private struct SessionFailingSender: AudioFrameSender {
    func send(_ frame: AudioFrame) async throws {
        throw SessionSenderError.failed
    }
}

private actor SessionFailOnceSender: AudioFrameSender {
    private var hasFailed = false
    private var acceptedFrames: [AudioFrame] = []

    func send(_ frame: AudioFrame) async throws {
        guard hasFailed else {
            hasFailed = true
            throw SessionSenderError.failed
        }
        acceptedFrames.append(frame)
    }

    func values() -> [AudioFrame] {
        acceptedFrames
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

private let sessionProcessorBudget = AudioProcessorBudget(
    maximumAlgorithmicWindow: .milliseconds(40),
    maximumInternalBufferDuration: .milliseconds(80),
    maximumOutputFrameCountPerInput: 4,
    maximumProcessingDuration: .seconds(1)
)

private func makeSessionProcessorChain(
    _ processors: [any AudioFrameProcessor]
) throws -> AudioFrameProcessorChain {
    try AudioFrameProcessorChain(
        processors: processors,
        budget: sessionProcessorBudget
    )
}

private struct SessionDropOrDuplicateProcessor: AudioFrameProcessor {
    let declaration = AudioFrameProcessorDeclaration(
        algorithmicWindow: .zero,
        maximumInternalBufferDuration: .zero,
        maximumOutputFrameCount: 2,
        formatBehavior: .preservesInput,
        retainsSensitiveState: false
    )

    mutating func process(
        _ frame: AudioFrame,
        emit: @Sendable (AudioFrame) -> Void
    ) throws {
        guard frame.sequence != 0 else { return }
        emit(frame)
        emit(try AudioFrame(
            flowID: frame.flowID,
            sequence: frame.sequence + 100,
            timestamp: frame.timestamp,
            format: frame.format,
            payload: frame.payload,
            duration: frame.duration
        ))
    }

    mutating func reset() {}
}

private struct SessionFirstFramePerGenerationProcessor: AudioFrameProcessor {
    let declaration = AudioFrameProcessorDeclaration(
        algorithmicWindow: .zero,
        maximumInternalBufferDuration: .zero,
        maximumOutputFrameCount: 1,
        formatBehavior: .preservesInput,
        retainsSensitiveState: true
    )
    private let resetRecorder: SessionProcessorResetRecorder
    private var hasEmittedFrame = false

    init(resetRecorder: SessionProcessorResetRecorder) {
        self.resetRecorder = resetRecorder
    }

    mutating func process(
        _ frame: AudioFrame,
        emit: @Sendable (AudioFrame) -> Void
    ) throws {
        guard !hasEmittedFrame else { return }
        hasEmittedFrame = true
        emit(frame)
    }

    mutating func reset() {
        hasEmittedFrame = false
        resetRecorder.recordReset()
    }
}

private struct SessionFailingProcessor: AudioFrameProcessor {
    let declaration = AudioFrameProcessorDeclaration(
        algorithmicWindow: .zero,
        maximumInternalBufferDuration: .zero,
        maximumOutputFrameCount: 1,
        formatBehavior: .preservesInput,
        retainsSensitiveState: false
    )

    mutating func process(
        _ frame: AudioFrame,
        emit: @Sendable (AudioFrame) -> Void
    ) throws {
        throw SessionProcessorError.failed
    }

    mutating func reset() {}
}

private struct SessionUndeclaredFormatProcessor: AudioFrameProcessor {
    let declaration = AudioFrameProcessorDeclaration(
        algorithmicWindow: .zero,
        maximumInternalBufferDuration: .zero,
        maximumOutputFrameCount: 1,
        formatBehavior: .preservesInput,
        retainsSensitiveState: false
    )

    mutating func process(
        _ frame: AudioFrame,
        emit: @Sendable (AudioFrame) -> Void
    ) throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 16_000)
        emit(try AudioFrame(
            flowID: frame.flowID,
            sequence: frame.sequence,
            timestamp: frame.timestamp,
            format: format,
            payload: Data(count: 640),
            duration: frame.duration
        ))
    }

    mutating func reset() {}
}

private struct SessionPairFormatProcessor: AudioFrameProcessor {
    let declaration: AudioFrameProcessorDeclaration
    private let outputFormat: AudioStreamFormat
    private var hasBufferedFrame = false

    init(outputFormat: AudioStreamFormat) {
        self.outputFormat = outputFormat
        declaration = AudioFrameProcessorDeclaration(
            algorithmicWindow: .milliseconds(40),
            maximumInternalBufferDuration: .milliseconds(20),
            maximumOutputFrameCount: 1,
            formatBehavior: .changesTo(outputFormat),
            retainsSensitiveState: true
        )
    }

    mutating func process(
        _ frame: AudioFrame,
        emit: @Sendable (AudioFrame) -> Void
    ) throws {
        guard hasBufferedFrame else {
            hasBufferedFrame = true
            return
        }
        hasBufferedFrame = false
        emit(try AudioFrame(
            flowID: frame.flowID,
            sequence: frame.sequence,
            timestamp: frame.timestamp,
            format: outputFormat,
            payload: Data(count: 640),
            duration: frame.duration
        ))
    }

    mutating func reset() {
        hasBufferedFrame = false
    }
}

private enum SessionProcessorError: Error {
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

private final class SessionRecoveryStopEventSink:
    AudioEventSink,
    @unchecked Sendable
{
    private let lock = NSLock()
    private weak var session: AudioPipelineSession?
    private var events: [AudioEvent] = []
    private var recoveryStopTask: Task<Void, Never>?
    private var recoveryStopComplete = false
    private var hasSuspendedTerminalDelivery = false
    private var terminalDelivery: CheckedContinuation<Void, Never>?

    func attach(session: AudioPipelineSession) {
        lock.withLock {
            self.session = session
        }
    }

    func receive(_ event: AudioEvent) async {
        let shouldSpawnStop: Bool = lock.withLock {
            events.append(event)
            guard case .endpointFailed = event else { return false }
            return recoveryStopTask == nil
        }
        if shouldSpawnStop {
            let session = lock.withLock { self.session }
            let task = Task { [weak self, weak session] in
                await session?.stop()
                self?.recordRecoveryStopComplete()
            }
            lock.withLock {
                recoveryStopTask = task
            }
        }
        let shouldSuspendTerminal: Bool = lock.withLock {
            guard case .flowStopped = event,
                  !hasSuspendedTerminalDelivery
            else {
                return false
            }
            hasSuspendedTerminalDelivery = true
            return true
        }
        guard shouldSuspendTerminal else { return }
        await withCheckedContinuation { continuation in
            lock.withLock {
                terminalDelivery = continuation
            }
        }
    }

    func values() -> [AudioEvent] {
        lock.withLock { events }
    }

    func isRecoveryStopComplete() -> Bool {
        lock.withLock { recoveryStopComplete }
    }

    func isTerminalDeliverySuspended() -> Bool {
        lock.withLock { terminalDelivery != nil }
    }

    func resumeTerminalDelivery() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            let continuation = terminalDelivery
            terminalDelivery = nil
            return continuation
        }
        continuation?.resume()
    }

    func waitForRecoveryStop() async {
        let task = lock.withLock { recoveryStopTask }
        await task?.value
    }

    private func recordRecoveryStopComplete() {
        lock.withLock {
            recoveryStopComplete = true
        }
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
