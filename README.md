# DevSift

**Understand storage before changing it.**

DevSift is an open-source, local-first storage analyzer for macOS developers and
AI builders. It observes filesystem metadata under one explicitly selected
folder, shows where apparent allocation is concentrated, and applies
explainable read-only policy rules to recognized development caches.

> [!IMPORTANT]
> DevSift is pre-alpha. Scanning and classification are read-only: DevSift does
> not delete, move, quarantine, or otherwise modify files.

## Why DevSift?

Build tools, package managers, browsers, virtual machines, and AI workflows can
leave tens of gigabytes behind. DevSift is being built around a transparent,
local workflow:

- analyze before acting;
- explain every recommendation;
- keep risky or active data protected by default;
- make every cleanup plan reviewable and reproducible;
- process paths and reports locally, without telemetry.

The initial rule catalog recognizes selected development-related storage such
as Xcode DerivedData and DeviceSupport versions, SwiftPM build output, and uv,
npm, and Homebrew caches. For a complete item, the scanner can now give its age
check a conservative upper bound of the newest inode modification time observed
during traversal. Recognition or a satisfied age check is not permission to
clean: uncollected trusted-location, ownership, generated-marker, activity, and
protected-descendant facts keep real candidates protected. Large AI models,
virtual machines, user documents, and active application data are never
treated as disposable merely because they are large.

## Current interfaces

- `DevSiftCore`: a Swift library for read-only scanning and versioned,
  explainable classification; planning and execution remain later phases;
- `devsift`: a scriptable command-line interface;
- `DevSift`: a native SwiftUI dashboard with explicit folder selection,
  cancellable scans, observation results, and policy explanations.

The app and CLI share the same core behavior. There will be no separate,
less-safe cleanup implementation hidden in either frontend.

## Safety first

DevSift remains read-only. Cleanup will only be introduced after dry-run plans,
path containment, symlink handling, and race-condition tests are in place.
Recoverable quarantine is planned before permanent removal.

Read the full [rules contract](docs/RULES.md),
[safety model](docs/SAFETY.md), and [privacy contract](docs/PRIVACY.md).

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

DevSiftCore contains a read-only allocated-size scanner, and the CLI exposes it
and the classifier as deterministic text and separately versioned JSON. The
native app invokes the same Core scanner and classifier and does not contain a
separate filesystem or policy implementation. See the [app contract](docs/APP.md),
[CLI contract](docs/CLI.md), [scanning contract](docs/SCANNING.md), and
[rules contract](docs/RULES.md).

Development uses small Conventional Commits. Every code commit must build and
pass tests before it is pushed. Filesystem tests operate only inside temporary,
synthetic fixtures and never scan or clean a contributor's real home directory.

## Project status

- Current phase: explainable read-only rules
- Current behavior: Core scanner and rule classifier, text/JSON CLI, and native
  dashboard; no planning, cleanup, quarantine, or deletion
- First tagged release target: `v0.1.0-alpha.1`, read-only scan and
  classification surfaces
- Supported platform target: macOS 14 or newer
- Implementation language: Swift 6

See [CHANGELOG.md](CHANGELOG.md) for changes and
[CONTRIBUTING.md](CONTRIBUTING.md) to participate.

## License

DevSift is available under the [Apache License 2.0](LICENSE).
