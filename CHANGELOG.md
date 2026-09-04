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
- The initial classification JSON schema version 1, including a bounded
  `scanIntegrity` projection with decimal-string counts and explicit uncertainty
  flags. The deferred-precondition increment below supersedes it with version 2.
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
  roster to classifier reports and, at that planning increment, cleanup
  manifest contract version 2. The deferred-precondition increment below
  supersedes that manifest contract with version 3.
  Presentation-only custom catalogs remain unprovenanced unless they opt into
  an explicit non-built-in catalog revision.
- A Core-only `CleanupManifestDiffer` for deterministic, linear comparison of
  compatible in-memory drafts. Contract, policy-provenance, and expected-root
  mismatches fail closed; exact raw paths identify added, removed, and modified
  entries, and all observed-total changes use overflow-safe directional
  `UInt64` values.
- The initial internal CLI-owned `devsift.cleanup-manifest-review` JSON schema
  version 1 projection, pinned at that increment to cleanup manifest contract
  version 2. The deferred-precondition increment below supersedes both with
  review schema version 2 over source manifest version 3. Its explicit
  redacted and root-relative-exact profiles always omit filesystem identities,
  expose no decoder, and mark the result non-importable, non-approvable, and
  non-executable. The encoder has no CLI command or file-writing path; manifest
  diff export, approval, and execution remain absent from the CLI.
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
  feature. At that approval increment, only an approval-bound revalidation
  layer could consume it; descriptor-relative execution-time checks remained
  later work.
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
  roots, ownership, activity, protected descendants outside the npm profile,
  and most generated markers remain uncollected, so real candidates remain
  Protected.
- Bounded generated-marker evidence for an exact npm `_cacache` containing
  exact raw `content-v2` and `index-v5` direct-child directories. Observation
  permits at most 256 non-dot direct entries, reads no cache contents, follows
  no symbolic links, and reports missing or wrong-kind entries as false while
  failures, races, and over-limit directories remain structured unknowns.
- Exact raw directory-entry gating for the existing SwiftPM
  `workspace-state.json` marker, including on case-insensitive filesystems.
- Descriptor-bound `account-owned-cache-namespace` evidence for an exact
  top-level npm `_cacache` candidate. It is satisfied only when the held
  selected root and held candidate directory both have the current account's
  exact POSIX UID.
  It does not invoke npm, inspect processes or contents, make network calls, or
  infer historical creation, descendant ownership, write ACLs, inactivity, or
  mutation authority.
- Bounded protected-descendant evidence for an exact top-level npm `_cacache`.
  A descriptor-relative, no-follow traversal accepts only the pinned cacache
  raw path-and-kind grammar, an absent or empty `tmp`, same-device current-
  account ownership, and single-link regular files. Stable exceptions are
  protected; permission failures, races, malformed metadata, count drift, and
  entry, depth, or raw-name-byte limits remain structured unknowns. The pass
  reads no file contents and adds no mutation authority.
- A primary-source npm activity capability review and fail-closed contract.
  At that decision-review increment, the unprivileged product could not prove
  subtree-wide inactivity or hold that observation through a later operation,
  so empty process results, quiet-tree sampling, advisory locks, kqueue, and
  FSEvents could not produce `inactive`; npm remained Protected. That increment
  added no process observation, execution, filesystem mutation, policy
  revision, or schema change. The deferred-precondition increment below later
  changed the policy result without changing the unknown activity evidence.
- A narrowly scoped deferred execution-precondition policy for recoverable npm
  quarantine. Runtime activity remains exactly
  `unknown(.notCollected)`; when every non-deferred npm fact passes, the
  classifier emits Review required plus
  `requires-user-attestation-that-responsible-tool-is-stopped@1` instead of
  claiming inactivity.
  The planner and cleanup manifest preserve that condition, the differ treats
  it as a first-class changed field, and revalidation reports it as awaiting an
  execution precondition rather than eligible or rejected.
- Process-local approval-review references and acknowledgements for every
  pending execution precondition. Acknowledgement binds that the condition and
  risk were reviewed; it is copyable, replayable review intent, explicitly not
  an attestation that npm stopped, fresh activity evidence, or execution
  authority.
- Deferred-precondition disclosure in classification text and JSON, the
  internal manifest-review JSON projection, and the native draft review. The
  app says activity remains unobserved and provides no attestation or approval
  action.
- Core-only, in-memory quarantine-attempt authorization contract version 1.
  `CleanupQuarantineAuthorizer.beginAttempt(for:)` retains one exact canonical
  approval and exposes one `CleanupQuarantineAttestationRequest` covering its
  complete ordered npm pending set. After canonical built-in validation, the
  public default independently pins classifier revision 3 and catalog revision
  6, with drift reported as `unsupportedApprovalPolicy`. It directly pins npm
  rule revision 5, responsible tool `npm`, precondition policy revision 1, and
  statement policy revision 1; requirement drift fails as
  `unsupportedAttestationRequirements`.
- Explicit `CleanupQuarantineUserAttestation` caller assertions scoped by
  process-local attempt identity. An assertion is not observed inactivity,
  proof of human action or understanding, caller authentication, or standalone
  filesystem authority. Cross-attempt substitution fails, and no clock or TTL
  supplies freshness.
- Shared actor-backed attempt lifecycle. At most one authorization issuance and
  one internal executor handoff can succeed for an attempt across all value
  copies; cancellation is terminal. Wrong-attempt or wrong-statement input may
  be corrected while the session remains open, while observed task cancellation
  clears retained state and throws `CancellationError`. The public API exposes
  no consume method, executor, quarantine, receipt, recovery, restore, purge,
  deletion, frontend action, or CLI action and performs no process, npm, clock,
  or filesystem I/O.
- Core-internal npm `_cacache` quarantine execution kernel. It consumes only the
  authorization's internal single-use claim, independently rechecks the exact
  classifier-3/catalog-6/npm-5 policy shape, and descriptor-reopens the real
  account's exact `~/.npm` root and sole approved candidate.
- Exhaustive descriptor-held execution preflight for the pinned cacache grammar,
  current-account ownership, same-device containment, identity and mutation
  stability, no non-owner POSIX writes, no subtree extended ACL, single-link
  regular files, bounded traversal, and an inclusive seven-day modification-
  time floor.
- Same-volume, non-overwriting atomic quarantine into a verified private
  `.devsift-quarantine-v1` directory using `renameatx_np` with `RENAME_EXCL`,
  `RENAME_NOFOLLOW_ANY`, and `RENAME_RESOLVE_BENEATH`. Destination collisions
  are bounded; copy, unlink, shell, npm invocation, and permanent deletion are
  absent.
- The quarantine mutation path requires macOS 26 or newer for
  `RENAME_RESOLVE_BENEATH`. On older supported macOS versions it rejects the
  attempt before creating quarantine state or invoking a mutation syscall.
- Post-rename source/destination reconciliation, non-overwriting reverse-rename
  rollback, and bounded manual-recovery outcomes. Cancellation after rename is
  latched into the report while reconciliation and rollback continue.
- Internal process-local `CleanupQuarantineExecutionReport` contract version 1.
  A verified move is `quarantinedAwaitingReceipt`, not completed: durable
  intent, receipt, sync, startup recovery, restore, public API, app action, and
  CLI action remain absent.
- A Core-internal durable quarantine journal with canonical version-1 intent
  and receipt records. It preplans all 16 exclusive destination names, publishes
  immutable records through exclusive staged renames, and requires
  `F_FULLFSYNC` barriers for records, the npm root, and the quarantine root.
- A descriptor-bound recovery engine that runs under a validated nonblocking
  account-owned lock before new intent creation and can also reopen an existing
  npm quarantine namespace without requiring `_cacache` to exist. It validates
  bounded inventory, record pairing, and current namespace truth for
  receipt-less intents, then records only a provable `not-moved` or
  `quarantined` outcome. It never resumes, restores, rolls back, unlinks, or
  overwrites an interrupted transaction.
- Internal `CleanupQuarantineExecutionReport` contract version 2. It separates
  no record, durable intent, durable terminal receipt, and unresolved state;
  only a receipt is durably recorded, and unresolved state is not declared
  crash-recoverable even when it carries a transaction identifier.

### Changed

- The explainable-classification contract is revision 3, the built-in catalog
  is version 6, and `devsift.cache.npm` is rule revision 5. SwiftPM remains at
  revision 2 and every other built-in rule remains at revision 1.
- Cleanup manifest is contract version 3, manifest diff is contract version 2,
  approval is contract version 2, revalidation is contract version 2, and
  quarantine authorization is contract version 1. Older in-memory manifests
  and approvals must be regenerated; there is no import migration.
- Scan JSON remains version 2. Classification JSON is version 2, and the
  internal cleanup-manifest-review JSON is version 2 pinned to source manifest
  version 3. Both projections always carry the sorted deferred-precondition
  array. Older exports are not imported or migrated and must be regenerated.
- The project selected the user-attested policy option only for recoverable
  quarantine. `CleanupQuarantineAuthorization` now combines one exact approval
  with an explicit attempt-scoped caller assertion and process-local
  single-use lifecycle. It authorizes no permanent deletion, still requires
  inline filesystem revalidation, and grants no standalone mutation authority.
  The Core-internal npm executor can consume that handoff for one atomic
  quarantine move. The later durability increment advances its process-local
  report to contract version 2 and adds private durable intent, receipt, sync,
  and recovery. Restore, purge, deletion, public API, frontend actions, and
  automatic app-launch recovery remain absent.
- New journal intents require the exact current policy tuple, while canonical
  records carrying supported earlier revisions remain readable. Unknown, zero,
  and future revisions fail closed, preventing routine policy upgrades from
  poisoning completed history or inert intent stages.
- Crash-recoverable report state now requires canonical, reachable journal
  evidence with structurally admissible inventory. Detached, malformed,
  orphaned, or conflicting state is reported as unresolved; a valid pending
  intent may still require manual resolution when live namespace truth is
  ambiguous.
