# Native app contract

The DevSift macOS app is a read-only SwiftUI projection of DevSiftCore. It lets
the user choose exactly one folder, observes filesystem metadata, applies the
same versioned rule classifier as the CLI, and presents observation and policy
results separately. It can also create and display an unapproved in-memory
draft from explicitly selected eligible results. It has no persistence,
import, export, diff, approval, execution, cleanup, move, quarantine, or
deletion action.

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

The view model retains the exact `RuleClassificationRequest` sent to the
classifier and its exact returned report for the current result. It never
reconstructs a request from displayed values. Review preparation passes those
values and a frozen, canonically ordered selection to Core, then immediately
projects the resulting manifest into an app-owned identity-free value. The
review presentation retains no root or candidate filesystem identities,
manifest, source request, provenance roster, reference time, serialized raw
path, approval state, or execution state. An exact raw relative path remains
only as an in-memory row identifier; escaped display text is rendered instead.
The selected root is shown separately from the current window state so the user
can verify scope.

The review displays the disposition, rule revision, responsible tool,
reproducibility, classification explanation, and every satisfied finding. It
also displays all seven stored observations: logical bytes, apparent allocated
bytes, hard-link-exclusive allocated bytes, possible shared-content file count,
shared-content metadata-unavailable count, unobserved hard-link file count, and
non-exclusive hard-link file count. These are observations and uncertainty
indicators, never a guaranteed savings forecast.

The view is explicitly labeled an unapproved, non-executable in-memory draft.
Returning to selection discards only the presentation and preserves the user's
included set for editing. Rescanning, choosing another folder, or closing the
window discards both selection and review. Nothing is saved, imported,
exported, diffed, approved, executed, checked against the live filesystem, or
changed on disk. Because the runtime classifier still lacks several required
facts, an honest real scan can show zero eligible draft candidates.

DevSiftCore now has a separate approval-review session contract prepared from
an exact source-bound planning request, but this app increment does not invoke
it. The app continues to discard the Core manifest after making its
identity-free presentation, exposes no approval button or state, and cannot
reconstruct the opaque session, its exact root, or its session-bound entry
references from that lossy presentation.

## Observation and policy language

The app uses “Reclaimable” only as a rule disposition, never as a measured or
guaranteed savings claim. It always explains that observed allocation is not
guaranteed reclaimable. Hard links, APFS clones, snapshots, compression,
unreadable paths, and concurrent changes can make actual free-space changes
differ from the observation. A real scan may show its age requirement as
Satisfied from the newest inode modification time observed for a complete item.
An exact SwiftPM `.build` row may also show its generated-marker finding as
Satisfied after an identity-bound metadata check for `workspace-state.json`.
An exact uv, npm, or Homebrew default cache location may show trusted-location
as Satisfied after descriptor-bound root reobservation. The app does not display
the raw candidate timestamp, scan-time identity, or current account home path,
and none of these findings changes disposition by itself. Missing ownership,
activity, protected-descendant, or generated-marker evidence keeps the candidate
Protected. Scan-time identity is not cleanup or deletion authority.

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
quantities, and window-lifecycle invalidation.

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
