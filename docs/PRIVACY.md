# Privacy contract

DevSift is designed to work locally and reveal as little as possible.

## Current contract

- No telemetry or analytics.
- No account requirement.
- No upload of paths, metadata, scan results, or cleanup plans.
- No network access required for scanning.
- No background or automatic scanning.
- No scan outside roots explicitly selected by the user.

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

## Future changes

Any feature that introduces networking, update checks, telemetry, crash upload,
or third-party services must be documented before release, disabled by default
unless essential, and reviewed as a separate privacy change. Local scanning and
cleanup must remain usable without an account.
