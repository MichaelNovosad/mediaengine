# Versioning, API stability and support (draft for the owner)

- **Semantic versioning** of the Swift package: MAJOR for source- or behaviour-breaking changes of the public API, MINOR for additions,
  PATCH for fixes (including security updates of the bundled FFmpeg and dav1d). Version 1.0 is the first release that follows this.
- **API stability:** public API is exactly what the DocC documentation lists. Before every release `swift package diagnose-api-breaking-changes
  <previous tag>` runs and its output decides the version bump (API-9; possible once a 1.0 tag exists).
- **Binaries:** each release carries checksummed XCFrameworks (core, extended, LibASS), the source pack and `BUILD-INFO.txt`.
  The extended variant has the same module name and ABI as core: switching never needs source changes.
- **Third-party updates:** FFmpeg, dav1d and the subtitle libraries are pinned (`third_party/sources.lock`); a pin change is a PATCH
  or MINOR release with a changelog line. Security advisories of FFmpeg are monitored; the target is a patch release within 14 days
  for a high-severity issue that the engine's configuration exposes (proposal, owner to confirm; PRF-6).
- **Support policy (proposal, owner to confirm):** the current and the previous minor version receive fixes; supported OS versions are
  the platform versions in `Package.swift` (27.0 and later) while Apple supports them; response to a bug report within 3 business days.
- **Deprecation:** a symbol is deprecated for at least one MINOR release (with a message that names the replacement) before it is
  removed in the next MAJOR.
