import Foundation
import Testing
@testable import BabylonAudio

@Suite("Audio device engine")
@MainActor
struct AudioDeviceEngineTests {
    @Test("Voice processing is disabled by default and requires pre-start opt-in")
    func voiceProcessingRequiresExplicitPreStartOptIn() throws {
        let backend = RecordingDeviceEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)

        #expect(engine.voiceProcessingPolicy == .disabled)
        try engine.configureVoiceProcessing(
            .enabledForPrivateAccessoryDuplex
        )
        #expect(
            engine.voiceProcessingPolicy
                == .enabledForPrivateAccessoryDuplex
        )
        try engine.start()
        #expect(throws: AudioDeviceEngineError.engineAlreadyRunning) {
            try engine.configureVoiceProcessing(.disabled)
        }
        #expect(backend.actions == [
            .configureVoiceProcessing(.enabledForPrivateAccessoryDuplex),
            .start,
        ])
    }

    @Test("Playback format must be configured before the engine starts")
    func playbackConfigurationPrecedesEngineStart() async throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let backend = RecordingDeviceEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)
        try engine.start()

        #expect(throws: AudioDeviceEngineError.engineAlreadyRunning) {
            try engine.configurePlayback(format: format)
        }
        await #expect(throws: AudioDeviceEngineError.playbackNotConfigured) {
            try await engine.consume(makePlaybackFrame(format: format))
        }
    }

    @Test("Playback consume returns only after data-consumed completion")
    func playbackCompletesWhenDataIsConsumed() async throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let backend = RecordingDeviceEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)
        try engine.configurePlayback(format: format)
        try engine.start()
        let frame = try makePlaybackFrame(format: format)

        let consumption = Task {
            try await engine.consume(frame)
        }
        for _ in 0..<10 { await Task.yield() }

        #expect(backend.pendingPlaybackSequences == [frame.sequence])
        backend.completePlayback(sequence: frame.sequence)
        try await consumption.value
        #expect(backend.actions == [
            .configurePlayback(format),
            .start,
            .schedulePlayback(frame.sequence),
        ])
    }

    @Test("Muted startup keeps playback consumption pending until unmuted")
    func mutedStartupBackpressuresPlayback() async throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let backend = RecordingDeviceEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)
        try engine.configurePlayback(format: format)
        try engine.start()
        let frame = try makePlaybackFrame(format: format)
        let consumption = Task {
            try await engine.consume(frame)
        }
        for _ in 0..<10 { await Task.yield() }

        #expect(engine.isOutputMuted)
        #expect(backend.pendingPlaybackSequences == [frame.sequence])

        let output = AudioRoutePort(
            id: "wired",
            name: "Wired Headphones",
            kind: .wiredHeadphones
        )
        try engine.unmuteOutput(after: .safe(output: output))
        backend.completePlayback(sequence: frame.sequence)
        try await consumption.value
    }

    @Test("Stopping playback fails all pending consumption")
    func stopPlaybackFailsPendingConsumption() async throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let backend = RecordingDeviceEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)
        try engine.configurePlayback(format: format)
        try engine.start()
        let frame = try makePlaybackFrame(format: format)
        let consumption = Task {
            try await engine.consume(frame)
        }
        for _ in 0..<10 { await Task.yield() }

        engine.stopPlayback()

        do {
            try await consumption.value
            Issue.record("Expected pending playback to fail")
        } catch {
            #expect(error as? AudioDeviceEngineError == .playbackStopped)
        }
    }

    @Test("Global playback stop cancels every pending playback owner")
    func globalStopPlaybackCancelsAllOwners() async throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let backend = RecordingDeviceEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)
        try engine.configurePlayback(format: format)
        try engine.start()
        let firstFrame = try makePlaybackFrame(format: format, sequence: 70)
        let secondFrame = try makePlaybackFrame(format: format, sequence: 71)
        let firstToken = engine.makePlaybackToken()
        let secondToken = engine.makePlaybackToken()
        let firstConsumption = Task {
            try await engine.consume(firstFrame, token: firstToken)
        }
        let secondConsumption = Task {
            try await engine.consume(secondFrame, token: secondToken)
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(backend.pendingPlaybackSequences == [70, 71])

        engine.stopPlayback()

        await #expect(throws: AudioDeviceEngineError.playbackStopped) {
            try await firstConsumption.value
        }
        await #expect(throws: AudioDeviceEngineError.playbackStopped) {
            try await secondConsumption.value
        }
        #expect(backend.pendingPlaybackSequences.isEmpty)
    }

    @Test("Stopped playback owner rejects a late consume without affecting its replacement")
    func stoppedPlaybackOwnerCannotBeResurrected() async throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let backend = RecordingDeviceEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)
        try engine.configurePlayback(format: format)
        try engine.start()
        let staleFrame = try makePlaybackFrame(format: format, sequence: 80)
        let replacementFrame = try makePlaybackFrame(
            format: format,
            sequence: 81
        )
        let staleToken = engine.makePlaybackToken()
        let replacementToken = engine.makePlaybackToken()
        let suspension = PlaybackConsumeSuspension()

        let staleConsumption = Task { @MainActor in
            await suspension.suspend()
            try await engine.consume(staleFrame, token: staleToken)
        }
        await suspension.waitUntilSuspended()
        engine.stopPlayback(token: staleToken)

        let replacementConsumption = Task { @MainActor in
            try await engine.consume(
                replacementFrame,
                token: replacementToken
            )
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(backend.pendingPlaybackSequences == [81])

        suspension.resume()
        await #expect(throws: AudioDeviceEngineError.playbackStopped) {
            try await staleConsumption.value
        }
        #expect(backend.actions.filter {
            if case .schedulePlayback(80) = $0 { return true }
            return false
        }.isEmpty)

        backend.completePlayback(sequence: 81)
        try await replacementConsumption.value
    }

    @Test("Capture callback overflow becomes a visible bounded failure")
    func captureCallbackOverflowIsVisible() async {
        let bridge = BoundedAudioCaptureBridge(capacity: 2)

        bridge.offer(AudioCaptureChunk(payload: Data([0])))
        bridge.offer(AudioCaptureChunk(payload: Data([1])))
        bridge.offer(AudioCaptureChunk(payload: Data([2])))
        bridge.offer(AudioCaptureChunk(payload: Data([3])))

        var received: [AudioCaptureHandoffEvent] = []
        for await event in bridge.stream {
            received.append(event)
        }
        #expect(received == [
            .chunk(AudioCaptureChunk(payload: Data([2]))),
            .failure(.captureHandoffOverflow),
        ])
    }

    @Test("Hardware callbacks may use the configured buffered-duration bound")
    func hardwareCallbackUsesBufferedDurationBound() throws {
        let configuration = try makeCaptureConfiguration()

        #expect(configuration.tapBufferFrameCapacity(sampleRate: 48_000) == 960)
        #expect(configuration.maximumCallbackFrameCapacity(
            sampleRate: 48_000
        ) == 4_800)
    }

    @Test("Capture callback work bound must cover the buffered-duration bound")
    func captureCallbackWorkBoundMustBeConsistent() throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)

        #expect(throws: AudioDeviceEngineError.invalidCaptureConfiguration) {
            try AudioCaptureConfiguration(
                flowID: AudioFlowID(),
                format: format,
                frameDuration: .milliseconds(20),
                maximumBufferedDuration: .milliseconds(100),
                maximumFramesPerCallback: 4,
                maximumPendingCallbackCount: 4
            )
        }
    }

    @Test("Capture requires a running engine and has one active tap")
    func captureLifecycleIsExclusive() throws {
        let backend = RecordingDeviceEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)
        let configuration = try makeCaptureConfiguration()

        #expect(throws: AudioDeviceEngineError.engineNotRunning) {
            try engine.startCapture(configuration: configuration) { _ in }
        }

        try engine.start()
        try engine.startCapture(configuration: configuration) { _ in }
        #expect(engine.isCapturing)
        #expect(throws: AudioDeviceEngineError.captureAlreadyRunning) {
            try engine.startCapture(configuration: configuration) { _ in }
        }

        engine.stopCapture()
        #expect(!engine.isCapturing)
        #expect(backend.actions == [
            .start,
            .startCapture(configuration),
            .stopCapture,
        ])
    }

    @Test("Capture delivery failure clears the public capture state")
    func captureFailureClearsState() async throws {
        let backend = RecordingDeviceEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)
        try engine.start()
        try engine.startCapture(
            configuration: makeCaptureConfiguration(),
            onFrame: { _ in },
            onFailure: { _ in }
        )

        await backend.failCapture()

        #expect(!engine.isCapturing)
    }

    @Test("A stale capture failure cannot clear replacement capture state")
    func staleCaptureFailureCannotClearReplacementState() async throws {
        let backend = RecordingDeviceEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)
        let configuration = try makeCaptureConfiguration()
        let failures = DeviceEngineFailureCounter()
        try engine.start()
        try engine.startCapture(
            configuration: configuration,
            onFrame: { _ in },
            onFailure: { _ in await failures.increment() }
        )
        engine.stopCapture()
        try engine.startCapture(
            configuration: configuration,
            onFrame: { _ in },
            onFailure: { _ in await failures.increment() }
        )

        await backend.failCapture(at: 0)
        #expect(engine.isCapturing)
        #expect(await failures.value == 0)

        await backend.failCapture(at: 1)
        #expect(!engine.isCapturing)
        #expect(await failures.value == 1)
    }

    @Test("Output can only unmute after a safe route evaluation")
    func unmuteRequiresSafeRoute() throws {
        let backend = RecordingDeviceEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)
        let output = AudioRoutePort(
            id: "wired",
            name: "Wired Headphones",
            kind: .wiredHeadphones
        )

        #expect(throws: AudioDeviceEngineError.unsafeRoute) {
            try engine.unmuteOutput(
                after: .trustRequired(output: output)
            )
        }
        #expect(backend.actions.isEmpty)

        try engine.unmuteOutput(after: .safe(output: output))
        #expect(!engine.isOutputMuted)
        #expect(backend.actions == [.setOutputMuted(false)])
    }

    @Test("Safety controls mute and stop both sides of the shared engine")
    func safetyControlsStopSharedEngineSides() throws {
        let backend = RecordingDeviceEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)
        let output = AudioRoutePort(
            id: "wired",
            name: "Wired Headphones",
            kind: .wiredHeadphones
        )
        try engine.start()
        try engine.unmuteOutput(after: .safe(output: output))

        engine.muteOutput()
        engine.stopCapture()
        engine.stopPlayback()
        engine.stop()

        #expect(engine.isOutputMuted)
        #expect(!engine.isRunning)
        #expect(backend.actions == [
            .start,
            .setOutputMuted(false),
            .setOutputMuted(true),
            .stopCapture,
            .stopPlayback,
            .stop,
        ])
    }

    @Test("Media reset clears public state and rebuilds an unconfigured graph")
    func mediaResetRebuildsFreshGraph() async throws {
        let backend = RecordingDeviceEngineBackend()
        let engine = AudioDeviceEngine(backend: backend)
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let output = AudioRoutePort(
            id: "wired",
            name: "Wired Headphones",
            kind: .wiredHeadphones
        )
        try engine.configureVoiceProcessing(
            .enabledForPrivateAccessoryDuplex
        )
        try engine.configurePlayback(format: format)
        try engine.start()
        try engine.unmuteOutput(after: .safe(output: output))
        try engine.startCapture(
            configuration: makeCaptureConfiguration()
        ) { _ in }
        let consumption = Task {
            try await engine.consume(makePlaybackFrame(format: format))
        }
        for _ in 0..<10 { await Task.yield() }

        engine.rebuildAfterMediaServicesReset()

        do {
            try await consumption.value
            Issue.record("Expected reset to fail pending playback")
        } catch {
            #expect(error as? AudioDeviceEngineError == .playbackStopped)
        }
        #expect(!engine.isRunning)
        #expect(engine.isOutputMuted)
        #expect(!engine.isCapturing)
        #expect(engine.playbackFormat == nil)
        #expect(engine.voiceProcessingPolicy == .disabled)
        #expect(backend.actions.last == .rebuildMediaServicesGraph)

        try engine.configurePlayback(format: format)
        #expect(engine.playbackFormat == format)
        #expect(backend.actions.last == .configurePlayback(format))
    }

    private func makeCaptureConfiguration() throws -> AudioCaptureConfiguration {
        try AudioCaptureConfiguration(
            flowID: AudioFlowID(),
            format: .monoPCM16(sampleRate: 16_000),
            frameDuration: .milliseconds(20),
            maximumBufferedDuration: .milliseconds(100),
            maximumFramesPerCallback: 8,
            maximumPendingCallbackCount: 4
        )
    }

    private func makePlaybackFrame(
        format: AudioStreamFormat,
        sequence: UInt64 = 7
    ) throws -> AudioFrame {
        try AudioFrame(
            flowID: AudioFlowID(),
            sequence: sequence,
            timestamp: .zero,
            format: format,
            payload: Data(count: 960),
            duration: .milliseconds(20)
        )
    }
}

@MainActor
private final class RecordingDeviceEngineBackend: AudioDeviceEngineBackend {
    enum Action: Equatable {
        case start
        case stop
        case configurePlayback(AudioStreamFormat)
        case configureVoiceProcessing(AudioVoiceProcessingPolicy)
        case schedulePlayback(UInt64)
        case setOutputMuted(Bool)
        case startCapture(AudioCaptureConfiguration)
        case stopCapture
        case stopPlayback
        case rebuildMediaServicesGraph
    }

    private(set) var actions: [Action] = []
    private var captureFailureHandlers: [AudioCaptureFailureHandler?] = []
    private var playbackContinuations:
        [UInt64: CheckedContinuation<Void, any Error>] = [:]
    private var playbackOwners: [UInt64: AudioDevicePlaybackOwner] = [:]

    var pendingPlaybackSequences: [UInt64] {
        playbackContinuations.keys.sorted()
    }

    func start() throws {
        actions.append(.start)
    }

    func stop() {
        actions.append(.stop)
    }

    func setOutputMuted(_ muted: Bool) {
        actions.append(.setOutputMuted(muted))
    }

    func configurePlayback(format: AudioStreamFormat) throws {
        actions.append(.configurePlayback(format))
    }

    func configureVoiceProcessing(
        _ policy: AudioVoiceProcessingPolicy
    ) throws {
        actions.append(.configureVoiceProcessing(policy))
    }

    func schedulePlayback(
        _ frame: AudioFrame,
        owner: AudioDevicePlaybackOwner
    ) async throws {
        actions.append(.schedulePlayback(frame.sequence))
        try await withCheckedThrowingContinuation { continuation in
            playbackContinuations[frame.sequence] = continuation
            playbackOwners[frame.sequence] = owner
        }
    }

    func completePlayback(sequence: UInt64) {
        playbackOwners.removeValue(forKey: sequence)
        playbackContinuations.removeValue(forKey: sequence)?.resume()
    }

    func startCapture(
        configuration: AudioCaptureConfiguration,
        onFrame: @escaping AudioCaptureFrameHandler,
        onFailure: AudioCaptureFailureHandler?
    ) throws {
        actions.append(.startCapture(configuration))
        captureFailureHandlers.append(onFailure)
    }

    func failCapture() async {
        guard !captureFailureHandlers.isEmpty else { return }
        await failCapture(at: captureFailureHandlers.count - 1)
    }

    func failCapture(at index: Int) async {
        await captureFailureHandlers[index]?(DeviceEngineTestError.captureFailed)
    }

    func stopCapture() {
        actions.append(.stopCapture)
    }

    func stopPlayback(owner: AudioDevicePlaybackOwner?) {
        actions.append(.stopPlayback)
        let sequences = playbackContinuations.keys.filter {
            owner == nil || playbackOwners[$0] == owner
        }
        let pending = sequences.compactMap { sequence in
            playbackOwners.removeValue(forKey: sequence)
            return playbackContinuations.removeValue(forKey: sequence)
        }
        for continuation in pending {
            continuation.resume(throwing: AudioDeviceEngineError.playbackStopped)
        }
    }

    func rebuildAfterMediaServicesReset() {
        actions.append(.rebuildMediaServicesGraph)
        let pending = Array(playbackContinuations.values)
        playbackContinuations.removeAll()
        playbackOwners.removeAll()
        for continuation in pending {
            continuation.resume(throwing: AudioDeviceEngineError.playbackStopped)
        }
    }
}

@MainActor
private final class PlaybackConsumeSuspension {
    private var isSuspended = false
    private var suspendedWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        let waiters = suspendedWaiters
        suspendedWaiters.removeAll()
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
            suspendedWaiters.append(continuation)
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private enum DeviceEngineTestError: Error {
    case captureFailed
}

private actor DeviceEngineFailureCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
