# Contributing to DevSift

Thank you for helping build a safer storage tool for macOS developers.

## Before you start

- Read the [product scope](docs/PRODUCT.md),
  [safety model](docs/SAFETY.md), and [rules contract](docs/RULES.md).
- Open an issue before starting a large feature or a change to cleanup safety.
- Never attach a real scan report without redacting usernames, paths, project
  names, file names, and other private metadata.
- Follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Workflow

1. Create a short-lived branch from `main`.
2. Keep commits small and use Conventional Commits, for example
   `feat(core): add allocated-size scanning`.
3. Add or update tests with behavior changes.
4. Run formatting, build, and tests locally.
5. Open a pull request describing behavior, safety impact, and verification.

`main` must remain buildable and testable. Do not force-push public shared
branches.

## Filesystem-test rules

Filesystem behavior is security-sensitive. Tests must:

- create all fixtures under a fresh temporary directory;
- use synthetic names and contents;
- avoid a contributor's home directory and real application data;
- verify that paths outside the fixture are unchanged;
- cover symlinks, missing files, permission failures, cancellation, and path
  containment where relevant.

No test may invoke a real cleanup command against `/`, `/Users`, a home
directory, `/Applications`, or another broad path.

CLI integration tests execute the built `devsift` binary directly, never
through a shell, and may scan only their own synthetic temporary fixture. Text
goldens and the versioned JSON DTO must be updated deliberately when a visible
output contract changes.

Rule tests must cover exact raw-byte matches, near misses, hostile names,
missing and failed evidence, common scan-integrity guards, boundary ages,
activity, conflicts, and deterministic ordering. Do not weaken `Protected`
fallback behavior to make a fixture pass.

Modification-time evidence tests must cover the newest descendant, an empty
directory's own inode, symbolic-link inode inclusion without target traversal,
conservative subsecond rounding, invalid metadata, incomplete summaries,
future clock skew, and an age-satisfied result that still remains `Protected`
when another required fact is unavailable.

Descriptor evidence tests must use synthetic roots and cover missing or wrong-
kind markers, symbolic-link non-following, identity replacement, bounded
failure, and cancellation. A satisfied marker must still remain `Protected`
while another required fact is unavailable. Treat `scanTimeIdentity` only as a
read-only observation-binding token; tests must never use it as cleanup or
deletion authority.

## Privacy and secrets

Do not commit scan reports, cleanup manifests from real machines, absolute home
paths, logs containing file names, `.env` files, credentials, certificates,
private keys, or signing material. Use synthetic fixtures for documentation and
tests.

Security vulnerabilities should be reported privately as described in
[SECURITY.md](SECURITY.md).
