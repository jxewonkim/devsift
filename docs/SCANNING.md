# Scanning contract

DevSiftCore provides a read-only scanner for explicitly selected local
directories. It reads filesystem metadata, never file contents, and exposes no
mutation operation.

```swift
let report = try await AllocatedSizeScanner().scan(
  ScanRequest(root: selectedFolder)
)
```

## Result shape

A report contains:

- a recursive summary for the selected root;
- one recursive summary per successfully observed direct child, ordered by
  exact filesystem bytes;
- structured, root-relative issues;
- issue and accounting-completeness fields for every bounded result.

`ScanRelativePath` retains each component's original filesystem bytes. Its
human-readable description preserves valid UTF-8 and renders an invalid
component as hexadecimal escapes. `description` is display-only and can match a
valid literal escape-like name; equality and ordering use `rawComponents`.
Frontends must apply their own context-safe display escaping. The app escapes
control, format, line-separator, default-ignorable, backslash, and invalid UTF-8
bytes before rendering a path, while retaining the raw path as row identity.

The scanner does not retain a result object for every descendant. A caller can
drill down by explicitly scanning one direct child as a new root. If the
configured top-level output bound is exceeded, DevSift returns no arbitrary
subset: it suppresses the complete top-level list, keeps the root aggregate,
and marks the report incomplete. `topLevelItemCount` is the number of direct
children whose metadata was successfully observed; it remains available when
the summary list alone is suppressed, but resets with the other details after a
global entry-limit overflow. Entry counts include the summary node itself, so
an empty root reports one directory.

## Size semantics

- `recursiveSize.logicalBytes` is the sum of apparent inode sizes for every
  observed path.
- `recursiveSize.allocatedBytes` is the corresponding sum of POSIX allocated
  blocks (`st_blocks * 512`). Because it is an apparent total, multiple hard
  links to one inode appear once per pathname.
- `hardLinkExclusiveAllocatedBytes` removes only hard-link ambiguity. A
  hard-linked regular-file inode is credited once only when all of its links
  were observed inside the same summary boundary. It is still not a guaranteed
  reclaimable value because clones and snapshots have separate uncertainty.
- `nonExclusiveHardLinkFileCount` identifies regular-file paths whose
  allocation cannot be assigned exclusively to that summary. Link counts
  larger than the links seen under the selected root increment
  `unobservedHardLinkFileCount` once per affected inode group, not once per
  missing link.
- directories and symbolic links contribute only their own inode storage;
  symbolic-link targets are never opened or sized.
- `sizeOverflowed` records that at least one size sum in that summary saturated
  at `UInt64.max`. It remains available even if the corresponding bounded issue
  is not retained, so a frontend can withhold the saturated value.

The descriptor-relative scanner deliberately does not reconstruct absolute
child paths to query Foundation resource values. Clone-sharing metadata is
therefore currently reported as unavailable, not as `false`. APFS clones,
snapshots, compression, and concurrent changes can all make a later change in
free volume space differ from either measurement.

DevSift never labels a scan total as guaranteed reclaimable space. The rule
classifier and Core draft planner consume the bounded report as separate
read-only layers, and execution-time revalidation remains separate again. See
the [rules contract](RULES.md) and [planning contract](PLANNING.md).

The command-line projection, including human labels, JSON schema, stream
behavior, and exit codes, is documented in the [CLI contract](CLI.md).

## Modification-time evidence

Each root and top-level summary retains one bounded lifecycle aggregate:
`newestContentModificationUnixSeconds`. It is the maximum conservative
whole-second upper bound of the summary inode and every descendant inode
observed during the existing descriptor-relative traversal. The scanner does
not retain one timestamp per descendant and performs no later path-based probe.

- A timestamp with zero nanoseconds retains its POSIX seconds value. A positive
  fractional second rounds up to the next second, preventing lost precision
  from making the item appear older.
- Negative, malformed, or unrepresentable timestamps invalidate the entire
  affected aggregate rather than being hidden by another inode's newer value.
- Directory and symbolic-link inode times contribute. Symbolic-link targets do
  not, because they are never followed.
- An empty directory uses its own inode modification time.
- A partial summary's observed maximum does not prove that no newer descendant
  exists. The rule adapter uses this value as known age evidence only when the
  top-level item summary is complete.

An inode modification time is not a last-access time and can be changed by a
user or process. It does not establish inactivity, ownership, generated
content, or cleanup safety. A scan is not a filesystem snapshot, so a file may
change after its individual observation. Draft planning must not treat this
aggregate as current authority. A Core approval review session retains the
exact scan-derived planning root and manifest but does not refresh either;
any execution must require fresh policy and object revalidation before any
mutation.

This aggregate is currently a Core-only input to rule findings. Scan JSON v2
does not emit the raw timestamp; classification JSON v2 exposes the resulting
finding state and explanation, not the candidate timestamp itself.

## Scan-time identity

The root and each retained top-level summary also carry the `(device, inode)`
of that summary's own inode as `scanTimeIdentity`. It is not an aggregate of
descendant identities. Hard-linked top-level paths may legitimately have the
same identity, while a symbolic-link summary records the link inode rather than
its target. The scanner retains root and top-level identities together or
fails closed rather than presenting a partially bound set.

This value exists only to let a bounded descriptor-relative evidence observer
verify that a reopened root or candidate is the object that was scanned. It is
not a durable identifier, trusted-location or ownership evidence, a cleanup
capability, or deletion authority. Inodes can be reused; a draft plan carries
these values only as comparison evidence, and any execution must reopen and
revalidate containment, kind, identity, and policy evidence immediately before
mutation. Scan JSON v2 and classification JSON v2 do not emit raw scan-time
identities.

## App presentation contract

The native dashboard maps Core scan values without deriving cleanup eligibility
itself:

| App label | Core value |
| --- | --- |
| Observed apparent allocation | `root.recursiveSize.allocatedBytes` |
| Hard-link-adjusted allocation | `root.hardLinkExclusiveAllocatedBytes` |
| Observed logical size | `root.recursiveSize.logicalBytes` |
| Observed entries | `root.counts.total` |

The selected directory inode is included in the root summary. Top-level rows
therefore do not have to sum to the root values. Rows sort by apparent allocated
bytes descending, then by `ScanRelativePath` raw-byte ordering. Row identity is
the raw relative path rather than its display string. A row with one or more
unknown allocation measurements stays in that same ordering based on the
allocation bytes that were observed; it is marked partial but is not promoted
or demoted as a special case.

The app applies these partial-result rules:

- `topLevelItemsWereSuppressed` shows the observed direct-child count and no
  arbitrary subset of rows;
- `traversalDetailsWereDiscarded` withholds normal descendant totals and rows,
  because the remaining root values describe only the selected directory inode
  and earlier issues were discarded;
- `hardLinkAccountingIsComplete == false` marks hard-link-adjusted values as
  partial;
- `sizeOverflowed` withholds that summary's size values as overflowed rather
  than exact;
- unknown allocated sizes and incomplete item summaries are visibly partial;
- retained `issues.count` and `suppressedIssueCount` are displayed separately.

“Complete observation” means the configured traversal and accounting bounds
were satisfied. It does not mean that an item is safe to remove. Observation
status and the rule classifier's policy status remain visibly separate. The
complete app behavior and accessibility contract is documented in
[APP.md](APP.md).

## Containment and traversal

- The selected root must be an absolute local `file:` URL with no remote host,
  query, or fragment. Its final component cannot be a symbolic link.
- Symbolic-link ancestors such as `/var` on macOS are allowed.
- The root is opened once with `O_DIRECTORY | O_NOFOLLOW`. Every descendant is
  read relative to an already-open parent using `fstatat`; directories are
  opened with `openat`, `O_DIRECTORY`, and `O_NOFOLLOW`, then identity-checked
  with `fstat` before traversal.
- Descendant symbolic links are recorded but never traversed. A concurrent
  directory-to-symlink replacement is reported and skipped.
- Descendants on a different device are reported and pruned.
- Hidden files are included. No shell command is constructed or executed.
- Cancellation throws `CancellationError`; it is never converted into a
  successful partial report. A blocking filesystem call itself is not
  interruptible, but cancellation is checked between directory entries.

## Resource limits and determinism

Defaults are:

- depth: 128 components;
- scanned entries: 10,000,000;
- direct-child summaries: 50,000;
- tracked hard-link path entries: 100,000;
- retained hard-link path bytes: 32 MiB;
- recorded issues: 4,096.

Limits are configurable through `ScanLimits`. Reaching any limit is visible and
marks the report incomplete. If the global entry limit is exceeded, DevSift
discards traversal-order-dependent descendant aggregates and issues, then
returns a root-only partial report with a resource-limit issue. Those discarded
issues are not part of `suppressedIssueCount`, which describes only the bounded
issue collector; `traversalDetailsWereDiscarded` records this separate event. If
hard-link tracking exceeds its bound, all pending hard-link credits are
discarded and `hardLinkAccountingIsComplete` becomes `false`.

Issue storage uses a bounded heap. Regardless of discovery order, the retained
issues are the earliest by raw root-relative path and structured issue fields;
`suppressedIssueCount` reports the rest.

## Consistency

A scan is a point-in-time observation, not a filesystem snapshot. Each entry's
logical and allocated sizes come from one POSIX stat result. An opened
directory's device and inode are revalidated before recursion, but files can
still change before or after their individual observation. Paths and inode
identities from a scan must never be reused as authority for later cleanup.
Core authorization contract version 1 can bind an exact approval and explicit
caller assertion into a process-local, single-use value, but it performs no
filesystem I/O and grants no standalone mutation authority. The Core-internal
npm executor enters only through the `CleanupQuarantineAuthorization` handoff,
reopens the exact approval-bound `~/.npm` root, and revalidates the sole
authorized `_cacache` candidate while descriptors remain held through the
atomic move.
A bare approval or revalidation report is not executor input. See the
[authorization contract](AUTHORIZATION.md) and
[quarantine execution contract](QUARANTINE.md).
