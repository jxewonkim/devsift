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

The current pre-alpha implements the first job and a conservative foundation
for jobs 2 and 3. It can recognize selected path shapes and explain why missing
evidence keeps them protected. Jobs 4 and 5 remain later product direction.

1. Show where allocated storage is being consumed.
2. Attribute known storage to a tool or workflow when evidence supports it.
3. Explain whether an item is regenerable, user-owned, active, stale, or
   protected.
4. Produce a deterministic, reviewable plan before changing anything.
5. Report what was actually reclaimed and what was skipped.

## Initial catalog

The first versioned catalog is present in Core, the CLI, and the app. Its
eligible outcomes are policy ceilings for fully evidenced synthetic
observations. For a complete item, the current real-scan adapter can establish
the age input from the newest inode modification time observed during scanning.
Trusted-location, ownership, generated-marker, reliable-activity, and
protected-descendant evidence remain unavailable, so runtime outcomes remain
Protected.

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
3. **Plan** an immutable dry run with estimated reclaimed bytes.
4. **Revalidate** identity, containment, and active-use conditions.
5. **Quarantine** approved candidates using a recoverable operation.
6. **Report** completed, changed, failed, and skipped items.
7. **Purge** quarantined data only as a later, explicit action.

## Non-goals

DevSift is not:

- a malware scanner or antivirus product;
- a memory, battery, or performance "booster";
- a tool for bypassing macOS permissions or platform protections;
- an automatic remover of user documents or unfamiliar large files;
- a wrapper around arbitrary shell deletion commands.

No cleanup operation exists in the current milestone.
