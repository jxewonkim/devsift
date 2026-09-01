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

1. Show where allocated storage is being consumed.
2. Attribute known storage to a tool or workflow when evidence supports it.
3. Explain whether an item is regenerable, user-owned, active, stale, or
   protected.
4. Produce a deterministic, reviewable plan before changing anything.
5. Report what was actually reclaimed and what was skipped.

## Initial catalog

The first rule set is planned to recognize:

- Xcode DerivedData and versioned DeviceSupport;
- temporary build remnants under explicitly selected roots;
- uv, npm, and Homebrew caches;
- selected browser cache directories when the browser is not active;
- installer images that the user explicitly marks as no longer needed.

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

No cleanup operation will exist in the `v0.1` scan-only milestone.
