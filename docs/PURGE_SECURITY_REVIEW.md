# Receipt-bound purge focused security and privacy review

Status: completed for the Phase 10 source-run app boundary on 2026-09-07.

This is a repository-internal focused review of DevSift's npm quarantine purge
implementation through commit `c10d814`. It records the acceptance review for
this increment; it is not an independent third-party security audit and does
not certify secure erasure.

## Reviewed boundary

The review covered:

- complete mixed quarantine, restore, and purge journal validation; immutable
  record decoding; bounded inventory; and opaque process-local references;
- distinct initial-purge and explicit-retry confirmations, single-use purge
  authorization, atomic claim consumption, and mutual exclusion with restore;
- passwd-home root discovery, descriptor-held containment, current-account
  ownership, same-device checks, modes, flags, ACL state, historical identity,
  and the bounded canonical npm cache grammar;
- intent-before-staging ordering, exclusive beneath-root rename, staging
  synchronization, descriptor-relative traversal and unlink, cancellation, and
  every conclusive or unresolved namespace state;
- partial-deletion preservation, explicit retry, restore cutoff, terminal
  receipt publication, and observational same-volume capacity reporting; and
- package-scoped facade projection, app workflow isolation, four independent UI
  acknowledgements, stale-result suppression, mandatory post-attempt inventory
  reconciliation, accessibility, and light/dark/minimum-window snapshots.

## Required invariants confirmed

- An initial purge begins only from one Core-issued opaque reference whose
  canonical quarantine intent and final receipt identify one exact quarantined
  item. Callers cannot supply a root, path, item name, journal record, or
  transaction identifier.
- Explicit retry begins only from a fresh opaque retry reference for one
  existing canonical purge intent and its exact staged work tree. It creates no
  second intent and invokes no second staging rename.
- Quarantine, restore, and purge use mutually non-interpretable confirmation and
  authorization families. Each issued purge authorization and every copy share
  one atomic internal-consumption state.
- The active `_cacache` name is never a purge target. The only deletion root is
  the exact receipt-bound item after its validated, synchronized move to the
  intent-bound purge-work name.
- No unlink is attempted before the durable intent, exclusive staging rename,
  held-to-named reconciliation, and required parent synchronization establish a
  committed staging state.
- Traversal remains descriptor-relative and bounded. Symbolic links, hard-linked
  regular files, special files, mount crossings, unsafe ownership or metadata,
  unexpected names, identity changes, malformed records, and exhausted bounds
  fail closed without broadening the target.
- Once staging may have been invoked, cancellation cannot bypass reconciliation
  or safe state reporting. Restore is suspended while staging truth is
  unresolved and becomes permanently unavailable after a validated staging
  commit.
- Only an exact, safely validated and successfully synchronized partial staged
  tree becomes explicit retry work. Unsafe, unavailable, or barrier-failed
  state requires manual recovery. Recovery never resumes unlink automatically,
  and a terminal receipt is published only from conclusive managed-namespace
  truth.
- Core's package projections may expose the fixed responsible tool, fixed
  original name, attempt kind, exact statement, opaque handles, and bounded
  readiness, counts, outcomes, and capacity observations. The app separately
  adds the static remanence disclosure and owns the four local acknowledgement
  states; neither is projected as journal evidence. Neither layer exposes a raw
  path, record bytes, transaction identifier, filesystem identity, or internal
  execution claim.
- Capacity change is an observation that may be zero, negative, or unavailable;
  it is never reported as exact bytes causally reclaimed by DevSift.

## Findings closed during review

1. An `ENOENT` raised while validating the quarantine tree could be mistaken for
   the later, expected observation that the purge-work name was absent. Tree
   validation and work-name observation now have separate error boundaries, and
   a disappearing tree entry rejects before intent or rename.
2. Staging reconciliation originally compared change time across a directory
   rename even though rename can legitimately update it. Reconciliation now
   excludes change time while retaining device, inode, generation, birth time,
   owner, kind, mode, flags, link count, modification time, safe metadata, ACL,
   and held-to-named checks.
3. Initial unlink originally repeated historical mode and flag values from the
   quarantine record after staging. A safe current mode change could therefore
   strand valid work. The executor now relies on the current safe metadata that
   was revalidated immediately before staging and again through the held work
   descriptor; unsafe current metadata still fails closed.
4. The first end-to-end purge fixture exercised the low-level executor but did
   not prove the package-scoped facade wiring. The final fixture now performs
   initial purge and explicit retry through the actual opaque-reference facade
   before asserting exact-tree deletion and active-cache sentinel preservation.
5. Trusted-parent preflight originally compared directory change time,
   modification time, and link count. Unrelated sibling fixture creation under
   `/private/tmp` could therefore produce a false `homeUnsafe` result in the
   parallel suite. Ancestor comparison now requires stable binding, kind,
   owner, mode, and flags while exact npm, quarantine, item, work, and record
   roots retain their strict checks. Deterministic unrelated-child-churn tests
   and five consecutive complete parallel-suite runs cover the correction.
6. Hardened synthetic journal fixtures could leave their UUID-scoped trees
   behind because teardown encountered read-only directories. Teardown now
   closes held descriptors, normalizes only that exact generated tree without
   following symbolic links, retries removal, and records completion only after
   removal succeeds. Repeated post-fix runs created no additional fixture
   directories. Eleven zero-byte pre-fix remnants were validated as generated
   UUID-scoped fixtures and removed by exact path during final cleanup.

No open blocking, high-priority, priority-zero, or priority-one finding remained
at review completion.

## Explicit residual-risk disposition

Darwin does not provide the implementation with an unprivileged primitive that
atomically conditions `unlinkat` on the inode inspected immediately before the
call. Another process running as the same account can race a child-name
replacement. Descriptor-held parents, one-component raw names, no-follow opens,
held-to-named comparisons, grammar checks, ownership checks, and immediate
revalidation narrow the race but cannot eliminate it.

Phase 10 accepts that residual risk only for the manual, fixed npm quarantine
boundary. The app requires a separate acknowledgement that npm and other work
using the cache were stopped, that DevSift did not observe inactivity, and that
same-account activity or post-validation replacement can still occur. Any
requirement for identity-conditioned deletion against a hostile same-UID
process would make this implementation unavailable rather than silently weaken
the contract.

Permanent deletion is also not secure erase. The UI states before authority can
be issued that APFS snapshots or clones, backups, open file descriptors, and
storage-device behavior may retain data or blocks. Capacity accounting can also
be delayed independently, so the separate capacity acknowledgement and result
make no causal reclaimed-byte claim. Automatic, active-cache, arbitrary-path,
custom-root, batch, background, CLI, and public-API deletion remain outside the
accepted boundary.

## Verification evidence

Focused verification at the reviewed snapshot passed:

```shell
swift format lint --recursive --strict Package.swift Sources Tests
swift package describe
swift build --disable-sandbox
swift build -c release --disable-sandbox
swift test --disable-sandbox --filter QuarantinePurgeFacadeTests
swift test --disable-sandbox --filter QuarantinePurgeEndToEndTests
swift test --disable-sandbox --filter QuarantineRecovery
env DEVSIFT_SNAPSHOT_DIR=/private/tmp/devsift-purge-ui.9vawa0 \
  swift test --disable-sandbox --filter VisualSnapshotTests
swift test --disable-sandbox --parallel
git diff --check
```

The focused runs included 7 package-facade tests, 2 real-filesystem end-to-end
tests, 65 `QuarantineRecovery`-filtered tests including 14 app purge workflow
and presentation tests, and the native visual snapshot suite. The complete
parallel suite passed five consecutive times with 771 tests in 73 suites while
the trusted-ancestor race fix was verified. Purge transaction tests used only
uniquely named synthetic `/private/tmp/devsift-journal-tests-*` fixtures; other
filesystem-facing suites use their own UUID-scoped synthetic temporary roots.
No test targets the real account home or cache. The end-to-end tests proved that
initial purge and explicit retry delete only their synthetic staged trees while
an independently created active `_cacache` sentinel survives.

See the [purge contract](PURGE.md), [safety model](SAFETY.md), and
[privacy contract](PRIVACY.md).
