# Explainable rules contract

DevSift classifies storage observations with versioned, deterministic rules.
Classification is read-only: it explains evidence and policy, but it cannot
plan, move, quarantine, or delete anything. The separate Core-internal npm
executor is constrained by the [quarantine execution contract](QUARANTINE.md).

```text
scan observation -> rule recognition -> evidence checks -> policy disposition
```

Recognition and eligibility are deliberately separate. A familiar name such
as `DerivedData`, `.build`, or `_cacache` is only a lexical signal. It is never
enough on its own to call an item reclaimable.

## Result vocabulary

Each recognized candidate has both a match state and a disposition:

- **Matched:** the raw path matched and every non-deferred required check was
  satisfied. One exact activity `unknown(.notCollected)` may remain visible
  only for the deferred activity policy with its canonical execution
  precondition.
- **Possible match:** the raw path matched, but at least one required fact was
  false or unavailable.
- **Conflict:** more than one rule recognized the same raw path, or the input
  repeated one exact raw path observation.
- **Invalid rule:** a rule or its findings violated the catalog contract.
- **Reclaimable:** a matched rule has strong evidence for generated,
  reproducible, inactive, sufficiently old data.
- **Review required:** all non-deferred checks passed, but policy still requires
  explicit review or records a pending execution precondition.
- **Protected:** evidence failed, was unknown, conflicted, or was incomplete.

`Possible match`, `conflict`, and `invalid rule` always produce `Protected`.
Unknown is protected rather than silently converted into review-required,
except for the versioned deferred activity mapping from exactly one
`unknown(.notCollected)` finding to
`requires-user-attestation-that-responsible-tool-is-stopped@1`. The finding
stays unknown; the precondition is not evidence or authorization. This shape
is available to valid custom Review-required rules, while the current built-in
catalog opts in only the npm rule.

## Evidence model

A rule declares a stable identifier, positive integer version, responsible
tool, reproducibility class, eligible disposition, minimum age, activity
requirement, positive evidence, exclusions, and user-facing explanations.
The central classifier—not an individual rule—computes the disposition.

Each valid single-rule recognition receives structured findings for:

- exact raw-byte lexical recognition;
- trusted container location;
- responsible-tool ownership when the rule requires that fact;
- rule-specific namespace evidence such as npm's
  `account-owned-cache-namespace` check;
- a generated-content marker;
- protected descendants;
- rule-specific evidence such as a sibling `Package.swift`;
- reproducibility, minimum age, and tool activity;
- complete scanning, retained output and issues, known allocation, arithmetic
  overflow, hard-link-accounting integrity, and scan-identity rebinding.

A failed or unknown required finding blocks eligibility unless the classifier's
versioned contract explicitly recognizes that exact finding as the sole
deferred execution precondition. A partial report,
partial item, suppressed top-level output, discarded traversal detail,
suppressed issue, unknown allocation, size overflow, or incomplete hard-link
accounting therefore remains protected.

Catalog validation also enforces a structural safety floor. Every rule needs
both positive evidence and an exclusion. A rule whose eligible disposition is
Reclaimable additionally needs declared reproducibility, a positive minimum
age, and a must-be-inactive activity check. Only a Review-required rule may use
`.mustBeInactiveOrDeferToAttestationWhenUnobserved`, and the current classifier
defers only activity `unknown(.notCollected)` to the sole sorted, unique
precondition above. The current built-in catalog enables that policy only for
npm. Known active use, any other unknown reason, duplicates, or a second
blocker remains Protected. Classifier-owned finding identifiers are reserved
so rule findings cannot collide with common guards. If malformed
findings and a multi-rule conflict occur together, invalid-rule reporting takes
precedence; both outcomes remain protected.

## Built-in catalog version 6

The initial catalog intentionally starts small. The eligible disposition shown
below is a ceiling reached only after every non-deferred fact is known and
passes. Catalog version 6 keeps `devsift.swiftpm.build` at rule revision 2 and
advances `devsift.cache.npm` to rule revision 5 for its narrow deferred activity
policy. SwiftPM requires an exact regular-file
`workspace-state.json` inside `.build`; npm requires exact direct-child
directories named `content-v2` and `index-v5` inside `_cacache` and replaces
the generic tool-ownership requirement with its narrower
`account-owned-cache-namespace` check. npm now also collects a bounded
protected-descendant exclusion against the pinned cacache grammar. npm activity
remains literally unknown; the new revision records an attempt-scoped user-
attestation precondition rather than claiming inactivity. The separate Core
authorizer can bind that condition to an explicit caller assertion, but does
not change the finding or grant standalone mutation authority. Every other
built-in rule remains at revision 1.
The identity-rebinding finding is a classifier-owned integrity invariant, not
a rule-specific definition change; classifier-wide semantics are now tracked
separately by the explainable-classification contract revision.

| Rule ID | Raw-byte recognition | Reproducibility | Eligible disposition | Minimum age | Additional policy |
| --- | --- | --- | --- | ---: | --- |
| `devsift.cache.uv` | direct child named exactly `uv` | Reproducible | Reclaimable | 7 days | Generated, tool-owned cache in a trusted uv cache container; uv inactive |
| `devsift.cache.npm` | direct child named exactly `_cacache` | Conditional | Review required | 7 days | Exact `content-v2` and `index-v5` directory layout, trusted npm cache container, current-account-owned root and candidate namespace, no protected descendants, and either observed npm inactivity or the pending `requires-user-attestation-that-responsible-tool-is-stopped@1` condition for a recoverable quarantine authorization attempt |
| `devsift.cache.homebrew` | direct child named exactly `Homebrew` | Conditional | Review required | 7 days | Trusted Homebrew cache container; Homebrew inactive |
| `devsift.xcode.derived-data` | direct child named exactly `DerivedData` | Conditional | Review required | 7 days | Trusted Xcode container and generated-content evidence; Xcode inactive |
| `devsift.swiftpm.build` | direct child named exactly `.build` | Conditional | Review required | 7 days | Exact regular-file `Package.swift` sibling and `.build/workspace-state.json` marker; build tooling inactive |
| `devsift.xcode.ios-device-support` | version-like direct child of a selected root named exactly `iOS DeviceSupport` | Conditional | Review required | 30 days | Trusted Xcode container and generated-content evidence; Xcode inactive |

All names are compared as filesystem bytes, not normalized display strings.
Near misses, different case, invalid UTF-8 lookalikes, nested paths, and broader
directories do not match. The selected root itself is never a candidate.

The catalog policy is informed by the tools' own documentation:

- uv documents `$HOME/.cache/uv` as the Unix fallback cache location and
  supports `uv cache clean` and `uv cache prune`, while warning against direct
  modification: [uv cache documentation](https://docs.astral.sh/uv/concepts/cache/).
- npm documents `~/.npm` as its default POSIX cache and `_cacache` as its
  integrity-verified content store:
  [npm configuration](https://docs.npmjs.com/cli/using-npm/config/) and
  [npm cache documentation](https://docs.npmjs.com/cli/cache/). The pinned
  cacache source defines content paths beneath `content-v2` and index paths
  beneath `index-v5`:
  [content path](https://github.com/npm/cacache/blob/6e8eb4d7e82694149c34fbb0fbe5441628fc1703/lib/content/path.js) and
  [index path](https://github.com/npm/cacache/blob/6e8eb4d7e82694149c34fbb0fbe5441628fc1703/lib/entry-index.js). The same pinned
  [cacache README](https://github.com/npm/cacache/blob/6e8eb4d7e82694149c34fbb0fbe5441628fc1703/README.md)
  describes cacache as a standalone library with lockless cache operations.
  Its source also defines caller-managed `tmp`, `_lastverified`, and
  `CACHEDIR.TAG` behavior:
  [temporary directories](https://github.com/npm/cacache/blob/6e8eb4d7e82694149c34fbb0fbe5441628fc1703/lib/util/tmp.js),
  [verification](https://github.com/npm/cacache/blob/6e8eb4d7e82694149c34fbb0fbe5441628fc1703/lib/verify.js), and
  [cache tags](https://github.com/npm/cacache/blob/6e8eb4d7e82694149c34fbb0fbe5441628fc1703/lib/util/cache-dir.js).
  Its [cache removal implementation](https://github.com/npm/cacache/blob/6e8eb4d7e82694149c34fbb0fbe5441628fc1703/lib/rm.js)
  and [tests](https://github.com/npm/cacache/blob/6e8eb4d7e82694149c34fbb0fbe5441628fc1703/test/rm.js)
  deliberately distinguish content/index/tag data from `tmp` and unrelated
  top-level entries, which is why DevSift requires `tmp` to be empty and rejects
  unknown siblings in this revision.
  Those properties are additional reasons that layout and location cannot
  prove npm was the historical creator or sole writer. The allowlist below is
  DevSift's fail-closed interpretation of that pinned implementation, not an
  upstream promise that no other entry can ever be valid.
- Homebrew documents `~/Library/Caches/Homebrew` as its default macOS cache and
  provides `brew --cache` and age-based `brew cleanup` behavior:
  [Homebrew manual](https://docs.brew.sh/Manpage).
- Swift Package Manager documents `.build` as the default scratch directory:
  [SwiftPM build documentation](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageManagerDocs/Documentation.docc/SwiftBuild.md).

Those sources establish tool behavior, not permission to remove arbitrary
lookalike directories. The Xcode rules remain review-only because the catalog
does not treat path names or undocumented lifecycle assumptions as a disposal
guarantee.

## Current evidence boundary

The scan adapter consumes only the existing `ScanReport`. It does not reopen
paths, read file contents, invoke tools, inspect processes, or reconstruct
absolute child URLs. The report retains reliable top-level raw names, scan-
integrity fields, each summary inode's scan-time identity, and a bounded
modification-time aggregate. The adapter can also infer an exact regular-file
`Package.swift` sibling.

For each root and top-level summary, the descriptor-relative scan retains the
greatest conservative whole-second upper bound of the candidate inode and all
observed descendant inode modification times. A timestamp with subsecond
precision is rounded up, so precision loss cannot make an item appear older.
Directory and symbolic-link inodes may contribute; symbolic-link targets are
never followed. An empty directory contributes its own inode time.

The adapter exposes that aggregate as known age evidence only for a complete
top-level item with a nonnegative value. An incomplete item becomes
`unknown(.incompleteScan)`, an absent value becomes `unknown(.notCollected)`,
and invalid or unrepresentable metadata becomes
`unknown(.invalidMetadata)`. A value later than the request's reference time
becomes `unknown(.clockSkew)` in the classifier. The minimum-age comparison is
inclusive: `reference - newest >= minimumAge` satisfies it.

This timestamp is only the newest value observed during a non-snapshot scan.
It is not proof of last use, tool inactivity, tool ownership, generated
content, or the absence of protected descendants.

The current evidence observer reopens the selected root and every retained
top-level candidate descriptor-relatively to verify their kinds and scan-time
`(device, inode)` identities. It handles two deliberately narrow generated-
marker cases. For an exact top-level `.build` directory, an exact child named
`workspace-state.json` must be a stable same-device regular file. For an exact
top-level `_cacache` directory, exact direct children named `content-v2` and
`index-v5` must both be stable same-device directories. Missing or wrong-kind
requirements produce a known missing marker. Extra direct children do not
invalidate the npm signature, and no descendant or file content is read.

Before metadata lookup, the observer enumerates direct child names as raw bytes
through a descriptor-backed directory stream. This prevents a case-insensitive
filesystem from satisfying an exact-name rule with a case variant. Enumeration
continues to EOF even after all requirements are found and permits at most 256
non-dot entries; exceeding that bound produces
`unknown(.resourceLimit)`. Symbolic-link targets are never followed. Permission,
resource-limit, invalid-metadata, incomplete, or changed-object cases remain
structured unknowns. The cacache layout is generated-content evidence only: it
does not establish that npm owns the candidate.

For exact top-level `uv`, `_cacache`, and `Homebrew` candidates, the observer
also recognizes only the documented default containers `$HOME/.cache`,
`$HOME/.npm`, and `$HOME/Library/Caches`, respectively. It obtains the current
account home from the operating-system account record rather than the `$HOME`
environment variable. A raw-path match is only a gate: the observer walks from
`/` through individually validated directory components with descriptor-
relative, no-follow opens and requires the final descriptor to match the held
selected-root identity. It repeats that walk before returning. A different
location is known false; permission, resource, malformed-path, symlink, device,
or changed-binding cases remain unknown. Custom cache overrides, Xcode roots,
and arbitrary Swift package roots are not collected by this profile.

Trusted location proves only that location fact. It does not imply that a tool
created the contents, that the tool is inactive, that descendants are safe, or
that a later operation may mutate the path.

The npm rule has one further, deliberately distinct evidence slot:
`RuleObservationFacts.accountOwnedCacheNamespace` is projected through
`CandidateRuleEvidence.accountOwnedCacheNamespace` as the finding
`account-owned-cache-namespace`. It is collected only for an exact top-level
`_cacache` candidate. The finding is satisfied only
when the held selected-root directory and held candidate directory both report
the exact UID of the current non-root POSIX account. A UID mismatch is known
false; unavailable or unsupported account metadata stays structured unknown.
The root and candidate bindings must remain stable across observation.

This is an account-owned cache-namespace fact, not generic responsible-tool
ownership. It does not establish which process or tool historically created
the directories, effective write access or ACLs, cache content, npm inactivity,
or permission to mutate. It invokes no npm command, inspects no process or cache
content, and makes no network request. Every other rule continues to receive
unknown tool-ownership evidence from the runtime observer.

The exact top-level `_cacache` rule also receives bounded
`protectedDescendantPresent` evidence from a second pass over its already-held
candidate descriptor. The pass uses raw `readdir`, no-follow `fstatat`, and
descriptor-relative directory opens; it never builds an absolute descendant
path or reads file content. It permits at most 1,000,000 strict descendants,
depth 32 beneath the candidate, and 64 MiB of cumulative raw filename bytes.

The pinned clean grammar permits:

- `content-v2/<algorithm>/<2 lowercase hex>/<2 lowercase hex>/<remaining
  lowercase hex>` with directories at each prefix and a regular file at the
  leaf;
- `index-v5/<2 lowercase hex>/<2 lowercase hex>/<60 lowercase hex>` with
  directories at each prefix and a regular file at the leaf;
- an absent or empty `tmp` directory;
- optional regular files named exactly `_lastverified` and `CACHEDIR.TAG`.

Empty intermediate cache directories are allowed. Any unexpected raw name,
case variant, wrong kind, non-empty `tmp`, symbolic link, special node,
regular-file hard link, different-device entry, different-account UID, or
repeated directory identity is a protected descendant. File contents, ACLs,
extended attributes, flags, and effective access are outside this fact.

`.known(false)` requires stable exhaustive traversal to EOF and an observed
strict-descendant count equal to the complete scanner summary's count minus the
candidate itself. Stable protected evidence produces `.known(true)`; permission
failure, a changed binding, malformed metadata, or a reached bound remains a
structured unknown. The exact non-directory `_cacache` case is known false for
this descendant fact but independently fails the candidate-directory finding.
Other candidates remain `unknown(.notCollected)`.

The default classifier seals its returned Core report to the exact in-memory
`RuleClassificationRequest` and `RulePolicyProvenance`. Validation rejects that
report if it is later paired with a different root URL, scan report, reference
time, or edited provenance. The provenance contains
`devsift.classification.explainable@3`, the Core-owned
`devsift.builtin-rules@6` revision, and the complete sorted built-in rule roster.
Neither the private binding nor provenance is part of CLI JSON. A report created
with the public unbound initializer can still support a trusted custom
presentation flow, but the cleanup planner will not accept it.

`ExplainableRuleClassifier(rules:)` also remains presentation-only: it binds
its source request but declares no policy provenance. A trusted custom catalog
can opt into planning by supplying an explicit non-built-in `catalogRevision`;
the classifier derives the roster from the actual rule definitions. Provenance
is version metadata, not a code signature. Custom catalog authors must advance
that revision whenever their catalog composition or `assess` behavior changes.

A scan-time identity binds that read-only observation to the inode that was
scanned. It is not proof of trusted location or ownership, is not durable
filesystem identity, and grants no planning, cleanup, or deletion authority.
Inodes can be reused, so any execution must reopen and revalidate
containment, kind, identity, and policy evidence immediately before mutation.
Generic responsible-tool ownership remains uncollected for every rule that
requires it. npm instead consumes only the narrower current-account cache-
namespace fact described above and collects its bounded protected-descendant
fact. Reliable activity remains exactly `unknown(.notCollected)` for npm. When
all other npm findings pass, classifier contract revision 3 preserves that
finding and emits
`requires-user-attestation-that-responsible-tool-is-stopped@1`, producing a
matched Review-required result. The precondition is not evidence that npm is
inactive and not permission to operate. Generated-marker evidence also remains
uncollected outside the SwiftPM and npm rules; trusted location and protected-
descendant evidence remain uncollected outside their supported profiles.

Consequently, a real scan can recognize a possible built-in candidate and may
satisfy trusted-location, npm layout, npm account-owned namespace, or npm
protected-descendant findings. An exact npm candidate with every non-deferred
fact satisfied may now reach Review required with the pending condition; other
unavailable facts keep a candidate `Protected`. Tests may construct synthetic
complete evidence to verify the catalog's eligible outcomes; that does not
weaken the runtime boundary. The explainable-classification contract is
revision 3. The built-in
catalog is version 6, SwiftPM is at rule revision 2, npm is at rule revision 5,
and all other rule revisions remain at version 1.

Any future observer for the remaining facts must preserve this
descriptor-relative safety model. It must use operations such as `openat`,
`fstatat`, `fstat`, and `O_NOFOLLOW`, stay on the approved device, bound all
work, and report changed or unavailable facts as unknown. Rebuilding absolute
descendant paths with string or `URL` concatenation is not acceptable authority
for classification or cleanup.

Activity is the remaining npm execution fact. The completed
[capability review](ACTIVITY.md) found no supported, unprivileged macOS API that
can prove the absence of active use throughout the cache subtree or prevent a
new access between a check and an operation. The classifier must not map a
quiet interval, empty process result, advisory-lock success, kqueue result, or
FSEvents result to `known(.inactive)`. The narrow recoverable-quarantine policy
defers only `unknown(.notCollected)`; it does not satisfy the finding. A future
positive-only conflict observer may return `active` when it has concrete
evidence, but every negative, incomplete, raced, denied, or bounded result must
remain unknown and cannot close an execution race. The explicit caller
attestation is accepted only by the separate Core authorization attempt, not by
classification. Its process-local single-use
`CleanupQuarantineAuthorization` is still not observed activity or a
standalone filesystem capability. See the
[authorization contract](AUTHORIZATION.md). The internal executor accepts that
handoff only for the exact pinned npm rule and rechecks the complete policy and
filesystem grammar before an atomic move.

## Determinism and versioning

- Rule and finding identifiers use stable lowercase ASCII identifiers.
- A rule-specific semantic change increments that rule's version.
- A built-in composition or catalog-owned recognition change increments the
  Core-owned catalog revision.
- A change to automatic findings, evidence interpretation, conflict handling,
  validation, or another classifier-wide semantic increments the
  classification contract revision.
- Policy provenance combines the classification contract, catalog revision,
  and the complete sorted unique rule roster. It never uses Swift `hashValue`,
  runtime type names, or closure hashing as a stable identity.
- Results are ordered by exact raw path and rule revision, never locale-aware
  display text.
- The reference time is captured once per classification request, so every age
  check in that report uses the same instant.
- Frontends project Core results into their own versioned contracts. The scan
  JSON schema remains independent from classification output.
- Paths remain root-relative and retain Base64 raw components in machine output.
- Both frontends validate a returned report against the original `ScanReport`
  and reference time before presentation. Evaluation cardinality, exact path
  coverage and order, rule identities, duplicate-conflict handling, findings,
  common finding states, disposition semantics, and scan integrity must agree.

## Resource bounds and extension trust

The classification layer has independent bounds even when a caller constructs
Core models directly:

- 128 rules per catalog;
- 64 declared checks per rule;
- 50,000 observations per classification;
- 1,024 UTF-8 bytes for each definition text field, check explanation, or
  runtime-finding explanation;
- 64 runtime findings returned by one rule;
- 128 matching rule revisions in one evaluation;
- 80 findings in one final evaluation and 1,000,000 across one report;
- 100,000 matching-rule revision references across one report;
- 4,096 UTF-8 bytes of display metadata per evaluation;
- 64 MiB of aggregate explanation text and 8 MiB of aggregate rule and
  finding-identifier text per report.

An observation-count overflow is rejected with a typed classification error
before adapter projection or sorting. Returned reports are rejected if retained
top-level counts, suppression flags, discarded traversal state, root and item
completion, or retained and suppressed issue state contradict the original
`ScanReport`. A complete root cannot carry issues, and a complete report cannot
retain an incomplete item. Duplicate raw paths collapse to one protected
conflict rather than producing input-order-dependent decisions. Diagnostics
for duplicate observations and lexical recognition must use the exact
classifier-owned identifier, kind, and failed state.

A custom `ExplainableRule` is trusted in-process Swift code. Bounds can reject
what it returns, but cannot preempt code that never returns from `assess`.
Likewise, final report bounds apply after a trusted custom classifier returns;
they cannot prevent memory it allocates while constructing that report. Loading
third-party executable rule code is not a current product feature.

The provenance roster is independently limited to 128 revisions and rejects
duplicate rule identifiers, including two versions of the same identifier.
Every `rule` and `matchingRules` revision in a provenanced report must occur in
that roster before the report can be planned.

Classification results reveal filenames, tool usage, sizes, policy findings,
and a reference timestamp. Treat them as sensitive local data even though
DevSift performs no upload or telemetry.

## Adding or changing a rule

A contribution must include matches, near misses, raw-byte and hostile-path
cases, missing and failed evidence, boundary-age behavior, activity behavior,
partial-report guards, deterministic ordering, conflicts, malformed findings,
and resource-bound behavior. Filesystem tests must use fresh synthetic
temporary fixtures and may not inspect or classify a contributor's real
caches.

Changes that loosen eligibility require an explicit safety review. A rule may
never bypass the common classifier guards, and a reclaimable rule must declare
data reproducible. See the [safety model](SAFETY.md) and
[contribution guide](../CONTRIBUTING.md).
