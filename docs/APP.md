# Native app contract

The DevSift macOS app is a read-only SwiftUI projection of DevSiftCore. It lets
the user choose exactly one folder, observes filesystem metadata, applies the
same versioned rule classifier as the CLI, and presents observation and policy
results separately. It can also create and display an unapproved in-memory
draft from explicitly selected eligible results. It has no persistence,
import, export, diff, approval, activity-attestation, authorization, execution,
cleanup, move, quarantine, restore, purge, or deletion action.
Core's internal npm quarantine kernel, durable journal, and recovery engine are
intentionally unreachable from the app. Frontend transaction design, restore
and manual-recovery flows, security review, and release checks must precede any
wiring; the app does not automatically invoke recovery on launch.

Run the development executable on macOS 14 or newer:

```shell
swift run DevSiftApp
```

The current Swift Package product is an unsigned development executable, not a
distributed `.app` bundle.

## Explicit scope

The app starts empty and never scans on launch. `Select Folder…` opens a native
single-directory importer. Alias resolution is disabled at the file-dialog
boundary, and the selected file URL is passed to DevSiftCore unchanged: the app
does not standardize it, resolve symlinks, rebuild it from a path string, or
discard dot components.

The app requests security-scoped access for the returned URL. A successful
request is balanced only after scanning, classification, and result preparation
finish, on every success, error, and cancellation path. Development URLs that
are already readable can return `false` because no scope was granted; the
scanner still attempts its descriptor-based validation and reports a typed read
failure if access is unavailable.

Folder choices, table focus, candidate inclusion, reports, and draft reviews
are not persisted. Closing a window cancels its active task and discards that
window's in-memory state.

## States and transitions

Each window owns an independent `ScanViewModel` and one scan phase. A completed
result also owns one draft-review subphase:

```text
empty --select--> scanning --scan result--> classifying --success--> result
                       |                         |             |
                       |                         |             +--> failed
                       +-----------cancel--------+-----------> cancelled

result/cancelled/failed --rescan--> scanning
any stable state --------select--> scanning a new root

result/selecting --include exact candidates--> selecting
selecting --review nonempty selection--------> preparing --success--> review
                                                  |             |
                                                  +--cancel-----> selecting
                                                  +--failure----> failed
review --back-----------------------------------------------> selecting
failed --edit selection or retry--------------------> selecting/preparing
```

Core does not expose a known total or progress callback, so scanning and policy
analysis use honest indeterminate progress states. They never invent a
percentage. Cancellation becomes visible immediately and asks the active task
to stop; a blocking filesystem call can return before Core reaches its next
checkpoint.

Every scan receives a unique operation ID. Starting a new scan invalidates and
cancels the previous task. A scanner that ignores cancellation and returns late
can release its own security scope, but its success or error cannot overwrite
the newer phase.

Draft preparation has a separate operation ID and is performed away from the
main actor. The selected set is frozen while Core planning and app presentation
run. Cancellation returns immediately to selection, while the worker observes
cooperative cancellation at bounded checkpoints. A new scan, folder change, or
window closure invalidates the planning session; operation and scan-session
tokens prevent any late success or failure from replacing newer state.

## Result presentation

The dashboard shows one observation summary band and a native table of
top-level items. It uses the field mapping and partial rules in
[SCANNING.md](SCANNING.md#app-presentation-contract), then joins Core policy
decisions by exact raw `ScanRelativePath` identity.

The initial table order is apparent allocated bytes descending, with exact raw
path bytes as the deterministic tie-breaker. The visible row columns are:

- explicit dry-run inclusion, or a lock for an ineligible row;
- root-relative item name;
- filesystem kind;
- observed apparent allocation;
- hard-link-adjusted allocation;
- observed entry count;
- complete or partial observation status;
- an independent policy disposition.

The policy badge always presents the effective disposition: Reclaimable,
Review, or Protected. Valid unrecognized, possible-match, conflict, and
invalid-rule decisions therefore display Protected. Before presentation, the
app validates the classifier's report against the original `ScanReport` and
reference time; missing, duplicate, extra, or internally inconsistent output
enters a bounded policy-analysis failure state instead of being rendered. The
row presenter also keeps malformed non-protected decisions Protected as a
secondary defense.

No row is focused automatically, and zero candidates are included in a draft
by default. Table focus only reveals a policy disclosure; it never toggles
draft inclusion. The disclosure shows the match state, rule revision or
revisions when present, responsible tool, explanation, and every structured
finding. The entire central result pane is top-anchored and scrollable at the
900 x 620 minimum window size; the dashboard header and safety footer remain
fixed while the table and disclosure can move through the viewport.

Paths are untrusted display data. Control and invisible formatting characters,
backslashes, and invalid UTF-8 bytes are escaped before display. The raw
`ScanRelativePath` remains the SwiftUI row identifier, so two byte-distinct
names cannot collapse into one visible identity.

## Draft selection and review

The table exposes inclusion only for rows that pass a conservative app-side
eligibility filter. Each inclusion value is one exact
`CleanupCandidateSelection`: the raw root-relative path and the selected rule
revision. The view model accepts only values from the current scan's exact
whitelist. The filter is a UI convenience, not a policy decision; the Core
`CleanupPlanner` remains the fail-closed authority and repeats complete report,
source binding, provenance, identity, allocation, and evaluation validation.
The filter accepts the sole canonical deferred activity shape but rejects
active use, another unknown reason, another blocking finding, or malformed
precondition metadata. Valid custom rules can use that shape; the current
built-in catalog produces it only for npm.

The view model retains the exact `RuleClassificationRequest` sent to the
classifier and its exact returned report for the current result. It never
reconstructs a request from displayed values. Review preparation passes those
values and a frozen, canonically ordered selection to Core, then immediately
projects the resulting manifest into an app-owned identity-free value. The
review presentation retains no root or candidate filesystem identities,
manifest, source request, provenance roster, reference time, serialized raw
path, approval state, attestation state, authorization state, or execution
state. An exact raw relative path remains only as an in-memory row identifier;
escaped display text is rendered instead.
The selected root is shown separately from the current window state so the user
can verify scope.

The review displays the disposition, rule revision, responsible tool,
reproducibility, classification explanation, and every finding. It
also displays all seven stored observations: logical bytes, apparent allocated
bytes, hard-link-exclusive allocated bytes, possible shared-content file count,
shared-content metadata-unavailable count, unobserved hard-link file count, and
non-exclusive hard-link file count. These are observations and uncertainty
indicators, never a guaranteed savings forecast.

If a manifest entry carries
`requires-user-attestation-that-responsible-tool-is-stopped@1`, the review
displays “Activity remains unobserved” at both review and entry level. It says
that the pending condition is policy metadata, not evidence that npm is
inactive; any recoverable operation requires fresh revalidation and a separate
attempt-scoped authorization. The draft is not that authorization and cannot
be executed. There is no approval, acknowledgement, or attestation CTA.

The view is explicitly labeled an unapproved, non-executable in-memory draft.
Returning to selection discards only the presentation and preserves the user's
included set for editing. Rescanning, choosing another folder, or closing the
window discards both selection and review. Nothing is saved, imported,
exported, diffed, approved, acknowledged, attested, authorized, executed,
checked against the live filesystem, or changed on disk. Because the runtime
classifier still lacks several required facts, an honest real scan can show
zero eligible draft candidates. An exact npm candidate whose non-deferred facts
all pass may instead appear as Review required with the pending condition; that
does not make it safe to operate.

DevSiftCore now has a separate approval-review session contract prepared from
an exact source-bound planning request, but this app increment does not invoke
it. The app continues to discard the Core manifest after making its
identity-free presentation, exposes no approval button or state, and cannot
reconstruct the opaque session, its exact root, or its session-bound entry
or precondition references from that lossy presentation.

Core also has an in-memory `CleanupQuarantineAuthorizer`, but the app neither
begins an attempt nor constructs `CleanupQuarantineUserAttestation`. It exposes
no attestation request, statement, authorization state, cancellation, or
filesystem action. Authorization contract version 1 is not a UI safety verdict
and grants no standalone mutation authority. The internal execution report is
not app presentation state. Its contract-version-2 durability state and the
private journal are likewise not app inventory or completion UI; see the
[authorization contract](AUTHORIZATION.md),
[quarantine execution contract](QUARANTINE.md), and
[durability contract](DURABILITY.md).

## Prospective Phase 9 transaction contract

Status: planned and not implemented. This section defines the boundary that
must be satisfied before the app's current read-only contract can change. It
does not describe a capability in the current build.

The first native mutation workflow will remain restricted to one exact npm
`_cacache` selected from a scan of the current account's exact passwd-home
`~/.npm`. The app will reach it only through a package-scoped DevSiftCore facade;
the low-level executor, descriptor-held scopes, journal codecs, recovery engine,
and restore claims will remain unavailable to the app and to public library
clients. The CLI will remain read-only.

Draft preparation will retain the exact Core-issued approval review session in
memory while separately rendering the identity-free review presentation. To
continue, the user will explicitly confirm every session entry and acknowledge
every pending condition from that same session. The app will not rebuild those
values from displayed paths or policy text. A separate confirmation surface
will then present the complete attempt-scoped attestation request and require
the user to state that npm work using the cache is stopped and that DevSift did
not observe inactivity. Checking that statement will not be described as
observed activity evidence or proof that the operation is safe.

The final action will request exactly one recoverable quarantine attempt. It
will be unavailable below macOS 26 and will make no request for elevated
permissions. Once execution may have crossed its rename boundary, dismissal or
cancellation will not prevent Core from reconciling the namespace, applying its
durability barriers, and publishing a safe terminal receipt when possible. The
app will distinguish not moved, durably quarantined, rolled back, and manual-
recovery-required outcomes. It will not call an intent-only or unresolved
transaction complete.

Before another transaction is enabled after restart, the app will ask the
package-scoped facade to reconcile the fixed npm journal and prepare a bounded
inventory. Inventory rows will originate only from canonical Core journal
relationships and will carry opaque process-local action references rather
than frontend-provided paths, quarantine names, or transaction identifiers. An
unresolved global blocker will remain visible and will disable conflicting
actions.

One receipt-bound inventory row may start a separate explicit manual restore.
The restore confirmation will identify the original and quarantine locations,
state that npm is stopped, and explain that post-quarantine contents may have
changed. Restore will never overwrite a recreated `_cacache`, run
automatically, or infer eligibility from presentation state. Core will reopen
and revalidate the fixed roots, journal pair, exact item, complete tree, and
destination absence before its one non-overwriting reverse rename.

Quarantine is a same-volume rename into `.devsift-quarantine-v1`; it does not
free disk space. The UI will label the displayed bytes as observed allocation,
not reclaimed capacity, and will explain that permanent removal is required to
increase free space. Phase 9 will add no purge, deletion, retention policy,
batch or background cleanup, custom path, non-npm mutation, automatic restore,
CLI mutation, application-bundle packaging, signing, notarization, installer,
or updater.

## Observation and policy language

The app uses “Reclaimable” only as a rule disposition, never as a measured or
guaranteed savings claim. It always explains that observed allocation is not
guaranteed reclaimable. Hard links, APFS clones, snapshots, compression,
unreadable paths, and concurrent changes can make actual free-space changes
differ from the observation. A real scan may show its age requirement as
Satisfied from the newest inode modification time observed for a complete item.
An exact SwiftPM `.build` row may also show its generated-marker finding as
Satisfied after an identity-bound metadata check for `workspace-state.json`.
An exact npm `_cacache` row may satisfy the same finding when bounded raw
directory enumeration confirms exact `content-v2` and `index-v5` directories.
An exact uv, npm, or Homebrew default cache location may show trusted-location
as Satisfied after descriptor-bound root reobservation. The exact npm candidate
may additionally show `account-owned-cache-namespace` as Satisfied only when
the held root and `_cacache` directory both carry the current account's exact
POSIX UID. That fact replaces generic tool ownership only for the npm rule; it
does not establish historical creation, write ACLs, content, inactivity, or
mutation authority. The npm row may also satisfy `no-protected-descendants`
after a bounded stable traversal matches the pinned cacache grammar and earlier
scan count. The app does not display descendant paths, the raw candidate
timestamp, scan-time identity, current account home path, or UID, and none of
these satisfied findings makes a candidate eligible by itself. npm activity
remains literally `unknown(.notCollected)`: the
[activity capability review](ACTIVITY.md) rejects an empty process query or
quiet tree as proof of inactivity. Classifier contract revision 3 may preserve
that unknown and expose the fixed pending precondition when every non-deferred
npm fact passes. The UI must say “Activity remains unobserved”; it must not call
npm inactive, safe, approved, or authorized. The other rules retain unknown
tool ownership, protected-descendant evidence, and other required facts, so
they remain Protected. Scan-time identity is not cleanup or deletion authority.

“Complete observation” describes traversal within the configured limits. A
partial observation can result from skipped entries, output bounds, incomplete
hard-link accounting, discarded traversal details, suppressed issues, unknown
allocated sizes, or size overflow. Retained issues and additional unretained
issues have separate counts and issue rows include operation and impact.

## Keyboard and accessibility

- `Command-O`: select a folder when a scan is not active;
- `Command-R`: rescan the current folder when available;
- `Escape`: cancel an active scan or policy analysis;
- arrow keys: move the native table focus without changing draft inclusion;
- the draft-selection bar's `Cancel` button: cancel active draft preparation.

Buttons use text labels and accessibility hints. Decorative symbols are hidden
from VoiceOver. Metric groups, progress, observation status, and the results
table have explicit labels. Scan and draft-review phase changes post a
high-priority VoiceOver announcement, and state titles carry the heading trait.
Complete and partial states include text and icons, so color is never the only
signal.

The interface uses semantic macOS colors and system typography. It supports
light and dark appearance without separate assets, has a 900 x 620 minimum
window size, and uses 1200 x 760 as its design QA viewport. Observation status
uses green only for an explicitly complete observation; partial states use text
plus the system warning color.

## Verification

`DevSiftAppTests` covers initial privacy, exact request forwarding, success,
every report-level partial flag, typed and unexpected failures, cancellation,
late completion, newer-scan precedence, security-scope balance, presentation
sorting and escaping, overflow behavior, and real Core scans over synthetic
temporary fixtures, including an age-satisfied candidate that remains
Protected. Draft-review tests additionally cover conservative candidate
eligibility, exact current-session whitelisting, default-zero and frozen
selection behavior, exact request and report reuse, off-main planning,
cancellation and stale-result suppression, generic failure text, identity-free
projection, safe free-form text, canonical ordering, all seven observed
quantities, deferred-precondition fail-closed boundaries, explicit unobserved
activity disclosure, absence of authorization or safety claims, and window-
lifecycle invalidation.

The optional native snapshot harness renders representative empty, scanning,
classifying, light and dark results, 900 x 620 complete and partial results,
expanded policy evidence, draft selection, and light and dark draft review at
default and minimum sizes without scanning a real directory:

```shell
env DEVSIFT_SNAPSHOT_DIR=/private/tmp/devsift-snapshots \
  swift test --filter VisualSnapshotTests
```

The Swift Package does not yet define an Xcode UI-testing bundle. Keyboard and
VoiceOver interaction remain a local manual acceptance check; build and value-
based behavior are the CI gate.
