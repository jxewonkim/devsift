# Safety model

DevSift treats filesystem cleanup as a security-sensitive transaction rather
than a convenience command.

## Trust classes

Every recognized item belongs to one of three policy classes:

- **Reclaimable:** generated and reproducible data with strong ownership and
  lifecycle evidence.
- **Review required:** data that may be reclaimable but needs context or an
  explicit user decision.
- **Protected:** user content, active data, unknown data, broad system paths, or
  anything that fails a safety check.

Unknown is protected, not reclaimable or review-required.

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
- The app and CLI expose no cleanup, delete, move, quarantine, or
  permission-escalation action; scan and classification reports remain
  read-only.
- The app never presents a partial, bounded, or overflowed observation as
  complete or as evidence that an item can be cleaned.
- Core logic does not construct or execute shell commands.
- Failure to read metadata produces a visible error or skip, never permission
  escalation or an unsafe assumption.
- A newest observed inode modification time is not proof of inactivity,
  ownership, generated content, or the absence of protected descendants. An
  incomplete item never turns its partial maximum into known age evidence.
- A scan-time `(device, inode)` pair is only a token for binding a later
  read-only observation. It is not trusted-location or ownership evidence and
  grants no cleanup or deletion authority; inode reuse requires immediate
  revalidation before any future mutation.
- A satisfied SwiftPM `workspace-state.json` marker proves only that the exact
  metadata check passed. It does not override an unavailable required fact, so
  the candidate remains `Protected`.
- A candidate remains `Protected` when a required activity check reports active
  use or is unavailable.
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
- an eligible disposition and reproducibility class;
- required activity and age checks;
- user-facing explanations;
- synthetic tests for matches, near misses, and hostile paths.

Path shape alone is insufficient for a high-confidence rule when the path can
contain user-owned content.

The current classifier enforces common integrity checks centrally. Rules only
recognize raw path shapes and project declared evidence; they cannot directly
grant a disposition. An unavailable required fact, invalid rule assessment,
classification conflict, or incomplete scan produces `Protected`. A malformed
returned report is rejected against the request's reference time and original
`ScanReport` before either frontend renders it. The adapter performs no extra
filesystem probing and may project the conservative newest inode time already
retained by a complete scan summary. A separate bounded observer may rebind
retained top-level candidates to their scan-time identities and, for an exact
SwiftPM `.build` directory, inspect only the metadata of an exact
`workspace-state.json` child. A satisfied age or marker check alone is
insufficient: every remaining unknown required fact keeps the real candidate
protected. See the complete [rules contract](RULES.md).

## Test boundary

All filesystem tests use newly created temporary directories and synthetic
fixtures. Tests never point at a real home directory, tool cache, project,
simulator, virtual machine, or browser profile. Mutation tests must assert that
nothing outside the fixture changed.

Any future permanent-removal feature requires a separate design review, threat
model, and release milestone.
