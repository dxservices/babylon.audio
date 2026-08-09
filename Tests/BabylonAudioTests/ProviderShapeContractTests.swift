import Foundation
import Testing
@testable import BabylonAudio

@Suite("Provider-shaped adapter fakes")
struct ProviderShapeContractTests {
    @Test("A 24 kHz PCM16 adapter uses the neutral sender contract")
    func openAIShapedAdapterCompilesAgainstNeutralContract() async throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let frame = try makeFrame(format: format, byteCount: 960)
        let adapter: any AudioFrameSender = OpenAIShapedSender(expectedFormat: format)

        try await adapter.send(frame)
    }

    @Test("A split-rate adapter uses neutral sender and receiver contracts")
    func googleShapedAdapterCompilesAgainstNeutralContracts() async throws {
        let uplinkFormat = try AudioStreamFormat.monoPCM16(sampleRate: 16_000)
        let downlinkFormat = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let uplinkFrame = try makeFrame(format: uplinkFormat, byteCount: 640)
        let downlinkFrame = try makeFrame(format: downlinkFormat, byteCount: 960)
        let adapter = GoogleShapedAdapter(
            expectedUplinkFormat: uplinkFormat,
            downlinkFrames: [downlinkFrame]
        )
        let sender: any AudioFrameSender = adapter
        let receiver: any AudioFrameReceiver = adapter

        try await sender.send(uplinkFrame)
        var receivedFrames: [AudioFrame] = []
        for try await frame in receiver.frames(for: downlinkFrame.flowID) {
            receivedFrames.append(frame)
        }

        #expect(receivedFrames == [downlinkFrame])
    }

    private func makeFrame(format: AudioStreamFormat, byteCount: Int) throws -> AudioFrame {
        try AudioFrame(
            flowID: AudioFlowID(),
            sequence: 0,
            timestamp: .zero,
            format: format,
            payload: Data(count: byteCount),
            duration: .milliseconds(20)
        )
    }
}

private actor OpenAIShapedSender: AudioFrameSender {
    let expectedFormat: AudioStreamFormat

    init(expectedFormat: AudioStreamFormat) {
        self.expectedFormat = expectedFormat
    }

    func send(_ frame: AudioFrame) async throws {
        guard frame.format == expectedFormat else {
            throw FakeAdapterError.unexpectedFormat
        }
    }
}

private actor GoogleShapedAdapter: AudioFrameSender, AudioFrameReceiver {
    let expectedUplinkFormat: AudioStreamFormat
    let downlinkFrames: [AudioFrame]

    init(expectedUplinkFormat: AudioStreamFormat, downlinkFrames: [AudioFrame]) {
        self.expectedUplinkFormat = expectedUplinkFormat
        self.downlinkFrames = downlinkFrames
    }

    func send(_ frame: AudioFrame) async throws {
        guard frame.format == expectedUplinkFormat else {
            throw FakeAdapterError.unexpectedFormat
        }
    }

    nonisolated func frames(
        for flowID: AudioFlowID
    ) -> AsyncThrowingStream<AudioFrame, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                let frames = self.downlinkFrames
                for frame in frames where frame.flowID == flowID {
                    continuation.yield(frame)
                }
                continuation.finish()
            }
        }
    }
}

private enum FakeAdapterError: Error {
    case unexpectedFormat
}
