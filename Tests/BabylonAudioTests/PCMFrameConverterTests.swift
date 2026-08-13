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

    @Test("A converter preserves resampler state across a continuous flow")
    func continuousFlowMatchesSingleBufferConversion() throws {
        let inputFormat = try AudioStreamFormat.monoPCM16(sampleRate: 16_000)
        let outputFormat = try AudioStreamFormat.monoPCM16(sampleRate: 48_000)
        let flowID = AudioFlowID()
        let inputFrames = try makeSineFrames(
            count: 8,
            flowID: flowID,
            format: inputFormat,
            frequency: 1_173
        )
        let converter = try PCMFrameConverter(
            outputFormat: outputFormat,
            maximumInputDuration: .milliseconds(20)
        )

        let streamed = try inputFrames.map(converter.convert)
        let combinedInput = try combine(inputFrames)
        let reference = try PCMFrameConverter(
            outputFormat: outputFormat,
            maximumInputDuration: .milliseconds(200)
        ).convert(combinedInput)

        #expect(streamed.reduce(0) { $0 + $1.payload.count } == reference.payload.count)
        #expect(maximumSampleDifference(
            streamed.flatMap { pcm16Samples($0.payload) },
            pcm16Samples(reference.payload)
        ) <= 2)
    }

    @Test("A converter rejects replacement flow or input format until reset")
    func streamContextMustBeReset() throws {
        let outputFormat = try AudioStreamFormat.monoPCM16(sampleRate: 48_000)
        let firstFormat = try AudioStreamFormat.monoPCM16(sampleRate: 16_000)
        let replacementFormat = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let firstFlow = AudioFlowID()
        let replacementFlow = AudioFlowID()
        let converter = try PCMFrameConverter(
            outputFormat: outputFormat,
            maximumInputDuration: .milliseconds(20)
        )

        _ = try converter.convert(makeSilentFrame(format: firstFormat, flowID: firstFlow))
        #expect(throws: PCMFrameConversionError.streamContextChanged) {
            try converter.convert(makeSilentFrame(format: firstFormat, flowID: replacementFlow))
        }
        #expect(throws: PCMFrameConversionError.streamContextChanged) {
            try converter.convert(makeSilentFrame(format: replacementFormat, flowID: firstFlow))
        }

        converter.reset()
        let replacement = try converter.convert(
            makeSilentFrame(format: replacementFormat, flowID: replacementFlow)
        )
        #expect(replacement.flowID == replacementFlow)
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

    private func makeSilentFrame(
        format: AudioStreamFormat,
        flowID: AudioFlowID = AudioFlowID()
    ) throws -> AudioFrame {
        let sampleFrameCount = Int(format.sampleRate / 100)
        let payload = Data(count: sampleFrameCount * format.bytesPerFrame)
        return try AudioFrame(
            flowID: flowID,
            sequence: 9,
            timestamp: .milliseconds(40),
            format: format,
            payload: payload,
            duration: .milliseconds(10)
        )
    }

    private func makeSineFrames(
        count: Int,
        flowID: AudioFlowID,
        format: AudioStreamFormat,
        frequency: Double
    ) throws -> [AudioFrame] {
        let samplesPerFrame = Int(format.sampleRate / 100)
        return try (0..<count).map { frameIndex in
            var payload = Data()
            payload.reserveCapacity(samplesPerFrame * MemoryLayout<Int16>.size)
            for sampleIndex in 0..<samplesPerFrame {
                let absoluteIndex = frameIndex * samplesPerFrame + sampleIndex
                let phase = 2 * Double.pi * frequency * Double(absoluteIndex) / format.sampleRate
                var sample = Int16((sin(phase) * 20_000).rounded()).littleEndian
                withUnsafeBytes(of: &sample) { payload.append(contentsOf: $0) }
            }
            return try AudioFrame(
                flowID: flowID,
                sequence: UInt64(frameIndex),
                timestamp: .milliseconds(frameIndex * 10),
                format: format,
                payload: payload,
                duration: .milliseconds(10)
            )
        }
    }

    private func combine(_ frames: [AudioFrame]) throws -> AudioFrame {
        let payload = frames.reduce(into: Data()) { $0.append($1.payload) }
        return try AudioFrame(
            flowID: frames[0].flowID,
            sequence: frames[0].sequence,
            timestamp: frames[0].timestamp,
            format: frames[0].format,
            payload: payload,
            duration: frames.reduce(.zero) { $0 + $1.duration }
        )
    }

    private func pcm16Samples(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Int16.self)).map { Int16(littleEndian: $0) }
        }
    }

    private func maximumSampleDifference(_ left: [Int16], _ right: [Int16]) -> Int {
        guard left.count == right.count else { return .max }
        return zip(left, right).reduce(0) { maximum, pair in
            max(maximum, abs(Int(pair.0) - Int(pair.1)))
        }
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
