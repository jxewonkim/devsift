# Product scope

## Product statement

DevSift helps macOS developers and AI builders understand storage created by
their tools and make narrowly scoped, reviewable decisions about it. It favors
evidence and user control over opaque "one-click optimization." The current
product has no permanent-removal or storage-reclaim feature.

## Target users

- developers using Xcode, package managers, containers, simulators, and virtual
  machines;
- AI builders accumulating model caches, generated assets, agent workspaces,
  and temporary build output;
- users who want to understand why disk usage grew before deciding what to do.

## Core jobs

The current pre-alpha implements jobs 1 through 4 for analysis and review, plus
one narrow recoverable native transaction. It can recognize selected path
shapes, explain why missing evidence keeps them protected, and build an
immutable draft from explicitly selected eligible classifications.
The app starts with zero included candidates and presents an identity-free
review without persisting it. Core can also compare compatible
policy-provenanced drafts and prepare a root-bound, opaque review session from
one exact source-bound planning request without reading the filesystem. The
caller must confirm every entry and acknowledge every pending condition for
review before Core issues approval. That acknowledgement is not an activity
attestation. Core can separately bind that exact approval to one explicit
caller assertion in a process-local, single-use quarantine authorization
attempt. A Core-internal npm-only kernel can consume that authorization and
atomically quarantine one exact `_cacache` behind a durable intent/receipt
journal and recovery engine. A separate Core-internal workflow can explicitly
confirm, authorize, and durably restore one exact receipt-bound quarantine item.
The CLI target can internally project one draft into a privacy-profiled,
review-only JSON schema, but no command or file export exposes it. The source-
run app retains the Core-issued review session and, after explicit review plus
stopped-risk and final-move confirmations, can quarantine one exact npm cache
at the current non-root account's passwd-home `~/.npm/_cacache` on macOS 26 or
newer. A separate explicit action loads reconciled bounded inventory and can
confirm one
receipt-bound, non-overwriting restore. The CLI and public Core API remain
read-only. Automatic app-launch recovery and automatic restore are absent, and
job 5 remains later product direction because same-volume quarantine guarantees
0 B of freed capacity.

1. Show where allocated storage is being consumed.
2. Attribute known storage to a tool or workflow when evidence supports it.
3. Explain whether an item is regenerable, user-owned, active, stale, or
   protected.
4. Produce a deterministic, reviewable plan before changing anything.
5. Report what was actually reclaimed and what was skipped.

## Built-in catalog version 6

The sixth version of the built-in catalog is present in Core, the CLI, and the
app. Its eligible outcomes are policy ceilings for fully evidenced synthetic
observations. For a complete item, the current real-scan adapter can establish
the age input from the newest inode modification time observed during scanning.
For an exact SwiftPM `.build` candidate, a bounded identity-bound observer can
establish whether an exact regular-file `workspace-state.json` marker is
present. For an exact npm `_cacache`, it can establish a supported layout marker
from exact raw `content-v2` and `index-v5` directories without reading cache
contents. For uv, npm, and Homebrew, it can establish trusted location only when
the selected root descriptor rebinds to that tool's exact documented default
container beneath the current account home. For an exact npm candidate, it can
also establish `account-owned-cache-namespace` only when the held selected root
and `_cacache` directory both have the current account's exact POSIX UID. This
replaces unprovable generic tool ownership only for npm; it does not prove the
historical creator, write ACLs, content, inactivity, or mutation authority.
For the same exact npm candidate, a bounded descriptor-relative traversal can
also prove the absence of descendants outside the pinned cacache path-and-kind
grammar. It rejects non-empty `tmp`, links, special nodes, hard-linked regular
files, different-device entries, different-account owners, and repeated
directory identities. Other rules retain unknown tool ownership and protected-
descendant evidence. npm rule revision 5 leaves runtime activity literally
`unknown(.notCollected)` but, when every non-deferred fact passes, records
`requires-user-attestation-that-responsible-tool-is-stopped@1` and produces a
Review-required result. That condition is not evidence or authorization.
Custom locations, other generated markers, and other unavailable required facts
remain Protected.

The corresponding current contracts are explainable classification revision 3,
cleanup manifest 3, manifest diff 2, approval 2, revalidation 2, quarantine
authorization 1, and internal execution report 2. Scan JSON remains version 2;
classification JSON and the
internal manifest-review JSON are version 2, with the latter pinned to source
manifest 3.

The first rule set recognizes:

- Xcode DerivedData and versioned DeviceSupport;
- SwiftPM `.build` output with a `Package.swift` sibling;
- uv, npm, and Homebrew caches.

Browser caches, installer images, and broad temporary-build discovery remain
future catalog work because reliable ownership and activity evidence is not yet
available.

AI model stores, virtual-machine disks, browser profiles, source repositories,
documents, photos, and application databases are protected or review-only by
default. Size alone is never evidence that data is disposable.

## User journey

The long-term workflow is:

1. **Scan** an explicitly selected root without modifying it.
2. **Explain** candidates using versioned rules and visible evidence.
3. **Plan** an immutable dry run with observed allocation estimates and their
   uncertainty.
4. **Approve** the exact reviewed draft and acknowledge its pending conditions
   as a separate explicit action.
5. **Revalidate** identity, containment, and active-use conditions.
6. **Authorize** one quarantine attempt with fresh explicit user attestation.
7. **Quarantine** authorized candidates using a recoverable operation.
8. **Report** bounded outcomes; reserve completed for a durably recorded,
   crash-recoverable result.
9. **Recover inventory** on an explicit initial load or refresh, reconciling
   durable state before presenting it; refresh once when a restore execution
   returns to the still-current, uncancelled view-model operation.
10. **Restore** one ready receipt-bound item after a separate exact confirmation.
11. **Purge** quarantined data only as a later, explicit action.

The planning layer uses in-memory Core manifest version 3, typed Core diff
version 2, an internal CLI-owned review schema version 2 pinned to source
manifest version 3, and a native identity-free in-memory review. The app keeps
table focus independent from explicit inclusion, which begins at zero, and
allows only current-session exact raw-path and rule-revision pairs. Core then
revalidates the exact classification request and report before planning. The
app review displays all seven observed size and uncertainty quantities; none is
a guaranteed savings claim. Current real scans may have zero eligible
candidates, while an exact npm candidate may reach Review required with its
pending condition when every non-deferred fact passes. The app retains the
opaque Core review session separately from that presentation only for the
current in-memory workflow.

Core can now prepare an opaque review session from an exact source-bound
planning request. The session owns the exact source root and Core-built
manifest and issues session-bound entry references. An in-memory approval is
produced only when the caller confirms every canonical entry and calls
`acknowledgePreconditionForReview` for every pending condition from that same
session. Each `CleanupApprovalPreconditionReviewAcknowledgement` means the
condition and risk were reviewed, not that npm stopped. Approval is all-or-
nothing; mismatched or foreign-session values fail even when their visible path,
rule, and condition are equal. A different subset requires a new draft and
review. Approval contract version 2 is non-`Codable`, performs no filesystem
I/O, and is never reconstructed from app display state. The source-run app can
produce it transiently inside its app-local workflow without placing it in UI
state; the CLI does not expose it. It
records intent, not activity attestation, proof of human review, freshness,
authenticity, execution authority, or reclaimed space. The approval remains
copyable and is not single-use.

Phase 7 added a Core-only revalidation diagnostic. It accepts only the
approval, rescans its stored root, and reruns current built-in policy before
returning canonical per-entry status. It reobserves root identity, path, kind,
device, identity, rule, findings, and policy, while incomplete or unknown data
fails closed. The report is point-in-time, copyable, non-`Codable`, and omits
the absolute root; it is neither a cleanup capability nor an executor input.
Exact default uv, npm, and Homebrew
containers can now satisfy trusted location, and npm may satisfy its supported
cacache-layout marker plus its current-account cache-namespace check. That
npm-specific check is not generic ownership or cleanup authority. npm can also
satisfy its bounded protected-descendant exclusion for a complete, stable tree
matching the pinned cacache grammar and the earlier scan. npm activity remains
`unknown(.notCollected)`; revalidation contract version 2 reports an otherwise
valid deferred entry as `awaitingExecutionPreconditions`, not eligible or
inactive. Tool ownership, protected descendants, and other required evidence
remain unobserved for the other rules.

Classification JSON version 2 and the internal manifest-review JSON version 2
always include each decision or entry's sorted
`deferredExecutionPreconditions` array. The internal projection is lossy and
non-importable; it explicitly sets
`canBeApproved` and `canBeExecuted` to `false`. The app projection is ephemeral,
identity-free presentation state rather than a document. A diff requires the
same manifest contract, policy provenance, and expected root identity, and
still says nothing about current disk freshness. No frontend workflow persists,
imports, exports, or diffs a manifest, and no diff-export format exists. The app
does not mutate from its lossy review presentation; its separate package-scoped
workflow carries the retained Core-issued session through approval,
authorization, and fresh inline descriptor validation.
The revalidation boundary accepts only `CleanupApproval` and reopens the root
stored within it, rather than accepting a separately supplied root, standalone
draft, diff, or review projection.

`CleanupQuarantineAuthorizer.beginAttempt(for:)` now validates and retains that
exact approval, then exposes one request for an explicit caller assertion over
the complete canonical npm pending set. Review acknowledgement is replayable
review intent; the separate `CleanupQuarantineUserAttestation` is an attempt-
bound assertion, not observed inactivity, human proof, or authentication.
Process-local identity rejects cross-attempt replay without a clock or TTL.
Authorization issuance and the shared internal handoff each succeed at most
once. Contract version 1 is recoverable-quarantine-only, requires inline
filesystem revalidation, and grants no standalone mutation authority. Neither
consumer nor executor is public; the sole executor is Core-internal. See the
[authorization contract](AUTHORIZATION.md).

The internal npm executor takes only the authorization handoff, not a bare
approval or revalidation report. It validates the exact policy and cacache
grammar inline while holding descriptors through one exclusive same-volume
rename into `.devsift-quarantine-v1`. It publishes a canonical immutable intent
before rename, synchronizes both namespace parents after a possible rename, and
records a canonical terminal receipt only for a conclusive outcome. The
internal recovery engine reconciles receipt-less intents without resuming,
reversing, restoring, overwriting, or deleting them. Final receipts remain
immutable historical evidence; current namespace truth is used for
receipt-less recovery or receipt-stage promotion, not to reinterpret them. See
the [quarantine execution contract](QUARANTINE.md) and
[durability contract](DURABILITY.md).

The remaining npm execution fact is activity. The capability review in the
[activity safety contract](ACTIVITY.md) found no supported, unprivileged macOS
primitive that can prove subtree-wide inactivity or prevent a new cache access
between a check and an operation. The current product therefore leaves this
fact unknown. The project has selected explicit caller-attested risk only for
recoverable quarantine. Core now accepts that assertion for one exact
authorization attempt without changing the observation. The source-run app
collects the stopped-npm/unobserved-risk value independently from review and
asks for a separate final move confirmation; it neither displays nor constructs
the raw Core attestation request. A quiet-tree, empty-process snapshot, caller
assertion, or authorization is never called inactivity evidence.

## Non-goals

DevSift is not:

- a malware scanner or antivirus product;
- a memory, battery, or performance "booster";
- a tool for bypassing macOS permissions or platform protections;
- an automatic remover of user documents or unfamiliar large files;
- a wrapper around arbitrary shell deletion commands.

No public Core or CLI cleanup operation exists. The source-run app's sole
mutation surface is package-scoped and fixed to the current non-root account's
exact passwd-home `~/.npm/_cacache`; it cannot supply arbitrary paths, roots,
journal records, or transaction identifiers. Its explicit recovery inventory
and single-item restore surface uses opaque receipt-bound references and never
overwrites `_cacache`.

The internal npm kernels perform no permanent deletion. Purge, storage reclaim,
retention, batch or background operation, custom-path mutation, network access,
telemetry, automatic app-launch recovery or restore, and a distributed app all
remain absent. Same-volume quarantine deallocates no file data and guarantees
exactly 0 B of freed capacity. See the [manual restore contract](RESTORE.md).
