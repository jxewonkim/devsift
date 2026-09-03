# Architecture

DevSift uses one safety-critical Swift core shared by its native app and CLI.

```text
DevSift SwiftUI app  --->  DevSiftCore  <---  devsift CLI
                              |
                 scan -> rules -> plan -> diff -> approve -> executor
                   now      now    now    Core      Core      later
                                   |
                                   +-> app review now
```

## Components

### DevSiftCore

The core owns domain models and filesystem behavior. It must not depend on
SwiftUI, command-line formatting, shell commands, analytics, or application
state.

Core layers are:

- **Scanning:** read-only enumeration and allocated-size measurement. The
  current scanner streams metadata into root and top-level summaries rather
  than retaining every path. It anchors traversal to directory descriptors and
  resolves every child relative to its already-open parent. It also carries
  each summary inode's scan-time identity and one bounded, conservative
  newest-observed inode modification-time aggregate per summary;
- **Rules:** versioned, deterministic candidate recognition, evidence findings,
  and conservative policy classification. Rules receive observations rather
  than filesystem URLs; the central classifier alone computes dispositions;
- **Planning:** pure Core transformations from explicit path-and-rule
  selections over a validated classification into policy-provenanced immutable
  drafts, and between compatible drafts into deterministic differences.
  Planning and diffing perform no filesystem I/O, and neither selection nor a
  diff is approval;
- **Approval:** a read-only, Core-only transition from an exact source-bound
  planning request through one opaque review session into an in-memory
  approval. The session owns the exact root and manifest and issues
  session-bound entry references. It permits no partial subset, performs no
  filesystem I/O, and creates neither freshness, authenticity, nor execution
  authority;
- **Execution:** fresh revalidation of an approval and recoverable quarantine,
  introduced only after the earlier layers are stable;
- **Reporting:** structured outcomes without frontend-specific rendering.

### devsift CLI

The CLI parses explicit commands, invokes DevSiftCore, and renders human-readable
or versioned JSON output. Results go to standard output and diagnostics to
standard error. The `scan` and `classify` schemas are versioned independently.
The CLI does not implement independent filesystem rules. It currently has no
plan, plan-review, manifest-import, or manifest-export command.

The executable has a thin process entry point over a testable async runner.
Arguments, filesystem requests, rendering, and exit mapping are exercised
without replacing global standard streams. JSON uses a CLI-owned versioned DTO
rather than making Core domain models directly serializable. Report paths are
root-relative, and exact path-component bytes are retained as Base64.

The CLI target also owns internal review schema
`devsift.cleanup-manifest-review` version 1, explicitly pinned to Core cleanup
manifest contract version 2. It is a one-way, lossy `Encodable` projection for
an already constructed manifest. No command invokes it, and it performs no
standard-stream, file, filesystem, or network I/O. There is no decoder or
import path; the envelope sets `canBeApproved` and `canBeExecuted` to `false`,
and no manifest-diff export, approval, or execution surface accompanies it.

### DevSift app

The current macOS app provides explicit folder selection, distinct
indeterminate scan and policy-analysis states, cancellation, rescan,
observation results, partial-result details, explainable policy assessments,
accessibility, explicit eligible-candidate inclusion, and a read-only in-memory
draft review. Table focus and draft inclusion are separate, and every result
starts with zero included candidates.

Each window owns a `@MainActor` observable view model with injected
`FileSystemScanning`, `RuleClassifying`, and `CleanupPlanning` capabilities. It
passes the file importer's selected URL unchanged to DevSiftCore. A scan UUID
prevents a cancelled or superseded task from publishing a late result over the
current state. Security-scoped access is held until Core scanning,
classification, and result presentation preparation finish, then balanced on
success, failure, or cancellation; later draft planning uses only retained
values and holds no filesystem scope.

The app and CLI validate every returned `RuleClassificationReport` against the
request's reference time and original `ScanReport` before rendering it. This
shared Core boundary checks path coverage, scan-report structure, common
finding states, semantic invariants, and aggregate resource limits; malformed
output never reaches a frontend-specific projection.

The Core planner repeats that validation at its own boundary before joining an
explicit `CleanupCandidateSelection` to a scan summary and rule evaluation by
exact raw path and revision. It requires the classifier's non-public seal over
the exact source request and `RulePolicyProvenance`, so one scan's evidence
cannot be paired with another scan's identities, sizes, or edited policy
metadata. It accepts only matched `reclaimable` or `review-required` decisions,
preserves their evidence and expected identities, and fails the whole request
if any selection is invalid or ambiguous. The result does not include the
absolute root URL and cannot authorize execution.

For the current result, the app retains the exact classification request and
report plus an exact whitelist of presentable `CleanupCandidateSelection`
values. A selection contains one raw path and rule revision, and the view model
ignores any value outside that current-session whitelist. Candidate filtering
is only a conservative UI convenience; Core validation remains authoritative.
The included set is frozen and canonically ordered before the planner runs in a
detached user-initiated task. A planning UUID plus the source scan UUID prevents
cancelled, superseded, or closed-window work from publishing a late result.

The manifest is immediately converted to an app-owned, identity-free review
presentation and discarded. That presentation retains a raw relative path only
as an in-memory row identity and renders escaped display text. It does not
retain root or candidate filesystem identities, the source request or manifest,
reference time, provenance roster, serialization, approval, or execution state.
The visible root scope comes separately from the active scan window. The view
shows all seven stored observation and uncertainty quantities, never guaranteed
savings. It has no persistence, import, export, diff, approval, execution,
execution-time filesystem revalidation, or filesystem capability.

The Core differ first rejects manifest-contract, provenance, or expected-root
identity incompatibility. It then performs an `O(n + m)` merge by exact raw path
and reports every stored entry-field change plus overflow-safe directional
differences for observed totals. It does not infer renames from inode identity,
reopen paths, render output, or create approval state.

The Core approver starts from one exact `CleanupManifestRequest` rather than a
caller-supplied manifest. It runs the concrete planner and returns an opaque
review session that retains the request's exact local root, the resulting
manifest, and entry references bound to a process-local session seal. The
caller can turn only those references into confirmations, and the complete
canonical confirmation sequence must belong to that same session. A mismatched
or foreign-session value fails even when its visible raw path and rule revision
are equal. A subset must first become a new draft and review.

The approval output retains the session's exact root and manifest in memory
without `Codable`, filesystem I/O, clock reads, or mutation capability. The
opaque seal correlates values only inside the current process; it is not a
secret, authenticity proof, proof of human review, or permission to execute.
Neither frontend invokes this contract in the current increment. A future
revalidation request must accept only `CleanupApproval` and reopen the root
stored within it, rather than accepting a separately supplied root, unapproved
manifest, diff, or review projection.

The internal manifest-review projection always removes root and candidate
filesystem identities and has no dedicated absolute-root field. Its redacted
profile removes paths, time, free-form text, and the complete rule roster while
retaining exact sizes plus selected rule and finding identifiers; it is not an
anonymous or automatically share-safe format. Its root-relative-exact profile
includes exact Base64 path components, the exact reference time, escaped
free-form text, and the complete provenance roster. Custom free-form text can
still contain an arbitrary absolute path. Redacted entry ordinals have meaning
only inside one document. Rendering has a cumulative per-entry encoded-size
preflight and final post-encoding check against a 128 MiB cap. Cancellation is
checked around bounded phases, but the final
Foundation `JSONEncoder.encode` call cannot be interrupted before it returns.

## Dependency rules

- Frontends may depend on DevSiftCore; DevSiftCore never imports a frontend.
- Filesystem capabilities are injected so tests can use controlled fixtures.
- Domain values use stable identifiers and deterministic ordering.
- Display strings are never path identity; rules compare exact raw components.
- Concurrency supports cancellation and bounded work.
- External dependencies require a written reason and supply-chain review.
- The initial workspace avoids third-party runtime dependencies.

## Measurement

DevSift distinguishes logical file size from observed allocated disk usage. The
current analysis and draft-review UI displays observations and does not
calculate reclaim estimates. Rules derive policy; draft plans preserve
explicitly selected validated decisions and their uncertainty. Hard links,
sparse files, packages, clones, and filesystem snapshots require explicit
handling and tests rather than naive recursive summation.

The scanner reports apparent bytes separately from hard-link-exclusive
allocated bytes. A hard-linked regular-file inode receives that credit only
when all of its links were observed inside the same summary boundary; links
crossing top-level items or leaving the selected root remain explicitly
non-exclusive. This field does not claim to resolve clone or snapshot sharing.
APFS clones are not deduplicated because file-level APIs do not expose block
ownership. A reported allocated size is therefore a point-in-time estimate, not
a guaranteed reclaimable byte count.

## Evolution rule

Scanning, classification, planning, and execution remain separate stages. A
future optimization must not combine them in a way that allows discovery code
to mutate the filesystem or bypass plan review.

The current planner receives no filesystem capability or descendant URL. It
copies only validated, bounded values into an in-memory draft: the root identity
without its absolute URL, exact root-relative raw paths, expected candidate
identity and kind, classifier-owned policy provenance, rule revision, policy
evidence, and observed allocation estimates. `CleanupCandidateSelection`
identifies a requested path and rule revision; it is not approval. The differ
receives only manifest values and likewise has no filesystem capability.
The app-owned in-memory review projection and CLI-owned JSON projection are not
serialized Core state and carry no authority. The app review is presentational
only. A Core approval review session instead owns its exact planning request,
source root, manifest, and session-bound entry references; it cannot be rebuilt
from either projection. The approval retains the exact root and manifest but
does not make either projection approvable. User-facing export, import,
persistence, diffing, frontend approval, and execution remain separate future
boundaries. The CLI projection's sorted `JSONEncoder` output targets
repeatability only for the same input, privacy profile, implementation build,
and Swift/Foundation runtime; it is not a cryptographic canonical form, stable
digest, signature, or authenticity proof.

The current scan-to-rule adapter projects only facts already present in the
bounded `ScanReport`; it performs no additional filesystem I/O. Rules consume
the modification-time aggregate only for complete item summaries. A separate,
bounded evidence stage reopens each retained top-level candidate to verify the
root and candidate against their scan-time identities. For an exact SwiftPM
`.build` candidate, it additionally observes metadata for an exact
`workspace-state.json` child without following symbolic-link targets.

Scan-time `(device, inode)` values are read-only observation-binding tokens,
not persistent object identities or deletion authority. Copying them into a
draft manifest does not establish trusted location, ownership, approval, or
cleanup authority, and future execution must revalidate containment, kind,
identity, and policy evidence.
Any observer added for the remaining facts must preserve descriptor-relative
traversal and identity checks rather than reconstructing descendant `URL`
values from untrusted names. See the [rules contract](RULES.md) and
[planning contract](PLANNING.md).
