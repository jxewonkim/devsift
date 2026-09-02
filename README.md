# DevSift

**Understand storage before changing it.**

DevSift is an open-source, local-first storage analyzer for macOS developers and
AI builders. The current scan-only milestone observes filesystem metadata under
one explicitly selected folder and shows where apparent allocation is
concentrated. Classification, recommendations, and cleanup are later phases.

> [!IMPORTANT]
> DevSift is pre-alpha. The first milestone is scan-only: it does not delete,
> move, or modify files.

## Why DevSift?

Build tools, package managers, browsers, virtual machines, and AI workflows can
leave tens of gigabytes behind. DevSift is being built around a transparent,
local workflow:

- analyze before acting;
- explain every recommendation;
- keep risky or active data protected by default;
- make every cleanup plan reviewable and reproducible;
- process paths and reports locally, without telemetry.

The future rule catalog will focus on development-related storage such as Xcode
DerivedData and old DeviceSupport versions, temporary build remnants,
package-manager caches, and explicitly selected application caches. Those rules
are not implemented in the scan-only milestone. Large AI models, virtual
machines, user documents, and active application data will never be treated as
disposable merely because they are large.

## Current interfaces

- `DevSiftCore`: a Swift library for the read-only scanner; classification,
  planning, and safety validation remain planned phases;
- `devsift`: a scriptable command-line interface;
- `DevSift`: a native SwiftUI dashboard with explicit folder selection,
  cancellable scans, and complete or partial result presentation.

The app and CLI share the same core behavior. There will be no separate,
less-safe cleanup implementation hidden in either frontend.

## Safety first

DevSift starts read-only. Cleanup will only be introduced after the scanner,
rule engine, dry-run plans, path containment, symlink handling, and race-condition
tests are in place. Recoverable quarantine is planned before permanent removal.

Read the full [safety model](docs/SAFETY.md) and [privacy contract](docs/PRIVACY.md).

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
swift run devsift scan --json ./synthetic-cache
swift run DevSiftApp
```

DevSiftCore contains a read-only allocated-size scanner, and the CLI exposes it
as deterministic text and versioned JSON. The native app invokes the same Core
scanner and does not contain a separate filesystem implementation. See the
[app contract](docs/APP.md), [CLI contract](docs/CLI.md), and
[scanning contract](docs/SCANNING.md).

Development uses small Conventional Commits. Every code commit must build and
pass tests before it is pushed. Filesystem tests operate only inside temporary,
synthetic fixtures and never scan or clean a contributor's real home directory.

## Project status

- Current phase: read-only scan app and CLI
- Current behavior: Core scanner, text/JSON CLI, and native scan dashboard; no
  classification, recommendations, or cleanup
- First tagged release target: `v0.1.0-alpha.1`, read-only scan surfaces
- Supported platform target: macOS 14 or newer
- Implementation language: Swift 6

See [CHANGELOG.md](CHANGELOG.md) for changes and
[CONTRIBUTING.md](CONTRIBUTING.md) to participate.

## License

DevSift is available under the [Apache License 2.0](LICENSE).
