# Receipt-bound quarantine purge contract

Status: implemented in the source-run Phase 10 app on macOS 26 or newer. The
app now exposes separately confirmed initial purge and explicit-retry actions;
Core provides the single-use authority, canonical journal records,
descriptor-relative bounded unlink engine, recovery/terminalization, and
observational same-volume capacity result described here. There is still no
signed, notarized, or downloadable app artifact.

This contract extends the existing
[quarantine durability contract](DURABILITY.md) and
[manual restore contract](RESTORE.md). It does not broaden quarantine or restore
authorization. The only purge target is the current contents of one
exact npm quarantine item selected from a canonical durable quarantine receipt
through an opaque, process-local inventory reference.

## Scope and exact milestone

The implemented Phase 10 source build can:

- explicitly load and reconcile the fixed npm quarantine inventory;
- select one exact item whose canonical quarantine intent and matching final
  receipt record a `quarantined` outcome;
- issue a fresh process-local confirmation and single-use purge authority for
  that receipt-bound item;
- durably record one purge intent before any irreversible operation;
- atomically stage the exact selected item under one intent-bound purge-work
  name before recursive deletion begins;
- delete only the staged work tree with bounded descriptor-relative operations;
- preserve a safely validated and synchronized interrupted remainder for a
  separately confirmed explicit retry, while routing unsafe or
  durability-unresolved state to manual recovery;
- publish an immutable terminal purge receipt only after current namespace
  truth is conclusive; and
- report the observed change in available capacity on the same held volume.

The milestone is one explicit, receipt-bound purge attempt at a time. It is not
a general-purpose file remover. It accepts no arbitrary path, active
`_cacache`, custom root, caller-created transaction identifier, quarantine item
name, journal record, or unjournaled directory.

## Terms and irreversible boundary

The following events have different meanings and must never be collapsed in
code or user-facing wording:

| Event | Meaning |
| --- | --- |
| Inventory selection | One opaque reference identifies canonical journal evidence inside one process-local inventory session. It is not authority. |
| Confirmation | The caller supplies the exact requested permanent-deletion statement for one attempt. It is not activity evidence, authentication, or filesystem authority. |
| Authority consumption | One internal executor obtains the retained evidence. Preflight can still fail without changing the namespace. |
| Durable purge intent | Recovery has authoritative evidence it may inspect. No deletion has necessarily begun. |
| Staging rename may have been invoked | Restore execution is suspended until reconciliation proves whether the expected object remains at the original name or reached the work name. This is not yet a durable staging claim. |
| Staging commit | The exact receipt-bound `item-v1-*` is moved to the intent-bound purge-work name and that parent change is validated and fully synchronized. Restore is no longer available. |
| Unlink progress | One or more names beneath the staged work tree may have been irreversibly removed. Progress is non-atomic and may be partial. |
| Terminal purge receipt | The managed namespace conclusively shows either that staging never committed or that the selected item is absent from both managed names. |

Consuming an in-memory authority is not the irreversible cutoff. The cutoff is
the validated, synchronized staging rename. A durable intent with the original
exact item still present and no work item can be closed as `not-purged`; only
then may a fresh inventory make restore available again.

## Exact eligibility and opaque selection

An initial purge can be prepared only when one bounded, descriptor-held
inventory pass proves all of the following:

1. A canonical final quarantine intent and matching canonical final receipt
   exist, have safe record metadata and supported versions, and the receipt
   outcome is `quarantined`.
2. The receipt selects one exact destination component and binds it to the
   intent's exact candidate identity.
3. No successful restore receipt or terminal `item-absent` purge receipt exists
   for that quarantine transaction, and no conflicting receipt-less mutation
   intent is present. Canonical historical `not-purged` attempts are immutable
   but do not themselves block a fresh restore or purge attempt.
4. The fixed current account, passwd-home `~/.npm`, quarantine root, records,
   selected item, device, ownership, permissions, flags, ACL state, and named
   versus opened bindings remain safe.
5. The current selected item is the exact receipt-bound directory and its
   complete tree satisfies the current purge policy and bounded canonical npm
   cache grammar.
6. The complete mixed quarantine, restore, and purge journal inventory is
   structurally admissible and has capacity for the operation's worst-case
   managed-name peak.

The current `_cacache` source name does not become a purge input. It may be
missing or may contain a different current cache; neither condition grants
authority over that name. A state in which the historical expected object is
observed at both its quarantine item name and another managed location is
ambiguous and blocks.

The app facade receives only a bounded presentation and an opaque,
process-local reference tied to the exact inventory session. Core must resolve
that reference to the canonical record bytes, reread and revalidate those bytes,
and derive all path components and bindings internally. A stale or foreign
reference must fail even when its visible fields are identical.

## Confirmation and single-use authority

Purge must use a new authority family. It must not reuse or reinterpret a
`CleanupQuarantineAuthorization`, restore authorization, quarantine receipt,
restore confirmation, approval, manifest, or presentation value.

Before initial staging, the app must show a prominent disclosure that:

- the current contents of the selected quarantined npm cache will be
  permanently deleted;
- the operation is not secure erase and APFS snapshots, clones, backups, open
  file descriptors, or storage-device behavior may retain data or blocks;
- restore execution may be suspended once staging is attempted and becomes
  permanently unavailable at the staging commit, even if recursive deletion
  later stops partway;
- DevSift cannot prove that npm or every other same-account process is inactive;
- after DevSift validates a child, a same-account process can replace that name,
  and the platform cannot guarantee that `unlinkat` still names the checked
  inode;
- the current quarantined contents may differ from those first quarantined; and
- displayed allocation and capacity changes are observations, not guaranteed
  savings attributable to DevSift.

The final attempt-specific statement must explicitly confirm permanent
deletion of the current receipt-bound contents, acknowledge the restore cutoff
and partial-deletion model, assert that npm and other work using the item have
been stopped, accept the unobserved-activity and post-quarantine-change risk,
and accept that the observed available-capacity increase may be zero or
unavailable.

The resulting process-local authority is non-`Codable`, single-use across all
copies, bound to one exact canonical record pair and attempt kind, and usable
only by the internal descriptor-relative purge executor. It authorizes
permanent deletion only inside that exact staged purge-work tree, requires
inline filesystem revalidation, grants no standalone filesystem capability,
uses no wall-clock freshness, and cannot be persisted or reconstructed.

An interrupted purge requires a new inventory, a distinct retry confirmation,
and a fresh single-use retry authority bound to the existing canonical purge
intent and current exact work item. A retry does not create a second purge
intent or silently inherit the first confirmation.

## Threat model and platform limit

The purge boundary protects against malformed or hostile journal records,
untrusted names, symbolic links, special files, mount crossings, unexpected
hard links, unsafe permissions and flags, identity changes observable at its
checks, stale frontend selections, accidental concurrent DevSift processes,
and path traversal outside the exact work tree.

The journal lock coordinates cooperating DevSift processes. It is not mandatory
access control against another process running as the same account. Darwin
provides descriptor-relative `unlinkat`, but no supported primitive that
atomically conditions unlink on the inode previously opened and validated. A
same-UID process can therefore replace a child name between final validation
and `unlinkat`. Held parent descriptors, one-component raw names, no-follow
opens, device checks, and refusal of links or special nodes prevent path escape
and target traversal, but they cannot eliminate that name-swap race.

Phase 10 explicitly does not claim protection from an actively malicious
same-UID process racing each deletion. OS discretionary permissions may let
such a process modify this private cache namespace; that is not DevSift purge
authorization. The residual race must remain documented in the focused
security review and user disclosure; if later review expands the threat model
to require identity-conditioned deletion against a same-UID adversary, the
purge feature must not ship without a different platform primitive or design.

`removefileat` recursive removal, Foundation path deletion, shell commands, and
permission escalation are not acceptable substitutes because they do not
preserve the required per-entry validation, bounds, ordering, and reporting.

## Managed namespace and record families

The Phase 10 namespace reserves these exact managed names beneath the
fixed private quarantine root, where `ID` is 32 lowercase hexadecimal digits:

```text
.devsift-quarantine-v1/
  .purge-intent-stage-v1-ID
  .purge-intent-v1-ID
  .purge-receipt-stage-v1-ID
  .purge-receipt-v1-ID
  .purge-work-v1-ID
```

The purge-work name is not a record. It is the exact receipt-bound directory
after the staging rename. It is derived inside Core from the fresh purge
transaction identifier, is validated as one raw component, and is never
caller-selected or reused for a different purge transaction. An explicit retry
retains the same intent-bound work name.

Each purge record is a canonical immutable version-1 record published
through exclusive staged creation, complete bounded writes, metadata and named-
binding validation, `F_FULLFSYNC`, exclusive beneath-root rename, quarantine-
root `F_FULLFSYNC`, final byte revalidation, and a final record-descriptor
barrier. No record or work item may be overwritten.

### Purge intent version 1

One intent binds at least:

- a fresh 128-bit purge transaction identifier;
- the source quarantine transaction identifier;
- SHA-256 digests of the exact canonical quarantine intent and receipt bytes;
- the exact npm-root, quarantine-root, and selected candidate stable bindings;
- the original `item-v1-*` component and the derived purge-work component;
- purge schema and current purge-policy revisions;
- the same-volume identity and the raw pre-deletion available-capacity sample;
  and
- the canonical codec and aggregate resource bounds.

The factory derives the intent only from the canonical quarantine pair and
current descriptor-held evidence. Callers cannot assemble its fields. Decoding
rejects unknown or duplicate fields, noncanonical bytes, invalid identifiers,
unsafe components, digest or relationship mismatches, zero or future revisions,
and any value whose re-encoded bytes differ.

The pre-staging `Q` binding is the original complete candidate binding. After
staging, work identity means only the historical stable device, inode,
generation, birth time, kind, and owner plus current same-device, safe mode,
flags, ACL, and named-versus-opened agreement. Recursive deletion legitimately
changes directory modification and change times and link counts; retry must not
require those mutable historical values to remain equal.

### Purge receipt version 1

A receipt binds the exact canonical purge-intent bytes and digest and records
one terminal managed-namespace observation:

- `not-purged`: staging did not commit; the original exact item remains and the
  purge-work name is absent; or
- `item-absent`: the expected selected item is absent from both managed names.

The second outcome does not claim who removed the item, secure erasure, causal
block reclamation, or absence from snapshots, clones, backups, open handles, or
an unmanaged name. A receipt also records whether the original quarantine item
name was recreated by another object, whether recovery produced the receipt,
the post-attempt capacity observation when available, and the observation's
provenance.

Partial deletion is never a terminal receipt outcome. It remains a valid final
purge intent without a receipt and an exact purge-work item, visibly requiring
explicit retry or manual recovery.

## Mixed inventory and admission bounds

Quarantine, restore, and purge record handling shares one validated
exclusive lock and one aggregate managed namespace. The inventory must pair
every record, stage, item, and purge-work name before it exposes any row or
admits any mutation. It must reject orphan, duplicate, conflicting, unsafe,
unrecognized managed-looking, or over-bound state atomically.

Across all three operation families, at most one mutation intent may lack a
terminal receipt. Admission never assumes that an item or stage will be
successfully removed. Checked capacity arithmetic reserves the larger of every
reachable name combination. In particular, it accounts for the purge intent,
work name, receipt stage or final record, and a possible unrelated object that
recreates the original item name. Completed journal records remain immutable;
Phase 10 performs no record retention, compaction, or migration and never
unlinks a completed journal record.

## Initial preflight and staging order

Inventory, preparation, and execution are separate lifecycle stages. Inventory
and execution own distinct journal-lock lifetimes, preparation is lock-free,
and an opaque reference never carries a live lock between them. The initial
attempt uses this order:

1. The explicit inventory load acquires the validated nonblocking exclusive
   journal lock, runs recovery, validates the complete mixed inventory without
   retrying any mutation, projects an opaque reference, and releases the lock.
2. Preparation resolves that process-local reference to retained canonical
   evidence and performs descriptor-held record, root, and tree revalidation
   without holding the journal lock. It publishes no record and performs no
   namespace mutation before issuing the confirmation session.
3. After a matching authorization is consumed, the executor acquires a new
   validated nonblocking exclusive journal lock. While holding it, the executor
   repeats recovery, complete mixed-inventory validation, admission, and exact
   evidence rebinding. It retains that lock through intent publication,
   staging, bounded unlink, reconciliation, and terminalization.
4. Verify macOS 26-or-newer support for the required rename flags, with no
   fallback. Reopen and hold the fixed account root, npm root, quarantine root,
   records, and selected item; validate current eligibility and capacity and
   perform the first complete canonical-tree traversal.
5. Observe available capacity from the held volume. Failure or overflow before
   the intent exists rejects the attempt without mutation.
6. Publish and fully synchronize the immutable purge intent.
7. Because publication changes quarantine-root metadata, take fresh parent
   snapshots and repeat containment, identity, ownership, device, permissions,
   flags, ACL, record, selected-item, complete-tree, purge-policy, and work-name
   absence checks. After the final test hook and cancellation check, the staging
   rename is the next filesystem syscall.
8. Invoke at most one quarantine-root-descriptor-relative rename from the exact
   `item-v1-*` name to the exact purge-work name using `RENAME_EXCL`,
   `RENAME_NOFOLLOW_ANY`, and `RENAME_RESOLVE_BENEATH`.
9. Reconcile both names despite late cancellation. Before the first unlink,
   require the exact expected object at the work name, validate the parent
   bindings, apply `F_FULLFSYNC` to the quarantine root, and revalidate the
   synchronized named work binding.
10. Only then may the bounded recursive deletion engine enter the work tree.

Failure before a durable intent performs no purge mutation. A conclusive failed
staging attempt can publish `not-purged`. An indeterminate rename, failed parent
barrier, changed binding, or unsafe observation starts no unlink and preserves
the intent for recovery or manual inspection. Unsupported systems fail before
the capacity sample, intent publication, namespace creation, or mutation.

## Descriptor-relative recursive deletion

Recursive deletion is not an atomic operation. The engine deletes only beneath
the held, intent-bound purge-work descriptor and follows no symbolic link.

Before the first unlink of an initial attempt, the complete tree must satisfy
the full pinned npm cache grammar. Before a retry, a separate remainder
validator accepts only a subset obtainable by deletion from that grammar: names
may be missing and directories may be empty, but every remaining name, kind,
owner, device, permission, flag, ACL, link count, and relationship must still
be valid. The ordinary full-tree validator cannot be weakened or reused in a
way that makes partial state look like a complete cache.

For every explicit attempt, the engine:

- bounds total entries, depth, per-directory entries, aggregate raw-name bytes,
  memory, `EINTR` retries, and synchronization work with checked arithmetic;
- snapshots each directory's complete raw one-component names, validates and
  sorts them deterministically, and never derives a descendant path string;
- opens directories and regular files relative to held parents with no-follow
  semantics and requires named and opened bindings to agree immediately before
  mutation;
- requires the current account UID, same device, safe modes and flags, no
  extended ACL, one link for regular files, no repeated directory identity, and
  no symbolic link, special node, or mount crossing;
- deletes regular files with `unlinkat(parent, name, 0)` and empty directories
  depth-first with `unlinkat(parent, name, AT_REMOVEDIR)`;
- re-enumerates each directory to prove it empty before attempting its removal;
- never changes permissions or flags, follows a target, adopts an unexpected
  object, overwrites a name, copies data, or falls back to a path-based remover;
  and
- attempts to revalidate and fully synchronize every dirty directory boundary
  required to make the observed remainder or completion honest before
  returning.

Each unlink is an irreversible linearization point for one name. A return code
alone is not proof of the whole attempt. Post-operation observation determines
whether the name is gone, changed, or indeterminate. On the first unsafe,
changed, unavailable, over-bound, cancellation, or synchronization condition,
the engine stops attempting new unlinks and preserves all remaining names. It
must reconcile the current name and attempt every required dirty-parent
barrier. Only successful observation and barriers may produce a synchronized
partial result eligible for explicit retry. Observation or barrier failure
keeps the receipt-less intent and returns durability-unresolved manual recovery;
it must not claim a safe synchronized boundary or publish a terminal receipt.

The work root itself is removed only after its descriptor-held traversal proves
it empty. The quarantine root is then fully synchronized and reread before an
`item-absent` receipt may be published.

## Interruption and observational recovery

Recovery may validate records, observe the two managed item names, complete
required parent barriers, and publish a conclusive terminal receipt. It never
invokes or retries the staging rename and never unlinks an entry.

Let `Q` be the original quarantine item name, `W` the purge-work name, and
`expected` the stable directory identity sealed by the quarantine receipt and
purge intent. `another object` means a safely observed, nonexpected binding;
unsafe, changed during observation, or unavailable state is not classified as
another object:

| Current `Q` | Current `W` | Recovery result |
| --- | --- | --- |
| `expected` | missing | After full validation and synchronization, publish recovered `not-purged`; restore can become available through a fresh inventory. |
| missing | `expected` | After remainder validation and successful synchronization, preserve the complete or partial work tree and report explicit purge retry required; otherwise require manual recovery. Restore remains unavailable. |
| another object | `expected` | Preserve the recreated `Q`; after remainder validation and successful synchronization, expose only the exact work tree for explicit retry; otherwise require manual recovery. Restore remains unavailable. |
| missing | missing | Synchronize and publish recovered `item-absent` with observational wording. |
| another object | missing | Preserve the unrelated `Q`, synchronize, and publish recovered `item-absent` for the selected expected object. |
| `expected` | `expected` | Ambiguous; preserve both observations and require manual recovery. |
| any | safely observed other object | Preserve everything and require manual recovery. |
| unsafe, changing, or unavailable observation at either `Q` or `W` | any | Preserve everything and require manual recovery. |
| unavailable or changed parent/record state | any | Preserve everything and require manual recovery. |

Recovery cannot claim that DevSift performed deletion merely because the
expected item is absent. It cannot mark an unsafe work tree retryable, suppress
a blocker, or attach malformed global state to an unrelated transaction.

## Cancellation and explicit retry

- Cancellation before durable intent publication performs no mutation.
- Cancellation after intent but before a possible staging rename must reconcile
  `Q` and `W`; when `Q` remains exact and `W` is absent, it may close the attempt
  with a durable `not-purged` receipt.
- Once staging may have been invoked, cancellation cannot skip name
  reconciliation, the quarantine-root barrier, or safe state reporting.
- During recursive unlink, cancellation is observed at bounded checkpoints.
  The current entry outcome is reconciled and every required dirty-parent
  barrier is attempted before return. Only successful reconciliation and
  barriers produce a synchronized partial result; otherwise the result is
  durability-unresolved manual recovery. Cancellation does not grant permission
  to continue deleting to completion.
- Process death leaves the durable intent and current work-tree remainder as
  authoritative observable state. A later explicit inventory load may explain
  it but performs no deletion.
- Continuing requires a newly displayed permanent-deletion disclosure, a fresh
  exact confirmation, and a new single-use retry authority for the same intent.

There is no automatic, launch-time, periodic, background, age-only, or
confirmation-free retry.

## Restore interaction

Restore eligibility is not permanently revoked until staging commits, merely
because an authority is issued or consumed. Once the staging rename may have
been invoked, restore execution is suspended until reconciliation proves a
terminal state. A valid purge intent with `Q == expected` and `W` missing blocks
concurrent mutation while it is pending; after recovery records `not-purged`, a
fresh inventory may offer restore or a new purge attempt again.

Once the exact expected object is validated and synchronized at `W`, every
restore preparation for the source quarantine transaction fails. Partial
deletion never re-enables restore. A terminal `item-absent` receipt permanently
records that the managed receipt-bound item can no longer be restored. Purge
never touches or overwrites a recreated current `_cacache` or a recreated
quarantine item name.

## Observed capacity change

Capacity reporting must use an injected descriptor-based volume observer
suitable for synthetic tests. It must read the same held volume with `fstatfs`,
validate the volume identity, and compute non-root available bytes from
`f_bavail` and `f_bsize` using checked unsigned arithmetic.

The pre-deletion raw observation is taken before purge-intent publication and
stored in the intent. The post-attempt observation is taken only after current
namespace truth and required parent barriers are established and before the
terminal receipt is published. A retry or recovery may span processes and a
long interval; its receipt records that provenance.

The bounded result is one of:

- available capacity observed to increase by a stated amount;
- available capacity observed unchanged;
- available capacity observed to decrease by a stated amount; or
- comparison unavailable.

A failed or overflowing pre-observation prevents initial intent publication.
An unavailable post-observation does not rewrite conclusive deletion state or
invent a delta; the receipt records an unavailable comparison.

Concurrent writes and removals, APFS clones and snapshots, compression,
purgeable-space accounting, delayed block release, open file descriptors,
journal records, and filesystem implementation details mean the difference is
not a causal measurement. Zero, negative, or unexpectedly large changes are
valid observations. DevSift never polls until the value becomes positive,
equates it to the selected item's scanned allocation, or labels it guaranteed
freed or reclaimed bytes.

## Reporting, privacy, and non-goals

An in-process execution report may distinguish observed staging with no unlink
yet from one or more unlinks observed during that same call. No durable progress
marker or complete original-entry manifest exists, so a later process or
recovery pass must combine both as `staged-or-partially-purged`. That state
becomes explicit retry only after the exact remainder is safely validated and
successfully synchronized; otherwise it requires manual recovery. Process-local
execution and recovery reports otherwise distinguish at least:

- no mutation before a durable intent;
- staging not committed with a terminal `not-purged` receipt;
- safely validated and synchronized staged-or-partially-purged work requiring
  explicit retry, with finer progress wording only when observed inside the
  current execution call;
- item absence with a terminal receipt;
- cancellation before and after individual irreversible boundaries;
- unsafe, changed, busy, unsupported, over-bound, unavailable, durability, and
  manual-recovery failures; and
- capacity increase, unchanged, decrease, or unavailable with provenance.

Only a validated terminal receipt is durably completed. A receipt-less intent
with exact work state is crash-recoverable in the limited sense that Core can
inspect, preserve, explain, and offer a separately authorized retry. It is not
automatically recoverable to the original contents.

Purge intents and receipts contain sensitive raw relative components,
filesystem bindings, policy revisions, transaction relationships, and volume
observations. They remain local inside the private quarantine namespace and are
not logs, credentials, authentication, analytics, exports, uploads, or CLI
schema. Package-scoped frontend projections contain no transaction identifier,
record bytes, arbitrary path, or quarantine/work filename.

Phase 10 adds no secure erase, deletion of snapshots or backups, arbitrary-path
cleanup, active-cache deletion, batch operation, retention or journal
compaction, automatic or background cleanup, custom root, non-npm purge,
privilege escalation, shell execution, network access, telemetry, public Core
mutation API, CLI mutation command, updater, installer, signing, notarization,
or downloadable app artifact.

## Version and verification gate

Purge authorization, intent, receipt, policy, capacity observation, and bounded
report versions advance independently. Canonical completed records remain
readable under explicitly supported historical revisions, but old records never
gain new mutation authority. There is no import, record rewrite, migration, or
compaction path in Phase 10.

All tests use only fresh synthetic temporary fixtures. The implementation gate
must cover:

- canonical purge intent and receipt bytes, exact digests, stages, names,
  relationship validation, supported history, and malformed, duplicate,
  unknown, noncanonical, zero, and future values;
- opaque inventory references, stale and foreign sessions, exact-evidence
  rebinding, separate initial and retry confirmations, concurrent issuance and
  consumption, cancellation, and non-serializability;
- mixed-journal admission, maximum managed entries and raw-name bytes, checked
  overflow, one receipt-less mutation across all families, and preservation of
  every immutable historical record;
- full and remainder tree validation at every entry, depth, and byte boundary,
  including symlinks, hard links, special nodes, ACLs, modes, flags, ownership,
  device crossings, repeated directories, identity and parent swaps, and names
  that are byte-near-misses of the npm grammar;
- intent-before-staging ordering, exact rename flags, every rename return and
  indeterminate branch, parent and record synchronization failures, and no
  unlink before the validated synchronized staging commit;
- failure, cancellation, or simulated interruption before and after every
  unlink and directory removal, deterministic traversal, safe dirty-directory
  barriers, complete remainder validation, and preservation of sentinels
  outside the exact work tree;
- the complete `Q`/`W` recovery table, explicit retry authority, recreated-name
  preservation, terminal receipt publication, and permanent restore refusal
  after staging;
- capacity-observer unavailable and overflow paths, increase, unchanged, and
  decrease results, plus cross-process provenance without causal wording;
- presentation disclosure covering APFS snapshots or clones, backups, open
  file descriptors, and storage-device data or block retention;
- package-scoped app confirmation, accessibility, cancellation, dismissal,
  stale-result suppression, and bounded presentation; and
- source-visibility and CLI negative tests proving that no public, arbitrary,
  automatic, batch, or command-line deletion path exists.

The completed
[focused irreversible-deletion security and privacy review](PURGE_SECURITY_REVIEW.md)
records acceptance of the disclosed same-UID limitation for this narrow manual
boundary and confirms that no priority-zero or priority-one finding remains.
Strict formatting, manifest validation, debug and release builds, the complete
parallel test suite, and `git diff --check` remain release gates.
