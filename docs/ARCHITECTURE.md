# Architecture

DevSift uses one safety-critical Swift core shared by its native app and CLI.

```text
source-run DevSift app ---> DevSiftCore <--- devsift CLI (read-only)
        |                      |
        +-> scan -> rules -> plan -> review/approve
                               |
                               +-> package-scoped npm quarantine facade
                                      |          |
                               durable move   explicit reconcile/inventory
                                                     |
                                             receipt-bound restore

public DevSiftCore API: read-only analysis/review/authorization values;
mutation executors, journal records, and raw transaction selectors stay hidden.
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
  deferred execution-precondition metadata, and conservative policy
  classification. Rules receive observations rather than filesystem URLs; the
  central classifier alone computes dispositions;
- **Planning:** pure Core transformations from explicit path-and-rule
  selections over a validated classification into policy-provenanced immutable
  drafts, and between compatible drafts into deterministic differences.
  Planning and diffing perform no filesystem I/O, and neither selection nor a
  diff is approval;
- **Approval:** a read-only, Core-only transition from an exact source-bound
  planning request through one opaque review session into an in-memory
  approval. The session owns the exact root and manifest and issues
  session-bound entry and pending-precondition references. It permits no
  partial subset, performs no filesystem I/O, and creates neither activity
  attestation, freshness, authenticity, nor execution authority;
- **Revalidation:** a read-only Core diagnostic that accepts only an approval,
  rescans its retained root, and reclassifies it with current built-in policy.
  It emits canonical point-in-time entry statuses, including pending execution
  preconditions, and no execution capability;
- **Authorization:** a Core-defined process-local transition that binds one exact
  approval to an explicit caller assertion covering its complete canonical
  pending set. `CleanupQuarantineAuthorization` is single-use and recoverable-
  quarantine-only, requires inline filesystem revalidation, and grants no
  standalone mutation authority. It uses shared attempt identity and state,
  not a wall-clock TTL;
- **Execution:** an internal npm-only kernel that consumes only the
  authorization's internal handoff, descriptor-revalidates the sole exact
  `_cacache` candidate, and can make one exclusive same-volume rename into a
  verified private quarantine directory on macOS 26 or newer. Older systems
  reject before namespace mutation because the safety boundary requires
  `RENAME_RESOLVE_BENEATH`;
- **Durability and recovery:** a private canonical intent/receipt journal that
  serializes cooperating quarantine and restore attempts, applies required
  `F_FULLFSYNC` record and namespace barriers, and reconciles receipt-less
  intents from current descriptor-bound namespace truth without retrying a
  rename, overwriting, or deleting. Recovery is never wired to app launch. A
  package-scoped explicit inventory request runs recovery, final journal
  reread/revalidation, and bounded projection under one validated exclusive
  lock. Malformed or unresolved journal state, unsafe parents, and aggregate
  resource exhaustion fail atomically; item-level problems remain visible as
  non-restorable rows;
- **Manual restore:** a separate Core-internal npm-only selector, confirmation,
  single-use authorization, descriptor preflight, and executor for one exact
  final-receipt-bound quarantine item. It can make at most one non-overwriting
  reverse rename and returns bounded process-local diagnostics. The UI sees only
  package-scoped opaque references, readiness, exact confirmation text, and
  bounded results. The app-local adapter briefly holds the package authorization
  before passing it back to Core; the internal claim remains Core-only;
- **Reporting:** structured outcomes without frontend-specific rendering.

Current Core semantic versions are explainable classification revision 3,
cleanup manifest version 3, manifest diff version 2, approval version 2, and
revalidation version 2. Quarantine authorization and its internal execution
report are contract version 1 and version 2 respectively. Restore authorization
and its internal report are contract version 1. Private quarantine and restore
intent/receipt wire records are version 1. The
built-in catalog is version 6 and npm is rule revision 5. Older manifests and
approvals are regenerated rather than migrated.

The mutation architecture intentionally contains no purge, permanent deletion,
storage-reclaim, retention, batch or background executor, custom-root or non-npm
executor, network, telemetry, or privilege-escalation component. The app remains
source-run rather than distributed. Core runs locked recovery during quarantine
transaction admission, restore preparation, and restore transaction admission,
and during an explicit inventory load or refresh. A restore execution that returns
to the still-current, uncancelled view-model operation schedules one follow-up
refresh; dismissal, cancellation, or superseding work can prevent or cancel it
and suppresses stale UI publication. Recovery never runs merely because the app
launched or as periodic or background work.

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
`devsift.cleanup-manifest-review` version 2, explicitly pinned to Core cleanup
manifest contract version 3. It is a one-way, lossy `Encodable` projection for
an already constructed manifest. No command invokes it, and it performs no
standard-stream, file, filesystem, or network I/O. There is no decoder or
import path; the envelope sets `canBeApproved` and `canBeExecuted` to `false`,
and no manifest-diff export, approval, or execution surface accompanies it.
Both privacy profiles preserve each entry's fixed deferred-precondition
identifier and policy revision so a pending condition is not hidden.

Scan JSON remains version 2. Classification JSON is version 2 and always
includes a sorted deferred-precondition array for every decision. Old JSON
exports have no import migration; rerun the producing flow to regenerate them.

### DevSift app

The current macOS app provides explicit folder selection, distinct
indeterminate scan and policy-analysis states, cancellation, rescan,
observation results, partial-result details, explainable policy assessments,
accessibility, explicit eligible-candidate inclusion, and a read-only in-memory
draft review. Table focus and draft inclusion are separate, and every result
starts with zero included candidates. For one exact npm `_cacache` in the
current non-root account's passwd-home, the source-run app also provides an
explicit reviewed quarantine transaction plus explicit recovery-inventory and
manual-restore transactions.
Those are package-scoped integrations, not general frontend filesystem access.

Each window owns a main-actor observable view model with injected scanning,
classification, review, and package-scoped transaction capabilities. It passes
the file importer's selected URL unchanged to DevSiftCore. A scan token prevents
a cancelled or superseded task from publishing a late result over the current
state. Security-scoped access is held until Core scanning,
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
preserves their evidence, deferred execution preconditions, and expected
identities, and fails the whole request if any selection is invalid or
ambiguous. The sole supported deferred shape is activity
`unknown(.notCollected)` paired with its canonical pending precondition on a
Review-required result. Valid custom rules can opt into that shape; the current
built-in catalog does so only for npm. The result does not include the absolute
root URL and cannot authorize execution.

For the current result, the app retains the exact classification request and
report plus an exact whitelist of presentable `CleanupCandidateSelection`
values. A selection contains one raw path and rule revision, and the view model
ignores any value outside that current-session whitelist. Candidate filtering
is only a conservative UI convenience; Core validation remains authoritative.
The included set is frozen and canonically ordered before the planner runs in a
detached user-initiated task. A planning UUID plus the source scan UUID prevents
cancelled, superseded, or closed-window work from publishing a late result.

The manifest is converted to an app-owned, identity-free review presentation.
That presentation retains a raw relative path only as an in-memory row identity
and renders escaped display text. It does not retain root or candidate
filesystem identities, the source request or manifest, reference time,
provenance roster, serialization, approval, attestation, authorization, or
execution state. For the supported npm transaction, the app separately retains
the opaque Core-issued review session; it never reconstructs authority from the
lossy presentation. The visible root scope comes from active window state. The
view shows all seven stored observation and uncertainty quantities, never
guaranteed savings, and shows pending npm activity as unobserved policy
metadata. It has no persistence, import, export, or diff capability.

After explicit review, the app requires two independent confirmation gates: the
attempt-scoped stopped-npm/unobserved-risk assertion and a final confirmation of
the recoverable move. An app-local workflow then derives and briefly holds the
Core approval, authorization session, attestation, and authorization before
passing the authorization into the package-scoped executor. None of those values
enters UI presentation state, and Core alone consumes the internal execution
claim. Core repeats every descriptor-held safety check and, on macOS 26 or newer,
may perform one durable, non-overwriting same-volume rename. The projected result
distinguishes terminal receipt state from unresolved state and reports
guaranteed freed capacity as 0 B.

The Core differ first rejects manifest-contract, provenance, or expected-root
identity incompatibility. It then performs an `O(n + m)` merge by exact raw path
and reports every stored entry-field change, including deferred execution
preconditions, plus overflow-safe directional differences for observed totals.
Its contract version is 2. It does not infer renames from inode identity, reopen
paths, render output, or create approval state.

The Core approver starts from one exact `CleanupManifestRequest` rather than a
caller-supplied manifest. It runs the concrete planner and returns an opaque
review session that retains the request's exact local root, the resulting
manifest, entry references, and pending-precondition references bound to a
process-local session seal. The caller confirms every entry and calls
`acknowledgePreconditionForReview` for every pending reference; both complete
canonical sequences must belong to that same session. A
`CleanupApprovalPreconditionReviewAcknowledgement` binds only that the condition
and risk were reviewed. It is not a user attestation or satisfaction of the
condition. A mismatched or foreign-session value fails even when its visible
path, rule revision, and condition are equal. A subset must first become a new
draft and review.

Approval contract version 2 retains the session's exact root, manifest, and
`preconditionReviewAcknowledgements` in memory without `Codable`, filesystem
I/O, clock reads, or mutation capability. The
opaque seal correlates values only inside the current process; it is not a
secret, authenticity proof, activity attestation, proof of human review, or
permission to execute.
The app invokes this contract only through its retained current review session;
the CLI does not. Core revalidation accepts only `CleanupApproval` and reopens
the root stored within it, rather than accepting a separately supplied root,
unapproved manifest, diff, or review projection.

The first Phase 7 `CleanupRevalidator` now accepts only `CleanupApproval`. It
performs a fresh scan and fresh built-in classification using the approval's
stored root, validates only current built-in policy provenance, and compares the
new root identity and each approved entry's path, kind, device, identity, rule,
findings, deferred preconditions, and stable policy fields. Its per-entry
results are canonical, point-in-time diagnostics; incomplete observations fail
closed. A valid deferred npm entry remains
`awaitingExecutionPreconditions`, not eligible or inactive. The contract-
version-2 report omits the absolute root URL, is non-`Codable`, copyable, and
never a filesystem capability or executor input.

`CleanupQuarantineAuthorizer.beginAttempt(for:)` now validates and retains one
exact approval. After canonical current-built-in validation, authorization
contract version 1 independently pins classifier revision 3 and catalog
revision 6, then directly pins npm rule revision 5, tool `npm`, precondition
policy revision 1, and statement policy revision 1. Drift fails through typed
unsupported-policy or unsupported-requirement errors.

The session exposes a `CleanupQuarantineAttestationRequest` over the complete
canonical pending set. `CleanupQuarantineUserAttestation` is an explicit caller
assertion for that request, not observed inactivity, proof of human action, or
authentication. Shared process-local state permits at most one authorization
issuance and one internal handoff across every copy; cancellation is terminal,
and cross-attempt replay fails without using a clock or TTL. Authorization v1
is recoverable-quarantine-only, requires inline filesystem revalidation, and
grants no standalone mutation authority. The consumer, execution claim, and
npm-only executor are internal. The executor keeps verified descriptors live
through one non-overwriting same-volume rename. It publishes immutable intent
before mutation, synchronizes affected namespace parents, and publishes a
terminal receipt for a conclusive outcome. The report's durability state
distinguishes no record, validated intent, terminal receipt, and unresolved
state. See the
[authorization contract](AUTHORIZATION.md) and
[quarantine execution contract](QUARANTINE.md), plus the
[durability contract](DURABILITY.md).

Manual restore is a distinct internal authority chain. Its preflight accepts
only a quarantine transaction identifier, discovers the canonical final intent
and matching `quarantined` receipt through the journal, generates the new
restore transaction identifier inside Core, and returns a process-local
confirmation session. A matching confirmation can issue one version-1 restore
authorization, whose internal handoff is consumable once.

The restore executor reopens the real account's passwd-home `.npm` and fixed
quarantine namespace with no-follow, beneath-root descriptors. It revalidates
historical bindings, current ownership and containment, the receipt-selected
item and bounded cacache tree, and source-name absence. Under the shared journal
lock it publishes and synchronizes a separate restore intent before invoking at
most one exclusive reverse rename. It then reconciles both names and publishes a
terminal restore receipt only for conclusive state. Mixed recovery may complete
a receipt from namespace truth but never invokes the rename. These low-level
types and entry points remain internal and non-`Codable`. The app can reach only
a package-scoped facade that explicitly reconciles and validates the complete
bounded inventory, issues opaque process-local item references, and projects
honest restore readiness and bounded outcomes. The CLI and public library
clients cannot reach either mutation path. See the
[manual restore contract](RESTORE.md).

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
a guaranteed reclaimable byte count. Phase 9 quarantine is only a same-volume
namespace rename: it retains all file data and its guaranteed freed capacity is
exactly 0 B.

## Evolution rule

Scanning, classification, planning, and execution remain separate stages. A
future optimization must not combine them in a way that allows discovery code
to mutate the filesystem or bypass plan review.

The current planner receives no filesystem capability or descendant URL. It
copies only validated, bounded values into an in-memory draft: the root identity
without its absolute URL, exact root-relative raw paths, expected candidate
identity and kind, classifier-owned policy provenance, rule revision, policy
evidence, deferred execution preconditions, and observed allocation estimates.
`CleanupCandidateSelection`
identifies a requested path and rule revision; it is not approval. The differ
receives only manifest values and likewise has no filesystem capability.
The app-owned in-memory review projection and CLI-owned JSON projection are not
serialized Core state and carry no authority. The app review is presentational
only. A Core approval review session instead owns its exact planning request,
source root, manifest, and session-bound entry and pending-precondition
references; it cannot be rebuilt from either projection. The approval retains
the exact root, manifest, and review acknowledgements but does not make either
projection approvable. Core review, caller-created quarantine attestation,
restore confirmation, and both single-attempt authorizations now exist only as
process-local values. The app view model retains the Core review session apart
from presentation and enforces its independent UI gates. After final
confirmation, the app-local workflow derives approval and fresh authorization,
then passes only that authorization to the package-scoped executor. Neither
display state nor the public Core API becomes mutation authority.
User-facing export, import, persistence, and diffing remain outside the current
boundary, as do CLI mutation and arbitrary-path execution. The CLI projection's
sorted `JSONEncoder` output targets
repeatability only for the same input, privacy profile, implementation build,
and Swift/Foundation runtime; it is not a cryptographic canonical form, stable
digest, signature, or authenticity proof.

The current scan-to-rule adapter projects only facts already present in the
bounded `ScanReport`; it performs no additional filesystem I/O. Rules consume
the modification-time aggregate only for complete item summaries. A separate,
bounded evidence stage reopens each retained top-level candidate to verify the
root and candidate against their scan-time identities. For an exact SwiftPM
`.build` candidate, it additionally observes metadata for an exact
`workspace-state.json` child without following symbolic-link targets. For an
exact npm `_cacache`, it recognizes the supported cacache layout only when
bounded descriptor-backed enumeration finds exact raw `content-v2` and
`index-v5` directory entries. For exact uv, npm, and Homebrew names, it can also
prove the selected root is the matching documented default container beneath
the current account home. For an exact top-level npm `_cacache` candidate, the
held selected root and held candidate descriptors can additionally establish the distinct
`account-owned-cache-namespace` fact when both metadata records carry the
current account's exact POSIX UID. Raw path shape only gates a descriptor walk;
the final root identity must match before and after observation.

That npm-specific namespace fact is not responsible-tool ownership. It proves
neither historical creation, write ACLs, cache content, inactivity, nor
mutation authority. For the same exact candidate, the held descriptor also
anchors a bounded raw-name traversal that recognizes only the pinned cacache
path-and-kind grammar, an absent or empty `tmp`, same-device current-account
owners, and single-link regular files. Stable exceptions are protected; races,
permission failures, malformed metadata, and reached bounds remain unknown.
Other rules retain unknown tool-ownership and protected-descendant evidence.
The observer invokes no npm process, performs no process inspection, reads no
cache contents, and makes no network request. npm activity stays literally
`unknown(.notCollected)`. If every non-deferred fact passes, classifier
contract revision 3 may produce Review required with
`requires-user-attestation-that-responsible-tool-is-stopped@1`; this remains a
pending condition, not observed inactivity.

Scan-time `(device, inode)` values are read-only observation-binding tokens,
not persistent object identities or deletion authority. Copying them into a
draft manifest does not establish trusted location, ownership, approval, or
cleanup authority. The internal quarantine and restore executors therefore
revalidate containment, kind, identity, and policy evidence immediately before
their respective mutations.
Any observer added for the remaining facts must preserve descriptor-relative
traversal and identity checks rather than reconstructing descendant `URL`
values from untrusted names. See the [rules contract](RULES.md) and
[planning contract](PLANNING.md).

Activity is the remaining npm execution fact. The completed
[capability review](ACTIVITY.md) found no supported, unprivileged macOS API that
can establish the absence of active subtree use and hold that result through a
later operation. Classification therefore leaves the fact unknown and records
the selected narrow recoverable-quarantine precondition. A positive-only
conflict probe may add a protective signal in a separately versioned increment,
but a negative result must not become `inactive`. The Core authorizer now binds
the exact approval to an explicit attempt-scoped caller assertion and process-
local single-use `CleanupQuarantineAuthorization`; only its internal handoff may
reach the Core-internal npm executor. It does not change activity evidence or
grant standalone mutation authority. Neither a process snapshot, review
acknowledgement, returned diagnostic, nor wall-clock TTL is durable authority.
