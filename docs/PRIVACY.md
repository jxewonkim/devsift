# Privacy contract

DevSift is designed to work locally and reveal as little as possible.

## Current contract

- No telemetry or analytics.
- No account requirement.
- No upload of paths, metadata, scan results, or cleanup plans.
- No network access required for scanning.
- No background or automatic scanning.
- No scan outside roots explicitly selected by the user.
- The app does not scan before the folder picker returns an explicit selection,
  automatically rescan a previous folder, or persist a recent-folder list.
- The app does not save or upload reports. It displays root-relative item paths
  and keeps the selected absolute root only in the current in-memory window
  state.
- Classification runs locally over in-memory scan observations. It does not
  reopen files, read contents, invoke package managers, or make network calls.

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
be reviewed before sharing.

The app displays the selected root path so the user can verify scope, then shows
top-level rows as root-relative names. Closing the window discards its in-memory
selection and report. The opt-in developer snapshot harness uses only synthetic
paths and is never run automatically by the application.

## Future changes

Any feature that introduces networking, update checks, telemetry, crash upload,
or third-party services must be documented before release, disabled by default
unless essential, and reviewed as a separate privacy change. Local scanning and
cleanup must remain usable without an account.
