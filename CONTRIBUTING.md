# Contributing

BabylonAudio is currently in pre-0.1 contract development. Public API stability is not guaranteed.

## Local checks

Run these checks before submitting a change:

```sh
swift package resolve
swift test
swift build
python3 Scripts/check_repository.py
```

All repository documentation, code comments, tests, and commit messages must be written in English.

## Verification boundary

Automated checks can validate package structure, concurrency rules, queue behavior, policy logic, and Simulator compilation. They cannot establish physical audio-route behavior.

Changes involving device, route, capture, playback, interruption, or media reset require maintainer validation on a physical iPhone before merge. Evidence must cover the affected private-output and fail-closed scenarios.

Never add raw audio, transcripts, credentials, provider payloads, personal signing data, or content-bearing logs to fixtures, diagnostics, screenshots, or commits.

