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
- Extend repository checks to cover all reachable commit messages and
  extensionless text files.
