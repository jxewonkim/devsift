# Scanning contract

DevSiftCore provides a read-only scanner for explicitly selected local
directories. It reads filesystem metadata, never file contents, and exposes no
mutation operation.

```swift
let report = try await AllocatedSizeScanner().scan(root: selectedFolder)
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

DevSift never labels a scan total as guaranteed reclaimable space. Future
cleanup rules and execution-time revalidation are separate layers.

The command-line projection, including human labels, JSON schema, stream
behavior, and exit codes, is documented in the [CLI contract](CLI.md).

## App presentation contract

The native dashboard maps Core values without deriving cleanup eligibility:

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
were satisfied. It does not mean that an item is safe to remove. The complete
app behavior and accessibility contract is documented in [APP.md](APP.md).

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
identities from a scan must never be reused as authority for later cleanup. A
future executor will reopen and revalidate every approved item before mutation.
