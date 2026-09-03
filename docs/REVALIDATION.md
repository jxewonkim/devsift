# Revalidation contract

`CleanupRevalidator` is the first Phase 7 boundary. It is a read-only,
point-in-time diagnostic over one in-memory `CleanupApproval`; it is neither an
executor nor a cleanup capability.

## Input and scope

The public API accepts only `CleanupApproval`. It takes no separately supplied
root, manifest, diff, app presentation, or CLI review document. The approval's
retained absolute local root is the only scan root, and its reviewed manifest is
the only candidate roster.

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
activity remains uncollected, while other rules retain unknown tool ownership,
protected descendants, and other required facts, so real entries still receive
no eligible result. This is a policy outcome, not a promise that no future
observer can make those facts available.

## Output and failures

`CleanupRevalidationReport` is a non-`Codable`, copyable, in-memory diagnostic.
It omits the absolute root URL and contains only the observed root identity,
current built-in policy provenance, reference time, and canonical per-entry
statuses. It is a point-in-time observation: it grants no filesystem mutation
authority, is not an executor input, and may become stale immediately after it
is returned.

Public failures are deliberately reduced to stable categories: invalid approval
invariants, unsupported policy, scan or scan-report failure, changed root,
classification or classification-report failure, source-binding failure, and a
fail-closed planning invariant. Dependency-specific errors do not cross this
boundary. Cancellation is cooperative: checks occur at phase boundaries and
while bounded entry work is processed, but an in-progress scanner or classifier
operation may finish before its next checkpoint. Cancellation returns no partial
report.

## Execution remains later

This contract does not close time-of-check/time-of-use gaps. A future executor
must accept the `CleanupApproval`, not this report, and revalidate each item
inline while holding verified descriptors immediately before a recoverable
operation. That executor must independently establish containment, kind,
identity, device, activity, and current policy evidence; it must not treat this
report as a capability or proof that a later path lookup is safe.

Activity is the final npm eligibility fact, so its observer and the future
executor's immediate, descriptor-held revalidation can be designed as one
coordinated safety boundary.
