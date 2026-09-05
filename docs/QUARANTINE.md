# Quarantine execution contract

DevSift's ninth increment added a Core-internal execution kernel for one exact
npm `_cacache` quarantine attempt. The tenth adds a durable journal and recovery
engine around that move. The kernel consumes only the internal claim from a
single-use `CleanupQuarantineAuthorization`, revalidates the approved object
while descriptors remain held, and can perform one same-volume, exclusive
namespace move. After explicit review and two confirmation gates, the source-run
app's local workflow derives the approval and authorization, then passes only
that authorization into the package-scoped executor for this exact operation.
The CLI and public package API expose neither execution nor recovery.

The scanner, classifier, and read-only surfaces support macOS 14 or newer. The
internal quarantine mutation kernel has a stricter runtime requirement: it
requires macOS 26 or newer because its safety boundary depends on
`RENAME_RESOLVE_BENEATH`. On older macOS versions, execution fails closed before
creating the quarantine directory or invoking any mutation syscall.

The report remains process-local and non-`Codable`, but the internal transaction
now uses canonical immutable intent and receipt records, full synchronization,
and descriptor-bound recovery. This quarantine transaction grants no restore,
purge, or deletion authority. The later, separately authorized Core-internal
manual restore workflow is defined in [RESTORE.md](RESTORE.md). The app can
explicitly request bounded recovery inventory and one receipt-bound restore only
through package-scoped facades; neither operation is available to the CLI or
public package API, and neither runs automatically at launch.

## Exact supported policy

The internal `CleanupQuarantineExecutor` fails closed unless its consumed claim
retains one canonical approval with all of these exact properties:

- explainable-classification revision 3;
- built-in catalog revision 6;
- one `devsift.cache.npm` revision 5 entry;
- one direct child named exactly `_cacache`, with directory kind and the
  approval-bound identity on the selected root's device;
- `review-required`, conditional reproducibility, and responsible tool `npm`;
- the sole version-1 deferred npm-stop precondition, its canonical review
  acknowledgement, and the exact version-1 attempt attestation.

A bare approval, revalidation report, review projection, path, manifest, or
caller-created lookalike cannot enter execution. Authorization consumption is
atomic and single-use across all copies, even when preflight later fails.

## Descriptor-held preflight

Execution resolves the real current non-root account through `getuid`/`geteuid`
and passwd data, then requires the approved source root to be exactly `~/.npm`.
Starting at `/`, each component is opened relative to an already-held
descriptor without following symbolic links. The `.npm` root and sole
`_cacache` candidate must match their approval-bound identities. The home,
root, and candidate must be current-account-owned directories on one device,
and the snapshots captured at execution must remain stable through preflight.
The home, root, candidate, and descendants may not expose group or other POSIX
write bits or filesystem flags. The root, candidate, and every opened
descendant must also have no extended ACL; the home can retain macOS's
protective deny ACL and is not treated as ACL-derived write-safety evidence.

The candidate is exhaustively traversed through held directory descriptors.
The complete pinned cacache grammar is enforced: exact root entries, marker
directories, lowercase shard and leaf names, an absent or empty `tmp`, no
unexpected entries, no symbolic links or special nodes, no crossed device, no
repeated directory identity, current-account ownership, and exactly one link
for every regular file. Entry, depth, and raw-name-byte limits are bounded.
Every entry's
modification time must satisfy the inclusive seven-day rule against the
execution clock; a future timestamp, younger entry, race, malformed value,
permission failure, or incomplete traversal fails closed.

The synchronous move closure runs before those descriptors are released. The
kernel does not use a prior `CleanupRevalidationReport` as authority and does
not create a check-then-use gap by returning a path-only decision.

Held descriptors do not make the filesystem a snapshot. Descendant content can
change after its individual observation, and macOS provides no supported
`renameatx_np` condition that requires the source name to still reference a
particular held inode. A same-account process can therefore replace the source
between the last named check and the rename syscall. Exclusive rename protects
the destination from overwrite, not that source identity. A process with
sufficient namespace access, including another same-account process, can win
this race. A mismatch that remains observable during reconciliation is reported
for manual recovery with a bounded location when possible; the kernel does not
relabel that observed wrong object as a successful quarantine.

The held quarantine-root descriptor is validation and reconciliation evidence,
not the forward syscall's destination anchor. Both rename operands resolve from
the held approved-root descriptor so a reparented quarantine directory cannot
carry DevSift's move outside that root. No Darwin primitive atomically requires
both the validated quarantine-root inode and its ancestry. A same-account
process can therefore replace the quarantine-root name after its last check and
redirect a move into that replacement inside the held root. When reconciliation
observes that binding mismatch, Core does not report success and may have no
trustworthy location to return. Only a successful `quarantined` outcome asserts
that the destination parent was the verified private directory when reconciled.
Its separate durability state says whether the corresponding intent or terminal
receipt was recorded.

Post-rename reconciliation is detection, not prevention, and a safe rollback is
not always possible. The npm-stop attestation is still an explicit accepted
risk, not a lock or proof of inactivity.

## Private quarantine namespace

The destination path is `.devsift-quarantine-v1/<generated-name>`, resolved
beneath the held `~/.npm` descriptor. For a successful outcome, its parent must
remain the same held, same-volume directory owned by the current account with
mode `0700`, no extended ACL, no unsafe flags, and volume support for the
required exclusive-rename and POSIX-permission behavior. If absent, Core creates
it with the private mode and immediately verifies the opened and named bindings.

Destination names are bounded, validated raw components with a fixed
`item-v1-` prefix and random nonce. At most 16 names are attempted. Existing
destinations are never overwritten.

Every forward and reverse attempt uses root-descriptor-relative `renameatx_np`
with all of these flags:

```text
RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH
```

There is no copy fallback, `unlink`, recursive deletion, shell command, npm
invocation, cross-volume move, alternate destination, or permission
escalation.

## Reconciliation and rollback

Core does not infer the result from the rename return code alone. Immediately
after every attempt it reconciles the held source, destination, and parent
bindings. A verified moved candidate with an absent source becomes
`quarantined`. If a different object recreated the source name after the move,
Core preserves both objects and emits the same status with
`sourceNameWasRecreated == true`. Status and durability are deliberately
separate: a move status alone does not claim its receipt was published.

If the destination contains the approved object but post-move validation does
not remain trustworthy, Core attempts one reverse descriptor-relative rename
with the same non-following, beneath, and non-overwriting constraints. A
verified reverse move becomes `rolledBack`. Core never overwrites a recreated
source name during rollback. Ambiguous rename results, an unverifiable
destination, changed parents, a source that prevents rollback, or a failed or
indeterminate rollback become `manualRecoveryRequired`; the report may include
only a bounded root-relative location that Core could establish.

The fixed quarantine root may itself have been created even when the candidate
was not moved. `quarantineRootMutation` therefore separately records `none`,
`created`, or `indeterminate`.

## Cancellation

Cancellation before the forward rename produces `notMoved(.cancelled)` when
the kernel can establish that no candidate move occurred. Once rename has
been invoked, cancellation cannot safely short-circuit reconciliation or
rollback. The executing task continues to a bounded report and records
`cancellationWasObservedAfterRename` when cancellation is observed.
Cancellation never rewrites a verified moved result into a false `notMoved`
result.

## Journal, recovery, and report contract

`CleanupQuarantineExecutionReport` contract version 2 is internal,
process-local, `Sendable`, and non-`Codable`. It contains the root-relative
candidate path, rule revision, bounded status, quarantine-root mutation state,
post-rename cancellation flag, and a separate durability state. A reported
location may also retain an observed filesystem identity. A successful status
separately records whether a different object recreated the original source
name. Durability is one of:

- `notRecorded`, before a final intent exists;
- `intentRecorded(transactionID:)`, when the canonical journal has
  authoritative durable intent but no terminal receipt yet;
- `receiptRecorded(transactionID:producedByRecovery:)`, for a validated,
  synchronized terminal receipt; or
- `unresolved(transactionID:)`, when Core cannot safely assert a recoverable
  durable state. A transaction identifier here is diagnostic only.

`isDurablyRecorded` is true only for `receiptRecorded`.
`isCrashRecoverable` is true only for validated `intentRecorded` or
`receiptRecorded`; `unresolved` remains false even when it carries a transaction
identifier. `performedPermanentDeletion` remains unconditionally false.
Crash-recoverable here means restart reconciliation has authoritative evidence
it can safely inspect, preserve, complete, or block; it does not guarantee that
an ambiguous live namespace can automatically produce a receipt.

Before rename, Core durably publishes a canonical intent containing all 16
preplanned destination names. After any possible rename it synchronizes both
namespace parents, then publishes a canonical terminal receipt when the outcome
is conclusive. The journal uses validated exclusive records and `F_FULLFSYNC`;
there is no weaker fallback.

Recovery runs under the journal's validated exclusive lock before a new intent
is admitted. The app's explicit recovery-inventory action can reach the fixed
journal even when `_cacache` is absent; app launch never invokes it. Recovery,
final journal reread/revalidation, and bounded inventory projection remain under
the same lock. Malformed or unresolved journal state, unsafe trusted parents,
and aggregate resource exhaustion fail without a partial list. Individual
missing, changed, unsafe, or per-item over-bound contents remain visible as non-
restorable rows. Recovery observes receipt-less intent state and may publish
only a provable `not-moved` or `quarantined` receipt. It never resumes the forward
rename, automatically rolls back, restores, overwrites, or deletes anything.

A valid final receipt is immutable historical evidence of the transaction and
is never reinterpreted from later live source or destination changes. Current
namespace truth is required for receipt-less intent recovery and for promoting
a canonical receipt stage, where the intent, digest, and terminal namespace
must all agree. The later Core-internal manual restore increment adds a separate
authorization and record family without broadening this quarantine authority;
the source-run app exposes only its bounded receipt-driven facade, while purge
and permanent deletion remain later work. See the exact state machine, record
boundary, synchronization order, and recovery table in the
[quarantine durability contract](DURABILITY.md), plus the
[manual restore contract](RESTORE.md).

## Frontend and privacy boundary

The executor, recovery engine, journal records, claims, and raw report are
internal to `DevSiftCore`. The app cannot construct or consume those values
directly. App view-model state retains the Core-issued review session. After the
UI's independent review and stopped-risk values plus final move confirmation,
the app-local workflow derives the approval, begins the authorization attempt,
constructs Core's requested attestation, and passes only the resulting
authorization to the package-scoped executor. That executor invokes the exact
transaction and projects a bounded result.
Its separate explicit recovery facade returns opaque process-local inventory
references instead of paths, record bytes, or transaction identifiers. The CLI
and public API expose no mutation path. Intent and receipt records are
necessarily persisted inside the private quarantine directory; they are not
logs, exports, uploads, app state, or part of a CLI schema.

The in-memory claim and report contain sensitive raw relative paths, rule and
policy metadata, filesystem identities retained through the claim, and a
quarantine location when one can be established. The durable records also bind
raw paths, filesystem metadata, policy versions, and a transaction identifier.
They are not credentials or authentication. See [DURABILITY.md](DURABILITY.md)
for their local persistence and validation contract.

Quarantine is not storage reclamation: the same-volume rename deallocates no
file data and guarantees exactly 0 B of freed capacity. This contract adds no
purge, permanent deletion, retention, batch or custom-path operation,
networking, telemetry, or distributed app.
