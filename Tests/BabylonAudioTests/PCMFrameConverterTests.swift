import Foundation
import Testing
@testable import BabylonAudio

@Suite("PCM frame conversion")
struct PCMFrameConverterTests {
    @Test("All supported sample-rate pairs convert")
    func allSampleRatePairsConvert() throws {
        let sampleRates: [Double] = [16_000, 24_000, 44_100, 48_000]

        for inputRate in sampleRates {
            for outputRate in sampleRates {
                let input = try AudioStreamFormat.monoPCM16(sampleRate: inputRate)
                let output = try AudioStreamFormat.monoPCM16(sampleRate: outputRate)
                try verifyConversion(from: input, to: output)
            }
        }
    }

    @Test("Encoding, channels, and interleaving convert in both directions")
    func layoutAndEncodingConvert() throws {
        let monoPCM = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let stereoFloatPlanar = try AudioStreamFormat(
            sampleRate: 48_000,
            channelCount: 2,
            sampleEncoding: .float32,
            interleaving: .nonInterleaved
        )
        let stereoPCMInterleaved = try AudioStreamFormat(
            sampleRate: 44_100,
            channelCount: 2,
            sampleEncoding: .signedPCM16LittleEndian,
            interleaving: .interleaved
        )

        try verifyConversion(from: monoPCM, to: stereoFloatPlanar)
        try verifyConversion(from: stereoFloatPlanar, to: monoPCM)
        try verifyConversion(from: stereoPCMInterleaved, to: stereoFloatPlanar)
        try verifyConversion(from: stereoFloatPlanar, to: stereoPCMInterleaved)
    }

    @Test("Every supported format shape converts at every sample rate")
    func everySupportedFormatShapeConverts() throws {
        let canonical = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)

        for sampleRate in [16_000.0, 24_000.0, 44_100.0, 48_000.0] {
            for format in try formatShapes(sampleRate: sampleRate) {
                try verifyConversion(from: format, to: canonical)
                try verifyConversion(from: canonical, to: format)
            }
        }
    }

    @Test("Non-silent PCM samples survive encoding conversion")
    func nonSilentSamplesSurviveConversion() throws {
        let inputFormat = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let outputFormat = try AudioStreamFormat(
            sampleRate: 24_000,
            channelCount: 1,
            sampleEncoding: .float32,
            interleaving: .interleaved
        )
        var payload = Data()
        payload.reserveCapacity(480)
        for _ in 0..<240 {
            payload.append(0x00)
            payload.append(0x20)
        }
        let frame = try AudioFrame(
            flowID: AudioFlowID(),
            sequence: 0,
            timestamp: .zero,
            format: inputFormat,
            payload: payload,
            duration: .milliseconds(10)
        )
        let converted = try PCMFrameConverter(
            outputFormat: outputFormat,
            maximumInputDuration: .milliseconds(20)
        ).convert(frame)

        #expect(converted.payload.contains { $0 != 0 })
    }

    @Test("Identity conversion preserves the frame value")
    func identityConversionPreservesFrame() throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let frame = try makeSilentFrame(format: format)
        let converted = try PCMFrameConverter(
            outputFormat: format,
            maximumInputDuration: .milliseconds(20)
        ).convert(frame)

        #expect(converted == frame)
    }

    @Test("Conversion rejects frames beyond the caller supplied bound")
    func conversionHasAnExplicitInputBound() throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let frame = try makeSilentFrame(format: format)
        let converter = try PCMFrameConverter(
            outputFormat: format,
            maximumInputDuration: .milliseconds(5)
        )

        #expect(throws: PCMFrameConversionError.inputDurationLimitExceeded(
            maximum: .milliseconds(5)
        )) {
            try converter.convert(frame)
        }
    }

    private func verifyConversion(
        from inputFormat: AudioStreamFormat,
        to outputFormat: AudioStreamFormat
    ) throws {
        let input = try makeSilentFrame(format: inputFormat)
        let converted = try PCMFrameConverter(
            outputFormat: outputFormat,
            maximumInputDuration: .milliseconds(20)
        ).convert(input)

        #expect(converted.flowID == input.flowID)
        #expect(converted.sequence == input.sequence)
        #expect(converted.timestamp == input.timestamp)
        #expect(converted.format == outputFormat)
        #expect(!converted.payload.isEmpty)
        #expect(converted.payload.allSatisfy { $0 == 0 })
        let expectedSampleFrameCount = Int(
            (seconds(input.duration) * outputFormat.sampleRate).rounded()
        )
        #expect(converted.payload.count
            == expectedSampleFrameCount * outputFormat.bytesPerFrame)
        #expect(abs(seconds(converted.duration) - seconds(input.duration))
            < 1e-12)
    }

    private func makeSilentFrame(format: AudioStreamFormat) throws -> AudioFrame {
        let sampleFrameCount = Int(format.sampleRate / 100)
        let payload = Data(count: sampleFrameCount * format.bytesPerFrame)
        return try AudioFrame(
            flowID: AudioFlowID(),
            sequence: 9,
            timestamp: .milliseconds(40),
            format: format,
            payload: payload,
            duration: .milliseconds(10)
        )
    }

    private func formatShapes(sampleRate: Double) throws -> [AudioStreamFormat] {
        var formats: [AudioStreamFormat] = []
        for encoding in [SampleEncoding.signedPCM16LittleEndian, .float32] {
            for channelCount in 1...2 {
                for interleaving in [Interleaving.interleaved, .nonInterleaved] {
                    formats.append(try AudioStreamFormat(
                        sampleRate: sampleRate,
                        channelCount: channelCount,
                        sampleEncoding: encoding,
                        interleaving: interleaving
                    ))
                }
            }
        }
        return formats
    }

    private func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
