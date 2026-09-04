# Development plan

This document defines the implementation order for DevSift. Each phase ends in
a buildable, tested commit that is pushed to GitHub. `main` remains releasable;
feature work is developed on short-lived branches and merged through pull
requests once repository automation is available.

## Phase 0: foundation

Commit: `docs: establish DevSift scope and safety model`

- Define product goals and non-goals.
- Publish the safety and privacy contracts.
- Document architecture and contribution rules.
- Adopt Apache-2.0 and a changelog.

Gate: links resolve, terminology is consistent, no real machine paths or scan
data are present, and the repository contains no secrets.

## Phase 1: Swift workspace

Commit: `chore: bootstrap Swift workspace and CI`

- Add `DevSiftCore`, `devsift`, and a minimal SwiftUI app surface.
- Add unit-test targets and formatting checks.
- Add GitHub Actions for build and tests.
- Keep the core free of third-party runtime dependencies.

Gate: package description, formatting, build, and tests pass locally and in CI.

## Phase 2: read-only scanner

Status: implemented in DevSiftCore; CLI and app integration remain separate
phases.

Commit: `feat(core): add a read-only allocated-size scanner`

- Enumerate only an explicit root.
- Measure logical and allocated bytes.
- Return structured partial errors instead of hiding them.
- Support cancellation and deterministic result ordering.
- Do not follow symlinks.

Gate: synthetic tests cover empty and nested trees, sparse data where reliable,
missing and unreadable paths, cancellation, symlink escape attempts, Unicode,
and spaces. Nothing outside a temporary fixture changes.

## Phase 3: scan CLI

Status: implemented with dependency-free argument parsing, root-relative text
and JSON output, stable exit codes, and synthetic subprocess tests.

Commit: `feat(cli): expose read-only scans as text and JSON`

- Add `devsift scan <path>`.
- Add human-readable and versioned JSON formats.
- Document exit codes and stderr behavior.
- Add integration tests over synthetic fixtures.

Gate: output is deterministic, JSON round-trips, error exit codes are tested,
and no cleanup command exists.

## Phase 4: scan app

Status: implemented with explicit folder selection, an indeterminate scan
activity state, cancellation, rescan, and complete or partial result views.

Commit: `feat(app): add a read-only storage scan dashboard`

- Add explicit folder selection, honest indeterminate activity, cancellation,
  and result views.
- Display that the current release is analysis-only.
- Cover the view model with unit tests.
- Check basic keyboard, VoiceOver, light-mode, and dark-mode behavior.

Gate: the app builds without signing in CI and invokes DevSiftCore rather than a
duplicate scanner. Synthetic tests cover empty, scanning, complete, partial,
cancelled, failed, rescan, stale-result, and Core-integration behavior. Native
1200 x 760 light and dark render snapshots are available as an opt-in local QA
harness.

Implementation milestone reached at that phase: scan-only app and CLI. The
first tag was deferred; the current `v0.1.0-alpha.1` target also includes the
Phase 5 classification surface.

## Phase 5: explainable rules

Status: implemented as a conservative classification foundation. Built-in
rules can recognize exact raw path shapes and explain every missing or
failed check. A descriptor-relative increment now retains a conservative newest
observed inode modification time per summary and projects it into age findings
for complete items. Summaries also retain their own scan-time identity, and a
bounded identity-bound observer can now verify the metadata of an exact
`workspace-state.json` marker inside an exact SwiftPM `.build` candidate. This
advances that rule to revision 2. The observer also establishes trusted location
for exact uv, npm, and Homebrew default containers, which first advanced the
classification contract to revision 2, and recognizes the supported npm cacache layout from
exact `content-v2` and `index-v5` directory children. That npm rule is now
revision 5 and the built-in catalog is version 6. Its structural evidence still
includes the distinct `account-owned-cache-namespace` fact: both the held
selected root and held `_cacache` directory must carry the current account's
exact POSIX UID. A
bounded descriptor-relative traversal now also collects npm protected-
descendant evidence against the pinned cacache grammar and prior scan count.
The classifier contract is now revision 3 because the narrow npm activity
policy adds a first-class deferred execution precondition.

The scan-time identity only binds this read-only reobservation; it is not cleanup
or deletion authority. The npm-specific namespace check is not generic tool
ownership and does not prove historical creation, write ACLs, content,
inactivity, or mutation authority. The npm descendant check reads no content
and treats any unexpected path or kind, non-empty `tmp`, link, special node,
different-device entry, different-account owner, or unstable observation as
blocking or unknown. Other rules retain unknown tool ownership and descendant
evidence. npm activity, generated markers outside SwiftPM and npm, and location
for other rules remain uncollected. npm activity stays exactly
`unknown(.notCollected)`; only an otherwise valid npm result can become Review
required with the versioned pending attestation condition. The activity
capability review confirmed that the current unprivileged product cannot safely
turn a negative process or quiet-tree observation into `inactive`; see the
[activity safety contract](ACTIVITY.md).

Implemented commit sequence:

- `feat(rules): add explainable candidate classification`;
- `fix(rules): harden classification boundaries`;
- `feat(rules): validate classification report integrity`;
- `feat(cli): expose explainable classification reports`;
- `fix(rules): tighten report validation semantics`;
- `fix(cli): isolate classification failures`;
- `feat(app): present explainable policy decisions`;
- `feat(scanner): retain newest modification evidence`;
- `feat(rules): project observed candidate age`;
- `test(frontends): verify observed age stays protected`;
- `fix(scanner): keep age evidence conservative`;
- `docs(rules): document observed age evidence`;
- `feat(scanner): retain scan-time inode identities`;
- `refactor(rules): preflight scan reports before observation`;
- `feat(rules): add descriptor-bound evidence observer`;
- `feat(rules): bind SwiftPM marker evidence`;
- `docs(rules): document identity-bound marker evidence`;
- `feat(rules): bind trusted cache locations`;
- `docs(rules): define trusted location evidence`;
- `feat(rules): bind npm cache marker evidence`;
- `docs(rules): define npm layout evidence`;
- `feat(rules): bind npm account-owned namespace`;
- `docs(rules): define npm account namespace evidence`;
- `feat(rules): bind npm protected descendants`;
- `docs(rules): define npm descendant evidence`;
- `docs(safety): define npm activity capability boundary`.

- Introduce versioned rule definitions, eligible dispositions, and
  reproducibility classes.
- Start with high-confidence development caches.
- Show positive evidence, exclusions, age, activity requirements, and why a
  candidate is or is not reclaimable.

Gate: each rule has matches, near misses, hostile-path tests, and a visible
explanation. Unknown data remains protected.

Implementation milestone reached: scanning and explainable policy
classification are available in Core, CLI, and app without any mutation API.

## Phase 6: dry-run plans

Status: the Core planning increments create policy-provenanced immutable draft
manifests and deterministic compatible-manifest diffs in memory. A CLI-owned
increment adds an internal one-way CLI review JSON projection. The native app
now adds explicit current-session candidate selection and an identity-free,
read-only in-memory draft review. A Core-only increment now prepares an opaque
review session from one exact source-bound planning request, binds its source
root and manifest, and records intent only after confirming every session-owned
entry and acknowledging every pending condition for review. The acknowledgement
is not an activity attestation. There is still no CLI planning command,
manifest persistence, import, user-facing export, frontend diff or approval,
authorization, execution, execution-time filesystem revalidation, or mutation.

Implemented first commit: `feat(planner): create immutable cleanup manifests`.

- Convert explicit path-and-rule-revision selections over validated matched
  `reclaimable` or `review-required` decisions into deterministic immutable
  draft manifests.
- Record expected root and candidate identities, exact root-relative raw paths,
  rule and evidence state, and observed allocation estimates.
- Require the classifier's exact in-memory source-request binding so evidence
  cannot be mixed with a different scan's identities or sizes.
- Keep selection distinct from approval and retain the requirement for fresh
  execution-time revalidation.

Implemented next commits: `feat(rules): bind policy provenance` and
`feat(planner): diff compatible manifests`.

- Bind the classification contract revision, catalog revision, and complete
  rule-revision roster to reports and, in that increment, manifest contract
  version 2. The current deferred-precondition milestone advances the manifest
  to version 3.
- Keep legacy custom catalogs presentation-only unless they opt into an
  explicit non-built-in catalog revision.
- Compare only manifests with the same supported contract, exact provenance,
  and expected root identity; every incompatibility fails before entry output.
- Merge by exact raw path in linear time, compare every stored entry field, and
  represent observed-total changes with full-width directional quantities.
- Manifest diff contract version 2 now treats deferred execution preconditions
  as a first-class changed field.
- Keep user-facing privacy-aware export outside these Core increments and
  frontend review as a separate increment.

Implemented next commit: `feat(cli): add privacy-aware manifest review projection`.

- The original increment pinned CLI-owned
  `devsift.cleanup-manifest-review` schema version 1 to Core cleanup manifest
  contract version 2 without making Core models `Codable`. The current schema
  is version 2 pinned to source manifest version 3 and always projects the
  deferred-precondition array.
- Require an explicit redacted or root-relative-exact profile, always omit
  filesystem identities, and make the lossy document non-importable,
  non-approvable, and non-executable.
- Keep the encoder internal: no argument parser or application command invokes
  it, and it writes no file or standard output.
- Bound encoded output to 128 MiB with preflight and post-encode checks while
  retaining cooperative cancellation around non-interruptible Foundation
  encoding calls.
- Keep manifest-diff export, approval, execution, and frontend plan review out
  of this CLI-only increment.

Implemented next commit: `feat(app): present in-memory cleanup draft review`.

- Start every result with zero included candidates and keep native-table focus
  independent from draft inclusion.
- Expose only conservative candidate selections containing one exact raw path
  and rule revision, and accept only selections from the current result's exact
  whitelist.
- Retain and pass the exact source classification request and report to the
  Core planner so it repeats fail-closed validation rather than trusting the UI
  filter or reconstructed display values.
- Prepare the Core manifest and app-owned review projection away from the main
  actor, support cooperative cancellation, and use planning and scan-session
  tokens to suppress late results after cancellation, rescan, root change, or
  window closure.
- Discard the Core manifest after building an identity-free app presentation
  that shows all seven observed size and uncertainty quantities. Keep the flow
  in memory with no persistence, import, export, diff, approval, execution,
  execution-time filesystem revalidation, or filesystem access.
- Present an honest zero-candidate state. Current real classifications can
  remain Protected while non-deferred runtime facts are unavailable; an exact
  npm result may now reach Review required with an explicitly unobserved
  pending condition.

Implemented next commit: `feat(approval): bind intent to reviewed manifests`.

- Prepare an opaque review session directly from one exact source-bound
  `CleanupManifestRequest`, retaining its exact root and the concrete Core
  planner's manifest rather than accepting a later caller-supplied manifest.
- Issue session-bound entry references and require one explicit confirmation
  for every canonical entry. Reject missing, extra, duplicate, reordered,
  changed, or foreign-session confirmations as one failed request. Partial
  approval is unsupported; a different subset must be planned and reviewed as
  a new session.
- Keep approval in memory and non-`Codable`, with no persistence, importer,
  export, frontend action, or transfer from a manifest diff or review
  projection.
- Perform only bounded, cancellation-aware value validation. Approval performs
  no filesystem I/O or mutation and establishes neither freshness,
  authenticity, nor execution authority.
- Retain the exact source root and manifest in the approval. At that increment,
  reserve later authority derivation to that approval rather than a separately
  supplied root or unapproved manifest; the current design adds a distinct
  `CleanupQuarantineAuthorization` before any executor.

The recorded identity is comparison evidence, not mutation authority. A plan
must not convert an observer's successful identity or marker check into
permission to clean. Planning performs no filesystem I/O and the current Core
manifest deliberately has no `Codable`, import, or frontend-owned wire
contract. The separate CLI review projection is a lossy presentation document,
not serialized Core state. The app review is a separate ephemeral presentation,
not a wire format or approval input. The Core approval review session retains
the exact planning request, root, manifest, and process-local entry and pending-
condition bindings. The final approval drops the larger source request and
retains the root, manifest, and review acknowledgements. It is accepted by the
read-only revalidator but grants no execution authority. The current Core
authorizer separately binds it to an explicit attempt-scoped caller assertion
and process-local single-use lifecycle before the internal executor can receive
its handoff.

Gate: planning and diffing remain read-only and deterministic, selected
ineligible or policy-undeclared input fails closed, incompatible manifests never
produce a partial diff, and a substituted review value must invalidate approval.
A stale candidate must be rejected by execution-time revalidation. The
review projection must not expose filesystem identities or create import,
approval, attestation, authorization, execution, or user-facing export
authority. App selection must default to zero, remain independent from row
focus, reuse the exact source request and report, and suppress cancelled or
superseded planning results without filesystem access. Approval must originate
from one opaque source-bound review session, cover its exact root, complete
manifest, and pending-condition acknowledgement set, reject foreign-session
values, fail atomically, remain in memory, and add no filesystem or execution
capability.

Milestone: `v0.2.0-alpha.1` -- explainable recommendations and dry runs.

## Phase 7: recoverable cleanup

Each implemented-increment block below is a historical snapshot of the
contract at that increment. The tenth block records the current contracts and
supersedes the earlier version numbers, npm disposition statements, and future-
authorization language.

Implemented first commit: `feat(revalidation): reobserve approved cleanup intent`.

- Add a Core-only `CleanupRevalidator` that accepts only `CleanupApproval`,
  rescans its stored exact root, and reruns classification using only current
  built-in policy provenance.
- Reobserve exact root identity and each candidate's raw path, directory kind,
  device, identity, rule revision, findings, disposition, and stable policy
  fields. Preserve manifest order in canonical per-entry diagnostic results;
  incomplete or unknown source observations fail closed.
- Keep the report non-`Codable`, root-URL-free, copyable, and point-in-time. It
  creates no mutation authority, executor input, persistence, frontend, CLI,
  network, quarantine, restore, or purge capability.
- Keep cancellation cooperative and collapse public failures into stable,
  fail-closed categories. The report does not prove freshness after return or
  close execution races.

Implemented second increment: `feat(rules): bind trusted cache locations`.

- Observe trusted location only for exact uv, npm, and Homebrew documented
  default containers beneath the current operating-system account home.
- Gate on exact raw path components, then walk from `/` with no-follow,
  descriptor-relative opens and require the selected-root identity to match
  before and after observation.
- Keep custom overrides, Xcode and SwiftPM locations, tool ownership, activity,
  protected descendants, and non-SwiftPM generated markers unknown. Location
  evidence alone cannot make a real candidate eligible.
- Advance only the classifier-wide evidence contract to revision 2; keep the
  built-in catalog and individual rule revisions unchanged.

Implemented third increment: `feat(rules): bind npm cache marker evidence`.

- Recognize the supported cacache layout only when exact raw direct-child names
  `content-v2` and `index-v5` both identify same-device directories.
- Enumerate raw direct-child names to EOF through a descriptor, permit at most
  256 non-dot entries, and use the same gate to harden SwiftPM marker casing.
- Read no file contents, infer no tool ownership or activity, and expose no
  mutation authority; unresolved required facts keep real candidates
  `Protected`.
- Advance npm to rule revision 2 and the built-in catalog to revision 3. Keep
  SwiftPM and the classifier contract at revision 2, with frontend schemas
  unchanged.

Implemented fourth increment: `feat(rules): bind npm account-owned namespace`.

- Replace the npm rule's unprovable generic tool-ownership requirement with the
  distinct `account-owned-cache-namespace` fact.
- Satisfy it only when both the held selected root and held `_cacache`
  descriptor report the current account's exact POSIX UID.
- Treat this as a narrow namespace fact, not proof of historical creation,
  descendant ownership, write ACLs, cache content, inactivity, or mutation
  authority. Invoke no npm command, inspect no process or file content, and
  make no network request.
- Keep other rules' tool-ownership evidence unknown. npm activity and protected
  descendants remain unknown, so runtime npm candidates stay `Protected`.
- Advance npm to rule revision 3 and the built-in catalog to revision 4. Keep
  SwiftPM and the classifier contract at revision 2; scan JSON v2,
  classification JSON v1, cleanup manifest contract v2, and manifest-review
  JSON v1 remain unchanged.

Implemented fifth increment: `feat(rules): bind npm protected descendants`.

- Collect `protectedDescendantPresent` only for an exact top-level `_cacache`
  directory by walking its held descriptor without following symbolic links.
- Pin the accepted raw path-and-kind grammar to cacache 21.0.1: content and
  index shards, optional metadata files, and absent or empty `tmp`. Treat an
  unexpected path or kind, link, special node, hard-linked regular file,
  different-device entry, different-account owner, or repeated directory
  identity as protected.
- Bound the pass to 1,000,000 strict descendants, depth 32, and 64 MiB of raw
  filename bytes. Require stable traversal to EOF and agreement with the
  complete scanner count before reporting that no protected descendant exists.
- Read no file contents and treat permission, resource, malformed, incomplete,
  or changed observations as structured unknowns. Keep other evidence slots
  isolated and every non-npm protected-descendant fact uncollected.
- Advance npm to rule revision 4 and the built-in catalog to revision 5. Keep
  SwiftPM and the classifier contract at revision 2; scan JSON v2,
  classification JSON v1, cleanup manifest contract v2, and manifest-review
  JSON v1 remain unchanged.

Implemented sixth increment:
`docs(safety): define npm activity capability boundary`.

- Record the primary-source capability review in the
  [activity safety contract](ACTIVITY.md). The
  current unprivileged macOS product has no supported API that can prove the
  absence of active use across an entire cache subtree and preserve that
  result until a later operation.
- Reject quiet-tree sampling, empty process queries, advisory-lock success,
  kqueue, and FSEvents as automatic `inactive` evidence. cacache is explicitly
  lockless, libproc is private and cannot supply an exhaustive negative proof,
  and Endpoint Security requires a restricted entitlement and a materially
  different distribution and privacy model.
- At that historical decision-review increment, keep npm activity unknown and
  every real npm candidate `Protected`. Add no runtime process inspection,
  filesystem access, mutation, public capability, or schema change. At that
  point npm was rule revision 4, the built-in catalog was revision 5, the
  classifier contract was revision 2, scan JSON was v2, classification JSON was
  v1, cleanup manifest was v2, manifest-review JSON was v1, approval was v1,
  and revalidation was v1.
- Require a separate product and security decision, subsequently completed,
  before execution work:
  either a privileged authorization gate, an explicit user-attested policy for
  atomic recoverable quarantine that makes no inactivity claim, or an upstream
  cooperative lock. A positive-only conflict detector may harden any option,
  but no-match, permission, race, or resource-limit results stay unknown.

Implemented seventh increment:
`feat(policy): defer unobserved npm activity for recoverable quarantine`.

- Select option 2 only for a future recoverable npm quarantine attempt.
  Runtime activity remains literally `unknown(.notCollected)`; the classifier
  does not observe or claim inactivity.
- Add `RuleActivityRequirement.mustBeInactiveOrDeferToAttestationWhenUnobserved`
  and the policy-revision-1 pending condition
  `requiresUserAttestationThatResponsibleToolIsStopped`. Permit only one exact
  activity `unknown(.notCollected)` to be deferred on an otherwise valid,
  matched, Review-required npm result. Active use, another unknown reason,
  duplicates, or another blocker remains Protected.
- Advance the classifier contract to revision 3, npm to rule revision 5, and
  the built-in catalog to version 6. Scan JSON remains version 2;
  classification JSON advances to version 2 and always includes sorted
  `deferredExecutionPreconditions`.
- Carry the pending condition through cleanup manifest contract version 3.
  Manifest diff contract version 2 compares it as a first-class changed field.
  Internal manifest-review JSON version 2 is pinned to source manifest version
  3 and always projects the condition identifier and decimal-string policy
  revision in both privacy profiles.
- Advance approval to contract version 2. Review sessions expose exact pending-
  condition references, `acknowledgePreconditionForReview` creates
  `CleanupApprovalPreconditionReviewAcknowledgement`, and approval retains the
  canonical `preconditionReviewAcknowledgements`. This binds only that the
  condition and risk were reviewed; it is not the user's statement that npm
  stopped, freshness, or execution authority.
- Advance revalidation to contract version 2. Revalidate the unchanged pending
  policy and report an otherwise valid npm entry as
  `awaitingExecutionPreconditions`; expose
  `hasPendingExecutionPreconditions` without calling the entry eligible or
  authorized.
- Let the native app select the exact canonical deferred result and display
  “Activity remains unobserved,” fresh-revalidation and separate attempt-
  authorization language. Add no approval, acknowledgement, or attestation
  control.
- Regenerate older manifests, approvals, and exports instead of importing or
  migrating them. Add no wall-clock TTL freshness rule and no executor,
  quarantine, restore, purge, or deletion implementation.

Implemented eighth increment:
`feat(core): add single-attempt quarantine authorization`.

- Add Core-only `CleanupQuarantineAuthorizer.beginAttempt(for:)`. Validate and
  retain one exact approval; accept no caller-supplied root, manifest,
  revalidation report, or review projection.
- After current-built-in canonical validation, independently pin classifier
  revision 3 and catalog revision 6 for authorization contract version 1.
  Report drift as `unsupportedApprovalPolicy` rather than silently inheriting a
  future built-in default.
- Directly pin every pending subject to npm rule revision 5, responsible tool
  `npm`, precondition policy revision 1, and statement policy revision 1.
  Reject no-pending, mixed, or unsupported sets; unsupported
  requirements report `unsupportedAttestationRequirements`.
- Expose one `CleanupQuarantineAttestationRequest` whose canonical subjects
  cover the complete pending set. Accept one explicit
  `CleanupQuarantineUserAttestation` using the required
  `responsibleToolStoppedAndUnobservedActivityRiskAccepted` statement. This is
  a caller assertion, not observed inactivity, human proof, authentication, or
  standalone mutation authority. Approval-time review acknowledgement remains
  separate copyable, replayable review intent.
- Bind request, attestation, session, and authorization to process-local attempt
  identity. Reject cross-attempt replay without clock reads or a TTL. Permit at
  most one authorization issuance per attempt and one internal executor handoff
  across every authorization copy through shared actor state.
- Make cancellation terminal for an open or issued attempt and release retained
  state. Allow a correct retry after wrong-attempt or wrong-statement input
  while the session remains open; observed task cancellation returns
  `CancellationError` and no partial authorization.
- Define `CleanupQuarantineAuthorization` contract version 1 as single-use,
  recoverable-quarantine-only, not permanent-deletion authorization, and still
  requiring inline filesystem revalidation. Explicitly report
  `grantsStandaloneFilesystemMutationAuthority == false` and
  `usesWallClockFreshness == false`.
- Keep `consumeForExecution()` and `CleanupQuarantineExecutionClaim` internal.
  Add no executor, filesystem I/O, npm or process invocation, persistence,
  `Codable`, frontend or CLI action, quarantine, receipt, recovery, restore,
  purge, or deletion.
- Record the complete contract in the
  [authorization contract](AUTHORIZATION.md).

Implemented ninth increment:
`feat(core): add atomic npm quarantine executor`.

- Add a Core-internal `CleanupQuarantineExecutor` that can enter only by
  atomically consuming an authorization's internal execution claim.
- Independently validate the exact classifier-3/catalog-6/npm-5 approval,
  single `_cacache` entry, review-required conditional policy, npm tool,
  deferred precondition, acknowledgement, and version-1 attestation.
- Reopen the real account's exact passwd-home `~/.npm` root and approved
  candidate through held descriptors. Recheck current UID ownership, same
  device, identities, mutation state, the complete pinned cacache grammar,
  no non-owner POSIX write access, safe flags, no extended ACL below the home,
  traversal limits, single-link regular files, and the inclusive seven-day age
  requirement.
- Create or reopen only `.devsift-quarantine-v1` under the held root and require
  mode `0700`, current UID, same volume, no ACL, safe flags, and the required
  volume capabilities.
- Make each candidate-move attempt through one `renameatx_np` call with
  `RENAME_EXCL`, `RENAME_NOFOLLOW_ANY`, and `RENAME_RESOLVE_BENEATH`. Retry only
  a reconciled destination collision, within a bounded random-name budget, and
  never overwrite or pre-create a destination leaf.
- Require macOS 26 or newer for the mutation kernel because older kernels lack
  `RENAME_RESOLVE_BENEATH`; reject before quarantine-root creation or rename on
  older supported systems while retaining macOS 14 read-only surfaces.
- Reconcile source, destination, and parent bindings after every rename result.
  Attempt only a non-overwriting reverse rename when rollback is safe;
  otherwise return a bounded manual-recovery outcome. Once rename is invoked,
  continue reconciliation despite cancellation and record late cancellation.
- Define internal process-local, non-`Codable`
  `CleanupQuarantineExecutionReport` contract version 1. Report a verified
  move as `quarantinedAwaitingReceipt`, never completed or crash-recoverable.
- Add no durable intent, receipt, sync, startup recovery, restore, purge,
  deletion, copy, unlink, public API, app action, or CLI action. Record the
  boundary in the [quarantine execution contract](QUARANTINE.md).

Implemented tenth increment:
`feat(core): add durable quarantine journal and recovery`.

- Add a private, canonical version-1 journal for one already-authorized npm
  transaction. Publish an immutable intent before rename and an immutable
  terminal `quarantined`, `not-moved`, or `rolled-back` receipt only after the
  required namespace barriers.
- Preplan exactly 16 distinct destination names in the intent. Bind the exact
  raw source path, root, quarantine root, candidate, policy revisions, and
  destination set; bind a receipt to the exact intent bytes with SHA-256.
- Serialize cooperating processes through a validated mode-`0600`, nonblocking
  exclusive lock. Publish records with exclusive staged renames and require
  `F_FULLFSYNC` for record files plus the npm-root and quarantine-root namespace
  parents, with no weaker durability fallback.
- Reconcile journal state under the same lock before admitting a new intent.
  Validate bounded inventory and canonical record pairing. For a receipt-less
  intent, observe all planned destinations and record only namespace truth that
  proves `not-moved` or `quarantined`; never resume, automatically reverse,
  overwrite, compact, or delete an interrupted transaction.
- Add a root-only internal recovery entry point that can reopen an existing npm
  quarantine namespace even when the source `_cacache` name is absent. It is
  not yet wired to app launch or either frontend.
- Advance the internal, process-local, non-`Codable`
  `CleanupQuarantineExecutionReport` to contract version 2. Distinguish no
  durability record, intent recorded, terminal receipt recorded, and unresolved
  state. Only a terminal receipt is durably recorded; only validated intent or
  receipt state is declared crash-recoverable. An unresolved transaction ID
  alone is not enough. Crash-recoverable means canonical restart recovery has
  authoritative evidence to inspect and safely complete, preserve, or block;
  it does not guarantee automatic receipt publication for ambiguous live state.
- Require exact current policy revisions for every new intent while retaining
  canonical read compatibility for supported earlier revisions. Unknown, zero,
  and future revisions still fail closed, so normal policy upgrades do not
  poison completed journal history or inert stages.
- Keep final receipts immutable as historical transaction evidence. Current
  live source/destination truth is required when recovering receipt-less intents
  or promoting a receipt stage, not to reinterpret a valid final receipt.
- Add no restore, manual-recovery user flow, purge, permanent deletion, public
  API, app action, or CLI action. Record the contract in the
  [quarantine durability contract](DURABILITY.md).

Implemented eleventh increment:
`feat(core): add durable manual npm restore`.

- Add a Core-internal, npm-only manual workflow that discovers one exact
  restorable item only from a canonical final quarantine intent and its matching
  final `quarantined` receipt. Accept no arbitrary path, root, item name, or
  caller-created journal value.
- Keep quarantine authorization version 1 consumed and one-way. Bind a fresh,
  process-local, single-use restore claim to one exact durable transaction after
  an explicit caller confirmation; the claim is not authentication, durable
  authority, or a public filesystem capability.
- Reopen the real account's exact `~/.npm` and quarantine roots through held
  descriptors. Immediately before mutation, revalidate historical parent and
  candidate bindings plus current containment, kind, identity, ownership,
  same-device, metadata, ACL, bounded cacache-tree, restore-policy, and exact
  destination-absence requirements.
- Add separate canonical immutable restore intent and receipt records without
  rewriting the historical quarantine pair. Bind the exact source transaction
  and record digests, publish and fully synchronize the restore intent before
  rename, synchronize both namespace parents afterward, and publish a terminal
  `restored` or `not-restored` receipt only for conclusive state.
- Perform at most one descriptor-relative reverse rename from the receipt-bound
  `item-v1-*` name to its original exact `_cacache` name with `RENAME_EXCL`,
  `RENAME_NOFOLLOW_ANY`, and `RENAME_RESOLVE_BENEATH`. Never overwrite, copy,
  unlink, remove, or use a path-based fallback.
- Extend the bounded journal inventory and recovery state machine before the
  restore executor can publish intents. Permit at most one receipt-less mutation
  intent across quarantine and restore, reserve the worst-case record capacity,
  and recover an interrupted restore only by observing namespace truth and
  completing a receipt, never by retrying its rename.
- Add deterministic, bounded, per-transaction manual-recovery diagnostics for
  completed, failed, changed, recovered, restored, skipped, and unresolved
  states. Diagnostics cannot suppress a blocker, edit or delete records, adopt
  an occupant, or create mutation authority.
- Keep supported historical quarantine records restorable while requiring the
  exact current restore-policy revision for each new restore intent. Unknown,
  zero, future, malformed, or unsupported history remains fail-closed.
- Keep every restore model, selection, claim, executor, recovery entry point,
  and report internal and non-`Codable`. Add no public API, app or CLI action,
  automatic launch recovery, batch or background restore, custom-root or
  multi-rule support, purge, permanent deletion, journal compaction, analytics,
  or network access. Record the implemented contract in the
  [manual quarantine restore contract](RESTORE.md).

Current boundary after the manual-restore increment:

- Core can internally prepare, explicitly authorize, execute, durably record,
  recover, and report one exact receipt-bound npm `_cacache` restore at a time.
  The workflow accepts no arbitrary root, source path, destination path, or
  quarantine item name.
- Restore selection, authorization, executor, reports, journal facade, and
  recovery entry points remain internal and non-`Codable`. The app and CLI are
  read-only and expose no restore action; no automatic, launch-time, batch, or
  background restore runs.
- Purge, permanent deletion, overwrite, unlink, journal compaction, and
  retention remain absent. Neither quarantine authorization version 1 nor a
  restore artifact authorizes deletion.
- Bounded internal reports distinguish conclusive terminal receipts from
  receipt-less or unresolved state without turning diagnostics into mutation
  authority.

Gate: adversarial tests cover symlink swaps, path races, mounts, partial
failures, cancellation on both sides of the rename linearization point, crash-
consistent receipt recovery, non-overwriting rollback, restore, and fixture-
boundary integrity. A focused security review is required. Revalidation must
reopen the target and establish fresh containment, kind, identity, and policy
evidence immediately before any mutation; scan-time inode identity alone is
never sufficient.

The eleventh increment's repository-internal focused review is recorded in
[MANUAL_RESTORE_SECURITY_REVIEW.md](MANUAL_RESTORE_SECURITY_REVIEW.md).

Milestone: `v0.3.0-alpha.1` -- quarantine-based cleanup. Permanent removal is a
later, separately reviewed milestone.

## Definition of done for every code commit

- Formatting passes.
- The project builds without warnings introduced by the change.
- Unit and integration tests pass.
- Tests use only synthetic temporary fixtures.
- Safety, privacy, and user-visible behavior changes are documented.
- `git diff --check` passes.
- No generated artifacts, personal paths, reports, credentials, or signing
  material are staged.
