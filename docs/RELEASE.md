# Release contract

This document defines how DevSift pre-release binaries are versioned, built,
checked, signed, notarized, and published. Distribution must not expand the
product authority described by the safety contracts.

## Current status and target

The next candidate is `v0.3.0-alpha.2`. The immutable
`v0.3.0-alpha.1` source tag failed before publishing any GitHub Release and must
never be moved or reused.

The local universal-app packager and the guarded GitHub signing pipeline are
implemented, but no signed app has been published. The live credentials and
release-only gates must be independently verified before every publication.
The current implementation-review snapshot is recorded in the
[native app distribution security review](APP_RELEASE_SECURITY_REVIEW.md). Do
not describe a local ad-hoc build as an official download.

While the candidate is unpublished, its changes stay under `Unreleased` in
`CHANGELOG.md` and its release notes identify themselves as a candidate. The
final pre-tag commit must add the dated `0.3.0-alpha.2` changelog heading and
convert the candidate note to final release wording. Until then, tag metadata
verification intentionally fails closed.

A completed candidate release contains exactly these four assets:

```text
DevSift-0.3.0-alpha.2-macos-universal.zip
DevSift-0.3.0-alpha.2-macos-universal.zip.sha256
SHA256SUMS
devsift-0.3.0-alpha.2-macos-universal.tar.gz
```

The app ZIP contains a Developer ID-signed app accepted by Apple notarization
with its ticket stapled. The CLI archive remains explicitly read-only and
ad-hoc signed.

## Version authority

`VERSION` contains the exact semantic pre-release version without a leading
`v`. For a release, all of the following must agree:

- the single line in `VERSION`;
- `DevSiftStatus.current.version`;
- the CLI's `devsift --version` output;
- the matching dated `CHANGELOG.md` heading;
- the release-notes file at `docs/releases/v<VERSION>.md`;
- the annotated Git tag formed by prefixing the version with `v`.

`APP_BUILD_NUMBER` is a separate positive decimal integer used as the app's
`CFBundleVersion`. It must increase for each app release and is never derived by
resetting a semantic-version prerelease counter. `CFBundleShortVersionString`
is the numeric release core (`0.3.0`), while `DevSiftReleaseVersion` preserves
the complete `0.3.0-alpha.2` value inside `Info.plist`.

Product and app-build versions are independent of classifier, manifest,
report, authorization, and journal wire-contract versions. Changing them does
not migrate or reinterpret those contracts. Metadata validation rejects extra
lines, symbolic links, noncanonical values, placeholders, or disagreement.

## Native app artifact

The final ZIP contains one fixed bundle:

```text
DevSift.app/
DevSift.app/Contents/
DevSift.app/Contents/CodeResources
DevSift.app/Contents/Info.plist
DevSift.app/Contents/MacOS/
DevSift.app/Contents/MacOS/DevSift
DevSift.app/Contents/Resources/
DevSift.app/Contents/Resources/LICENSE
DevSift.app/Contents/Resources/VERSION
DevSift.app/Contents/_CodeSignature/
DevSift.app/Contents/_CodeSignature/CodeResources
```

`Contents/CodeResources` is the stapled notarization ticket and exists only in
the final release bundle. The bundle identifier is
`io.github.jxewonkim.devsift`. The executable has exactly `arm64` and `x86_64`
slices, targets macOS 14.0, contains no unsafe build rpath or local source path,
and links only system dependencies.

The app enables the hardened runtime. Its reviewed entitlement file is an empty
dictionary: it requests no sandbox, debugging, JIT, unsigned-memory, library-
validation, automation, camera, microphone, location, contacts, calendar, or
photos capability. Omitting App Sandbox preserves the same ordinary-user
filesystem authority as `swift run DevSiftApp`; it does not grant root or Full
Disk Access. User folder selection still goes through the native picker and
Core's descriptor-bound validation. The fixed npm mutation workflow retains all
of its existing confirmation and macOS 26 admission gates.

Create and independently reproduce a local candidate with:

```shell
scripts/release/verify-app-reproducibility.sh \
  /private/tmp/devsift-app-candidate
```

The local output contains `DevSift.app`, its ZIP, and `SHA256SUMS`. It is
ad-hoc signed with hardened runtime and is for development verification only.
Use a fresh nonexistent output path, and delete that output after verification
so local release checks do not accumulate storage.
The verifier has three explicit lifecycle modes:

- `adhoc`: requires an ad-hoc signature, hardened runtime, empty entitlements,
  and no ticket or team identity;
- `signed`: requires the pinned Developer ID team, secure timestamp, hardened
  runtime, empty entitlements, and no ticket before notarization;
- `release`: adds stapler validation and a Gatekeeper result of
  `Notarized Developer ID` after notarization.

The app ZIP fixes its tree, modes, timestamps, locale, timezone, and metadata.
Two independent ad-hoc builds must be byte-identical. Developer ID timestamps
and Apple tickets intentionally make final signed archives non-reproducible by
digest; the workflow instead applies the same fixed structural inspection,
records a checksum, and binds the exact final bytes to GitHub provenance.

## CLI artifact

The CLI archive contains exactly:

```text
devsift-0.3.0-alpha.2-macos-universal/
devsift-0.3.0-alpha.2-macos-universal/LICENSE
devsift-0.3.0-alpha.2-macos-universal/RELEASE_NOTES.md
devsift-0.3.0-alpha.2-macos-universal/VERSION
devsift-0.3.0-alpha.2-macos-universal/devsift
```

Its executable has exactly `arm64` and `x86_64` slices, reports the release
version, passes the scan-only status smoke test, and targets macOS 14. The tag
workflow builds on an arm64 macOS 15 runner with Xcode 16.4 build 16F6, the
macOS 15.5 SDK, and Apple Swift 6.1.2. Independent CLI builds with those inputs
must produce byte-identical archives.

The archive contains no build directory, debug symbol, source path, scan data,
credential, signing material, quarantine journal, or local user file.

## Signing and notarization credentials

The public publisher Team ID is pinned in the reviewed workflow as
`VN6283SM8B`; an environment variable cannot redefine the verifier's trust
root. The protected GitHub `release` environment must contain these secrets:

- `DEVSIFT_DEVELOPER_ID_CERTIFICATE_BASE64` — exported Developer ID Application
  certificate and private key in base64-encoded PKCS #12 form;
- `DEVSIFT_DEVELOPER_ID_CERTIFICATE_PASSWORD` — password for that PKCS #12;
- `DEVSIFT_NOTARY_KEY_BASE64` — base64-encoded App Store Connect API `.p8` key;
- `DEVSIFT_NOTARY_KEY_ID` — API key identifier;
- `DEVSIFT_NOTARY_ISSUER_ID` — API issuer UUID.

Secret values, `.p12`, and `.p8` files must never enter the repository or a
workflow artifact. The signing job exposes each secret only to the step that
needs it. It imports exactly one matching Developer ID Application identity
into an ephemeral keychain made available to `codesign`, removes that keychain
before exposing the notarization key, and performs best-effort cleanup of every
raw credential even if an earlier cleanup action fails.

Apple requires Developer ID signing, hardened runtime, and a secure timestamp
before notarization. The workflow submits the pre-staple ZIP with
`xcrun notarytool`, requires `Accepted`, downloads the notarization log and
requires zero issues, staples the app rather than the ZIP, and then creates a
new ZIP containing the stapled app.

## Two-stage publication workflow

Publication deliberately has two stages so no public release exists before the
notarized app passes its native launch gates.

1. Pushing a new annotated `v*-alpha.*` tag starts
   `.github/workflows/release.yml`. It binds the tag to the exact `main` tip,
   re-runs formatting, builds, tests, CLI reproducibility, and native arm64 and
   x86_64 smoke tests, creates CLI provenance, and leaves an exact two-asset
   draft pre-release.
2. An operator selects that same tag in the Actions ref picker and dispatches
   `.github/workflows/release-app.yml` with the identical `release_tag` input.
   The workflow refuses `v0.3.0-alpha.1`, a lightweight tag, a non-main commit,
   a missing successful main CI run, a missing successful CLI release run, a
   published release, unexpected draft assets, or mismatched metadata.
3. The app workflow re-runs the complete Swift test suite and independent local
   app reproducibility check before entering the protected `release`
   environment. It then signs, notarizes, staples, and strictly verifies the
   bundle.
4. Fresh macOS 14 arm64 and macOS 15 x86_64 runners download the exact final
   handoff, verify both digests and the notarized bundle, install it into a new
   temporary Applications directory, launch it, and require the process to stay
   alive.
5. The final job creates provenance for the app archive, uploads only the two
   exact app assets to the still-hidden draft, downloads all four assets again,
   verifies both checksum files, verifies the CLI archive's original
   `release.yml` attestation, compares the draft title and body with tag-pinned
   release notes, rebinds the tag to `main`, and only then publishes.

The manual dispatch command is:

```shell
gh workflow run release-app.yml \
  --repo jxewonkim/devsift \
  --ref v0.3.0-alpha.2 \
  -f release_tag=v0.3.0-alpha.2
```

Dispatch only after the tag workflow has successfully created the draft and an
authorized reviewer is available. Review and approve the protected `release`
environment deployment when GitHub pauses the running workflow at that gate.

## Consumer verification

Download all four assets into one directory. Verify transport integrity:

```shell
shasum -a 256 -c SHA256SUMS
shasum -a 256 -c DevSift-0.3.0-alpha.2-macos-universal.zip.sha256
```

Verify GitHub provenance:

```shell
gh attestation verify \
  devsift-0.3.0-alpha.2-macos-universal.tar.gz \
  --repo jxewonkim/devsift \
  --signer-workflow jxewonkim/devsift/.github/workflows/release.yml \
  --source-ref refs/tags/v0.3.0-alpha.2 \
  --deny-self-hosted-runners

gh attestation verify \
  DevSift-0.3.0-alpha.2-macos-universal.zip \
  --repo jxewonkim/devsift \
  --signer-workflow jxewonkim/devsift/.github/workflows/release-app.yml \
  --source-ref refs/tags/v0.3.0-alpha.2 \
  --deny-self-hosted-runners
```

After extracting the app, verify Apple's controls:

```shell
codesign --verify --all-architectures --strict --verbose=2 DevSift.app
xcrun stapler validate -v DevSift.app
spctl --assess --type execute --verbose=4 DevSift.app
```

A checksum detects corruption or the wrong file. The Developer ID signature
identifies the publisher. Notarization and its stapled ticket record Apple's
acceptance of the submitted bytes after automated checks; they are not an
endorsement or a complete security audit. GitHub attestation binds an exact
archive digest to its source ref and workflow.

## Publication gate

Before creating the tag:

1. Merge the release pull request into `main` after required CI succeeds.
2. Confirm the repository allows only reviewed GitHub-owned actions pinned to
   full commit hashes, protects `v*` tags from update or deletion, protects the
   `release` environment, and has immutable releases enabled.
3. Provision the exact Developer ID and notarization secrets above and require
   an authorized environment reviewer.
4. Confirm `VERSION`, `APP_BUILD_NUMBER`, Core status, changelog, and release
   notes agree; increment both release identities as required.
5. Confirm the local tree is clean and synchronized with `origin/main`.
6. Run metadata validation plus CLI and app reproducibility checks locally.
7. Confirm the merge commit's normal `main` CI succeeds.
8. Create one annotated new tag on that exact merge commit and push only that
   tag. Never reuse or move `v0.3.0-alpha.1` or another published tag.
9. Let the CLI workflow create its draft, then manually dispatch the app
   workflow at the identical tag and ref.

If any gate fails, keep the release hidden. Correct source or configuration and
use a new incremented candidate when the source identity must change. Never
replace a published tag or silently substitute published artifact bytes.

## Explicit non-goals

Distribution adds no new scan root, root privilege, Full Disk Access request,
public-Core or CLI mutation API, updater, installer, Homebrew tap, telemetry,
account, network dependency, background agent, scheduled cleanup, retention,
batch action, automatic launch-time work, or secure-erase claim. See the
[app contract](APP.md), [safety model](SAFETY.md),
[privacy contract](PRIVACY.md), [quarantine contract](QUARANTINE.md),
[manual restore contract](RESTORE.md), and [purge contract](PURGE.md).
