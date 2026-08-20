public enum AudioInputPolicy: Equatable, Sendable {
    case builtInMicrophoneRequired
    case preferBuiltInAllowPrivateAccessoryDuplex
}

public enum DeviceOutputPolicy: Equatable, Sendable {
    case privateOutputRequired
}

@available(iOS 18, macOS 13, *)
public struct AudioMicrophoneSourceConfiguration: Equatable, Sendable {
    public let inputPolicy: AudioInputPolicy
    public let capture: AudioCaptureSettings

    public init(
        inputPolicy: AudioInputPolicy,
        capture: AudioCaptureSettings
    ) {
        self.inputPolicy = inputPolicy
        self.capture = capture
    }
}

@available(iOS 18, macOS 13, *)
public enum AudioSourceConfiguration: Sendable {
    case microphone(AudioMicrophoneSourceConfiguration)
    case externalFrames
    case external(any AudioFrameSource)
}

@available(iOS 18, macOS 13, *)
public enum AudioSinkConfiguration: Sendable {
    case device(policy: DeviceOutputPolicy)
    case external(any AudioFrameSink)
}

@available(iOS 18, macOS 13, *)
public struct AudioPipelineConfiguration: Sendable {
    public let source: AudioSourceConfiguration?
    public let sourceProcessorChain: AudioFrameProcessorChain?
    public let localMonitorSink: AudioSinkConfiguration?
    public let uplinkSender: (any AudioFrameSender)?
    public let downlinkReceiver: (any AudioFrameReceiver)?
    public let downlinkSink: AudioSinkConfiguration?
    public let eventSink: (any AudioEventSink)?
    public let diagnosticSink: (any AudioDiagnosticSink)?

    public init(
        source: AudioSourceConfiguration? = nil,
        sourceProcessorChain: AudioFrameProcessorChain? = nil,
        localMonitorSink: AudioSinkConfiguration? = nil,
        uplinkSender: (any AudioFrameSender)? = nil,
        downlinkReceiver: (any AudioFrameReceiver)? = nil,
        downlinkSink: AudioSinkConfiguration? = nil,
        eventSink: (any AudioEventSink)? = nil,
        diagnosticSink: (any AudioDiagnosticSink)? = nil
    ) throws {
        let hasSourceDrivenPlan = localMonitorSink != nil || uplinkSender != nil
        let hasAnyDownlinkComponent = downlinkReceiver != nil || downlinkSink != nil
        let hasCompleteDownlink = downlinkReceiver != nil && downlinkSink != nil

        guard hasSourceDrivenPlan || hasAnyDownlinkComponent else {
            throw AudioContractError.noPipelineDirection
        }
        guard !hasSourceDrivenPlan || source != nil else {
            throw AudioContractError.sourceRequired
        }
        guard sourceProcessorChain == nil || source != nil else {
            throw AudioContractError.sourceRequired
        }
        guard source == nil || hasSourceDrivenPlan else {
            throw AudioContractError.unusedSource
        }
        guard !hasAnyDownlinkComponent || hasCompleteDownlink else {
            throw AudioContractError.incompleteDownlink
        }
        self.source = source
        self.sourceProcessorChain = sourceProcessorChain
        self.localMonitorSink = localMonitorSink
        self.uplinkSender = uplinkSender
        self.downlinkReceiver = downlinkReceiver
        self.downlinkSink = downlinkSink
        self.eventSink = eventSink
        self.diagnosticSink = diagnosticSink
    }
}
