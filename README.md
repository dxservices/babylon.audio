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
