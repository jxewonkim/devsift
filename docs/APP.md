# Native app contract

The DevSift macOS app is a SwiftUI projection of DevSiftCore. Its analysis
surfaces let the user choose exactly one folder, observe filesystem metadata,
apply the same versioned rule classifier as the CLI, and review an explicitly
selected in-memory draft. Those stages remain read-only. The source-run app can
also use package-scoped Core workflows to durably quarantine one exact npm cache
at the current non-root account's passwd-home `~/.npm/_cacache` after explicit
review and two confirmation gates, explicitly reconcile and load a bounded
recovery inventory, and separately confirm a receipt-bound, non-overwriting
restore.

The app has no manifest persistence, import, export, or diff action. It has no
purge, permanent deletion, retention, background cleanup, batch operation,
custom-path mutation, network, or telemetry feature. It never invokes recovery
automatically on launch. The low-level journal, descriptor scopes, transaction
identifiers, and execution claims remain behind Core's package boundary, and
the CLI and public Core API remain read-only.

Run the development executable on macOS 14 or newer:

```shell
swift run DevSiftApp
```

The current Swift Package product is an unsigned development executable, not a
distributed `.app` bundle. Scanning and review are available on macOS 14 or
newer; every quarantine or restore mutation requires macOS 26 or newer.

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

Folder choices, table focus, candidate inclusion, reports, drafts, review
sessions, confirmations, and inventory action references are not persisted.
Canonical transaction intents and receipts are durable workflow metadata inside
the fixed quarantine namespace, where the moved cache also remains. Closing a
window asks its active task to cancel and discards window state, but Core may
finish post-rename reconciliation and receipt publication when the mutation
boundary has already been crossed.

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

review --explicit review + stopped-risk confirmation--> final confirmation
final confirmation --confirm--> executing --> quarantine result
any stable state --explicit recovery action--> reconcile/load --> inventory
inventory --select one ready receipt + confirm--> restoring --> restore result
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
inactive. The draft is not authorization. For the sole supported npm workflow,
continuation requires explicit review, a separate confirmation that npm work
using the cache was stopped while acknowledging that inactivity was not
observed, and a final confirmation of the quarantine move. Core still performs
fresh inline revalidation before mutation.

The view is explicitly labeled an unapproved in-memory draft. Returning to
selection discards the presentation and its Core review session while preserving
the included set for editing. Rescanning, choosing another folder, or closing
the window discards selection, review, and unused authority. Before review and
both confirmations complete, nothing is authorized, revalidated for execution,
or changed on disk. Because the runtime classifier still lacks several required
facts, an honest real scan can show zero eligible draft candidates. An exact
npm candidate whose non-deferred facts all pass may instead appear as Review
required with the pending condition; that state can begin only the narrow
confirmation workflow and is not itself a safety verdict.

DevSiftCore prepares the approval-review session from the exact source-bound
planning request, and the app retains that opaque session alongside its separate
identity-free presentation. It never reconstructs the session, root, entries,
or pending conditions from display text. After final confirmation, an app-local
workflow derives and briefly holds Core's approval, attempt, attestation, and
authorization values, then passes the authorization to the package-scoped
executor. The UI and presentation never receive those values. No frontend-
created path, transaction identifier, journal record, or execution claim enters
the executor.

After final confirmation, the same facade binds the exact review to a fresh
attempt-scoped stopped-npm assertion and consumes its single-use authority. The
assertion is not observed inactivity, authentication, or a general filesystem
capability. The app projects only bounded transaction outcomes and durability
states, and it calls a terminal receipt successful rather than treating a move
alone as completion.
See the [authorization contract](AUTHORIZATION.md),
[quarantine execution contract](QUARANTINE.md), and
[durability contract](DURABILITY.md).

## Implemented Phase 9 transaction contract

Status: implemented for the source-run native app. The distributed CLI archive
and public DevSiftCore API have no mutation surface.

The native mutation workflow is restricted to one exact npm
`_cacache` selected from a scan of the current non-root account's exact
passwd-home `~/.npm`. The app reaches it only through a package-scoped
DevSiftCore facade;
the low-level executor, descriptor-held scopes, journal codecs, recovery engine,
and restore claims remain unavailable to the app and to public library
clients. The CLI remains read-only.

Draft preparation retains the exact Core-issued approval review session in
memory while separately rendering the identity-free review presentation. To
continue, the review surface records two independent values: confirmation that
every displayed entry and pending requirement was reviewed, and the assertion
that npm work using the cache was stopped while accepting that DevSift did not
observe inactivity. The UI does not display or reconstruct a raw Core
attestation-request identifier or statement from display text. A separate final
confirmation dialog then names the recoverable move. Only after that action does
the app-local `CleanupQuarantineWorkflow` derive the approval, begin a fresh
Core attempt, and construct the attestation from the exact statement requested
by Core. It passes only the issued authorization into the package-scoped
executor. None of these controls is described as observed activity evidence or
proof that the operation is safe.

The final action requests exactly one recoverable quarantine attempt. It is
unavailable below macOS 26 and makes no request for elevated
permissions. Once execution may have crossed its rename boundary, dismissal or
cancellation does not prevent Core from reconciling the namespace, applying its
durability barriers, and publishing a safe terminal receipt when possible. The
app distinguishes not moved, durably quarantined, rolled back, and manual-
recovery-required outcomes. It does not call an intent-only or unresolved
transaction complete.

Recovery is never an app-launch side effect. The initial inventory load and a
manual refresh require an explicit user action. Core also runs locked recovery
as a fail-closed prerequisite during quarantine transaction admission, restore
preparation, and restore transaction admission. When a restore execution
returns to the still-current, uncancelled view-model operation, that view model performs one fresh
reconciliation and inventory refresh while preserving the bounded result.
Dismissal, cancellation, or a superseding operation suppresses stale UI
publication and can prevent or cancel that follow-up refresh. Each inventory
load runs fixed-npm recovery, journal reread, validation, and bounded projection
under the same validated exclusive lock. Inventory rows originate only from canonical durable
quarantine receipts that have not been restored and carry opaque process-local
action references rather than frontend-provided paths, quarantine names, record
bytes, or transaction identifiers. Malformed or unresolved journal state, an
unsafe trusted parent, or aggregate resource exhaustion rejects the complete
load instead of returning a partial list. Source readiness distinguishes a clear
original name, the previously expected object, and another occupant. Item
readiness preserves missing, changed, unsafe, and per-item over-bound contents as
visible non-restorable rows rather than hiding them.

One ready receipt-bound inventory row can start a separate explicit manual
restore. The restore confirmation identifies the fixed original name and exact
receipt-bound selection, states that npm is stopped, and explains that post-
quarantine contents may have changed. Restore never overwrites a recreated
`_cacache`, never runs automatically, and never infers eligibility from
presentation state. Core reopens and revalidates the fixed roots, journal pair,
exact item, complete tree, and destination absence before its one non-
overwriting reverse rename.

Quarantine is a same-volume rename into `.devsift-quarantine-v1`; it deallocates
no data and guarantees exactly 0 B of freed capacity. The UI labels displayed
bytes as observed allocation, not reclaimed capacity. Phase 9 adds no purge,
permanent deletion, retention policy, batch or background cleanup, custom path,
non-npm mutation, launch-time or unattended recovery or restore, CLI or public-
Core mutation, networking, telemetry, distributed application bundle, signing,
notarization, installer, or updater. The bounded post-attempt inventory refresh
described above is the only recovery follow-up scheduled by the UI; mandatory
quarantine admission, restore preparation, and restore admission still perform
locked recovery inside explicitly initiated operations.

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

Transaction tests cover retained Core review-session binding, the independent
review and stopped-npm confirmations, the final quarantine confirmation,
single-attempt execution, macOS-version rejection, bounded durability outcomes,
late cancellation, and guaranteed freed capacity of 0 B. Recovery and restore
tests use only synthetic journal fixtures and cover explicit (never launch-time)
reconciliation, atomic inventory rejection, deterministic receipt-bound rows,
honest source/item readiness, opaque-reference isolation, exact restore
confirmation, single use, and non-overwriting outcomes.

The optional native snapshot harness renders representative empty, scanning,
classifying, complete, partial, policy, selection, and draft-review states. It
also renders light and dark npm quarantine review/results, recovery inventory,
restore confirmation, and restore results without scanning a real directory:

```shell
env DEVSIFT_SNAPSHOT_DIR=/private/tmp/devsift-snapshots \
  swift test --filter VisualSnapshotTests
```

The Swift Package does not yet define an Xcode UI-testing bundle. Keyboard and
VoiceOver interaction for scanning, confirmations, quarantine, recovery
inventory, and restore remains a local manual acceptance check; build and value-
based behavior are the CI gate.
