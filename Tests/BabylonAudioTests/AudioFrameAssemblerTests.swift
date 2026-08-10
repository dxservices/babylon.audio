import Foundation
import Testing
@testable import BabylonAudio

@Suite("Bounded frame assembler")
struct AudioFrameAssemblerTests {
    @Test("Partial chunks assemble ordered fixed-duration frames")
    func partialChunksAssembleFrames() throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        let flowID = AudioFlowID()
        var assembler = try AudioFrameAssembler(
            flowID: flowID,
            format: format,
            frameDuration: .milliseconds(20),
            maximumBufferedDuration: .milliseconds(40),
            maximumFramesPerAppend: 2
        )

        #expect(try assembler.append(Data(count: 480)).isEmpty)
        let frames = try assembler.append(Data(count: 1_440))

        #expect(frames.count == 2)
        #expect(frames.map(\.sequence) == [0, 1])
        #expect(frames.map(\.timestamp) == [.zero, .milliseconds(20)])
        #expect(frames.allSatisfy { $0.duration == .milliseconds(20) })
        #expect(assembler.bufferedByteCount == 0)
    }

    @Test("Total staged audio cannot exceed the duration bound")
    func assemblerRejectsStagedDurationBeyondBound() throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        var assembler = try AudioFrameAssembler(
            flowID: AudioFlowID(),
            format: format,
            frameDuration: .milliseconds(20),
            maximumBufferedDuration: .milliseconds(40),
            maximumFramesPerAppend: 4
        )
        _ = try assembler.append(Data(count: 480))

        #expect(throws: AudioAssemblerError.bufferDurationLimitExceeded(
            maximum: .milliseconds(40)
        )) {
            try assembler.append(Data(count: 1_441))
        }
        #expect(assembler.bufferedByteCount == 480)
        #expect(assembler.nextSequence == 0)
    }

    @Test("Per-append output work has a separate frame-count bound")
    func assemblerRejectsOutputWorkBeyondBound() throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        var assembler = try AudioFrameAssembler(
            flowID: AudioFlowID(),
            format: format,
            frameDuration: .milliseconds(20),
            maximumBufferedDuration: .milliseconds(100),
            maximumFramesPerAppend: 2
        )

        #expect(throws: AudioAssemblerError.appendLimitExceeded(maximumFrames: 2)) {
            try assembler.append(Data(count: 2_880))
        }
        #expect(assembler.bufferedByteCount == 0)
        #expect(assembler.nextSequence == 0)
    }

    @Test("Configured duration bounds must contain an integral sample-frame count")
    func assemblerRejectsFractionalSampleFrameBounds() throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)

        #expect(throws: AudioAssemblerError.invalidConfiguration) {
            try AudioFrameAssembler(
                flowID: AudioFlowID(),
                format: format,
                frameDuration: .milliseconds(20),
                maximumBufferedDuration: .microseconds(1),
                maximumFramesPerAppend: 1
            )
        }
    }

    @Test("Reset discards partial bytes without reusing sequence numbers")
    func resetDiscardsPartialBytes() throws {
        let format = try AudioStreamFormat.monoPCM16(sampleRate: 24_000)
        var assembler = try AudioFrameAssembler(
            flowID: AudioFlowID(),
            format: format,
            frameDuration: .milliseconds(20),
            maximumBufferedDuration: .milliseconds(20),
            maximumFramesPerAppend: 1
        )

        let first = try #require(assembler.append(Data(count: 960)).first)
        _ = try assembler.append(Data(count: 480))
        assembler.reset()
        let second = try #require(assembler.append(Data(count: 960)).first)

        #expect(first.sequence == 0)
        #expect(second.sequence == 1)
        #expect(second.timestamp == .milliseconds(20))
        #expect(assembler.bufferedByteCount == 0)
    }
}
