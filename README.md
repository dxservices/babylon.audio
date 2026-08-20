# BabylonAudio

BabylonAudio is an iOS real-time audio data-plane and device-management Swift package.

The package is pre-0.1 and its provider-neutral contracts and bounded audio core
are under active development.

## Requirements

- iOS 18 or later
- Swift 6 language mode
- Swift tools 6.0 or later
- No third-party dependencies in the core product

## Adoption requirement

BabylonAudio must be the sole authority for `AVAudioSession` configuration and the hardware `AVAudioEngine` graph in a consuming process. Applications and SDK adapters must not create a competing audio-session or hardware-engine owner.

Frame timestamps are flow-relative media or capture positions, not wall-clock
or queue-entry times. Queue age and jitter-buffer freshness must use separately
recorded local monotonic enqueue or receive instants.

`PCMFrameConverter` keeps resampling state for one flow and format tuple. A
consumer must call `reset()` after stop and before flow replacement or input
format change. Reset discards filter history; the converter uses no priming tail,
so there is no output to flush.

## Intended responsibilities

- Audio session, route, interruption, and media-services-reset handling
- Microphone capture, PCM playback, conversion, resampling, and framing
- Bounded uplink queues and bounded downlink jitter buffers
- Synchronous, bounded audio processor chains
- Flow-generation isolation and safe shutdown
- Private-output fail-closed policy
- Content-free diagnostics

## Streaming data plane

`BoundedUplinkQueue` serializes one `AudioFrameSender.send` at a time. Its
pending budget is calculated from each validated frame's duration, independent
of sample rate, channel count, encoding, and byte layout. Overflow keeps the
newest pending audio, and frame age is measured from a queue-local monotonic
enqueue instant rather than from the frame's media timestamp.

`BoundedDownlinkJitterBuffer` can consume an `AudioFrameReceiver` directly or
accept frames through `enqueue`. It reorders pending frames by sequence during
prebuffering, bounds pending plus in-flight audio, and requires the target
duration again after starvation. Duplicate or already-delivered sequences are
discarded. A sink's `consume` operation must complete at the data-consumed
scheduling boundary, not after audible playback completes.

`finishSource(flowID:)` is the explicit end-of-stream boundary. It bypasses the
normal prebuffer target for the accepted tail and returns only after that tail
is consumed, or `false` if stop, replacement, or failure wins the transition.
Draining to zero only creates a pending starvation observation. Rebuffering is
counted when a later accepted frame actually recovers that flow, so a receiver
completion that follows its last sink completion is not misclassified as
rebuffering.

The initial policies use a one-second maximum buffer, a 1.5-second maximum
frame age, and a 200-millisecond downlink target. These are configurable
starting points, not provider guarantees. Stop, replacement, and endpoint
failure invalidate the active flow generation so late completions cannot
restart old work. Snapshots and optional diagnostics contain counts, durations,
latencies, and discard reasons only.

## Pipeline session

The initial `AudioPipelineSession` vertical slice owns a downlink receiver task,
one bounded jitter buffer, an external sink, and their shared flow generation.
It emits `flowStarted`, then `endpointEnded(.downlink)` when the receiver stream
completes, drains any eligible sub-target tail under the configured frame-age
policy, and emits `flowStopped(.sourceEnded)` after that bounded drain. Receiver failure reports the downlink
endpoint before stopping, and sink failure enters the same lifecycle through
the jitter buffer's failure handler. Both receiver and sink failures discard
pending audio with the `endpointFailure` reason. Caller stop invalidates the
generation and prevents a late tail completion from producing another stop
event.

Session events are serialized through completion even when lifecycle methods
overlap. An `AudioEventSink` must return after handing the event to its consumer
state machine; it must not await a lifecycle method on the same session because
that method may be waiting for the current event delivery to finish. Each flow
identifier is single-use within one session instance, so a late completion can
never match a later generation that happens to reuse the same identifier.

Caller-driven `.externalFrames` can now fan each accepted frame into an external
local-monitor sink and a format-aware bounded uplink queue under the same flow
generation. Submission is serial, rejects frames from another flow, and records
the current source format in the pipeline snapshot. A submission cancelled
while waiting for serialization releases its FIFO position without reaching
either endpoint. Uplink sender and local-
monitor sink failures atomically claim flow termination before serialized
`endpointFailed` and `flowStopped(.endpointFailure)` delivery, so concurrent
caller stop cannot rewrite the terminal reason.

An external `AudioFrameSource` can drive the same serialized local-monitor and
uplink fan-out without caller submission. Natural source completion emits
`endpointEnded(.source)`, then drains the eligible accepted tail under the
bounded queue's capacity and frame-age policies before emitting
`flowStopped(.sourceEnded)`. Source stream failure reports the content-free
`.source` endpoint direction and stops the shared flow.

The first naturally ended source or downlink endpoint owns termination of the
shared flow in v0.1. A source-first ending stops, rather than drains, the
downlink side. This deliberate half-close policy matches the initial bounded
half-duplex consumer; a full-duplex consumer requires a separate lifecycle
decision before adoption. Pipeline endpoint events never carry underlying
source, receiver, sender, or sink errors. Callers that need private debugging
detail must observe or map errors inside their injected endpoint boundary.

A microphone source now carries an explicit `AudioCaptureSettings` value for
its normalized format, frame duration, callback work bound, buffered-duration
bound, and handoff capacity. `AudioPipelineSession` materializes those settings
with the active flow identifier and starts capture on one injected, already
configured and running `AudioDeviceEngine`. Frames delivered by that engine are
validated against the flow and requested normalized format before entering the
same serialized local-monitor/uplink fan-out. Capture failure reports the
content-free `.source` endpoint, while stop and replacement use capture
ownership tokens so late frames or failures cannot stop a newer capture.

This slice does not configure an audio session, select a route, enable voice
processing, or start the engine. Those safety transitions remain caller-owned
until the route/runtime orchestration slice lands. Fake-backed tests prove the
normalized engine boundary, not physical microphone conversion on Simulator.

Local-monitor and downlink `.device` sinks resolve to that same injected
`AudioDeviceEngine`; the session never creates a second graph. Device playback
requires the shared engine to be running with one exact format configured
before start. A microphone-to-device local monitor additionally requires that
format to match its normalized capture format. Natural downlink completion
drains eligible accepted frames through the data-consumed scheduling boundary,
not audible completion, before terminal delivery. Consumer stop, failure, or
stopping a flow before starting its replacement stops device playback to
release pending consumes, but leaves the shared engine running for the external
safety/runtime owner. This shared-engine wiring does not by itself prove a safe
private route or physical playback; route evaluation and output unmute remain
the runtime owner's fail-closed responsibility.

The deterministic session suite also composes local monitor, uplink, and
downlink in one configuration. Both source-driven branches observe the same
flow as the controlled receiver and its flushed tail, and the combined session
emits only one terminal flow lifecycle.

## Device and route policy

`AudioRouteSafetyPolicy` evaluates the actual current input and output route.
Wired headphones are accepted directly. Bluetooth A2DP, HFP, and LE outputs
require an exact caller-owned `AudioTrustedOutput`; BabylonAudio never persists
that trust. Missing, public, mixed, or multiple outputs fail closed. Both
`AudioRouteSafetyPolicy.evaluate` and `AudioRouteController.configure` require
an explicit `DeviceOutputPolicy`; v0.1 supports only
`.privateOutputRequired`. Preference success never replaces evaluation of the
resulting current route.

HFP is not an implicit fallback. `builtInMicrophoneRequired` activates only the
built-in-microphone/private-output profile and rejects an HFP route.
`preferBuiltInAllowPrivateAccessoryDuplex` explicitly permits an ordered A2DP
then private-accessory-duplex attempt. `AudioRouteController` returns
`trustRequired` without treating an unconfirmed Bluetooth route as safe. It
deactivates the audio session before returning that result, so caller
confirmation never leaves the package's play-and-record session active. After
persisting trust in its own boundary, the caller must configure the route
again. The controller also deactivates when no safe private route forms.
The iOS `AudioSessionController.shared` is the package-owned low-level
`AVAudioSession` adapter; preference success never substitutes for inspecting
its resulting `routeSnapshot`.

The built-in-microphone profile exposes `.disabled` voice processing and uses
the default session mode. Only the explicitly allowed private-accessory-duplex
profile exposes `.enabledForPrivateAccessoryDuplex` and uses `.voiceChat`.
`AudioDeviceEngine.configureVoiceProcessing` is a separate pre-start opt-in
that enables the input node's Voice Processing I/O; the engine defaults to
disabled and reset restores that default. `AudioPipelineSession` must wire the
active profile policy into the engine in A5. Stable unsafe route and input-
discovery snapshots stop polling after a configurable number of unchanged
confirmation samples; the device default is five at 100 ms intervals. Any
snapshot change continues observation up to the configured bound. If a private
accessory input was successfully selected, that duplex profile disables early
exit for the whole observation round so SCO setup gets the full window.

Microphone selection and capture bounds are represented by
`AudioSourceConfiguration.microphone(AudioMicrophoneSourceConfiguration)`;
caller-provided PCM uses `.externalFrames` or `.external`. Device playback is represented only by
`AudioSinkConfiguration.device(policy: .privateOutputRequired)`. Omitting a
device sink means that the pipeline has no device-output path; it never implies
a speaker fallback.

`AudioSafetyCoordinator` connects route-change, interruption, and media-reset
facts to a fixed fail-closed sequence. It latches output mute, stops capture,
stops playback, invalidates both streaming flow generations, deactivates the
audio session, and only then delivers the device event to the caller. An
interruption-ended event never resumes hardware automatically. Session
deactivation failure is reported as a content-free boolean result and cannot
skip consumer delivery. For a media-services reset, the coordinator additionally
replaces the invalid device-engine graph after deactivation and before consumer
delivery; it never asks the caller to recover against stale audio objects.
Device events are FIFO-serialized through the end of consumer delivery. Caller
session/graph configuration must run through `performConfiguration`, which is
mutually exclusive with the hardware, buffer, deactivate, and rebuild phase.
Every boundary event synchronously latches idempotent output mute before waiting
for either gate, so queued delivery or configuration cannot delay fail-closed
silence. The full mute-and-stop sequence still runs inside the transition gate.
Delivery does not hold the configuration gate, so an event sink may await
configuration directly while the next device event remains queued. Configuration
calls must not be nested. Serialization does not preempt an operation already in
progress; output must remain muted until its route safety is confirmed. A custom
`discardPendingAudio` must not call `performConfiguration`, and an event sink must
not await `handle`, because each callback already runs under the corresponding
gate. Cancellation-aware configuration still occupies its FIFO position before
exiting without running caller work. Event snapshots describe observation-time
state; configuration must inspect the current session route again rather than
treating a queued `routeChanged` snapshot as current.

The consumer must retain the coordinator until both the device engine and
audio session are no longer in use. Its convenience initializer installs the
session authority's sole event handler; consumers must not replace that handler
while hardware is active. Every route-change notification deliberately enters
the safety boundary, including changes that may be favorable. Route-reason
specialization is a later optimization, so continuity guarantees apply only
while the route remains stable.

`AudioDeviceEngine` is the initial shared `AVAudioEngine` safety foundation.
It starts muted, owns one player node, and refuses to unmute unless given a
`.safe` route evaluation. Its capture and playback safety controls satisfy the
coordinator contract. A media-services reset discards the old engine and player
node, cancels their pending work, and creates a fresh stopped and muted graph.
Running, capture, and playback-format state is cleared, so recovery requires an
explicit session configuration, playback-format configuration, engine start,
and safe-route unmute.

Microphone capture installs one input-node tap using the hardware-native PCM
format. The callback only validates the bounded frame count, copies PCM bytes,
and offers the chunk to a bounded non-suspending handoff; it does not create a
task, await, log, persist, perform network work, or invoke caller code. The tap
buffer size is only a request: callbacks may contain up to the configured
`maximumBufferedDuration`. A larger hardware buffer, invalid buffer layout, or
handoff overflow closes the bridge with a content-free failure instead of
silently producing zero audio. A dedicated drain task then assembles
fixed-duration frames, performs stateful conversion to the requested format,
and serially invokes the caller handler. Hardware-format assembler and
converter validation completes synchronously before the tap is installed.
Configuration also rejects a `maximumFramesPerCallback` that cannot cover every
frame permitted by `maximumBufferedDuration`, so accepted callback sizes cannot
later fail solely because the assembler work bound is smaller.

Capture ownership is tokenized inside `AudioDeviceEngine`. A stale backend
failure cannot clear a replacement capture's public state, and the iOS backend
also checks the failed handoff bridge identity before removing a tap. This
isolation is required because capture stop is intentionally not an async
delivery barrier.

`stopCapture()` removes the tap, closes the handoff, and requests drain-task
cancellation, but it is not an async delivery barrier: an `onFrame` call already
in flight may return after `stopCapture()`. Consumers must invalidate the flow
generation and stop downstream bounded queues as part of the same safety
transition; late delivery is then rejected by generation. PCM playback
scheduling uses the same shared engine. Callers configure one exact PCM format
before starting the engine; the engine then acts as an `AudioFrameSink` and
rejects missing or mismatched playback configuration. Each consume operation
returns only from `AVAudioPlayerNodeCompletionDataConsumed`, allowing the next
buffer to be scheduled without waiting for audible completion. The completion
callback only yields to a one-element bridge and performs no async, logging,
network, disk, or business work. If playback has never been unmuted, the player
node remains stopped and `consume` intentionally backpressures until a safe-route
unmute, `stopPlayback`, or task cancellation. Muting an already-started player
sets its volume to zero without stopping it, so scheduled data continues to be
consumed silently; the safety coordinator follows mute with `stopPlayback` when
discard is required. `stopPlayback()` terminates all pending bridges before
stopping the player node, so discarded buffers fail with `playbackStopped`
instead of reporting successful consumption. Simulator compilation does not
validate microphone, playback, or route hardware behavior.

## Non-goals

BabylonAudio does not promise to:

- Read digital audio that another app is playing on iOS 18
- Bypass Zoom, Apple News, AVPlayer, DRM, or content-provider protections
- Start full-screen capture without user authorization and visible system UI
- Guarantee that calling apps, protected content, or third-party apps expose audio to capture APIs
- Capture independent raw channels from arbitrary pairs of hardware input devices

The initial package does not contain provider protocols, credentials, reconnection policy, UI, subtitles, voiceprints, ScreenCaptureKit adapters, Zoom SDK integration, codecs, persistence, or content logging.

## Development

```sh
swift package resolve
swift test
swift build
```

Simulator and unit-test results do not prove Bluetooth routing, private-output safety, gapless playback, or zero speaker leakage. Device and route changes require maintainer-owned physical-device validation.

## License

BabylonAudio is available under the MIT License. See `LICENSE`.
