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
  explanations. That classification increment added no planning or filesystem
  mutation action.
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
- A Core-only cleanup planner that converts explicit exact-path and rule-
  revision selections over validated eligible classifications into
  deterministic immutable draft manifests. Drafts retain expected identities,
  policy evidence, and observed allocation estimates without storing an
  absolute root URL or performing filesystem I/O. Selection is not approval,
  and that Core increment included no Codable, export, frontend, or mutation
  surface.
- Exact non-public source-request binding on built-in classification results so
  planning cannot combine one scan's evidence with another scan's identities or
  size observations.
- Core-owned `RulePolicyProvenance`, binding the explainable-classification
  contract revision, catalog revision, and complete canonical rule-revision
  roster to classifier reports and cleanup manifest contract version 2.
  Presentation-only custom catalogs remain unprovenanced unless they opt into
  an explicit non-built-in catalog revision.
- A Core-only `CleanupManifestDiffer` for deterministic, linear comparison of
  compatible in-memory drafts. Contract, policy-provenance, and expected-root
  mismatches fail closed; exact raw paths identify added, removed, and modified
  entries, and all observed-total changes use overflow-safe directional
  `UInt64` values.
- An internal CLI-owned `devsift.cleanup-manifest-review` JSON schema version 1
  projection pinned to cleanup manifest contract version 2. Its explicit
  redacted and root-relative-exact profiles always omit filesystem identities,
  expose no decoder, and mark the result non-importable, non-approvable, and
  non-executable. The encoder has no CLI command or file-writing path; manifest
  diff export, approval, and execution remain absent.
- A native read-only dry-run review flow. Users explicitly include exact
  eligible path-and-rule-revision pairs from the scan table, starting from zero
  included items independently of table focus. The app freezes the selection,
  asks the Core planner to revalidate the exact source classification request
  and report off the main actor, and presents an identity-free in-memory view
  with all seven observed size and uncertainty quantities. Preparation is
  cancellable, scan and window lifecycle changes invalidate late results, and
  no persistence, import, export, diff, approval, execution, execution-time
  filesystem revalidation, or mutation surface was added.
- A Core-only explicit approval contract prepared from one exact source-bound
  planning request. Its opaque review session retains the exact source root and
  Core-built manifest and issues session-bound entry references. Every entry
  requires a matching confirmation; missing, extra, duplicate, reordered,
  changed, or foreign-session input rejects the request atomically. Partial
  approval is unsupported, so a different subset requires a new draft and
  review. Approval regenerates the manifest from the retained source request and
  requires full equality with the reviewed value. It then retains the exact root
  and manifest in memory, remains non-`Codable`, and performs no filesystem I/O.
  It is copyable rather than single-use and is not freshness evidence,
  authentication, proof of human review, execution authority, or a frontend
  feature. Only an approval-bound revalidation layer may consume it;
  descriptor-relative execution-time checks remain later work.
- A Core-only, approval-only `CleanupRevalidator` as the first Phase 7
  diagnostic boundary. It freshly scans and classifies only the exact root
  retained by `CleanupApproval`, supports only the current built-in policy
  provenance, and emits canonical per-entry revalidation results.
- Reobservation of root identity plus each approved path, kind, device,
  identity, rule revision, findings, and policy decision. Incomplete or unknown
  observations fail closed.
- In-memory, non-`Codable`, copyable, root-URL-free revalidation reports that
  are diagnostic only, not execution inputs or mutation authority. No
  quarantine, restore, purge, persistence, frontend, CLI, network, or mutation
  surface was added.
- Descriptor-bound trusted-location evidence for exact uv, npm, and Homebrew
  default cache containers. The observer uses the current account record rather
  than `$HOME`, validates raw components, refuses symbolic-link traversal, and
  requires the selected root to retain the same filesystem identity across two
  absolute descriptor walks.
- Structured false or unknown location outcomes for non-default, unavailable,
  malformed, cross-device, or changed observations. Xcode, SwiftPM, custom cache
  roots, ownership, activity, protected descendants, and most generated markers
  remain uncollected, so real candidates remain Protected.
- Bounded generated-marker evidence for an exact npm `_cacache` containing
  exact raw `content-v2` and `index-v5` direct-child directories. Observation
  permits at most 256 non-dot direct entries, reads no cache contents, follows
  no symbolic links, and reports missing or wrong-kind entries as false while
  failures, races, and over-limit directories remain structured unknowns.
- Exact raw directory-entry gating for the existing SwiftPM
  `workspace-state.json` marker, including on case-insensitive filesystems.

### Changed

- Scan JSON v2 and classification JSON v1 retain their existing wire shapes.
  Raw candidate timestamps and scan-time identities remain Core-only;
  classification reflects the timestamp only through the existing age finding
  state and generic explanation.
- The CLI built-in catalog is now version 3. `devsift.cache.npm` advances to
  rule revision 2 for its cacache-layout marker; `devsift.swiftpm.build` remains
  at revision 2 and every other rule remains at revision 1. The catalog
  identifier and version come from the Core-owned catalog revision rather than
  duplicate CLI constants; the classification JSON wire shape is unchanged.
- The explainable-classification contract is now revision 2 for trusted-location
  evidence interpretation. The npm marker advances only its rule and the
  built-in catalog; scan JSON v2 and classification JSON v1 remain unchanged.
