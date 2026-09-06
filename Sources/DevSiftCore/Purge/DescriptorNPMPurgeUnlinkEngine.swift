import Darwin

enum DescriptorNPMPurgeUnlinkAttemptKind: String, Equatable, Sendable {
  case initial
  case retry
}

enum DescriptorNPMPurgeUnlinkStopReason: Equatable, Sendable {
  case invalidRequest
  case cancelled
  case preflightValidationFailed(DescriptorNPMPurgeTreeValidationFailure)
  case treeChanged
  case treeUnsafe
  case traversalLimitExceeded
  case synchronizationLimitExceeded
  case observationUnavailable(CleanupQuarantineSystemFailure)
  case unlinkFailed(CleanupQuarantineSystemFailure)
  case synchronizationFailed(CleanupQuarantineSystemFailure)
}

enum DescriptorNPMPurgeUnlinkStatus: Equatable, Sendable {
  /// The exact staged work name was observed absent after its parent barrier.
  /// A caller must still reconcile the original quarantine name before it can
  /// publish an `item-absent` receipt.
  case itemAbsent

  /// The exact work root remains and every directory dirtied by this call was
  /// observed and synchronized. A separately authorized retry is required.
  case synchronizedPartial(reason: DescriptorNPMPurgeUnlinkStopReason)

  /// Current namespace or durability evidence is not strong enough to offer a
  /// retry. The receipt-less intent must remain for manual recovery.
  case durabilityUnresolved(reason: DescriptorNPMPurgeUnlinkStopReason)
}

struct DescriptorNPMPurgeUnlinkReport: Equatable, Sendable {
  let status: DescriptorNPMPurgeUnlinkStatus

  /// Number of names observed absent after this call invoked `unlinkat` for
  /// them. This is process-local progress, not a causal deletion or reclaimed-
  /// capacity claim.
  let observedAbsentNameCount: UInt64
  let cancellationWasRequested: Bool
  let synchronizationOperationCount: UInt64
}

struct DescriptorNPMPurgeUnlinkRequest: Sendable {
  let quarantineRootDescriptor: Int32
  let purgeWorkDescriptor: Int32
  let purgeWorkComponent: DescriptorPathComponent
  let historicalCandidateBinding: QuarantineJournalFileBindingV1
  let accountUID: uid_t
  let rootDevice: UInt64
  let attemptKind: DescriptorNPMPurgeUnlinkAttemptKind
  let resourceBounds: QuarantinePurgeJournalResourceBoundsV1
}

struct DescriptorNPMPurgeUnlinkHooks: Sendable {
  typealias UnlinkHook =
    @Sendable (Int32, DescriptorPathComponent, Int32) -> Void
  typealias UnlinkResultHook =
    @Sendable (DescriptorPathComponent, Int32, Int32?) -> Void

  var didPassAttemptValidator: @Sendable () -> Void
  var didSnapshotDirectory: @Sendable (Int, Int) -> Void
  var beforeUnlink: UnlinkHook
  var didReturnFromUnlink: UnlinkResultHook
  var willFullSync: @Sendable (Int32) -> Void

  init(
    didPassAttemptValidator: @escaping @Sendable () -> Void = {},
    didSnapshotDirectory: @escaping @Sendable (Int, Int) -> Void = { _, _ in },
    beforeUnlink: @escaping UnlinkHook = { _, _, _ in },
    didReturnFromUnlink: @escaping UnlinkResultHook = { _, _, _ in },
    willFullSync: @escaping @Sendable (Int32) -> Void = { _ in }
  ) {
    self.didPassAttemptValidator = didPassAttemptValidator
    self.didSnapshotDirectory = didSnapshotDirectory
    self.beforeUnlink = beforeUnlink
    self.didReturnFromUnlink = didReturnFromUnlink
    self.willFullSync = willFullSync
  }
}

struct DescriptorNPMPurgeUnlinkDependencies: Sendable {
  typealias UnlinkAt =
    @Sendable (Int32, DescriptorPathComponent, Int32) -> Int32?
  typealias FullSync = @Sendable (Int32) -> Int32?

  var unlinkAt: UnlinkAt
  var fullSync: FullSync
  var cancellationIsRequested: @Sendable () -> Bool
  var hooks: DescriptorNPMPurgeUnlinkHooks

  init(
    unlinkAt: @escaping UnlinkAt = descriptorNPMPurgeUnlinkAt,
    fullSync: @escaping FullSync = descriptorNPMPurgeFullSync,
    cancellationIsRequested: @escaping @Sendable () -> Bool = { Task.isCancelled },
    hooks: DescriptorNPMPurgeUnlinkHooks = DescriptorNPMPurgeUnlinkHooks()
  ) {
    self.unlinkAt = unlinkAt
    self.fullSync = fullSync
    self.cancellationIsRequested = cancellationIsRequested
    self.hooks = hooks
  }
}

/// Deletes only one already-staged, receipt-bound npm cache tree.
///
/// Every descendant operation is relative to a held parent descriptor and one
/// validated raw component. There is intentionally no path-based fallback.
/// Darwin cannot atomically condition `unlinkat` on the inode validated just
/// before it, so an actively racing same-UID process can still swap the final
/// name. The engine limits that platform race with no-follow opens, exact
/// opened-versus-named checks, post-call reconciliation, and immediate stop;
/// it does not claim to eliminate the race.
struct DescriptorNPMPurgeUnlinkEngine: Sendable {
  private let dependencies: DescriptorNPMPurgeUnlinkDependencies

  init(
    dependencies: DescriptorNPMPurgeUnlinkDependencies =
      DescriptorNPMPurgeUnlinkDependencies()
  ) {
    self.dependencies = dependencies
  }

  func execute(_ request: DescriptorNPMPurgeUnlinkRequest) -> DescriptorNPMPurgeUnlinkReport {
    guard
      let policy = DescriptorNPMPurgeUnlinkPolicy(
        request.resourceBounds,
        accountUID: request.accountUID,
        rootDevice: request.rootDevice
      ),
      request.resourceBounds == .current,
      request.accountUID != 0,
      Darwin.getuid() == request.accountUID,
      Darwin.geteuid() == request.accountUID,
      request.rootDevice == request.historicalCandidateBinding.device,
      request.historicalCandidateBinding.kind == .directory,
      request.historicalCandidateBinding.ownerUID == UInt32(exactly: request.accountUID),
      request.historicalCandidateBinding.birthNanoseconds < 1_000_000_000,
      request.historicalCandidateBinding.permissionMode <= 0o7777,
      request.historicalCandidateBinding.permissionMode & 0o022 == 0,
      request.historicalCandidateBinding.flags == 0,
      request.historicalCandidateBinding.linkCount > 0,
      descriptorNPMPurgeIsWorkComponent(request.purgeWorkComponent)
    else {
      return DescriptorNPMPurgeUnlinkReport(
        status: .durabilityUnresolved(reason: .invalidRequest),
        observedAbsentNameCount: 0,
        cancellationWasRequested: false,
        synchronizationOperationCount: 0
      )
    }

    var state = DescriptorNPMPurgeUnlinkState(policy: policy)
    do {
      let quarantineRoot = try makeQuarantineRootContext(request, policy: policy)
      let workRoot = try makeWorkRootContext(
        request,
        quarantineRoot: quarantineRoot,
        policy: policy
      )

      do {
        try cancellationCheckpoint(state: &state)
        try validateBeforeFirstUnlink(
          request,
          workRoot: workRoot,
          policy: policy
        )
        dependencies.hooks.didPassAttemptValidator()
        _ = try validateDirectory(quarantineRoot, policy: policy)
        let validatedWorkRoot = try validateDirectory(workRoot, policy: policy)
        guard state.seenDirectoryIdentities.insert(validatedWorkRoot.identity).inserted else {
          throw DescriptorNPMPurgeUnlinkHalt(.treeUnsafe, disposition: .unresolved)
        }
        try cancellationCheckpoint(state: &state)

        try purgeDirectoryContents(
          workRoot,
          format: .cacheRoot,
          childDepth: 1,
          requiresCompleteRootLayout: request.attemptKind == .initial,
          state: &state
        )
        try cancellationCheckpoint(state: &state)
        guard try directoryIsEmpty(workRoot, policy: policy) else {
          throw DescriptorNPMPurgeUnlinkHalt(.treeChanged, disposition: .unresolved)
        }
        _ = try validateDirectory(workRoot, policy: policy)
        try cancellationCheckpoint(state: &state)

        var quarantineRootMayBeDirty = false
        do {
          try invokeAndReconcileUnlink(
            parent: quarantineRoot,
            component: request.purgeWorkComponent,
            openedDescriptor: request.purgeWorkDescriptor,
            expectedBefore: try readDescriptor(request.purgeWorkDescriptor, policy: policy),
            flags: AT_REMOVEDIR,
            parentMayBeDirty: &quarantineRootMayBeDirty,
            state: &state
          )
        } catch let halt as DescriptorNPMPurgeUnlinkHalt {
          let rootBarrierWasRequired = quarantineRootMayBeDirty
          let finalHalt = synchronizeDirtyParentIfNeeded(
            quarantineRoot,
            isDirty: &quarantineRootMayBeDirty,
            originalHalt: halt,
            state: &state
          )
          if quarantineRootMayBeDirty {
            return report(
              status: .durabilityUnresolved(reason: finalHalt.reason),
              state: state
            )
          }
          return finish(
            finalHalt,
            request: request,
            quarantineRoot: quarantineRoot,
            workRoot: workRoot,
            workNameParentIsSynchronized:
              rootBarrierWasRequired && !quarantineRootMayBeDirty,
            state: &state
          )
        }

        if let syncReason = synchronizeDirectory(quarantineRoot, state: &state) {
          return report(
            status: .durabilityUnresolved(reason: syncReason),
            state: state
          )
        }
        quarantineRootMayBeDirty = false
        switch observeNamed(
          at: request.quarantineRootDescriptor,
          component: request.purgeWorkComponent,
          policy: policy
        ) {
        case .missing:
          return report(status: .itemAbsent, state: state)
        case .present:
          return report(
            status: .durabilityUnresolved(reason: .treeChanged),
            state: state
          )
        case .unavailable(let failure):
          return report(
            status: .durabilityUnresolved(reason: .observationUnavailable(failure)),
            state: state
          )
        }
      } catch let halt as DescriptorNPMPurgeUnlinkHalt {
        return finish(
          halt,
          request: request,
          quarantineRoot: quarantineRoot,
          workRoot: workRoot,
          state: &state
        )
      } catch {
        return report(
          status: .durabilityUnresolved(reason: .observationUnavailable(.unspecified)),
          state: state
        )
      }
    } catch let halt as DescriptorNPMPurgeUnlinkHalt {
      return report(
        status: .durabilityUnresolved(reason: halt.reason),
        state: state
      )
    } catch {
      return report(
        status: .durabilityUnresolved(reason: .observationUnavailable(.unspecified)),
        state: state
      )
    }
  }

  private func validateBeforeFirstUnlink(
    _ request: DescriptorNPMPurgeUnlinkRequest,
    workRoot: DescriptorNPMPurgeDirectoryContext,
    policy: DescriptorNPMPurgeUnlinkPolicy
  ) throws {
    do {
      switch request.attemptKind {
      case .initial:
        let current = try validateDirectory(workRoot, policy: policy)
        _ = try DescriptorNPMCompletePurgeTreeValidator(
          checkpoint: { try cancellationCheckpointForValidator() },
          limits: policy.traversalLimits
        ).validate(
          descriptor: request.purgeWorkDescriptor,
          namedAt: request.quarantineRootDescriptor,
          component: request.purgeWorkComponent,
          expected: current,
          rootDevice: request.rootDevice,
          accountUID: request.accountUID
        )
      case .retry:
        _ = try DescriptorNPMPurgeRemainderTreeValidator(
          checkpoint: { try cancellationCheckpointForValidator() },
          limits: policy.traversalLimits
        ).validate(
          descriptor: request.purgeWorkDescriptor,
          namedAt: request.quarantineRootDescriptor,
          component: request.purgeWorkComponent,
          expectedBinding: request.historicalCandidateBinding,
          rootDevice: request.rootDevice,
          accountUID: request.accountUID
        )
      }
    } catch is CancellationError {
      throw DescriptorNPMPurgeUnlinkHalt(.cancelled, disposition: .retryable)
    } catch let failure as DescriptorNPMPurgeTreeValidationFailure {
      throw DescriptorNPMPurgeUnlinkHalt(
        .preflightValidationFailed(failure),
        disposition: .unresolved
      )
    } catch {
      throw DescriptorNPMPurgeUnlinkHalt(
        .observationUnavailable(descriptorJournalFailure(for: error)),
        disposition: .unresolved
      )
    }
  }

  private func purgeDirectoryContents(
    _ directory: DescriptorNPMPurgeDirectoryContext,
    format: NPMCacheDirectoryFormat,
    childDepth: Int,
    requiresCompleteRootLayout: Bool = false,
    state: inout DescriptorNPMPurgeUnlinkState
  ) throws {
    var directoryMayBeDirty = false
    do {
      try cancellationCheckpoint(state: &state)
      _ = try validateDirectory(directory, policy: state.policy)
      let names = try snapshotNames(
        directory,
        childDepth: childDepth,
        state: &state
      )
      if requiresCompleteRootLayout {
        let observedNames = Set(names)
        guard
          DescriptorNPMPurgeUnlinkState.requiredCompleteRootNames.isSubset(
            of: observedNames
          )
        else {
          throw DescriptorNPMPurgeUnlinkHalt(.treeChanged, disposition: .unresolved)
        }
      }

      for rawName in names {
        try cancellationCheckpoint(state: &state)
        guard let component = DescriptorPathComponent(rawName),
          let expectation = format.expectation(for: rawName)
        else {
          throw DescriptorNPMPurgeUnlinkHalt(.treeUnsafe, disposition: .unresolved)
        }
        try purgeEntry(
          parent: directory,
          component: component,
          expectation: expectation,
          childDepth: childDepth,
          parentMayBeDirty: &directoryMayBeDirty,
          state: &state
        )
      }

      try cancellationCheckpoint(state: &state)
      guard try directoryIsEmpty(directory, policy: state.policy) else {
        throw DescriptorNPMPurgeUnlinkHalt(.treeChanged, disposition: .unresolved)
      }
      let synchronizationFailure = synchronizeDirectory(directory, state: &state)
      directoryMayBeDirty = false
      guard synchronizationFailure == nil else {
        throw DescriptorNPMPurgeUnlinkHalt(
          synchronizationFailure ?? .synchronizationFailed(.unspecified),
          disposition: .unresolved
        )
      }
      _ = try validateDirectory(directory, policy: state.policy)
    } catch let halt as DescriptorNPMPurgeUnlinkHalt {
      let finalHalt = synchronizeDirtyParentIfNeeded(
        directory,
        isDirty: &directoryMayBeDirty,
        originalHalt: halt,
        state: &state
      )
      throw finalHalt
    }
  }

  private func purgeEntry(
    parent: DescriptorNPMPurgeDirectoryContext,
    component: DescriptorPathComponent,
    expectation: NPMCacheEntryExpectation,
    childDepth: Int,
    parentMayBeDirty: inout Bool,
    state: inout DescriptorNPMPurgeUnlinkState
  ) throws {
    let namedBefore = try readRequiredNamed(
      at: parent.descriptor,
      component: component,
      policy: state.policy
    )
    try validateEntrySnapshot(
      namedBefore,
      expectedKind: expectation.expectedKind,
      policy: state.policy
    )

    let childDescriptor = try openEntry(
      at: parent.descriptor,
      component: component,
      kind: expectation.expectedKind,
      policy: state.policy
    )
    defer { descriptorCloseIgnoringErrors(childDescriptor) }

    let opened = try readDescriptor(childDescriptor, policy: state.policy)
    let namedAfter = try readRequiredNamed(
      at: parent.descriptor,
      component: component,
      policy: state.policy
    )
    guard descriptorNPMPurgeSameCurrentSnapshot(opened, namedBefore),
      descriptorNPMPurgeSameCurrentSnapshot(namedAfter, namedBefore)
    else {
      throw DescriptorNPMPurgeUnlinkHalt(.treeChanged, disposition: .unresolved)
    }
    try validateEntrySnapshot(
      opened,
      expectedKind: expectation.expectedKind,
      policy: state.policy
    )
    do {
      guard try !descriptorHasExtendedACL(childDescriptor) else {
        throw DescriptorNPMPurgeUnlinkHalt(.treeUnsafe, disposition: .unresolved)
      }
    } catch let halt as DescriptorNPMPurgeUnlinkHalt {
      throw halt
    } catch {
      throw DescriptorNPMPurgeUnlinkHalt(
        .observationUnavailable(descriptorJournalFailure(for: error)),
        disposition: .unresolved
      )
    }

    switch expectation.expectedKind {
    case .regularFile:
      try cancellationCheckpoint(state: &state)
      try invokeAndReconcileUnlink(
        parent: parent,
        component: component,
        openedDescriptor: childDescriptor,
        expectedBefore: opened,
        flags: 0,
        parentMayBeDirty: &parentMayBeDirty,
        state: &state
      )
    case .directory:
      guard let childFormat = expectation.childDirectoryFormat else {
        throw DescriptorNPMPurgeUnlinkHalt(.treeUnsafe, disposition: .unresolved)
      }
      guard let stable = DescriptorNPMPurgeStableDirectoryBinding(opened),
        state.seenDirectoryIdentities.insert(opened.identity).inserted
      else {
        throw DescriptorNPMPurgeUnlinkHalt(.treeUnsafe, disposition: .unresolved)
      }
      let child = DescriptorNPMPurgeDirectoryContext(
        descriptor: childDescriptor,
        namedAt: parent.descriptor,
        component: component,
        stableBinding: stable,
        accountUID: state.policy.accountUID,
        rootDevice: state.policy.rootDevice
      )
      let (nextDepth, overflow) = childDepth.addingReportingOverflow(1)
      guard !overflow else {
        throw DescriptorNPMPurgeUnlinkHalt(
          .traversalLimitExceeded,
          disposition: .unresolved
        )
      }
      try purgeDirectoryContents(
        child,
        format: childFormat,
        childDepth: nextDepth,
        requiresCompleteRootLayout: false,
        state: &state
      )
      guard try directoryIsEmpty(child, policy: state.policy) else {
        throw DescriptorNPMPurgeUnlinkHalt(.treeChanged, disposition: .unresolved)
      }
      let current = try validateDirectory(child, policy: state.policy)
      try cancellationCheckpoint(state: &state)
      try invokeAndReconcileUnlink(
        parent: parent,
        component: component,
        openedDescriptor: childDescriptor,
        expectedBefore: current,
        flags: AT_REMOVEDIR,
        parentMayBeDirty: &parentMayBeDirty,
        state: &state
      )
    case .symbolicLink, .other:
      throw DescriptorNPMPurgeUnlinkHalt(.treeUnsafe, disposition: .unresolved)
    }
  }

  private func invokeAndReconcileUnlink(
    parent: DescriptorNPMPurgeDirectoryContext,
    component: DescriptorPathComponent,
    openedDescriptor: Int32,
    expectedBefore: DescriptorStatSnapshot,
    flags: Int32,
    parentMayBeDirty: inout Bool,
    state: inout DescriptorNPMPurgeUnlinkState
  ) throws {
    var attempt = 0
    while true {
      try cancellationCheckpoint(state: &state)
      _ = try validateDirectory(parent, policy: state.policy)
      let openedImmediatelyBefore = try readDescriptor(
        openedDescriptor,
        policy: state.policy
      )
      let namedImmediatelyBefore = try readRequiredNamed(
        at: parent.descriptor,
        component: component,
        policy: state.policy
      )
      guard
        descriptorNPMPurgeSameCurrentSnapshot(openedImmediatelyBefore, expectedBefore),
        descriptorNPMPurgeSameCurrentSnapshot(namedImmediatelyBefore, expectedBefore)
      else {
        throw DescriptorNPMPurgeUnlinkHalt(.treeChanged, disposition: .unresolved)
      }
      let expectedKind: FileSystemEntryKind =
        flags == AT_REMOVEDIR ? .directory : .regularFile
      try validateEntrySnapshot(
        openedImmediatelyBefore,
        expectedKind: expectedKind,
        policy: state.policy
      )
      do {
        guard try !descriptorHasExtendedACL(openedDescriptor) else {
          throw DescriptorNPMPurgeUnlinkHalt(.treeUnsafe, disposition: .unresolved)
        }
      } catch let halt as DescriptorNPMPurgeUnlinkHalt {
        throw halt
      } catch {
        throw DescriptorNPMPurgeUnlinkHalt(
          .observationUnavailable(descriptorJournalFailure(for: error)),
          disposition: .unresolved
        )
      }
      dependencies.hooks.beforeUnlink(parent.descriptor, component, flags)
      try cancellationCheckpoint(state: &state)

      parentMayBeDirty = true
      let failureCode = dependencies.unlinkAt(parent.descriptor, component, flags)
      dependencies.hooks.didReturnFromUnlink(component, flags, failureCode)

      let observation = observeNamed(
        at: parent.descriptor,
        component: component,
        policy: state.policy
      )
      switch observation {
      case .missing:
        try state.recordObservedAbsentName()
        if dependencies.cancellationIsRequested() || Task.isCancelled {
          state.cancellationWasRequested = true
          throw DescriptorNPMPurgeUnlinkHalt(.cancelled, disposition: .retryable)
        }
        if let failureCode {
          throw DescriptorNPMPurgeUnlinkHalt(
            .unlinkFailed(descriptorJournalFailure(for: failureCode)),
            disposition: .retryable
          )
        }
        return
      case .present(let current):
        let openedNow: DescriptorStatSnapshot
        do {
          openedNow = try readDescriptor(openedDescriptor, policy: state.policy)
        } catch let halt as DescriptorNPMPurgeUnlinkHalt {
          throw halt
        }
        guard descriptorNPMPurgeSameCurrentSnapshot(current, expectedBefore),
          descriptorNPMPurgeSameCurrentSnapshot(openedNow, expectedBefore)
        else {
          throw DescriptorNPMPurgeUnlinkHalt(.treeChanged, disposition: .unresolved)
        }
        guard let failureCode else {
          throw DescriptorNPMPurgeUnlinkHalt(.treeChanged, disposition: .unresolved)
        }
        if failureCode == EINTR,
          attempt + 1 < state.policy.maximumInterruptedSystemCallAttempts
        {
          attempt += 1
          continue
        }
        throw DescriptorNPMPurgeUnlinkHalt(
          .unlinkFailed(descriptorJournalFailure(for: failureCode)),
          disposition: .retryable
        )
      case .unavailable(let failure):
        throw DescriptorNPMPurgeUnlinkHalt(
          .observationUnavailable(failure),
          disposition: .unresolved
        )
      }
    }
  }

  private func snapshotNames(
    _ directory: DescriptorNPMPurgeDirectoryContext,
    childDepth: Int,
    state: inout DescriptorNPMPurgeUnlinkState
  ) throws -> [[UInt8]] {
    let enumerationDescriptor = try openCurrentDirectory(
      directory.descriptor,
      policy: state.policy
    )
    guard let stream = Darwin.fdopendir(enumerationDescriptor) else {
      let code = errno
      descriptorCloseIgnoringErrors(enumerationDescriptor)
      throw DescriptorNPMPurgeUnlinkHalt(
        .observationUnavailable(descriptorJournalFailure(for: code)),
        disposition: .unresolved
      )
    }
    defer { _ = Darwin.closedir(stream) }

    var names: [[UInt8]] = []
    var directoryEntryCount = 0
    var interruptedAttempts = 0
    while true {
      try cancellationCheckpoint(state: &state)
      errno = 0
      guard let entry = Darwin.readdir(stream) else {
        let code = errno
        if code == EINTR,
          interruptedAttempts + 1 < state.policy.maximumInterruptedSystemCallAttempts
        {
          interruptedAttempts += 1
          continue
        }
        guard code == 0 else {
          throw DescriptorNPMPurgeUnlinkHalt(
            .observationUnavailable(descriptorJournalFailure(for: code)),
            disposition: .unresolved
          )
        }
        break
      }
      interruptedAttempts = 0

      let rawName = descriptorRawName(from: entry)
      if rawName == [0x2E] || rawName == [0x2E, 0x2E] { continue }
      let (nextDirectoryEntryCount, overflow) = directoryEntryCount.addingReportingOverflow(1)
      guard !overflow,
        nextDirectoryEntryCount <= state.policy.maximumEntriesPerDirectory
      else {
        throw DescriptorNPMPurgeUnlinkHalt(
          .traversalLimitExceeded,
          disposition: .unresolved
        )
      }
      directoryEntryCount = nextDirectoryEntryCount
      try state.record(rawName: rawName, depth: childDepth)
      names.append(rawName)
    }

    names.sort { $0.lexicographicallyPrecedes($1) }
    for index in names.indices.dropFirst() where names[index - 1] == names[index] {
      throw DescriptorNPMPurgeUnlinkHalt(.treeChanged, disposition: .unresolved)
    }
    dependencies.hooks.didSnapshotDirectory(childDepth, names.count)
    return names
  }

  private func directoryIsEmpty(
    _ directory: DescriptorNPMPurgeDirectoryContext,
    policy: DescriptorNPMPurgeUnlinkPolicy
  ) throws -> Bool {
    _ = try validateDirectory(directory, policy: policy)
    let enumerationDescriptor = try openCurrentDirectory(directory.descriptor, policy: policy)
    guard let stream = Darwin.fdopendir(enumerationDescriptor) else {
      let code = errno
      descriptorCloseIgnoringErrors(enumerationDescriptor)
      throw DescriptorNPMPurgeUnlinkHalt(
        .observationUnavailable(descriptorJournalFailure(for: code)),
        disposition: .unresolved
      )
    }
    defer { _ = Darwin.closedir(stream) }

    var interruptedAttempts = 0
    while true {
      errno = 0
      guard let entry = Darwin.readdir(stream) else {
        let code = errno
        if code == EINTR,
          interruptedAttempts + 1 < policy.maximumInterruptedSystemCallAttempts
        {
          interruptedAttempts += 1
          continue
        }
        guard code == 0 else {
          throw DescriptorNPMPurgeUnlinkHalt(
            .observationUnavailable(descriptorJournalFailure(for: code)),
            disposition: .unresolved
          )
        }
        return true
      }
      interruptedAttempts = 0
      let rawName = descriptorRawName(from: entry)
      if rawName != [0x2E] && rawName != [0x2E, 0x2E] {
        return false
      }
    }
  }

  private func synchronizeDirtyParentIfNeeded(
    _ directory: DescriptorNPMPurgeDirectoryContext,
    isDirty: inout Bool,
    originalHalt: DescriptorNPMPurgeUnlinkHalt,
    state: inout DescriptorNPMPurgeUnlinkState
  ) -> DescriptorNPMPurgeUnlinkHalt {
    guard isDirty else { return originalHalt }
    if let syncReason = synchronizeDirectory(directory, state: &state) {
      return DescriptorNPMPurgeUnlinkHalt(syncReason, disposition: .unresolved)
    }
    isDirty = false
    return originalHalt
  }

  private func synchronizeDirectory(
    _ directory: DescriptorNPMPurgeDirectoryContext,
    state: inout DescriptorNPMPurgeUnlinkState
  ) -> DescriptorNPMPurgeUnlinkStopReason? {
    let before: DescriptorStatSnapshot?
    let validationFailureBeforeSync: DescriptorNPMPurgeUnlinkStopReason?
    do {
      before = try validateDirectory(directory, policy: state.policy)
      validationFailureBeforeSync = nil
    } catch let halt as DescriptorNPMPurgeUnlinkHalt {
      before = nil
      validationFailureBeforeSync = halt.reason
    } catch {
      before = nil
      validationFailureBeforeSync = .observationUnavailable(.unspecified)
    }

    do {
      try state.recordSynchronizationOperation()
    } catch let halt as DescriptorNPMPurgeUnlinkHalt {
      return halt.reason
    } catch {
      return .synchronizationLimitExceeded
    }
    dependencies.hooks.willFullSync(directory.descriptor)

    var attempt = 0
    while true {
      let failureCode = dependencies.fullSync(directory.descriptor)
      guard let failureCode else { break }
      if failureCode == EINTR,
        attempt + 1 < state.policy.maximumInterruptedSystemCallAttempts
      {
        attempt += 1
        continue
      }
      return .synchronizationFailed(descriptorJournalFailure(for: failureCode))
    }

    guard let before else {
      return validationFailureBeforeSync ?? .observationUnavailable(.unspecified)
    }
    do {
      let after = try validateDirectory(directory, policy: state.policy)
      guard descriptorNPMPurgeSameCurrentSnapshot(before, after) else {
        return .treeChanged
      }
      return nil
    } catch let halt as DescriptorNPMPurgeUnlinkHalt {
      return halt.reason
    } catch {
      return .observationUnavailable(.unspecified)
    }
  }

  /// Cancellation is deliberately ignored here. Once an unlink may have
  /// happened, the engine must finish a bounded read-only validation before it
  /// can call the remainder synchronized and eligible for an explicit retry.
  private func validateCompleteRemainderForPartialReport(
    _ workRoot: DescriptorNPMPurgeDirectoryContext,
    policy: DescriptorNPMPurgeUnlinkPolicy
  ) throws {
    let rootBefore = try validateDirectory(workRoot, policy: policy)
    var inspection = DescriptorNPMPurgeRemainderInspectionState(
      policy: policy,
      seenDirectoryIdentities: [rootBefore.identity]
    )
    try validateRemainderDirectory(
      workRoot,
      format: .cacheRoot,
      childDepth: 1,
      inspection: &inspection
    )
    let rootAfter = try validateDirectory(workRoot, policy: policy)
    guard descriptorNPMPurgeSameCurrentSnapshot(rootBefore, rootAfter) else {
      throw DescriptorNPMPurgeUnlinkHalt(.treeChanged, disposition: .unresolved)
    }
  }

  private func validateRemainderDirectory(
    _ directory: DescriptorNPMPurgeDirectoryContext,
    format: NPMCacheDirectoryFormat,
    childDepth: Int,
    inspection: inout DescriptorNPMPurgeRemainderInspectionState
  ) throws {
    let directoryBefore = try validateDirectory(directory, policy: inspection.policy)
    let names = try snapshotRemainderNames(
      directory,
      childDepth: childDepth,
      inspection: &inspection
    )

    for rawName in names {
      guard let component = DescriptorPathComponent(rawName),
        let expectation = format.expectation(for: rawName)
      else {
        throw DescriptorNPMPurgeUnlinkHalt(.treeUnsafe, disposition: .unresolved)
      }
      let namedBefore = try readRequiredNamed(
        at: directory.descriptor,
        component: component,
        policy: inspection.policy
      )
      try validateEntrySnapshot(
        namedBefore,
        expectedKind: expectation.expectedKind,
        policy: inspection.policy
      )

      let childDescriptor = try openEntry(
        at: directory.descriptor,
        component: component,
        kind: expectation.expectedKind,
        policy: inspection.policy
      )
      defer { descriptorCloseIgnoringErrors(childDescriptor) }
      let opened = try readDescriptor(childDescriptor, policy: inspection.policy)
      let namedAfter = try readRequiredNamed(
        at: directory.descriptor,
        component: component,
        policy: inspection.policy
      )
      guard descriptorNPMPurgeSameCurrentSnapshot(opened, namedBefore),
        descriptorNPMPurgeSameCurrentSnapshot(namedAfter, namedBefore)
      else {
        throw DescriptorNPMPurgeUnlinkHalt(.treeChanged, disposition: .unresolved)
      }
      try validateEntrySnapshot(
        opened,
        expectedKind: expectation.expectedKind,
        policy: inspection.policy
      )
      do {
        guard try !descriptorHasExtendedACL(childDescriptor) else {
          throw DescriptorNPMPurgeUnlinkHalt(.treeUnsafe, disposition: .unresolved)
        }
      } catch let halt as DescriptorNPMPurgeUnlinkHalt {
        throw halt
      } catch {
        throw DescriptorNPMPurgeUnlinkHalt(
          .observationUnavailable(descriptorJournalFailure(for: error)),
          disposition: .unresolved
        )
      }

      if expectation.expectedKind == .directory {
        guard let childFormat = expectation.childDirectoryFormat,
          let stable = DescriptorNPMPurgeStableDirectoryBinding(opened),
          inspection.seenDirectoryIdentities.insert(opened.identity).inserted
        else {
          throw DescriptorNPMPurgeUnlinkHalt(.treeUnsafe, disposition: .unresolved)
        }
        let (nextDepth, overflow) = childDepth.addingReportingOverflow(1)
        guard !overflow else {
          throw DescriptorNPMPurgeUnlinkHalt(
            .traversalLimitExceeded,
            disposition: .unresolved
          )
        }
        try validateRemainderDirectory(
          DescriptorNPMPurgeDirectoryContext(
            descriptor: childDescriptor,
            namedAt: directory.descriptor,
            component: component,
            stableBinding: stable,
            accountUID: inspection.policy.accountUID,
            rootDevice: inspection.policy.rootDevice
          ),
          format: childFormat,
          childDepth: nextDepth,
          inspection: &inspection
        )
      }
    }

    let directoryAfter = try validateDirectory(directory, policy: inspection.policy)
    guard descriptorNPMPurgeSameCurrentSnapshot(directoryBefore, directoryAfter) else {
      throw DescriptorNPMPurgeUnlinkHalt(.treeChanged, disposition: .unresolved)
    }
  }

  private func snapshotRemainderNames(
    _ directory: DescriptorNPMPurgeDirectoryContext,
    childDepth: Int,
    inspection: inout DescriptorNPMPurgeRemainderInspectionState
  ) throws -> [[UInt8]] {
    let enumerationDescriptor = try openCurrentDirectory(
      directory.descriptor,
      policy: inspection.policy
    )
    guard let stream = Darwin.fdopendir(enumerationDescriptor) else {
      let code = errno
      descriptorCloseIgnoringErrors(enumerationDescriptor)
      throw DescriptorNPMPurgeUnlinkHalt(
        .observationUnavailable(descriptorJournalFailure(for: code)),
        disposition: .unresolved
      )
    }
    defer { _ = Darwin.closedir(stream) }

    var names: [[UInt8]] = []
    var directoryEntryCount = 0
    var interruptedAttempts = 0
    while true {
      errno = 0
      guard let entry = Darwin.readdir(stream) else {
        let code = errno
        if code == EINTR,
          interruptedAttempts + 1 < inspection.policy.maximumInterruptedSystemCallAttempts
        {
          interruptedAttempts += 1
          continue
        }
        guard code == 0 else {
          throw DescriptorNPMPurgeUnlinkHalt(
            .observationUnavailable(descriptorJournalFailure(for: code)),
            disposition: .unresolved
          )
        }
        break
      }
      interruptedAttempts = 0
      let rawName = descriptorRawName(from: entry)
      if rawName == [0x2E] || rawName == [0x2E, 0x2E] { continue }
      let (nextDirectoryEntryCount, overflow) = directoryEntryCount.addingReportingOverflow(1)
      guard !overflow,
        nextDirectoryEntryCount <= inspection.policy.maximumEntriesPerDirectory
      else {
        throw DescriptorNPMPurgeUnlinkHalt(
          .traversalLimitExceeded,
          disposition: .unresolved
        )
      }
      directoryEntryCount = nextDirectoryEntryCount
      try inspection.record(rawName: rawName, depth: childDepth)
      names.append(rawName)
    }

    names.sort { $0.lexicographicallyPrecedes($1) }
    for index in names.indices.dropFirst() where names[index - 1] == names[index] {
      throw DescriptorNPMPurgeUnlinkHalt(.treeChanged, disposition: .unresolved)
    }
    return names
  }

  private func finish(
    _ halt: DescriptorNPMPurgeUnlinkHalt,
    request: DescriptorNPMPurgeUnlinkRequest,
    quarantineRoot: DescriptorNPMPurgeDirectoryContext,
    workRoot: DescriptorNPMPurgeDirectoryContext,
    workNameParentIsSynchronized: Bool = false,
    state: inout DescriptorNPMPurgeUnlinkState
  ) -> DescriptorNPMPurgeUnlinkReport {
    if dependencies.cancellationIsRequested() || Task.isCancelled {
      state.cancellationWasRequested = true
    }

    switch observeNamed(
      at: request.quarantineRootDescriptor,
      component: request.purgeWorkComponent,
      policy: state.policy
    ) {
    case .missing:
      if !workNameParentIsSynchronized {
        if let syncReason = synchronizeDirectory(quarantineRoot, state: &state) {
          return report(
            status: .durabilityUnresolved(reason: syncReason),
            state: state
          )
        }
      }
      guard
        case .missing = observeNamed(
          at: request.quarantineRootDescriptor,
          component: request.purgeWorkComponent,
          policy: state.policy
        )
      else {
        return report(
          status: .durabilityUnresolved(reason: .treeChanged),
          state: state
        )
      }
      return report(status: .itemAbsent, state: state)
    case .present:
      do {
        _ = try validateDirectory(workRoot, policy: state.policy)
      } catch let validationHalt as DescriptorNPMPurgeUnlinkHalt {
        return report(
          status: .durabilityUnresolved(reason: validationHalt.reason),
          state: state
        )
      } catch {
        return report(
          status: .durabilityUnresolved(reason: .observationUnavailable(.unspecified)),
          state: state
        )
      }
      if halt.disposition == .retryable {
        do {
          try validateCompleteRemainderForPartialReport(
            workRoot,
            policy: state.policy
          )
        } catch let validationHalt as DescriptorNPMPurgeUnlinkHalt {
          return report(
            status: .durabilityUnresolved(reason: validationHalt.reason),
            state: state
          )
        } catch {
          return report(
            status: .durabilityUnresolved(reason: .observationUnavailable(.unspecified)),
            state: state
          )
        }
      }
      switch halt.disposition {
      case .retryable:
        return report(
          status: .synchronizedPartial(reason: halt.reason),
          state: state
        )
      case .unresolved:
        return report(
          status: .durabilityUnresolved(reason: halt.reason),
          state: state
        )
      }
    case .unavailable(let failure):
      return report(
        status: .durabilityUnresolved(reason: .observationUnavailable(failure)),
        state: state
      )
    }
  }

  private func report(
    status: DescriptorNPMPurgeUnlinkStatus,
    state: DescriptorNPMPurgeUnlinkState
  ) -> DescriptorNPMPurgeUnlinkReport {
    DescriptorNPMPurgeUnlinkReport(
      status: status,
      observedAbsentNameCount: state.observedAbsentNameCount,
      cancellationWasRequested: state.cancellationWasRequested,
      synchronizationOperationCount: state.synchronizationOperationCount
    )
  }

  private func makeQuarantineRootContext(
    _ request: DescriptorNPMPurgeUnlinkRequest,
    policy: DescriptorNPMPurgeUnlinkPolicy
  ) throws -> DescriptorNPMPurgeDirectoryContext {
    let snapshot = try readDescriptor(request.quarantineRootDescriptor, policy: policy)
    guard snapshot.kind == .directory,
      snapshot.identity.device == request.rootDevice,
      snapshot.ownerUID == request.accountUID,
      snapshot.linkCount >= 2,
      snapshot.permissionMode == mode_t(0o700),
      snapshot.flags == 0
    else {
      throw DescriptorNPMPurgeUnlinkHalt(.treeUnsafe, disposition: .unresolved)
    }
    do {
      guard try !descriptorHasExtendedACL(request.quarantineRootDescriptor) else {
        throw DescriptorNPMPurgeUnlinkHalt(.treeUnsafe, disposition: .unresolved)
      }
    } catch let halt as DescriptorNPMPurgeUnlinkHalt {
      throw halt
    } catch {
      throw DescriptorNPMPurgeUnlinkHalt(
        .observationUnavailable(descriptorJournalFailure(for: error)),
        disposition: .unresolved
      )
    }
    guard let stableBinding = DescriptorNPMPurgeStableDirectoryBinding(snapshot) else {
      throw DescriptorNPMPurgeUnlinkHalt(.treeUnsafe, disposition: .unresolved)
    }
    return DescriptorNPMPurgeDirectoryContext(
      descriptor: request.quarantineRootDescriptor,
      namedAt: nil,
      component: nil,
      stableBinding: stableBinding,
      accountUID: request.accountUID,
      rootDevice: request.rootDevice
    )
  }

  private func makeWorkRootContext(
    _ request: DescriptorNPMPurgeUnlinkRequest,
    quarantineRoot: DescriptorNPMPurgeDirectoryContext,
    policy: DescriptorNPMPurgeUnlinkPolicy
  ) throws -> DescriptorNPMPurgeDirectoryContext {
    let opened = try readDescriptor(request.purgeWorkDescriptor, policy: policy)
    let named = try readRequiredNamed(
      at: quarantineRoot.descriptor,
      component: request.purgeWorkComponent,
      policy: policy
    )
    guard
      descriptorNPMPurgeHistoricalIdentity(
        opened,
        matches: request.historicalCandidateBinding
      ),
      descriptorNPMPurgeHistoricalIdentity(
        named,
        matches: request.historicalCandidateBinding
      ),
      descriptorNPMPurgeSameCurrentSnapshot(opened, named),
      opened.kind == .directory,
      opened.identity.device == request.rootDevice,
      opened.ownerUID == request.accountUID,
      opened.linkCount >= 2,
      descriptorNPMPurgeHasSafeMutationMetadata(opened)
    else {
      throw DescriptorNPMPurgeUnlinkHalt(.treeUnsafe, disposition: .unresolved)
    }
    if request.attemptKind == .initial {
      guard
        UInt32(exactly: opened.permissionMode)
          == request.historicalCandidateBinding.permissionMode,
        opened.flags == request.historicalCandidateBinding.flags
      else {
        throw DescriptorNPMPurgeUnlinkHalt(.treeChanged, disposition: .unresolved)
      }
    }
    do {
      guard try !descriptorHasExtendedACL(request.purgeWorkDescriptor) else {
        throw DescriptorNPMPurgeUnlinkHalt(.treeUnsafe, disposition: .unresolved)
      }
    } catch let halt as DescriptorNPMPurgeUnlinkHalt {
      throw halt
    } catch {
      throw DescriptorNPMPurgeUnlinkHalt(
        .observationUnavailable(descriptorJournalFailure(for: error)),
        disposition: .unresolved
      )
    }
    guard let currentStableBinding = DescriptorNPMPurgeStableDirectoryBinding(opened) else {
      throw DescriptorNPMPurgeUnlinkHalt(.treeUnsafe, disposition: .unresolved)
    }
    let context = DescriptorNPMPurgeDirectoryContext(
      descriptor: request.purgeWorkDescriptor,
      namedAt: quarantineRoot.descriptor,
      component: request.purgeWorkComponent,
      stableBinding: currentStableBinding,
      accountUID: request.accountUID,
      rootDevice: request.rootDevice
    )
    _ = try validateDirectory(context, policy: policy)
    return context
  }

  private func validateDirectory(
    _ directory: DescriptorNPMPurgeDirectoryContext,
    policy: DescriptorNPMPurgeUnlinkPolicy
  ) throws -> DescriptorStatSnapshot {
    let opened = try readDescriptor(directory.descriptor, policy: policy)
    guard directory.stableBinding.matches(opened),
      opened.kind == .directory,
      opened.identity.device == directory.rootDevice,
      opened.ownerUID == directory.accountUID,
      opened.linkCount >= 2,
      descriptorNPMPurgeHasSafeMutationMetadata(opened)
    else {
      throw DescriptorNPMPurgeUnlinkHalt(.treeUnsafe, disposition: .unresolved)
    }
    do {
      guard try !descriptorHasExtendedACL(directory.descriptor) else {
        throw DescriptorNPMPurgeUnlinkHalt(.treeUnsafe, disposition: .unresolved)
      }
    } catch let halt as DescriptorNPMPurgeUnlinkHalt {
      throw halt
    } catch {
      throw DescriptorNPMPurgeUnlinkHalt(
        .observationUnavailable(descriptorJournalFailure(for: error)),
        disposition: .unresolved
      )
    }

    if let parentDescriptor = directory.namedAt,
      let component = directory.component
    {
      let named = try readRequiredNamed(
        at: parentDescriptor,
        component: component,
        policy: policy
      )
      guard directory.stableBinding.matches(named),
        descriptorNPMPurgeSameCurrentSnapshot(opened, named)
      else {
        throw DescriptorNPMPurgeUnlinkHalt(.treeChanged, disposition: .unresolved)
      }
    }
    return opened
  }

  private func validateEntrySnapshot(
    _ snapshot: DescriptorStatSnapshot,
    expectedKind: FileSystemEntryKind,
    policy: DescriptorNPMPurgeUnlinkPolicy
  ) throws {
    guard snapshot.kind == expectedKind,
      snapshot.identity.device == policy.rootDevice,
      snapshot.ownerUID == policy.accountUID,
      descriptorNPMPurgeHasSafeMutationMetadata(snapshot)
    else {
      throw DescriptorNPMPurgeUnlinkHalt(.treeUnsafe, disposition: .unresolved)
    }
    switch expectedKind {
    case .regularFile:
      guard snapshot.linkCount == 1 else {
        throw DescriptorNPMPurgeUnlinkHalt(.treeUnsafe, disposition: .unresolved)
      }
    case .directory:
      guard snapshot.linkCount >= 2 else {
        throw DescriptorNPMPurgeUnlinkHalt(.treeUnsafe, disposition: .unresolved)
      }
    case .symbolicLink, .other:
      throw DescriptorNPMPurgeUnlinkHalt(.treeUnsafe, disposition: .unresolved)
    }
  }

  private func cancellationCheckpoint(
    state: inout DescriptorNPMPurgeUnlinkState
  ) throws {
    guard !dependencies.cancellationIsRequested(), !Task.isCancelled else {
      state.cancellationWasRequested = true
      throw DescriptorNPMPurgeUnlinkHalt(.cancelled, disposition: .retryable)
    }
  }

  private func cancellationCheckpointForValidator() throws {
    guard !dependencies.cancellationIsRequested(), !Task.isCancelled else {
      throw CancellationError()
    }
  }
}

private struct DescriptorNPMPurgeUnlinkPolicy: Sendable {
  let accountUID: uid_t
  let rootDevice: UInt64
  let traversalLimits: DescriptorNPMPurgeTraversalLimits
  let maximumEntries: UInt64
  let maximumDepth: Int
  let maximumEntriesPerDirectory: Int
  let maximumRawNameBytes: UInt64
  let maximumInterruptedSystemCallAttempts: Int
  let maximumSynchronizationOperations: UInt64
  let maximumObservedAbsentNames: UInt64

  init?(
    _ bounds: QuarantinePurgeJournalResourceBoundsV1,
    accountUID: uid_t,
    rootDevice: UInt64
  ) {
    guard let maximumDepth = Int(exactly: bounds.maximumDepth),
      let maximumEntriesPerDirectory = Int(exactly: bounds.maximumEntriesPerDirectory),
      let maximumInterruptedSystemCallAttempts = Int(
        exactly: bounds.maximumInterruptedSystemCallAttempts
      ),
      maximumInterruptedSystemCallAttempts > 0,
      let traversalMaximumEntries = Int(exactly: bounds.maximumEntries),
      let traversalMaximumRawNameBytes = Int(exactly: bounds.maximumRawNameBytes)
    else {
      return nil
    }
    let (maximumObservedAbsentNames, overflow) = bounds.maximumEntries.addingReportingOverflow(1)
    guard !overflow else { return nil }

    self.accountUID = accountUID
    self.rootDevice = rootDevice
    maximumEntries = bounds.maximumEntries
    self.maximumDepth = maximumDepth
    self.maximumEntriesPerDirectory = maximumEntriesPerDirectory
    maximumRawNameBytes = bounds.maximumRawNameBytes
    self.maximumInterruptedSystemCallAttempts = maximumInterruptedSystemCallAttempts
    maximumSynchronizationOperations = bounds.maximumSynchronizationOperations
    self.maximumObservedAbsentNames = maximumObservedAbsentNames
    traversalLimits = DescriptorNPMPurgeTraversalLimits(
      maximumEntries: traversalMaximumEntries,
      maximumDepth: maximumDepth,
      maximumEntriesPerDirectory: maximumEntriesPerDirectory,
      maximumRawNameBytes: traversalMaximumRawNameBytes,
      maximumInterruptedSystemCallAttempts: maximumInterruptedSystemCallAttempts
    )
  }
}

private struct DescriptorNPMPurgeUnlinkState {
  static let requiredCompleteRootNames: Set<[UInt8]> = [
    Array("content-v2".utf8),
    Array("index-v5".utf8),
  ]

  var policy: DescriptorNPMPurgeUnlinkPolicy
  var seenDirectoryIdentities: Set<FileIdentity>
  var entryCount: UInt64 = 0
  var rawNameByteCount: UInt64 = 0
  var observedAbsentNameCount: UInt64 = 0
  var synchronizationOperationCount: UInt64 = 0
  var cancellationWasRequested = false

  init(policy: DescriptorNPMPurgeUnlinkPolicy) {
    self.policy = policy
    seenDirectoryIdentities = []
  }

  mutating func record(rawName: [UInt8], depth: Int) throws {
    let (newEntryCount, entryOverflow) = entryCount.addingReportingOverflow(1)
    let rawByteCount = UInt64(rawName.count)
    let (newRawNameByteCount, byteOverflow) = rawNameByteCount.addingReportingOverflow(
      rawByteCount
    )
    guard !entryOverflow,
      !byteOverflow,
      newEntryCount <= policy.maximumEntries,
      depth <= policy.maximumDepth,
      newRawNameByteCount <= policy.maximumRawNameBytes
    else {
      throw DescriptorNPMPurgeUnlinkHalt(
        .traversalLimitExceeded,
        disposition: .unresolved
      )
    }
    entryCount = newEntryCount
    rawNameByteCount = newRawNameByteCount
  }

  mutating func recordObservedAbsentName() throws {
    let (newValue, overflow) = observedAbsentNameCount.addingReportingOverflow(1)
    guard !overflow, newValue <= policy.maximumObservedAbsentNames else {
      throw DescriptorNPMPurgeUnlinkHalt(
        .traversalLimitExceeded,
        disposition: .unresolved
      )
    }
    observedAbsentNameCount = newValue
  }

  mutating func recordSynchronizationOperation() throws {
    let (newValue, overflow) = synchronizationOperationCount.addingReportingOverflow(1)
    guard !overflow, newValue <= policy.maximumSynchronizationOperations else {
      throw DescriptorNPMPurgeUnlinkHalt(
        .synchronizationLimitExceeded,
        disposition: .unresolved
      )
    }
    synchronizationOperationCount = newValue
  }
}

private struct DescriptorNPMPurgeRemainderInspectionState {
  let policy: DescriptorNPMPurgeUnlinkPolicy
  var seenDirectoryIdentities: Set<FileIdentity>
  private var entryCount: UInt64 = 0
  private var rawNameByteCount: UInt64 = 0

  init(
    policy: DescriptorNPMPurgeUnlinkPolicy,
    seenDirectoryIdentities: Set<FileIdentity>
  ) {
    self.policy = policy
    self.seenDirectoryIdentities = seenDirectoryIdentities
  }

  mutating func record(rawName: [UInt8], depth: Int) throws {
    let (newEntryCount, entryOverflow) = entryCount.addingReportingOverflow(1)
    let (newRawNameByteCount, byteOverflow) = rawNameByteCount.addingReportingOverflow(
      UInt64(rawName.count)
    )
    guard !entryOverflow,
      !byteOverflow,
      newEntryCount <= policy.maximumEntries,
      depth <= policy.maximumDepth,
      newRawNameByteCount <= policy.maximumRawNameBytes
    else {
      throw DescriptorNPMPurgeUnlinkHalt(
        .traversalLimitExceeded,
        disposition: .unresolved
      )
    }
    entryCount = newEntryCount
    rawNameByteCount = newRawNameByteCount
  }
}

private struct DescriptorNPMPurgeStableDirectoryBinding: Sendable {
  let device: UInt64
  let inode: UInt64
  let generation: UInt32
  let birthSeconds: Int64
  let birthNanoseconds: UInt32
  let ownerUID: UInt32
  let permissionMode: UInt32
  let flags: UInt32

  init?(_ snapshot: DescriptorStatSnapshot) {
    guard let birthSeconds = Int64(exactly: snapshot.birthSeconds),
      let birthNanoseconds = UInt32(exactly: snapshot.birthNanoseconds),
      birthNanoseconds < 1_000_000_000,
      let ownerUID = UInt32(exactly: snapshot.ownerUID),
      let permissionMode = UInt32(exactly: snapshot.permissionMode)
    else {
      return nil
    }
    device = snapshot.identity.device
    inode = snapshot.identity.inode
    generation = snapshot.generation
    self.birthSeconds = birthSeconds
    self.birthNanoseconds = birthNanoseconds
    self.ownerUID = ownerUID
    self.permissionMode = permissionMode
    flags = snapshot.flags
  }

  func matches(_ snapshot: DescriptorStatSnapshot) -> Bool {
    snapshot.identity.device == device
      && snapshot.identity.inode == inode
      && snapshot.generation == generation
      && Int64(exactly: snapshot.birthSeconds) == birthSeconds
      && UInt32(exactly: snapshot.birthNanoseconds) == birthNanoseconds
      && snapshot.kind == .directory
      && UInt32(exactly: snapshot.ownerUID) == ownerUID
      && UInt32(exactly: snapshot.permissionMode) == permissionMode
      && snapshot.flags == flags
  }
}

private struct DescriptorNPMPurgeDirectoryContext: Sendable {
  let descriptor: Int32
  let namedAt: Int32?
  let component: DescriptorPathComponent?
  let stableBinding: DescriptorNPMPurgeStableDirectoryBinding
  let accountUID: uid_t
  let rootDevice: UInt64
}

private enum DescriptorNPMPurgeNamedObservation {
  case missing
  case present(DescriptorStatSnapshot)
  case unavailable(CleanupQuarantineSystemFailure)
}

private enum DescriptorNPMPurgeHaltDisposition: Equatable {
  case retryable
  case unresolved
}

private struct DescriptorNPMPurgeUnlinkHalt: Error {
  let reason: DescriptorNPMPurgeUnlinkStopReason
  let disposition: DescriptorNPMPurgeHaltDisposition

  init(
    _ reason: DescriptorNPMPurgeUnlinkStopReason,
    disposition: DescriptorNPMPurgeHaltDisposition
  ) {
    self.reason = reason
    self.disposition = disposition
  }
}

private func descriptorNPMPurgeIsWorkComponent(
  _ component: DescriptorPathComponent
) -> Bool {
  let prefix = Array(".purge-work-v1-".utf8)
  return component.bytes.count == prefix.count + 32
    && component.bytes.starts(with: prefix)
    && component.bytes.dropFirst(prefix.count).allSatisfy { byte in
      (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
    }
}

private func descriptorNPMPurgeHasSafeMutationMetadata(
  _ snapshot: DescriptorStatSnapshot
) -> Bool {
  snapshot.permissionMode & mode_t(0o022) == 0 && snapshot.flags == 0
}

private func descriptorNPMPurgeHistoricalIdentity(
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

private func descriptorNPMPurgeSameCurrentSnapshot(
  _ left: DescriptorStatSnapshot,
  _ right: DescriptorStatSnapshot
) -> Bool {
  left.sameProtectedDescendantState(as: right)
    && left.permissionMode == right.permissionMode
    && left.flags == right.flags
}

private func readDescriptor(
  _ descriptor: Int32,
  policy: DescriptorNPMPurgeUnlinkPolicy
) throws -> DescriptorStatSnapshot {
  var information = stat()
  for attempt in 0..<policy.maximumInterruptedSystemCallAttempts {
    guard Darwin.fstat(descriptor, &information) == 0 else {
      let code = errno
      if code == EINTR, attempt + 1 < policy.maximumInterruptedSystemCallAttempts {
        continue
      }
      throw DescriptorNPMPurgeUnlinkHalt(
        .observationUnavailable(descriptorJournalFailure(for: code)),
        disposition: .unresolved
      )
    }
    return DescriptorStatSnapshot(information: information)
  }
  throw DescriptorNPMPurgeUnlinkHalt(
    .observationUnavailable(.inputOutput),
    disposition: .unresolved
  )
}

private func readRequiredNamed(
  at parentDescriptor: Int32,
  component: DescriptorPathComponent,
  policy: DescriptorNPMPurgeUnlinkPolicy
) throws -> DescriptorStatSnapshot {
  switch observeNamed(at: parentDescriptor, component: component, policy: policy) {
  case .present(let snapshot):
    return snapshot
  case .missing:
    throw DescriptorNPMPurgeUnlinkHalt(.treeChanged, disposition: .unresolved)
  case .unavailable(let failure):
    throw DescriptorNPMPurgeUnlinkHalt(
      .observationUnavailable(failure),
      disposition: .unresolved
    )
  }
}

private func observeNamed(
  at parentDescriptor: Int32,
  component: DescriptorPathComponent,
  policy: DescriptorNPMPurgeUnlinkPolicy
) -> DescriptorNPMPurgeNamedObservation {
  var information = stat()
  for attempt in 0..<policy.maximumInterruptedSystemCallAttempts {
    let result = component.withCString { pointer in
      Darwin.fstatat(parentDescriptor, pointer, &information, AT_SYMLINK_NOFOLLOW)
    }
    if result == 0 {
      return .present(DescriptorStatSnapshot(information: information))
    }
    let code = errno
    if code == ENOENT {
      return .missing
    }
    if code == EINTR, attempt + 1 < policy.maximumInterruptedSystemCallAttempts {
      continue
    }
    return .unavailable(descriptorJournalFailure(for: code))
  }
  return .unavailable(.inputOutput)
}

private func openEntry(
  at parentDescriptor: Int32,
  component: DescriptorPathComponent,
  kind: FileSystemEntryKind,
  policy: DescriptorNPMPurgeUnlinkPolicy
) throws -> Int32 {
  let typeFlags: Int32
  switch kind {
  case .directory:
    typeFlags = O_DIRECTORY
  case .regularFile:
    typeFlags = O_NONBLOCK
  case .symbolicLink, .other:
    throw DescriptorNPMPurgeUnlinkHalt(.treeUnsafe, disposition: .unresolved)
  }

  for attempt in 0..<policy.maximumInterruptedSystemCallAttempts {
    let descriptor = component.withCString { pointer in
      Darwin.openat(
        parentDescriptor,
        pointer,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_RESOLVE_BENEATH | typeFlags
      )
    }
    if descriptor >= 0 { return descriptor }
    let code = errno
    if code == EINTR, attempt + 1 < policy.maximumInterruptedSystemCallAttempts {
      continue
    }
    let failure = descriptorJournalFailure(for: code)
    if failure == .pathChanged {
      throw DescriptorNPMPurgeUnlinkHalt(.treeChanged, disposition: .unresolved)
    }
    throw DescriptorNPMPurgeUnlinkHalt(
      .observationUnavailable(failure),
      disposition: .unresolved
    )
  }
  throw DescriptorNPMPurgeUnlinkHalt(
    .observationUnavailable(.inputOutput),
    disposition: .unresolved
  )
}

private func openCurrentDirectory(
  _ descriptor: Int32,
  policy: DescriptorNPMPurgeUnlinkPolicy
) throws -> Int32 {
  for attempt in 0..<policy.maximumInterruptedSystemCallAttempts {
    let opened = Darwin.openat(
      descriptor,
      ".",
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    if opened >= 0 { return opened }
    let code = errno
    if code == EINTR, attempt + 1 < policy.maximumInterruptedSystemCallAttempts {
      continue
    }
    throw DescriptorNPMPurgeUnlinkHalt(
      .observationUnavailable(descriptorJournalFailure(for: code)),
      disposition: .unresolved
    )
  }
  throw DescriptorNPMPurgeUnlinkHalt(
    .observationUnavailable(.inputOutput),
    disposition: .unresolved
  )
}

private func descriptorNPMPurgeUnlinkAt(
  _ parentDescriptor: Int32,
  _ component: DescriptorPathComponent,
  _ flags: Int32
) -> Int32? {
  let result = component.withCString { pointer in
    Darwin.unlinkat(parentDescriptor, pointer, flags)
  }
  return result == 0 ? nil : errno
}

private func descriptorNPMPurgeFullSync(_ descriptor: Int32) -> Int32? {
  Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 ? nil : errno
}
