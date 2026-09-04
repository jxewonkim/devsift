# Revalidation contract

`CleanupRevalidator` contract version 2 is the first Phase 7 boundary. It is a
read-only, point-in-time diagnostic over one in-memory `CleanupApproval`; it is
neither an executor nor a cleanup capability.

## Input and scope

The public API accepts only `CleanupApproval`. It takes no separately supplied
root, manifest, diff, app presentation, or CLI review document. The approval's
retained absolute local root is the only scan root, and its reviewed manifest is
the only candidate roster.

Preflight requires approval contract version 2, cleanup manifest contract
version 3, and the exact canonical precondition-review-acknowledgement sequence
retained by the approval. Each acknowledgement establishes only that a pending
condition and its risk were reviewed. It is not an activity attestation and
cannot be substituted for the separate attempt authorization assertion. Older
approval or manifest values must be regenerated; there is no import migration.

The default revalidator performs a new allocated-size scan and a new built-in
explainable classification using that retained root. It accepts only the
current built-in policy provenance; custom, changed, or otherwise unsupported
policy provenance fails closed. It performs no persistence, network I/O,
filesystem mutation, quarantine, restore, purge, frontend action, or CLI
command.

## What is checked

Before scanning, the revalidator validates the approval and its complete,
canonical manifest under bounded limits. It then requires the newly observed
root identity to equal the manifest's expected root identity. An invalid,
incomplete, or different-root observation does not produce an eligible entry.

For each approved entry, results remain in the approval manifest's canonical
order. The revalidator reobserves its exact raw relative path, directory kind,
device, file identity, rule revision, findings, disposition, and full current
policy decision. A missing path, ambiguous path, kind or identity change,
changed rule, blocking finding, or policy mismatch is reported as a per-entry
rejection. A cross-volume traversal or any other incomplete source scan rejects
every approved entry as `sourceObservationIncomplete` rather than assuming that
an unobserved value is safe.

The current built-in runtime evidence deliberately remains conservative. Exact
default uv, npm, and Homebrew containers may satisfy trusted location after a
descriptor-bound root check. An npm `_cacache` may also satisfy its supported
cacache-layout marker and the distinct `account-owned-cache-namespace` check
when both the held selected root and held candidate have the current account's
exact POSIX UID. That check replaces generic tool ownership only for npm and
does not prove historical creation, write ACLs, content, inactivity, or
mutation authority. The same exact npm candidate may also satisfy bounded
protected-descendant evidence after a stable descriptor-relative traversal
matches the pinned cacache path-and-kind grammar and the earlier scan. npm
activity remains literally `unknown(.notCollected)`. When that is the sole
deferred finding and the fresh policy exactly matches the approved manifest,
the entry receives
`awaitingExecutionPreconditions([.requiresUserAttestationThatResponsibleToolIsStopped])`.
It does
not receive `eligibleAtObservation`, and the status does not say that npm is
inactive. Other rules retain unknown tool ownership, protected descendants, and
other required facts. This is a policy outcome, not a promise that no future
observer can make those facts available.

A fresh known-active result or activity `unknown(.permissionDenied)` is
`.rejected(.blockingFinding(activity-requirement))`. That concrete blocking
diagnosis takes precedence over reporting a mismatch between the approved and
fresh pending-condition sets; an absent fresh deferral must not hide active or
denied activity behind a generic policy-change result.

## Output and failures

`CleanupRevalidationReport` is a non-`Codable`, copyable, in-memory diagnostic.
It omits the absolute root URL and contains only the observed root identity,
current built-in policy provenance, reference time, and canonical per-entry
statuses. It is a point-in-time observation: it grants no filesystem mutation
authority, is not an executor input, and may become stale immediately after it
is returned.

`eligibleAtObservation` means no precondition was pending at that observation.
`awaitingExecutionPreconditions` means no non-deferred rejection was found but
one or more exact versioned conditions remain unresolved.
`hasPendingExecutionPreconditions` reports that state; it is deliberately not
“ready to execute.”

Public failures are deliberately reduced to stable categories: invalid approval
invariants, unsupported policy, scan or scan-report failure, changed root,
classification or classification-report failure, source-binding failure, and a
fail-closed planning invariant. Dependency-specific errors do not cross this
boundary. Cancellation is cooperative: checks occur at phase boundaries and
while bounded entry work is processed, but an in-progress scanner or classifier
operation may finish before its next checkpoint. Cancellation returns no partial
report.

## Authorization is separate; execution remains later

This contract does not close time-of-check/time-of-use gaps. A later phase must
still implement the executor, but Core now creates an in-memory authorization
attempt separately from revalidation. `CleanupQuarantineAuthorizer` accepts the
exact `CleanupApproval`, not this report, and exposes one canonical request for
an explicit caller assertion over the complete npm pending set. A precondition
review acknowledgement is not that assertion. The attestation is not observed
inactivity, proof of human action, or authentication.

The authorization attempt uses process-local identity rather than a clock or
TTL. Issuance succeeds at most once, and all authorization copies share one
atomic internal handoff. Cancellation is terminal. Authorization contract
version 1 is recoverable-quarantine-only, requires inline filesystem
revalidation, and grants no standalone mutation authority. The public API has
no consumer or executor. See the [authorization contract](AUTHORIZATION.md).

A future executor must enter only through that authorization's internal
handoff, not a bare approval or this report, and revalidate each item inline
while holding verified descriptors immediately before a recoverable operation.
It must independently establish
containment, kind, identity, device, the selected activity policy, and current
policy evidence; it must not treat this report as a capability or proof that a
later path lookup is safe.

Activity is the remaining npm execution fact. The
[activity safety contract](ACTIVITY.md) establishes that the current
unprivileged product has no supported primitive for proving subtree-wide
inactivity or preventing access after a check. Revalidation therefore keeps npm
activity unknown and cannot emit execution authority. The selected narrow
recoverable-quarantine policy can now bind an explicit attempt assertion
without changing that observation. The authorization remains only an in-memory,
single-use handoff boundary; immediate descriptor-held revalidation by a future
executor remains mandatory.
