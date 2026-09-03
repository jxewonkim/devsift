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
advances that rule to revision 2 and the CLI catalog to version 2. A later
observer can now establish trusted location for exact uv, npm, and Homebrew
default containers, advancing the classification contract to revision 2 without
changing catalog or rule revisions.

The scan-time identity only binds this read-only reobservation; it is not cleanup
or deletion authority. Ownership, reliable activity, protected descendants,
non-SwiftPM generated markers, and location for other rules remain uncollected,
so real candidates stay `Protected`. Observers for those remaining facts are
later increments.

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
- `docs(rules): define trusted location evidence`.

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
entry. There is still no CLI planning command, manifest persistence, import,
user-facing export, frontend diff or approval, execution, execution-time
filesystem revalidation, or mutation.

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
  rule-revision roster to reports and manifest contract version 2.
- Keep legacy custom catalogs presentation-only unless they opt into an
  explicit non-built-in catalog revision.
- Compare only manifests with the same supported contract, exact provenance,
  and expected root identity; every incompatibility fails before entry output.
- Merge by exact raw path in linear time, compare every stored entry field, and
  represent observed-total changes with full-width directional quantities.
- Keep user-facing privacy-aware export outside these Core increments and
  frontend review as a separate increment.

Implemented next commit: `feat(cli): add privacy-aware manifest review projection`.

- Pin the CLI-owned `devsift.cleanup-manifest-review` schema version 1 to Core
  cleanup manifest contract version 2 without making Core models `Codable`.
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
- Present an honest zero-candidate state. Current real classifications can all
  remain Protected while required runtime facts are unavailable.

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
- Retain the exact source root and manifest in the approval. Require any future
  executor and its inline revalidation to consume only that approval rather
  than a separately supplied root or unapproved manifest.

The recorded identity is comparison evidence, not mutation authority. A plan
must not convert an observer's successful identity or marker check into
permission to clean. Planning performs no filesystem I/O and the current Core
manifest deliberately has no `Codable`, import, or frontend-owned wire
contract. The separate CLI review projection is a lossy presentation document,
not serialized Core state. The app review is a separate ephemeral presentation,
not a wire format or approval input. The Core approval review session retains
the exact planning request, root, manifest, and process-local entry bindings.
The final approval drops the larger source request and retains the root and
manifest. It is accepted by the read-only revalidator but grants no execution
authority; a future executor requires its own inline revalidation boundary.

Gate: planning and diffing remain read-only and deterministic, selected
ineligible or policy-undeclared input fails closed, incompatible manifests never
produce a partial diff, and a substituted review value must invalidate approval.
A stale candidate must be rejected by future execution-time revalidation. The
review projection must not expose filesystem identities or create import,
approval, execution, or user-facing export authority. App selection must default
to zero, remain independent from row focus, reuse the exact source request and
report, and suppress cancelled or superseded planning results without filesystem
access. Approval must originate from one opaque source-bound review session,
cover its exact root and complete manifest, reject foreign-session confirmations,
fail atomically, remain in memory, and add no filesystem or execution capability.

Milestone: `v0.2.0-alpha.1` -- explainable recommendations and dry runs.

## Phase 7: recoverable cleanup

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

Next: add separately reviewed rule-specific evidence needed for real
eligibility; only then design recoverable quarantine. The future executor must
accept the approval, not the diagnostic report, and revalidate inline while
holding descriptors immediately before an operation.

Later Phase 7 work, after that evidence and executor design:

- Accept only `CleanupApproval` and reopen the root stored within it, never a
  separately supplied root, draft manifest, diff, or presentation.
- Revalidate identity, containment, activity, and rule version.
- Move approved items to a recoverable quarantine.
- Report completed, failed, changed, and skipped items individually.
- Add restore support before considering purge.

Gate: adversarial tests cover symlink swaps, path races, mounts, partial
failures, interruption, restore, and fixture-boundary integrity. A focused
security review is required. Revalidation must reopen the target and establish
fresh containment, kind, identity, and policy evidence immediately before any
mutation; scan-time inode identity alone is never sufficient.

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
