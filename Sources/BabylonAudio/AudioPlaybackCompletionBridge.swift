@available(iOS 18, macOS 13, *)
final class AudioPlaybackCompletionBridge: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    /// Called by the AVAudioPlayerNode data-consumed completion callback.
    /// This method is non-suspending and performs no task creation or I/O.
    func consumed() {
        _ = continuation.yield(())
        continuation.finish()
    }

    func cancel() {
        continuation.finish()
    }

    func waitUntilConsumed() async -> Bool {
        await withTaskCancellationHandler {
            for await _ in stream {
                return true
            }
            return false
        } onCancel: {
            cancel()
        }
    }
}
