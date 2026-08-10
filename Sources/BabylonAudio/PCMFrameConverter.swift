import AVFAudio
import Foundation

@available(iOS 18, macOS 13, *)
/// Converts bounded frames synchronously outside hardware render callbacks.
public struct PCMFrameConverter: Sendable {
    public let outputFormat: AudioStreamFormat
    public let maximumInputDuration: Duration

    public init(
        outputFormat: AudioStreamFormat,
        maximumInputDuration: Duration
    ) throws {
        guard maximumInputDuration > .zero else {
            throw PCMFrameConversionError.invalidConfiguration
        }
        self.outputFormat = outputFormat
        self.maximumInputDuration = maximumInputDuration
    }

    public func convert(_ frame: AudioFrame) throws -> AudioFrame {
        guard frame.duration <= maximumInputDuration else {
            throw PCMFrameConversionError.inputDurationLimitExceeded(
                maximum: maximumInputDuration
            )
        }
        guard frame.format != outputFormat else {
            return frame
        }
        guard let inputAVFormat = Self.makeAVFormat(frame.format),
              let outputAVFormat = Self.makeAVFormat(outputFormat),
              let converter = AVAudioConverter(
                  from: inputAVFormat,
                  to: outputAVFormat
              )
        else {
            throw PCMFrameConversionError.unsupportedConversion
        }

        let inputFrameCount = frame.payload.count / frame.format.bytesPerFrame
        guard inputFrameCount <= Int(AVAudioFrameCount.max),
              let inputBuffer = AVAudioPCMBuffer(
                  pcmFormat: inputAVFormat,
                  frameCapacity: AVAudioFrameCount(inputFrameCount)
              )
        else {
            throw PCMFrameConversionError.frameTooLarge
        }
        inputBuffer.frameLength = AVAudioFrameCount(inputFrameCount)
        try Self.copy(frame.payload, to: inputBuffer, format: frame.format)

        let outputCapacityValue = ceil(
            Double(inputFrameCount) * outputFormat.sampleRate / frame.format.sampleRate
        ) + 1
        guard outputCapacityValue <= Double(AVAudioFrameCount.max),
              let outputBuffer = AVAudioPCMBuffer(
                  pcmFormat: outputAVFormat,
                  frameCapacity: AVAudioFrameCount(outputCapacityValue)
              )
        else {
            throw PCMFrameConversionError.frameTooLarge
        }

        converter.primeMethod = .normal
        let inputProvider = SinglePCMBufferProvider(buffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(
            to: outputBuffer,
            error: &conversionError
        ) { _, inputStatus in
            inputProvider.next(status: inputStatus)
        }

        guard conversionError == nil,
              status != .error,
              outputBuffer.frameLength > 0
        else {
            throw PCMFrameConversionError.conversionFailed
        }

        let payload = try Self.copy(from: outputBuffer, format: outputFormat)
        let duration = try outputFormat.duration(forPayloadByteCount: payload.count)
        return try AudioFrame(
            flowID: frame.flowID,
            sequence: frame.sequence,
            timestamp: frame.timestamp,
            format: outputFormat,
            payload: payload,
            duration: duration
        )
    }

    private static func makeAVFormat(_ format: AudioStreamFormat) -> AVAudioFormat? {
        let commonFormat: AVAudioCommonFormat
        switch format.sampleEncoding {
        case .signedPCM16LittleEndian:
            commonFormat = .pcmFormatInt16
        case .float32:
            commonFormat = .pcmFormatFloat32
        }
        return AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: format.sampleRate,
            channels: AVAudioChannelCount(format.channelCount),
            interleaved: format.interleaving == .interleaved
        )
    }

    private static func copy(
        _ payload: Data,
        to buffer: AVAudioPCMBuffer,
        format: AudioStreamFormat
    ) throws {
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        try payload.withUnsafeBytes { source in
            guard let sourceBaseAddress = source.baseAddress else {
                throw PCMFrameConversionError.invalidBufferLayout
            }
            switch format.interleaving {
            case .interleaved:
                guard buffers.count == 1,
                      let destination = buffers[0].mData,
                      payload.count <= Int(buffers[0].mDataByteSize)
                else {
                    throw PCMFrameConversionError.invalidBufferLayout
                }
                destination.copyMemory(from: sourceBaseAddress, byteCount: payload.count)
            case .nonInterleaved:
                let bytesPerPlane = payload.count / format.channelCount
                guard buffers.count == format.channelCount else {
                    throw PCMFrameConversionError.invalidBufferLayout
                }
                for channel in 0..<format.channelCount {
                    guard let destination = buffers[channel].mData,
                          bytesPerPlane <= Int(buffers[channel].mDataByteSize)
                    else {
                        throw PCMFrameConversionError.invalidBufferLayout
                    }
                    destination.copyMemory(
                        from: sourceBaseAddress.advanced(by: channel * bytesPerPlane),
                        byteCount: bytesPerPlane
                    )
                }
            }
        }
    }

    private static func copy(
        from buffer: AVAudioPCMBuffer,
        format: AudioStreamFormat
    ) throws -> Data {
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let frameCount = Int(buffer.frameLength)

        switch format.interleaving {
        case .interleaved:
            let byteCount = frameCount * format.bytesPerFrame
            guard buffers.count == 1,
                  let source = buffers[0].mData,
                  byteCount <= Int(buffers[0].mDataByteSize)
            else {
                throw PCMFrameConversionError.invalidBufferLayout
            }
            return Data(bytes: source, count: byteCount)
        case .nonInterleaved:
            let bytesPerPlane = frameCount * format.bytesPerSample
            guard buffers.count == format.channelCount else {
                throw PCMFrameConversionError.invalidBufferLayout
            }
            var payload = Data()
            payload.reserveCapacity(bytesPerPlane * format.channelCount)
            for channel in 0..<format.channelCount {
                guard let source = buffers[channel].mData,
                      bytesPerPlane <= Int(buffers[channel].mDataByteSize)
                else {
                    throw PCMFrameConversionError.invalidBufferLayout
                }
                payload.append(source.assumingMemoryBound(to: UInt8.self), count: bytesPerPlane)
            }
            return payload
        }
    }
}

@available(iOS 18, macOS 13, *)
public enum PCMFrameConversionError: Error, Equatable, Sendable {
    case invalidConfiguration
    case inputDurationLimitExceeded(maximum: Duration)
    case unsupportedConversion
    case frameTooLarge
    case invalidBufferLayout
    case conversionFailed
}

@available(iOS 18, macOS 13, *)
private final class SinglePCMBufferProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !supplied else {
            status.pointee = .endOfStream
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
}
