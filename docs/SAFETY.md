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

Unknown is protected, not reclaimable or review-required, except for one
versioned policy deferral: npm activity may remain exactly
`unknown(.notCollected)` while an otherwise valid npm candidate becomes Review
required with `requires-user-attestation-that-responsible-tool-is-stopped@1`.
That exception records a pending execution condition; it is neither inactivity
evidence nor operation authority.

## Required workflow

Cleanup functionality must preserve this ordering:

```text
scan -> classify -> plan -> review/approve -> authorize attempt
  -> inline descriptor revalidation -> durable quarantine -> recover/report
canonical quarantined receipt -> confirm restore -> authorize restore
  -> inline descriptor revalidation -> durable manual restore -> recover/report

optional read-only diagnostic: approval -> CleanupRevalidator -> report
```

Current versions are classifier contract 3, cleanup manifest 3, manifest diff
2, approval 2, revalidation 2, quarantine authorization 1, internal quarantine
execution report 2, restore authorization 1, restore report 1, classification
JSON 2, and internal manifest-review JSON 2 over source manifest 3. npm is rule
revision 5 in built-in catalog 6. Scan JSON remains version 2. Old manifests,
approvals, and exports are regenerated rather than imported or migrated.

Scanning and planning are read-only. A plan records the exact candidate,
evidence, expected identity, rule version, and estimated allocated bytes. Before
any mutation, DevSift must revalidate that the item is still the same item and
still inside its approved root.

The current Core planner produces only an immutable policy-provenanced draft,
and the Core differ compares only compatible drafts. An explicit
`CleanupCandidateSelection` binds an exact root-relative raw path to an exact
rule revision, but selection and diff output are not approval. Core can now
record explicit intent for one fully confirmed reviewed manifest and its
pending execution conditions. Core now has an approval-only, read-only
revalidation diagnostic, a Core-defined in-memory quarantine-attempt authorizer,
and an internal npm-only atomic quarantine kernel. The kernel now surrounds its
rename with canonical immutable intent/receipt publication, required
`F_FULLFSYNC` barriers, and descriptor-bound recovery. Core also has a separate
internal, explicitly confirmed, single-item npm restore path with its own
authorization, intent, receipt, and bounded diagnostics. Purge, permanent
deletion, public mutation API, automatic restore, and automatic app-launch
recovery do not exist. The source-run app can reach both kernels only through
narrow package-scoped facades for one exact npm cache at the current non-root
account's passwd-home `~/.npm/_cacache`; the CLI and public Core API remain
read-only.

The native app can include an explicit subset of conservative candidates and
show Core's result as an unapproved in-memory review. Inclusion starts at zero
and is independent from table-row focus. The app's exact current-session
path-and-rule-revision whitelist is only a UI restriction; it cannot weaken or
replace the planner's complete fail-closed validation. The review has no save,
load, import, export, or diff operation. A pending npm condition is shown as
unobserved policy metadata, never as proof that npm is inactive.

For the sole supported npm transaction, the app retains the opaque Core review
session separately from its lossy presentation. Every entry reference and
confirmation is bound to that process-local session. Approval requires the
complete canonical entry confirmations and pending-condition review
acknowledgements; foreign, mismatched, missing, duplicate, or reordered input
rejects the request. A review acknowledgement says only that the condition and
risk were reviewed. Before quarantine, the app then requires two independent
confirmation gates: a stopped-npm/unobserved-risk value and a final confirmation
of the same-volume move. Only after the final action does the app-local workflow
derive the approval, begin a fresh Core attempt, and construct the attestation
from Core's exact requested statement. It passes only the resulting
authorization to the package-scoped executor. Neither confirmation is activity
evidence, authentication, or general filesystem authority.

The resulting approval retains the exact root and manifest in memory, is non-
`Codable`, and is not itself mutation authority. After final confirmation, the
app-local workflow derives and briefly holds the Core approval, authorization
session, attestation, and authorization before passing the authorization to the
package-scoped executor. The UI and presentation receive none of those values;
the app cannot supply a raw root, path, transaction identifier, journal record,
or execution claim. Core performs fresh descriptor-held validation before any
rename.

The CLI target has an internal one-way review JSON encoder over an already
constructed manifest. No command or file-writing workflow invokes it. It is
non-importable, cannot reconstruct or diff a manifest, and explicitly declares
that its document cannot be approved or executed.

`CleanupRevalidator` accepts only an in-memory `CleanupApproval`, rescans the
approval's retained root, and uses only current built-in policy provenance. It
requires the observed root identity to match, then emits canonical diagnostic
statuses after reobserving each approved path, kind, device, identity, rule,
findings, and policy decision. Incomplete and unknown observations fail closed,
except that the one canonical deferred npm activity finding remains explicitly
pending rather than becoming eligible. Its root-URL-free, non-`Codable` report
is point-in-time and copyable; it is not freshness proof, mutation authority,
or executor input. Current real entries mostly remain Protected. Exact default
uv, npm, and Homebrew containers can satisfy
trusted location, and npm may satisfy its supported cacache-layout marker.
An exact top-level npm `_cacache` may also satisfy
`account-owned-cache-namespace` when the held selected root and held candidate
both have the current account's exact POSIX UID. That narrow fact replaces
generic tool ownership only for npm; it is not mutation authority. A separate
bounded traversal may satisfy npm's protected-descendant exclusion only for a
stable same-device, current-account-owned tree whose names and kinds match the
pinned cacache grammar and whose count matches the earlier scan. npm activity
remains `unknown(.notCollected)`; an otherwise unchanged npm entry is reported
as `awaitingExecutionPreconditions`, not eligible, inactive, or authorized.
Other rules retain unknown tool ownership, protected-descendant evidence, and
other required facts.

`CleanupQuarantineAuthorizer.beginAttempt(for:)` validates and retains one
exact approval, then exposes one request for an explicit caller assertion over
its complete canonical npm pending set. After canonical built-in approval
validation, version 1 independently pins classifier revision 3 and catalog
revision 6, then directly pins npm rule revision 5, tool `npm`, precondition
policy revision 1, and statement policy revision 1. The assertion is not
observed inactivity, proof of human action, or authentication. Process-local
identity rejects cross-attempt replay without a clock or TTL. Authorization
issuance and the internal handoff are each atomic and at most once across all
copies; cancellation is terminal. Version 1 is recoverable-quarantine-only,
requires inline filesystem revalidation, and grants no standalone mutation
authority. No consumer or executor is public; the internal npm executor is
the sole consumer. See the [authorization contract](AUTHORIZATION.md) and
[quarantine execution contract](QUARANTINE.md).

Manual restore does not reuse quarantine authorization. An explicit inventory
load first runs recovery, final reread/revalidation, and projection under one
validated exclusive lock. It admits only canonical durable `quarantined`
receipts not already restored. Malformed or unresolved journal state, unsafe
parents, and aggregate resource exhaustion fail the entire request. Individual
item failures remain visible as non-restorable rows. The UI receives
deterministic bounded rows, honest source/item readiness, and opaque process-
local references—not paths, record bytes, or transaction identifiers.

From one ready opaque reference, Core selects the exact canonical transaction,
generates a new restore transaction identifier, and requires a separate
process-local confirmation.
Restore authorization version 1 is single-use and grants no standalone,
overwrite, purge, or deletion authority. Its internal executor reopens the
fixed account-owned npm namespace, validates the receipt-bound item and current
cacache tree through held descriptors, publishes a durable restore intent, and
may invoke one exclusive reverse rename only while `_cacache` is absent.
Observational recovery may finish a conclusive restore receipt but never retries
that rename. Neither recovery nor restore runs automatically at app launch. See
the [manual restore contract](RESTORE.md).

## Hard invariants

- A scan root is explicit; there is no implicit whole-disk cleanup.
- Planning is a pure transformation over bounded, validated scan and
  classification values. It performs no filesystem I/O and has no mutation
  capability.
- Planning requires classifier-sealed provenance containing the classification
  contract, catalog revision, and complete rule-revision roster. Missing,
  edited, or undeclared provenance fails closed.
- A selected candidate must resolve unambiguously to one matched evaluation
  with a `Reclaimable` or `Review required` disposition and no non-deferred
  blocking findings. The only allowed deferred shape is one activity
  `unknown(.notCollected)` paired with the sole canonical precondition on a
  Review-required result. Valid custom rules can opt in; the current built-in
  catalog does so only for npm. Selection cannot override `Protected`, another
  unknown reason, active use, partial, conflicting, invalid, or incomplete
  state.
- The app includes no candidate automatically. Row focus never changes the
  included set, and only an exact path-and-rule-revision value from the current
  result's whitelist can enter it. Core remains the final authority.
- A draft manifest is not approval or an execution capability. It stores no
  absolute root URL, and copying expected identities or pending preconditions
  into it grants no path authority.
- Approval review must begin from the exact source-bound planning request. Core
  alone creates the reviewed manifest and binds its exact local root; callers
  cannot substitute either value at approval time.
- Every entry confirmation and precondition review acknowledgement is bound to
  one opaque process-local review session, canonical ordinal, exact raw path,
  and rule revision. Missing, extra, duplicate, reordered, changed, or foreign-
  session values fail atomically even when their visible values are otherwise
  equal. A precondition review acknowledgement is not a user attestation or
  satisfaction of the condition.
- Partial approval is forbidden. A different entry set requires a new draft
  and review rather than transferring intent from an old manifest or diff.
- A Core approval is in-memory, non-`Codable` intent only. It retains the exact
  source root and reviewed manifest but establishes no freshness, authenticity,
  signature, proof of human review, single-use semantics, execution capability,
  filesystem authority, or permission to mutate the filesystem.
- A timestamp or wall-clock TTL must not turn an approval, entry confirmation,
  precondition review acknowledgement, attestation, or diagnostic into
  freshness. The authorization attempt uses process-local identity and shared
  single-use state; the internal executor performs inline descriptor-held
  checks.
- Approval performs no filesystem or network I/O. It cannot be passed directly
  to the executor. `CleanupQuarantineAuthorizer` instead binds the exact
  approval to an explicit, attempt-scoped caller assertion and process-local
  single-use `CleanupQuarantineAuthorization`.
- A precondition review acknowledgement remains copyable, replayable review
  intent. `CleanupQuarantineUserAttestation` is the distinct caller assertion
  bound to the authorization attempt, but is not observed activity, human
  proof, authentication, or standalone mutation authority.
- All authorization copies share one atomic internal-consumption state.
  Authorization is recoverable-quarantine-only, authorizes no permanent
  deletion, requires inline filesystem revalidation, and grants no standalone
  filesystem mutation authority. Its consumer and execution claim are not
  public.
- Revalidation accepts only `CleanupApproval`, uses its retained root, and
  accepts only current built-in policy provenance. It returns canonical,
  point-in-time diagnostic entries; incomplete or unknown observations fail
  closed. Its report omits the absolute root URL and is not an execution input
  or filesystem capability.
- Revalidation does not make a later operation race-free. The internal executor
  receives only `CleanupQuarantineAuthorization`, never the approval or report
  directly, and revalidates containment, kind, device, identity, age, activity
  policy, full grammar, ownership, and destination safety inline while holding
  verified descriptors through mutation.
- App planning reuses the exact retained classification request and report,
  freezes the selected set, and runs without a filesystem capability or active
  security scope. Planning and scan-session tokens must reject any late result
  after cancellation, rescan, root change, or window closure.
- The app-owned review projection retains no filesystem identity, manifest,
  source request, provenance roster, reference time, serialization, approval,
  attestation, authorization, or execution state. It may retain the fixed
  pending-precondition identifier and policy revision as disclosure metadata.
  Its raw relative path is only an in-memory row identity; the UI renders
  escaped text. The opaque Core review session is retained separately and
  cannot be reconstructed from that projection.
- All seven displayed size and uncertainty quantities are point-in-time
  observations, not promised reclaimed bytes. A legitimate current scan can
  expose zero eligible candidates.
- The CLI-owned review projection is lossy, non-importable, and never an
  executor input. It always omits root and candidate filesystem identities,
  sets `canBeApproved` and `canBeExecuted` to `false`, and defines no diff
  export, approval, attestation, authorization, or execution operation. Both
  privacy profiles retain fixed pending-precondition identifiers and revisions.
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
- DevSift resolves both quarantine rename operands beneath the held approved-
  root descriptor, so its syscall cannot escape that root through symlinks,
  aliases, path normalization, mounts, or a quarantine-root reparent race.
  Same-account namespace replacement remains an accepted, post-detected race;
  it can redirect the move only within the held root and does not yield a
  success report when reconciliation observes the quarantine-root binding
  change.
- Manual restore accepts only the item selected by one canonical final
  `quarantined` receipt. It reopens the fixed passwd-home npm and quarantine
  roots, matches their historical bindings, validates the current held item and
  bounded cacache tree, and refuses an occupied `_cacache`; no caller-selected
  path or item name reaches the rename.
- Initial inventory loading and manual refresh require an explicit action and
  never run at app launch. When a restore execution returns to the still-current,
  uncancelled view-model operation, it schedules one reconciliation and
  inventory refresh. Dismissal, cancellation, or superseding work can prevent or
  cancel that refresh and suppresses stale UI publication.
  Recovery, complete canonical reread/revalidation, and projection share one
  validated exclusive lock. Malformed or unresolved journal state, unsafe
  parents, and aggregate resource exhaustion fail the whole request.
- Inventory contains only canonical durable quarantined receipts not already
  restored, in deterministic bounded order. Its opaque process-local references
  cannot cross sessions. Source readiness distinguishes a missing original name,
  the previously expected object, and another occupant. Item readiness reports
  available, missing, changed, unsafe, and over-bound contents.
- Restore uses a fresh process-local confirmation and single-use authorization,
  then at most one same-volume, no-follow, beneath-root, exclusive reverse
  rename. It cannot overwrite, copy, link, unlink, purge, or delete.
- A candidate rename cannot be invoked until a canonical immutable intent and
  its quarantine-directory publication barrier exist. Cooperating transactions
  hold a validated nonblocking exclusive journal lock through reconciliation
  and terminal receipt publication. The same ordering applies to the separate
  restore intent before a reverse rename.
- Record and namespace durability requires every specified `F_FULLFSYNC` call
  to succeed; Core does not downgrade to `fsync` or report durable success after
  a failed barrier. An inconclusive post-intent state remains receipt-less and
  blocks later mutation.
- Recovery treats a valid final receipt as immutable historical evidence. It
  consults current source and destination truth only for a receipt-less
  quarantine or restore intent or canonical receipt-stage promotion. It may
  publish a conclusive receipt but never invokes or retries either rename,
  adopts an occupant, overwrites, compacts, or deletes.
- Quarantine report contract version 2 declares only a terminal receipt durably
  recorded.
  A validated, canonically reachable intent or receipt is crash-recoverable;
  unresolved state is not, even when it carries a transaction identifier. This
  evidence lets restart recovery inspect and safely complete, preserve, or
  block state; it does not promise automatic receipt publication.
- Restore report contract version 1 uses the same durability rule. A terminal
  `not-restored` receipt is durably recorded without claiming a restore, and a
  report is durably restored only when its terminal receipt records `restored`.
- Broad paths such as `/`, `/System`, `/Applications`, `/Users`, and a home
  directory itself are protected cleanup targets.
- Scan, classification, planning, approval, revalidation, and both authorization
  layers cannot mutate files. Only the internal npm quarantine and manual-
  restore executors own their narrow atomic namespace operations; their
  authorizations grant no standalone filesystem capability.
- The source-run app's package-scoped facade is the sole frontend mutation
  surface, fixed to one exact npm cache at the current non-root account's
  passwd-home `~/.npm/_cacache`. The CLI and public Core API expose no cleanup,
  move, quarantine, restore, purge, or permission-escalation action.
- Quarantine and restore mutation require macOS 26 or newer. Older supported
  systems fail before namespace creation, durable intent publication, or rename
  and retain all read-only analysis surfaces.
- Quarantine is a same-volume namespace rename, not storage reclamation. It
  deallocates no file data and guarantees exactly 0 B of freed capacity.
- No purge, permanent deletion, retention policy, background cleanup, batch or
  custom-path mutation, network access, telemetry, or distributed app exists.
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
- A satisfied npm `no-protected-descendants` finding proves only that a bounded
  descriptor-relative traversal reached stable EOF, matched the complete
  scan's descendant count, and found only the pinned `content-v2`/`index-v5`
  path grammar, optional metadata files, and an absent or empty `tmp`. A
  symlink, special node, regular-file hard link, different-device entry,
  different-account owner, repeated directory identity, unexpected raw name,
  or wrong kind is protected. Permission failures, races, and traversal limits
  remain unknown. The observer reads no file content and does not inspect ACLs,
  extended attributes, flags, effective access, cache provenance, or activity.
- A candidate remains `Protected` when a required activity check reports active
  use or any unavailable reason other than npm's exact
  `unknown(.notCollected)` deferral. That one state may produce Review required
  with the pending attestation precondition, but it is not eligible to execute.
- A changed candidate is skipped during revalidation.
- Partial failures are reported item by item.
- Permanent deletion is not part of the initial milestones.

Activity is the remaining npm execution fact. The
[activity safety contract](ACTIVITY.md) records that no supported,
unprivileged macOS API can prove the absence of subtree-wide active use and
preserve that result until a later operation. DevSift must not infer
`inactive` from a quiet interval, empty process query, advisory lock, kqueue, or
FSEvents result. The selected recoverable-quarantine policy therefore preserves
`unknown(.notCollected)` and carries an explicit pending precondition. The
Core-defined `CleanupQuarantineAuthorization` now binds the exact approval to an
attempt-scoped caller assertion and a shared single-use lifecycle; only its
internal handoff may reach the Core-internal npm executor. It still grants no
standalone mutation authority. A prior observation, review acknowledgement, or
elapsed-time test is never execution authority.

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

Authorization attempt cancellation is terminal. Cancelling an open or issued
attempt clears retained state; concurrent issuance and internal consumption
permit at most one success each across all copies. An attestation belonging to
another attempt or carrying the wrong statement may be corrected while the
session remains open, but cancellation, successful issuance, or consumption is
not reversed by waiting.

Restore-attempt cancellation is also terminal before its internal claim is
consumed. Before durable restore-intent publication it causes no restore
mutation. After intent publication but before rename, Core may record a
conclusive `not-restored` receipt. Once rename has been invoked, cancellation is
latched for reporting while namespace reconciliation, required durability
barriers, and safe receipt publication continue.

## Rule requirements

A cleanup rule must declare:

- a stable identifier and version;
- the tool or workflow responsible for the data;
- positive evidence used to identify a candidate;
- exclusions and protected descendants;
- an eligible disposition and reproducibility class;
- required activity and age checks;
- any versioned deferred execution precondition and the exact finding shape it
  is permitted to defer;
- user-facing explanations;
- synthetic tests for matches, near misses, and hostile paths.

Path shape alone is insufficient for a high-confidence rule when the path can
contain user-owned content.

The current classifier enforces common integrity checks centrally. Rules only
recognize raw path shapes and project declared evidence; they cannot directly
grant a disposition. An unavailable required fact, invalid rule assessment,
classification conflict, or incomplete scan produces `Protected`, except for
the sole versioned deferred activity shape described above. The current built-
in catalog enables it only for npm. A malformed returned report is rejected
against the request's reference time and original `ScanReport` before either
frontend renders it. The adapter performs no extra filesystem probing and may
project the conservative newest inode time already retained by a complete scan
summary. A separate bounded observer may rebind
retained top-level candidates to their scan-time identities and, for an exact
SwiftPM `.build` directory, inspect only the metadata of an exact
`workspace-state.json` child. A satisfied age or marker check alone is
insufficient: every non-deferred unknown required fact keeps the real candidate
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
planning request, then accepts only that session's complete entry-confirmation
and precondition-review-acknowledgement sequences. The session binds its source
root, full manifest, canonical ordinals, raw paths, rule revisions, and pending-
condition identifiers without deriving intent from a diff or lossy projection.
Its process-local seal prevents cross-session value mixing but is not proof of
human review, authenticity, attestation, or freshness. The revalidator is a
read-only diagnostic that consumes only the approval and reopens its stored
root. The Core authorizer now combines that exact approval with an explicit
attempt-scoped caller assertion and produces a process-local single-use
`CleanupQuarantineAuthorization`. The internal npm executor accepts only its
internal handoff and establishes policy and object evidence inline while
holding verified descriptors through its atomic move. See the
[planning contract](PLANNING.md), [revalidation contract](REVALIDATION.md), and
[authorization contract](AUTHORIZATION.md), plus the
[quarantine execution contract](QUARANTINE.md),
[durability contract](DURABILITY.md), and
[manual restore contract](RESTORE.md).

The internal review encoder accepts only Core manifest contract version 3 and
emits CLI schema `devsift.cleanup-manifest-review` version 2. A per-entry
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
source versions, deferred-precondition projection, non-importable authority
flags, deterministic same-runtime bytes, output limits, and cancellation
without writing files.

Native app draft-review tests use only synthetic values and cover conservative
eligibility, default-zero and exact-whitelist selection, exact source-request
and report reuse, off-main planning, frozen selection, cancellation, stale
results, lifecycle invalidation, bounded generic failures, escaped display,
identity omission, canonical ordering, and all seven observed quantities.
They also verify that deferred npm activity remains displayed as unobserved and
that the presentation itself introduces no approval, attestation, safety, or
execution claim. Separate app workflow tests cover retained opaque sessions,
the two confirmation gates, macOS rejection, single-attempt execution, stale
result suppression, late cancellation, bounded durability projection, and 0 B
guaranteed freed capacity.

Approval tests use source-bound synthetic planning requests and cover opaque
session preparation, exact root and manifest retention, complete entry
confirmations and precondition review acknowledgements, missing, extra,
duplicate, reordered, changed, and foreign-session input, cross-root and cross-
manifest substitution, planning bounds, pre-cancel rejection, non-UTF-8 raw-
path identity, and the absence of filesystem, serialization, attestation,
freshness, authentication, and execution authority.

Authorization tests use only synthetic approvals. They cover independent
classifier/catalog pins, npm rule/tool/precondition/statement pins, complete
canonical subjects, no-pending and mixed-set rejection, cross-attempt
substitution, retryable statement mismatch, atomic concurrent issuance and
internal consumption across copies, terminal cancellation, non-`Codable`
values, and the absence of process, npm, clock, filesystem, persistence,
public mutation, and CLI operations.

Durability and restore tests use only synthetic temporary journal namespaces.
They cover canonical quarantine and restore record bytes, exclusive
publication, lock contention, sync failures, staged and orphan records, mixed
bounded inventory, capacity boundaries, destination-plan collisions, both
receipt-less recovery tables, single-use restore confirmation and execution,
descriptor/path races, non-overwriting reverse rename, and preservation outside
the exact journal namespace. Package-facade tests additionally cover explicit
same-lock reconciliation and inventory validation, deterministic bounded rows,
atomic failure, readiness distinctions, opaque-reference isolation, exact
confirmation, and single-use restore without touching a real home.

Any future permanent-removal feature requires a separate design review, threat
model, and release milestone.
