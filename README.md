# DevSift

**Know what's safe to clear.**

DevSift is an open-source, local-first storage analyzer for macOS developers and
AI builders. It explains which tools created reclaimable files, why an item is a
cleanup candidate, and what must be checked before any action is taken.

> [!IMPORTANT]
> DevSift is pre-alpha. The first milestone is scan-only: it does not delete,
> move, or modify files.

## Why DevSift?

Build tools, package managers, browsers, virtual machines, and AI workflows can
leave tens of gigabytes behind. Generic disk visualizers show where the bytes
are; generic cleaners often hide why something is safe to remove. DevSift is
being built around a different contract:

- analyze before acting;
- explain every recommendation;
- keep risky or active data protected by default;
- make every cleanup plan reviewable and reproducible;
- process paths and reports locally, without telemetry.

The initial rule catalog will focus on development-related storage such as
Xcode DerivedData and old DeviceSupport versions, temporary build remnants,
package-manager caches, and explicitly selected application caches. Large AI
models, virtual machines, user documents, and active application data are never
treated as disposable merely because they are large.

## Planned surfaces

- `DevSiftCore`: a Swift library for scanning, classification, planning, and
  safety validation;
- `devsift`: a scriptable command-line interface;
- `DevSift`: a native SwiftUI macOS application.

The app and CLI will share the same core behavior. There will be no separate,
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

The current foundation workspace can be exercised with:

```shell
swift build
swift test
swift run devsift status
swift run DevSiftApp
```

The CLI and app currently report their scan-only development status. Filesystem
scanning begins in the next milestone.

Development uses small Conventional Commits. Every code commit must build and
pass tests before it is pushed. Filesystem tests operate only inside temporary,
synthetic fixtures and never scan or clean a contributor's real home directory.

## Project status

- Current phase: Swift workspace foundation
- Current behavior: status-only CLI and app shell; no filesystem scanning
- First release target: `v0.1.0-alpha.1`, read-only scan surfaces
- Supported platform target: macOS 14 or newer
- Implementation language: Swift 6

See [CHANGELOG.md](CHANGELOG.md) for changes and
[CONTRIBUTING.md](CONTRIBUTING.md) to participate.

## License

DevSift is available under the [Apache License 2.0](LICENSE).
