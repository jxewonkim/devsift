# Architecture

DevSift uses one safety-critical Swift core shared by its native app and CLI.

```text
DevSift SwiftUI app  --->  DevSiftCore  <---  devsift CLI
                              |
                 scan -> rules -> plan -> executor
                   now      later    later    later
```

## Components

### DevSiftCore

The core owns domain models and filesystem behavior. It must not depend on
SwiftUI, command-line formatting, shell commands, analytics, or application
state.

Planned modules are:

- **Scanning:** read-only enumeration and allocated-size measurement. The
  current scanner streams metadata into root and top-level summaries rather
  than retaining every path. It anchors traversal to directory descriptors and
  resolves every child relative to its already-open parent;
- **Rules:** versioned, explainable candidate classification;
- **Planning:** deterministic immutable dry-run manifests;
- **Execution:** revalidation and recoverable quarantine, introduced only after
  the earlier layers are stable;
- **Reporting:** structured outcomes without frontend-specific rendering.

### devsift CLI

The CLI parses explicit commands, invokes DevSiftCore, and renders human-readable
or versioned JSON output. Results go to standard output and diagnostics to
standard error. The CLI does not implement independent filesystem rules.

### DevSift app

The macOS app provides explicit folder selection, progress and cancellation,
candidate explanations, plan review, and accessibility. View models call the
same DevSiftCore APIs as the CLI.

## Dependency rules

- Frontends may depend on DevSiftCore; DevSiftCore never imports a frontend.
- Filesystem capabilities are injected so tests can use controlled fixtures.
- Domain values use stable identifiers and deterministic ordering.
- Concurrency supports cancellation and bounded work.
- External dependencies require a written reason and supply-chain review.
- The initial workspace avoids third-party runtime dependencies.

## Measurement

DevSift distinguishes logical file size from allocated disk usage. User-facing
reclaim estimates use allocated bytes where the filesystem exposes them and
label estimates when exact accounting is not possible. Hard links, sparse
files, packages, clones, and filesystem snapshots require explicit handling and
tests rather than naive recursive summation.

The scanner reports apparent bytes separately from hard-link-exclusive
allocated bytes. A hard-linked regular-file inode receives that credit only
when all of its links were observed inside the same summary boundary; links
crossing top-level items or leaving the selected root remain explicitly
non-exclusive. This field does not claim to resolve clone or snapshot sharing.
APFS clones are not deduplicated because file-level APIs do not expose block
ownership. A reported allocated size is therefore a point-in-time estimate, not
a guaranteed reclaimable byte count.

## Evolution rule

Scanning, classification, planning, and execution remain separate stages. A
future optimization must not combine them in a way that allows discovery code
to mutate the filesystem or bypass plan review.
