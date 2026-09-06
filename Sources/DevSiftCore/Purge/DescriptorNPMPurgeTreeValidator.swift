import Darwin

/// Resource limits used only by irreversible npm-cache traversal.
///
/// This is deliberately separate from the scan/quarantine limits so a future
/// purge-policy revision cannot silently inherit a broader read-only policy.
struct DescriptorNPMPurgeTraversalLimits: Equatable, Sendable {
  static let current: DescriptorNPMPurgeTraversalLimits = {
    let bounds = QuarantinePurgeJournalResourceBoundsV1.current
    guard
      let maximumEntries = Int(exactly: bounds.maximumEntries),
      let maximumDepth = Int(exactly: bounds.maximumDepth),
      let maximumEntriesPerDirectory = Int(exactly: bounds.maximumEntriesPerDirectory),
      let maximumRawNameBytes = Int(exactly: bounds.maximumRawNameBytes),
      let maximumInterruptedSystemCallAttempts = Int(
        exactly: bounds.maximumInterruptedSystemCallAttempts
      )
    else {
      preconditionFailure("The canonical purge bounds must fit this platform")
    }
    return DescriptorNPMPurgeTraversalLimits(
      maximumEntries: maximumEntries,
      maximumDepth: maximumDepth,
      maximumEntriesPerDirectory: maximumEntriesPerDirectory,
      maximumRawNameBytes: maximumRawNameBytes,
      maximumInterruptedSystemCallAttempts: maximumInterruptedSystemCallAttempts
    )
  }()

  static let defaults = current

  let maximumEntries: Int
  let maximumDepth: Int
  let maximumEntriesPerDirectory: Int
  let maximumRawNameBytes: Int
  let maximumInterruptedSystemCallAttempts: Int

  init(
    maximumEntries: Int,
    maximumDepth: Int,
    maximumEntriesPerDirectory: Int,
    maximumRawNameBytes: Int,
    maximumInterruptedSystemCallAttempts: Int = 3
  ) {
    self.maximumEntries = maximumEntries
    self.maximumDepth = maximumDepth
    self.maximumEntriesPerDirectory = maximumEntriesPerDirectory
    self.maximumRawNameBytes = maximumRawNameBytes
    self.maximumInterruptedSystemCallAttempts = maximumInterruptedSystemCallAttempts
  }

  var isValid: Bool {
    maximumEntries >= 0
      && maximumDepth >= 0
      && maximumEntriesPerDirectory >= 0
      && maximumRawNameBytes >= 0
      && maximumInterruptedSystemCallAttempts > 0
  }
}

struct DescriptorNPMPurgeRemainderValidation: Equatable, Sendable {
  let entryCount: Int
  let rawNameByteCount: Int
  let maximumObservedDepth: Int
}

enum DescriptorNPMPurgeTreeValidationFailure: Error, Equatable, Sendable {
  case invalidLimits
  case rootBindingMismatch
  case treeChanged
  case treeUnsafe
  case layoutMismatch
  case traversalLimitExceeded
}

/// The initial purge gate uses the purge-specific deterministic traversal and
/// additionally requires both generated cache directories. It must never
/// accept an interrupted remainder as a complete cache.
struct DescriptorNPMCompletePurgeTreeValidator: Sendable {
  typealias Checkpoint = DescriptorNPMPurgeRemainderTreeValidator.Checkpoint
  typealias EntryHook = DescriptorNPMPurgeRemainderTreeValidator.EntryHook

  private let validator: DescriptorNPMPurgeRemainderTreeValidator

  init(
    checkpoint: @escaping Checkpoint,
    limits: DescriptorNPMPurgeTraversalLimits = .current,
    beforeTraversalEntry: @escaping EntryHook = { _, _ in }
  ) {
    validator = DescriptorNPMPurgeRemainderTreeValidator(
      checkpoint: checkpoint,
      limits: limits,
      beforeTraversalEntry: beforeTraversalEntry
    )
  }

  func validate(
    descriptor: Int32,
    namedAt parentDescriptor: Int32,
    component: DescriptorPathComponent,
    expected: DescriptorStatSnapshot,
    rootDevice: UInt64,
    accountUID: uid_t
  ) throws -> DescriptorNPMCacheTreeValidation {
    try validator.validateComplete(
      descriptor: descriptor,
      namedAt: parentDescriptor,
      component: component,
      expected: expected,
      rootDevice: rootDevice,
      accountUID: accountUID
    )
  }
}

/// Validates only a deletion-derived remainder of one receipt-bound npm cache.
///
/// Missing names and empty directories are valid here. Every name that still
/// exists must remain valid at its exact position in the pinned npm grammar.
/// The historical root binding deliberately excludes mutable timestamps and
/// link count from retry identity because successful child removal changes
/// those values.
struct DescriptorNPMPurgeRemainderTreeValidator: Sendable {
  typealias Checkpoint = @Sendable () throws -> Void
  typealias EntryHook = @Sendable (Int, Int) throws -> Void

  private let checkpoint: Checkpoint
  private let limits: DescriptorNPMPurgeTraversalLimits
  private let beforeTraversalEntry: EntryHook

  init(
    checkpoint: @escaping Checkpoint,
    limits: DescriptorNPMPurgeTraversalLimits = .defaults,
    beforeTraversalEntry: @escaping EntryHook = { _, _ in }
  ) {
    self.checkpoint = checkpoint
    self.limits = limits
    self.beforeTraversalEntry = beforeTraversalEntry
  }

  func validate(
    descriptor: Int32,
    namedAt parentDescriptor: Int32,
    component: DescriptorPathComponent,
    expectedBinding: QuarantineJournalFileBindingV1,
    rootDevice: UInt64,
    accountUID: uid_t
  ) throws -> DescriptorNPMPurgeRemainderValidation {
    let validation = try validateTree(
      descriptor: descriptor,
      namedAt: parentDescriptor,
      component: component,
      expectedBinding: expectedBinding,
      exactCurrentRoot: nil,
      rootDevice: rootDevice,
      accountUID: accountUID,
      requiresCompleteLayout: false
    )
    return DescriptorNPMPurgeRemainderValidation(
      entryCount: validation.entryCount,
      rawNameByteCount: validation.rawNameByteCount,
      maximumObservedDepth: validation.maximumObservedDepth
    )
  }

  fileprivate func validateComplete(
    descriptor: Int32,
    namedAt parentDescriptor: Int32,
    component: DescriptorPathComponent,
    expected: DescriptorStatSnapshot,
    rootDevice: UInt64,
    accountUID: uid_t
  ) throws -> DescriptorNPMCacheTreeValidation {
    guard let expectedBinding = QuarantineJournalFileBindingV1(snapshot: expected) else {
      throw DescriptorNPMPurgeTreeValidationFailure.rootBindingMismatch
    }
    let validation = try validateTree(
      descriptor: descriptor,
      namedAt: parentDescriptor,
      component: component,
      expectedBinding: expectedBinding,
      exactCurrentRoot: expected,
      rootDevice: rootDevice,
      accountUID: accountUID,
      requiresCompleteLayout: true
    )
    guard let newestModificationUnixSeconds = validation.newestModificationUnixSeconds else {
      throw DescriptorNPMPurgeTreeValidationFailure.treeUnsafe
    }
    return DescriptorNPMCacheTreeValidation(
      newestModificationUnixSeconds: newestModificationUnixSeconds
    )
  }

  private func validateTree(
    descriptor: Int32,
    namedAt parentDescriptor: Int32,
    component: DescriptorPathComponent,
    expectedBinding: QuarantineJournalFileBindingV1,
    exactCurrentRoot: DescriptorStatSnapshot?,
    rootDevice: UInt64,
    accountUID: uid_t,
    requiresCompleteLayout: Bool
  ) throws -> PurgeTreeReadValidation {
    guard limits.isValid else {
      throw DescriptorNPMPurgeTreeValidationFailure.invalidLimits
    }
    try cancellationCheckpoint()

    let openedRoot = try DescriptorStatSnapshot.read(from: descriptor)
    let namedRoot = try DescriptorStatSnapshot.read(
      at: parentDescriptor,
      component: component
    )
    guard
      historicalRootBinding(openedRoot, matches: expectedBinding),
      historicalRootBinding(namedRoot, matches: expectedBinding),
      stableCurrentSnapshot(namedRoot, equals: openedRoot),
      expectedBinding.device == rootDevice,
      expectedBinding.ownerUID == UInt32(accountUID),
      expectedBinding.kind == .directory,
      expectedBinding.permissionMode <= 0o7777,
      expectedBinding.permissionMode & 0o022 == 0,
      expectedBinding.flags == 0,
      expectedBinding.linkCount > 0
    else {
      throw DescriptorNPMPurgeTreeValidationFailure.rootBindingMismatch
    }
    if let exactCurrentRoot {
      guard
        stableCurrentSnapshot(openedRoot, equals: exactCurrentRoot),
        stableCurrentSnapshot(namedRoot, equals: exactCurrentRoot)
      else {
        throw DescriptorNPMPurgeTreeValidationFailure.treeChanged
      }
    }
    guard
      openedRoot.kind == .directory,
      openedRoot.linkCount >= 2,
      openedRoot.identity.device == rootDevice,
      openedRoot.ownerUID == accountUID,
      hasSafeMutationMetadata(openedRoot),
      try !descriptorHasExtendedACL(descriptor)
    else {
      throw DescriptorNPMPurgeTreeValidationFailure.treeUnsafe
    }

    var state = PurgeRemainderTraversalState(
      limits: limits,
      accountUID: accountUID,
      rootDevice: rootDevice,
      seenDirectoryIdentities: [openedRoot.identity]
    )
    if requiresCompleteLayout {
      try state.recordModification(openedRoot)
    }
    try traverseDirectory(
      descriptor: descriptor,
      namedAt: parentDescriptor,
      component: component,
      expected: openedRoot,
      format: .cacheRoot,
      childDepth: 1,
      isCacheRoot: true,
      requiresCompleteLayout: requiresCompleteLayout,
      state: &state
    )
    if requiresCompleteLayout {
      guard state.requiredCacheRootNames == PurgeRemainderTraversalState.requiredRootNames else {
        throw DescriptorNPMPurgeTreeValidationFailure.layoutMismatch
      }
    }
    return PurgeTreeReadValidation(
      entryCount: state.entryCount,
      rawNameByteCount: state.rawNameByteCount,
      maximumObservedDepth: state.maximumObservedDepth,
      newestModificationUnixSeconds: state.newestModificationUnixSeconds
    )
  }

  private func traverseDirectory(
    descriptor: Int32,
    namedAt parentDescriptor: Int32,
    component: DescriptorPathComponent,
    expected: DescriptorStatSnapshot,
    format: NPMCacheDirectoryFormat,
    childDepth: Int,
    isCacheRoot: Bool,
    requiresCompleteLayout: Bool,
    state: inout PurgeRemainderTraversalState
  ) throws {
    try cancellationCheckpoint()
    let before = try DescriptorStatSnapshot.read(from: descriptor)
    guard stableCurrentSnapshot(before, equals: expected) else {
      throw DescriptorNPMPurgeTreeValidationFailure.treeChanged
    }
    guard
      before.kind == .directory,
      before.linkCount >= 2,
      before.identity.device == state.rootDevice,
      before.ownerUID == state.accountUID,
      hasSafeMutationMetadata(before),
      try !descriptorHasExtendedACL(descriptor)
    else {
      throw DescriptorNPMPurgeTreeValidationFailure.treeUnsafe
    }

    let names = try snapshotNames(
      descriptor: descriptor,
      childDepth: childDepth,
      state: &state
    )
    for rawName in names {
      try cancellationCheckpoint()
      try beforeTraversalEntry(state.visitedEntryCount + 1, childDepth)
      let (visitedEntryCount, overflow) = state.visitedEntryCount.addingReportingOverflow(1)
      guard !overflow else {
        throw DescriptorNPMPurgeTreeValidationFailure.traversalLimitExceeded
      }
      state.visitedEntryCount = visitedEntryCount
      guard
        let childComponent = DescriptorPathComponent(rawName),
        let expectation = format.expectation(for: rawName)
      else {
        throw DescriptorNPMPurgeTreeValidationFailure.layoutMismatch
      }
      if isCacheRoot,
        PurgeRemainderTraversalState.requiredRootNames.contains(rawName)
      {
        state.requiredCacheRootNames.insert(rawName)
      }
      try traverseEntry(
        parentDescriptor: descriptor,
        component: childComponent,
        expectation: expectation,
        childDepth: childDepth,
        requiresCompleteLayout: requiresCompleteLayout,
        state: &state
      )
    }

    let finalOpened = try DescriptorStatSnapshot.read(from: descriptor)
    let finalNamed = try DescriptorStatSnapshot.read(
      at: parentDescriptor,
      component: component
    )
    guard
      stableCurrentSnapshot(finalOpened, equals: expected),
      stableCurrentSnapshot(finalNamed, equals: expected)
    else {
      throw DescriptorNPMPurgeTreeValidationFailure.treeChanged
    }
  }

  private func snapshotNames(
    descriptor: Int32,
    childDepth: Int,
    state: inout PurgeRemainderTraversalState
  ) throws -> [[UInt8]] {
    let enumerationDescriptor = try descriptorOpenCurrentDirectory(descriptor)
    guard let stream = Darwin.fdopendir(enumerationDescriptor) else {
      let code = errno
      descriptorCloseIgnoringErrors(enumerationDescriptor)
      throw DescriptorObservationError.posix(code)
    }
    defer { _ = Darwin.closedir(stream) }

    var names: [[UInt8]] = []
    var directoryEntryCount = 0
    var interruptedAttempts = 0
    while true {
      try cancellationCheckpoint()
      errno = 0
      guard let entry = Darwin.readdir(stream) else {
        let code = errno
        if code == EINTR,
          interruptedAttempts + 1 < limits.maximumInterruptedSystemCallAttempts
        {
          interruptedAttempts += 1
          continue
        }
        guard code == 0 else {
          throw DescriptorObservationError.posix(code)
        }
        break
      }
      interruptedAttempts = 0

      let rawName = descriptorRawName(from: entry)
      if rawName == [0x2E] || rawName == [0x2E, 0x2E] { continue }
      let (nextDirectoryEntryCount, directoryCountOverflow) =
        directoryEntryCount.addingReportingOverflow(1)
      guard
        !directoryCountOverflow,
        nextDirectoryEntryCount <= limits.maximumEntriesPerDirectory
      else {
        throw DescriptorNPMPurgeTreeValidationFailure.traversalLimitExceeded
      }
      directoryEntryCount = nextDirectoryEntryCount
      try state.record(rawName: rawName, depth: childDepth)
      names.append(rawName)
    }
    names.sort { $0.lexicographicallyPrecedes($1) }
    for index in names.indices.dropFirst() where names[index - 1] == names[index] {
      throw DescriptorNPMPurgeTreeValidationFailure.treeChanged
    }
    return names
  }

  private func traverseEntry(
    parentDescriptor: Int32,
    component: DescriptorPathComponent,
    expectation: NPMCacheEntryExpectation,
    childDepth: Int,
    requiresCompleteLayout: Bool,
    state: inout PurgeRemainderTraversalState
  ) throws {
    let namedBefore = try DescriptorStatSnapshot.read(
      at: parentDescriptor,
      component: component
    )
    guard
      namedBefore.kind == expectation.expectedKind,
      namedBefore.identity.device == state.rootDevice,
      namedBefore.ownerUID == state.accountUID,
      hasSafeMutationMetadata(namedBefore)
    else {
      throw DescriptorNPMPurgeTreeValidationFailure.treeUnsafe
    }
    if requiresCompleteLayout {
      try state.recordModification(namedBefore)
    }

    switch namedBefore.kind {
    case .regularFile:
      guard namedBefore.linkCount == 1 else {
        throw DescriptorNPMPurgeTreeValidationFailure.treeUnsafe
      }
      let childDescriptor = try openPurgeRegularFile(
        at: parentDescriptor,
        component: component
      )
      defer { descriptorCloseIgnoringErrors(childDescriptor) }
      let opened = try DescriptorStatSnapshot.read(from: childDescriptor)
      let namedAfter = try DescriptorStatSnapshot.read(
        at: parentDescriptor,
        component: component
      )
      guard
        stableCurrentSnapshot(opened, equals: namedBefore),
        stableCurrentSnapshot(namedAfter, equals: namedBefore),
        opened.kind == .regularFile,
        opened.identity.device == state.rootDevice,
        opened.ownerUID == state.accountUID,
        opened.linkCount == 1,
        hasSafeMutationMetadata(opened)
      else {
        throw DescriptorNPMPurgeTreeValidationFailure.treeChanged
      }
      guard try !descriptorHasExtendedACL(childDescriptor) else {
        throw DescriptorNPMPurgeTreeValidationFailure.treeUnsafe
      }
    case .directory:
      guard
        let childFormat = expectation.childDirectoryFormat,
        state.seenDirectoryIdentities.insert(namedBefore.identity).inserted
      else {
        throw DescriptorNPMPurgeTreeValidationFailure.treeUnsafe
      }
      let childDescriptor = try descriptorOpenTrustedDirectory(
        at: parentDescriptor,
        component: component
      )
      defer { descriptorCloseIgnoringErrors(childDescriptor) }
      let opened = try DescriptorStatSnapshot.read(from: childDescriptor)
      guard
        stableCurrentSnapshot(opened, equals: namedBefore),
        opened.linkCount >= 2,
        opened.identity.device == state.rootDevice,
        opened.ownerUID == state.accountUID,
        hasSafeMutationMetadata(opened)
      else {
        throw DescriptorNPMPurgeTreeValidationFailure.treeChanged
      }
      let (nextDepth, overflow) = childDepth.addingReportingOverflow(1)
      guard !overflow else {
        throw DescriptorNPMPurgeTreeValidationFailure.traversalLimitExceeded
      }
      try traverseDirectory(
        descriptor: childDescriptor,
        namedAt: parentDescriptor,
        component: component,
        expected: opened,
        format: childFormat,
        childDepth: nextDepth,
        isCacheRoot: false,
        requiresCompleteLayout: requiresCompleteLayout,
        state: &state
      )
    case .symbolicLink, .other:
      throw DescriptorNPMPurgeTreeValidationFailure.treeUnsafe
    }
  }

  private func cancellationCheckpoint() throws {
    do {
      try checkpoint()
      try Task.checkCancellation()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw DescriptorNPMPurgeTreeValidationFailure.treeChanged
    }
  }
}

private struct PurgeTreeReadValidation {
  let entryCount: Int
  let rawNameByteCount: Int
  let maximumObservedDepth: Int
  let newestModificationUnixSeconds: Int64?
}

private struct PurgeRemainderTraversalState {
  static let requiredRootNames: Set<[UInt8]> = [
    Array("content-v2".utf8),
    Array("index-v5".utf8),
  ]

  let limits: DescriptorNPMPurgeTraversalLimits
  let accountUID: uid_t
  let rootDevice: UInt64
  var seenDirectoryIdentities: Set<FileIdentity>
  var requiredCacheRootNames: Set<[UInt8]> = []
  var newestModificationUnixSeconds: Int64?
  var entryCount = 0
  var rawNameByteCount = 0
  var maximumObservedDepth = 0
  var visitedEntryCount = 0

  mutating func record(rawName: [UInt8], depth: Int) throws {
    let (newEntryCount, entryOverflow) = entryCount.addingReportingOverflow(1)
    let (newRawNameByteCount, byteOverflow) = rawNameByteCount.addingReportingOverflow(
      rawName.count
    )
    guard
      !entryOverflow,
      !byteOverflow,
      newEntryCount <= limits.maximumEntries,
      depth <= limits.maximumDepth,
      newRawNameByteCount <= limits.maximumRawNameBytes
    else {
      throw DescriptorNPMPurgeTreeValidationFailure.traversalLimitExceeded
    }
    entryCount = newEntryCount
    rawNameByteCount = newRawNameByteCount
    maximumObservedDepth = max(maximumObservedDepth, depth)
  }

  mutating func recordModification(_ snapshot: DescriptorStatSnapshot) throws {
    guard let unixSeconds = snapshot.conservativeModificationUnixSeconds else {
      throw DescriptorNPMPurgeTreeValidationFailure.treeUnsafe
    }
    newestModificationUnixSeconds = max(newestModificationUnixSeconds ?? unixSeconds, unixSeconds)
  }
}

private func historicalRootBinding(
  _ snapshot: DescriptorStatSnapshot,
  matches binding: QuarantineJournalFileBindingV1
) -> Bool {
  snapshot.identity.device == binding.device
    && snapshot.identity.inode == binding.inode
    && snapshot.generation == binding.generation
    && Int64(exactly: snapshot.birthSeconds) == binding.birthSeconds
    && UInt32(exactly: snapshot.birthNanoseconds) == binding.birthNanoseconds
    && snapshot.kind == binding.kind
    && UInt32(exactly: snapshot.ownerUID) == binding.ownerUID
}

private func stableCurrentSnapshot(
  _ observed: DescriptorStatSnapshot,
  equals expected: DescriptorStatSnapshot
) -> Bool {
  observed.sameProtectedDescendantState(as: expected)
    && observed.permissionMode == expected.permissionMode
    && observed.flags == expected.flags
}

private func hasSafeMutationMetadata(_ snapshot: DescriptorStatSnapshot) -> Bool {
  snapshot.permissionMode & mode_t(0o022) == 0 && snapshot.flags == 0
}

private func openPurgeRegularFile(
  at parentDescriptor: Int32,
  component: DescriptorPathComponent
) throws -> Int32 {
  var descriptor: Int32 = -1
  try descriptorRetryingInterrupted {
    descriptor = try component.withCString { pointer in
      let value = Darwin.openat(
        parentDescriptor,
        pointer,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | O_RESOLVE_BENEATH
      )
      guard value >= 0 else { throw DescriptorObservationError.posix(errno) }
      return value
    }
  }
  return descriptor
}
