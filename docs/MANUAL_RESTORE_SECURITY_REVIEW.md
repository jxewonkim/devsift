# Manual restore focused security review

Status: completed for the eleventh Phase 7 increment on 2026-09-04.

This is a repository-internal focused review of the Core-only npm manual
restore implementation. It records the acceptance review performed for this
increment; it is not an independent third-party security audit.

## Reviewed boundary

The review covered:

- canonical quarantine and restore record decoding, digests, policy revisions,
  inventory bounds, and mixed pending-intent admission;
- process-local confirmation, single-use authorization, claim consumption, and
  the absence of a public, app, or CLI restore entry point;
- passwd-home root discovery, descriptor-held containment, ownership, device,
  mode, flags, ACL, item identity, and bounded cacache-tree validation;
- durable intent publication, required `F_FULLFSYNC` barriers, the single
  exclusive reverse rename, namespace reconciliation, and receipt publication;
- cancellation before intent, between intent and rename, and after the rename
  linearization point; and
- observational interrupted-restore recovery, receipt-stage promotion, and
  ambiguous-state preservation.

## Required invariants confirmed

- A caller supplies only a canonical quarantine transaction identifier. Core
  derives the receipt-selected item, fixed `_cacache` destination, and fresh
  restore transaction identifier.
- The complete current tree is validated before durable restore-intent
  admission and again after intent publication. Immediately before mutation,
  the final source-absence observation is followed only by the test hook,
  cancellation check, and one `renameatx_np` call.
- The rename uses `RENAME_EXCL`, `RENAME_NOFOLLOW_ANY`, and
  `RENAME_RESOLVE_BENEATH`. No overwrite, copy, link, unlink, removal, rollback,
  or path-based fallback exists in the restore executor.
- Once rename may have been invoked, cancellation cannot skip reconciliation,
  namespace barriers, or safe terminal-receipt publication.
- Recovery observes namespace truth and may finish a conclusive receipt. It
  never invokes or retries the reverse rename and preserves ambiguous state.
- Quarantine and restore share one validated journal lock and permit at most one
  receipt-less mutation intent across both operation types.
- At the reviewed Phase 7 snapshot, all restore domain values and execution
  entry points remained internal and non-`Codable`; the app and CLI were
  read-only.

## Findings closed during review

1. Restore recovery originally compared historical parent permission modes and
   link counts as immutable identity. Safe current mode tightening could leave
   an otherwise valid pending restore permanently unresolved. Restore paths now
   pin stable historical identity, kind, and owner while independently enforcing
   current safe mode, flags, ACL, containment, and held-to-named equality.
2. The same over-strict historical comparison remained on the quarantined item
   in preflight and in the post-open journal observation. Those gates now use
   the same stable-history/current-safety split. Quarantine's forward-move paths
   retain their stricter original comparisons.
3. Full current-tree validation was required both before intent admission and
   after publication. The journal admission and restorer now enforce that
   order, and an unsafe tree is regression-tested to publish neither a staged
   nor final restore intent.
4. Restore tree layout mismatches were initially reported as generic change.
   They now map to the bounded unsafe-item result consistently across journal
   and executor layers.

No open priority-zero or priority-one finding remained at review completion.

## Verification evidence

The reviewed snapshot passed:

```shell
swift format lint --recursive --strict Package.swift Sources Tests
swift build
swift test
git diff --check
```

The full suite reported 544 passing tests in 49 suites. Restore-focused tests
cover canonical success, non-overwrite collision, current safe metadata drift,
unsafe-tree rejection before intent, mutation races, cancellation on both sides
of rename, durability failures, every recovery truth-table branch, and
ambiguous-state preservation using synthetic temporary fixtures only.

The later Phase 9 package-scoped app inventory and restore surface was outside
this historical review and is a separate frontend review boundary. Public or
CLI mutation, automatic app-launch recovery, custom root, batch operation,
purge, record retention, and permanent deletion remain additional new review
boundaries. See the [manual restore contract](RESTORE.md) and
[safety model](SAFETY.md).
