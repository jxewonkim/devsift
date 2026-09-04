# DevSift

**Understand storage before changing it.**

DevSift is an open-source, local-first storage analyzer for macOS developers and
AI builders. It observes filesystem metadata under one explicitly selected
folder, shows where apparent allocation is concentrated, and applies
explainable read-only policy rules to recognized development caches.

> [!IMPORTANT]
> DevSift is pre-alpha. Scanning, classification, draft planning, Core approval,
> revalidation, and quarantine-attempt authorization perform no mutation:
> DevSift does not delete, move, quarantine, or otherwise modify files.

## Why DevSift?

Build tools, package managers, browsers, virtual machines, and AI workflows can
leave tens of gigabytes behind. DevSift is being built around a transparent,
local workflow:

- analyze before acting;
- explain every recommendation;
- keep risky or active data protected by default;
- make every cleanup plan reviewable and reproducible;
- process paths and reports locally, without telemetry.

The built-in rule catalog recognizes selected development-related storage such
as Xcode DerivedData and DeviceSupport versions, SwiftPM build output, and uv,
npm, and Homebrew caches. For a complete item, the scanner can now give its age
check a conservative upper bound of the newest inode modification time observed
during traversal. For an exact SwiftPM `.build` candidate, a bounded
descriptor-relative observer can also verify the metadata of an exact regular
file named `workspace-state.json`. For an exact npm `_cacache`, it can verify
the exact raw direct-child directories `content-v2` and `index-v5` as a bounded
cacache layout marker without reading their contents. The observer can
additionally establish trusted-location evidence for exact uv, npm, and
Homebrew default cache containers by rebinding the selected root descriptor to
the current account's raw home-relative path without following symbolic links.
For that exact npm candidate, it can also establish the distinct
`account-owned-cache-namespace` fact only when both the held selected root and
held `_cacache` directory have the current account's exact POSIX UID. This is
not generic npm or tool ownership: it proves neither who created the cache nor
write ACLs, content, inactivity, or mutation authority. A separate bounded,
descriptor-relative traversal can now reject descendants outside the pinned
cacache path-and-kind grammar, non-empty `tmp`, links, special nodes,
different-device entries, different-account owners, and repeated directory
identities. A clean result requires exhaustive stable traversal and agreement
with the earlier scan. Other rules retain unknown tool-ownership and protected-
descendant evidence. npm activity remains literally `unknown(.notCollected)`.
Only the npm rule can defer that one exact unknown to the versioned
`requires-user-attestation-that-responsible-tool-is-stopped@1` execution
precondition and produce a Review-required draft candidate; it does not report
npm inactive or authorize an operation. All other unavailable required facts
stay protected. Large AI
models, virtual machines, user documents, and active
application data are never treated as disposable merely because they are large.

## Current interfaces

- `DevSiftCore`: a Swift library for read-only scanning, versioned explainable
  classification, policy-provenanced in-memory draft manifests, and
  deterministic compatible-manifest diffing, plus exact review-bound approval,
  revalidation, and process-local quarantine-attempt authorization;
- `devsift`: a scriptable command-line interface;
- `DevSift`: a native SwiftUI dashboard with explicit folder selection,
  cancellable scans, observation results, policy explanations, explicit draft
  candidate selection, and read-only in-memory draft review.

The native app can ask Core to create an in-memory draft from an explicitly
selected eligible subset and display an identity-free review projection. It
starts with zero candidates included, keeps table focus separate from draft
inclusion, and treats the exact raw path and rule revision as one selection.
The Core planner revalidates the exact source classification request and report
before producing a draft. A real scan can legitimately expose zero eligible
candidates.

Core can now prepare an opaque approval-review session directly from one exact
source-bound planning request. The session retains that request's exact root
and Core-built manifest and issues entry references that cannot be reused in a
different review session. It also issues canonical references for every
deferred execution precondition. The caller must explicitly confirm every
session entry and acknowledge every pending condition for review in canonical
order; a missing, added, duplicate, reordered, changed, or foreign entry
confirmation or review acknowledgement rejects the whole request. A
precondition review acknowledgement means only that its condition and risk were
included in review. It is not an attestation that npm stopped, current
activity evidence, freshness, or execution authorization. The acknowledgement
and resulting approval remain copyable, replayable review intent rather than
single-attempt authority. Partial approval is
intentionally unsupported: changing the subset requires a new draft and review.
Before issuing approval, Core regenerates the manifest from the retained source
request and requires exact equality with the reviewed value. The resulting
approval retains the exact root and manifest in memory and remains
non-`Codable`. It proves neither freshness, authenticity, nor human review; it
is copyable rather than single-use, grants no execution or filesystem authority,
and performs no filesystem I/O.

Core can also revalidate only that in-memory approval with a fresh scan and
built-in classification of its retained root. Its canonical per-entry report is
a point-in-time, non-`Codable` diagnostic, not mutation authority or executor
input. Root, path, kind, device, identity, rule, findings, and policy are
reobserved; incomplete or unknown observations fail closed. Current runtime
evidence still leaves most real candidates Protected. Exact default uv, npm,
and Homebrew containers can now have trusted location reobserved, and npm may
also satisfy its supported cacache-layout marker, current-account cache-
namespace check, and bounded protected-descendant exclusion. These npm-specific
checks do not authorize mutation. npm activity remains uncollected; an otherwise
valid npm entry is reported as awaiting its unchanged deferred execution
precondition, not as inactive or execution-ready. Tool ownership, protected
descendants, and other required evidence remain unavailable for the other
rules. See the
[revalidation contract](docs/REVALIDATION.md).

Core can now begin one in-memory quarantine authorization attempt from an exact
approval. The session exposes the complete canonical npm pending set and the
required statement; a caller-created `CleanupQuarantineUserAttestation` is an
explicit assertion for that one attempt, not observed inactivity, caller
authentication, or proof that a human acted. Authorization contract version 1
issues at most once per attempt. All copies share one process-local internal
handoff that can be consumed at most once; cross-attempt replay fails, and no
clock or TTL defines freshness. The authorization is recoverable-quarantine-
only, still requires inline filesystem revalidation, and reports
`grantsStandaloneFilesystemMutationAuthority == false`. Its consume operation
is internal, and no executor or filesystem operation exists. See the
[authorization contract](docs/AUTHORIZATION.md).

Manifest diffing remains Core-only. The CLI target contains an internal,
one-way manifest-review JSON v2 encoder pinned to Core manifest contract
version 3, but no command invokes it and it never writes a file. The app review
is not a saved or serialized manifest. Neither frontend invokes the Core
approval or authorization contract or provides manifest persistence, import,
export, diffing, approval, attestation, authorization, execution, or filesystem
mutation.

Current semantic contracts are explainable classification revision 3, cleanup
manifest version 3, manifest diff version 2, approval version 2, and
revalidation version 2. Quarantine authorization is contract version 1. CLI
scan JSON remains version 2; classification JSON is version 2, and the internal
manifest-review JSON is version 2 over source manifest version 3. The built-in
catalog is version 6, with npm at rule revision 5.

The app and CLI share the same core behavior. There will be no separate,
less-safe cleanup implementation hidden in either frontend.

The remaining npm execution fact is activity. DevSift's completed capability
review found no supported, unprivileged macOS API that can prove the absence of
active use across an entire cache tree or turn that observation into a lease.
DevSift therefore does not infer `inactive` from a quiet tree, an empty process
query, or an advisory lock. The project has narrowly selected the explicit
user-attested policy only for recoverable quarantine. Core now binds the exact
approval to one explicit caller assertion for the complete pending set and a
process-local, single-use `CleanupQuarantineAuthorization`. It does not change
the unknown activity finding, authenticate the caller, prove human review, or
grant standalone mutation authority. A wall-clock TTL is not freshness. See the
[activity safety contract](docs/ACTIVITY.md).

## Safety first

DevSift remains read-only. Cleanup will only be introduced after dry-run plans,
path containment, symlink handling, and race-condition tests are in place.
Recoverable quarantine is planned before permanent removal.

Read the full [rules contract](docs/RULES.md),
[planning contract](docs/PLANNING.md), [revalidation contract](docs/REVALIDATION.md),
[activity safety contract](docs/ACTIVITY.md), [safety model](docs/SAFETY.md), and
[privacy contract](docs/PRIVACY.md).

## Development

The implementation order and acceptance gates are documented in
[the development plan](docs/DEVELOPMENT_PLAN.md). The intended dependency flow
is described in [the architecture guide](docs/ARCHITECTURE.md).

The current workspace can be exercised with:

```shell
swift build
swift test
swift run devsift status
swift run devsift scan .
swift run devsift scan --json .
swift run devsift classify .
swift run devsift classify --json .
swift run DevSiftApp
```

DevSiftCore contains a read-only allocated-size scanner, rule classifier,
Core-only draft-manifest planner, fail-closed manifest differ, in-memory
approval sessions, a read-only approval revalidator, and a Core-only in-memory
quarantine-attempt authorizer. The CLI exposes the scanner and classifier as
deterministic text and separately versioned JSON. It also owns an internal,
non-importable review projection for privacy-contract testing; this is not a
CLI command or file-export feature. The native app invokes the same Core
scanner, classifier, and planner and does not contain a separate filesystem or
policy implementation. Its review shows all seven stored observation and
uncertainty quantities as point-in-time estimates, not guaranteed savings, and
shows a pending npm condition as unobserved rather than as a safety or
inactivity claim. See the
[app contract](docs/APP.md),
[CLI contract](docs/CLI.md), [scanning contract](docs/SCANNING.md),
[rules contract](docs/RULES.md), [planning contract](docs/PLANNING.md), and
[authorization contract](docs/AUTHORIZATION.md).

Development uses small Conventional Commits. Every code commit must build and
pass tests before it is pushed. Filesystem tests operate only inside temporary,
synthetic fixtures and never scan or clean a contributor's real home directory.

## Project status

- Current phase: policy-provenanced in-memory dry-run manifests, Core-only
  diffing, review-bound entry confirmation and precondition review
  acknowledgement, and an approval-only, point-in-time Core revalidation
  diagnostic, plus Core-only process-local, single-use quarantine-attempt
  authorization; app and CLI remain read-only
- Current behavior: Core scanner, rule classifier, in-memory draft planner,
  compatible-manifest differ, approver, revalidator, and quarantine-attempt
  authorizer, plus the existing text/JSON CLI and native analysis dashboard
  with explicit in-memory draft review of pending execution conditions; no
  manifest-review CLI command, persistence, import, or user-facing export; no
  frontend diff, approval, attestation, authorization, or revalidation
  workflow; and no executor, cleanup, quarantine, receipt, recovery, restore,
  purge, or deletion
- First tagged release target: `v0.1.0-alpha.1`, read-only scan and
  classification surfaces
- Supported platform target: macOS 14 or newer
- Implementation language: Swift 6

See [CHANGELOG.md](CHANGELOG.md) for changes and
[CONTRIBUTING.md](CONTRIBUTING.md) to participate.

## License

DevSift is available under the [Apache License 2.0](LICENSE).
