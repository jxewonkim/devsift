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
advances that rule to revision 2 and the CLI catalog to version 2.

The scan-time identity only binds this read-only reobservation; it is not
cleanup or deletion authority. Trusted-location, ownership, reliable-activity,
and protected-descendant evidence remain uncollected, so even a satisfied age
and generated-marker finding leaves the real candidate `Protected`. Observers
for those remaining facts are later Phase 5 increments.

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
- `docs(rules): document identity-bound marker evidence`.

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

Commit sequence begins with `feat(planner): create immutable cleanup manifests`.

- Convert approved candidates into deterministic immutable plans.
- Record expected identity and allocated bytes.
- Add plan diffing and export with privacy-aware paths.

The recorded identity is comparison evidence, not mutation authority. A plan
must not convert an observer's successful identity or marker check into
permission to clean.

Gate: planning remains read-only and a stale or edited candidate invalidates
execution.

Milestone: `v0.2.0-alpha.1` -- explainable recommendations and dry runs.

## Phase 7: recoverable cleanup

Commit sequence begins with `feat(cleaner): quarantine revalidated candidates`.

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
