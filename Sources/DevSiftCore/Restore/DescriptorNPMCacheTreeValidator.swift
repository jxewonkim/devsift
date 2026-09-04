import Darwin

struct DescriptorNPMCacheTreeValidation: Equatable, Sendable {
  let newestModificationUnixSeconds: Int64
}

/// Revalidates the complete npm cache layout from held descriptors without
/// assuming whether the cache is currently active or quarantined.
///
/// The caller keeps both the candidate and its parent descriptor alive for the
/// entire synchronous traversal. This validator never mutates the namespace.
struct DescriptorNPMCacheTreeValidator: Sendable {
  typealias Checkpoint = @Sendable () throws -> Void
  typealias EntryHook = @Sendable (Int, Int) throws -> Void

  private static let contentDirectoryName = Array("content-v2".utf8)
  private static let indexDirectoryName = Array("index-v5".utf8)

  private let checkpoint: Checkpoint
  private let limits: DescriptorNPMQuarantineTraversalLimits
  private let beforeTraversalEntry: EntryHook

  init(
    checkpoint: @escaping Checkpoint,
    limits: DescriptorNPMQuarantineTraversalLimits = .defaults,
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
    expected: DescriptorStatSnapshot,
    rootDevice: UInt64,
    accountUID: uid_t
  ) throws -> DescriptorNPMCacheTreeValidation {
    guard limits.isValid else {
      throw DescriptorNPMQuarantinePreflightFailure.traversalLimitExceeded
    }
    var state = TraversalState(
      limits: limits,
      accountUID: accountUID,
      rootDevice: rootDevice,
      seenDirectoryIdentities: [expected.identity],
      newestModificationUnixSeconds: expected.conservativeModificationUnixSeconds
    )
    guard state.newestModificationUnixSeconds != nil else {
      throw DescriptorNPMQuarantinePreflightFailure.candidateUnsafe
    }

    try traverseDirectory(
      descriptor: descriptor,
      namedAt: parentDescriptor,
      component: component,
      expected: expected,
      format: .cacheRoot,
      childDepth: 1,
      isCacheRoot: true,
      state: &state
    )
    guard
      state.requiredCacheRootNames == [Self.contentDirectoryName, Self.indexDirectoryName],
      let newestModificationUnixSeconds = state.newestModificationUnixSeconds
    else {
      throw DescriptorNPMQuarantinePreflightFailure.layoutMismatch
    }
    return DescriptorNPMCacheTreeValidation(
      newestModificationUnixSeconds: newestModificationUnixSeconds
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
    state: inout TraversalState
  ) throws {
    try checkpoint()
    let before = try DescriptorStatSnapshot.read(from: descriptor)
    guard stableSnapshot(before, equals: expected) else {
      throw DescriptorNPMQuarantinePreflightFailure.candidateChanged
    }
    guard try !descriptorHasExtendedACL(descriptor) else {
      throw DescriptorNPMQuarantinePreflightFailure.candidateUnsafe
    }

    let enumerationDescriptor = try descriptorOpenCurrentDirectory(descriptor)
    guard let stream = Darwin.fdopendir(enumerationDescriptor) else {
      let code = errno
      descriptorCloseIgnoringErrors(enumerationDescriptor)
      throw DescriptorObservationError.posix(code)
    }
    defer { _ = Darwin.closedir(stream) }

    var interruptedAttempts = 0
    while true {
      try checkpoint()
      errno = 0
      guard let entry = Darwin.readdir(stream) else {
        let code = errno
        if code == EINTR, interruptedAttempts + 1 < 3 {
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
      try state.record(rawName: rawName, depth: childDepth)
      try beforeTraversalEntry(state.entryCount, childDepth)
      try checkpoint()
      guard
        let childComponent = DescriptorPathComponent(rawName),
        let expectation = format.expectation(for: rawName)
      else {
        throw DescriptorNPMQuarantinePreflightFailure.layoutMismatch
      }
      if isCacheRoot,
        rawName == Self.contentDirectoryName || rawName == Self.indexDirectoryName
      {
        state.requiredCacheRootNames.insert(rawName)
      }
      try traverseEntry(
        parentDescriptor: descriptor,
        component: childComponent,
        expectation: expectation,
        childDepth: childDepth,
        state: &state
      )
    }

    let finalOpened = try DescriptorStatSnapshot.read(from: descriptor)
    let finalNamed = try DescriptorStatSnapshot.read(
      at: parentDescriptor,
      component: component
    )
    guard
      stableSnapshot(finalOpened, equals: expected),
      stableSnapshot(finalNamed, equals: expected)
    else {
      throw DescriptorNPMQuarantinePreflightFailure.candidateChanged
    }
  }

  private func traverseEntry(
    parentDescriptor: Int32,
    component: DescriptorPathComponent,
    expectation: NPMCacheEntryExpectation,
    childDepth: Int,
    state: inout TraversalState
  ) throws {
    let namedBefore = try DescriptorStatSnapshot.read(
      at: parentDescriptor,
      component: component
    )
    guard
      let modificationUnixSeconds = namedBefore.conservativeModificationUnixSeconds,
      namedBefore.kind == expectation.expectedKind,
      namedBefore.identity.device == state.rootDevice,
      namedBefore.ownerUID == state.accountUID,
      accountOwnsWriteAccess(namedBefore)
    else {
      throw DescriptorNPMQuarantinePreflightFailure.candidateUnsafe
    }
    state.recordModification(modificationUnixSeconds)

    switch namedBefore.kind {
    case .regularFile:
      guard namedBefore.linkCount == 1 else {
        throw DescriptorNPMQuarantinePreflightFailure.candidateUnsafe
      }
      let childDescriptor = try openRegularFile(
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
        stableSnapshot(opened, equals: namedBefore),
        stableSnapshot(namedAfter, equals: namedBefore),
        opened.kind == .regularFile,
        opened.ownerUID == state.accountUID,
        opened.linkCount == 1,
        accountOwnsWriteAccess(opened)
      else {
        throw DescriptorNPMQuarantinePreflightFailure.candidateChanged
      }
      guard try !descriptorHasExtendedACL(childDescriptor) else {
        throw DescriptorNPMQuarantinePreflightFailure.candidateUnsafe
      }
    case .directory:
      guard
        let childFormat = expectation.childDirectoryFormat,
        state.seenDirectoryIdentities.insert(namedBefore.identity).inserted
      else {
        throw DescriptorNPMQuarantinePreflightFailure.candidateUnsafe
      }
      let childDescriptor = try descriptorOpenTrustedDirectory(
        at: parentDescriptor,
        component: component
      )
      defer { descriptorCloseIgnoringErrors(childDescriptor) }
      let opened = try DescriptorStatSnapshot.read(from: childDescriptor)
      guard
        stableSnapshot(opened, equals: namedBefore),
        accountOwnsWriteAccess(opened)
      else {
        throw DescriptorNPMQuarantinePreflightFailure.candidateChanged
      }
      let (nextDepth, overflow) = childDepth.addingReportingOverflow(1)
      guard !overflow else {
        throw DescriptorNPMQuarantinePreflightFailure.traversalLimitExceeded
      }
      try traverseDirectory(
        descriptor: childDescriptor,
        namedAt: parentDescriptor,
        component: component,
        expected: opened,
        format: childFormat,
        childDepth: nextDepth,
        isCacheRoot: false,
        state: &state
      )
    case .symbolicLink, .other:
      throw DescriptorNPMQuarantinePreflightFailure.candidateUnsafe
    }
  }

  private func stableSnapshot(
    _ observed: DescriptorStatSnapshot,
    equals expected: DescriptorStatSnapshot
  ) -> Bool {
    observed.sameProtectedDescendantState(as: expected)
      && observed.permissionMode == expected.permissionMode
      && observed.flags == expected.flags
  }

  private func accountOwnsWriteAccess(_ snapshot: DescriptorStatSnapshot) -> Bool {
    snapshot.permissionMode & mode_t(0o022) == 0 && snapshot.flags == 0
  }
}

private struct TraversalState {
  let limits: DescriptorNPMQuarantineTraversalLimits
  let accountUID: uid_t
  let rootDevice: UInt64
  var seenDirectoryIdentities: Set<FileIdentity>
  var newestModificationUnixSeconds: Int64?
  var requiredCacheRootNames: Set<[UInt8]> = []
  var entryCount = 0
  var rawNameBytes = 0

  mutating func record(rawName: [UInt8], depth: Int) throws {
    let (newEntryCount, entryOverflow) = entryCount.addingReportingOverflow(1)
    let (newRawNameBytes, byteOverflow) = rawNameBytes.addingReportingOverflow(rawName.count)
    guard
      !entryOverflow,
      !byteOverflow,
      newEntryCount <= limits.maximumEntries,
      depth <= limits.maximumDepth,
      newRawNameBytes <= limits.maximumRawNameBytes
    else {
      throw DescriptorNPMQuarantinePreflightFailure.traversalLimitExceeded
    }
    entryCount = newEntryCount
    rawNameBytes = newRawNameBytes
  }

  mutating func recordModification(_ unixSeconds: Int64) {
    newestModificationUnixSeconds = max(newestModificationUnixSeconds ?? unixSeconds, unixSeconds)
  }
}

private func openRegularFile(
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
