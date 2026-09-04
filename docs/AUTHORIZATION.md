# Quarantine attempt authorization contract

`CleanupQuarantineAuthorizer` is the Core-only, in-memory boundary that binds
one exact `CleanupApproval` to one explicit caller assertion for one future
recoverable-quarantine attempt. `CleanupQuarantineAuthorization` contract
version 1 is implemented, but no executor, quarantine, receipt, recovery,
restore, purge, deletion, app action, or CLI action exists.

Authorization is not filesystem access. The public contract performs no scan,
process inspection, npm invocation, clock read, network request, or filesystem
I/O. In particular, `grantsStandaloneFilesystemMutationAuthority == false`.
A future executor must
use the internal single-use handoff and still revalidate every filesystem fact
descriptor-relatively immediately before an operation.

## Four distinct meanings

| Value | What it records | What it does not establish |
| --- | --- | --- |
| `CleanupApprovalPreconditionReviewAcknowledgement` | A pending condition and its risk were included in approval review. | It is copyable, replayable review intent—not an assertion that npm stopped, freshness, or authority. |
| `CleanupQuarantineUserAttestation` | The caller explicitly supplies the required statement for one exact authorization attempt and its complete canonical subject set. | It is not observed inactivity, proof that a human acted or understood, caller authentication, or standalone mutation authority. |
| `CleanupQuarantineAuthorization` | The exact approval and accepted attempt-scoped assertion passed the version-1 authorization policy, and one internal executor handoff may be attempted. | It is not a filesystem capability, a safety verdict, proof that npm remains stopped, or permission for permanent deletion. |
| Internal executor claim | One internal consumer atomically obtains the retained approval and attestation. | The claim itself performs no I/O; no public consumer, executor, inline filesystem check, or mutation exists. |

The names are intentionally not interchangeable. Approval review
acknowledgement must never be presented as the separate attestation. The caller's
attestation must never be described as activity DevSift observed. Issuing an
authorization must never be described as making a path safe or mutating it.

## Supported policy

The public default `CleanupQuarantineAuthorizer()` is deliberately narrow. It
first applies canonical approval validation against the current built-in
provenance. Authorization contract version 1 then independently pins
`devsift.classification.explainable@3` and `devsift.builtin-rules@6`; drift in
either marker fails as the typed `unsupportedApprovalPolicy` result even if a
future built-in default changes. Every pending subject is then directly pinned
to:

- rule `devsift.cache.npm` revision 5;
- responsible tool `npm`;
- precondition
  `requires-user-attestation-that-responsible-tool-is-stopped` policy revision
  1; and
- statement
  `CleanupQuarantineAttestationStatement.responsibleToolStoppedAndUnobservedActivityRiskAccepted`,
  raw value
  `responsible-tool-stopped-and-unobserved-activity-risk-accepted`, policy
  revision 1.

An approval without a pending execution precondition is not an authorization
candidate. A malformed approval fails as `invalidApproval`; unsupported or
drifted approval provenance fails as `unsupportedApprovalPolicy`. A changed
rule, responsible-tool string, precondition, precondition policy revision,
statement policy revision, or mixed attestation requirement fails as
`unsupportedAttestationRequirements`. The authorizer does not silently drop,
sort, translate, or broaden a pending requirement.

## Attempt creation and attestation

`CleanupQuarantineAuthorizer.beginAttempt(for:)` validates and retains the
exact `CleanupApproval` inside a new process-local attempt. Callers cannot
substitute a root, manifest, revalidation report, review projection, or a
second approval after the attempt begins.

The returned `CleanupQuarantineAuthorizationSession` exposes one
`CleanupQuarantineAttestationRequest`. Its `subjects` are the complete
canonical pending set from the retained approval. Each subject contains its
canonical ordinal, exact raw relative path, rule revision, responsible tool,
and deferred precondition. One required statement covers that entire set; the
contract does not turn each earlier review acknowledgement into an
attestation.

The caller explicitly constructs `CleanupQuarantineUserAttestation` with that
exact request and its `requiredStatement`, then calls
`session.authorize(using:)`. This is a caller assertion that the responsible
tool was stopped for the listed subjects and that the unobserved-activity risk
was accepted. DevSift still reports activity as
`unknown(.notCollected)`: it did not observe inactivity, cannot prevent a new
access, and cannot authenticate who supplied the value.

Future user-facing wording must convey both parts without making a safety
claim. The intended meaning is: “I stopped npm work that may use every listed
cache, and I understand DevSift did not observe npm inactivity and another
process may access the cache.” There is currently no UI or CLI surface that
asks for or constructs this assertion.

## Process-local freshness and lifecycle

Freshness is structural, not elapsed time. The request, attestation, session,
and authorization share an opaque process-local attempt identity. A
same-looking request or attestation from another attempt or approval is not
substitutable. The contract reads no clock, stores no timestamp, and applies no
wall-clock TTL.

One shared actor owns the attempt state across every value copy:

```text
open --authorize once--> issued --internal consume once--> consumed
  \---------------------- cancel -------------------------> cancelled
```

- Concurrent or repeated authorization issuance for one attempt permits one
  success at most.
- Every copy of the issued authorization shares one atomic internal-consumption
  state, so only one internal handoff can succeed in total.
- Cancellation of an open or issued attempt is irreversible, releases retained
  state, and makes later issuance or consumption fail. Cancellation cannot undo
  a handoff that already consumed the authorization.
- A cross-attempt attestation or statement mismatch leaves an open session
  available for one correct retry. Cancellation and consumption are terminal;
  issuance also prevents any second authorization. Waiting never refreshes or
  reopens those states, so a new attempt is required when another assertion or
  authorization is needed.

The public package intentionally exposes no consume method or execution claim.
`consumeForExecution()` and `CleanupQuarantineExecutionClaim` are internal,
reserved for a future descriptor-held executor.

## Authorization properties and limits

Every valid version-1 `CleanupQuarantineAuthorization` reports:

- `isSingleUse == true`;
- `authorizesRecoverableQuarantineOnly == true`;
- `authorizesPermanentDeletion == false`;
- `requiresInlineFilesystemRevalidation == true`;
- `grantsStandaloneFilesystemMutationAuthority == false`; and
- `usesWallClockFreshness == false`.

Those properties describe the boundary, not an implemented operation. The
authorization neither consumes `CleanupRevalidationReport` nor turns one into
authority. A future executor must consume only the internal authorization
handoff, reopen the approval-bound root, and establish current containment,
kind, device, identity, rule, activity policy, descendant, ownership, and
quarantine-destination facts while verified descriptors remain held.

The scope is recoverable quarantine only. Permanent deletion and purge require
a later, separate policy and authorization design even after quarantine,
receipt, recovery, and restore exist.

## Privacy, persistence, and failures

The request and subjects repeat exact root-relative paths, rule identity,
responsible-tool attribution, and policy metadata. The attempt also retains the
approval, including its absolute root and manifest, until cancellation or
internal consumption. These values are sensitive even though they are
in-memory and non-`Codable`.

No authorization value is persisted, imported, exported, logged, uploaded, or
included in any CLI JSON schema. Process-local identity is not encryption,
authentication, a secret, or proof of human intent. Callers must discard all
copies with the analysis session.

`CleanupQuarantineAuthorizationError` exposes only bounded domain cases:

- `invalidApproval(CleanupApprovalInvariant)`;
- `unsupportedApprovalPolicy`;
- `noPendingExecutionPreconditions`;
- `unsupportedAttestationRequirements`;
- `attestationDoesNotBelongToAttempt`;
- `attestationStatementMismatch`;
- `attemptAlreadyAuthorized`; and
- `attemptCancelled`.

Observed task cancellation can instead throw `CancellationError`.
`beginAttempt(for:)` then creates no session; cancellation while authorizing
clears the retained attempt state and returns no partial authorization.

## Version boundary

Authorization is contract version 1. Existing contracts remain unchanged:
explainable classification 3, cleanup manifest 3, manifest diff 2, approval 2,
revalidation 2, built-in catalog 6, npm rule 5, scan JSON 2, classification JSON
2, and internal manifest-review JSON 2 over source manifest 3.

The authorization contract has no wire format or migration path. If any
supported rule, responsible-tool identity, precondition policy, statement
policy, lifecycle, or handoff semantic changes, advance the appropriate
contract and regenerate the approval and attempt rather than adapting an old
value.
