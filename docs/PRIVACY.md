# Privacy contract

DevSift is designed to work locally and reveal as little as possible.

## Current contract

- No telemetry or analytics.
- No account requirement.
- No upload of paths, metadata, scan results, or cleanup plans.
- No network access required for scanning.
- No background or automatic scanning.
- No scan outside roots explicitly selected by the user.
- Scanning reads POSIX inode modification times but retains only one maximum
  aggregate per root or top-level summary, not a timestamp for every
  descendant. It does not read file contents.
- The app does not scan before the folder picker returns an explicit selection,
  automatically rescan a previous folder, or persist a recent-folder list.
- The app does not save or upload reports. It displays root-relative item paths
  and keeps the selected absolute root only in the current in-memory window
  state.
- Classification runs locally. Its bounded evidence stage may reopen the
  selected root and retained top-level candidates descriptor-relatively to
  verify scan-time identity. For an exact `.build` candidate, it may also
  inspect metadata for an exact `workspace-state.json` child. For an exact npm
  `_cacache`, it may enumerate direct-child names through EOF or the first entry
  over a 256 non-dot-entry limit, and inspect the metadata of exact `content-v2`
  and `index-v5` entries. For exact uv, npm, and Homebrew default cache
  candidates, it may resolve the current account home and rewalk the matching
  container without following symbolic links. It does not read file contents,
  invoke package managers, or make network calls.
- Core draft planning runs only over already constructed scan and
  classification values. It performs no filesystem or network I/O, stores no
  absolute root URL, and is not exposed by the CLI. The native app can invoke
  it only for an explicitly selected, current-session in-memory review.
- The app includes zero draft candidates by default, accepts only exact raw
  path-and-rule-revision values from the current result's conservative
  whitelist, and retains the exact source classification request and report
  only for that in-memory session. Draft preparation performs no filesystem or
  network I/O.
- Core approval review sessions retain one exact source-bound planning request,
  including its absolute root URL, complete scan and classification reports,
  source binding, and selections, together with the Core-built manifest and
  process-local entry references. A final approval itself retains the exact
  root and manifest, but not that larger source request. These values are
  non-`Codable`, perform no filesystem or network I/O, and are not invoked by
  either frontend. No session or approval is persisted, logged, uploaded,
  imported, or exported. Non-`Codable` does not prevent in-memory copying or
  provide confidentiality.
- The CLI target contains an internal one-way manifest-review JSON encoder, but
  no command invokes it and it does not write standard output or a file. No
  manifest importer, persistence path, upload, or background export exists.

## Sensitive output

File paths can expose usernames, client names, repository names, installed
software, and personal interests. Sizes and timestamps can reveal work habits.
For that reason, scan reports and cleanup plans are sensitive even when they do
not include file contents.

DevSift will prefer redacted or root-relative display where practical. Exported
reports must be explicit user actions and should support privacy-preserving
output. Real reports must not be committed as examples or test fixtures.

The scan CLI emits only root-relative report paths and does not repeat the
selected absolute root in text or JSON. JSON retains exact relative filename
bytes as Base64, so reports can still reveal sensitive names and must be
reviewed before sharing. Redirecting standard output is the explicit export
action; DevSift never writes a report file on its own.

Classification output is also root-relative, but adds tool attribution, rule
identifiers, evidence findings, policy results, and one captured reference
timestamp. These details may reveal installed tools and work patterns and must
be reviewed before sharing. The current scan and classification JSON schemas do
not expose a candidate's raw modification-time aggregate or scan-time identity;
classification emits only the resulting findings and its reference timestamp.

The classifier retains a non-public seal containing its exact source request
and policy provenance inside the in-memory Core report so planning cannot mix
one scan's evidence with another scan's identities, sizes, or edited policy
metadata. That binding includes the selected root URL. It is not part of CLI or
app output, is not Codable or exported, and must be discarded with the current
analysis session; access control does not make it non-sensitive.

An in-memory draft manifest contains exact root-relative raw path components,
root and candidate identities, observed allocation estimates, rule revisions,
policy evidence, and bounded classifier/catalog provenance. A manifest diff can
combine two such snapshots and expose both sides of added, removed, or modified
entries, so it is at least as sensitive as either input. Those values remain
sensitive even without an absolute root URL. Core manifests and diffs remain
non-`Codable`, unpersisted, unlogged, and unuploaded, and no CLI or app command
imports or exports them. Diffing does not copy the root URL or complete rule
definitions, and no diff-export projection exists.

An in-memory approval review session contains the exact planning source request,
including its absolute root URL, complete `ScanReport`, classification report
and source binding, and selections, plus the reviewed manifest. It can therefore
retain raw paths, identities, sizes, timestamps, and policy evidence for
unselected items and is more sensitive than the manifest alone. Its entry
references and confirmations repeat canonical ordinals, exact raw paths, and
rule revisions and carry an opaque process-local session binding. They are
validation input, not a redacted review format, stable identifier, digest,
signature, secret, or anonymous identifier. Partial approval is unsupported;
changing the subset requires a new planning request and review session rather
than copying old intent.

The final approval itself does not retain the larger source request; it retains
its exact root and manifest. Callers can still copy the session, source request,
references, confirmations, and approval, and must discard every copy when the
analysis session ends. These values remain non-`Codable`, unpersisted,
unlogged, and unuploaded, and neither frontend currently creates one.
Non-`Codable` supplies no encryption, zeroization, confidentiality, or copy
prevention.

A revalidation report retains the observed root identity, policy provenance,
reference time, and canonical root-relative entry statuses, but deliberately
omits the absolute root URL. It is non-`Codable`, in-memory, copyable, and not
created by either frontend. It is not persisted, logged, uploaded, imported, or
exported. Omitting the root URL does not make raw relative paths, rule revisions,
findings, or policy results non-sensitive.

Trusted-location observation resolves the current account home from the local
operating-system account record and compares only bounded raw path components
and directory metadata. It does not use the `$HOME` environment variable,
enumerate the home directory, read cache contents, retain the home path in a
report, or add it to CLI or app output. The selected root and account-home path
still remain sensitive in process memory while that observation runs.

The native app immediately maps a planned manifest to a separate identity-free
presentation and does not retain the manifest. The presentation omits root and
candidate filesystem identities, the source request and report, reference time,
policy-provenance roster, Base64 path serialization, and authority state. It
keeps an exact raw root-relative path only as the in-memory row identifier and
renders an escaped display form. The review still contains sensitive relative
names, display names, tool attribution, rule and finding identifiers, free-form
explanations, and all seven exact observed size and uncertainty quantities. It
is not anonymized or automatically safe to share, even though the app provides
no save, copy-as-manifest, import, export, or upload workflow.

The internal CLI review schema is a separate lossy projection pinned to Core
manifest contract version 2. Both profiles omit root and candidate filesystem
identities and contain no dedicated absolute-root field. They explicitly say
that import, approval, and execution are unsupported. This does not make the
documents non-sensitive:

- The redacted profile omits every path, the reference time, free-form text,
  and the complete rule roster. It retains exact observed sizes and totals plus
  the selected rule and finding identifiers, which can still reveal tools,
  policy choices, and work patterns. It is neither anonymous nor automatically
  safe to share.
- The root-relative-exact profile includes exact raw path components as Base64,
  an escaped display path, the exact reference time, escaped display names,
  tool attribution, classification explanations, finding explanations, and the
  complete provenance roster. Escaping prevents terminal control effects; it
  does not redact the text.

Redacted ordinals identify entries only inside one review document; they are
not stable cross-document identifiers. Although neither profile has a
dedicated root field, trusted custom-rule free-form text can contain an
arbitrary absolute path. The encoder enforces a 128 MiB preflight and
post-encoding limit, which bounds output size but does not lower its
sensitivity.

The app displays the selected root path from the active window state so the user
can verify scope, then shows top-level rows as root-relative names. Draft-table
focus and explicit inclusion are separate, and inclusion starts empty. A new
scan or root discards draft state; closing the window cancels active work and
discards its in-memory selection, report, and review. Operation tokens prevent a
late cancelled or superseded planner result from restoring discarded state. The
opt-in developer snapshot harness uses only synthetic paths and is never run
automatically by the application.

## Future changes

A future user-facing plan export must explicitly select a privacy profile and
must not silently turn the internal encoder into automatic persistence. Any
future importer requires its own untrusted-input bounds and authenticity model;
the current schema is one-way and cannot be imported. Review documents continue
to omit filesystem identities, and the current app presentation must not be
treated as a wire format or approval input. Future execution-time revalidation
must receive only the in-memory Core approval and use its retained root without
turning either into automatic persistence. A revalidation report must never be
used as an execution input or mutation capability. Any future execution
document must decide its identity and authority fields in a separate security
review. Adding these features must not silently make Core domain models
`Codable`.

Any feature that introduces networking, update checks, telemetry, crash upload,
or third-party services must be documented before release, disabled by default
unless essential, and reviewed as a separate privacy change. Local scanning and
cleanup must remain usable without an account.
