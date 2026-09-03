# Safety model

DevSift treats filesystem cleanup as a security-sensitive transaction rather
than a convenience command.

## Trust classes

Every recognized item belongs to one of three policy classes:

- **Reclaimable:** generated and reproducible data with strong ownership and
  lifecycle evidence.
- **Review required:** data that may be reclaimable but needs context or an
  explicit user decision.
- **Protected:** user content, active data, unknown data, broad system paths, or
  anything that fails a safety check.

Unknown is protected, not reclaimable or review-required.

## Required workflow

Cleanup functionality must preserve this ordering:

`scan -> classify -> plan -> approve -> revalidate -> quarantine -> report`

Scanning and planning are read-only. A plan records the exact candidate,
evidence, expected identity, rule version, and estimated allocated bytes. Before
any mutation, DevSift must revalidate that the item is still the same item and
still inside its approved root.

The current Core planner produces only an immutable policy-provenanced draft,
and the Core differ compares only compatible drafts. An explicit
`CleanupCandidateSelection` binds an exact root-relative raw path to an exact
rule revision, but selection and diff output are not approval. Core can now
record explicit intent for one fully confirmed reviewed manifest. Core now has
an approval-only, read-only revalidation diagnostic. Execution, quarantine, and
deletion APIs do not exist in this phase.

The native app can include an explicit subset of conservative candidates and
show Core's result as an unapproved in-memory review. Inclusion starts at zero
and is independent from table-row focus. The app's exact current-session
path-and-rule-revision whitelist is only a UI restriction; it cannot weaken or
replace the planner's complete fail-closed validation. The review has no save,
load, import, export, diff, approval, execution, live-filesystem revalidation,
or mutation operation.

The Core approval boundary is not wired to the app or CLI. It prepares an
opaque review session from the exact source-bound planning request, retaining
the exact source root and Core-built manifest. Every entry reference and
confirmation is bound to that process-local session. The complete canonical
sequence is required, and foreign, mismatched, missing, duplicate, or reordered
input rejects the request. It never grants a partial subset: changing the set
requires a new draft and review session. The resulting approval retains the
exact root and manifest in memory, is non-`Codable`, performs no filesystem I/O,
and is neither fresh evidence, authentication, nor execution authority.

The CLI target has an internal one-way review JSON encoder over an already
constructed manifest. No command or file-writing workflow invokes it. It is
non-importable, cannot reconstruct or diff a manifest, and explicitly declares
that its document cannot be approved or executed.

`CleanupRevalidator` accepts only an in-memory `CleanupApproval`, rescans the
approval's retained root, and uses only current built-in policy provenance. It
requires the observed root identity to match, then emits canonical diagnostic
statuses after reobserving each approved path, kind, device, identity, rule,
findings, and policy decision. Incomplete and unknown observations fail closed.
Its root-URL-free, non-`Codable` report is point-in-time and copyable; it is not
freshness proof, mutation authority, or executor input. Current real entries
remain Protected. Exact default uv, npm, and Homebrew containers can satisfy
trusted location, and npm may satisfy its supported cacache-layout marker.
An exact top-level npm `_cacache` may also satisfy
`account-owned-cache-namespace` when the held selected root and held candidate
both have the current account's exact POSIX UID. That narrow fact replaces
generic tool ownership only for npm; it is not mutation authority. npm activity
and protected descendants remain
uncollected, while other rules retain unknown tool ownership and other required
facts.

## Hard invariants

- A scan root is explicit; there is no implicit whole-disk cleanup.
- Planning is a pure transformation over bounded, validated scan and
  classification values. It performs no filesystem I/O and has no mutation
  capability.
- Planning requires classifier-sealed provenance containing the classification
  contract, catalog revision, and complete rule-revision roster. Missing,
  edited, or undeclared provenance fails closed.
- A selected candidate must resolve unambiguously to one matched evaluation
  with a `Reclaimable` or `Review required` disposition and only satisfied
  findings. Selection cannot override `Protected`, unknown, partial,
  conflicting, invalid, or incomplete state.
- The app includes no candidate automatically. Row focus never changes the
  included set, and only an exact path-and-rule-revision value from the current
  result's whitelist can enter it. Core remains the final authority.
- A draft manifest is not approval or an execution capability. It stores no
  absolute root URL, and copying expected identities into it grants no path
  authority.
- Approval review must begin from the exact source-bound planning request. Core
  alone creates the reviewed manifest and binds its exact local root; callers
  cannot substitute either value at approval time.
- Every entry reference and confirmation is bound to one opaque process-local
  review session, canonical ordinal, exact raw path, and rule revision. Missing,
  extra, duplicate, reordered, changed, or foreign-session confirmations fail
  atomically even when their visible values are otherwise equal.
- Partial approval is forbidden. A different entry set requires a new draft
  and review rather than transferring intent from an old manifest or diff.
- A Core approval is in-memory, non-`Codable` intent only. It retains the exact
  source root and reviewed manifest but establishes no freshness, authenticity,
  signature, proof of human review, single-use semantics, execution capability,
  filesystem authority, or permission to mutate the filesystem.
- Approval performs no filesystem or network I/O. Future execution-time
  revalidation must accept only `CleanupApproval` and reopen the root stored
  within it, rather than accepting a separately supplied root, standalone draft,
  diff, app presentation, or CLI review document.
- Revalidation accepts only `CleanupApproval`, uses its retained root, and
  accepts only current built-in policy provenance. It returns canonical,
  point-in-time diagnostic entries; incomplete or unknown observations fail
  closed. Its report omits the absolute root URL and is not an execution input
  or filesystem capability.
- Revalidation does not make a later operation race-free. A future executor
  must receive the approval rather than the report and revalidate containment,
  kind, device, identity, activity, and current policy inline while holding
  verified descriptors immediately before mutation.
- App planning reuses the exact retained classification request and report,
  freezes the selected set, and runs without a filesystem capability or active
  security scope. Planning and scan-session tokens must reject any late result
  after cancellation, rescan, root change, or window closure.
- The app-owned review projection retains no filesystem identity, manifest,
  source request, provenance roster, reference time, serialization, approval,
  or execution state. Its raw relative path is only an in-memory row identity;
  the UI renders escaped text.
- All seven displayed size and uncertainty quantities are point-in-time
  observations, not promised reclaimed bytes. A legitimate current scan can
  expose zero eligible candidates.
- The CLI-owned review projection is lossy, non-importable, and never an
  executor input. It always omits root and candidate filesystem identities,
  sets `canBeApproved` and `canBeExecuted` to `false`, and defines no diff
  export, approval, or execution operation.
- Redaction is not anonymity. Redacted documents retain exact observed sizes
  and totals plus selected rule and finding identifiers; their entry ordinals
  identify entries only inside that one document. Exact-profile documents also
  contain raw Base64 paths, the exact reference time, and escaped free-form
  text.
- Having no dedicated absolute-root field is not sanitization. Trusted custom
  free-form text in an exact document can contain an arbitrary absolute path.
- Manifest diffing requires the same supported manifest contract, exactly equal
  policy provenance, and exactly equal expected root identity before examining
  entries. An incompatibility never produces a partial or "unchanged" result.
- Diff identity is the exact raw relative path. Candidate identities do not
  imply rename, sameness, freshness, ownership, or cleanup authority.
- An empty diff or unchanged entry means only that retained manifest fields are
  equal. It does not prove that disk contents are unchanged or safe to mutate.
- Directory enumeration is anchored to an opened root descriptor. Descendants
  are opened relative to verified parent descriptors and symbolic links are not
  followed.
- Mounted descendants on a different device are reported and not traversed.
- Scan depth, entry count, top-level output, hard-link accounting, and recorded
  issue count have explicit limits; a reached limit produces a partial result
  rather than silent omission.
- A candidate cannot escape its approved root through symlinks, aliases, path
  normalization, mounts, or race conditions.
- Broad paths such as `/`, `/System`, `/Applications`, `/Users`, and a home
  directory itself are protected cleanup targets.
- Scan code cannot mutate files.
- The app and CLI expose no cleanup, delete, move, quarantine, or
  permission-escalation action; scan and classification reports remain
  read-only.
- The app never presents a partial, bounded, or overflowed observation as
  complete or as evidence that an item can be cleaned.
- Core logic does not construct or execute shell commands.
- Failure to read metadata produces a visible error or skip, never permission
  escalation or an unsafe assumption.
- A newest observed inode modification time is not proof of inactivity,
  ownership, generated content, or the absence of protected descendants. An
  incomplete item never turns its partial maximum into known age evidence.
- A scan-time `(device, inode)` pair is only a token for binding a later
  read-only observation. It is not trusted-location or ownership evidence and
  grants no cleanup or deletion authority; inode reuse requires immediate
  revalidation before any future mutation.
- A trusted-location result for uv, npm, or Homebrew requires both the exact
  current-account default container path and a stable descriptor identity match.
  It proves no tool ownership, inactivity, descendant safety, or mutation
  authority. Environment and configuration overrides are not trusted inputs.
- A satisfied npm `account-owned-cache-namespace` finding proves only that the
  held selected-root and `_cacache` directory metadata carry the exact current
  non-root POSIX account UID. It does not prove historical creator or npm
  provenance, ownership of every descendant, write ACLs or effective access,
  cache content, inactivity, or mutation authority. A UID mismatch fails the
  finding; unavailable account metadata stays unknown. No npm invocation,
  process inspection, content read, or network request contributes to it.
- A satisfied SwiftPM `workspace-state.json` marker proves only that the exact
  metadata check passed. It does not override an unavailable required fact, so
  the candidate remains `Protected`.
- A satisfied npm generated marker proves only that bounded direct-child
  metadata matched the supported `content-v2` and `index-v5` cacache layout. It
  does not prove npm ownership, inspect cached content, or grant mutation
  authority.
- A candidate remains `Protected` when a required activity check reports active
  use or is unavailable. npm also remains `Protected` while its required
  protected-descendant finding is unavailable.
- A changed candidate is skipped during revalidation.
- Partial failures are reported item by item.
- Permanent deletion is not part of the initial milestones.

The next npm policy increment will add bounded protected-descendant evidence.
Activity observation remains the last eligibility fact and must be coordinated
with the future executor's descriptor-held revalidation immediately before a
recoverable operation; a prior inactivity observation is not execution
authority.

Cancellation is safe but may not be instantaneous. A blocking filesystem call
can finish before the next cancellation checkpoint is reached. The scanner
still performs no filesystem mutation while cancellation unwinds. The internal
review encoder checks cancellation during validation, projection, and its
per-entry size preflight, but the single final Foundation `JSONEncoder.encode`
call cannot be interrupted until it returns. Cancellation observed after that
call returns no partial document. Native app draft planning and identity-free
projection run away from the main actor and check cooperative cancellation;
token validation prevents an ignored or late cancellation from publishing
stale review state. Core approval checks cancellation at phase boundaries and
while validating the complete confirmation sequence. Deep source validation
and whole-manifest equality can finish before the next checkpoint, but
cancellation produces no partial approval.

Revalidation is also cooperative: it checks cancellation at bounded phase
boundaries and while producing entry diagnostics. A scanner or classifier call
already in progress may finish before its next checkpoint. Cancellation returns
no partial revalidation report.

## Rule requirements

A cleanup rule must declare:

- a stable identifier and version;
- the tool or workflow responsible for the data;
- positive evidence used to identify a candidate;
- exclusions and protected descendants;
- an eligible disposition and reproducibility class;
- required activity and age checks;
- user-facing explanations;
- synthetic tests for matches, near misses, and hostile paths.

Path shape alone is insufficient for a high-confidence rule when the path can
contain user-owned content.

The current classifier enforces common integrity checks centrally. Rules only
recognize raw path shapes and project declared evidence; they cannot directly
grant a disposition. An unavailable required fact, invalid rule assessment,
classification conflict, or incomplete scan produces `Protected`. A malformed
returned report is rejected against the request's reference time and original
`ScanReport` before either frontend renders it. The adapter performs no extra
filesystem probing and may project the conservative newest inode time already
retained by a complete scan summary. A separate bounded observer may rebind
retained top-level candidates to their scan-time identities and, for an exact
SwiftPM `.build` directory, inspect only the metadata of an exact
`workspace-state.json` child. A satisfied age or marker check alone is
insufficient: every remaining unknown required fact keeps the real candidate
protected. See the complete [rules contract](RULES.md).

The planner validates that classification again before processing any
selection. It requires the classifier's exact in-memory source-request and
policy-provenance seal, then joins selections to retained scan summaries and
evaluations by exact raw path and rule revision. This prevents cross-scan
evidence, identity, and policy mixing. It rejects duplicate or ambiguous inputs
and fails the complete request rather than silently omitting an ineligible
selected item. Its immutable output retains evidence for later review, but does
not re-observe the filesystem or make previously unknown evidence known.

The differ validates compatibility and bounded manifest invariants before a
linear raw-path merge. It compares every stored entry field, represents total
changes with directional `UInt64` magnitudes, and checks cancellation during
bounded work. It never reads a path or transfers approval between drafts. See
the [planning contract](PLANNING.md).

The approver creates one opaque review session from an exact source-bound
planning request, then accepts only that session's complete per-entry
confirmation sequence. The session binds its source root, full manifest,
canonical ordinals, raw paths, and rule revisions without deriving intent from
a diff or lossy projection. Its process-local seal prevents cross-session value
mixing but is not proof of human review or authenticity. The revalidator is a
read-only diagnostic that consumes only the approval and reopens its stored
root. A future executor must independently establish policy and object
evidence inline while holding verified descriptors before any mutation. See
the [planning contract](PLANNING.md) and [revalidation contract](REVALIDATION.md).

The internal review encoder accepts only Core manifest contract version 2 and
emits CLI schema `devsift.cleanup-manifest-review` version 1. A per-entry
encoded-size preflight and final post-encoding check enforce a 128 MiB hard
cap. Sorted `JSONEncoder` bytes target repeatability only for the same validated
input, privacy profile, implementation build, and Swift/Foundation runtime;
they are not a cryptographic canonical representation, stable digest,
signature, authenticity proof, or approval token.

## Test boundary

All filesystem tests use newly created temporary directories and synthetic
fixtures. Tests never point at a real home directory, tool cache, project,
simulator, virtual machine, or browser profile. Mutation tests must assert that
nothing outside the fixture changed.

Planner tests additionally verify that constructed or synthetic fixture state
is unchanged before and after planning, including when validation fails.
Manifest-diff tests use only in-memory synthetic drafts and include incompatible
inputs, non-UTF-8 path collisions, full-width quantities, and maximum bounds.
Manifest-review projection tests use synthetic in-memory drafts and cover both
privacy profiles, exact identity omission, document-local ordinals, unsupported
source versions, non-importable authority flags, deterministic same-runtime
bytes, output limits, and cancellation without writing files.

Native app draft-review tests use only synthetic values and cover conservative
eligibility, default-zero and exact-whitelist selection, exact source-request
and report reuse, off-main planning, frozen selection, cancellation, stale
results, lifecycle invalidation, bounded generic failures, escaped display,
identity omission, canonical ordering, and all seven observed quantities.

Approval tests use source-bound synthetic planning requests and cover opaque
session preparation, exact root and manifest retention, complete confirmations,
missing, extra, duplicate, reordered, changed, and foreign-session input,
cross-root and cross-manifest substitution, planning bounds, pre-cancel
rejection, non-UTF-8 raw-path identity, and the absence of filesystem,
serialization, freshness, authentication, and execution authority.

Any future permanent-removal feature requires a separate design review, threat
model, and release milestone.
