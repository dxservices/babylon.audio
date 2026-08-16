@available(iOS 18, macOS 13, *)
public enum AudioDeviceEngineError: Error, Equatable, Sendable {
    case unsafeRoute
    case invalidCaptureConfiguration
    case engineNotRunning
    case captureAlreadyRunning
    case captureHardwareBufferLimitExceeded
    case captureBufferLayoutMismatch
    case captureHandoffOverflow
}

@available(iOS 18, macOS 13, *)
public struct AudioCaptureConfiguration: Equatable, Sendable {
    public let flowID: AudioFlowID
    public let format: AudioStreamFormat
    public let frameDuration: Duration
    public let maximumBufferedDuration: Duration
    public let maximumFramesPerCallback: Int
    public let maximumPendingCallbackCount: Int

    public init(
        flowID: AudioFlowID,
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
                flowID: flowID,
                format: format,
                frameDuration: frameDuration,
                maximumBufferedDuration: maximumBufferedDuration,
                maximumFramesPerAppend: maximumFramesPerCallback
            )
        } catch {
            throw AudioDeviceEngineError.invalidCaptureConfiguration
        }

        guard Self.frameCapacity(
            duration: frameDuration,
            sampleRate: format.sampleRate
        ) != nil else {
            throw AudioDeviceEngineError.invalidCaptureConfiguration
        }

        self.flowID = flowID
        self.format = format
        self.frameDuration = frameDuration
        self.maximumBufferedDuration = maximumBufferedDuration
        self.maximumFramesPerCallback = maximumFramesPerCallback
        self.maximumPendingCallbackCount = maximumPendingCallbackCount
    }

    func tapBufferFrameCapacity(sampleRate: Double) -> UInt32? {
        Self.frameCapacity(duration: frameDuration, sampleRate: sampleRate)
    }

    func maximumCallbackFrameCapacity(sampleRate: Double) -> UInt32? {
        Self.frameCapacity(
            duration: maximumBufferedDuration,
            sampleRate: sampleRate
        )
    }

    private static func frameCapacity(
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
public typealias AudioCaptureFrameHandler =
    @Sendable (_ frame: AudioFrame) async throws -> Void

@available(iOS 18, macOS 13, *)
public typealias AudioCaptureFailureHandler =
    @Sendable (_ error: any Error) async -> Void

@available(iOS 18, macOS 13, *)
@MainActor
protocol AudioDeviceEngineBackend: AnyObject {
    func start() throws
    func stop()
    func setOutputMuted(_ muted: Bool)
    func startCapture(
        configuration: AudioCaptureConfiguration,
        onFrame: @escaping AudioCaptureFrameHandler,
        onFailure: AudioCaptureFailureHandler?
    ) throws
    func stopCapture()
    func stopPlayback()
}

@available(iOS 18, macOS 13, *)
@MainActor
public final class AudioDeviceEngine: AudioHardwareSafetyControlling {
    public private(set) var isRunning = false
    public private(set) var isOutputMuted = true
    public private(set) var isCapturing = false

    private let backend: any AudioDeviceEngineBackend

    init(backend: any AudioDeviceEngineBackend) {
        self.backend = backend
    }

    public func start() throws {
        guard !isRunning else { return }
        try backend.start()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        muteOutput()
        backend.stop()
        isCapturing = false
        isRunning = false
    }

    public func startCapture(
        configuration: AudioCaptureConfiguration,
        onFrame: @escaping AudioCaptureFrameHandler,
        onFailure: AudioCaptureFailureHandler? = nil
    ) throws {
        guard isRunning else {
            throw AudioDeviceEngineError.engineNotRunning
        }
        guard !isCapturing else {
            throw AudioDeviceEngineError.captureAlreadyRunning
        }
        let stateAwareFailureHandler: AudioCaptureFailureHandler = {
            [weak self] error in
            await self?.captureDidFail()
            await onFailure?(error)
        }
        try backend.startCapture(
            configuration: configuration,
            onFrame: onFrame,
            onFailure: stateAwareFailureHandler
        )
        isCapturing = true
    }

    public func unmuteOutput(
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
        backend.stopCapture()
        isCapturing = false
    }

    public func stopPlayback() {
        backend.stopPlayback()
    }

    private func captureDidFail() {
        isCapturing = false
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
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var captureTapInstalled = false
    private var captureBridge: BoundedAudioCaptureBridge?
    private var captureTask: Task<Void, Never>?

    init() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        playerNode.volume = 0
    }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func stop() {
        stopCapture()
        playerNode.stop()
        engine.stop()
    }

    func setOutputMuted(_ muted: Bool) {
        playerNode.volume = muted ? 0 : 1
        if muted {
            // Stopping also discards any buffers already scheduled to the node.
            playerNode.stop()
        } else if engine.isRunning, !playerNode.isPlaying {
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
                await self?.stopCaptureAfterFailure()
                await onFailure?(error)
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
        playerNode.stop()
    }

    private func stopCaptureAfterFailure() {
        stopCapture()
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
