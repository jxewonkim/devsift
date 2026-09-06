import Darwin
import Foundation

/// Descriptor-backed scope retained only for the synchronous staging call.
struct DescriptorNPMQuarantinePurgeStagingScope {
  let heldRootDescriptor: Int32
  let heldQuarantineRootDescriptor: Int32
  let heldQuarantinedItemDescriptor: Int32
  let recoveryRequest: DescriptorQuarantineJournalRecoveryRequest
  let claim: CleanupQuarantinePurgeExecutionClaim
}

struct DescriptorExclusiveQuarantinePurgeStagerHooks: Sendable {
  var afterDurableIntent: @Sendable () -> Void
  var afterFullTreeValidation: @Sendable () -> Void
  var afterFinalWorkAbsenceValidation: @Sendable () -> Void
  var afterRenameReturn: @Sendable (DescriptorExclusiveRenameResult) -> Void
  var beforeQuarantineRootSync: @Sendable () -> Void

  init(
    afterDurableIntent: @escaping @Sendable () -> Void = {},
    afterFullTreeValidation: @escaping @Sendable () -> Void = {},
    afterFinalWorkAbsenceValidation: @escaping @Sendable () -> Void = {},
    afterRenameReturn: @escaping @Sendable (DescriptorExclusiveRenameResult) -> Void = { _ in },
    beforeQuarantineRootSync: @escaping @Sendable () -> Void = {}
  ) {
    self.afterDurableIntent = afterDurableIntent
    self.afterFullTreeValidation = afterFullTreeValidation
    self.afterFinalWorkAbsenceValidation = afterFinalWorkAbsenceValidation
    self.afterRenameReturn = afterRenameReturn
    self.beforeQuarantineRootSync = beforeQuarantineRootSync
  }
}

struct DescriptorExclusiveQuarantinePurgeStagerDependencies: Sendable {
  typealias ReadDescriptor =
    @Sendable (Int32, DescriptorCancellationPolicy) throws -> DescriptorStatSnapshot
  typealias ReadNamed =
    @Sendable (
      Int32,
      DescriptorPathComponent,
      DescriptorCancellationPolicy
    ) throws -> DescriptorStatSnapshot
  typealias ReadAbsoluteRoot =
    @Sendable (
      [DescriptorPathComponent],
      Int,
      DescriptorCancellationPolicy
    ) throws -> DescriptorStatSnapshot
  typealias ValidateCompleteTree = DescriptorQuarantinePurgeJournalDependencies.ValidateCompleteTree

  var currentAccountUID: @Sendable () -> uid_t?
  var supportsResolveBeneathRename: @Sendable () -> Bool
  var readDescriptor: ReadDescriptor
  var readNamed: ReadNamed
  var readAbsoluteRoot: ReadAbsoluteRoot
  var hasExtendedACL: @Sendable (Int32) throws -> Bool
  var volumeCapabilities:
    @Sendable (
      Int32
    ) -> DescriptorQuarantineDependencyResult<DescriptorQuarantineVolumeCapabilities>
  var validateCompleteTree: ValidateCompleteTree
  var renameExclusive:
    @Sendable (
      Int32,
      DescriptorQuarantineRelativePath,
      Int32,
      DescriptorQuarantineRelativePath,
      UInt32
    ) -> DescriptorExclusiveRenameResult
  var fullSync: @Sendable (Int32) -> Int32?
  var journal: DescriptorQuarantinePurgeJournal
  var cancellationIsRequested: @Sendable () -> Bool
  var hooks: DescriptorExclusiveQuarantinePurgeStagerHooks

  init(
    currentAccountUID: @escaping @Sendable () -> uid_t? = descriptorPurgeCurrentAccountUID,
    supportsResolveBeneathRename: @escaping @Sendable () -> Bool =
      descriptorPurgeSupportsResolveBeneathRename,
    readDescriptor: @escaping ReadDescriptor = { descriptor, policy in
      try DescriptorStatSnapshot.read(from: descriptor, cancellationPolicy: policy)
    },
    readNamed: @escaping ReadNamed = { parent, component, policy in
      try DescriptorStatSnapshot.read(
        at: parent,
        component: component,
        cancellationPolicy: policy
      )
    },
    readAbsoluteRoot: @escaping ReadAbsoluteRoot = { components, homeCount, policy in
      try descriptorSnapshot(
        atAbsoluteComponents: components,
        homeComponentCount: homeCount,
        cancellationPolicy: policy
      )
    },
    hasExtendedACL: @escaping @Sendable (Int32) throws -> Bool = descriptorHasExtendedACL,
    volumeCapabilities:
      @escaping @Sendable (
        Int32
      ) -> DescriptorQuarantineDependencyResult<DescriptorQuarantineVolumeCapabilities> =
      descriptorPurgeVolumeCapabilities,
    validateCompleteTree: @escaping ValidateCompleteTree =
      descriptorPurgeStagerValidateCompleteTree,
    renameExclusive:
      @escaping @Sendable (
        Int32,
        DescriptorQuarantineRelativePath,
        Int32,
        DescriptorQuarantineRelativePath,
        UInt32
      ) -> DescriptorExclusiveRenameResult = descriptorPurgeRenameExclusive,
    fullSync: @escaping @Sendable (Int32) -> Int32? = descriptorPurgeFullSync,
    journal: DescriptorQuarantinePurgeJournal = DescriptorQuarantinePurgeJournal(),
    cancellationIsRequested: @escaping @Sendable () -> Bool = { Task.isCancelled },
    hooks: DescriptorExclusiveQuarantinePurgeStagerHooks =
      DescriptorExclusiveQuarantinePurgeStagerHooks()
  ) {
    self.currentAccountUID = currentAccountUID
    self.supportsResolveBeneathRename = supportsResolveBeneathRename
    self.readDescriptor = readDescriptor
    self.readNamed = readNamed
    self.readAbsoluteRoot = readAbsoluteRoot
    self.hasExtendedACL = hasExtendedACL
    self.volumeCapabilities = volumeCapabilities
    self.validateCompleteTree = validateCompleteTree
    self.renameExclusive = renameExclusive
    self.fullSync = fullSync
    self.journal = journal
    self.cancellationIsRequested = cancellationIsRequested
    self.hooks = hooks
  }
}

struct DescriptorQuarantinePurgeStagedWork: Sendable {
  let journalSession: DescriptorQuarantinePurgeJournalSession
  let workSnapshot: DescriptorStatSnapshot
  let quarantineNameWasRecreated: Bool
  let cancellationWasObservedAfterRename: Bool
}

enum DescriptorQuarantinePurgeStagingResult: Sendable {
  case notStaged(DescriptorQuarantinePurgeFailure)
  case intentRecorded(
    DescriptorQuarantinePurgeFailure,
    purgeTransactionID: String,
    stagingRenameWasInvoked: Bool
  )
  case staged(DescriptorQuarantinePurgeStagedWork)
  case unresolved(purgeTransactionID: String)
}

/// Publishes one immutable initial purge intent and stages its exact item.
/// This type never unlinks, removes, copies, overwrites, or rolls back a name.
struct DescriptorExclusiveQuarantinePurgeStager: Sendable {
  static let renameFlags = DescriptorExclusiveQuarantineMover.renameFlags

  private let dependencies: DescriptorExclusiveQuarantinePurgeStagerDependencies

  init(
    dependencies: DescriptorExclusiveQuarantinePurgeStagerDependencies =
      DescriptorExclusiveQuarantinePurgeStagerDependencies()
  ) {
    self.dependencies = dependencies
  }

  func stage(
    _ scope: DescriptorNPMQuarantinePurgeStagingScope
  ) -> DescriptorQuarantinePurgeStagingResult {
    guard case .initial(let evidence) = scope.claim.evidence else {
      return .notStaged(.invalidClaim)
    }
    let intent = evidence.purgeIntent
    guard
      validateClaimAndScope(scope, evidence: evidence),
      let itemComponent = DescriptorPathComponent(intent.quarantineItemComponent),
      let workComponent = DescriptorPathComponent(intent.purgeWorkComponent),
      let itemPath = DescriptorQuarantineRelativePath([itemComponent]),
      let workPath = DescriptorQuarantineRelativePath([workComponent])
    else {
      return .notStaged(.invalidClaim)
    }
    guard !dependencies.cancellationIsRequested() else {
      return .notStaged(.cancelled)
    }
    guard dependencies.supportsResolveBeneathRename() else {
      return .notStaged(.exclusiveRenameUnsupported)
    }

    switch validateParentsBeforeIntent(scope, intent: intent) {
    case .valid:
      break
    case .cancelled:
      return .notStaged(.cancelled)
    case .unsupported:
      return .notStaged(.exclusiveRenameUnsupported)
    case .changed, .unavailable:
      return .notStaged(.quarantinedItemChanged)
    }
    let preIntentSnapshot: DescriptorStatSnapshot
    switch validateCompleteTreeBeforeIntent(
      scope,
      intent: intent,
      itemComponent: itemComponent,
      workComponent: workComponent
    ) {
    case .valid(let snapshot):
      preIntentSnapshot = snapshot
    case .failure(let failure):
      return .notStaged(failure)
    }
    _ = preIntentSnapshot
    guard !dependencies.cancellationIsRequested() else {
      return .notStaged(.cancelled)
    }

    let journalSession: DescriptorQuarantinePurgeJournalSession
    switch dependencies.journal.begin(
      DescriptorQuarantinePurgeJournalBeginRequest(
        recoveryRequest: scope.recoveryRequest,
        quarantinedItemDescriptor: scope.heldQuarantinedItemDescriptor,
        claim: scope.claim
      )
    ) {
    case .success(let session):
      journalSession = session
    case .failure(let failure):
      if case .journal(.recoveryRequired(let transactionID)) = failure,
        transactionID == intent.purgeTransactionID
      {
        return .intentRecorded(
          failure,
          purgeTransactionID: intent.purgeTransactionID,
          stagingRenameWasInvoked: false
        )
      }
      return .notStaged(failure)
    }

    var keepSession = false
    defer {
      if !keepSession { journalSession.releasePreservingIntent() }
    }
    func pending(
      _ failure: DescriptorQuarantinePurgeFailure,
      renameWasInvoked: Bool
    ) -> DescriptorQuarantinePurgeStagingResult {
      .intentRecorded(
        failure,
        purgeTransactionID: intent.purgeTransactionID,
        stagingRenameWasInvoked: renameWasInvoked
      )
    }

    guard session(journalSession, exactlyMatches: evidence) else {
      return .unresolved(purgeTransactionID: intent.purgeTransactionID)
    }
    dependencies.hooks.afterDurableIntent()
    guard !dependencies.cancellationIsRequested() else {
      return pending(.cancelled, renameWasInvoked: false)
    }

    let treeSnapshot: DescriptorStatSnapshot
    switch validateCompleteTreeAfterIntent(
      scope,
      session: journalSession,
      itemComponent: itemComponent
    ) {
    case .valid(let snapshot):
      treeSnapshot = snapshot
    case .failure(let failure):
      return pending(failure, renameWasInvoked: false)
    }
    dependencies.hooks.afterFullTreeValidation()
    guard !dependencies.cancellationIsRequested() else {
      return pending(.cancelled, renameWasInvoked: false)
    }

    switch validateImmediatelyBeforeRename(
      scope,
      session: journalSession,
      itemComponent: itemComponent,
      workComponent: workComponent,
      treeSnapshot: treeSnapshot
    ) {
    case .valid:
      break
    case .failure(let failure):
      return pending(failure, renameWasInvoked: false)
    }
    dependencies.hooks.afterFinalWorkAbsenceValidation()
    guard !dependencies.cancellationIsRequested() else {
      return pending(.cancelled, renameWasInvoked: false)
    }

    let renameResult = dependencies.renameExclusive(
      scope.heldQuarantineRootDescriptor,
      itemPath,
      scope.heldQuarantineRootDescriptor,
      workPath,
      Self.renameFlags
    )
    var cancellationAfterRename = dependencies.cancellationIsRequested()
    dependencies.hooks.afterRenameReturn(renameResult)
    cancellationAfterRename = cancellationAfterRename || dependencies.cancellationIsRequested()

    let truthBeforeSync = reconcile(
      scope,
      session: journalSession,
      itemComponent: itemComponent,
      workComponent: workComponent,
      treeSnapshot: treeSnapshot
    )
    cancellationAfterRename = cancellationAfterRename || dependencies.cancellationIsRequested()

    switch truthBeforeSync.classification {
    case .staged:
      dependencies.hooks.beforeQuarantineRootSync()
      guard dependencies.fullSync(scope.heldQuarantineRootDescriptor) == nil else {
        return .unresolved(purgeTransactionID: intent.purgeTransactionID)
      }
      let truthAfterSync = reconcile(
        scope,
        session: journalSession,
        itemComponent: itemComponent,
        workComponent: workComponent,
        treeSnapshot: treeSnapshot
      )
      guard case .staged(let quarantineNameWasRecreated) = truthAfterSync.classification,
        let workSnapshot = truthAfterSync.workSnapshot,
        truthAfterSync.sameNamespaceBindings(as: truthBeforeSync)
      else {
        return .unresolved(purgeTransactionID: intent.purgeTransactionID)
      }
      keepSession = true
      return .staged(
        DescriptorQuarantinePurgeStagedWork(
          journalSession: journalSession,
          workSnapshot: workSnapshot,
          quarantineNameWasRecreated: quarantineNameWasRecreated,
          cancellationWasObservedAfterRename: cancellationAfterRename
        )
      )

    case .notStaged:
      let failure: DescriptorQuarantinePurgeFailure
      switch renameResult {
      case .succeeded:
        return .unresolved(purgeTransactionID: intent.purgeTransactionID)
      case .failed(let code):
        failure =
          code == EEXIST
          ? .workNameOccupied
          : .renameRejected(
            descriptorPurgeFailure(for: code)
          )
      }
      return pending(failure, renameWasInvoked: true)

    case .unresolved:
      return .unresolved(purgeTransactionID: intent.purgeTransactionID)
    }
  }

  private func validateClaimAndScope(
    _ scope: DescriptorNPMQuarantinePurgeStagingScope,
    evidence: CleanupQuarantinePurgeInitialPreparedEvidence
  ) -> Bool {
    let request = scope.recoveryRequest
    let claim = scope.claim
    let intent = evidence.purgeIntent
    let confirmation = claim.confirmation
    guard
      scope.heldRootDescriptor >= 0,
      scope.heldQuarantineRootDescriptor >= 0,
      scope.heldQuarantinedItemDescriptor >= 0,
      request.rootDescriptor == scope.heldRootDescriptor,
      request.quarantineRootDescriptor == scope.heldQuarantineRootDescriptor,
      request.quarantineRootComponent.bytes
        == DescriptorExclusiveQuarantineMover.quarantineRootBytes,
      request.accountUID != 0,
      claim.attemptKind == .initial,
      intent.sourceComponents == [Array("_cacache".utf8)],
      intent.purgePolicyRevision
        == QuarantinePurgeJournalIntentV1.currentPurgePolicyRevision,
      intent.resourceBounds == .current,
      confirmation.request.attemptKind == .initial,
      confirmation.statement == .initialPermanentDeletionRisksAccepted,
      confirmation.request.requiredStatement == confirmation.statement,
      confirmation.statement.policyRevision == intent.purgePolicyRevision,
      confirmation.request.subject.responsibleTool == "npm",
      confirmation.request.subject.originalName == "_cacache",
      dependencies.currentAccountUID() == request.accountUID
    else {
      return false
    }
    do {
      let derived = try QuarantinePurgeJournalV1Codec.makeIntent(
        purgeTransactionID: intent.purgeTransactionID,
        capacityBefore: intent.capacityBefore,
        canonicalQuarantineIntentBytes: evidence.canonicalQuarantineIntentBytes,
        canonicalQuarantineReceiptBytes: evidence.canonicalQuarantineReceiptBytes
      )
      return derived == intent
    } catch {
      return false
    }
  }

  private func session(
    _ session: DescriptorQuarantinePurgeJournalSession,
    exactlyMatches evidence: CleanupQuarantinePurgeInitialPreparedEvidence
  ) -> Bool {
    do {
      let decoded = try QuarantinePurgeJournalV1Codec.decodeIntent(
        session.canonicalIntentBytes,
        matchingQuarantineIntentBytes: evidence.canonicalQuarantineIntentBytes,
        matchingQuarantineReceiptBytes: evidence.canonicalQuarantineReceiptBytes
      )
      return session.purgeTransactionID == evidence.purgeIntent.purgeTransactionID
        && session.quarantineTransactionID == evidence.purgeIntent.quarantineTransactionID
        && session.intent == evidence.purgeIntent
        && decoded == evidence.purgeIntent
    } catch {
      return false
    }
  }

  private func validateParentsBeforeIntent(
    _ scope: DescriptorNPMQuarantinePurgeStagingScope,
    intent: QuarantinePurgeJournalIntentV1
  ) -> PurgeStagerParentValidation {
    guard dependencies.currentAccountUID() == scope.recoveryRequest.accountUID else {
      return .changed
    }
    do {
      let heldRoot = try dependencies.readDescriptor(
        scope.heldRootDescriptor,
        .observeTaskCancellation
      )
      let namedRoot = try dependencies.readAbsoluteRoot(
        scope.recoveryRequest.absoluteRootComponents,
        scope.recoveryRequest.homeComponentCount,
        .observeTaskCancellation
      )
      guard
        purgeHistoricalBinding(heldRoot, matches: intent.npmRootBinding),
        purgeCurrentNamedSnapshot(namedRoot, matches: heldRoot),
        heldRoot.kind == .directory,
        heldRoot.ownerUID == scope.recoveryRequest.accountUID,
        purgeHasSafeMutationMetadata(heldRoot),
        try !dependencies.hasExtendedACL(scope.heldRootDescriptor)
      else {
        return .changed
      }
      let heldQuarantineRoot = try dependencies.readDescriptor(
        scope.heldQuarantineRootDescriptor,
        .observeTaskCancellation
      )
      let namedQuarantineRoot = try dependencies.readNamed(
        scope.heldRootDescriptor,
        scope.recoveryRequest.quarantineRootComponent,
        .observeTaskCancellation
      )
      guard
        purgeHistoricalBinding(
          heldQuarantineRoot,
          matches: intent.quarantineRootBinding
        ),
        purgeCurrentNamedSnapshot(namedQuarantineRoot, matches: heldQuarantineRoot),
        heldQuarantineRoot.kind == .directory,
        heldQuarantineRoot.ownerUID == scope.recoveryRequest.accountUID,
        heldQuarantineRoot.identity.device == heldRoot.identity.device,
        heldQuarantineRoot.permissionMode == mode_t(0o700),
        heldQuarantineRoot.flags == 0,
        try !dependencies.hasExtendedACL(scope.heldQuarantineRootDescriptor)
      else {
        return .changed
      }
      switch dependencies.volumeCapabilities(scope.heldQuarantineRootDescriptor) {
      case .success(let capabilities):
        guard
          capabilities.supportsExclusiveRename,
          capabilities.supportsPOSIXPermissions
        else {
          return .unsupported
        }
      case .failure:
        return .unavailable
      }
      return .valid
    } catch is CancellationError {
      return .cancelled
    } catch {
      return .unavailable
    }
  }

  private func validateCompleteTreeBeforeIntent(
    _ scope: DescriptorNPMQuarantinePurgeStagingScope,
    intent: QuarantinePurgeJournalIntentV1,
    itemComponent: DescriptorPathComponent,
    workComponent: DescriptorPathComponent
  ) -> PurgeStagerTreeValidation {
    let snapshot: DescriptorStatSnapshot
    switch validateItem(
      scope,
      intent: intent,
      namedComponent: itemComponent,
      expectedCurrentSnapshot: nil,
      cancellationPolicy: .observeTaskCancellation
    ) {
    case .valid(let value):
      snapshot = value
    case .failure(let failure):
      return .failure(failure)
    }
    do {
      try dependencies.validateCompleteTree(
        scope.heldQuarantinedItemDescriptor,
        scope.heldQuarantineRootDescriptor,
        itemComponent,
        snapshot,
        intent.npmRootBinding.device,
        scope.recoveryRequest.accountUID
      )
    } catch is CancellationError {
      return .failure(.cancelled)
    } catch DescriptorNPMPurgeTreeValidationFailure.traversalLimitExceeded,
      DescriptorNPMPurgeTreeValidationFailure.invalidLimits
    {
      return .failure(.traversalLimitExceeded)
    } catch DescriptorNPMPurgeTreeValidationFailure.treeUnsafe,
      DescriptorNPMPurgeTreeValidationFailure.layoutMismatch
    {
      return .failure(.quarantinedItemUnsafe)
    } catch DescriptorNPMPurgeTreeValidationFailure.rootBindingMismatch,
      DescriptorNPMPurgeTreeValidationFailure.treeChanged
    {
      return .failure(.quarantinedItemChanged)
    } catch {
      return .failure(.quarantinedItemChanged)
    }

    do {
      _ = try dependencies.readNamed(
        scope.heldQuarantineRootDescriptor,
        workComponent,
        .observeTaskCancellation
      )
      return .failure(.workNameOccupied)
    } catch is CancellationError {
      return .failure(.cancelled)
    } catch let error where descriptorPurgePOSIXCode(error) == ENOENT {
      return .valid(snapshot)
    } catch {
      return .failure(.quarantinedItemChanged)
    }
  }

  private func validateCompleteTreeAfterIntent(
    _ scope: DescriptorNPMQuarantinePurgeStagingScope,
    session: DescriptorQuarantinePurgeJournalSession,
    itemComponent: DescriptorPathComponent
  ) -> PurgeStagerTreeValidation {
    switch validateParents(scope, session: session, mutationIsExpected: false) {
    case .valid:
      break
    case .cancelled:
      return .failure(.cancelled)
    case .unsupported:
      return .failure(.exclusiveRenameUnsupported)
    case .changed, .unavailable:
      return .failure(.quarantinedItemChanged)
    }
    let snapshot: DescriptorStatSnapshot
    switch validateItem(
      scope,
      intent: session.intent,
      namedComponent: itemComponent,
      expectedCurrentSnapshot: nil,
      cancellationPolicy: .observeTaskCancellation
    ) {
    case .valid(let value):
      snapshot = value
    case .failure(let failure):
      return .failure(failure)
    }
    do {
      try dependencies.validateCompleteTree(
        scope.heldQuarantinedItemDescriptor,
        scope.heldQuarantineRootDescriptor,
        itemComponent,
        snapshot,
        session.intent.npmRootBinding.device,
        scope.recoveryRequest.accountUID
      )
      return .valid(snapshot)
    } catch is CancellationError {
      return .failure(.cancelled)
    } catch DescriptorNPMPurgeTreeValidationFailure.traversalLimitExceeded,
      DescriptorNPMPurgeTreeValidationFailure.invalidLimits
    {
      return .failure(.traversalLimitExceeded)
    } catch DescriptorNPMPurgeTreeValidationFailure.treeUnsafe,
      DescriptorNPMPurgeTreeValidationFailure.layoutMismatch
    {
      return .failure(.quarantinedItemUnsafe)
    } catch {
      return .failure(.quarantinedItemChanged)
    }
  }

  private func validateImmediatelyBeforeRename(
    _ scope: DescriptorNPMQuarantinePurgeStagingScope,
    session: DescriptorQuarantinePurgeJournalSession,
    itemComponent: DescriptorPathComponent,
    workComponent: DescriptorPathComponent,
    treeSnapshot: DescriptorStatSnapshot
  ) -> PurgeStagerSimpleValidation {
    guard !dependencies.cancellationIsRequested() else {
      return .failure(.cancelled)
    }
    switch validateParents(scope, session: session, mutationIsExpected: false) {
    case .valid:
      break
    case .cancelled:
      return .failure(.cancelled)
    case .unsupported:
      return .failure(.exclusiveRenameUnsupported)
    case .changed, .unavailable:
      return .failure(.quarantinedItemChanged)
    }
    switch validateItem(
      scope,
      intent: session.intent,
      namedComponent: itemComponent,
      expectedCurrentSnapshot: treeSnapshot,
      cancellationPolicy: .observeTaskCancellation
    ) {
    case .valid:
      break
    case .failure(let failure):
      return .failure(failure)
    }
    // This no-follow work-name lookup is deliberately the final filesystem
    // call before the hook, cancellation check, and rename syscall.
    do {
      _ = try dependencies.readNamed(
        scope.heldQuarantineRootDescriptor,
        workComponent,
        .observeTaskCancellation
      )
      return .failure(.workNameOccupied)
    } catch is CancellationError {
      return .failure(.cancelled)
    } catch let error where descriptorPurgePOSIXCode(error) == ENOENT {
      return .valid
    } catch {
      return .failure(.quarantinedItemChanged)
    }
  }

  private func validateParents(
    _ scope: DescriptorNPMQuarantinePurgeStagingScope,
    session: DescriptorQuarantinePurgeJournalSession,
    mutationIsExpected: Bool
  ) -> PurgeStagerParentValidation {
    guard dependencies.currentAccountUID() == scope.recoveryRequest.accountUID else {
      return .changed
    }
    do {
      let policy: DescriptorCancellationPolicy =
        mutationIsExpected ? .ignoreTaskCancellation : .observeTaskCancellation
      let heldRoot = try dependencies.readDescriptor(scope.heldRootDescriptor, policy)
      let namedRoot = try dependencies.readAbsoluteRoot(
        scope.recoveryRequest.absoluteRootComponents,
        scope.recoveryRequest.homeComponentCount,
        policy
      )
      guard
        purgeParentSnapshot(
          heldRoot,
          matches: session.rootSnapshotAfterIntent,
          historicalBinding: session.intent.npmRootBinding,
          mutationIsExpected: false,
          requiredMode: nil
        ),
        purgeCurrentNamedSnapshot(namedRoot, matches: heldRoot),
        try !dependencies.hasExtendedACL(scope.heldRootDescriptor)
      else {
        return .changed
      }
      let heldQuarantineRoot = try dependencies.readDescriptor(
        scope.heldQuarantineRootDescriptor,
        policy
      )
      let namedQuarantineRoot = try dependencies.readNamed(
        scope.heldRootDescriptor,
        scope.recoveryRequest.quarantineRootComponent,
        policy
      )
      guard
        purgeParentSnapshot(
          heldQuarantineRoot,
          matches: session.quarantineRootSnapshotAfterIntent,
          historicalBinding: session.intent.quarantineRootBinding,
          mutationIsExpected: mutationIsExpected,
          requiredMode: mode_t(0o700)
        ),
        heldQuarantineRoot.identity.device == heldRoot.identity.device,
        purgeCurrentNamedSnapshot(namedQuarantineRoot, matches: heldQuarantineRoot),
        try !dependencies.hasExtendedACL(scope.heldQuarantineRootDescriptor)
      else {
        return .changed
      }
      switch dependencies.volumeCapabilities(scope.heldQuarantineRootDescriptor) {
      case .success(let capabilities):
        guard capabilities.supportsExclusiveRename,
          capabilities.supportsPOSIXPermissions
        else {
          return .unsupported
        }
      case .failure:
        return .unavailable
      }
      return .valid
    } catch is CancellationError {
      return .cancelled
    } catch {
      return .unavailable
    }
  }

  private func validateItem(
    _ scope: DescriptorNPMQuarantinePurgeStagingScope,
    intent: QuarantinePurgeJournalIntentV1,
    namedComponent: DescriptorPathComponent,
    expectedCurrentSnapshot: DescriptorStatSnapshot?,
    cancellationPolicy: DescriptorCancellationPolicy
  ) -> PurgeStagerItemValidation {
    do {
      let held = try dependencies.readDescriptor(
        scope.heldQuarantinedItemDescriptor,
        cancellationPolicy
      )
      let named = try dependencies.readNamed(
        scope.heldQuarantineRootDescriptor,
        namedComponent,
        cancellationPolicy
      )
      guard
        purgeHistoricalBinding(held, matches: intent.candidateBinding),
        purgeCurrentNamedSnapshot(named, matches: held)
      else {
        return .failure(.quarantinedItemChanged)
      }
      if let expectedCurrentSnapshot {
        guard
          held.sameProtectedDescendantState(as: expectedCurrentSnapshot),
          held.permissionMode == expectedCurrentSnapshot.permissionMode,
          held.flags == expectedCurrentSnapshot.flags
        else {
          return .failure(.quarantinedItemChanged)
        }
      }
      guard
        held.kind == .directory,
        held.linkCount >= 2,
        held.ownerUID == scope.recoveryRequest.accountUID,
        held.identity.device == intent.npmRootBinding.device,
        purgeHasSafeMutationMetadata(held),
        try !dependencies.hasExtendedACL(scope.heldQuarantinedItemDescriptor)
      else {
        return .failure(.quarantinedItemUnsafe)
      }
      return .valid(held)
    } catch is CancellationError {
      return .failure(.cancelled)
    } catch let error where descriptorPurgePOSIXCode(error) == ENOENT {
      return .failure(.quarantinedItemMissing)
    } catch {
      return .failure(.quarantinedItemChanged)
    }
  }

  private func reconcile(
    _ scope: DescriptorNPMQuarantinePurgeStagingScope,
    session: DescriptorQuarantinePurgeJournalSession,
    itemComponent: DescriptorPathComponent,
    workComponent: DescriptorPathComponent,
    treeSnapshot: DescriptorStatSnapshot
  ) -> PurgeStagerNamespaceTruth {
    let parentsAreValid: Bool
    switch validateParents(scope, session: session, mutationIsExpected: true) {
    case .valid:
      parentsAreValid = true
    case .cancelled, .changed, .unsupported, .unavailable:
      parentsAreValid = false
    }

    let heldSnapshot: DescriptorStatSnapshot?
    do {
      let held = try dependencies.readDescriptor(
        scope.heldQuarantinedItemDescriptor,
        .ignoreTaskCancellation
      )
      if purgeHistoricalBinding(held, matches: session.intent.candidateBinding),
        purgePostRenameSnapshot(held, matches: treeSnapshot),
        held.kind == .directory,
        held.linkCount >= 2,
        held.ownerUID == scope.recoveryRequest.accountUID,
        purgeHasSafeMutationMetadata(held),
        try !dependencies.hasExtendedACL(scope.heldQuarantinedItemDescriptor)
      {
        heldSnapshot = held
      } else {
        // A failed held-item check cannot make either managed name safe, but
        // once rename was invoked both Q and W must still be observed. Those
        // observations remain `other`/`unavailable` without a trusted held
        // binding and therefore keep the outcome unresolved.
        heldSnapshot = nil
      }
    } catch {
      heldSnapshot = nil
    }

    let quarantineItem = observeName(
      parentDescriptor: scope.heldQuarantineRootDescriptor,
      component: itemComponent,
      expected: session.intent.candidateBinding,
      heldSnapshot: heldSnapshot
    )
    let work = observeName(
      parentDescriptor: scope.heldQuarantineRootDescriptor,
      component: workComponent,
      expected: session.intent.candidateBinding,
      heldSnapshot: heldSnapshot
    )
    return PurgeStagerNamespaceTruth(
      parentsAreValid: parentsAreValid,
      heldItemIsExpected: heldSnapshot != nil,
      quarantineItem: quarantineItem,
      work: work,
      workSnapshot: work == .expected ? heldSnapshot : nil
    )
  }

  private func observeName(
    parentDescriptor: Int32,
    component: DescriptorPathComponent,
    expected: QuarantineJournalFileBindingV1,
    heldSnapshot: DescriptorStatSnapshot?
  ) -> PurgeStagerNamedBinding {
    do {
      let snapshot = try dependencies.readNamed(
        parentDescriptor,
        component,
        .ignoreTaskCancellation
      )
      let isExpected =
        purgeHistoricalBinding(snapshot, matches: expected)
        && heldSnapshot.map { purgeCurrentNamedSnapshot(snapshot, matches: $0) } == true
      return isExpected ? .expected : .other
    } catch let error where descriptorPurgePOSIXCode(error) == ENOENT {
      return .missing
    } catch {
      return .unavailable
    }
  }
}

private enum PurgeStagerParentValidation {
  case valid
  case cancelled
  case changed
  case unsupported
  case unavailable
}

private enum PurgeStagerTreeValidation {
  case valid(DescriptorStatSnapshot)
  case failure(DescriptorQuarantinePurgeFailure)
}

private enum PurgeStagerSimpleValidation {
  case valid
  case failure(DescriptorQuarantinePurgeFailure)
}

private enum PurgeStagerItemValidation {
  case valid(DescriptorStatSnapshot)
  case failure(DescriptorQuarantinePurgeFailure)
}

private enum PurgeStagerNamedBinding: Equatable {
  case missing
  case expected
  case other
  case unavailable
}

private enum PurgeStagerNamespaceClassification: Equatable {
  case notStaged
  case staged(quarantineNameWasRecreated: Bool)
  case unresolved
}

private struct PurgeStagerNamespaceTruth {
  let parentsAreValid: Bool
  let heldItemIsExpected: Bool
  let quarantineItem: PurgeStagerNamedBinding
  let work: PurgeStagerNamedBinding
  let workSnapshot: DescriptorStatSnapshot?

  var classification: PurgeStagerNamespaceClassification {
    guard parentsAreValid, heldItemIsExpected else { return .unresolved }
    switch (quarantineItem, work) {
    case (.expected, .missing):
      return .notStaged
    case (.missing, .expected):
      return .staged(quarantineNameWasRecreated: false)
    case (.other, .expected):
      return .staged(quarantineNameWasRecreated: true)
    default:
      return .unresolved
    }
  }

  func sameNamespaceBindings(as other: PurgeStagerNamespaceTruth) -> Bool {
    parentsAreValid == other.parentsAreValid
      && heldItemIsExpected == other.heldItemIsExpected
      && quarantineItem == other.quarantineItem
      && work == other.work
      && workSnapshot.map(purgeStableSnapshotIdentity)
        == other.workSnapshot.map(purgeStableSnapshotIdentity)
  }
}

private struct PurgeStableSnapshotIdentity: Equatable {
  let identity: FileIdentity
  let generation: UInt32
  let birthSeconds: Int
  let birthNanoseconds: Int
  let kind: FileSystemEntryKind
  let ownerUID: uid_t
  let permissionMode: mode_t
  let flags: UInt32
}

private func purgeStableSnapshotIdentity(
  _ snapshot: DescriptorStatSnapshot
) -> PurgeStableSnapshotIdentity {
  PurgeStableSnapshotIdentity(
    identity: snapshot.identity,
    generation: snapshot.generation,
    birthSeconds: snapshot.birthSeconds,
    birthNanoseconds: snapshot.birthNanoseconds,
    kind: snapshot.kind,
    ownerUID: snapshot.ownerUID,
    permissionMode: snapshot.permissionMode,
    flags: snapshot.flags
  )
}

private func purgeParentSnapshot(
  _ observed: DescriptorStatSnapshot,
  matches expected: DescriptorStatSnapshot,
  historicalBinding: QuarantineJournalFileBindingV1,
  mutationIsExpected: Bool,
  requiredMode: mode_t?
) -> Bool {
  guard
    observed.sameBinding(as: expected),
    observed.kind == .directory,
    observed.ownerUID == expected.ownerUID,
    observed.permissionMode == expected.permissionMode,
    observed.flags == expected.flags,
    purgeHasSafeMutationMetadata(observed),
    purgeHistoricalBinding(observed, matches: historicalBinding)
  else {
    return false
  }
  if let requiredMode, observed.permissionMode != requiredMode { return false }
  if !mutationIsExpected {
    return observed.sameMutationState(as: expected)
      && observed.linkCount == expected.linkCount
  }
  return true
}

private func purgeCurrentNamedSnapshot(
  _ named: DescriptorStatSnapshot,
  matches held: DescriptorStatSnapshot
) -> Bool {
  named.sameProtectedDescendantState(as: held)
    && named.kind == held.kind
    && named.permissionMode == held.permissionMode
    && named.flags == held.flags
}

/// Renaming a directory can legitimately update its ctime. The staging
/// reconciliation therefore pins the stable object identity, owner and all
/// mutation-safety metadata while deliberately excluding change time.
private func purgePostRenameSnapshot(
  _ observed: DescriptorStatSnapshot,
  matches expected: DescriptorStatSnapshot
) -> Bool {
  observed.sameBinding(as: expected)
    && observed.ownerUID == expected.ownerUID
    && observed.permissionMode == expected.permissionMode
    && observed.flags == expected.flags
    && observed.linkCount == expected.linkCount
    && observed.modificationSeconds == expected.modificationSeconds
    && observed.modificationNanoseconds == expected.modificationNanoseconds
}

private func purgeHistoricalBinding(
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

private func purgeHasSafeMutationMetadata(_ snapshot: DescriptorStatSnapshot) -> Bool {
  snapshot.permissionMode & mode_t(0o022) == 0 && snapshot.flags == 0
}

private func descriptorPurgeCurrentAccountUID() -> uid_t? {
  let real = Darwin.getuid()
  guard real != 0, real == Darwin.geteuid() else { return nil }
  return real
}

private func descriptorPurgeSupportsResolveBeneathRename() -> Bool {
  ProcessInfo.processInfo.isOperatingSystemAtLeast(
    OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
  )
}

private func descriptorPurgeStagerValidateCompleteTree(
  descriptor: Int32,
  parentDescriptor: Int32,
  component: DescriptorPathComponent,
  expected: DescriptorStatSnapshot,
  rootDevice: UInt64,
  accountUID: uid_t
) throws {
  _ = try DescriptorNPMCompletePurgeTreeValidator(
    checkpoint: { try Task.checkCancellation() }
  ).validate(
    descriptor: descriptor,
    namedAt: parentDescriptor,
    component: component,
    expected: expected,
    rootDevice: rootDevice,
    accountUID: accountUID
  )
}

private func descriptorPurgeVolumeCapabilities(
  _ descriptor: Int32
) -> DescriptorQuarantineDependencyResult<DescriptorQuarantineVolumeCapabilities> {
  var attributes = attrlist()
  attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
  attributes.volattr = ATTR_VOL_INFO | UInt32(ATTR_VOL_CAPABILITIES)
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
    return .failure(descriptorPurgeFailure(for: errno))
  }
  guard words[0] == UInt32(words.count * MemoryLayout<UInt32>.stride) else {
    return .failure(.invalidMetadata)
  }
  let renameMask = UInt32(VOL_CAP_INT_RENAME_EXCL)
  let noPermissionsMask = UInt32(VOL_CAP_FMT_NO_PERMISSIONS)
  return .success(
    DescriptorQuarantineVolumeCapabilities(
      supportsExclusiveRename: words[6] & renameMask == renameMask
        && words[2] & renameMask == renameMask,
      supportsPOSIXPermissions: words[5] & noPermissionsMask == noPermissionsMask
        && words[1] & noPermissionsMask == 0
    )
  )
}

private func descriptorPurgeRenameExclusive(
  fromDescriptor: Int32,
  fromPath: DescriptorQuarantineRelativePath,
  toDescriptor: Int32,
  toPath: DescriptorQuarantineRelativePath,
  flags: UInt32
) -> DescriptorExclusiveRenameResult {
  var failureCode: Int32 = EINVAL
  let result = fromPath.withCString { fromPointer in
    toPath.withCString { toPointer in
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

private func descriptorPurgeFullSync(_ descriptor: Int32) -> Int32? {
  let maximumAttempts = Int(
    QuarantinePurgeJournalResourceBoundsV1.current.maximumInterruptedSystemCallAttempts
  )
  for attempt in 0..<maximumAttempts {
    if Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 { return nil }
    let code = errno
    if code == EINTR, attempt + 1 < maximumAttempts { continue }
    return code
  }
  return EINTR
}

private func descriptorPurgePOSIXCode(_ error: Error) -> Int32? {
  if case DescriptorObservationError.posix(let code) = error { return code }
  if let error = error as? DescriptorJournalPOSIXError { return error.code }
  let nsError = error as NSError
  guard nsError.domain == NSPOSIXErrorDomain else { return nil }
  return Int32(exactly: nsError.code)
}

private func descriptorPurgeFailure(
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
