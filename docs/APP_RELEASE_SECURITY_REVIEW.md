# Native app distribution security review

Status: implementation review completed on 2026-09-07. Local ad-hoc packaging
passed; live Developer ID signing, Apple notarization, fresh-runner Gatekeeper
checks, and public release remain blocked until the protected release
credentials are provisioned and the candidate is merged to `main`.

## Reviewed boundary

This review covers:

- `packaging/DevSiftApp/Info.plist.template`;
- `packaging/DevSiftApp/DevSift.entitlements`;
- the app package, archive, structural verification, and reproducibility
  scripts under `scripts/release/`;
- the existing tag workflow's draft-only handoff;
- `.github/workflows/release-app.yml` from manual gate through publication.

It does not reopen the scanner, quarantine, restore, or purge algorithms. Their
authority and same-account residual risks remain governed by the existing
safety contracts and focused reviews.

## Authority comparison

The distributed bundle uses the same executable target as
`swift run DevSiftApp`. It adds a bundle identity, version metadata, resources,
hardened runtime, a code signature, and a notarization ticket. It adds no
filesystem feature, background process, helper, login item, network client,
telemetry, updater, or new mutation entry point.

The entitlement plist is deliberately empty. In particular, it contains none
of these authority-expanding or protection-reducing values:

- App Sandbox file exceptions or temporary exceptions;
- `get-task-allow`;
- JIT or unsigned executable memory;
- disabled library validation or executable-memory protection;
- DYLD environment exceptions;
- Apple Events automation;
- camera, microphone, location, contacts, calendar, or photos access.

The app is not App Sandbox enabled. Sandboxing would block the fixed passwd-home
`~/.npm` recovery namespace used by the already reviewed transaction boundary
unless the product acquired a materially different permission and persistence
model. Remaining unsandboxed does not grant root or bypass macOS privacy
controls; it preserves the directly launched executable's ordinary user
authority.

## Artifact invariants

The packager builds independent macOS 14 `arm64` and `x86_64` slices, combines
only those slices, removes recognized developer-toolchain rpaths, strips debug
symbols, clears extended attributes, and signs the final fixed bundle. The
verifier fails closed on:

- an unexpected bundle entry, link, file type, mode, plist key, version, or
  bundle identifier;
- another architecture, deployment floor, dependency, rpath, or local build
  path;
- missing hardened runtime, nonempty entitlements, the wrong signature stage,
  publisher team, timestamp, or notarization ticket;
- failed `codesign`, stapler, or Gatekeeper validation.

Archive creation accepts only a canonical alpha semantic version and refuses
existing files and dangling symbolic-link targets. Local ad-hoc builds fix
metadata and must reproduce byte for byte across independent temporary build
paths and caller timezones. Signed releases instead bind the exact
timestamped-and-stapled bytes to a checksum and GitHub attestation.

## Supply-chain and publication controls

The source tag must be an annotated new alpha tag directly on the current
`main` tip. Normal main CI, full synthetic transaction tests, app
reproducibility, the CLI release workflow, and a protected `release`
environment are prerequisites.

The public Team ID `VN6283SM8B` is pinned in reviewed source. A configuration
value cannot redefine both the actual signer and the expected trust root. The
Developer ID certificate and notary key are step-scoped secrets. The
certificate is imported into a temporary keychain usable by `codesign`, and the
keychain is removed before any step receives the notary key. Signing and
notarization credentials are never present in the same step environment. Final
cleanup attempts every credential removal even if one cleanup operation fails.

The CLI workflow creates only a hidden two-asset draft. The app workflow is the
sole publisher. Before publication it requires:

- a zero-issue accepted Apple notarization log and stapled ticket;
- strict bundle and Gatekeeper validation;
- install-and-launch success on fresh arm64 and x86_64 runners;
- exact app handoff digests and app provenance;
- exactly four remote assets and canonical one-line checksum files;
- successful verification of the CLI archive's original tag-workflow
  attestation;
- exact agreement between the draft title/body and tag-pinned release notes;
- a final tag-to-`main` rebind.

Repository scripts and downloaded release executables are not run by the final
job that holds `contents: write`. GitHub-owned actions are pinned to complete
commit hashes.

## Testing evidence

The 2026-09-07 local acceptance run built both architectures twice with Xcode
26.6, produced identical ad-hoc ZIP bytes across separate temporary paths and
timezones, re-extracted and revalidated the archive, and launched the packaged
app without an error log. The package reported a valid ad-hoc signature,
hardened runtime, empty entitlements, macOS 14 floor, and both required slices.

The live release-only checks cannot be truthfully marked complete without a
Developer ID Application certificate and App Store Connect notary API key.
They remain mandatory workflow gates rather than skipped tests.

## Findings and disposition

During review, five publication weaknesses were corrected:

1. untrusted archive versions could influence an output path;
2. dangling output symlinks were not rejected;
3. the expected Team ID could be redefined by release configuration;
4. mutable draft CLI assets and release text were not rebound to their original
   provenance and tag-pinned notes before publication; and
5. an early credential-validation step exposed signing and notarization secrets
   together before either was needed.

No blocking or high-priority implementation finding remains in the reviewed
local and CI design. One release blocker remains external and explicit: the
required credentials are absent, so no signed/notarized claim or public asset
may be produced yet.

Residual operational risks remain:

- GitHub-hosted runner images and Apple's notarization service are external
  dependencies rather than reproducible local inputs;
- a repository administrator with release and environment authority is part of
  the trusted publication base;
- final Developer ID signatures and Apple tickets contain external timestamps,
  so signed archive bytes are intentionally not reproducible;
- a concurrent repository administrator could race mutable draft state between
  sequential API checks, although the protected environment, exact asset
  inventory, attestations, repeated tag binding, and immediate publication
  checks narrow that window.

These risks do not authorize unattended cleanup or broaden which filesystem
object DevSift may mutate.
