# Manual quarantine restore contract

This document defines the Core-internal, npm-only workflow for manually
restoring one item that DevSift previously moved into its private quarantine
namespace, plus the bounded package-scoped facade used by the source-run app. It
extends the
[quarantine execution contract](QUARANTINE.md) and the
[durability contract](DURABILITY.md); it does not broaden quarantine
authorization version 1 or authorize deletion.

The app reaches recovery inventory and restore only after an explicit user
action and only through opaque process-local references issued by Core. App
launch never invokes recovery. The CLI and public Core API remain read-only.

## Scope

The restore increment can:

- inspect the bounded private journal under its existing validated exclusive
  lock and report each transaction separately;
- identify one restorable npm `_cacache` only from a canonical final quarantine
  intent and its matching canonical final `quarantined` receipt;
- create a fresh process-local, single-use restore claim for that exact record
  pair after an explicit caller confirmation;
- publish a separate immutable restore intent before one reverse namespace
  rename;
- move the receipt-bound `item-v1-*` directory back to the intent-bound exact
  `_cacache` name only when that name is absent;
- synchronize and reconcile the two affected namespace parents, then publish a
  separate immutable terminal restore receipt; and
- return bounded, transaction-by-transaction diagnostics for restorable,
  restored, skipped, changed, failed, recovered, or unresolved state.

The increment supports one exact item and one restore attempt at a time. It does
not accept an arbitrary source URL, destination URL, quarantine item name, npm
root, custom cache root, or caller-created journal value.

## Authority boundary

A quarantine receipt is historical evidence, not authority for another
filesystem mutation. The original `CleanupQuarantineAuthorization` has already
been consumed, is recoverable-quarantine-only, and cannot be reused, persisted,
reconstructed from journal bytes, or revised to authorize restore.

The internal manual workflow therefore creates a distinct process-local restore
session and opaque exact-transaction reference. A caller must explicitly confirm
Core's exact statement for that reference: npm work using the cache was stopped,
the current quarantined contents may have changed since quarantine, and restore
must not overwrite the original name. The resulting internal claim is single-
use across every copy and is not authentication, proof of human review, a
durable credential, or standalone filesystem authority.

The selection session may become stale. The executor never trusts its earlier
observations: it consumes the claim once, reacquires the journal lock, reopens
the real account's exact passwd-home `~/.npm` root, and establishes every
filesystem fact again while descriptors remain held. No public restore
authorization, claim, executor, report, or inventory type is exposed. The
package-scoped app facade projects only bounded readiness, opaque references,
the exact confirmation statement, and bounded outcomes.

## Exact eligibility

An item is eligible for a restore attempt only when all of the following are
true under one bounded, descriptor-held inventory pass:

1. The final quarantine intent has a canonical managed filename, canonical
   bytes, safe record metadata, a supported historical schema and policy tuple,
   and the exact `_cacache` source grammar.
2. Its final receipt is canonical, has safe record metadata, matches the exact
   intent bytes and SHA-256 digest, and has outcome `quarantined`.
3. The receipt selects one destination ordinal from that intent and binds that
   destination to the intent's exact candidate binding.
4. The held current npm root and quarantine root match the historical parent
   bindings and still satisfy the current account, same-device, containment,
   mode, flag, ACL, volume-capability, and no-follow requirements.
5. The selected `item-v1-*` name currently identifies the exact receipt-bound
   directory. Its current descriptor-held tree passes the bounded restore
   policy for identity, kind, ownership, device, safe permissions and flags,
   ACLs, link counts, cacache grammar, and traversal limits.
6. The original exact `_cacache` name is absent immediately before mutation.
7. No successful restore receipt already exists for the source quarantine
   transaction, no mutation intent of either kind is pending, and the complete
   mixed journal inventory is structurally admissible.

A `not-moved` or `rolled-back` quarantine receipt is not restorable. A missing,
replaced, unverifiable, or unsafe quarantined item is never adopted. An occupied
`_cacache` name is never replaced; it produces a bounded skipped or changed
result and leaves both objects untouched.

The original cleanup age threshold and current cleanup disposition are not
rerun as restore eligibility. They justified the earlier one-way quarantine
attempt, not the recovery operation. New restore intents instead pin the exact
current restore-policy revision. Supported historical quarantine policies
remain readable and restorable; unknown, zero, future, malformed, or no-longer-
supported record revisions fail closed.

## Separate immutable restore journal

Restore never edits, replaces, or reinterprets a final quarantine intent or
receipt. It adds a separate canonical version-1 transaction in the same verified
quarantine directory:

```text
.devsift-quarantine-v1/
  .restore-intent-stage-v1-<32 lowercase hexadecimal digits>
  .restore-intent-v1-<32 lowercase hexadecimal digits>
  .restore-receipt-stage-v1-<32 lowercase hexadecimal digits>
  .restore-receipt-v1-<32 lowercase hexadecimal digits>
```

The suffix is a fresh 128-bit restore-attempt identifier, not the source
quarantine transaction identifier. This permits another explicit attempt after
a terminal `not-restored` receipt while forbidding another attempt after a
terminal `restored` receipt.

A restore intent binds at least:

- its restore-attempt identifier and the source quarantine transaction
  identifier;
- SHA-256 digests of the exact canonical quarantine intent and receipt bytes;
- the held npm-root, quarantine-root, and candidate bindings;
- the exact selected quarantine item component and exact original source
  components;
- the source receipt's selected destination ordinal; and
- the restore schema and current restore-policy revisions.

A restore receipt binds the exact canonical restore-intent bytes and records one
terminal namespace outcome: `restored` or `not-restored`. A `restored` receipt
also records whether the quarantine item name was recreated by another object;
a `not-restored` receipt records whether the original destination name was
occupied. Every receipt records whether recovery produced it. Ambiguous state
is not a terminal receipt outcome.

The dedicated wire DTOs own serialization. Core domain values remain
non-`Codable`. Decoding is bounded and canonical, rejects unknown or duplicate
fields and invalid relationships, and requires byte-for-byte re-encoding just
as the quarantine journal does. Digests detect mismatched records; they are not
signatures, secrets, or caller authentication.

## Inventory and admission

Quarantine and restore records form one managed inventory beneath the same held
quarantine-root descriptor. Before either operation publishes a new intent,
Core must:

- reconcile every receipt-less quarantine or restore intent without executing
  its rename;
- validate all stage/final pairings, record digests, parent bindings,
  transaction links, destination ownership, and successful-restore uniqueness;
- reject orphan, duplicate, conflicting, unsafe, or unmanaged records and
  items;
- allow at most one receipt-less mutation intent across both operation kinds;
  and
- reserve entry-count and raw-name-byte capacity with checked arithmetic for the
  operation's worst-case peak.

The existing selected item already counts toward inventory capacity. A restore
admission reserves two additional managed names: one final-or-staged restore
intent and one final-or-staged restore receipt. It must assume the item remains
present for a `not-restored` outcome and must not reclaim its capacity in
advance. Insufficient-capacity and every arithmetic-overflow branch fail closed
without publishing an intent; exact-boundary behavior is covered by tests.

Completed records remain immutable and accumulate. This increment performs no
journal compaction, retention, unlink, or record migration.

### Package-scoped recovery inventory

The app cannot supply a journal root, transaction identifier, record bytes,
quarantine filename, or item path. Its production facade is fixed to the current
non-root account's passwd-home `~/.npm` and fixed quarantine namespace.

The initial inventory load and a manual refresh explicitly open that namespace.
When a restore execution returns to the still-current, uncancelled view-model
operation, the app invokes the same operation once to publish current state.
Dismissal, cancellation, or superseding work can prevent or cancel that refresh
and suppresses stale UI publication without bypassing Core's transaction-level
durability handling. Under one validated exclusive lock, Core runs observational
recovery, rereads and revalidates the complete mixed
inventory after recovery, and only then projects a result. Malformed or
unresolved journal state, unsafe trusted parents, and aggregate resource
exhaustion reject the complete request; there is no partial-success list. An
individual missing, changed, unsafe, or per-item over-bound quarantine item
remains visible as a non-restorable row. App launch does not call this operation.

The successful projection contains a deterministic bounded list of items whose
canonical quarantine intent has a matching durable final `quarantined` receipt
and no successful restore receipt. Each row reports whether the original source
is clear or occupied and whether the quarantined item is available, missing,
changed, unsafe, or over its validation bound. A row is restore-ready only when
the original `_cacache` name is absent and the exact quarantined item remains
available.

Each row carries an opaque process-local reference bound to that one inventory
session. A reference from another or older session fails even when visible row
fields match. Preparing restore rebinds the reference to the exact canonical
intent and receipt observed by that session and rejects intervening inventory
change. Core then issues the exact restore confirmation statement, and a
matching confirmation can authorize one execution only. The app cannot derive
restore authority from presentation state.

## Mutation and synchronization order

The only restore mutation is one descriptor-relative, same-volume reverse
rename from the exact selected quarantine item to the exact original `_cacache`
name. It uses `renameatx_np` with `RENAME_EXCL`, `RENAME_NOFOLLOW_ANY`, and
`RENAME_RESOLVE_BENEATH`, and therefore retains the macOS 26-or-newer mutation
requirement while macOS 14 read-only surfaces remain supported.

The required order is:

1. Hold the validated nonblocking exclusive journal lock and validate the
   complete mixed inventory.
2. Reopen and hold the exact npm root, quarantine root, selected record files,
   and selected item; establish current eligibility and capacity.
3. Exclusively create, write, validate, and `F_FULLFSYNC` the restore-intent
   stage; exclusively rename it to the final intent name; `F_FULLFSYNC` the
   quarantine root; revalidate the exact final bytes through the still-held file
   descriptor; and `F_FULLFSYNC` that descriptor.
4. Because intent publication changes quarantine-directory metadata, take fresh
   parent snapshots and immediately revalidate containment, kind, identity,
   restore policy, item binding, and destination absence. The reverse rename is
   the next filesystem syscall after this final check and its test hook.
5. Invoke exactly one exclusive beneath-root rename. Never copy, clone, link,
   unlink, remove, replace, or fall back to a path-based operation.
6. After any result that could have invoked rename, reconcile the held parent
   bindings and both names despite cancellation, then apply `F_FULLFSYNC` to the
   npm-root and quarantine-root descriptors.
7. Only for conclusive namespace truth, publish and synchronize the immutable
   restore receipt through the same exclusive staged-record protocol.

No successful `write`, record-file sync, stage, rename return code, or in-memory
report by itself is durable success. A restore is durably completed only when
the final restore receipt, its exact intent relationship, and every required
barrier have been validated successfully.

## Interrupted-restore recovery

The internal recovery entry point and admission recovery are observational.
They may finish a receipt for a previously authorized restore intent, but never
invoke or retry the reverse rename. Let `expected` mean the candidate binding
sealed by the restore intent:

| Current quarantine item | Current `_cacache` | Recovery result |
| --- | --- | --- |
| `expected` | missing | synchronize and publish recovered `not-restored` |
| `expected` | another object | synchronize and publish recovered `not-restored`; destination occupied |
| missing | `expected` | synchronize and publish recovered `restored` |
| another object | `expected` | recovered `restored`; quarantine name recreated |
| any other combination | any | preserve the intent and report bounded manual recovery |

An unavailable observation, changed parent, expected object at both names,
missing expected object at both names, malformed link to the source transaction,
or any unrelated occupant that the table cannot classify remains unresolved.
Recovery never adopts an occupant, edits a record, chooses another destination,
or removes a conflicting `_cacache`. A recovered `restored` receipt records
only conclusive namespace truth for the expected object; it does not prove
which process performed the move.

## Cancellation and reporting

Cancellation before durable intent publication produces no restore mutation.
Cancellation after intent publication but before rename may be closed with a
durable `not-restored` receipt after revalidation. Once rename is invoked,
cancellation is only latched into the process-local report; reconciliation,
namespace barriers, and terminal receipt publication continue when safe.

The recovery and execution reports are bounded, deterministically ordered,
process-local, and non-`Codable`. They distinguish, per transaction:

- completed terminal journal state;
- failed system or durability work;
- live state changed from the durable binding;
- a receipt produced by recovery;
- a successfully restored item;
- a safely skipped item, including an occupied original name; and
- unresolved state that requires manual inspection.

State that cannot be attributed to a canonical transaction, such as a malformed
managed-looking name, is represented by one bounded global blocker rather than
being attached to an unrelated transaction.

A transaction identifier is diagnostic, not proof of a valid intent. An
unresolved result is neither completed nor crash-recoverable; a transaction
identifier alone cannot establish either claim. Every report states that
permanent deletion was not performed.

Core's bounded recovery diagnostics may inspect and explain ambiguous state and
refresh the inventory. A restore claim is created only for a newly proven
eligible item. Diagnostics cannot mark unsafe state resolved, suppress a
blocker, edit or delete a journal record, rename an arbitrary object, or become
authority.

## Privacy and non-goals

Restore records contain sensitive raw relative paths, filesystem bindings,
policy revisions, and links to historical transactions. They stay inside the
account-owned quarantine directory and are not logs, exports, credentials,
analytics, or authentication. Reports and process-local claims are not
persisted, uploaded, or included in a CLI schema.

Restore, like quarantine, is a same-volume namespace rename. Neither operation
deallocates file data, and quarantine guarantees exactly 0 B of freed capacity.

This increment adds no:

- purge, permanent deletion, unlink, recursive removal, overwrite, journal
  cleanup, compaction, retention policy, or record migration;
- automatic restore, automatic rollback, background action, app-launch action,
  batch restore, or unattended retry;
- public mutation API, public restore model, CLI command, or frontend access to
  raw journal records, transaction selectors, claims, or executors;
- custom root, caller-selected path, arbitrary quarantine namespace, multi-rule
  restore, or non-npm executor;
- persisted approval or attestation, import, export, general-purpose `Codable`
  domain state, telemetry, network access, npm invocation, privilege escalation,
  private process-inspection API, or distributed app artifact; or
- change to public `SafetyMode.scanOnly` or its
  `allowsFilesystemMutation == false` result.

Purge and permanent removal remain a later, separately reviewed policy,
authorization, and explicit user action. No restore artifact may be interpreted
as purge authority.

## Verification gate

Tests use only synthetic temporary fixtures. The implementation gate covers:

- canonical restore intent and receipt bytes, exact digests, historical
  quarantine-policy compatibility, current restore-policy admission, and every
  malformed, future, orphan, duplicate, and cross-transaction relationship;
- exact inventory limits, checked capacity arithmetic, mixed quarantine/restore
  pending-intent exclusion, staged records, retry-after-`not-restored`, and
  refusal after `restored`;
- record and item symlinks, hard links, ACLs, ownership, modes, flags, mounts,
  parent replacement, source and destination swaps, subtree grammar and
  traversal limits, and held-descriptor versus named-object disagreement;
- destination occupation before and immediately after final revalidation,
  exclusive-rename errors and indeterminate returns, and the complete recovery
  table;
- every `F_FULLFSYNC`, short-write, bounded-`EINTR`, stage-promotion, and receipt-
  publication failure boundary without overclaiming durability;
- cancellation before intent, between intent and rename, and after the rename
  linearization point;
- deterministic bounded per-item diagnostics and preservation of every fixture
  outside the exact journal namespace;
- package-facade tests for explicit same-lock load/reconciliation, atomic
  inventory failure, deterministic active-item projection, readiness, foreign
  or stale opaque references, exact confirmation, and single-use execution; and
- source-visibility inspection, scan-only public status tests, and CLI negative
  tests showing that restore, recovery, and mutation remain unreachable from
  public and CLI surfaces.

A focused filesystem-security and privacy review remains part of this
implemented boundary's acceptance gate. Every code commit must also satisfy the
repository-wide definition of done in
[DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md#definition-of-done-for-every-code-commit).
The completed repository-internal review and its closed findings are recorded
in [MANUAL_RESTORE_SECURITY_REVIEW.md](MANUAL_RESTORE_SECURITY_REVIEW.md).
