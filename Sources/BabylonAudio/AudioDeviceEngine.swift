@available(iOS 18, macOS 13, *)
public enum AudioDeviceEngineError: Error, Equatable, Sendable {
    case unsafeRoute
}

@available(iOS 18, macOS 13, *)
@MainActor
protocol AudioDeviceEngineBackend: AnyObject {
    func start() throws
    func stop()
    func setOutputMuted(_ muted: Bool)
    func stopCapture()
    func stopPlayback()
}

@available(iOS 18, macOS 13, *)
@MainActor
public final class AudioDeviceEngine: AudioHardwareSafetyControlling {
    public private(set) var isRunning = false
    public private(set) var isOutputMuted = true

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
        isRunning = false
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
    }

    public func stopPlayback() {
        backend.stopPlayback()
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

    func stopCapture() {
        guard captureTapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        captureTapInstalled = false
    }

    func stopPlayback() {
        playerNode.stop()
    }
}
#endif
