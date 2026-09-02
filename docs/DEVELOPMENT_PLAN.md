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

Commit: `feat(app): add a read-only storage scan dashboard`

- Add explicit folder selection, progress, cancellation, and result views.
- Display that the current release is analysis-only.
- Cover the view model with unit tests.
- Check basic keyboard, VoiceOver, light-mode, and dark-mode behavior.

Gate: the app builds without signing in CI and invokes DevSiftCore rather than a
duplicate scanner.

Milestone: `v0.1.0-alpha.1` -- scan-only app and CLI.

## Phase 5: explainable rules

Commit sequence begins with `feat(rules): classify cleanup candidates with explainable policies`.

- Introduce versioned rule definitions and risk classes.
- Start with high-confidence development caches.
- Show positive evidence, exclusions, age, activity requirements, and why a
  candidate is or is not reclaimable.

Gate: each rule has matches, near misses, hostile-path tests, and a visible
explanation. Unknown data remains protected.

## Phase 6: dry-run plans

Commit sequence begins with `feat(planner): create immutable cleanup manifests`.

- Convert approved candidates into deterministic immutable plans.
- Record expected identity and allocated bytes.
- Add plan diffing and export with privacy-aware paths.

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
security review is required.

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
