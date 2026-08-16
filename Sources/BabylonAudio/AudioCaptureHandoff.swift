@available(iOS 18, macOS 13, *)
enum AudioCaptureHandoffOfferResult: Equatable, Sendable {
    case accepted
    case droppedOldest
    case terminated
}

/// A non-suspending, bounded bridge from a hardware callback to async work.
///
/// `offer` performs no task creation, logging, disk, network, or async work.
/// When full, the oldest callback value is discarded so capture cannot grow an
/// unbounded backlog behind a slow consumer.
@available(iOS 18, macOS 13, *)
final class BoundedAudioCaptureHandoff<Element: Sendable>: Sendable {
    let stream: AsyncStream<Element>

    private let continuation: AsyncStream<Element>.Continuation

    init(capacity: Int) {
        precondition(capacity > 0)
        let pair = AsyncStream.makeStream(
            of: Element.self,
            bufferingPolicy: .bufferingNewest(capacity)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func offer(_ element: sending Element) -> AudioCaptureHandoffOfferResult {
        switch continuation.yield(element) {
        case .enqueued:
            .accepted
        case .dropped:
            .droppedOldest
        case .terminated:
            .terminated
        @unknown default:
            .terminated
        }
    }

    func finish() {
        continuation.finish()
    }
}

@available(iOS 18, macOS 13, *)
struct AudioCaptureChunk: Equatable, Sendable {
    let payload: Data
}

@available(iOS 18, macOS 13, *)
enum AudioCaptureHandoffEvent: Equatable, Sendable {
    case chunk(AudioCaptureChunk)
    case failure(AudioDeviceEngineError)
}

/// Converts bounded-stream overflow into a content-free terminal failure.
@available(iOS 18, macOS 13, *)
final class BoundedAudioCaptureBridge: Sendable {
    let stream: AsyncStream<AudioCaptureHandoffEvent>

    private let handoff: BoundedAudioCaptureHandoff<AudioCaptureHandoffEvent>

    init(capacity: Int) {
        let handoff = BoundedAudioCaptureHandoff<AudioCaptureHandoffEvent>(
            capacity: capacity
        )
        self.handoff = handoff
        stream = handoff.stream
    }

    func offer(_ chunk: sending AudioCaptureChunk) {
        switch handoff.offer(.chunk(chunk)) {
        case .accepted, .terminated:
            return
        case .droppedOldest:
            fail(.captureHandoffOverflow)
        }
    }

    func fail(_ error: AudioDeviceEngineError) {
        _ = handoff.offer(.failure(error))
        handoff.finish()
    }

    func finish() {
        handoff.finish()
    }
}
import Foundation
