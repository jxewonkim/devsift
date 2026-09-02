# Changelog

All notable changes to DevSift will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial product scope, safety model, privacy contract, architecture, and
  development plan.
- Swift package foundations for DevSiftCore, the `devsift` CLI, and the DevSift
  SwiftUI app.
- Continuous integration for formatting, debug and release builds, and tests.
- A read-only, cancellable allocated-size scanner with descriptor-anchored
  traversal, deterministic bounded reports, structured partial errors,
  cross-volume pruning, and conservative hard-link accounting.
- A dependency-free `devsift scan <path>` command with deterministic,
  terminal-safe text output, versioned root-relative JSON, explicit partial
  results, stable exit codes, and synthetic executable integration tests.
- A native read-only scan dashboard with explicit folder selection,
  cancellable scans, complete and partial result presentation, accessible
  keyboard controls, and light and dark appearance support.
- Explicit per-summary size-overflow state so frontends do not present a
  saturated size as an exact observation.
- JSON scan schema version 2, adding the per-summary `sizeOverflowed` flag;
  text output now withholds overflowed totals instead of formatting saturation
  as an exact byte count.
- A versioned explainable-rule model and conservative classifier with
  structured evidence, exclusions, age, activity, reproducibility, scan-
  integrity, conflict, and invalid-rule findings.
- Initial rules for uv, npm, Homebrew, Xcode DerivedData and iOS DeviceSupport,
  and SwiftPM build output. Remaining uncollected runtime evidence stays
  protected.
- Read-only `devsift classify` text and JSON output plus native dashboard policy
  explanations; no planning or filesystem mutation action was added.
- Classification JSON schema version 1, including a bounded `scanIntegrity`
  projection with decimal-string counts and explicit uncertainty flags.
- Shared fail-closed validation for classifier output, including reference-time
  and scan-report binding, path coverage, rule-specific evidence, diagnostics,
  and aggregate output bounds before either frontend renders a result.
- A per-summary conservative upper bound of the newest inode modification time
  observed during descriptor-relative traversal. Subseconds round up, invalid
  values fail closed, symbolic-link inodes contribute, and their targets do
  not.
- Rule age findings now consume that aggregate only for complete items. The
  other required facts still keep real candidates Protected even when age is
  satisfied.
- Scan-time root and retained top-level `(device, inode)` identities that bind
  later read-only descriptor-relative observations to the objects that were
  scanned. They are not cleanup or deletion authority.
- A bounded identity-bound observer for the SwiftPM `.build` rule that checks
  only metadata for an exact regular-file `workspace-state.json` marker without
  following symbolic-link targets. A satisfied marker remains Protected while
  other required evidence is unavailable.

### Changed

- Scan JSON v2 and classification JSON v1 retain their existing wire shapes.
  Raw candidate timestamps and scan-time identities remain Core-only;
  classification reflects the timestamp only through the existing age finding
  state and generic explanation.
- The CLI built-in catalog is now version 2. Only
  `devsift.swiftpm.build` advances to rule revision 2 for its generated-marker
  semantics; all other built-in rule revisions remain at version 1.
