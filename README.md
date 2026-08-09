# BabylonAudio

BabylonAudio is an iOS real-time audio data-plane and device-management Swift package.

The package is in its initial pre-0.1 scaffold. It does not expose a usable public API yet.

## Requirements

- iOS 18 or later
- Swift 6 language mode
- Swift tools 6.0 or later
- No third-party dependencies in the core product

## Adoption requirement

BabylonAudio must be the sole authority for `AVAudioSession` configuration and the hardware `AVAudioEngine` graph in a consuming process. Applications and SDK adapters must not create a competing audio-session or hardware-engine owner.

## Intended responsibilities

- Audio session, route, interruption, and media-services-reset handling
- Microphone capture, PCM playback, conversion, resampling, and framing
- Bounded uplink queues and bounded downlink jitter buffers
- Synchronous, bounded audio processor chains
- Flow-generation isolation and safe shutdown
- Private-output fail-closed policy
- Content-free diagnostics

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

