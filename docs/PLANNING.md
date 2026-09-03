# Planning contract

DevSiftCore can turn an explicitly selected subset of a validated scan and
classification result into an immutable draft cleanup manifest, then compare
two compatible drafts. Planning and diffing are pure, read-only value
transformations. They do not inspect the filesystem, approve a cleanup, export
a document, or grant authority to mutate anything.

The CLI and native app do not expose planning or diffing yet. The CLI target has
an internal, one-way review JSON projection over an already constructed
manifest, but no command invokes it and it writes no file. Core `Codable`
persistence, frontend review, user-facing export, import, approval,
revalidation, and cleanup remain separate later increments.

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
It requires the classifier's non-public in-memory seal over both that exact
request and the report's policy provenance. This prevents findings from one
scan from being combined with another scan's identities or sizes and prevents
provenance from being edited after classification. Publicly constructed
unbound reports remain available to trusted custom presentation flows, but
cannot be planned. A source-bound report without explicit policy provenance is
also rejected.

Every selection must resolve unambiguously to one retained top-level scan
summary and one evaluation with the same exact raw path and rule revision. The
evaluation must be `matched`, have either a `reclaimable` or `review-required`
disposition, and contain only satisfied findings. Every reported rule revision
must occur in the provenance roster. The enclosing report, root, item,
allocation, hard-link accounting, and scan-time identities must satisfy the
existing fail-closed classification invariants. This contract accepts directory
candidates only.

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

## Policy provenance

`RulePolicyProvenance` is bounded, classifier-owned version metadata. It
contains the explainable-classification contract revision, catalog revision,
and the catalog's complete rule-revision roster in canonical sorted order. The
roster is limited to 128 rules and rejects duplicate identifiers rather than
silently deduplicating them.

The default classifier seals `devsift.classification.explainable@1`, the
Core-owned `devsift.builtin-rules@2` catalog revision, and the exact built-in
roster into every report. `ExplainableRuleClassifier(rules:)` remains a
presentation-only extension point: its reports are source-bound but
deliberately unprovenanced and therefore cannot be planned. A trusted custom
catalog can opt into planning only through the overload that supplies its own
explicit `catalogRevision`; custom callers cannot claim the reserved built-in
catalog identifier.

Provenance is a version contract, not a code signature, stable document hash,
or proof of authenticity. Custom catalog owners must increment their catalog
revision whenever assessment behavior or catalog composition changes. DevSift
increments the classification contract revision for changes to automatic
findings, evidence interpretation, conflict handling, report validation, or
other classifier-wide semantics; it increments the built-in catalog and the
affected rule revision for catalog-owned or rule-specific semantic changes.
The model deliberately does not hash Swift closures, runtime type names,
`hashValue`, app versions, or rule-definition text as a substitute for this
semantic-versioning responsibility.

## Draft manifest

`CleanupManifest` is an immutable, in-memory draft with contract version 2. It
records the exact `RulePolicyProvenance`, classification reference time, and
expected root identity, then stores entries in deterministic raw-path order.
Each `CleanupManifestEntry` preserves the selected exact path and rule revision,
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

## Internal manifest-review projection

The CLI target owns review schema `devsift.cleanup-manifest-review` version 1,
pinned explicitly to Core cleanup manifest contract version 2. This is a lossy,
frontend-owned `Encodable` projection rather than `Codable` conformance on Core
models. No decoder or importer exists, no CLI command invokes it, and the
encoder performs no stream, file, filesystem, or network I/O. It cannot
reconstruct a manifest, compare drafts, approve a selection, or execute work;
the envelope explicitly sets `canBeApproved` and `canBeExecuted` to `false`.
Manifest-diff export remains undefined.

Both privacy profiles omit root and candidate filesystem identities and have no
dedicated absolute-root field. The redacted profile also omits paths, the
reference time, all free-form text, and unselected rule revisions. It retains
exact observed quantities plus selected rule and finding identifiers and is
therefore neither anonymous nor automatically safe to share. The
root-relative-exact profile includes exact Base64 path components, an escaped
display path, the exact reference time, escaped free-form metadata and finding
explanations, and the complete provenance roster. Trusted custom-rule text can
contain an arbitrary absolute path even though the schema has no dedicated root
field.

Entry ordinals are assigned from canonical raw-path order solely for reference
inside one output document. They are not persistent identity and cannot be
compared across documents. Every wide integer is a decimal string. A 128 MiB
hard output limit is checked with a per-entry encoded-size preflight and again
after final encoding. Cancellation checkpoints surround validation, projection,
and the preflight, but the single final Foundation encoding call cannot be
interrupted until it returns.

## Compatible-manifest diff

`CleanupManifestDiffer` compares a caller-designated baseline and comparison
using a linear merge over their already sorted entries. It first requires both
manifests to use the same supported manifest contract version, exactly equal
policy provenance, and exactly equal expected root `(device, inode)`. A
mismatch is a typed incompatibility error; the differ never emits a partial
entry result or labels anything unchanged across incompatible inputs. Root
identity equality is only a comparison token and is not proof that two scans
refer to the same logical scope.

Each manifest is independently limited to 50,000 unique entries, so the union
and maximum change output are bounded at 100,000 paths. Malformed duplicate,
out-of-order, over-limit, or policy-undeclared entries fail closed. The differ
checks cancellation during validation and the merge, performs no filesystem
I/O, and returns typed values rather than rendering or logging sensitive names.

An entry's identity for diffing is its exact raw-byte `ScanRelativePath` only.
The same path with a different candidate identity or rule revision is modified;
the same inode under another path is removed plus added. The differ never
infers a rename from `(device, inode)`, because hard links and inode reuse make
that unsafe. Modified entries compare every stored field: expected kind and
identity, rule revision, disposition, reproducibility, display metadata,
classification explanation, complete findings, and all seven size and
uncertainty quantities. Changed-field labels use a fixed declaration order,
and all entry differences use global raw-path order.

Totals use `unchanged`, `increased(by: UInt64)`, or
`decreased(by: UInt64)` for each observed quantity. No conversion to `Int64`
or timestamp subtraction can overflow; the two reference timestamps are
preserved as supplied, and either chronological direction is valid. These are
differences between observations, not guaranteed reclaimed-space deltas.

An empty diff means only that all retained entry fields compared equal. It does
not mean the manifests are identical in time, that the filesystem is unchanged,
that either draft is fresh, or that cleanup is approved or safe. A diff is not
an approval token and must never become an executor input.

## Determinism and trust boundary

For the same validated request and selections, the planner produces equal
manifest values independent of input selection order. Compatible manifest
diffs are likewise independent of construction order. Neither operation adds a
random identifier, reads the wall clock, reconstructs descendant URLs, opens a
path, or invokes a tool. Exact raw path bytes and stable domain identifiers—not
display text, locale rules, process-randomized hashes, or filesystem lookups—
define equality and ordering.

The manifest is a review artifact, not an authenticity proof. Swift `let`
properties make a value immutable after construction but cannot prove that a
review projection was not edited. Core models deliberately remain non-`Codable`;
the CLI schema is one-way and non-importable. Repeated `JSONEncoder` bytes are
intended to be stable only for the same validated input, privacy profile,
implementation build, and Swift/Foundation runtime. They are not a
cryptographic canonical form, stable digest, signature, or authenticity proof.

The source binding retains the exact classification request and provenance in
process, including the request's root URL, but is not a public report field and
is never copied into `CleanupManifest`. The bounded provenance value itself is
copied; rule definitions and the root URL are not. Access control is not
encryption: callers must still treat the in-memory report, manifests, and diffs
as sensitive and discard them with the analysis session.

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

## Test boundary

Planning and review-projection tests use constructed reports or newly created
synthetic temporary fixtures. They cover deterministic raw-byte ordering,
duplicate and hostile selections, malformed or incomplete inputs, protected
decisions, missing identity, allocation overflow, provenance sealing and
limits, diff compatibility, all stored entry fields, non-UTF-8 ordering,
`UInt64` boundaries, both review privacy profiles, identity omission, the
one-way authority boundary, output limits, 50,000-entry inputs, 100,000-path
diff output, cancellation, and unchanged fixture boundaries. Tests never plan
from, render, or compare a contributor's real cache, project, home directory,
or other user data.
