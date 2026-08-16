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

The initial policies use a one-second maximum buffer, a 1.5-second maximum
frame age, and a 200-millisecond downlink target. These are configurable
starting points, not provider guarantees. Stop, replacement, and endpoint
failure invalidate the active flow generation so late completions cannot
restart old work. Snapshots and optional diagnostics contain counts, durations,
latencies, and discard reasons only.

## Device and route policy

`AudioRouteSafetyPolicy` evaluates the actual current input and output route.
Wired headphones are accepted directly. Bluetooth A2DP, HFP, and LE outputs
require an exact caller-owned `AudioTrustedOutput`; BabylonAudio never persists
that trust. Missing, public, mixed, or multiple outputs fail closed.

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

`AudioSafetyCoordinator` connects route-change, interruption, and media-reset
facts to a fixed fail-closed sequence. It latches output mute, stops capture,
stops playback, invalidates both streaming flow generations, deactivates the
audio session, and only then delivers the device event to the caller. An
interruption-ended event never resumes hardware automatically. Session
deactivation failure is reported as a content-free boolean result and cannot
skip consumer delivery. For a media-services reset, the coordinator additionally
replaces the invalid device-engine graph after deactivation and before consumer
delivery; it never asks the caller to recover against stale audio objects.

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
