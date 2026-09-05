# DevSift

**Understand storage before changing it.**

DevSift is an open-source, local-first storage analyzer for macOS developers and
AI builders. It observes filesystem metadata under one explicitly selected
folder, shows where apparent allocation is concentrated, and applies
explainable policy rules to recognized development caches.

> [!IMPORTANT]
> DevSift is pre-alpha. The source-run native app can durably quarantine one
> exact npm cache at the current non-root account's passwd-home
> `~/.npm/_cacache` after explicit review and two confirmation gates, then
> explicitly reconcile and load its bounded recovery
> inventory and manually restore one receipt-bound item without overwriting a
> recreated source. Mutation requires macOS 26 or newer. The CLI and public
> DevSiftCore API remain read-only, and no distributed app, permanent deletion,
> or storage-reclaim feature exists.

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
  revalidation, process-local quarantine-attempt authorization, and an
  internal npm-only atomic quarantine kernel, durable mixed journal and
  observational recovery engine, single-item manual restore workflow, and
  package-scoped app facades over those mutation kernels;
- `devsift`: a scriptable command-line interface;
- `DevSift`: a native SwiftUI dashboard with explicit folder selection,
  cancellable scans, observation results, policy explanations, explicit draft
  candidate selection, in-memory review, narrowly scoped npm quarantine,
  explicit recovery inventory loading, and receipt-bound manual restore.

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
is internal. The internal executor now consumes only that handoff, performs
descriptor-held inline validation, and can make one exclusive same-volume
move into a private quarantine namespace. See the
[authorization contract](docs/AUTHORIZATION.md) and
[quarantine contract](docs/QUARANTINE.md).

Core also implements a separate manual restore authority for one exact
canonical quarantine intent and matching final `quarantined` receipt. An
explicit package-scoped inventory request first reconciles the fixed npm journal
and validates the complete bounded inventory under the same exclusive lock; it
rejects the whole load for malformed or unresolved journal state, unsafe trusted
parents, or aggregate resource exhaustion. Individual missing, changed, unsafe,
or per-item over-bound contents remain visible as non-restorable rows. The app
receives bounded readiness and opaque process-local references rather than raw
journal bytes, paths, or transaction identifiers. After a separate exact
confirmation, Core reopens and revalidates the fixed npm namespace, publishes a
durable restore intent, and performs at most one non-overwriting reverse rename
of the receipt-bound item to `_cacache` before recording a conclusive receipt.
When that execution returns to the still-current, uncancelled view-model
operation, the app performs one post-attempt reconciliation and inventory
refresh. Dismissed, cancelled, or superseded UI work cannot publish stale state.
Core also performs locked recovery during quarantine transaction admission,
restore preparation, and restore transaction admission. Nothing invokes recovery or
restore automatically at app launch. The low-level selection, journal, claims, and executors remain
unavailable to the CLI and public library API. See the
[manual restore contract](docs/RESTORE.md).

Manifest diffing remains Core-only. The CLI target contains an internal,
one-way manifest-review JSON v2 encoder pinned to Core manifest contract
version 3, but no command invokes it and it never writes a file. The app review
is not a saved or serialized manifest. The source-run app retains the exact
Core-issued review session only for its current supported npm transaction and
reaches mutation only through package-scoped facades. It provides no manifest
persistence, import, export, or diffing. The CLI invokes no approval,
attestation, authorization, recovery, restore, or filesystem mutation path.

Current semantic contracts are explainable classification revision 3, cleanup
manifest version 3, manifest diff version 2, approval version 2, and
revalidation version 2. Quarantine authorization and the internal process-local
quarantine execution report are contract version 1 and version 2 respectively.
Restore authorization and its internal report are contract version 1. The
private quarantine and restore intent/receipt wire records are version 1. CLI
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

Scanning, classification, planning, every CLI command, and the public
DevSiftCore API remain read-only. The source-run app's package-scoped npm
workflow is the sole mutation surface. It performs no deletion: quarantine uses
one non-overwriting same-volume rename into `.devsift-quarantine-v1`, while a
separately confirmed manual restore can use one non-overwriting reverse rename
for the exact receipt-bound item. Each mutation publishes its own canonical
immutable intent first, requires the specified `F_FULLFSYNC` record and
namespace barriers, and records a terminal receipt only for conclusive state.
Explicit recovery observes receipt-less intents and may complete a provable
receipt, but never retries a rename. Same-volume quarantine deallocates no file
data and therefore guarantees exactly 0 B of freed capacity. Purge and permanent
removal remain absent.

Read the full [rules contract](docs/RULES.md),
[planning contract](docs/PLANNING.md), [revalidation contract](docs/REVALIDATION.md),
[authorization contract](docs/AUTHORIZATION.md),
[quarantine contract](docs/QUARANTINE.md),
[durability contract](docs/DURABILITY.md),
[manual restore contract](docs/RESTORE.md),
[activity safety contract](docs/ACTIVITY.md), [safety model](docs/SAFETY.md),
and [privacy contract](docs/PRIVACY.md).

## Development

The implementation order and acceptance gates are documented in
[the development plan](docs/DEVELOPMENT_PLAN.md). The intended dependency flow
is described in [the architecture guide](docs/ARCHITECTURE.md).

The current workspace can be exercised with:

```shell
swift build
swift test
swift run devsift --version
swift run devsift status
swift run devsift scan .
swift run devsift scan --json .
swift run devsift classify .
swift run devsift classify --json .
swift run DevSiftApp
```

### Try the Phase 9 source build

This is a pre-alpha workflow that performs a real rename if every confirmation
is completed. On macOS 26 or newer:

1. Stop npm work that may use the cache.
2. Run `swift run DevSiftApp`, choose `Select Folder…`, and select the current
   account's exact `~/.npm` directory—not `_cacache` itself. Because `.npm` is
   hidden, press `⌘⇧G` in the folder picker and enter `~/.npm` if needed.
3. If `_cacache` passes the conservative policy, include it and choose
   `Review Draft…`.
4. Read the complete draft, select the review and stopped-npm/risk checkboxes,
   then choose `Final Confirmation…` and `Move to Quarantine`.
5. To inspect or undo that move, choose `Recovery…`, then
   `Load and Reconcile`. A ready receipt can be restored only after all three
   restore confirmations.

Quarantine is a recoverable same-volume move. It frees exactly 0 B; permanent
purge and real storage reclamation are not implemented yet.

DevSiftCore contains a read-only allocated-size scanner, rule classifier,
Core-only draft-manifest planner, fail-closed manifest differ, in-memory
approval sessions, a read-only approval revalidator, a Core-only in-memory
quarantine-attempt authorizer, and an internal npm-only atomic quarantine
kernel with durable journal and recovery components, plus an internal
single-item manual npm restore workflow and package-scoped app facades. The CLI
exposes the scanner and classifier as
deterministic text and separately versioned JSON. It also owns an internal,
non-importable review projection for privacy-contract testing; this is not a
CLI command or file-export feature. The native app invokes the same Core
scanner, classifier, and planner and does not contain a separate filesystem or
policy implementation. Its review shows all seven stored observation and
uncertainty quantities as point-in-time estimates, not guaranteed savings, and
shows a pending npm condition as unobserved rather than as a safety or
inactivity claim. For the exact npm cache at the current non-root account's
passwd-home, that same source-run app can retain the Core review authority,
require the two separate confirmation gates, perform a durable quarantine on
macOS 26 or newer, and explicitly load a reconciled inventory for one-at-a-time
restore. See the
[app contract](docs/APP.md),
[CLI contract](docs/CLI.md), [scanning contract](docs/SCANNING.md),
[rules contract](docs/RULES.md), [planning contract](docs/PLANNING.md),
[authorization contract](docs/AUTHORIZATION.md), and
[quarantine contract](docs/QUARANTINE.md), plus the
[durability contract](docs/DURABILITY.md) and
[manual restore contract](docs/RESTORE.md).

Development uses small Conventional Commits. Every code commit must build and
pass tests before it is pushed. Filesystem tests operate only inside temporary,
synthetic fixtures and never scan or clean a contributor's real home directory.

## Pre-release distribution status

The source tag `v0.3.0-alpha.1` exists, but its release workflow did not
complete. There is currently no GitHub Release, downloadable CLI archive,
`SHA256SUMS` asset, provenance attestation, or installable native app. Do not
treat that tag as a binary distribution. The immutable failed pre-release must
be superseded by a new version rather than moved or republished with different
source.

The intended archive remains a read-only universal CLI; the SwiftUI executable
is source-only. See the [release contract](docs/RELEASE.md) and the historical
[version-specific release notes](docs/releases/v0.3.0-alpha.1.md).

## Project status

- Current phase: Phase 9 implemented. The source-run native app can move one
  explicitly reviewed npm cache at the current non-root account's passwd-home
  `~/.npm/_cacache` into durable same-volume quarantine on macOS 26 or newer
  after two confirmation gates, explicitly reconcile and load a bounded
  recovery inventory, and separately confirm one receipt-bound non-overwriting
  restore. The CLI and public Core API remain read-only
- Current behavior: Core scanner, rule classifier, in-memory draft planner,
  compatible-manifest differ, approver, revalidator, and quarantine-attempt
  authorizer, plus the existing text/JSON CLI and native analysis dashboard
  with explicit in-memory draft review of pending execution conditions; no
  manifest-review CLI command, persistence, import, or user-facing export. The
  app alone reaches the package-scoped quarantine and recovery/restore facades;
  there is no CLI or public Core mutation API, purge, deletion, retention,
  batch operation, custom-path mutation, automatic restore, or automatic
  app-launch recovery. Quarantine guarantees 0 B of freed capacity
- Distribution status: the `v0.3.0-alpha.1` source tag exists, but no GitHub
  Release or downloadable assets were published; the native app remains
  source-only
- Supported platform target: macOS 14 or newer for scanning and read-only
  surfaces; app quarantine and restore require macOS 26 or newer and fail closed
  before mutation on older systems
- Implementation language: Swift 6

See [CHANGELOG.md](CHANGELOG.md) for changes and
[CONTRIBUTING.md](CONTRIBUTING.md) to participate.

## License

DevSift is available under the [Apache License 2.0](LICENSE).
