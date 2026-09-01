# Security Policy

DevSift inspects filesystem metadata and is intended to eventually move or
remove files, so safety and security defects are treated as high priority.

## Supported versions

DevSift is pre-alpha. Until the first stable release, only the latest commit on
`main` and the latest published pre-release are supported.

## Reporting a vulnerability

Do not open a public issue for a vulnerability that could cause data loss,
escape a selected scan root, expose private paths, execute unintended commands,
or bypass a safety check.

Use GitHub's **Report a vulnerability** flow in the repository's Security tab.
Include the smallest synthetic reproduction possible and avoid real user paths,
scan reports, secrets, or personal data.

The maintainers will acknowledge a report as soon as practical, investigate it
privately, and coordinate disclosure after a fix is available. If private
reporting is temporarily unavailable, open a public issue containing only a
request for a private contact channel and no vulnerability details.
