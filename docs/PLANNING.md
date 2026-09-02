# Planning contract

DevSiftCore can turn an explicitly selected subset of a validated scan and
classification result into an immutable draft cleanup manifest. Planning is a
pure, read-only value transformation. It does not inspect the filesystem,
approve a cleanup, export a document, or grant authority to mutate anything.

The CLI and native app do not expose planning yet. Codable persistence, plan
diffing, frontend review, export, approval, revalidation, and cleanup remain
separate later increments.

## Inputs and selection

`CleanupPlanner` receives a `CleanupManifestRequest` containing the exact scan
and classification inputs plus bounded `CleanupCandidateSelection` values.
It is the default implementation of the injectable `CleanupPlanning` boundary.
Each selection identifies both:

- one exact root-relative `ScanRelativePath`, compared by raw component bytes;
- the exact `RuleRevision` the user intends to include in the draft.

The current bound is 50,000 selections. A candidate path must contain exactly
one nonempty raw component of at most 255 bytes. A component equal to `.` or
`..`, or containing a null byte or `/`, is rejected before entry construction.

The rule revision prevents a path from silently selecting a different rule
after policy changes. A selection expresses only which eligible classification
result should appear in the draft. It is not user approval, execution consent,
or permission to clean. In particular, changing a selection cannot promote a
protected or uncertain classification.

Before producing a manifest, the planner validates the complete
`RuleClassificationReport` against its original `RuleClassificationRequest`.
It also requires the built-in classifier's non-public, exact in-memory
source-request binding. This prevents findings from one scan from being
combined with the identity or size values of another scan that happens to have
the same relative paths and reference time. Publicly constructed unbound reports
remain available to trusted custom presentation flows, but cannot be planned.
Every selection must then resolve unambiguously to one retained top-level scan
summary and one evaluation with the same exact raw path and rule revision. The
evaluation must be `matched`, have either a `reclaimable` or `review-required`
disposition, and contain only satisfied findings. The enclosing report, root,
item, allocation, hard-link accounting, and scan-time identities must satisfy
the existing fail-closed classification invariants. This first contract accepts
directory candidates only.

An invalid, duplicate, ambiguous, unavailable, protected, or stale selection
fails the whole planning request with a typed error. The planner never silently
drops a requested candidate and never converts `possible-match`,
`unrecognized`, `conflict`, or `invalid-rule` output into a plan entry.
An empty selection produces an empty draft when its enclosing scan and
classification inputs are valid; the planner never invents candidates.

The current real-scan adapter still leaves several required built-in facts
unknown, so those recognized candidates remain `Protected` and cannot enter a
nonempty draft. Synthetic complete evidence exercises eligible planning without
weakening the runtime classification boundary.

## Draft manifest

`CleanupManifest` is an immutable, in-memory draft with an explicit contract
version. It records the classification reference time and expected root
identity, then stores entries in deterministic raw-path order. Each
`CleanupManifestEntry` preserves the selected exact path and rule revision,
expected candidate identity and kind, policy disposition and reproducibility,
display metadata, the complete satisfied finding snapshot, and observed
allocation estimates. Findings are ordered by stable identifier. Manifest
totals are checked rather than silently saturated on overflow.

Every manifest reports that explicit approval and execution-time revalidation
are still required. Those requirements cannot be disabled per manifest.

The manifest does not contain the selected root's absolute URL. Paths remain
root-relative and retain their exact component bytes. The root and candidate
`(device, inode)` values are comparison evidence copied from the bounded scan;
they are not persistent object identities, capabilities, or deletion authority.
Hard links may legitimately share an identity, so identity is not used as an
entry-uniqueness key.

Observed apparent and hard-link-exclusive allocated bytes remain point-in-time
estimates. Clones, snapshots, compression, concurrent changes, and later
filesystem activity can make actual reclaimed space differ. A draft must not
label either value as guaranteed reclaimable space.

## Determinism and trust boundary

For the same validated request and selections, the planner produces equal
manifest values independent of input selection order. It does not add a random
identifier, read the wall clock, reconstruct descendant URLs, open a path, or
invoke a tool. Exact raw path bytes and stable domain identifiers—not display
text, locale rules, object hashes, or filesystem lookups—define equality and
ordering.

The manifest is a review artifact, not an authenticity proof. Swift `let`
properties make a value immutable after construction but cannot prove that a
future serialized document was not edited. Core models are deliberately not
`Codable` in this increment, and no import or export format is defined.

The source binding retains the exact classification request in process,
including its root URL, but is not a public report field and is never copied
into `CleanupManifest`. Access control is not encryption: callers must still
treat the in-memory report as sensitive and discard it with the analysis
session.

## Staleness and future execution

A manifest can become stale immediately after its source scan. Matching a
recorded `(device, inode)` pair is not enough to prove that content, activity,
containment, protected descendants, or rule evidence is unchanged; inode reuse
is also possible. The draft therefore has no “safe to execute” or approved
state.

Future approval must be a separate action bound to the exact reviewed
manifest. A future executor must receive an explicit root, reopen it and each
candidate descriptor-relatively, and revalidate containment, kind, device,
identity, activity, rule revision, and all required policy evidence immediately
before any mutation. Changed or unavailable candidates must be skipped.

Before approval is added, planning also needs an explicit Core-level catalog
or classification-contract provenance value. Changes to classifier-owned
semantics must invalidate older drafts even when individual rule revisions do
not change.

## Test boundary

Planning tests use constructed reports or newly created synthetic temporary
fixtures. They cover deterministic raw-byte ordering, duplicate and hostile
selections, malformed or incomplete inputs, protected decisions, missing
identity, allocation overflow, and unchanged fixture boundaries. Tests never
plan from a contributor's real cache, project, home directory, or other user
data.
