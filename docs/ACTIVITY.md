# Activity safety contract

This document records DevSift's current capability boundary for deciding
whether an npm content cache is active. It is a safety decision, not an
implementation of process monitoring or cleanup.

## Current decision

The unprivileged DevSift app and CLI do not have a supported macOS capability
that can both:

1. establish the absence of active use throughout an `_cacache` subtree; and
2. prevent a new use from starting before a later filesystem operation.

DevSift therefore does not produce `RuleObserved.known(.inactive)` from an
empty process query, a quiet metadata interval, or successful acquisition of
an advisory lock. Runtime npm activity remains literally
`unknown(.notCollected)`.

DevSift has selected policy option 2 below only for a future recoverable npm
quarantine attempt. When every non-deferred npm finding is satisfied, the
classifier applies
`RuleActivityRequirement.mustBeInactiveOrDeferToAttestationWhenUnobserved` and
may return `matched` / `review-required` while preserving the unknown activity
finding and adding
`RuleDeferredExecutionPrecondition.requiresUserAttestationThatResponsibleToolIsStopped`
with raw value
`requires-user-attestation-that-responsible-tool-is-stopped` and
`policyRevision == 1`. Text surfaces render that pair as
`requires-user-attestation-that-responsible-tool-is-stopped@1`. This is a
policy deferral, not an observation that npm is inactive. Known active use, any
other unknown reason, or any other blocking finding remains Protected.

The current milestone only propagates that pending condition through
classification, planning, review, approval, and revalidation. Approval binds a
review acknowledgement that the condition and its risk were reviewed. That
copyable, replayable review intent does not collect the user's statement that
npm stopped, establish freshness, or authorize an operation. There is still no
executor or filesystem mutation API.

This conclusion is scoped to the current local, unprivileged, dependency-free
product. It is not a claim that macOS has no privileged security mechanism.

## Capability review

| Candidate signal | What it can establish | Why it cannot prove inactivity |
| --- | --- | --- |
| `flock` or `fcntl` lock | No cooperating process held a conflicting advisory lock at that instant. | Darwin file locks are advisory, and [cacache explicitly supports lockless, high-concurrency access](https://github.com/npm/cacache/blob/6e8eb4d7e82694149c34fbb0fbe5441628fc1703/README.md). npm does not participate in a DevSift lock. See Apple's [`flock(2)`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/flock.2.html) and [`fcntl(2)`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fcntl.2.html) documentation. |
| Repeated metadata scans | No observed inode metadata changed between bounded samples. | An open or read need not change any sampled field, a paused writer can resume, and a new access can begin after the final sample. A quiet interval is historical observation, not a lease. |
| `kqueue` / `EVFILT_VNODE` | Selected vnode changes such as write, rename, delete, link, or attribute changes. | It does not report general open, read, or close activity, and the [kernel-queue guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/KernelQueues/KernelQueues.html) requires an open descriptor for every watched file. It cannot cover an unbounded changing subtree atomically. |
| FSEvents | Asynchronous filesystem-change notifications beneath watched directories. | Default streams are directory-level and latency-coalesced; [file-level events can be requested](https://developer.apple.com/documentation/coreservices/kfseventstreamcreateflagfileevents), but FSEvents still is not an open, read, or close gate or a complete current-use snapshot. Apple's guide also requires clients to handle [coalesced or dropped events by rescanning](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html). |
| `libproc` process/vnode queries | A positive match can reveal a process reference to one exact vnode. | Apple's [`libproc.h`](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.h) labels these interfaces private and subject to change. [`proc_listpidspath`](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/proc_listpidspath.c) starts with `stat(path)`, matches an exact device/inode unless asked for an entire volume, races PID/FD/thread/region enumeration, and treats per-process inspection errors as nonmatches. Zero matches are not an exhaustive subtree-wide negative proof. |
| Endpoint Security | A full-system privileged client can observe or authorize subscribed system events. | [`es_new_client`](https://developer.apple.com/documentation/endpointsecurity/es_new_client(_:_:)) requires an Apple-approved [restricted entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.endpoint-security.client), root execution, and user-granted Full Disk Access. Apple recommends a system extension, but also documents [an entitled daemon deployment](https://developer.apple.com/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement). Either path introduces a materially different privacy, installation, and distribution model and is outside the current product scope. |

The boundary follows from the combined limitations above. A single positive
observation may be useful as an additional reason to protect a candidate, but
absence of that observation cannot satisfy the activity requirement.

## Hard invariants

- A positive-only conflict detector may return `active` only from concrete,
  identity-bound evidence. No match, partial enumeration, permission denial,
  unsupported APIs, PID or descriptor churn, cancellation, and every resource
  bound remain unknown.
- `active` may safely outrank a simultaneous unknown because both outcomes
  protect the candidate. Unknown must never be collapsed into `inactive`.
- Process names, arguments, executable paths, PIDs, and open-file paths are not
  current classification output and must not be logged, persisted, or exposed
  merely to add a conflict detector.
- A classification or revalidation result is a point-in-time diagnostic. It is
  never a capability, lease, approval, or executor input.
- A deferred execution precondition is policy metadata, not evidence. Its
  presence must never change `unknown(.notCollected)` into `inactive`.
- Acknowledging a deferred precondition for review during approval means only
  “this condition and risk were included in review.” It must not be labeled or
  accepted as the later attempt-scoped attestation.
- Atomic rename protects the binding of an operation; it does not prove that a
  tool was inactive and must not be described as doing so.

## Selected policy for future recoverable quarantine

The project has narrowly adopted the second of the three reviewed policy paths:

1. **Privileged authorization gate.** Design an Endpoint Security client and
   obtain the restricted entitlement, with a new threat model, privacy
   contract, privileged installation model, and explicit handling for
   references opened before subscription, the complete relevant event set,
   authorization deadlines and default behavior, result caching, queue or
   sequence gaps, and startup and teardown gaps. A system extension is the
   recommended deployment model; an entitled daemon is another documented
   route. Endpoint Security must not be treated as sufficient until this design
   proves that both pre-existing use and new access are covered.
2. **Explicitly accepted recoverable-operation risk — selected, narrowly.**
   Replace automatic inactivity proof with a fresh, attempt-scoped user
   statement that they stopped npm work that may use the cache. The statement
   must also disclose that DevSift did not observe inactivity and that another
   process may access the cache. A positive conflict still blocks; an
   exclusive, same-volume quarantine move, durable restore metadata, and best-
   effort non-overwriting rollback may limit consequences but cannot prevent
   tool disruption. This policy applies only to future recoverable quarantine,
   never purge or permanent deletion.
3. **Cooperative upstream lock.** Remain protected until npm/cacache exposes a
   stable lock or lease that covers the operation and DevSift can participate
   without invoking npm or modifying the cache during classification.

Options 1 and 3 remain unimplemented alternatives rather than current product
claims. Selecting option 2 does not add an attestation UI or operation in this
milestone.

A later phase must introduce `CleanupQuarantineAuthorization` as the only
executor input. It must bind one exact `CleanupApproval`, a fresh explicit user
attestation captured for that exact quarantine attempt, and process-local
single-attempt identity and consumption. It must not accept a review-time
precondition review acknowledgement as the attestation, permit serialization
or replay, or infer freshness from a wall-clock TTL. “Fresh” means created and
consumed inside the same bounded attempt flow, not “younger than N seconds.”

## Future executor boundary

Under the selected narrow policy, a future executor must:

- accept only `CleanupQuarantineAuthorization`, never a bare
  `CleanupApproval`, `CleanupRevalidationReport`, caller-supplied root,
  standalone manifest, diff, precondition review acknowledgement, or
  presentation;
- reopen the approval's root and candidate descriptor-relatively without
  following links, and revalidate identity, containment, kind, device,
  ownership, descendant grammar, rule revision, policy provenance, and the
  selected activity policy while descriptors remain held;
- open and validate a trusted quarantine parent whose containment, device,
  identity, ownership, permissions, and no-follow traversal remain stable;
  choose a bounded valid leaf that is absent, then let an exclusive descriptor-
  relative rename such as `renameatx_np` with `RENAME_EXCL` atomically claim
  it, retrying collisions only within a fixed bound and only after separately
  validating every required runtime flag and volume capability;
- after the rename linearizes, finish destination validation and durable
  outcome recording even if cancellation arrives; cancellation may stop only
  before the rename or between entries;
- write and sync crash-consistent quarantine metadata sufficient for restore
  before reporting completion;
- attempt rollback only when both parent bindings remain stable, the source
  name is absent, the destination still names the held candidate, and an
  exclusive reverse rename succeeds; never overwrite a newly recreated source,
  and report manual recovery when those conditions do not hold;
- report completed, skipped, changed, rollback-required, and failed entries
  individually; and
- provide restore before any separately reviewed permanent purge.

The operation and its immediate revalidation must share one non-escaping
descriptor-held scope. Returning a Boolean and performing the rename later is
not an acceptable implementation.

## Test gate

Any future activity or executor implementation requires synthetic adversarial
tests for positive-use detection, negative-result fail-closure, permissions,
PID and descriptor churn, enumeration limits, pre-existing references, event
coverage and gaps, cancellation before and after the rename linearization
point, source and destination swaps, symlinks, mount boundaries, rename
collision, concurrent source recreation, post-move validation, crash-consistent
receipt recovery, non-overwriting rollback, partial failure reporting,
attestation substitution, cross-attempt replay, double consumption, and
fixture-boundary integrity.

Tests must not inspect a contributor's live process table or real cache as an
oracle. Runtime process inspection, if ever selected, needs injected system-
call fixtures and an explicit privacy review.

## Versioning effect

This decision adds policy behavior but no runtime activity evidence. The
explainable-classification contract is revision 3, npm is rule revision 5, and
the built-in catalog is version 6. Cleanup manifest is version 3, manifest diff
is version 2, approval is version 2, and revalidation is version 2. Scan JSON
remains version 2; classification JSON and internal manifest-review JSON are
version 2, with the latter pinned to source manifest version 3.

Older manifests, approvals, and exports are regenerated rather than migrated;
there is no import path. Executor, quarantine, restore, purge, and deletion
remain unimplemented.
