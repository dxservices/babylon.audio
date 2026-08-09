@available(iOS 18, macOS 13, *)
public protocol AudioFrameSource: Sendable {
    func frames(
        for flowID: AudioFlowID
    ) -> AsyncThrowingStream<AudioFrame, any Error>
}

@available(iOS 18, macOS 13, *)
public protocol AudioFrameSink: Sendable {
    func consume(_ frame: AudioFrame) async throws
}

@available(iOS 18, macOS 13, *)
public protocol AudioFrameSender: Sendable {
    /// Returns after the adapter accepts the frame, not after a remote endpoint processes it.
    func send(_ frame: AudioFrame) async throws
}

@available(iOS 18, macOS 13, *)
public protocol AudioFrameReceiver: Sendable {
    func frames(
        for flowID: AudioFlowID
    ) -> AsyncThrowingStream<AudioFrame, any Error>
}
