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

DevSift has selected policy option 2 below only for recoverable npm quarantine
attempts. When every non-deferred npm finding is satisfied, the
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

Approval still binds only a review acknowledgement that the condition and its
risk were reviewed. That copyable, replayable review intent is not the separate
attempt attestation. Core now exposes a process-local authorization attempt;
its `CleanupQuarantineUserAttestation` is an explicit caller assertion for one
exact canonical pending set, not activity evidence, human proof, or
authentication. The resulting single-use authorization grants no standalone
mutation authority. A Core-internal npm-only executor now consumes it for one
descriptor-held atomic quarantine move; no public or frontend mutation API
exists. See the [authorization contract](AUTHORIZATION.md) and
[quarantine execution contract](QUARANTINE.md).

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
  accepted as the separate attempt-scoped attestation.
- `CleanupQuarantineUserAttestation` is an explicit caller assertion for one
  exact attempt, not an observation that npm is inactive, proof that a human
  acted or understood, or caller authentication.
- `CleanupQuarantineAuthorization` is process-local and single-use, but it is
  not a filesystem capability or safety verdict and grants no standalone
  mutation authority.
- Atomic rename protects the binding of an operation; it does not prove that a
  tool was inactive and must not be described as doing so.

## Selected policy for recoverable quarantine

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
   tool disruption. This policy applies only to recoverable quarantine, never
   purge or permanent deletion.
3. **Cooperative upstream lock.** Remain protected until npm/cacache exposes a
   stable lock or lease that covers the operation and DevSift can participate
   without invoking npm or modifying the cache during classification.

Options 1 and 3 remain unimplemented alternatives rather than current product
claims. Implementing its Core authorization boundary adds no user-facing
attestation UI or filesystem operation.

`CleanupQuarantineAuthorizer.beginAttempt(for:)` now retains one exact
`CleanupApproval` and issues a request for one explicit assertion covering its
complete canonical pending set. The request, attestation, authorization, and
shared lifecycle carry process-local attempt identity. Cross-attempt replay
fails, authorization issuance succeeds at most once, and every authorization
copy shares one internal consumption state. No value is serialized, and no
wall-clock TTL supplies freshness. “Fresh” means bound to this newly begun
attempt, not “younger than N seconds.”

The required statement is
`responsibleToolStoppedAndUnobservedActivityRiskAccepted` at policy revision 1.
Supplying it is the caller's assertion that npm work was stopped and the
unobserved-activity risk was accepted. It does not change
`unknown(.notCollected)`, prove who supplied it, or prevent a new access. The
public API exposes no consume method; its only handoff is consumed by the
internal executor described below.

## Current internal executor boundary

Under the selected narrow policy, the current executor must:

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
  generate a bounded valid leaf, then require its absence atomically through a
  descriptor-relative rename such as `renameatx_np` with `RENAME_EXCL`, retrying
  collisions only within a fixed bound and only after separately validating
  every required runtime flag and volume capability;
- after the rename is invoked, finish source and destination reconciliation
  even if cancellation arrives, and record late cancellation in its report;
- attempt rollback only when both parent bindings remain stable, the source
  name is absent, the destination still names the held candidate, and an
  exclusive reverse rename succeeds; never overwrite a newly recreated source,
  and report manual recovery when those conditions do not hold;
- durably publish a canonical intent before rename, synchronize both namespace
  parents after any possible rename, and publish an immutable terminal receipt
  only for a conclusive not-moved, quarantined, or rolled-back outcome; and
- report bounded not-moved, quarantined, rolled-back, or manual-recovery-required
  outcomes with a separate contract-version-2 durability state.

The internal journal and recovery engine now reconcile receipt-less intents
without resuming, reversing, restoring, overwriting, or deleting the authorized
object. A root-only recovery entry point exists when `_cacache` is absent, but
automatic app-launch recovery and all frontend execution remain unwired. Restore
must exist before any separately reviewed permanent purge.

The operation and its immediate revalidation must share one non-escaping
descriptor-held scope. Returning a Boolean and performing the rename later is
not an acceptable implementation.

## Test gate

Current authorization tests use synthetic approvals and cover complete
canonical subjects, unsupported policy, the exact required statement policy,
attestation substitution, cross-attempt replay, concurrent issuance, shared-
copy double consumption, terminal cancellation, and fixture-boundary integrity.
Any future activity observer, public activation, or further recovery surface
still requires adversarial tests for
positive-use detection, negative-result fail-closure, permissions, PID and
descriptor churn, enumeration limits, pre-existing references, event coverage
and gaps,
cancellation before and after the rename linearization point, source and
destination swaps, symlinks, mount boundaries, rename collision, concurrent
source recreation, post-move validation, crash-consistent receipt recovery,
non-overwriting rollback, and partial failure reporting.

Tests must not inspect a contributor's live process table or real cache as an
oracle. Runtime process inspection, if ever selected, needs injected system-
call fixtures and an explicit privacy review.

## Versioning effect

This decision adds policy behavior but no runtime activity evidence. The
explainable-classification contract is revision 3, npm is rule revision 5, and
the built-in catalog is version 6. Cleanup manifest is version 3, manifest diff
is version 2, approval is version 2, revalidation is version 2, and quarantine
authorization is version 1 while the internal execution report is version 2.
Scan JSON remains version 2; classification JSON
and internal manifest-review JSON are version 2, with the latter pinned to
source manifest version 3.

Older manifests, approvals, and exports are regenerated rather than migrated;
there is no import path. The executor, atomic quarantine kernel, journal, and
recovery engine are internal. Restore, purge, deletion, public API, frontend
actions, and automatic app-launch recovery remain unimplemented.
