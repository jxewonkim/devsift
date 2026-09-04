# Command-line contract

The `devsift` command exposes DevSiftCore's read-only scanner and rule
classifier without adding a second filesystem or policy implementation. It
reads metadata under one explicitly named directory. It has no cleanup, move,
quarantine, delete, plan-review, manifest-import, or manifest-export command.
The CLI target contains an internal manifest-review JSON encoder described
below, but no command invokes it and it performs no stream or file output by
itself.

## Usage

```text
devsift scan [--format text|json] [--json] [--] <path>
devsift classify [--format text|json] [--json] [--] <path>
```

Text is the default format. `--json` is an alias for `--format json`. A path is
always required; DevSift never silently substitutes the current directory or a
home directory. Use `--` before a path whose first character is `-`.

Relative paths are interpreted from the process's starting directory. DevSift
preserves `.` and `..` components until the operating system opens the path; it
does not lexically collapse them or resolve symbolic links first. This matters
for paths such as `link/..`, whose POSIX meaning depends on the target of
`link`. A quoted `~` is not expanded by DevSift.

Symbolic-link ancestors are allowed. The final selected root cannot be a
symbolic link, and descendant symbolic links are observed but never traversed.
Descendant mount points on another device are reported and pruned. See the
[scanning contract](SCANNING.md) for the complete traversal and limit rules.

Examples:

```shell
devsift scan .
devsift scan --json .
devsift scan --format json -- -leading-dash
devsift classify .
devsift classify --json -- -leading-dash
```

`classify` first performs the same scan, then gives each observed top-level raw
path one deterministic policy decision. It does not reuse a separate or stale
scan report. For a complete retained item, the classifier can evaluate age from
the conservative newest inode modification time observed during that scan.
For an exact SwiftPM `.build` candidate, an identity-bound observer can also
check metadata for an exact regular-file `workspace-state.json` generated
marker. For an exact npm `_cacache`, bounded raw enumeration can identify exact
`content-v2` and `index-v5` directories as a supported cacache-layout marker.
Exact default uv, npm, and Homebrew cache containers may also satisfy trusted-
location evidence after descriptor-bound reobservation. For an exact npm
candidate, the held selected root and held `_cacache` directory may additionally
satisfy `account-owned-cache-namespace` when both have the current account's
exact POSIX UID. This is not generic npm ownership and does not inspect cache
contents, processes, or network state. It also proves neither historical
creation, write ACLs, inactivity, nor mutation authority. The same exact npm
candidate can additionally satisfy a bounded protected-descendant exclusion
only after a stable descriptor-relative traversal matches the pinned cacache
path-and-kind grammar and the earlier scan. npm activity remains uncollected;
the [activity capability review](ACTIVITY.md) rejects a quiet tree or empty
process result as proof of inactivity. The other rules retain unknown tool
ownership, protected descendants, and other required facts, so they stay
protected. An otherwise valid npm decision retains activity as
`unknown(.notCollected)`, becomes Review required, and prints the pending
`requires-user-attestation-that-responsible-tool-is-stopped@1` condition. That
is policy metadata, not an inactivity or execution claim; see the
[rules contract](RULES.md).
Before rendering, the CLI validates the returned classification against the
original `ScanReport` and reference time supplied to the classifier. An invalid
or malformed report produces only the generic internal-error response. It exits
with status `70`, writes that diagnostic to standard error, and emits no
standard output.

## Stream behavior

- Complete and partial scan or classification reports go to standard output.
- Usage errors and fatal scan diagnostics go to standard error, with no report
  on standard output.
- A report derived from a partial scan is still valid and machine-readable,
  but exits with status `2` so scripts cannot silently treat omitted data as
  complete.
- Output is assembled before it is written. JSON standard output therefore
  contains one document followed by exactly one newline.
- There are no progress messages, ANSI colors, telemetry, or network requests.

Human-readable names and diagnostics escape terminal control characters,
invisible Unicode format characters, quotes, and backslashes. Invalid UTF-8
filename bytes are rendered as `\xNN`; a literal backslash is doubled so the
two cases remain distinguishable.

## Scan text format

The text report labels completeness and accounting uncertainty explicitly.
Top-level entries are ordered by apparent allocated bytes, largest first, with
raw filesystem-byte path ordering as the deterministic tie-breaker.

`Observed apparent allocated` counts allocation once per observed pathname.
`Observed hard-link-exclusive allocated` only removes regular-file hard-link
ambiguity when the scanner observed every link inside one summary boundary.
Neither number is guaranteed reclaimable space: clones, snapshots,
compression, concurrent changes, and partial traversal can change the result.

When the global entry limit is reached, descendant aggregates are discarded.
Text output labels the recursive summary and top-level items unavailable rather
than presenting the remaining root-inode values as a complete total.

## Classification text format

Classification text is ordered by exact raw path. It includes the catalog
version and rule count, one captured Unix reference time, aggregate match and
disposition counts, and one expanded decision per observed top-level item.
Its `Scan integrity` block reports whole-report and root completeness,
observed and retained top-level counts, top-level suppression, discarded
traversal detail, hard-link-accounting completeness, retained and suppressed
issue counts, root and retained-item overflow, and root and retained-item
unknown-allocation state.

Each decision contains:

- terminal-safe root-relative path text;
- disposition, match state, rule revision or conflict revisions;
- display name, responsible tool, and reproducibility;
- sorted deferred execution preconditions as `identifier@policyRevision`, or
  `none`;
- observed apparent and hard-link-exclusive allocation, observation
  completeness, overflow, and unknown-allocation state;
- every structured finding and its satisfied, failed, or unknown state;
- a final explanation.

An unrecognized path has no invented rule revision and remains protected. If a
scan summary cannot be joined to the exact raw decision path, allocation is
shown as unavailable rather than borrowed from another item.

## Scan JSON schema version 2

JSON output is a versioned CLI-owned projection of the Core report. Core models
are not made `Codable`, so a future Core refactor cannot silently change the
wire format.

The envelope contains:

- `schema`: always `devsift.scan`;
- `schemaVersion`: the JSON number `2`;
- `devsiftVersion` and `safetyMode`;
- `pathStyle`: always `root-relative`;
- all six effective scan limits;
- a structured CLI projection of `ScanReport`, excluding Core-only aggregates
  such as the newest modification time.

Every size, count, and limit is encoded as a decimal string. This preserves the
full unsigned 64-bit range in JavaScript and other JSON consumers. The optional
POSIX `systemCode` is a JSON number or explicit `null`.

Each root and top-level item also includes `sizeOverflowed`. When it is `true`,
one or more of that summary's size additions saturated at `UInt64.max`; the raw
decimal fields remain machine-readable, but must not be presented as exact
totals. Schema version 2 adds this field. Version 1 did not carry an overflow
flag and is no longer emitted by the pre-release CLI.

Scan JSON v2 does not expose the Core summary's raw modification-time aggregate
or scan-time identity. Adding either wire field would require an explicit
schema decision; the current evidence changes do not alter the scan JSON shape.

Each path has a display value and an exact identity:

```json
{
  "display": "cache/module",
  "rawComponentsBase64": ["Y2FjaGU=", "bW9kdWxl"]
}
```

The selected absolute root is intentionally omitted. All reported paths are
relative to that root, reducing accidental username and workspace disclosure
when output is shared. Filenames and sizes can still be sensitive; redirecting
or publishing a report is an explicit user decision and requires review.

Top-level JSON items retain the Core scanner's exact raw-path order. Issues
retain the Core's deterministic structured order. The human size sort does not
change either JSON array.

A minimal synthetic envelope has this shape:

```json
{
  "devsiftVersion": "0.0.0-dev",
  "limits": {
    "maximumDepth": "128",
    "maximumEntries": "10000000",
    "maximumRecordedIssues": "4096",
    "maximumTopLevelItems": "50000",
    "maximumTrackedHardLinkEntries": "100000",
    "maximumTrackedHardLinkPathBytes": "33554432"
  },
  "pathStyle": "root-relative",
  "report": {
    "hardLinkAccountingIsComplete": true,
    "isComplete": true,
    "issues": [],
    "root": {
      "counts": {
        "directories": "1",
        "duplicateHardLinks": "0",
        "other": "0",
        "regularFiles": "0",
        "symbolicLinks": "0",
        "total": "1"
      },
      "hardLinkExclusiveAllocatedBytes": "0",
      "isComplete": true,
      "kind": "directory",
      "nonExclusiveHardLinkFileCount": "0",
      "path": { "display": ".", "rawComponentsBase64": [] },
      "possibleSharedContentFileCount": "0",
      "recursiveSize": { "allocatedBytes": "0", "logicalBytes": "0" },
      "sharedContentMetadataUnavailableCount": "1",
      "sizeOverflowed": false,
      "unknownAllocatedItemCount": "0",
      "unobservedHardLinkFileCount": "0"
    },
    "suppressedIssueCount": "0",
    "topLevelItemCount": "0",
    "topLevelItems": [],
    "topLevelItemsWereSuppressed": false,
    "traversalDetailsWereDiscarded": false
  },
  "safetyMode": "scan-only",
  "schema": "devsift.scan",
  "schemaVersion": 2
}
```

Directory allocation and metadata availability vary by filesystem, so this is
a schema example, not a promised scan result for an empty directory.

## Classification JSON schema version 2

`devsift classify --json` emits a separate CLI-owned contract. It does not
change the existing scan schema.

The classification JSON schema is version 2. Its built-in catalog is version 6.
`devsift.cache.npm` is rule revision 5 for its exact cacache-layout, trusted-
location, account-owned cache-namespace, protected-descendant evidence, and
narrow deferred activity policy;
`devsift.swiftpm.build` remains revision 2 for the exact
`workspace-state.json` marker, and every other built-in rule remains revision
1. Catalog and rule revisions can change without changing the JSON key shape.
The identifier and version come from the Core-owned
`BuiltInRuleCatalog.revision`, preventing CLI metadata from drifting from the
classifier. The full Core policy provenance and its rule roster are not
exported by this schema.

Schema version 2 adds an always-present `deferredExecutionPreconditions` array
to every decision. Each element contains a stable `identifier` and decimal-
string `policyRevision`; the array is empty when nothing is deferred. Version 1
documents are not imported or migrated. Re-run classification to create a
current export.

The related current contracts are explainable classification revision 3,
cleanup manifest version 3, manifest diff version 2, approval version 2,
revalidation version 2, quarantine authorization version 1, and internal
cleanup-manifest-review JSON version 2 pinned to source manifest version 3.
Scan JSON remains version 2.

The envelope contains:

- `schema`: always `devsift.classification`;
- `schemaVersion`: the JSON number `2`;
- `devsiftVersion`, `safetyMode`, and root-relative `pathStyle`;
- `catalog`: identifier, version, and built-in rule count;
- `referenceUnixSeconds`: one decimal string used by every age check;
- `scanIsComplete`;
- `scanIntegrity`: the complete bounded-scan integrity projection;
- `summary`: decimal-string counts for every match state and disposition;
- `decisions`: one decision per exact raw top-level path.

`scanIntegrity` contains:

- booleans `isComplete`, `rootIsComplete`,
  `topLevelItemsWereSuppressed`, `traversalDetailsWereDiscarded`,
  `hardLinkAccountingIsComplete`, `rootSizeOverflowed`,
  `anyRetainedItemSizeOverflowed`, and `anyUnknownAllocatedSize`;
- decimal strings `topLevelItemCount`, `retainedTopLevelItemCount`,
  `retainedIssueCount`, `suppressedIssueCount`,
  `rootUnknownAllocatedItemCount`, and
  `retainedItemsWithUnknownAllocatedSizeCount`.

Each decision contains the same display and Base64 raw path representation as
the scan schema, an optional `ruleRevision`, sorted `matchingRuleRevisions`,
match and disposition fields, reproducibility, a nullable observation, ordered
findings, an always-present sorted `deferredExecutionPreconditions` array, and
an explanation. A finding state has a `status` and nullable unknown `reason`.
The observation includes decimal-string apparent,
hard-link-exclusive, and unknown-allocation counts plus completeness and
overflow booleans.

An age finding may be satisfied, failed, or unknown from the in-memory scan
aggregate. Classification JSON v2 does not emit the candidate's raw timestamp
or scan-time identity; it emits the existing finding states and explanations
and continues to use the single `referenceUnixSeconds` value. The deferred
array does not alter the activity finding: npm activity remains explicitly
unknown, and the pending condition is not an attestation or authorization.

Every classification integer that can exceed a portable JSON integer range is
encoded as a decimal string. Nullable fields are emitted explicitly as JSON
`null`, and the document ends with exactly one newline. Keys and decisions are
deterministic. The selected absolute root is omitted, but relative names,
sizes, tool attribution, findings, and the reference time remain sensitive.

A shortened synthetic decision has this shape:

```json
{
  "schema": "devsift.classification",
  "schemaVersion": 2,
  "pathStyle": "root-relative",
  "catalog": {
    "identifier": "devsift.builtin-rules",
    "version": "6",
    "ruleCount": "6"
  },
  "referenceUnixSeconds": "1700000000",
  "scanIsComplete": true,
  "scanIntegrity": {
    "isComplete": true,
    "rootIsComplete": true,
    "topLevelItemCount": "1",
    "retainedTopLevelItemCount": "1"
  },
  "decisions": [
    {
      "path": {
        "display": "uv",
        "rawComponentsBase64": ["dXY="]
      },
      "ruleRevision": {
        "identifier": "devsift.cache.uv",
        "version": "1"
      },
      "matchState": "possible-match",
      "disposition": "protected",
      "deferredExecutionPreconditions": []
    }
  ]
}
```

The `scanIntegrity` object and decision above are shortened, and the excerpt
omits other required v2 keys for readability. It is not a complete schema
fixture. Tests assert the exact key sets and round-trip the full DTO.

## Cleanup manifest review JSON schema version 2 (internal only)

The CLI target owns an internal one-way JSON projection for a future manifest
review surface. It is not reachable from `CLIArguments` or `CLIApplication`, so
there is currently no `devsift` command, standard-output path, or file-writing
operation for it. It does not change the usage or exit-code contract above.

The projection accepts only Core cleanup manifest contract version 3 and emits
schema `devsift.cleanup-manifest-review` version 2. Its DTOs conform to
`Encodable`, not `Decodable`; Core `CleanupManifest` and its entries remain
non-`Codable`. The resulting JSON is deliberately lossy and cannot recreate a
Core manifest. It also cannot serve as an input to `CleanupManifestDiffer`, an
approval operation, or an executor. The envelope says `importSupported: false`,
`canBeApproved: false`, `canBeExecuted: false`, and `executionAuthority: none`.
There is no manifest-diff review schema in this increment.

Every projected entry always has a sorted `deferredExecutionPreconditions`
array. Each element contains the fixed policy `identifier` and decimal-string
`policyRevision`; an empty array is encoded explicitly. Both privacy profiles
include these fields so a pending execution condition cannot disappear through
redaction. They are review disclosure only and cannot represent the current
Core `CleanupQuarantineUserAttestation` or
`CleanupQuarantineAuthorization`.

Core's current approval boundary instead prepares an opaque review session from
the exact source-bound planning request. The session owns its exact root and
Core-built manifest and issues process-local entry and pending-precondition
references that this lossy document cannot reconstruct. The CLI does not expose
an approval, review-acknowledgement, attestation, or authorization command and
retains none of that state.

Core authorization contract version 1 now provides a separate process-local
API over one exact approval and one explicit caller assertion. It is not a CLI
schema or command: neither classification JSON nor manifest-review JSON can
construct its attempt-bound request, attestation, shared single-use state, or
internal executor handoff. It grants no standalone mutation authority, and no
executor exists. See the [authorization contract](AUTHORIZATION.md).

Every invocation requires one explicit privacy profile:

- `redacted` omits the root-relative path, classification reference time,
  display name, responsible-tool text, classification explanation, finding
  explanations, and unselected policy-rule revisions. It substitutes a
  canonical `candidate-00001`-style ordinal for each entry. It still includes
  exact observed sizes and uncertainty counts, classification and catalog
  identifiers, each selected rule revision, every selected finding's identifier,
  kind, and state, and every fixed deferred-precondition identifier and policy
  revision. Those values can reveal tools, policy, storage volume, and work
  patterns. Redacted output is neither anonymous nor automatically safe to
  share.
- `root-relative-exact` includes a terminal-safe display path, every exact raw
  path component as Base64, the exact classification reference time, escaped
  display and responsible-tool text, escaped classification and finding
  explanations, and the complete policy rule-revision roster. This profile is
  sensitive and requires inspection before any future export action.

The document-local candidate ordinal follows the manifest's canonical raw-path
order. It has no meaning outside that one document, is not stable identity
across two documents, and must not be used to infer a rename or authorize an
operation.

Neither profile has a dedicated absolute-root field or emits the manifest's
root or candidate `(device, inode)` values. This structural omission does not
sanitize arbitrary text supplied by trusted custom rules: in the exact profile,
a display name, tool label, or explanation could itself contain an absolute
path or other sensitive text. The redacted profile omits those free-form
fields, but retains the identifiers and quantities described above.

All potentially wide integers, including the source manifest contract version,
rule versions, timestamps, counts, and byte quantities, are decimal strings.
Output keys and entry order are deterministic and the encoder appends exactly
one newline. Repeated encoding of the same validated manifest and profile is
intended to produce the same bytes within the same implementation build and
Swift/Foundation runtime. `JSONEncoder` output is not a cryptographic canonical
form, stable content digest, signature, authenticity proof, or approval token;
consumers must not compare its bytes for security decisions.

The encoder validates the version-3 manifest and bounded entry invariants
before projection. It performs a per-entry encoded-size preflight and repeats a
post-encode check against a hard 128 MiB limit. Cancellation is checked during
validation, projection, and the per-entry preflight. A single Foundation
`JSONEncoder.encode` call is not cooperatively interruptible, so cancellation
requested during the final bounded encode is observed only after that call
returns. No partial JSON document is returned.

Version-1 review exports and source-manifest-version-2 material have no import
or migration path. Regenerate them from a current classification and manifest;
never synthesize a missing pending condition while decoding old data.

## Exit codes

| Code | Meaning | Output contract |
| ---: | --- | --- |
| `0` | Complete scan, complete classification, or successful informational command | Result on stdout |
| `2` | Valid report derived from an incomplete scan | Report on stdout; warning on stderr |
| `64` | Command or option usage error | Diagnostic and short usage on stderr |
| `65` | Invalid root type, including a file or root symlink | Diagnostic on stderr |
| `66` | Selected root does not exist | Diagnostic on stderr |
| `70` | Unexpected scanner, classifier, or encoding error | Generic diagnostic on stderr |
| `74` | Root I/O failure | Diagnostic on stderr |
| `75` | Root changed during validation; retry may succeed | Diagnostic on stderr |
| `77` | Root permission denied | Diagnostic on stderr |
| `130` | Cooperative cancellation or shell-conventional `SIGINT` status | No report |

The process keeps the operating system's default signal handling in this
milestone. Shells commonly report `143` for `SIGTERM`. Core cancellation is
checked between directory entries, but an individual blocking filesystem call
is not interruptible by Swift task cancellation.
