# Native app contract

The DevSift macOS app is a read-only SwiftUI projection of DevSiftCore. It lets
the user choose exactly one folder, observes filesystem metadata, and presents
complete or partial scan results. It has no classification, recommendation,
cleanup, move, quarantine, or deletion action.

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
request is balanced only after the scan and result preparation finish, on every
success, error, and cancellation path. Development URLs that are already
readable can return `false` because no scope was granted; the scanner still
attempts its descriptor-based validation and reports a typed read failure if
access is unavailable.

Selections, recent folders, and reports are not persisted. Closing a window
cancels its active task and discards that window's in-memory state.

## States and transitions

Each window owns an independent `ScanViewModel` and one visible phase:

```text
empty --select--> scanning --success--> result
                       |          |
                       |          +-----> failed
                       +--cancel--------> cancelled

result/cancelled/failed --rescan--> scanning
any stable state --------select--> scanning a new root
```

Core does not expose a known total or progress callback, so the scanning state
uses an indeterminate progress indicator. It never invents a percentage.
Cancellation becomes visible immediately and asks the underlying task to stop;
a blocking filesystem call can return before Core reaches its next checkpoint.

Every scan receives a unique operation ID. Starting a new scan invalidates and
cancels the previous task. A scanner that ignores cancellation and returns late
can release its own security scope, but its success or error cannot overwrite
the newer phase.

## Result presentation

The dashboard shows one open summary band and a native table of top-level
observations. It uses the field mapping and partial rules in
[SCANNING.md](SCANNING.md#app-presentation-contract).

The initial table order is apparent allocated bytes descending, with exact raw
path bytes as the deterministic tie-breaker. The visible row columns are:

- root-relative item name;
- filesystem kind;
- observed apparent allocation;
- hard-link-adjusted allocation;
- observed entry count;
- complete or partial observation status.

Paths are untrusted display data. Control and invisible formatting characters,
backslashes, and invalid UTF-8 bytes are escaped before display. The raw
`ScanRelativePath` remains the SwiftUI row identifier, so two byte-distinct
names cannot collapse into one visible identity.

## Accounting language

The app never uses “reclaimable,” “can free,” “savings,” or “safe to clean” as a
result label. It always explains that observed allocation is not guaranteed
reclaimable. Hard links, APFS clones, snapshots, compression, unreadable paths,
and concurrent changes can make actual free-space changes differ from the
observation.

“Complete observation” describes traversal within the configured limits. A
partial observation can result from skipped entries, output bounds, incomplete
hard-link accounting, discarded traversal details, suppressed issues, unknown
allocated sizes, or size overflow. Retained issues and additional unretained
issues have separate counts and issue rows include operation and impact.

## Keyboard and accessibility

- `Command-O`: select a folder when a scan is not active;
- `Command-R`: rescan the current folder when available;
- `Escape`: cancel an active scan;
- arrow keys: move the native table selection.

Buttons use text labels and accessibility hints. Decorative symbols are hidden
from VoiceOver. Metric groups, progress, observation status, and the results
table have explicit labels. Scan phase changes post a high-priority VoiceOver
announcement, and state titles carry the heading trait. Complete and partial
states include text and icons, so color is never the only signal.

The interface uses semantic macOS colors and system typography. It supports
light and dark appearance without separate assets, has a 900 x 620 minimum
window size, and uses 1200 x 760 as its design QA viewport. Green is reserved
for an explicitly complete observation; partial states use text plus the system
warning color.

## Verification

`DevSiftAppTests` covers initial privacy, exact request forwarding, success,
every report-level partial flag, typed and unexpected failures, cancellation,
late completion, newer-scan precedence, security-scope balance, presentation
sorting and escaping, overflow behavior, and a real Core scan over a synthetic
temporary fixture.

The optional native snapshot harness renders representative empty, scanning,
light result, dark result, 900 x 620 result, and 900 x 620 partial-result states
without scanning a real directory:

```shell
env DEVSIFT_SNAPSHOT_DIR=/private/tmp/devsift-snapshots swift test
```

The Swift Package does not yet define an Xcode UI-testing bundle. Keyboard and
VoiceOver interaction remain a local manual acceptance check; build and value-
based behavior are the CI gate.
