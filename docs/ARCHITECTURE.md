# Architecture

DevSift uses one safety-critical Swift core shared by its native app and CLI.

```text
DevSift SwiftUI app  --->  DevSiftCore  <---  devsift CLI
                              |
                 scan -> rules -> plan/diff -> executor
                   now      now    Core now      later
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
- **Execution:** revalidation and recoverable quarantine, introduced only after
  the earlier layers are stable;
- **Reporting:** structured outcomes without frontend-specific rendering.

### devsift CLI

The CLI parses explicit commands, invokes DevSiftCore, and renders human-readable
or versioned JSON output. Results go to standard output and diagnostics to
standard error. The `scan` and `classify` schemas are versioned independently.
The CLI does not implement independent filesystem rules. It currently has no
plan command or manifest serialization contract.

The executable has a thin process entry point over a testable async runner.
Arguments, filesystem requests, rendering, and exit mapping are exercised
without replacing global standard streams. JSON uses a CLI-owned versioned DTO
rather than making Core domain models directly serializable. Report paths are
root-relative, and exact path-component bytes are retained as Base64.

### DevSift app

The current macOS app provides explicit folder selection, distinct
indeterminate scan and policy-analysis states, cancellation, rescan,
observation results, partial-result details, explainable policy assessments,
and accessibility. Draft-manifest creation and plan review are not exposed in
the app yet.

Each window owns a `@MainActor` observable view model with injected
`FileSystemScanning` and `RuleClassifying` capabilities. It passes the file
importer's selected URL unchanged to DevSiftCore. A scan UUID prevents a
cancelled or superseded task from publishing a late result over the current
state. Security-scoped access is held until Core scanning, classification, and
presentation preparation finish, then balanced on success, failure, or
cancellation.

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

The Core differ first rejects manifest-contract, provenance, or expected-root
identity incompatibility. It then performs an `O(n + m)` merge by exact raw path
and reports every stored entry-field change plus overflow-safe directional
differences for observed totals. It does not infer renames from inode identity,
reopen paths, render output, or create approval state.

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
current UI displays observations and does not calculate reclaim estimates.
Rules derive policy; draft plans preserve explicitly selected validated
decisions and their uncertainty. Hard links, sparse files, packages, clones,
and filesystem snapshots require explicit handling and tests rather than naive
recursive summation.

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
Codable export, persistence, frontend review, approval, and execution are
separate future boundaries.

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
