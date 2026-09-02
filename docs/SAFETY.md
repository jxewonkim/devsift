# Safety model

DevSift treats filesystem cleanup as a security-sensitive transaction rather
than a convenience command.

## Trust classes

Every classified item will belong to one of three broad classes:

- **Reclaimable:** generated and reproducible data with strong ownership and
  lifecycle evidence.
- **Review required:** data that may be reclaimable but needs context or an
  explicit user decision.
- **Protected:** user content, active data, unknown data, broad system paths, or
  anything that fails a safety check.

Unknown is protected, not reclaimable.

## Required workflow

Cleanup functionality must preserve this ordering:

`scan -> classify -> plan -> approve -> revalidate -> quarantine -> report`

Scanning and planning are read-only. A plan records the exact candidate,
evidence, expected identity, rule version, and estimated allocated bytes. Before
any mutation, DevSift must revalidate that the item is still the same item and
still inside its approved root.

## Hard invariants

- A scan root is explicit; there is no implicit whole-disk cleanup.
- Directory enumeration is anchored to an opened root descriptor. Descendants
  are opened relative to verified parent descriptors and symbolic links are not
  followed.
- Mounted descendants on a different device are reported and not traversed.
- Scan depth, entry count, top-level output, hard-link accounting, and recorded
  issue count have explicit limits; a reached limit produces a partial result
  rather than silent omission.
- A candidate cannot escape its approved root through symlinks, aliases, path
  normalization, mounts, or race conditions.
- Broad paths such as `/`, `/System`, `/Applications`, `/Users`, and a home
  directory itself are protected cleanup targets.
- Scan code cannot mutate files.
- The app and scan CLI expose no cleanup, delete, move, quarantine, or
  permission-escalation action; complete and partial reports remain read-only.
- The app never presents a partial, bounded, or overflowed observation as
  complete or as evidence that an item can be cleaned.
- Core logic does not construct or execute shell commands.
- Failure to read metadata produces a visible error or skip, never permission
  escalation or an unsafe assumption.
- Active application data is skipped when a reliable activity check is
  required but unavailable.
- A changed candidate is skipped during revalidation.
- Partial failures are reported item by item.
- Permanent deletion is not part of the initial milestones.

Cancellation is safe but may not be instantaneous. A blocking filesystem call
can finish before the next cancellation checkpoint is reached. The scanner
still performs no filesystem mutation while cancellation unwinds.

## Rule requirements

A cleanup rule must declare:

- a stable identifier and version;
- the tool or workflow responsible for the data;
- positive evidence used to identify a candidate;
- exclusions and protected descendants;
- whether the data is reproducible;
- required activity and age checks;
- risk class and user-facing explanation;
- synthetic tests for matches, near misses, and hostile paths.

Path shape alone is insufficient for a high-confidence rule when the path can
contain user-owned content.

## Test boundary

All filesystem tests use newly created temporary directories and synthetic
fixtures. Tests never point at a real home directory, tool cache, project,
simulator, virtual machine, or browser profile. Mutation tests must assert that
nothing outside the fixture changed.

Any future permanent-removal feature requires a separate design review, threat
model, and release milestone.
