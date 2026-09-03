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
  inspect metadata for an exact `workspace-state.json` child. It does not read
  file contents, follow symbolic-link targets, invoke package managers, or make
  network calls.
- Core draft planning runs only over already constructed scan and
  classification values. It performs no filesystem or network I/O, stores no
  absolute root URL, and is not exposed by the CLI or app.
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

The app displays the selected root path so the user can verify scope, then shows
top-level rows as root-relative names. Closing the window discards its in-memory
selection and report. The opt-in developer snapshot harness uses only synthetic
paths and is never run automatically by the application.

## Future changes

A future user-facing plan export must explicitly select a privacy profile and
must not silently turn the internal encoder into automatic persistence. Any
future importer requires its own untrusted-input bounds and authenticity model;
the current schema is one-way and cannot be imported. Review documents continue
to omit filesystem identities, and any future execution document must decide
its identity and authority fields in a separate security review. Adding these
features must not silently make Core domain models `Codable`.

Any feature that introduces networking, update checks, telemetry, crash upload,
or third-party services must be documented before release, disabled by default
unless essential, and reviewed as a separate privacy change. Local scanning and
cleanup must remain usable without an account.
