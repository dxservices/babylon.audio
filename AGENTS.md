# Repository instructions

## Scope

BabylonAudio is a provider-neutral iOS real-time audio data-plane and device-management package. Keep UI, credentials, provider protocols, business recovery policy, persistence, and product state outside this repository.

## Engineering rules

- Target iOS 18 or later and use Swift 6 language mode with strict concurrency.
- Keep the core product free of third-party dependencies.
- Treat the package as the process's sole `AVAudioSession` and hardware `AVAudioEngine` authority.
- Treat route changes as safety events and fail closed before notifying a consumer.
- Bound every real-time queue and isolate stale callbacks by flow generation.
- Never persist or log raw audio, transcripts, credentials, or provider payloads.
- Do not perform network, JSON, logging, disk, or blocking work in audio callbacks.
- Write all repository documentation, comments, tests, and commit messages in English.
- Add a failing behavioral test before implementation changes.

## Verification

Run `swift test`, `swift build`, and `python3 Scripts/check_repository.py`. Device and route behavior also requires physical-iPhone acceptance evidence.

