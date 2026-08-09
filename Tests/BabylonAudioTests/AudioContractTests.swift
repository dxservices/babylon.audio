import Foundation
import Testing
@testable import BabylonAudio

@Suite("Audio data contracts")
struct AudioContractTests {
    @Test("Flow identifiers have stable value semantics")
    func flowIdentifiersHaveStableValueSemantics() {
        let rawValue = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let first = AudioFlowID(rawValue: rawValue)
        let second = AudioFlowID(rawValue: rawValue)

        #expect(first == second)
        #expect(first.rawValue == rawValue)
        requireSendable(first)
    }

    @Test("Formats expose validated PCM layout")
    func formatsExposeValidatedPCMLayout() throws {
        let providerUplink = try AudioStreamFormat(
            sampleRate: 24_000,
            channelCount: 1,
            sampleEncoding: .signedPCM16LittleEndian,
            interleaving: .interleaved
        )
        let deviceStereo = try AudioStreamFormat(
            sampleRate: 48_000,
            channelCount: 2,
            sampleEncoding: .float32,
            interleaving: .nonInterleaved
        )

        #expect(providerUplink.bytesPerSample == 2)
        #expect(providerUplink.bytesPerFrame == 2)
        #expect(deviceStereo.bytesPerSample == 4)
        #expect(deviceStereo.bytesPerFrame == 8)
        requireSendable(providerUplink)
    }

    @Test("Formats reject unsupported sample rates and channel counts")
    func formatsRejectUnsupportedValues() {
        #expect(throws: AudioContractError.unsupportedSampleRate(8_000)) {
            try AudioStreamFormat(
                sampleRate: 8_000,
                channelCount: 1,
                sampleEncoding: .signedPCM16LittleEndian,
                interleaving: .interleaved
            )
        }
        #expect(throws: AudioContractError.unsupportedChannelCount(3)) {
            try AudioStreamFormat(
                sampleRate: 24_000,
                channelCount: 3,
                sampleEncoding: .signedPCM16LittleEndian,
                interleaving: .interleaved
            )
        }
    }

    @Test("Frames validate payload alignment and duration")
    func framesValidatePayloadAndDuration() throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let flowID = AudioFlowID()

        #expect(throws: AudioContractError.emptyPayload) {
            try AudioFrame(
                flowID: flowID,
                sequence: 0,
                timestamp: .zero,
                format: format,
                payload: Data(),
                duration: .zero
            )
        }
        #expect(throws: AudioContractError.payloadNotFrameAligned(byteCount: 959, bytesPerFrame: 2)) {
            try AudioFrame(
                flowID: flowID,
                sequence: 0,
                timestamp: .zero,
                format: format,
                payload: Data(count: 959),
                duration: .milliseconds(20)
            )
        }
        #expect(throws: AudioContractError.durationMismatch(
            expected: .milliseconds(20),
            actual: .milliseconds(19)
        )) {
            try AudioFrame(
                flowID: flowID,
                sequence: 0,
                timestamp: .zero,
                format: format,
                payload: Data(count: 960),
                duration: .milliseconds(19)
            )
        }
        #expect(throws: AudioContractError.negativeTimestamp(.milliseconds(-1))) {
            try AudioFrame(
                flowID: flowID,
                sequence: 0,
                timestamp: .milliseconds(-1),
                format: format,
                payload: Data(count: 960),
                duration: .milliseconds(20)
            )
        }

        let frame = try AudioFrame(
            flowID: flowID,
            sequence: 7,
            timestamp: .seconds(1),
            format: format,
            payload: Data(count: 960),
            duration: .milliseconds(20)
        )

        #expect(frame.duration == .milliseconds(20))
        #expect(frame.sequence == 7)
        requireSendable(frame)
    }
}

private func requireSendable<T: Sendable>(_: T) {}
