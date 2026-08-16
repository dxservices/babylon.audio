# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

- Add provider-neutral audio frame, source, sink, sender, receiver, event,
  diagnostic, and pipeline-configuration contracts.
- Add bounded frame assembly, sequencing, generation isolation, processing
  chains, and PCM conversion across the supported format matrix.
- Preserve caller-owned processor failures without logging or stringifying
  their underlying errors.
- Keep resampling state flow-scoped across adjacent frames and require an
  explicit reset on stop, replacement, or input-format change.
- Remove policy cases that duplicated external-frame sources and absent sinks,
  so invalid configurations are no longer expressible.
- Define frame timestamps as flow-relative media or capture positions; queue
  freshness uses separate local monotonic enqueue or receive instants.
- Add a format-aware bounded uplink queue with one active send, drop-oldest
  overflow handling, local monotonic expiry, endpoint-failure reporting, and
  flow-generation isolation.
- Add a bounded downlink jitter buffer with receiver integration, sequence
  ordering, target prebuffering, rebuffering, pending-plus-in-flight accounting,
  and data-consumed sink scheduling semantics.
- Add content-free streaming snapshots and diagnostics for queue duration,
  discard counts, latency, overflow, expiry, stale work, and rebuffering.
- Add caller-owned trusted-output records, route snapshots, and a fail-closed
  safety policy for wired, Bluetooth, public, missing, mixed, and multiple
  outputs.
- Add explicit A2DP-first/HFP-duplex activation profiles plus package-owned
  audio-session and route controllers; HFP is never attempted by the
  built-in-microphone-required policy. An untrusted Bluetooth result
  deactivates the session before caller confirmation and requires a fresh
  configuration attempt after trust is recorded.
- Extend repository checks to cover all reachable commit messages and
  extensionless text files.
