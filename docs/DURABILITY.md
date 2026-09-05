# Quarantine durability contract

This document defines the crash-consistency boundary for DevSift's internal
npm quarantine transaction. It extends the atomic namespace-move contract in
[QUARANTINE.md](QUARANTINE.md); it does not authorize a new kind of filesystem
operation.

## Scope

The durability layer may:

- serialize one already-authorized `_cacache` quarantine attempt;
- publish immutable intent and terminal receipt records inside the verified
  `.devsift-quarantine-v1` directory;
- synchronize those records and the two affected namespace parents;
- reconcile an interrupted intent from current descriptor-bound source and
  destination observations; and
- block a new attempt when prior state is incomplete, malformed, unsafe, or
  ambiguous.

It may not resume an interrupted move, recreate process-local authorization,
automatically restore or roll back a candidate, overwrite a record or item,
delete or compact anything. Its raw recovery entry points, records, and reports
remain unavailable to the app and CLI. The source-run app can request only the
package-scoped explicit recovery/inventory projection; the CLI and public Core
API expose no mutation path.

## Transaction invariants

The state machine is monotonic:

```text
no transaction
  -> durable immutable intent
  -> at most one authorized rename outcome
  -> synchronized source and destination parents
  -> durable immutable terminal receipt
```

There is no mutable `rename-started` flag. A crash can therefore leave only
one of these durable states:

- no final intent, which can never authorize a candidate rename;
- an intent without a receipt, which later reconciliation must inspect;
- an intent and its matching terminal receipt; or
- malformed or inconsistent state, which blocks later mutation.

The implementation must publish and synchronize the final intent before the
candidate rename is invoked. A staged file, an in-memory report, a successful
`write`, or a successful record-file sync alone is not an intent.

## On-disk namespace

All names are single validated raw path components beneath a held, revalidated
quarantine-directory descriptor:

```text
.devsift-quarantine-v1/
  .lock-v1
  .intent-stage-v1-<32 lowercase hexadecimal digits>
  .intent-v1-<32 lowercase hexadecimal digits>
  .receipt-stage-v1-<32 lowercase hexadecimal digits>
  .receipt-v1-<32 lowercase hexadecimal digits>
  item-v1-<32 lowercase hexadecimal digits>
```

The 32 hexadecimal digits encode a 128-bit transaction or destination nonce.
Record creation is write-once and uses descriptor-relative, non-following,
exclusive operations. Final records, destination items, and staged files are
never overwritten. Staged records grant no authority and may remain after a
crash; this increment performs no cleanup or unlink.

A canonical intent stage without its final intent is preserved but inert and
does not block a later transaction. A canonical receipt stage may be promoted
only when its final intent, exact digest, and current terminal namespace state
all agree; recovery then completes the directory synchronization and final
record revalidation. Malformed, conflicting, or unverifiable staged state
blocks new mutation and requires manual recovery.

The directory is bounded to 4,096 entries other than `.` and `..`, and 4 MiB
of raw entry-name bytes during recovery. Admission reserves the worst-case
intent, item, and receipt-stage peak before publishing a new intent. Exceeding
either limit blocks new mutation. Current macOS `NAME_MAX` makes the entry-count
limit tighter in ordinary filesystems; the aggregate byte cap remains a
defense-in-depth bound for enumeration and future filesystem behavior.

## Intent version 1

The private wire schema is `devsift.quarantine-intent` version 1. The Core
domain value is not `Codable`; a dedicated wire DTO owns serialization.

One intent binds:

- a 128-bit transaction identifier;
- stable bindings for the held npm root, quarantine root, and approved
  candidate: device, inode, generation, birth time, kind, UID, mode, flags,
  and link count;
- the exact raw source path components;
- exactly 16 preplanned, distinct destination components;
- the exact classifier, built-in catalog, and npm rule revisions; and
- the current intent format and bounded codec rules.

All raw path components are losslessly Base64 encoded. The transaction
identifier is the same canonical 32-character lowercase hexadecimal value used
in record names. Integer fields are canonical decimal strings rather than JSON
numbers. Encoding uses sorted keys and a fixed maximum size. Decoding rejects
noncanonical bytes, unknown fields, duplicate fields, invalid Base64,
noncanonical integers, unsupported versions, unsafe paths, duplicate
destinations, unknown policy identifiers, zero revisions, and revisions newer
than this build by decoding, validating, re-encoding, and requiring
byte-for-byte equality.

Publishing a new intent additionally requires the exact current classifier,
catalog, and npm-rule revisions. Existing canonical records with supported
earlier revisions remain readable, so an ordinary policy update does not poison
completed history or an inert stage. This compatibility grants no old policy
new mutation authority: recovery never repeats a candidate rename, and every
new attempt must use the current policy tuple.

The destination plan is complete before intent publication. After a crash,
recovery observes those destinations but never continues to the next one.

## Receipt version 1

The private wire schema is `devsift.quarantine-receipt` version 1. A receipt
binds:

- the same transaction identifier;
- the SHA-256 digest of the exact canonical intent bytes;
- one terminal outcome: `quarantined`, `not-moved`, or `rolled-back`;
- the selected destination ordinal and expected destination binding when the
  outcome is `quarantined`;
- whether the source name was recreated; and
- whether recovery inferred the terminal outcome and constructed
  the receipt bytes.

Recovery may finish publishing a canonical receipt stage that the original
execution already constructed. In that case `producedByRecovery` remains
`false`; promotion does not rewrite the immutable payload.

The digest detects accidental corruption and mismatched records. It is not a
secret, signature, authentication mechanism, or defense against a process
running as the same account. A receipt is valid only when its filename,
transaction identifier, intent digest, field relationships, security metadata,
and canonical bytes all agree.

`manual-recovery-required` is deliberately not a terminal receipt outcome.
Ambiguous state retains its intent without a receipt and blocks later mutation.

## Exclusive session

Before recovery or intent creation, Core opens or exclusively creates
`.lock-v1` with mode `0600`, without following a symbolic link. It requires a
same-volume, single-link regular file owned by the current non-root account,
with exact mode `0600`, safe flags, no extended ACL, and agreement between its
held and named bindings. A nonblocking exclusive advisory lock is held from
recovery through receipt publication.

The lock prevents accidental overlap among cooperating DevSift processes. It
is not mandatory access control and makes no security claim about another
process running as the same account. All filesystem observations and
non-overwriting operations remain authoritative.

## Publication and synchronization

Record publication uses this order:

1. Exclusively create a unique staged regular file with mode `0600`.
2. Write the complete bounded canonical bytes, retrying only bounded `EINTR`.
3. Revalidate the held staged file's type, owner, mode, device, link count,
   flags, ACL, length, and named binding.
4. Apply `F_FULLFSYNC` to the staged file. There is no weaker fallback.
5. Rename the stage to its final name with `RENAME_EXCL`,
   `RENAME_NOFOLLOW_ANY`, and `RENAME_RESOLVE_BENEATH`.
6. Apply `F_FULLFSYNC` to the quarantine-directory descriptor.
7. Revalidate the final name against the still-held record descriptor and
   apply a final `F_FULLFSYNC` barrier to that descriptor.

Creating or reopening the quarantine root is followed by full synchronization
of the npm-root and quarantine-root descriptors before intent publication.
Because writing the intent changes quarantine-directory metadata, Core takes a
fresh quarantine-root snapshot before final source validation. The candidate
rename remains the next filesystem syscall after that final validation and its
test hook.

After any forward or reverse rename may have been invoked, Core completes
reconciliation despite cancellation, then applies `F_FULLFSYNC` to both the
npm-root and quarantine-root descriptors. Only after both namespace parents
cross that barrier may Core publish a terminal receipt using the same staged
protocol.

`fsync` or `F_FULLFSYNC` failure is never converted to durable success. Failure
before a durable intent prevents the candidate rename. Failure after a durable
intent leaves recovery-required state and preserves every observed object.
`F_FULLFSYNC` is Darwin's strongest available flush request and remains
best-effort at the hardware boundary; DevSift claims only that every required
call returned successfully, not absolute survival on defective storage.

## Recovery reconciliation

Recovery runs under the same exclusive session during quarantine transaction
admission, restore preparation, restore transaction admission, an explicit
inventory load or refresh, and the follow-up refresh when a restore execution
returns to the still-current, uncancelled view-model operation. Dismissal,
cancellation, or superseding work can prevent or cancel that UI refresh without
bypassing Core's transaction-level durability handling. Recovery can therefore
run later in the same process or after restart, but never merely because the app
launched. It strictly
validates and pairs every final intent and receipt, rejects orphan receipts and
unmanaged `item-v1-*` entries, and rejects destination reuse across intents. It
applies the staged-record rules above before reconciling receipt-less intents. A
valid existing terminal receipt is never rewritten. It is immutable historical
evidence, not a claim that the same source or destination names still exist
later. Validating a final receipt requires its record metadata, canonical bytes,
filename, transaction pairing, and digest; live namespace truth is required only
for a receipt-less intent or receipt-stage promotion.

For each receipt-less intent, all root, quarantine-root, record, source, and
planned-destination observations must be available and safe. Let `expected`
mean the complete stable candidate binding sealed by the intent:

| Current source | Planned destinations | Recovery result |
| --- | --- | --- |
| `expected` | none is `expected` | synchronize and publish recovered `not-moved` |
| missing | exactly one is `expected` | synchronize and publish recovered `quarantined` |
| another object | exactly one is `expected` | recovered `quarantined`; source recreated |
| any other combination | any | leave intent pending and block new mutation |

An unrelated occupant at a planned destination is never adopted. An
unavailable observation, multiple expected destinations, an expected object at
both source and destination, root replacement, record corruption, or an
unknown, zero, or future policy revision is ambiguous and blocks.

Recovery records only what the current namespace proves. It never repeats the
authorized rename, chooses another destination, removes an occupant, or
performs an automatic reverse rename.

## Reports and cancellation

Execution-report contract version 2 distinguishes:

- a pre-intent `notMoved` result with no durability claim;
- a durable terminal receipt;
- a durable intent whose terminal receipt still requires recovery; and
- an unresolved manual-recovery result.

`isDurablyRecorded` is true only for a validated, synchronized terminal
receipt. `isCrashRecoverable` is true only when the report carries validated
`intentRecorded` or `receiptRecorded` evidence. An `unresolved` state is false
even when it includes a transaction identifier; that identifier is diagnostic,
not proof that a valid intent crossed its publication barrier.
`performedPermanentDeletion` remains unconditionally false.

`isCrashRecoverable` does not promise that later reconciliation, including after
restart, can always publish a receipt. It means the canonical journal contains
authoritative evidence that recovery can safely inspect and then either
complete, preserve, or block. A detached journal, malformed or conflicting
inventory, or another state whose canonical evidence cannot be validated is
`unresolved`.

Cancellation before rename may produce a durable `not-moved` receipt. Once a
rename is invoked, cancellation is only latched into the report; it cannot skip
namespace synchronization, receipt publication, or reconciliation.

## Privacy and non-goals

Intent and receipt files contain sensitive exact raw relative paths, filesystem
bindings, and policy revisions. They remain local inside the account-owned
quarantine directory and are not logs, exports, credentials, or authentication.

The original durability increment added no restore or frontend action. The later
restore increment adds a separate internal record family and authority without
changing this quarantine transaction's meaning. Phase 9 exposes only bounded
package-scoped app facades: an explicit recovery request performs recovery,
final journal reread/revalidation, and inventory projection under the same
validated exclusive lock, and a separate receipt-bound confirmation can restore
one item without overwrite. Neither operation runs automatically at app launch.

Purge, permanent deletion, journal compaction, record deletion, automatic
rollback, retention, batch or background action, custom-root or multi-rule
execution, public or CLI mutation, distributed app packaging, analytics,
telemetry, and network access remain absent. Quarantine is a same-volume rename
that deallocates no data and guarantees exactly 0 B of freed capacity. See the
[manual restore contract](RESTORE.md).

## Verification gate

Tests must cover canonical wire bytes, future-version and malformed-record
rejection, exclusive publication, short writes and bounded `EINTR`, every sync
failure boundary, staged and orphan records, lock contention, the complete
recovery table, source and destination replacement, record symlinks and hard
links, ACL and mode failures, collision plans, cancellation on both sides of
rename, and preservation of every synthetic fixture outside the exact journal
namespace.
