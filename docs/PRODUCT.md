# Product scope

## Product statement

DevSift helps macOS developers and AI builders understand and safely reclaim
storage created by their tools. It favors evidence and user control over opaque
"one-click optimization."

## Target users

- developers using Xcode, package managers, containers, simulators, and virtual
  machines;
- AI builders accumulating model caches, generated assets, agent workspaces,
  and temporary build output;
- users who want to understand why disk usage grew before deciding what to do.

## Core jobs

The current pre-alpha implements the first job, a conservative foundation for
jobs 2 and 3, and a native read-only in-memory slice of job 4. It can recognize
selected path shapes, explain why missing evidence keeps them protected, and
build an immutable draft from explicitly selected eligible classifications.
The app starts with zero included candidates and presents an identity-free
review without persisting it. Core can also compare compatible
policy-provenanced drafts without reading the filesystem. The CLI target can
internally project one draft into a privacy-profiled, review-only JSON schema,
but no command or file export exposes it. Job 5 remains later product
direction.

1. Show where allocated storage is being consumed.
2. Attribute known storage to a tool or workflow when evidence supports it.
3. Explain whether an item is regenerable, user-owned, active, stale, or
   protected.
4. Produce a deterministic, reviewable plan before changing anything.
5. Report what was actually reclaimed and what was skipped.

## Built-in catalog version 2

The second version of the built-in catalog is present in Core, the CLI, and the
app. Its eligible outcomes are policy ceilings for fully evidenced synthetic
observations. For a complete item, the current real-scan adapter can establish
the age input from the newest inode modification time observed during scanning.
For an exact SwiftPM `.build` candidate, a bounded identity-bound observer can
also establish whether an exact regular-file `workspace-state.json` marker is
present. Scan-time identity is observation binding, not deletion authority;
trusted-location, ownership, reliable-activity, and protected-descendant
evidence remain unavailable, so runtime outcomes remain Protected even when
the marker is satisfied.

The first rule set recognizes:

- Xcode DerivedData and versioned DeviceSupport;
- SwiftPM `.build` output with a `Package.swift` sibling;
- uv, npm, and Homebrew caches.

Browser caches, installer images, and broad temporary-build discovery remain
future catalog work because reliable ownership and activity evidence is not yet
available.

AI model stores, virtual-machine disks, browser profiles, source repositories,
documents, photos, and application databases are protected or review-only by
default. Size alone is never evidence that data is disposable.

## User journey

The long-term workflow is:

1. **Scan** an explicitly selected root without modifying it.
2. **Explain** candidates using versioned rules and visible evidence.
3. **Plan** an immutable dry run with observed allocation estimates and their
   uncertainty.
4. **Approve** the exact reviewed draft as a separate explicit action.
5. **Revalidate** identity, containment, and active-use conditions.
6. **Quarantine** approved candidates using a recoverable operation.
7. **Report** completed, changed, failed, and skipped items.
8. **Purge** quarantined data only as a later, explicit action.

The current planning increment stops at in-memory Core drafts, typed Core
diffs, an internal CLI-owned review schema version 1 pinned to manifest
contract version 2, and a native identity-free in-memory review. The app keeps
table focus independent from explicit inclusion, which begins at zero, and
allows only current-session exact raw-path and rule-revision pairs. Core then
revalidates the exact classification request and report before planning. The
app review displays all seven observed size and uncertainty quantities; none is
a guaranteed savings claim. Current real scans may have zero eligible
candidates because unavailable required facts keep results Protected.

The CLI JSON projection is lossy and non-importable; it explicitly sets
`canBeApproved` and `canBeExecuted` to `false`. The app projection is ephemeral,
identity-free presentation state rather than a document. A diff requires the
same manifest contract, policy provenance, and expected root identity, and
still says nothing about current disk freshness. No frontend workflow persists,
imports, exports, diffs, approves, executes, performs live-filesystem
revalidation, or mutates from a manifest, and no diff-export format exists.

## Non-goals

DevSift is not:

- a malware scanner or antivirus product;
- a memory, battery, or performance "booster";
- a tool for bypassing macOS permissions or platform protections;
- an automatic remover of user documents or unfamiliar large files;
- a wrapper around arbitrary shell deletion commands.

No cleanup operation exists in the current milestone.
