# Release contract

This document defines how DevSift pre-release binaries are versioned, built,
checked, and published. Distribution must not expand the product authority
described by the safety contracts.

## Current target

The first distribution target is `v0.3.0-alpha.1`.

The release contains one command-line archive for macOS. The SwiftUI executable
remains available only as source because DevSift does not yet have a reviewed
application-bundle, entitlement, Developer ID signing, or notarization process.

The shipped CLI remains read-only. Core-internal npm quarantine and manual
restore kernels are not public API and are not reachable from the archive's
commands.

## Version authority

`VERSION` contains the exact product version without a leading `v`. For a
release, all of the following must agree:

- the single line in `VERSION`;
- `DevSiftStatus.current.version`;
- the CLI's `devsift --version` output;
- the matching dated `CHANGELOG.md` heading;
- the Git tag formed by prefixing the version with `v`.

Product versions are semantic pre-release identifiers. They are independent of
the classifier, manifest, report, authorization, and journal wire-contract
versions. Changing a product version does not migrate or reinterpret those
contracts.

Release metadata validation accepts the current alpha tag shape only and fails
closed on extra lines, missing files, placeholder development versions, or any
disagreement.

## CLI artifact

The release archive name is:

```text
devsift-0.3.0-alpha.1-macos-universal.tar.gz
```

It contains exactly one top-level directory with these entries:

```text
devsift-0.3.0-alpha.1-macos-universal/
devsift-0.3.0-alpha.1-macos-universal/LICENSE
devsift-0.3.0-alpha.1-macos-universal/RELEASE_NOTES.md
devsift-0.3.0-alpha.1-macos-universal/VERSION
devsift-0.3.0-alpha.1-macos-universal/devsift
```

The executable must be a Mach-O universal binary with exactly `arm64` and
`x86_64` slices, must report the release version, and must pass its read-only
status smoke test before packaging. The package's declared deployment floor is
macOS 14.

The tag workflow builds on an `arm64` macOS 15 runner and fails unless it is
using Xcode 16.4 build 16F6, the macOS 15.5 SDK, and Apple Swift 6.1.2 from that
Xcode installation. Reproducibility means independent builds with those same
declared toolchain inputs produce byte-identical archives; the hosted runner
image itself is not claimed to be a timeless or content-addressed input.

Packaging starts from a fresh temporary staging directory. It refuses to
replace an existing archive or checksum file, disables macOS AppleDouble sidecar
creation, and validates the archive membership against the fixed allowlist.
It fixes the archive locale, timezone, ownership, modes, and timestamps, then
checks that independent builds made from different caller timezones are
byte-for-byte identical.
The bundled release notes are self-contained and use tag-pinned links rather
than repository-relative documentation links.
It does not include build directories, debug symbols, source paths, scan data,
credentials, signing material, quarantine journals, or any other local file.

## Integrity and provenance

Each release includes `SHA256SUMS` for transport-integrity checking. A checksum
detects corruption or a mismatched download; by itself it does not establish who
built the artifact.

The tag workflow also asks GitHub's official attestation action to create build
provenance for the exact archive. Consumers can verify both controls after
downloading the two release assets:

```shell
shasum -a 256 -c SHA256SUMS
gh attestation verify \
  devsift-0.3.0-alpha.1-macos-universal.tar.gz \
  --repo jxewonkim/devsift \
  --signer-workflow jxewonkim/devsift/.github/workflows/release.yml \
  --source-ref refs/tags/v0.3.0-alpha.1 \
  --deny-self-hosted-runners
```

Workflow actions are pinned to full commit hashes. Repository contents are
read-only by default. The tag workflow separates unprivileged build and native
smoke-test jobs from its publish job. The extracted final archive runs natively
on macOS 14 `arm64` and macOS 15 `x86_64` before publication. Only the publish
job receives `contents: write`, `id-token: write`, and `attestations: write`; it
executes no repository scripts or release binary with those permissions.

## Signing boundary

The first archive is not Developer ID signed and is not Apple notarized. The
packager explicitly applies an ad-hoc signature to the final universal
executable and validates both slices. That signature protects file integrity;
it is not a publisher identity and must not be described as one. Gatekeeper or
local security policy may therefore require an explicit user decision before
running the binary.

DevSift does not recommend disabling Gatekeeper globally and does not publish a
`curl | sh` installer. Developer ID signing, notarization, a `.pkg`, a Homebrew
formula, auto-update, and SwiftUI `.app` distribution require later, separately
reviewed work.

## Publication gate

Before creating the tag:

1. Merge the release pull request into `main` after required CI succeeds.
2. Confirm the repository allows only reviewed GitHub-owned actions pinned to
   full commit hashes, protects `v*` tags from update or deletion, protects the
   `release` environment, and has immutable releases enabled.
3. Confirm the local tree is clean and synchronized with `origin/main`.
4. Run release metadata verification and a local packaging dry run.
5. Confirm the merge commit's normal `main` CI succeeds.
6. Create one annotated tag on that exact merge commit and push only that tag.

The tag workflow checks out the tagged commit without retaining Git credentials,
validates that the tag and source version agree, runs strict formatting and the
complete test suite, builds and inspects the universal archive, verifies its
checksum and every handoff digest, executes both native slices on their target
runner families, creates provenance, and only then creates a draft. It verifies
the uploaded asset bytes, exact asset inventory, and tag-to-main binding again
immediately before publishing the GitHub pre-release.

Published tags are immutable source identities. If an artifact is wrong or must
be withdrawn, record the problem and publish a new incremented pre-release. Do
not move an existing public tag to different source.

## Explicit non-goals

This phase adds no new scan root, filesystem permission, network behavior in the
CLI, telemetry, background service, privileged helper, cleanup command, restore
command, purge, deletion, automatic app-launch recovery, or frontend mutation
action. See the [safety model](SAFETY.md), [privacy contract](PRIVACY.md), [quarantine
contract](QUARANTINE.md), and [manual restore contract](RESTORE.md).
