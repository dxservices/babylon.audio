import Foundation

@available(iOS 18, macOS 13, *)
public enum AudioDeviceEngineError: Error, Equatable, Sendable {
    case unsafeRoute
    case invalidCaptureConfiguration
    case engineNotRunning
    case captureAlreadyRunning
    case captureHardwareBufferLimitExceeded
    case captureBufferLayoutMismatch
    case captureHandoffOverflow
    case engineAlreadyRunning
    case playbackNotConfigured
    case playbackFormatMismatch
    case invalidPlaybackBuffer
    case playbackStopped
}

@available(iOS 18, macOS 13, *)
public struct AudioCaptureSettings: Equatable, Sendable {
    public let format: AudioStreamFormat
    public let frameDuration: Duration
    public let maximumBufferedDuration: Duration
    public let maximumFramesPerCallback: Int
    public let maximumPendingCallbackCount: Int

    public init(
        format: AudioStreamFormat,
        frameDuration: Duration,
        maximumBufferedDuration: Duration,
        maximumFramesPerCallback: Int,
        maximumPendingCallbackCount: Int
    ) throws {
        guard maximumPendingCallbackCount > 0 else {
            throw AudioDeviceEngineError.invalidCaptureConfiguration
        }
        do {
            _ = try AudioFrameAssembler(
                flowID: AudioFlowID(),
                format: format,
                frameDuration: frameDuration,
                maximumBufferedDuration: maximumBufferedDuration,
                maximumFramesPerAppend: maximumFramesPerCallback
            )
        } catch {
            throw AudioDeviceEngineError.invalidCaptureConfiguration
        }

        guard let frameCapacity = Self.frameCapacity(
            duration: frameDuration,
            sampleRate: format.sampleRate
        ), let maximumCallbackFrameCapacity = Self.frameCapacity(
            duration: maximumBufferedDuration,
            sampleRate: format.sampleRate
        ) else {
            throw AudioDeviceEngineError.invalidCaptureConfiguration
        }
        let requiredFramesPerCallback =
            (UInt64(maximumCallbackFrameCapacity) + UInt64(frameCapacity) - 1)
            / UInt64(frameCapacity)
        guard UInt64(maximumFramesPerCallback) >= requiredFramesPerCallback else {
            throw AudioDeviceEngineError.invalidCaptureConfiguration
        }

        self.format = format
        self.frameDuration = frameDuration
        self.maximumBufferedDuration = maximumBufferedDuration
        self.maximumFramesPerCallback = maximumFramesPerCallback
        self.maximumPendingCallbackCount = maximumPendingCallbackCount
    }

    func resolve(flowID: AudioFlowID) -> AudioCaptureConfiguration {
        AudioCaptureConfiguration(flowID: flowID, settings: self)
    }

    fileprivate static func frameCapacity(
        duration: Duration,
        sampleRate: Double
    ) -> UInt32? {
        let components = duration.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1e18
        let exactCapacity = seconds * sampleRate
        let roundedCapacity = exactCapacity.rounded()
        guard roundedCapacity > 0,
              abs(exactCapacity - roundedCapacity) < 1e-7,
              roundedCapacity <= Double(UInt32.max)
        else {
            return nil
        }
        return UInt32(roundedCapacity)
    }
}

@available(iOS 18, macOS 13, *)
public struct AudioCaptureConfiguration: Equatable, Sendable {
    public let flowID: AudioFlowID
    public let format: AudioStreamFormat
    public let frameDuration: Duration
    public let maximumBufferedDuration: Duration
    public let maximumFramesPerCallback: Int
    public let maximumPendingCallbackCount: Int

    public init(flowID: AudioFlowID, settings: AudioCaptureSettings) {
        self.flowID = flowID
        format = settings.format
        frameDuration = settings.frameDuration
        maximumBufferedDuration = settings.maximumBufferedDuration
        maximumFramesPerCallback = settings.maximumFramesPerCallback
        maximumPendingCallbackCount = settings.maximumPendingCallbackCount
    }

    public init(
        flowID: AudioFlowID,
        format: AudioStreamFormat,
        frameDuration: Duration,
        maximumBufferedDuration: Duration,
        maximumFramesPerCallback: Int,
        maximumPendingCallbackCount: Int
    ) throws {
        self.init(
            flowID: flowID,
            settings: try AudioCaptureSettings(
                format: format,
                frameDuration: frameDuration,
                maximumBufferedDuration: maximumBufferedDuration,
                maximumFramesPerCallback: maximumFramesPerCallback,
                maximumPendingCallbackCount: maximumPendingCallbackCount
            )
        )
    }

    func tapBufferFrameCapacity(sampleRate: Double) -> UInt32? {
        AudioCaptureSettings.frameCapacity(
            duration: frameDuration,
            sampleRate: sampleRate
        )
    }

    func maximumCallbackFrameCapacity(sampleRate: Double) -> UInt32? {
        AudioCaptureSettings.frameCapacity(
            duration: maximumBufferedDuration,
            sampleRate: sampleRate
        )
    }
}

@available(iOS 18, macOS 13, *)
public typealias AudioCaptureFrameHandler =
    @Sendable (_ frame: AudioFrame) async throws -> Void

@available(iOS 18, macOS 13, *)
public typealias AudioCaptureFailureHandler =
    @Sendable (_ error: any Error) async -> Void

@available(iOS 18, macOS 13, *)
struct AudioDeviceCaptureToken: Equatable, Sendable {
    fileprivate let id: UUID

    fileprivate init() {
        id = UUID()
    }
}

@available(iOS 18, macOS 13, *)
@MainActor
protocol AudioDeviceEngineBackend: AnyObject {
    func start() throws
    func stop()
    func configurePlayback(format: AudioStreamFormat) throws
    func configureVoiceProcessing(
        _ policy: AudioVoiceProcessingPolicy
    ) throws
    func schedulePlayback(_ frame: AudioFrame) async throws
    func setOutputMuted(_ muted: Bool)
    func startCapture(
        configuration: AudioCaptureConfiguration,
        onFrame: @escaping AudioCaptureFrameHandler,
        onFailure: AudioCaptureFailureHandler?
    ) throws
    func stopCapture()
    func stopPlayback()
    func rebuildAfterMediaServicesReset()
}

@available(iOS 18, macOS 13, *)
@MainActor
public final class AudioDeviceEngine:
    AudioHardwareSafetyControlling,
    AudioFrameSink
{
    public private(set) var isRunning = false
    public private(set) var isOutputMuted = true
    public private(set) var isCapturing = false
    public private(set) var playbackFormat: AudioStreamFormat?
    public private(set) var voiceProcessingPolicy:
        AudioVoiceProcessingPolicy = .disabled

    private let backend: any AudioDeviceEngineBackend
    private var activeCaptureToken: AudioDeviceCaptureToken?

    init(backend: any AudioDeviceEngineBackend) {
        self.backend = backend
    }

    public func start() throws {
        guard !isRunning else { return }
        try backend.start()
        isRunning = true
    }

    public func configurePlayback(format: AudioStreamFormat) throws {
        guard !isRunning else {
            throw AudioDeviceEngineError.engineAlreadyRunning
        }
        try backend.configurePlayback(format: format)
        playbackFormat = format
    }

    public func configureVoiceProcessing(
        _ policy: AudioVoiceProcessingPolicy
    ) throws {
        guard !isRunning else {
            throw AudioDeviceEngineError.engineAlreadyRunning
        }
        try backend.configureVoiceProcessing(policy)
        voiceProcessingPolicy = policy
    }

    public func consume(_ frame: AudioFrame) async throws {
        guard isRunning else {
            throw AudioDeviceEngineError.engineNotRunning
        }
        guard let playbackFormat else {
            throw AudioDeviceEngineError.playbackNotConfigured
        }
        guard frame.format == playbackFormat else {
            throw AudioDeviceEngineError.playbackFormatMismatch
        }
        try await backend.schedulePlayback(frame)
    }

    public func stop() {
        guard isRunning else { return }
        muteOutput()
        backend.stop()
        activeCaptureToken = nil
        isCapturing = false
        isRunning = false
    }

    public func startCapture(
        configuration: AudioCaptureConfiguration,
        onFrame: @escaping AudioCaptureFrameHandler,
        onFailure: AudioCaptureFailureHandler? = nil
    ) throws {
        _ = try startCaptureOwned(
            configuration: configuration,
            onFrame: onFrame,
            onFailure: onFailure
        )
    }

    @discardableResult
    func startCaptureOwned(
        configuration: AudioCaptureConfiguration,
        onFrame: @escaping AudioCaptureFrameHandler,
        onFailure: AudioCaptureFailureHandler? = nil
    ) throws -> AudioDeviceCaptureToken {
        guard isRunning else {
            throw AudioDeviceEngineError.engineNotRunning
        }
        guard !isCapturing else {
            throw AudioDeviceEngineError.captureAlreadyRunning
        }
        let token = AudioDeviceCaptureToken()
        let stateAwareFailureHandler: AudioCaptureFailureHandler = {
            [weak self, token] error in
            guard await self?.captureDidFail(token: token) == true else {
                return
            }
            await onFailure?(error)
        }
        try backend.startCapture(
            configuration: configuration,
            onFrame: onFrame,
            onFailure: stateAwareFailureHandler
        )
        activeCaptureToken = token
        isCapturing = true
        return token
    }

    public func unmuteOutput(
        after safety: AudioRouteSafetyEvaluation,
        permit: AudioSafetyConfigurationPermit
    ) throws {
        try permit.validate()
        try unmuteOutput(after: safety)
    }

    func unmuteOutput(
        after safety: AudioRouteSafetyEvaluation
    ) throws {
        guard case .safe = safety else {
            throw AudioDeviceEngineError.unsafeRoute
        }
        guard isOutputMuted else { return }
        backend.setOutputMuted(false)
        isOutputMuted = false
    }

    public func muteOutput() {
        guard !isOutputMuted else { return }
        backend.setOutputMuted(true)
        isOutputMuted = true
    }

    public func stopCapture() {
        activeCaptureToken = nil
        backend.stopCapture()
        isCapturing = false
    }

    func stopCapture(token: AudioDeviceCaptureToken) {
        guard activeCaptureToken == token else { return }
        stopCapture()
    }

    public func stopPlayback() {
        backend.stopPlayback()
    }

    /// Replaces the graph invalidated by `mediaServicesWereReset`.
    ///
    /// `AudioSafetyCoordinator` calls this only after latching output closed,
    /// stopping both data-plane sides, discarding queues, and deactivating the
    /// session. The consumer must configure and start the fresh graph again.
    public func rebuildAfterMediaServicesReset() {
        backend.rebuildAfterMediaServicesReset()
        isRunning = false
        isOutputMuted = true
        isCapturing = false
        activeCaptureToken = nil
        playbackFormat = nil
        voiceProcessingPolicy = .disabled
    }

    private func captureDidFail(token: AudioDeviceCaptureToken) -> Bool {
        guard activeCaptureToken == token else { return false }
        activeCaptureToken = nil
        isCapturing = false
        return true
    }
}

#if os(iOS)
import AVFAudio

@available(iOS 18, *)
public extension AudioDeviceEngine {
    convenience init() {
        self.init(backend: AVAudioDeviceEngineBackend())
    }
}

@available(iOS 18, *)
@MainActor
private final class AVAudioDeviceEngineBackend: AudioDeviceEngineBackend {
    private var engine: AVAudioEngine
    private var playerNode: AVAudioPlayerNode
    private var playbackFormat: AudioStreamFormat?
    private var playbackAVFormat: AVAudioFormat?
    /// Monotonic across graph rebuilds so late completions cannot collide.
    private var nextPlaybackID: UInt64 = 0
    private var playbackCompletions:
        [UInt64: AudioPlaybackCompletionBridge] = [:]
    private var captureTapInstalled = false
    private var captureBridge: BoundedAudioCaptureBridge?
    private var captureTask: Task<Void, Never>?

    init() {
        let graph = Self.makeGraph()
        engine = graph.engine
        playerNode = graph.playerNode
    }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func stop() {
        stopCapture()
        stopPlayback()
        engine.stop()
    }

    func configurePlayback(format: AudioStreamFormat) throws {
        guard !engine.isRunning,
              let avFormat = Self.makeAVAudioFormat(format)
        else {
            throw AudioDeviceEngineError.invalidPlaybackBuffer
        }
        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: avFormat)
        playbackFormat = format
        playbackAVFormat = avFormat
    }

    func configureVoiceProcessing(
        _ policy: AudioVoiceProcessingPolicy
    ) throws {
        guard !engine.isRunning else {
            throw AudioDeviceEngineError.engineAlreadyRunning
        }
        try engine.inputNode.setVoiceProcessingEnabled(policy != .disabled)
    }

    func schedulePlayback(_ frame: AudioFrame) async throws {
        guard frame.format == playbackFormat,
              let playbackAVFormat,
              let buffer = try? Self.makePlaybackBuffer(
                frame: frame,
                format: playbackAVFormat
              ),
              nextPlaybackID < UInt64.max
        else {
            throw AudioDeviceEngineError.invalidPlaybackBuffer
        }

        let playbackID = nextPlaybackID
        nextPlaybackID += 1
        let completion = AudioPlaybackCompletionBridge()
        playbackCompletions[playbackID] = completion
        playerNode.scheduleBuffer(
            buffer,
            completionCallbackType: .dataConsumed
        ) { _ in
            completion.consumed()
        }
        if playerNode.volume > 0, engine.isRunning, !playerNode.isPlaying {
            playerNode.play()
        }

        let consumed = await completion.waitUntilConsumed()
        playbackCompletions.removeValue(forKey: playbackID)
        if Task.isCancelled {
            throw CancellationError()
        }
        guard consumed else {
            throw AudioDeviceEngineError.playbackStopped
        }
    }

    func setOutputMuted(_ muted: Bool) {
        playerNode.volume = muted ? 0 : 1
        if !muted, engine.isRunning, !playerNode.isPlaying {
            playerNode.play()
        }
    }

    func startCapture(
        configuration: AudioCaptureConfiguration,
        onFrame: @escaping AudioCaptureFrameHandler,
        onFailure: AudioCaptureFailureHandler?
    ) throws {
        guard !captureTapInstalled else {
            throw AudioDeviceEngineError.captureAlreadyRunning
        }
        let tapFormat = engine.inputNode.outputFormat(forBus: 0)
        guard let captureFormat = Self.makeAudioStreamFormat(tapFormat),
              let tapBufferFrameCapacity = configuration.tapBufferFrameCapacity(
                sampleRate: captureFormat.sampleRate
              ),
              let maximumCallbackFrameCapacity =
                configuration.maximumCallbackFrameCapacity(
                    sampleRate: captureFormat.sampleRate
                ),
              let initialAssembler = try? AudioFrameAssembler(
                flowID: configuration.flowID,
                format: captureFormat,
                frameDuration: configuration.frameDuration,
                maximumBufferedDuration: configuration.maximumBufferedDuration,
                maximumFramesPerAppend: configuration.maximumFramesPerCallback
              ),
              let converter = try? PCMFrameConverter(
                outputFormat: configuration.format,
                maximumInputDuration: configuration.frameDuration
              )
        else {
            throw AudioDeviceEngineError.invalidCaptureConfiguration
        }

        let bridge = BoundedAudioCaptureBridge(
            capacity: configuration.maximumPendingCallbackCount
        )
        captureBridge = bridge
        captureTask = Task.detached(priority: .high) { [weak self] in
            do {
                var assembler = initialAssembler
                for await event in bridge.stream {
                    try Task.checkCancellation()
                    switch event {
                    case .chunk(let chunk):
                        for frame in try assembler.append(chunk.payload) {
                            try await onFrame(converter.convert(frame))
                        }
                    case .failure(let error):
                        throw error
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                let ownedFailure = await self?.stopCaptureAfterFailure(
                    bridge: bridge
                ) ?? false
                if ownedFailure {
                    await onFailure?(error)
                }
            }
        }

        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: tapBufferFrameCapacity,
            format: tapFormat
        ) { buffer, _ in
            guard buffer.frameLength <= maximumCallbackFrameCapacity else {
                bridge.fail(.captureHardwareBufferLimitExceeded)
                return
            }
            guard let payload = Self.copyPayload(
                from: buffer,
                format: captureFormat
            ) else {
                bridge.fail(.captureBufferLayoutMismatch)
                return
            }
            bridge.offer(AudioCaptureChunk(payload: payload))
        }
        captureTapInstalled = true
    }

    func stopCapture() {
        guard captureTapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        captureTapInstalled = false
        captureBridge?.finish()
        captureBridge = nil
        captureTask?.cancel()
        captureTask = nil
    }

    func stopPlayback() {
        let pending = Array(playbackCompletions.values)
        playbackCompletions.removeAll()
        for completion in pending {
            completion.cancel()
        }
        playerNode.stop()
    }

    func rebuildAfterMediaServicesReset() {
        stopCapture()
        stopPlayback()
        engine.stop()

        let graph = Self.makeGraph()
        engine = graph.engine
        playerNode = graph.playerNode
        playbackFormat = nil
        playbackAVFormat = nil
    }

    private func stopCaptureAfterFailure(
        bridge: BoundedAudioCaptureBridge
    ) -> Bool {
        guard captureBridge === bridge else { return false }
        stopCapture()
        return true
    }

    private static func makeGraph() -> (
        engine: AVAudioEngine,
        playerNode: AVAudioPlayerNode
    ) {
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        playerNode.volume = 0
        return (engine, playerNode)
    }

    private nonisolated static func makeAudioStreamFormat(
        _ format: AVAudioFormat
    ) -> AudioStreamFormat? {
        let encoding: SampleEncoding
        switch format.commonFormat {
        case .pcmFormatInt16:
            encoding = .signedPCM16LittleEndian
        case .pcmFormatFloat32:
            encoding = .float32
        default:
            return nil
        }
        return try? AudioStreamFormat(
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount),
            sampleEncoding: encoding,
            interleaving: format.isInterleaved ? .interleaved : .nonInterleaved
        )
    }

    private nonisolated static func makeAVAudioFormat(
        _ format: AudioStreamFormat
    ) -> AVAudioFormat? {
        let commonFormat: AVAudioCommonFormat
        switch format.sampleEncoding {
        case .signedPCM16LittleEndian:
            commonFormat = .pcmFormatInt16
        case .float32:
            commonFormat = .pcmFormatFloat32
        }
        return AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: format.sampleRate,
            channels: AVAudioChannelCount(format.channelCount),
            interleaved: format.interleaving == .interleaved
        )
    }

    private nonisolated static func makePlaybackBuffer(
        frame: AudioFrame,
        format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer? {
        let frameCount = frame.payload.count / frame.format.bytesPerFrame
        guard frameCount <= Int(AVAudioFrameCount.max),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
              )
        else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        try copyPlaybackPayload(
            frame.payload,
            to: buffer,
            format: frame.format
        )
        return buffer
    }

    private nonisolated static func copyPlaybackPayload(
        _ payload: Data,
        to buffer: AVAudioPCMBuffer,
        format: AudioStreamFormat
    ) throws {
        let audioBuffers = UnsafeMutableAudioBufferListPointer(
            buffer.mutableAudioBufferList
        )
        try payload.withUnsafeBytes { source in
            guard let sourceBaseAddress = source.baseAddress else {
                throw AudioDeviceEngineError.invalidPlaybackBuffer
            }
            switch format.interleaving {
            case .interleaved:
                guard audioBuffers.count == 1,
                      let destination = audioBuffers[0].mData,
                      payload.count <= Int(audioBuffers[0].mDataByteSize)
                else {
                    throw AudioDeviceEngineError.invalidPlaybackBuffer
                }
                destination.copyMemory(
                    from: sourceBaseAddress,
                    byteCount: payload.count
                )
            case .nonInterleaved:
                let bytesPerPlane = payload.count / format.channelCount
                guard audioBuffers.count == format.channelCount else {
                    throw AudioDeviceEngineError.invalidPlaybackBuffer
                }
                for channel in 0..<format.channelCount {
                    guard let destination = audioBuffers[channel].mData,
                          bytesPerPlane <= Int(
                            audioBuffers[channel].mDataByteSize
                          )
                    else {
                        throw AudioDeviceEngineError.invalidPlaybackBuffer
                    }
                    destination.copyMemory(
                        from: sourceBaseAddress.advanced(
                            by: channel * bytesPerPlane
                        ),
                        byteCount: bytesPerPlane
                    )
                }
            }
        }
    }

    private nonisolated static func copyPayload(
        from buffer: AVAudioPCMBuffer,
        format: AudioStreamFormat
    ) -> Data? {
        let audioBuffers = UnsafeMutableAudioBufferListPointer(
            buffer.mutableAudioBufferList
        )
        let bytesPerPlane = Int(buffer.frameLength) * format.bytesPerSample
        let expectedBufferCount = format.interleaving == .interleaved
            ? 1
            : format.channelCount
        guard audioBuffers.count == expectedBufferCount else { return nil }

        var payload = Data()
        payload.reserveCapacity(Int(buffer.frameLength) * format.bytesPerFrame)
        for audioBuffer in audioBuffers {
            let expectedByteCount = format.interleaving == .interleaved
                ? bytesPerPlane * format.channelCount
                : bytesPerPlane
            guard Int(audioBuffer.mDataByteSize) >= expectedByteCount,
                  let bytes = audioBuffer.mData
            else {
                return nil
            }
            payload.append(bytes.assumingMemoryBound(to: UInt8.self), count: expectedByteCount)
        }
        return payload
    }
}
#endif
