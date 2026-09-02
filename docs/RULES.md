# Explainable rules contract

DevSift classifies storage observations with versioned, deterministic rules.
Classification is read-only: it explains evidence and policy, but it cannot
plan, move, quarantine, or delete anything.

```text
scan observation -> rule recognition -> evidence checks -> policy disposition
```

Recognition and eligibility are deliberately separate. A familiar name such
as `DerivedData`, `.build`, or `_cacache` is only a lexical signal. It is never
enough on its own to call an item reclaimable.

## Result vocabulary

Each recognized candidate has both a match state and a disposition:

- **Matched:** the raw path matched and every required check was satisfied.
- **Possible match:** the raw path matched, but at least one required fact was
  false or unavailable.
- **Conflict:** more than one rule recognized the same raw path, or the input
  repeated one exact raw path observation.
- **Invalid rule:** a rule or its findings violated the catalog contract.
- **Reclaimable:** a matched rule has strong evidence for generated,
  reproducible, inactive, sufficiently old data.
- **Review required:** all required checks passed, but policy still requires an
  explicit human decision.
- **Protected:** evidence failed, was unknown, conflicted, or was incomplete.

`Possible match`, `conflict`, and `invalid rule` always produce `Protected`.
Unknown is protected rather than silently converted into review-required.

## Evidence model

A rule declares a stable identifier, positive integer version, responsible
tool, reproducibility class, eligible disposition, minimum age, activity
requirement, positive evidence, exclusions, and user-facing explanations.
The central classifier—not an individual rule—computes the disposition.

Each valid single-rule recognition receives structured findings for:

- exact raw-byte lexical recognition;
- trusted container location;
- responsible-tool ownership;
- a generated-content marker;
- protected descendants;
- rule-specific evidence such as a sibling `Package.swift`;
- reproducibility, minimum age, and tool activity;
- complete scanning, retained output and issues, known allocation, arithmetic
  overflow, hard-link-accounting integrity, and scan-identity rebinding.

A failed or unknown required finding blocks eligibility. A partial report,
partial item, suppressed top-level output, discarded traversal detail,
suppressed issue, unknown allocation, size overflow, or incomplete hard-link
accounting therefore remains protected.

Catalog validation also enforces a structural safety floor. Every rule needs
both positive evidence and an exclusion. A rule whose eligible disposition is
Reclaimable additionally needs declared reproducibility, a positive minimum
age, and a must-be-inactive activity check. Classifier-owned finding identifiers
are reserved so rule findings cannot collide with common guards. If malformed
findings and a multi-rule conflict occur together, invalid-rule reporting takes
precedence; both outcomes remain protected.

## Built-in catalog version 2

The initial catalog intentionally starts small. The eligible disposition shown
below is a ceiling reached only after every required fact is known and passes.
Catalog version 2 advances only `devsift.swiftpm.build` to rule revision 2 to
define its generated marker as an exact regular-file `workspace-state.json`
inside `.build`. Every other built-in rule remains at revision 1.
The identity-rebinding finding is a classifier-owned integrity invariant, not
a rule-specific definition change; it is covered by the catalog version rather
than incrementing every individual rule revision.

| Rule ID | Raw-byte recognition | Reproducibility | Eligible disposition | Minimum age | Additional policy |
| --- | --- | --- | --- | ---: | --- |
| `devsift.cache.uv` | direct child named exactly `uv` | Reproducible | Reclaimable | 7 days | Generated, tool-owned cache in a trusted uv cache container; uv inactive |
| `devsift.cache.npm` | direct child named exactly `_cacache` | Conditional | Review required | 7 days | Generated, tool-owned npm content cache; npm inactive |
| `devsift.cache.homebrew` | direct child named exactly `Homebrew` | Conditional | Review required | 7 days | Trusted Homebrew cache container; Homebrew inactive |
| `devsift.xcode.derived-data` | direct child named exactly `DerivedData` | Conditional | Review required | 7 days | Trusted Xcode container and generated-content evidence; Xcode inactive |
| `devsift.swiftpm.build` | direct child named exactly `.build` | Conditional | Review required | 7 days | Exact regular-file `Package.swift` sibling and `.build/workspace-state.json` marker; build tooling inactive |
| `devsift.xcode.ios-device-support` | version-like direct child of a selected root named exactly `iOS DeviceSupport` | Conditional | Review required | 30 days | Trusted Xcode container and generated-content evidence; Xcode inactive |

All names are compared as filesystem bytes, not normalized display strings.
Near misses, different case, invalid UTF-8 lookalikes, nested paths, and broader
directories do not match. The selected root itself is never a candidate.

The catalog policy is informed by the tools' own documentation:

- uv documents its cache location and supported `uv cache clean` and
  `uv cache prune` operations, while warning against modifying cache files
  directly: [uv cache documentation](https://docs.astral.sh/uv/concepts/cache/).
- npm documents `_cacache` as an integrity-verified, self-healing cache and
  says clearing it is generally unnecessary: [npm cache documentation](https://docs.npmjs.com/cli/cache/).
- Homebrew documents `brew --cache` and age-based `brew cleanup` behavior:
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
`(device, inode)` identities. It handles one deliberately narrow generated-
marker case: for an exact top-level `.build` directory, it checks only metadata
for an exact child named `workspace-state.json`. A stable same-device regular
file produces a known present marker; a stably absent or different-kind entry
produces a known missing marker. Symbolic-link targets are never followed.
Permission, resource-limit, invalid-metadata, incomplete, or changed-object
cases remain structured unknowns.

A scan-time identity binds that read-only observation to the inode that was
scanned. It is not proof of trusted location or ownership, is not durable
filesystem identity, and grants no planning, cleanup, or deletion authority.
Inodes can be reused, so any future execution must reopen and revalidate
containment, kind, identity, and policy evidence immediately before mutation.
Trusted-location, ownership, reliable-activity, and protected-descendant facts
remain uncollected.

Consequently, a real scan can recognize a possible built-in candidate, but
those unavailable facts keep its disposition `Protected` even when its age
and generated-marker findings are satisfied. Tests may construct synthetic
complete evidence to verify the catalog's eligible outcomes; that does not
weaken the runtime boundary. The SwiftPM marker semantic advances
`devsift.swiftpm.build` to revision 2 and the CLI catalog to version 2; other
rule definitions, thresholds, eligible dispositions, and revisions are
unchanged.

Any future observer for the remaining facts must preserve this
descriptor-relative safety model. It must use operations such as `openat`,
`fstatat`, `fstat`, and `O_NOFOLLOW`, stay on the approved device, bound all
work, and report changed or unavailable facts as unknown. Rebuilding absolute
descendant paths with string or `URL` concatenation is not acceptable authority
for classification or cleanup.

## Determinism and versioning

- Rule and finding identifiers use stable lowercase ASCII identifiers.
- A policy or evidence-semantic change increments that rule's version.
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
