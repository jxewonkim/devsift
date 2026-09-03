# DevSift

**Understand storage before changing it.**

DevSift is an open-source, local-first storage analyzer for macOS developers and
AI builders. It observes filesystem metadata under one explicitly selected
folder, shows where apparent allocation is concentrated, and applies
explainable read-only policy rules to recognized development caches.

> [!IMPORTANT]
> DevSift is pre-alpha. Scanning, classification, draft planning, and the
> native app's in-memory draft review are read-only: DevSift does not delete,
> move, quarantine, or otherwise modify files.

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
file named `workspace-state.json`. Neither its scan-time identity nor a
satisfied marker or age check is permission to clean: uncollected
trusted-location, ownership, activity, and protected-descendant facts keep real
candidates protected. Large AI models, virtual machines, user documents, and
active application data are never treated as disposable merely because they
are large.

## Current interfaces

- `DevSiftCore`: a Swift library for read-only scanning, versioned explainable
  classification, policy-provenanced in-memory draft manifests, and
  deterministic compatible-manifest diffing;
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

Manifest diffing remains Core-only. The CLI target contains an internal,
one-way manifest-review JSON v1 encoder pinned to Core manifest contract
version 2, but no command invokes it and it never writes a file. The app review
is not a saved or serialized manifest. Neither frontend provides manifest
persistence, import, export, diffing, approval, execution, or filesystem
mutation.

The app and CLI share the same core behavior. There will be no separate,
less-safe cleanup implementation hidden in either frontend.

## Safety first

DevSift remains read-only. Cleanup will only be introduced after dry-run plans,
path containment, symlink handling, and race-condition tests are in place.
Recoverable quarantine is planned before permanent removal.

Read the full [rules contract](docs/RULES.md),
[planning contract](docs/PLANNING.md), [safety model](docs/SAFETY.md), and
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
Core-only draft-manifest planner, and fail-closed manifest differ. The CLI
exposes the scanner and classifier as deterministic text and separately
versioned JSON. It also owns an internal, non-importable review projection for
privacy-contract testing; this is not a CLI command or file-export feature. The
native app invokes the same Core scanner, classifier, and planner and does not
contain a separate filesystem or policy implementation. Its review shows all
seven stored observation and uncertainty quantities as point-in-time estimates,
not guaranteed savings. See the
[app contract](docs/APP.md),
[CLI contract](docs/CLI.md), [scanning contract](docs/SCANNING.md),
[rules contract](docs/RULES.md), and [planning contract](docs/PLANNING.md).

Development uses small Conventional Commits. Every code commit must build and
pass tests before it is pushed. Filesystem tests operate only inside temporary,
synthetic fixtures and never scan or clean a contributor's real home directory.

## Project status

- Current phase: policy-provenanced in-memory dry-run manifests, Core-only
  diffing, an internal CLI-owned privacy-aware review projection, and native
  app selection plus identity-free draft review
- Current behavior: Core scanner, rule classifier, in-memory draft planner, and
  compatible-manifest differ, plus the existing text/JSON CLI and native
  analysis dashboard with explicit in-memory draft review; no manifest-review
  CLI command, persistence, import, user-facing export, frontend diff,
  approval, execution, cleanup, quarantine, or deletion
- First tagged release target: `v0.1.0-alpha.1`, read-only scan and
  classification surfaces
- Supported platform target: macOS 14 or newer
- Implementation language: Swift 6

See [CHANGELOG.md](CHANGELOG.md) for changes and
[CONTRIBUTING.md](CONTRIBUTING.md) to participate.

## License

DevSift is available under the [Apache License 2.0](LICENSE).
