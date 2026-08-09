public enum AudioInputPolicy: Equatable, Sendable {
    case builtInMicrophoneRequired
    case preferBuiltInAllowPrivateAccessoryDuplex
    case externalFrames
}

public enum DeviceOutputPolicy: Equatable, Sendable {
    case privateOutputRequired
    case noDeviceOutput
}

@available(iOS 18, macOS 13, *)
public enum AudioSourceConfiguration: Sendable {
    case microphone(policy: AudioInputPolicy)
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
    public let localMonitorSink: AudioSinkConfiguration?
    public let uplinkSender: (any AudioFrameSender)?
    public let downlinkReceiver: (any AudioFrameReceiver)?
    public let downlinkSink: AudioSinkConfiguration?
    public let diagnosticSink: (any AudioDiagnosticSink)?

    public init(
        source: AudioSourceConfiguration? = nil,
        localMonitorSink: AudioSinkConfiguration? = nil,
        uplinkSender: (any AudioFrameSender)? = nil,
        downlinkReceiver: (any AudioFrameReceiver)? = nil,
        downlinkSink: AudioSinkConfiguration? = nil,
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
        guard source == nil || hasSourceDrivenPlan else {
            throw AudioContractError.unusedSource
        }
        guard !hasAnyDownlinkComponent || hasCompleteDownlink else {
            throw AudioContractError.incompleteDownlink
        }
        if case .some(.microphone(policy: .externalFrames)) = source {
            throw AudioContractError.invalidMicrophoneInputPolicy
        }
        if [localMonitorSink, downlinkSink].contains(where: Self.disablesDeviceOutput) {
            throw AudioContractError.invalidDeviceOutputPolicy
        }

        self.source = source
        self.localMonitorSink = localMonitorSink
        self.uplinkSender = uplinkSender
        self.downlinkReceiver = downlinkReceiver
        self.downlinkSink = downlinkSink
        self.diagnosticSink = diagnosticSink
    }

    private static func disablesDeviceOutput(_ sink: AudioSinkConfiguration?) -> Bool {
        if case .some(.device(policy: .noDeviceOutput)) = sink {
            return true
        }
        return false
    }
}
