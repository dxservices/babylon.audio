import Foundation
import Testing
@testable import BabylonAudio

@Suite("Audio pipeline contracts")
struct AudioPipelineContractTests {
    @Test("A pipeline must contain at least one direction")
    func pipelineRequiresADirection() {
        #expect(throws: AudioContractError.noPipelineDirection) {
            try AudioPipelineConfiguration()
        }
    }

    @Test("Uplink and local monitor plans require a source")
    func sourceIsRequiredForSourceDrivenPlans() throws {
        let sender = RecordingSender()
        let sink = RecordingSink()

        #expect(throws: AudioContractError.sourceRequired) {
            try AudioPipelineConfiguration(uplinkSender: sender)
        }
        #expect(throws: AudioContractError.sourceRequired) {
            try AudioPipelineConfiguration(localMonitorSink: .external(sink))
        }
    }

    @Test("A source-side processor cannot be attached to a downlink-only plan")
    func processorRequiresASource() throws {
        let chain = try AudioFrameProcessorChain(
            processors: [],
            budget: .init(
                maximumAlgorithmicWindow: .zero,
                maximumInternalBufferDuration: .zero,
                maximumOutputFrameCountPerInput: 1,
                maximumProcessingDuration: .milliseconds(1)
            )
        )

        #expect(throws: AudioContractError.sourceRequired) {
            try AudioPipelineConfiguration(
                sourceProcessorChain: chain,
                downlinkReceiver: FixedReceiver(frames: []),
                downlinkSink: .external(RecordingSink())
            )
        }
    }

    @Test("External frames are modeled as a source, not a microphone policy")
    func externalFramesAreASource() throws {
        let sender = RecordingSender()
        let configuration = try AudioPipelineConfiguration(
            source: .externalFrames,
            uplinkSender: sender
        )

        if case .externalFrames = configuration.source {
            // Expected: the source itself expresses caller-provided frames.
        } else {
            Issue.record("Expected an external-frame source")
        }
    }

    @Test("Microphone policies are explicit microphone source choices")
    func microphonePoliciesAreSourceChoices() throws {
        let sender = RecordingSender()
        let capture = try AudioCaptureSettings(
            format: .monoPCM16(sampleRate: 24_000),
            frameDuration: .milliseconds(20),
            maximumBufferedDuration: .milliseconds(100),
            maximumFramesPerCallback: 8,
            maximumPendingCallbackCount: 4
        )
        let policies: [AudioInputPolicy] = [
            .builtInMicrophoneRequired,
            .preferBuiltInAllowPrivateAccessoryDuplex,
        ]

        for policy in policies {
            let configuration = try AudioPipelineConfiguration(
                source: .microphone(AudioMicrophoneSourceConfiguration(
                    inputPolicy: policy,
                    capture: capture
                )),
                uplinkSender: sender
            )
            guard case .microphone(let microphone) = configuration.source
            else {
                Issue.record("Expected an explicit microphone source")
                continue
            }
            #expect(microphone.inputPolicy == policy)
            #expect(microphone.capture == capture)
        }
    }

    @Test("No device output is modeled by omitting a sink")
    func noDeviceOutputIsAnAbsentSink() throws {
        let sender = RecordingSender()
        let configuration = try AudioPipelineConfiguration(
            source: .externalFrames,
            uplinkSender: sender
        )

        #expect(configuration.localMonitorSink == nil)
        #expect(configuration.downlinkSink == nil)
    }

    @Test("Device output requires the explicit private-output policy")
    func deviceOutputRequiresPrivatePolicy() throws {
        let configuration = try AudioPipelineConfiguration(
            source: .externalFrames,
            localMonitorSink: .device(policy: .privateOutputRequired)
        )

        guard case .device(let policy) = configuration.localMonitorSink else {
            Issue.record("Expected an explicit device sink")
            return
        }
        #expect(policy == .privateOutputRequired)
    }

    @Test("Downlink requires both a receiver and a sink")
    func downlinkRequiresReceiverAndSink() {
        let receiver = FixedReceiver(frames: [])
        let sink = RecordingSink()

        #expect(throws: AudioContractError.incompleteDownlink) {
            try AudioPipelineConfiguration(downlinkReceiver: receiver)
        }
        #expect(throws: AudioContractError.incompleteDownlink) {
            try AudioPipelineConfiguration(downlinkSink: .external(sink))
        }
    }

    @Test("Configuration keeps diagnostics caller-owned")
    func configurationRequiresInjectedDiagnostics() throws {
        let diagnostics = RecordingDiagnosticSink()
        let sender = RecordingSender()
        let configuration = try AudioPipelineConfiguration(
            source: .externalFrames,
            uplinkSender: sender,
            diagnosticSink: diagnostics
        )

        #expect(configuration.diagnosticSink != nil)
        requireSendable(configuration)
    }

    @Test("External source and sink use neutral frame contracts")
    func externalSourceAndSinkUseNeutralFrameContracts() async throws {
        let frame = try makeFrame()
        let source = FixedSource(frames: [frame])
        let sink = RecordingSink()
        let configuration = try AudioPipelineConfiguration(
            source: .external(source),
            localMonitorSink: .external(sink)
        )

        var receivedFrames: [AudioFrame] = []
        for try await receivedFrame in source.frames(for: frame.flowID) {
            receivedFrames.append(receivedFrame)
            try await sink.consume(receivedFrame)
        }

        #expect(receivedFrames == [frame])
        #expect(await sink.frames == [frame])
        requireSendable(configuration)
    }

    @Test("Content-free events and snapshots are Sendable values")
    func contentFreeObservabilityContractsAreSendable() throws {
        let flowID = AudioFlowID()
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let event = AudioEvent.flowStopped(flowID: flowID, reason: .consumerRequested)
        let diagnostic = AudioDiagnosticEvent.queueDiscarded(
            flowID: flowID,
            direction: .uplink,
            reason: .overflow,
            frameCount: 2,
            duration: .milliseconds(40)
        )
        let snapshot = AudioPipelineSnapshot(
            flowID: flowID,
            state: .running,
            sourceFormat: format,
            uplink: .init(frameCount: 1, duration: .milliseconds(20)),
            downlink: .zero,
            discardedFrameCount: 0
        )

        #expect(event == .flowStopped(flowID: flowID, reason: .consumerRequested))
        #expect(diagnostic == .queueDiscarded(
            flowID: flowID,
            direction: .uplink,
            reason: .overflow,
            frameCount: 2,
            duration: .milliseconds(40)
        ))
        #expect(snapshot.sourceFormat == format)
        requireSendable(event)
        requireSendable(diagnostic)
        requireSendable(snapshot)
    }

    private func makeFrame() throws -> AudioFrame {
        try AudioFrame(
            flowID: AudioFlowID(),
            sequence: 0,
            timestamp: .zero,
            format: .monoPCM16(sampleRate: 24_000),
            payload: Data(count: 960),
            duration: .milliseconds(20)
        )
    }
}

private actor RecordingSender: AudioFrameSender {
    private(set) var frames: [AudioFrame] = []

    func send(_ frame: AudioFrame) async throws {
        frames.append(frame)
    }
}

private actor RecordingSink: AudioFrameSink {
    private(set) var frames: [AudioFrame] = []

    func consume(_ frame: AudioFrame) async throws {
        frames.append(frame)
    }
}

private struct FixedReceiver: AudioFrameReceiver {
    let storedFrames: [AudioFrame]

    init(frames: [AudioFrame]) {
        storedFrames = frames
    }

    func frames(for flowID: AudioFlowID) -> AsyncThrowingStream<AudioFrame, any Error> {
        AsyncThrowingStream { continuation in
            for frame in storedFrames where frame.flowID == flowID {
                continuation.yield(frame)
            }
            continuation.finish()
        }
    }
}

private struct FixedSource: AudioFrameSource {
    let storedFrames: [AudioFrame]

    init(frames: [AudioFrame]) {
        storedFrames = frames
    }

    func frames(for flowID: AudioFlowID) -> AsyncThrowingStream<AudioFrame, any Error> {
        AsyncThrowingStream { continuation in
            for frame in storedFrames where frame.flowID == flowID {
                continuation.yield(frame)
            }
            continuation.finish()
        }
    }
}

private actor RecordingDiagnosticSink: AudioDiagnosticSink {
    private(set) var events: [AudioDiagnosticEvent] = []

    func record(_ event: AudioDiagnosticEvent) async {
        events.append(event)
    }
}

private func requireSendable<T: Sendable>(_: T) {}
