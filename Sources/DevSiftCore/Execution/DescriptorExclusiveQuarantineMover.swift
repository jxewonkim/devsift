import Darwin
import Foundation

/// The exact result of one `renameatx_np` invocation. The production adapter
/// captures `errno` before any other operation can overwrite it.
enum DescriptorExclusiveRenameResult: Equatable, Sendable {
  case succeeded
  case failed(Int32)
}

/// A bounded relative path for one descriptor-rooted rename operand. Unlike a
/// single syscall component, this can represent the fixed quarantine root and
/// one validated leaf while still rejecting absolute and parent traversal.
struct DescriptorQuarantineRelativePath: Equatable, Sendable {
  let bytes: [UInt8]

  init?(_ components: [DescriptorPathComponent]) {
    guard !components.isEmpty else { return nil }
    var joined: [UInt8] = []
    for (index, component) in components.enumerated() {
      if index > 0 { joined.append(0x2F) }
      joined.append(contentsOf: component.bytes)
      guard joined.count < Int(PATH_MAX) else { return nil }
    }
    bytes = joined
  }

  func withCString<Result>(
    _ body: (UnsafePointer<CChar>) throws -> Result
  ) rethrows -> Result {
    var terminatedBytes = bytes.map { CChar(bitPattern: $0) }
    terminatedBytes.append(0)
    return try terminatedBytes.withUnsafeBufferPointer { buffer in
      try body(buffer.baseAddress!)
    }
  }
}

/// Bounded dependency result used by the mover's test seams.
enum DescriptorQuarantineDependencyResult<Value: Sendable>: Sendable {
  case success(Value)
  case failure(CleanupQuarantineSystemFailure)
}

struct DescriptorQuarantineVolumeCapabilities: Equatable, Sendable {
  let supportsExclusiveRename: Bool
  let supportsPOSIXPermissions: Bool
}

struct DescriptorExclusiveQuarantineMoverHooks: Sendable {
  var afterQuarantineRootValidation: @Sendable () -> Void
  var afterFinalSourceValidationBeforeRename: @Sendable (Int) -> Void
  var afterRenameReturn: @Sendable (Int, DescriptorExclusiveRenameResult) -> Void
  var beforeRollback: @Sendable () -> Void

  init(
    afterQuarantineRootValidation: @escaping @Sendable () -> Void = {},
    afterFinalSourceValidationBeforeRename: @escaping @Sendable (Int) -> Void = { _ in },
    afterRenameReturn: @escaping @Sendable (Int, DescriptorExclusiveRenameResult) -> Void = {
      _, _ in
    },
    beforeRollback: @escaping @Sendable () -> Void = {}
  ) {
    self.afterQuarantineRootValidation = afterQuarantineRootValidation
    self.afterFinalSourceValidationBeforeRename = afterFinalSourceValidationBeforeRename
    self.afterRenameReturn = afterRenameReturn
    self.beforeRollback = beforeRollback
  }
}

/// Injectable seams are intentionally internal. Production still performs
/// every namespace operation with descriptor-relative Darwin syscalls.
struct DescriptorExclusiveQuarantineMoverDependencies: Sendable {
  var currentAccountUID: @Sendable () -> uid_t?
  var supportsResolveBeneathRename: @Sendable () -> Bool
  var makeQuarantineRoot:
    @Sendable (
      Int32,
      DescriptorPathComponent
    ) -> DescriptorQuarantineMkdirResult
  var nonceBytes: @Sendable (Int) -> [UInt8]?
  var volumeCapabilities:
    @Sendable (
      Int32
    ) -> DescriptorQuarantineDependencyResult<DescriptorQuarantineVolumeCapabilities>
  var hasExtendedACL:
    @Sendable (
      Int32
    ) -> DescriptorQuarantineDependencyResult<Bool>
  var renameExclusive:
    @Sendable (
      Int32,
      DescriptorQuarantineRelativePath,
      Int32,
      DescriptorQuarantineRelativePath,
      UInt32
    ) -> DescriptorExclusiveRenameResult
  var cancellationIsRequested: @Sendable () -> Bool
  var hooks: DescriptorExclusiveQuarantineMoverHooks

  init(
    currentAccountUID: @escaping @Sendable () -> uid_t? =
      descriptorQuarantineCurrentAccountUID,
    supportsResolveBeneathRename: @escaping @Sendable () -> Bool =
      descriptorQuarantineSupportsResolveBeneathRename,
    makeQuarantineRoot:
      @escaping @Sendable (
        Int32,
        DescriptorPathComponent
      ) -> DescriptorQuarantineMkdirResult = descriptorQuarantineMakeRoot,
    nonceBytes: @escaping @Sendable (Int) -> [UInt8]? =
      descriptorQuarantineRandomNonce,
    volumeCapabilities:
      @escaping @Sendable (
        Int32
      ) -> DescriptorQuarantineDependencyResult<DescriptorQuarantineVolumeCapabilities> =
      descriptorQuarantineVolumeCapabilities,
    hasExtendedACL:
      @escaping @Sendable (
        Int32
      ) -> DescriptorQuarantineDependencyResult<Bool> = descriptorQuarantineHasExtendedACL,
    renameExclusive:
      @escaping @Sendable (
        Int32,
        DescriptorQuarantineRelativePath,
        Int32,
        DescriptorQuarantineRelativePath,
        UInt32
      ) -> DescriptorExclusiveRenameResult = descriptorQuarantineRenameExclusive,
    cancellationIsRequested: @escaping @Sendable () -> Bool = { Task.isCancelled },
    hooks: DescriptorExclusiveQuarantineMoverHooks = DescriptorExclusiveQuarantineMoverHooks()
  ) {
    self.currentAccountUID = currentAccountUID
    self.supportsResolveBeneathRename = supportsResolveBeneathRename
    self.makeQuarantineRoot = makeQuarantineRoot
    self.nonceBytes = nonceBytes
    self.volumeCapabilities = volumeCapabilities
    self.hasExtendedACL = hasExtendedACL
    self.renameExclusive = renameExclusive
    self.cancellationIsRequested = cancellationIsRequested
    self.hooks = hooks
  }
}

/// Attempts one exclusive source-name rename into the fixed quarantine
/// namespace, then reconciles the result against the preflight-held candidate.
/// It neither copies nor removes filesystem objects.
struct DescriptorExclusiveQuarantineMover: Sendable {
  static let quarantineRootBytes = Array(".devsift-quarantine-v1".utf8)
  static let destinationPrefixBytes = Array("item-v1-".utf8)
  static let maximumDestinationAttempts = 16
  // This flag entered the platform SDK in macOS 26. Keep its stable kernel ABI
  // value local so DevSift can still compile its read-only surfaces with older
  // SDKs; the runtime gate below never passes it to an older kernel.
  static let resolveBeneathRenameFlag = UInt32(0x0000_0020)
  static let renameFlags =
    UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
    | resolveBeneathRenameFlag

  private let dependencies: DescriptorExclusiveQuarantineMoverDependencies

  init(
    dependencies: DescriptorExclusiveQuarantineMoverDependencies =
      DescriptorExclusiveQuarantineMoverDependencies()
  ) {
    self.dependencies = dependencies
  }

  /// This API is synchronous so the preflight closure cannot let held
  /// descriptors escape across a suspension point. Once rename has been
  /// invoked, cancellation is only latched into the completed report.
  func move(
    _ scope: DescriptorNPMQuarantineCandidateScope
  ) -> CleanupQuarantineExecutionReport {
    var rootMutation = CleanupQuarantineRootMutation.none

    func report(
      _ status: CleanupQuarantineExecutionStatus,
      cancellationWasObservedAfterRename: Bool = false
    ) -> CleanupQuarantineExecutionReport {
      CleanupQuarantineExecutionReport(
        path: scope.entry.path,
        ruleRevision: scope.entry.ruleRevision,
        status: status,
        quarantineRootMutation: rootMutation,
        cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
      )
    }

    guard
      scope.entry.path.rawComponents.count == 1,
      scope.entry.path.rawComponents[0] == Array("_cacache".utf8),
      scope.entry.expectedKind == .directory,
      let sourceComponent = DescriptorPathComponent(scope.entry.path.rawComponents[0]),
      let quarantineRootComponent = DescriptorPathComponent(Self.quarantineRootBytes),
      let sourcePath = DescriptorQuarantineRelativePath([sourceComponent])
    else {
      return report(.notMoved(.unsupportedPolicy))
    }
    guard
      scope.accountUID != 0,
      dependencies.currentAccountUID() == scope.accountUID
    else {
      return report(.notMoved(.invalidCurrentAccount))
    }

    guard !dependencies.cancellationIsRequested() else {
      return report(.notMoved(.cancelled))
    }

    // Both rename operands are rooted at the approved npm descriptor and the
    // destination contains the quarantine directory as an intermediate path.
    // Older kernels cannot bind that traversal beneath the held root, so they
    // must remain mutation-free rather than fall back to weaker semantics.
    guard dependencies.supportsResolveBeneathRename() else {
      return report(.notMoved(.exclusiveRenameUnsupported))
    }

    switch validateSource(
      scope,
      expectedRootSnapshot: scope.rootSnapshot,
      cancellationPolicy: .observeTaskCancellation
    ) {
    case .valid:
      break
    case .candidateMissing:
      return report(.notMoved(.candidateMissing))
    case .candidateChanged:
      return report(.notMoved(.candidateChanged))
    case .candidateUnsafe:
      return report(.notMoved(.candidateUnsafe))
    case .parentChanged:
      return report(.notMoved(.trustedRootChanged))
    case .invalidCurrentAccount:
      return report(.notMoved(.invalidCurrentAccount))
    case .cancelled:
      return report(.notMoved(.cancelled))
    case .unavailable(let failure):
      return report(.notMoved(.trustedRootUnavailable(failure)))
    }

    guard !dependencies.cancellationIsRequested() else {
      return report(.notMoved(.cancelled))
    }

    let mkdirResult = dependencies.makeQuarantineRoot(
      scope.heldRootDescriptor,
      quarantineRootComponent
    )
    switch mkdirResult {
    case .created:
      rootMutation = .created
    case .alreadyExists:
      break
    case .failed(let code):
      if code == EINTR || code == EIO {
        rootMutation = .indeterminate
      }
      return report(
        .notMoved(.quarantineRootUnavailable(descriptorQuarantineFailure(for: code)))
      )
    }

    let quarantineRootDescriptor: Int32
    do {
      quarantineRootDescriptor = try descriptorOpenTrustedDirectory(
        at: scope.heldRootDescriptor,
        component: quarantineRootComponent
      )
    } catch is CancellationError {
      return report(.notMoved(.cancelled))
    } catch {
      return report(
        .notMoved(.quarantineRootUnavailable(descriptorQuarantineFailure(for: error)))
      )
    }
    defer { descriptorCloseIgnoringErrors(quarantineRootDescriptor) }

    switch validateQuarantineRoot(
      descriptor: quarantineRootDescriptor,
      namedAt: scope.heldRootDescriptor,
      component: quarantineRootComponent,
      expectedSnapshot: nil,
      expectedDevice: scope.rootSnapshot.identity.device,
      expectedUID: scope.accountUID,
      cancellationPolicy: .observeTaskCancellation
    ) {
    case .valid:
      break
    case .unsafe:
      return report(.notMoved(.quarantineRootUnsafe))
    case .unsupported:
      return report(.notMoved(.exclusiveRenameUnsupported))
    case .cancelled:
      return report(.notMoved(.cancelled))
    case .unavailable(let failure):
      return report(.notMoved(.quarantineRootUnavailable(failure)))
    }

    let preRenameRootSnapshot: DescriptorStatSnapshot
    let preRenameQuarantineRootSnapshot: DescriptorStatSnapshot
    do {
      preRenameRootSnapshot = try DescriptorStatSnapshot.read(
        from: scope.heldRootDescriptor
      )
      preRenameQuarantineRootSnapshot = try DescriptorStatSnapshot.read(
        from: quarantineRootDescriptor
      )
    } catch is CancellationError {
      return report(.notMoved(.cancelled))
    } catch {
      return report(
        .notMoved(.quarantineRootUnavailable(descriptorQuarantineFailure(for: error)))
      )
    }

    dependencies.hooks.afterQuarantineRootValidation()
    guard !dependencies.cancellationIsRequested() else {
      return report(.notMoved(.cancelled))
    }

    var cancellationWasObservedAfterRename = false
    for attempt in 0..<Self.maximumDestinationAttempts {
      guard
        let nonce = dependencies.nonceBytes(attempt),
        let destinationComponent = destinationComponent(nonce: nonce),
        let destinationPath = DescriptorQuarantineRelativePath([
          quarantineRootComponent,
          destinationComponent,
        ])
      else {
        return report(.notMoved(.invalidDestinationName))
      }

      switch validatePreRenameBindings(
        scope,
        expectedRootSnapshot: preRenameRootSnapshot,
        quarantineRootDescriptor: quarantineRootDescriptor,
        quarantineRootComponent: quarantineRootComponent,
        expectedQuarantineRootSnapshot: preRenameQuarantineRootSnapshot
      ) {
      case .valid:
        break
      case .candidateMissing:
        return report(.notMoved(.candidateMissing))
      case .candidateChanged:
        return report(.notMoved(.candidateChanged))
      case .candidateUnsafe:
        return report(.notMoved(.candidateUnsafe))
      case .parentChanged:
        return report(.notMoved(.trustedRootChanged))
      case .invalidCurrentAccount:
        return report(.notMoved(.invalidCurrentAccount))
      case .quarantineRootUnsafe:
        return report(.notMoved(.quarantineRootUnsafe))
      case .unsupported:
        return report(.notMoved(.exclusiveRenameUnsupported))
      case .cancelled:
        return report(.notMoved(.cancelled))
      case .unavailable(let failure):
        return report(.notMoved(.preRenameValidationUnavailable(failure)))
      }

      guard !dependencies.cancellationIsRequested() else {
        return report(.notMoved(.cancelled))
      }
      dependencies.hooks.afterFinalSourceValidationBeforeRename(attempt)
      guard !dependencies.cancellationIsRequested() else {
        return report(.notMoved(.cancelled))
      }

      let renameResult = dependencies.renameExclusive(
        scope.heldRootDescriptor,
        sourcePath,
        scope.heldRootDescriptor,
        destinationPath,
        Self.renameFlags
      )
      cancellationWasObservedAfterRename =
        cancellationWasObservedAfterRename || dependencies.cancellationIsRequested()
      dependencies.hooks.afterRenameReturn(attempt, renameResult)
      cancellationWasObservedAfterRename =
        cancellationWasObservedAfterRename || dependencies.cancellationIsRequested()

      let reconciled = reconcileAfterRename(
        scope,
        sourceComponent: sourceComponent,
        quarantineRootDescriptor: quarantineRootDescriptor,
        quarantineRootComponent: quarantineRootComponent,
        destinationComponent: destinationComponent
      )
      cancellationWasObservedAfterRename =
        cancellationWasObservedAfterRename || dependencies.cancellationIsRequested()

      if reconciled.destination == .expectedCandidate {
        guard reconciled.parentsAreValid else {
          return report(
            .manualRecoveryRequired(location: nil, reason: .parentBindingChanged),
            cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
          )
        }
        let location = quarantineLocation(
          destinationComponent: destinationComponent,
          identity: scope.candidateSnapshot.identity
        )
        guard renameResult == .succeeded else {
          return report(
            .manualRecoveryRequired(
              location: location,
              reason: .renameOutcomeIndeterminate
            ),
            cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
          )
        }
        if reconciled.source == .other,
          reconciled.candidateMatchesApprovalAfterRename,
          reconciled.parentsAreValid
        {
          return report(
            .quarantinedAwaitingReceipt(
              location: location,
              sourceNameWasRecreated: true
            ),
            cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
          )
        }
        if reconciled.source == .unavailable {
          return report(
            .manualRecoveryRequired(
              location: location,
              reason: .sourceCouldNotBeVerified
            ),
            cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
          )
        }
        if reconciled.source == .other || reconciled.source == .expectedCandidate {
          return report(
            .manualRecoveryRequired(
              location: location,
              reason: .sourceNameOccupied
            ),
            cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
          )
        }
        if reconciled.candidateMatchesApprovalAfterRename {
          return report(
            .quarantinedAwaitingReceipt(
              location: location,
              sourceNameWasRecreated: false
            ),
            cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
          )
        }

        let rollbackReason: CleanupQuarantineRollbackReason =
          reconciled.candidateValidationUnavailable
          ? .postMoveValidationUnavailable
          : .movedObjectDidNotMatchApproval
        return rollback(
          scope,
          sourceComponent: sourceComponent,
          quarantineRootDescriptor: quarantineRootDescriptor,
          quarantineRootComponent: quarantineRootComponent,
          destinationComponent: destinationComponent,
          location: location,
          reason: rollbackReason,
          rootMutation: rootMutation,
          cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
        )
      }

      let observedDestinationLocation =
        reconciled.parentsAreValid && reconciled.destination == .other
        ? quarantineLocation(
          destinationComponent: destinationComponent,
          identity: reconciled.destinationObservedIdentity
        )
        : nil

      switch renameResult {
      case .failed(EEXIST):
        if cancellationWasObservedAfterRename {
          return report(
            .notMoved(.cancelled),
            cancellationWasObservedAfterRename: true
          )
        }
        guard
          reconciled.source == .expectedCandidate,
          reconciled.candidateStillMatchesPreRename,
          reconciled.parentsAreValid,
          reconciled.destination == .other
        else {
          return report(
            .manualRecoveryRequired(
              location: observedDestinationLocation,
              reason: descriptorQuarantineIndeterminateReason(
                reconciliation: reconciled
              )
            ),
            cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
          )
        }
        continue
      case .failed(let code):
        if reconciled.source == .expectedCandidate,
          reconciled.candidateStillMatchesPreRename,
          reconciled.parentsAreValid,
          reconciled.destination == .missing
        {
          return report(
            .notMoved(.renameRejected(descriptorQuarantineFailure(for: code))),
            cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
          )
        }
        return report(
          .manualRecoveryRequired(
            location: observedDestinationLocation,
            reason: code == EINTR || code == EIO
              ? .renameOutcomeIndeterminate
              : descriptorQuarantineIndeterminateReason(reconciliation: reconciled)
          ),
          cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
        )
      case .succeeded:
        return report(
          .manualRecoveryRequired(
            location: observedDestinationLocation,
            reason: descriptorQuarantineIndeterminateReason(
              reconciliation: reconciled
            )
          ),
          cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
        )
      }
    }

    return report(
      .notMoved(.destinationCollisionLimitExceeded),
      cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
    )
  }

  private func validatePreRenameBindings(
    _ scope: DescriptorNPMQuarantineCandidateScope,
    expectedRootSnapshot: DescriptorStatSnapshot,
    quarantineRootDescriptor: Int32,
    quarantineRootComponent: DescriptorPathComponent,
    expectedQuarantineRootSnapshot: DescriptorStatSnapshot
  ) -> PreRenameValidation {
    switch validateQuarantineRoot(
      descriptor: quarantineRootDescriptor,
      namedAt: scope.heldRootDescriptor,
      component: quarantineRootComponent,
      expectedSnapshot: expectedQuarantineRootSnapshot,
      expectedDevice: scope.rootSnapshot.identity.device,
      expectedUID: scope.accountUID,
      cancellationPolicy: .observeTaskCancellation
    ) {
    case .valid:
      break
    case .unsafe:
      return .quarantineRootUnsafe
    case .unsupported:
      return .unsupported
    case .cancelled:
      return .cancelled
    case .unavailable(let failure):
      return .unavailable(failure)
    }

    // Source validation is deliberately last. The test hook follows it and
    // the exclusive rename is the next filesystem syscall.
    switch validateSource(
      scope,
      expectedRootSnapshot: expectedRootSnapshot,
      cancellationPolicy: .observeTaskCancellation
    ) {
    case .valid:
      return .valid
    case .candidateMissing:
      return .candidateMissing
    case .candidateChanged:
      return .candidateChanged
    case .candidateUnsafe:
      return .candidateUnsafe
    case .parentChanged:
      return .parentChanged
    case .invalidCurrentAccount:
      return .invalidCurrentAccount
    case .cancelled:
      return .cancelled
    case .unavailable(let failure):
      return .unavailable(failure)
    }
  }

  private func validateSource(
    _ scope: DescriptorNPMQuarantineCandidateScope,
    expectedRootSnapshot: DescriptorStatSnapshot,
    cancellationPolicy: DescriptorCancellationPolicy
  ) -> SourceValidation {
    do {
      guard dependencies.currentAccountUID() == scope.accountUID else {
        return .invalidCurrentAccount
      }
      let heldRoot = try DescriptorStatSnapshot.read(
        from: scope.heldRootDescriptor,
        cancellationPolicy: cancellationPolicy
      )
      let namedRoot = try descriptorSnapshot(
        atAbsoluteComponents: scope.absoluteRootComponents,
        homeComponentCount: scope.homeComponentCount,
        cancellationPolicy: cancellationPolicy
      )
      guard
        descriptorQuarantineSnapshotMatchesApproval(
          heldRoot,
          expected: expectedRootSnapshot
        ),
        namedRoot.sameBinding(as: heldRoot),
        namedRoot.sameMutationState(as: heldRoot),
        namedRoot.ownerUID == heldRoot.ownerUID,
        namedRoot.permissionMode == heldRoot.permissionMode,
        namedRoot.flags == heldRoot.flags,
        heldRoot.kind == .directory,
        heldRoot.identity.device == scope.rootSnapshot.identity.device,
        heldRoot.ownerUID == scope.accountUID,
        heldRoot.permissionMode == scope.rootSnapshot.permissionMode,
        heldRoot.flags == scope.rootSnapshot.flags,
        heldRoot.permissionMode & mode_t(0o022) == 0,
        heldRoot.flags == 0,
        try !descriptorHasExtendedACL(scope.heldRootDescriptor)
      else {
        return .parentChanged
      }

      let heldCandidate = try DescriptorStatSnapshot.read(
        from: scope.heldCandidateDescriptor,
        cancellationPolicy: cancellationPolicy
      )
      let sourceComponent = DescriptorPathComponent(scope.entry.path.rawComponents[0])!
      let namedCandidate: DescriptorStatSnapshot
      do {
        namedCandidate = try DescriptorStatSnapshot.read(
          at: scope.heldRootDescriptor,
          component: sourceComponent,
          cancellationPolicy: cancellationPolicy
        )
      } catch DescriptorObservationError.posix(ENOENT) {
        return .candidateMissing
      }
      guard
        descriptorQuarantineSnapshotMatchesApproval(
          heldCandidate,
          expected: scope.candidateSnapshot
        ),
        namedCandidate.sameBinding(as: heldCandidate),
        namedCandidate.sameMutationState(as: heldCandidate),
        namedCandidate.ownerUID == heldCandidate.ownerUID,
        namedCandidate.permissionMode == heldCandidate.permissionMode,
        namedCandidate.flags == heldCandidate.flags,
        namedCandidate.linkCount == heldCandidate.linkCount
      else {
        return .candidateChanged
      }
      guard
        heldCandidate.kind == .directory,
        heldCandidate.identity == scope.entry.expectedIdentity,
        heldCandidate.identity.device == scope.rootSnapshot.identity.device,
        heldCandidate.ownerUID == scope.accountUID,
        heldCandidate.permissionMode & mode_t(0o022) == 0,
        heldCandidate.flags == 0,
        try !descriptorHasExtendedACL(scope.heldCandidateDescriptor)
      else {
        return .candidateUnsafe
      }
      return .valid
    } catch is CancellationError {
      return .cancelled
    } catch {
      return .unavailable(descriptorQuarantineFailure(for: error))
    }
  }

  private func validateQuarantineRoot(
    descriptor: Int32,
    namedAt parentDescriptor: Int32,
    component: DescriptorPathComponent,
    expectedSnapshot: DescriptorStatSnapshot?,
    expectedDevice: UInt64,
    expectedUID: uid_t,
    cancellationPolicy: DescriptorCancellationPolicy
  ) -> QuarantineRootValidation {
    do {
      let held = try DescriptorStatSnapshot.read(
        from: descriptor,
        cancellationPolicy: cancellationPolicy
      )
      let named = try DescriptorStatSnapshot.read(
        at: parentDescriptor,
        component: component,
        cancellationPolicy: cancellationPolicy
      )
      guard
        held.sameBinding(as: named),
        named.sameMutationState(as: held),
        named.kind == held.kind,
        named.identity.device == held.identity.device,
        named.ownerUID == held.ownerUID,
        named.permissionMode == held.permissionMode,
        named.flags == held.flags
      else {
        return .unsafe
      }
      if let expectedSnapshot {
        guard
          descriptorQuarantineSnapshotMatchesApproval(
            held,
            expected: expectedSnapshot
          ),
          named.sameMutationState(as: held)
        else {
          return .unsafe
        }
      }
      guard
        held.kind == .directory,
        held.identity.device == expectedDevice,
        held.ownerUID == expectedUID,
        held.permissionMode == mode_t(0o700),
        held.flags == 0
      else {
        return .unsafe
      }

      switch dependencies.hasExtendedACL(descriptor) {
      case .success(false):
        break
      case .success(true):
        return .unsafe
      case .failure(let failure):
        return .unavailable(failure)
      }

      switch dependencies.volumeCapabilities(descriptor) {
      case .success(let capabilities):
        guard
          capabilities.supportsExclusiveRename,
          capabilities.supportsPOSIXPermissions
        else {
          return .unsupported
        }
      case .failure(let failure):
        return .unavailable(failure)
      }
      return .valid
    } catch is CancellationError {
      return .cancelled
    } catch {
      return .unavailable(descriptorQuarantineFailure(for: error))
    }
  }

  private func reconcileAfterRename(
    _ scope: DescriptorNPMQuarantineCandidateScope,
    sourceComponent: DescriptorPathComponent,
    quarantineRootDescriptor: Int32,
    quarantineRootComponent: DescriptorPathComponent,
    destinationComponent: DescriptorPathComponent
  ) -> RenameReconciliation {
    let policy = DescriptorCancellationPolicy.ignoreTaskCancellation
    let heldCandidate = try? DescriptorStatSnapshot.read(
      from: scope.heldCandidateDescriptor,
      cancellationPolicy: policy
    )
    let candidateHasNoExtendedACL: Bool?
    do {
      candidateHasNoExtendedACL = try !descriptorHasExtendedACL(
        scope.heldCandidateDescriptor
      )
    } catch {
      candidateHasNoExtendedACL = nil
    }
    let source = descriptorQuarantineNamedObservation(
      parentDescriptor: scope.heldRootDescriptor,
      component: sourceComponent,
      heldCandidate: heldCandidate,
      cancellationPolicy: policy
    )
    let destination = descriptorQuarantineNamedObservation(
      parentDescriptor: quarantineRootDescriptor,
      component: destinationComponent,
      heldCandidate: heldCandidate,
      cancellationPolicy: policy
    )
    let sourceParentIsValid = descriptorQuarantineRootBindingIsValid(
      scope,
      cancellationPolicy: policy
    )
    let quarantineParentIsValid: Bool
    switch validateQuarantineRoot(
      descriptor: quarantineRootDescriptor,
      namedAt: scope.heldRootDescriptor,
      component: quarantineRootComponent,
      expectedSnapshot: nil,
      expectedDevice: scope.rootSnapshot.identity.device,
      expectedUID: scope.accountUID,
      cancellationPolicy: policy
    ) {
    case .valid:
      quarantineParentIsValid = true
    case .unsafe, .unsupported, .cancelled, .unavailable:
      quarantineParentIsValid = false
    }
    return RenameReconciliation(
      source: source.binding,
      destination: destination.binding,
      destinationObservedIdentity: destination.observedIdentity,
      candidateMatchesApprovalAfterRename: heldCandidate.map {
        descriptorQuarantineSnapshotMatchesPostRename(
          $0,
          expected: scope.candidateSnapshot
        )
      } == true && candidateHasNoExtendedACL == true,
      candidateStillMatchesPreRename: heldCandidate.map {
        descriptorQuarantineSnapshotMatchesApproval(
          $0,
          expected: scope.candidateSnapshot
        )
      } == true && candidateHasNoExtendedACL == true,
      candidateValidationUnavailable: heldCandidate == nil
        || candidateHasNoExtendedACL == nil,
      parentsAreValid: sourceParentIsValid && quarantineParentIsValid
    )
  }

  private func rollback(
    _ scope: DescriptorNPMQuarantineCandidateScope,
    sourceComponent: DescriptorPathComponent,
    quarantineRootDescriptor: Int32,
    quarantineRootComponent: DescriptorPathComponent,
    destinationComponent: DescriptorPathComponent,
    location: CleanupQuarantineLocation,
    reason: CleanupQuarantineRollbackReason,
    rootMutation: CleanupQuarantineRootMutation,
    cancellationWasObservedAfterRename initialCancellation: Bool
  ) -> CleanupQuarantineExecutionReport {
    var cancellationWasObservedAfterRename =
      initialCancellation || dependencies.cancellationIsRequested()
    let policy = DescriptorCancellationPolicy.ignoreTaskCancellation
    guard
      let sourcePath = DescriptorQuarantineRelativePath([sourceComponent]),
      let destinationPath = DescriptorQuarantineRelativePath([
        quarantineRootComponent,
        destinationComponent,
      ])
    else {
      return CleanupQuarantineExecutionReport(
        path: scope.entry.path,
        ruleRevision: scope.entry.ruleRevision,
        status: .manualRecoveryRequired(
          location: location,
          reason: .rollbackFailed
        ),
        quarantineRootMutation: rootMutation,
        cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
      )
    }

    let beforeRollback = reconcileAfterRename(
      scope,
      sourceComponent: sourceComponent,
      quarantineRootDescriptor: quarantineRootDescriptor,
      quarantineRootComponent: quarantineRootComponent,
      destinationComponent: destinationComponent
    )
    cancellationWasObservedAfterRename =
      cancellationWasObservedAfterRename || dependencies.cancellationIsRequested()
    let beforeRollbackLocation: CleanupQuarantineLocation?
    if beforeRollback.parentsAreValid {
      switch beforeRollback.destination {
      case .expectedCandidate:
        beforeRollbackLocation = location
      case .other:
        beforeRollbackLocation = quarantineLocation(
          destinationComponent: destinationComponent,
          identity: beforeRollback.destinationObservedIdentity
        )
      case .missing, .unavailable:
        beforeRollbackLocation = nil
      }
    } else {
      beforeRollbackLocation = nil
    }
    guard beforeRollback.parentsAreValid else {
      return CleanupQuarantineExecutionReport(
        path: scope.entry.path,
        ruleRevision: scope.entry.ruleRevision,
        status: .manualRecoveryRequired(location: nil, reason: .parentBindingChanged),
        quarantineRootMutation: rootMutation,
        cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
      )
    }
    guard beforeRollback.source != .unavailable else {
      return CleanupQuarantineExecutionReport(
        path: scope.entry.path,
        ruleRevision: scope.entry.ruleRevision,
        status: .manualRecoveryRequired(
          location: beforeRollbackLocation,
          reason: .sourceCouldNotBeVerified
        ),
        quarantineRootMutation: rootMutation,
        cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
      )
    }
    guard beforeRollback.source == .missing else {
      return CleanupQuarantineExecutionReport(
        path: scope.entry.path,
        ruleRevision: scope.entry.ruleRevision,
        status: .manualRecoveryRequired(
          location: beforeRollbackLocation,
          reason: .sourceNameOccupied
        ),
        quarantineRootMutation: rootMutation,
        cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
      )
    }
    guard
      beforeRollback.destination == .expectedCandidate,
      (try? DescriptorStatSnapshot.read(
        from: scope.heldRootDescriptor,
        cancellationPolicy: policy
      ))?.sameBinding(as: scope.rootSnapshot) == true,
      (try? DescriptorStatSnapshot.read(
        from: quarantineRootDescriptor,
        cancellationPolicy: policy
      ))?.identity.device == scope.rootSnapshot.identity.device
    else {
      cancellationWasObservedAfterRename =
        cancellationWasObservedAfterRename || dependencies.cancellationIsRequested()
      return CleanupQuarantineExecutionReport(
        path: scope.entry.path,
        ruleRevision: scope.entry.ruleRevision,
        status: .manualRecoveryRequired(
          location: nil,
          reason: .destinationCouldNotBeVerified
        ),
        quarantineRootMutation: rootMutation,
        cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
      )
    }

    dependencies.hooks.beforeRollback()
    cancellationWasObservedAfterRename =
      cancellationWasObservedAfterRename || dependencies.cancellationIsRequested()
    let rollbackResult = dependencies.renameExclusive(
      scope.heldRootDescriptor,
      destinationPath,
      scope.heldRootDescriptor,
      sourcePath,
      Self.renameFlags
    )
    cancellationWasObservedAfterRename =
      cancellationWasObservedAfterRename || dependencies.cancellationIsRequested()

    let afterRollback = reconcileAfterRename(
      scope,
      sourceComponent: sourceComponent,
      quarantineRootDescriptor: quarantineRootDescriptor,
      quarantineRootComponent: quarantineRootComponent,
      destinationComponent: destinationComponent
    )
    cancellationWasObservedAfterRename =
      cancellationWasObservedAfterRename || dependencies.cancellationIsRequested()

    let status: CleanupQuarantineExecutionStatus
    let sourceRootIsValid = descriptorQuarantineRootBindingIsValid(
      scope,
      cancellationPolicy: policy
    )
    cancellationWasObservedAfterRename =
      cancellationWasObservedAfterRename || dependencies.cancellationIsRequested()
    let afterRollbackLocation: CleanupQuarantineLocation?
    if afterRollback.parentsAreValid {
      switch afterRollback.destination {
      case .expectedCandidate:
        afterRollbackLocation = location
      case .other:
        afterRollbackLocation = quarantineLocation(
          destinationComponent: destinationComponent,
          identity: afterRollback.destinationObservedIdentity
        )
      case .missing, .unavailable:
        afterRollbackLocation = nil
      }
    } else {
      afterRollbackLocation = nil
    }
    if !afterRollback.parentsAreValid || !sourceRootIsValid {
      status = .manualRecoveryRequired(location: nil, reason: .parentBindingChanged)
    } else if afterRollback.source == .unavailable {
      status = .manualRecoveryRequired(
        location: afterRollbackLocation,
        reason: .sourceCouldNotBeVerified
      )
    } else if afterRollback.source == .expectedCandidate {
      if afterRollback.candidateValidationUnavailable {
        status = .manualRecoveryRequired(
          location: afterRollbackLocation,
          reason: .sourceCouldNotBeVerified
        )
      } else if !afterRollback.candidateMatchesApprovalAfterRename {
        status = .manualRecoveryRequired(
          location: afterRollbackLocation,
          reason: .restoredObjectDidNotMatchApproval
        )
      } else if rollbackResult != .succeeded {
        status = .manualRecoveryRequired(
          location: afterRollbackLocation,
          reason: .rollbackOutcomeIndeterminate
        )
      } else if afterRollback.destination != .missing {
        status = .manualRecoveryRequired(
          location: afterRollbackLocation,
          reason: .destinationCouldNotBeVerified
        )
      } else {
        status = .rolledBack(reason)
      }
    } else if afterRollback.source == .other {
      status = .manualRecoveryRequired(
        location: afterRollbackLocation,
        reason: .sourceNameOccupied
      )
    } else {
      switch rollbackResult {
      case .failed(EINTR), .failed(EIO):
        status = .manualRecoveryRequired(
          location: afterRollbackLocation,
          reason: .rollbackOutcomeIndeterminate
        )
      case .succeeded, .failed:
        status = .manualRecoveryRequired(
          location: afterRollbackLocation,
          reason: .rollbackFailed
        )
      }
    }
    return CleanupQuarantineExecutionReport(
      path: scope.entry.path,
      ruleRevision: scope.entry.ruleRevision,
      status: status,
      quarantineRootMutation: rootMutation,
      cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
    )
  }

  private func destinationComponent(
    nonce: [UInt8]
  ) -> DescriptorPathComponent? {
    guard nonce.count == 16 else { return nil }
    let alphabet = Array("0123456789abcdef".utf8)
    var bytes = Self.destinationPrefixBytes
    bytes.reserveCapacity(Self.destinationPrefixBytes.count + 32)
    for byte in nonce {
      bytes.append(alphabet[Int(byte >> 4)])
      bytes.append(alphabet[Int(byte & 0x0F)])
    }
    return DescriptorPathComponent(bytes)
  }

  private func quarantineLocation(
    destinationComponent: DescriptorPathComponent,
    identity: FileIdentity?
  ) -> CleanupQuarantineLocation {
    CleanupQuarantineLocation(
      relativePath: ScanRelativePath(
        rawComponents: [Self.quarantineRootBytes, destinationComponent.bytes]
      ),
      observedIdentity: identity
    )
  }
}

private enum SourceValidation {
  case valid
  case candidateMissing
  case candidateChanged
  case candidateUnsafe
  case parentChanged
  case invalidCurrentAccount
  case cancelled
  case unavailable(CleanupQuarantineSystemFailure)
}

private enum QuarantineRootValidation {
  case valid
  case unsafe
  case unsupported
  case cancelled
  case unavailable(CleanupQuarantineSystemFailure)
}

private enum PreRenameValidation {
  case valid
  case candidateMissing
  case candidateChanged
  case candidateUnsafe
  case parentChanged
  case invalidCurrentAccount
  case quarantineRootUnsafe
  case unsupported
  case cancelled
  case unavailable(CleanupQuarantineSystemFailure)
}

private enum DescriptorNamedBinding: Equatable {
  case missing
  case expectedCandidate
  case other
  case unavailable
}

private struct DescriptorNamedObservation {
  let binding: DescriptorNamedBinding
  let observedIdentity: FileIdentity?
}

private struct RenameReconciliation {
  let source: DescriptorNamedBinding
  let destination: DescriptorNamedBinding
  let destinationObservedIdentity: FileIdentity?
  let candidateMatchesApprovalAfterRename: Bool
  let candidateStillMatchesPreRename: Bool
  let candidateValidationUnavailable: Bool
  let parentsAreValid: Bool
}

enum DescriptorQuarantineMkdirResult: Equatable, Sendable {
  case created
  case alreadyExists
  case failed(Int32)
}

private func descriptorQuarantineMakeRoot(
  _ parentDescriptor: Int32,
  _ component: DescriptorPathComponent
) -> DescriptorQuarantineMkdirResult {
  var failureCode: Int32 = EINVAL
  let result = component.withCString { pointer in
    let value = Darwin.mkdirat(parentDescriptor, pointer, mode_t(0o700))
    if value != 0 { failureCode = errno }
    return value
  }
  if result == 0 { return .created }
  if failureCode == EEXIST { return .alreadyExists }
  return .failed(failureCode)
}

private func descriptorQuarantineCurrentAccountUID() -> uid_t? {
  let real = Darwin.getuid()
  guard real != 0, real == Darwin.geteuid() else { return nil }
  return real
}

private func descriptorQuarantineRandomNonce(_ attempt: Int) -> [UInt8]? {
  guard attempt >= 0 else { return nil }
  var bytes = [UInt8](repeating: 0, count: 16)
  bytes.withUnsafeMutableBytes { buffer in
    if let address = buffer.baseAddress {
      Darwin.arc4random_buf(address, buffer.count)
    }
  }
  return bytes
}

private func descriptorQuarantineVolumeCapabilities(
  _ descriptor: Int32
) -> DescriptorQuarantineDependencyResult<DescriptorQuarantineVolumeCapabilities> {
  var attributes = attrlist()
  attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
  attributes.volattr = ATTR_VOL_INFO | UInt32(ATTR_VOL_CAPABILITIES)

  // Returned bytes are a UInt32 length followed by vol_capabilities_attr_t's
  // four capability and four validity words. All members are 4-byte aligned.
  var words = [UInt32](repeating: 0, count: 9)
  let result = words.withUnsafeMutableBytes { buffer in
    Darwin.fgetattrlist(
      descriptor,
      &attributes,
      buffer.baseAddress!,
      buffer.count,
      0
    )
  }
  guard result == 0 else {
    return .failure(descriptorQuarantineFailure(for: errno))
  }
  guard words[0] == UInt32(words.count * MemoryLayout<UInt32>.stride) else {
    return .failure(.invalidMetadata)
  }

  let capabilitiesFormat = words[1]
  let capabilitiesInterfaces = words[2]
  let validFormat = words[5]
  let validInterfaces = words[6]
  let renameMask = UInt32(VOL_CAP_INT_RENAME_EXCL)
  let noPermissionsMask = UInt32(VOL_CAP_FMT_NO_PERMISSIONS)
  return .success(
    DescriptorQuarantineVolumeCapabilities(
      supportsExclusiveRename: validInterfaces & renameMask == renameMask
        && capabilitiesInterfaces & renameMask == renameMask,
      supportsPOSIXPermissions: validFormat & noPermissionsMask == noPermissionsMask
        && capabilitiesFormat & noPermissionsMask == 0
    )
  )
}

private func descriptorQuarantineSupportsResolveBeneathRename() -> Bool {
  ProcessInfo.processInfo.isOperatingSystemAtLeast(
    OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
  )
}

private func descriptorQuarantineHasExtendedACL(
  _ descriptor: Int32
) -> DescriptorQuarantineDependencyResult<Bool> {
  do {
    return .success(try descriptorHasExtendedACL(descriptor))
  } catch {
    return .failure(descriptorQuarantineFailure(for: error))
  }
}

private func descriptorQuarantineRenameExclusive(
  fromDescriptor: Int32,
  fromComponent: DescriptorQuarantineRelativePath,
  toDescriptor: Int32,
  toComponent: DescriptorQuarantineRelativePath,
  flags: UInt32
) -> DescriptorExclusiveRenameResult {
  var failureCode: Int32 = EINVAL
  let result = fromComponent.withCString { fromPointer in
    toComponent.withCString { toPointer in
      let value = Darwin.renameatx_np(
        fromDescriptor,
        fromPointer,
        toDescriptor,
        toPointer,
        flags
      )
      if value != 0 { failureCode = errno }
      return value
    }
  }
  return result == 0 ? .succeeded : .failed(failureCode)
}

private func descriptorQuarantineSnapshotMatchesApproval(
  _ snapshot: DescriptorStatSnapshot,
  expected: DescriptorStatSnapshot
) -> Bool {
  snapshot.sameBinding(as: expected)
    && snapshot.sameMutationState(as: expected)
    && snapshot.ownerUID == expected.ownerUID
    && snapshot.permissionMode == expected.permissionMode
    && snapshot.flags == expected.flags
    && snapshot.linkCount == expected.linkCount
}

/// Rename can legitimately update ctime. Post-rename verification therefore
/// keeps the stable binding and security fields while omitting mutation time.
private func descriptorQuarantineSnapshotMatchesPostRename(
  _ snapshot: DescriptorStatSnapshot,
  expected: DescriptorStatSnapshot
) -> Bool {
  snapshot.sameBinding(as: expected)
    && snapshot.ownerUID == expected.ownerUID
    && snapshot.permissionMode == expected.permissionMode
    && snapshot.flags == expected.flags
    && snapshot.linkCount == expected.linkCount
}

private func descriptorQuarantineNamedObservation(
  parentDescriptor: Int32,
  component: DescriptorPathComponent,
  heldCandidate: DescriptorStatSnapshot?,
  cancellationPolicy: DescriptorCancellationPolicy
) -> DescriptorNamedObservation {
  do {
    let named = try DescriptorStatSnapshot.read(
      at: parentDescriptor,
      component: component,
      cancellationPolicy: cancellationPolicy
    )
    guard let heldCandidate else {
      return DescriptorNamedObservation(
        binding: .other,
        observedIdentity: named.identity
      )
    }
    let matchesHeldCandidate = descriptorQuarantineSnapshotMatchesPostRename(
      named,
      expected: heldCandidate
    )
    return DescriptorNamedObservation(
      binding: matchesHeldCandidate ? .expectedCandidate : .other,
      observedIdentity: named.identity
    )
  } catch DescriptorObservationError.posix(ENOENT) {
    return DescriptorNamedObservation(binding: .missing, observedIdentity: nil)
  } catch {
    return DescriptorNamedObservation(binding: .unavailable, observedIdentity: nil)
  }
}

private func descriptorQuarantineRootBindingIsValid(
  _ scope: DescriptorNPMQuarantineCandidateScope,
  cancellationPolicy: DescriptorCancellationPolicy
) -> Bool {
  do {
    let held = try DescriptorStatSnapshot.read(
      from: scope.heldRootDescriptor,
      cancellationPolicy: cancellationPolicy
    )
    let named = try descriptorSnapshot(
      atAbsoluteComponents: scope.absoluteRootComponents,
      homeComponentCount: scope.homeComponentCount,
      cancellationPolicy: cancellationPolicy
    )
    let rootHasExtendedACL = try descriptorHasExtendedACL(scope.heldRootDescriptor)
    return held.sameBinding(as: scope.rootSnapshot)
      && named.sameProtectedDescendantState(as: held)
      && named.kind == held.kind
      && named.identity.device == held.identity.device
      && named.ownerUID == held.ownerUID
      && named.permissionMode == held.permissionMode
      && named.flags == held.flags
      && held.kind == .directory
      && held.identity.device == scope.rootSnapshot.identity.device
      && held.ownerUID == scope.accountUID
      && held.permissionMode == scope.rootSnapshot.permissionMode
      && held.flags == scope.rootSnapshot.flags
      && held.permissionMode & mode_t(0o022) == 0
      && held.flags == 0
      && !rootHasExtendedACL
  } catch {
    return false
  }
}

private func descriptorQuarantineIndeterminateReason(
  reconciliation: RenameReconciliation
) -> CleanupQuarantineManualRecoveryReason {
  if !reconciliation.parentsAreValid {
    return .parentBindingChanged
  }
  if reconciliation.source == .unavailable {
    return .sourceCouldNotBeVerified
  }
  if reconciliation.source == .other || reconciliation.source == .expectedCandidate {
    return .sourceNameOccupied
  }
  if reconciliation.destination != .expectedCandidate {
    return .destinationCouldNotBeVerified
  }
  return .renameOutcomeIndeterminate
}

private func descriptorQuarantineFailure(
  for error: Error
) -> CleanupQuarantineSystemFailure {
  if let observation = error as? DescriptorObservationError {
    switch observation {
    case .bindingChanged, .crossedVolume:
      return .pathChanged
    case .markerEntryLimitExceeded, .protectedDescendantLimitExceeded:
      return .resourceLimit
    case .posix(let code):
      return descriptorQuarantineFailure(for: code)
    }
  }
  if error is CancellationError { return .pathChanged }
  let nsError = error as NSError
  if nsError.domain == NSPOSIXErrorDomain, let code = Int32(exactly: nsError.code) {
    return descriptorQuarantineFailure(for: code)
  }
  return .unspecified
}

private func descriptorQuarantineFailure(
  for code: Int32
) -> CleanupQuarantineSystemFailure {
  switch code {
  case EACCES, EPERM:
    return .permissionDenied
  case ENOENT, ENOTDIR, ELOOP, ESTALE, EAGAIN:
    return .pathChanged
  case ENOTSUP, ENOSYS, EINVAL:
    return .unsupported
  case EXDEV:
    return .crossDevice
  case EROFS:
    return .readOnlyFileSystem
  case ENOSPC, EDQUOT:
    return .noSpace
  case EMFILE, ENFILE, ENOMEM:
    return .resourceLimit
  case EFAULT, EOVERFLOW, ENAMETOOLONG:
    return .invalidMetadata
  case EIO, EINTR:
    return .inputOutput
  case EEXIST:
    return .destinationExists
  default:
    return .unspecified
  }
}
