import Darwin
import Foundation

/// Descriptor-backed authority which is valid only for the synchronous body
/// that opened and validated all three directories. None of these descriptors
/// may escape that body.
struct DescriptorNPMQuarantineRestoreScope {
  let heldRootDescriptor: Int32
  let heldQuarantineRootDescriptor: Int32
  let heldQuarantinedItemDescriptor: Int32
  let recoveryRequest: DescriptorQuarantineJournalRecoveryRequest
  let claim: CleanupQuarantineRestoreExecutionClaim
  let ruleRevision: RuleRevision
}

struct DescriptorExclusiveQuarantineRestorerHooks: Sendable {
  var afterDurableIntent: @Sendable () -> Void
  var afterFullTreeValidation: @Sendable () -> Void
  var afterFinalSourceAbsenceValidation: @Sendable () -> Void
  var afterRenameReturn: @Sendable (DescriptorExclusiveRenameResult) -> Void

  init(
    afterDurableIntent: @escaping @Sendable () -> Void = {},
    afterFullTreeValidation: @escaping @Sendable () -> Void = {},
    afterFinalSourceAbsenceValidation: @escaping @Sendable () -> Void = {},
    afterRenameReturn: @escaping @Sendable (DescriptorExclusiveRenameResult) -> Void = { _ in }
  ) {
    self.afterDurableIntent = afterDurableIntent
    self.afterFullTreeValidation = afterFullTreeValidation
    self.afterFinalSourceAbsenceValidation = afterFinalSourceAbsenceValidation
    self.afterRenameReturn = afterRenameReturn
  }
}

/// Injectable seams remain internal. The production defaults use only held
/// descriptors, no-follow observations, and one exclusive rename.
struct DescriptorExclusiveQuarantineRestorerDependencies: Sendable {
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
  typealias ValidateTree =
    @Sendable (
      Int32,
      Int32,
      DescriptorPathComponent,
      DescriptorStatSnapshot,
      UInt64,
      uid_t
    ) throws -> Void

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
  var validateTree: ValidateTree
  var renameExclusive:
    @Sendable (
      Int32,
      DescriptorQuarantineRelativePath,
      Int32,
      DescriptorQuarantineRelativePath,
      UInt32
    ) -> DescriptorExclusiveRenameResult
  var journal: DescriptorQuarantineRestoreJournal
  var cancellationIsRequested: @Sendable () -> Bool
  var hooks: DescriptorExclusiveQuarantineRestorerHooks

  init(
    currentAccountUID: @escaping @Sendable () -> uid_t? = descriptorRestoreCurrentAccountUID,
    supportsResolveBeneathRename: @escaping @Sendable () -> Bool =
      descriptorRestoreSupportsResolveBeneathRename,
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
      descriptorRestoreVolumeCapabilities,
    validateTree: @escaping ValidateTree = descriptorRestoreValidateTree,
    renameExclusive:
      @escaping @Sendable (
        Int32,
        DescriptorQuarantineRelativePath,
        Int32,
        DescriptorQuarantineRelativePath,
        UInt32
      ) -> DescriptorExclusiveRenameResult = descriptorRestoreRenameExclusive,
    journal: DescriptorQuarantineRestoreJournal = DescriptorQuarantineRestoreJournal(),
    cancellationIsRequested: @escaping @Sendable () -> Bool = { Task.isCancelled },
    hooks: DescriptorExclusiveQuarantineRestorerHooks =
      DescriptorExclusiveQuarantineRestorerHooks()
  ) {
    self.currentAccountUID = currentAccountUID
    self.supportsResolveBeneathRename = supportsResolveBeneathRename
    self.readDescriptor = readDescriptor
    self.readNamed = readNamed
    self.readAbsoluteRoot = readAbsoluteRoot
    self.hasExtendedACL = hasExtendedACL
    self.volumeCapabilities = volumeCapabilities
    self.validateTree = validateTree
    self.renameExclusive = renameExclusive
    self.journal = journal
    self.cancellationIsRequested = cancellationIsRequested
    self.hooks = hooks
  }
}

/// Performs one restore rename after durable intent publication. It never
/// copies, links, unlinks, overwrites, retries, or rolls a restore back.
struct DescriptorExclusiveQuarantineRestorer: Sendable {
  static let sourceNameBytes = Array("_cacache".utf8)
  static let renameFlags = DescriptorExclusiveQuarantineMover.renameFlags

  private let dependencies: DescriptorExclusiveQuarantineRestorerDependencies

  init(
    dependencies: DescriptorExclusiveQuarantineRestorerDependencies =
      DescriptorExclusiveQuarantineRestorerDependencies()
  ) {
    self.dependencies = dependencies
  }

  /// The preflight caller keeps every scope descriptor open until this
  /// synchronous operation returns.
  func restore(
    _ scope: DescriptorNPMQuarantineRestoreScope
  ) -> CleanupQuarantineRestoreReport {
    let evidence = scope.claim.evidence
    let intent = evidence.restoreIntent
    let sourcePath = ScanRelativePath(rawComponents: intent.sourceComponents)

    func report(
      _ status: CleanupQuarantineRestoreStatus,
      durabilityState: CleanupQuarantineRestoreDurabilityState = .notRecorded,
      cancellationWasObservedAfterRename: Bool = false
    ) -> CleanupQuarantineRestoreReport {
      CleanupQuarantineRestoreReport(
        quarantineTransactionID: intent.quarantineTransactionID,
        restoreTransactionID: intent.restoreTransactionID,
        path: sourcePath,
        ruleRevision: scope.ruleRevision,
        status: status,
        durabilityState: durabilityState,
        cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
      )
    }

    guard validateClaimAndScope(scope) else {
      return report(.notRestored(.invalidClaim))
    }
    guard
      let itemComponent = DescriptorPathComponent(intent.quarantineItemComponent),
      let sourceComponent = DescriptorPathComponent(Self.sourceNameBytes),
      let itemRelativePath = DescriptorQuarantineRelativePath([itemComponent]),
      let sourceRelativePath = DescriptorQuarantineRelativePath([sourceComponent])
    else {
      return report(.notRestored(.invalidClaim))
    }
    guard !dependencies.cancellationIsRequested() else {
      return report(.notRestored(.cancelled))
    }
    guard dependencies.supportsResolveBeneathRename() else {
      return report(.notRestored(.exclusiveRenameUnsupported))
    }

    // Eligibility is established immediately before admission so an unsafe
    // tree cannot cause a durable restore intent. The complete pass is repeated
    // after intent publication because the confirmation and first pass are not
    // freshness authority for the rename.
    switch validateFullCurrentTreeBeforeIntent(scope, intent: intent) {
    case .valid:
      break
    case .cancelled:
      return report(.notRestored(.cancelled))
    case .itemMissing:
      return report(.notRestored(.quarantinedItemMissing))
    case .itemChanged:
      return report(.notRestored(.quarantinedItemChanged))
    case .itemUnsafe:
      return report(.notRestored(.quarantinedItemUnsafe))
    case .traversalLimitExceeded:
      return report(.notRestored(.traversalLimitExceeded))
    case .unsupported:
      return report(.notRestored(.exclusiveRenameUnsupported))
    case .parentChanged, .sourceOccupied, .unavailable:
      return report(.notRestored(.quarantinedItemChanged))
    }
    guard !dependencies.cancellationIsRequested() else {
      return report(.notRestored(.cancelled))
    }

    let journalSession: DescriptorQuarantineRestoreJournalSession
    switch dependencies.journal.begin(
      DescriptorQuarantineRestoreJournalBeginRequest(
        recoveryRequest: scope.recoveryRequest,
        quarantinedItemDescriptor: scope.heldQuarantinedItemDescriptor,
        claim: scope.claim
      ))
    {
    case .success(let value):
      journalSession = value
    case .failure(let failure):
      return reportForBeginFailure(failure, base: report)
    }

    guard session(journalSession, exactlyMatches: evidence) else {
      _ = dependencies.journal.finish(
        journalSession,
        outcome: .unresolved,
        namespaceMutationMayHaveBeenInvoked: false
      )
      return report(
        .manualRecoveryRequired(
          quarantineLocation: quarantineLocation(intent: intent, observedIdentity: nil),
          reason: .quarantineJournalUnsafe
        ),
        durabilityState: .unresolved(restoreTransactionID: journalSession.restoreTransactionID)
      )
    }

    var namespaceMutationWasInvoked = false

    func finish(
      status: CleanupQuarantineRestoreStatus,
      outcome: DescriptorQuarantineRestoreJournalTerminalOutcome,
      cancellationWasObservedAfterRename: Bool = false
    ) -> CleanupQuarantineRestoreReport {
      let pending = report(
        status,
        durabilityState: .intentRecorded(
          restoreTransactionID: journalSession.restoreTransactionID
        ),
        cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
      )
      let finishResult = dependencies.journal.finish(
        journalSession,
        outcome: outcome,
        namespaceMutationMayHaveBeenInvoked: namespaceMutationWasInvoked
      )
      return mapFinish(
        finishResult,
        requestedOutcome: outcome,
        session: journalSession,
        pendingReport: pending
      )
    }

    func finishWithoutMutation(
      _ status: CleanupQuarantineRestoreStatus
    ) -> CleanupQuarantineRestoreReport {
      let truth = reconcile(
        scope,
        session: journalSession,
        parentMutationIsExpected: false
      )
      switch truth.terminalOutcome {
      case .notRestored(let sourceNameWasOccupied):
        return finish(
          status: status,
          outcome: .notRestored(sourceNameWasOccupied: sourceNameWasOccupied)
        )
      case .restored, .unresolved:
        return finish(
          status: manualRecoveryStatus(for: truth, fallback: status),
          outcome: .unresolved
        )
      }
    }

    dependencies.hooks.afterDurableIntent()
    guard !dependencies.cancellationIsRequested() else {
      return finishWithoutMutation(.notRestored(.cancelled))
    }

    let treeSnapshot: DescriptorStatSnapshot
    switch validateFullCurrentTree(scope, session: journalSession) {
    case .valid(let snapshot):
      treeSnapshot = snapshot
    case .cancelled:
      return finishWithoutMutation(.notRestored(.cancelled))
    case .parentChanged:
      return finishWithoutMutation(
        .manualRecoveryRequired(
          quarantineLocation: quarantineLocation(intent: intent, observedIdentity: nil),
          reason: .parentBindingChanged
        ))
    case .itemMissing:
      return finishWithoutMutation(.notRestored(.quarantinedItemMissing))
    case .itemChanged:
      return finishWithoutMutation(.notRestored(.quarantinedItemChanged))
    case .itemUnsafe:
      return finishWithoutMutation(.notRestored(.quarantinedItemUnsafe))
    case .traversalLimitExceeded:
      return finishWithoutMutation(.notRestored(.traversalLimitExceeded))
    case .unsupported:
      return finishWithoutMutation(.notRestored(.exclusiveRenameUnsupported))
    case .unavailable:
      return finishWithoutMutation(.notRestored(.quarantinedItemChanged))
    case .sourceOccupied:
      return finishWithoutMutation(.notRestored(.sourceNameOccupied))
    }

    dependencies.hooks.afterFullTreeValidation()
    guard !dependencies.cancellationIsRequested() else {
      return finishWithoutMutation(.notRestored(.cancelled))
    }

    switch validateImmediatelyBeforeRename(
      scope,
      session: journalSession,
      treeSnapshot: treeSnapshot
    ) {
    case .valid:
      break
    case .cancelled:
      return finishWithoutMutation(.notRestored(.cancelled))
    case .sourceOccupied:
      return finishWithoutMutation(.notRestored(.sourceNameOccupied))
    case .parentChanged:
      return finishWithoutMutation(
        .manualRecoveryRequired(
          quarantineLocation: quarantineLocation(intent: intent, observedIdentity: nil),
          reason: .parentBindingChanged
        ))
    case .itemMissing:
      return finishWithoutMutation(.notRestored(.quarantinedItemMissing))
    case .itemChanged:
      return finishWithoutMutation(.notRestored(.quarantinedItemChanged))
    case .itemUnsafe:
      return finishWithoutMutation(.notRestored(.quarantinedItemUnsafe))
    case .traversalLimitExceeded:
      return finishWithoutMutation(.notRestored(.traversalLimitExceeded))
    case .unsupported:
      return finishWithoutMutation(.notRestored(.exclusiveRenameUnsupported))
    case .unavailable:
      return finishWithoutMutation(.notRestored(.quarantinedItemChanged))
    }

    // Source absence was deliberately the final filesystem observation above.
    // If this hook does not cancel the attempt, rename is the next filesystem
    // syscall made by this type.
    dependencies.hooks.afterFinalSourceAbsenceValidation()
    guard !dependencies.cancellationIsRequested() else {
      return finishWithoutMutation(.notRestored(.cancelled))
    }

    namespaceMutationWasInvoked = true
    let renameResult = dependencies.renameExclusive(
      scope.heldQuarantineRootDescriptor,
      itemRelativePath,
      scope.heldRootDescriptor,
      sourceRelativePath,
      Self.renameFlags
    )
    var cancellationWasObservedAfterRename = dependencies.cancellationIsRequested()
    dependencies.hooks.afterRenameReturn(renameResult)
    cancellationWasObservedAfterRename =
      cancellationWasObservedAfterRename || dependencies.cancellationIsRequested()

    let truth = reconcile(
      scope,
      session: journalSession,
      parentMutationIsExpected: true
    )
    cancellationWasObservedAfterRename =
      cancellationWasObservedAfterRename || dependencies.cancellationIsRequested()

    switch (renameResult, truth.terminalOutcome) {
    case (.succeeded, .restored(let quarantineNameWasRecreated)):
      return finish(
        status: .restored(
          source: sourcePath,
          quarantineNameWasRecreated: quarantineNameWasRecreated
        ),
        outcome: .restored(quarantineNameWasRecreated: quarantineNameWasRecreated),
        cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
      )
    case (.failed(let code), .notRestored(let sourceNameWasOccupied)):
      let reason: CleanupQuarantineRestoreNotRestoredReason =
        sourceNameWasOccupied
        ? .sourceNameOccupied
        : .renameRejected(descriptorRestoreFailure(for: code))
      return finish(
        status: .notRestored(reason),
        outcome: .notRestored(sourceNameWasOccupied: sourceNameWasOccupied),
        cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
      )
    case (.succeeded, .notRestored), (.failed, .restored), (_, .unresolved):
      return finish(
        status: manualRecoveryStatus(
          for: truth,
          fallback: .manualRecoveryRequired(
            quarantineLocation: truth.quarantineLocation,
            reason: .renameOutcomeIndeterminate
          )
        ),
        outcome: .unresolved,
        cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
      )
    }
  }

  private func validateClaimAndScope(
    _ scope: DescriptorNPMQuarantineRestoreScope
  ) -> Bool {
    let request = scope.recoveryRequest
    let claim = scope.claim
    let evidence = claim.evidence
    let intent = evidence.restoreIntent
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
      intent.sourceComponents == [Self.sourceNameBytes],
      intent.restorePolicyRevision
        == QuarantineRestoreJournalIntentV1.currentRestorePolicyRevision,
      confirmation.statement
        == .restoreCurrentQuarantinedContentsToOriginalCacacheWithoutOverwriteWithNPMStoppedAndPostQuarantineChangesAccepted,
      confirmation.request.requiredStatement == confirmation.statement,
      confirmation.statement.policyRevision == intent.restorePolicyRevision,
      confirmation.request.subject.restoreTransactionID == intent.restoreTransactionID,
      confirmation.request.subject.quarantineTransactionID == intent.quarantineTransactionID,
      confirmation.request.subject.originalPath.rawComponents == intent.sourceComponents,
      confirmation.request.subject.quarantineItemPath.rawComponents
        == [
          DescriptorExclusiveQuarantineMover.quarantineRootBytes,
          intent.quarantineItemComponent,
        ],
      confirmation.request.subject.responsibleTool == "npm",
      dependencies.currentAccountUID() == request.accountUID
    else {
      return false
    }
    do {
      let quarantineIntent = try QuarantineJournalV1Codec.decodeIntent(
        evidence.canonicalQuarantineIntentBytes
      )
      guard
        scope.ruleRevision.identifier.rawValue == quarantineIntent.policy.npmRule.identifier,
        scope.ruleRevision.version.rawValue == quarantineIntent.policy.npmRule.version
      else {
        return false
      }
      try QuarantineRestoreJournalV1Codec.validate(
        intent,
        canonicalQuarantineIntentBytes: evidence.canonicalQuarantineIntentBytes,
        canonicalQuarantineReceiptBytes: evidence.canonicalQuarantineReceiptBytes
      )
      return try QuarantineRestoreJournalV1Codec.makeIntent(
        restoreTransactionID: intent.restoreTransactionID,
        canonicalQuarantineIntentBytes: evidence.canonicalQuarantineIntentBytes,
        canonicalQuarantineReceiptBytes: evidence.canonicalQuarantineReceiptBytes
      ) == intent
    } catch {
      return false
    }
  }

  private func session(
    _ session: DescriptorQuarantineRestoreJournalSession,
    exactlyMatches evidence: CleanupQuarantineRestorePreparedEvidence
  ) -> Bool {
    do {
      let decoded = try QuarantineRestoreJournalV1Codec.decodeIntent(
        session.canonicalIntentBytes,
        matchingQuarantineIntentBytes: evidence.canonicalQuarantineIntentBytes,
        matchingQuarantineReceiptBytes: evidence.canonicalQuarantineReceiptBytes
      )
      return session.restoreTransactionID == evidence.restoreIntent.restoreTransactionID
        && session.quarantineTransactionID == evidence.restoreIntent.quarantineTransactionID
        && session.intent == evidence.restoreIntent
        && decoded == evidence.restoreIntent
    } catch {
      return false
    }
  }

  private func reportForBeginFailure(
    _ failure: DescriptorQuarantineRestoreFailure,
    base: (
      CleanupQuarantineRestoreStatus,
      CleanupQuarantineRestoreDurabilityState,
      Bool
    ) -> CleanupQuarantineRestoreReport
  ) -> CleanupQuarantineRestoreReport {
    switch failure {
    case .cancelled:
      return base(.notRestored(.cancelled), .notRecorded, false)
    case .invalidClaim:
      return base(.notRestored(.invalidClaim), .notRecorded, false)
    case .transactionNotFound:
      return base(.notRestored(.originalTransactionUnavailable), .notRecorded, false)
    case .transactionNotRestorable:
      return base(.notRestored(.originalTransactionNotRestorable), .notRecorded, false)
    case .alreadyRestored:
      return base(.notRestored(.alreadyRestored), .notRecorded, false)
    case .sourceNameOccupied:
      return base(.notRestored(.sourceNameOccupied), .notRecorded, false)
    case .quarantinedItemMissing:
      return base(.notRestored(.quarantinedItemMissing), .notRecorded, false)
    case .quarantinedItemChanged:
      return base(.notRestored(.quarantinedItemChanged), .notRecorded, false)
    case .quarantinedItemUnsafe:
      return base(.notRestored(.quarantinedItemUnsafe), .notRecorded, false)
    case .traversalLimitExceeded:
      return base(.notRestored(.traversalLimitExceeded), .notRecorded, false)
    case .exclusiveRenameUnsupported:
      return base(.notRestored(.exclusiveRenameUnsupported), .notRecorded, false)
    case .renameRejected(let systemFailure):
      return base(.notRestored(.renameRejected(systemFailure)), .notRecorded, false)
    case .journal(.busy):
      return base(.notRestored(.quarantineJournalBusy), .notRecorded, false)
    case .journal(.unavailable(let systemFailure)):
      return base(
        .notRestored(.quarantineJournalUnavailable(systemFailure)),
        .notRecorded,
        false
      )
    case .journal(.unsafe):
      return base(
        .manualRecoveryRequired(
          quarantineLocation: nil,
          reason: .quarantineJournalUnsafe
        ),
        .unresolved(restoreTransactionID: nil),
        false
      )
    case .journal(.recoveryRequired(let transactionID)):
      return base(
        .manualRecoveryRequired(
          quarantineLocation: nil,
          reason: .quarantineJournalUnsafe
        ),
        .unresolved(restoreTransactionID: transactionID),
        false
      )
    }
  }

  private func validateFullCurrentTree(
    _ scope: DescriptorNPMQuarantineRestoreScope,
    session: DescriptorQuarantineRestoreJournalSession
  ) -> DescriptorRestoreValidation {
    switch validateParents(scope, session: session, mutationIsExpected: false) {
    case .valid:
      break
    case .cancelled:
      return .cancelled
    case .unsupported:
      return .unsupported
    case .changed:
      return .parentChanged
    case .unavailable:
      return .unavailable
    }
    let itemSnapshot: DescriptorStatSnapshot
    switch validateItem(
      scope,
      session: session,
      expectedMutationState: nil,
      cancellationPolicy: .observeTaskCancellation
    ) {
    case .valid(let value):
      itemSnapshot = value
    case .cancelled:
      return .cancelled
    case .missing:
      return .itemMissing
    case .changed:
      return .itemChanged
    case .unsafe:
      return .itemUnsafe
    case .unavailable:
      return .unavailable
    }
    guard let itemComponent = DescriptorPathComponent(session.intent.quarantineItemComponent) else {
      return .itemChanged
    }
    do {
      try dependencies.validateTree(
        scope.heldQuarantinedItemDescriptor,
        scope.heldQuarantineRootDescriptor,
        itemComponent,
        itemSnapshot,
        session.intent.npmRootBinding.device,
        scope.recoveryRequest.accountUID
      )
      return .valid(itemSnapshot)
    } catch is CancellationError {
      return .cancelled
    } catch DescriptorNPMQuarantinePreflightFailure.traversalLimitExceeded {
      return .traversalLimitExceeded
    } catch DescriptorNPMQuarantinePreflightFailure.candidateUnsafe,
      DescriptorNPMQuarantinePreflightFailure.layoutMismatch
    {
      return .itemUnsafe
    } catch DescriptorNPMQuarantinePreflightFailure.candidateMissing {
      return .itemMissing
    } catch DescriptorNPMQuarantinePreflightFailure.candidateChanged {
      return .itemChanged
    } catch {
      return .unavailable
    }
  }

  private func validateFullCurrentTreeBeforeIntent(
    _ scope: DescriptorNPMQuarantineRestoreScope,
    intent: QuarantineRestoreJournalIntentV1
  ) -> DescriptorRestoreValidation {
    guard let itemComponent = DescriptorPathComponent(intent.quarantineItemComponent) else {
      return .itemChanged
    }
    let itemSnapshot: DescriptorStatSnapshot
    do {
      guard !dependencies.cancellationIsRequested() else { return .cancelled }
      let held = try dependencies.readDescriptor(
        scope.heldQuarantinedItemDescriptor,
        .observeTaskCancellation
      )
      let named = try dependencies.readNamed(
        scope.heldQuarantineRootDescriptor,
        itemComponent,
        .observeTaskCancellation
      )
      guard
        restoreHistoricalBinding(held, matches: intent.candidateBinding),
        currentNamedSnapshot(named, matches: held)
      else {
        return .itemChanged
      }
      guard
        held.kind == .directory,
        held.identity.device == intent.npmRootBinding.device,
        held.ownerUID == scope.recoveryRequest.accountUID,
        held.permissionMode & mode_t(0o022) == 0,
        held.flags == 0,
        try !dependencies.hasExtendedACL(scope.heldQuarantinedItemDescriptor)
      else {
        return .itemUnsafe
      }
      itemSnapshot = held
    } catch is CancellationError {
      return .cancelled
    } catch let error where descriptorRestorePOSIXCode(error) == ENOENT {
      return .itemMissing
    } catch {
      return .unavailable
    }

    do {
      try dependencies.validateTree(
        scope.heldQuarantinedItemDescriptor,
        scope.heldQuarantineRootDescriptor,
        itemComponent,
        itemSnapshot,
        intent.npmRootBinding.device,
        scope.recoveryRequest.accountUID
      )
      return .valid(itemSnapshot)
    } catch is CancellationError {
      return .cancelled
    } catch DescriptorNPMQuarantinePreflightFailure.traversalLimitExceeded {
      return .traversalLimitExceeded
    } catch DescriptorNPMQuarantinePreflightFailure.candidateUnsafe,
      DescriptorNPMQuarantinePreflightFailure.layoutMismatch
    {
      return .itemUnsafe
    } catch DescriptorNPMQuarantinePreflightFailure.candidateMissing {
      return .itemMissing
    } catch DescriptorNPMQuarantinePreflightFailure.candidateChanged {
      return .itemChanged
    } catch {
      return .unavailable
    }
  }

  private func validateImmediatelyBeforeRename(
    _ scope: DescriptorNPMQuarantineRestoreScope,
    session: DescriptorQuarantineRestoreJournalSession,
    treeSnapshot: DescriptorStatSnapshot
  ) -> DescriptorRestoreValidation {
    guard !dependencies.cancellationIsRequested() else { return .cancelled }
    switch validateParents(scope, session: session, mutationIsExpected: false) {
    case .valid:
      break
    case .cancelled:
      return .cancelled
    case .unsupported:
      return .unsupported
    case .changed:
      return .parentChanged
    case .unavailable:
      return .unavailable
    }
    switch validateItem(
      scope,
      session: session,
      expectedMutationState: treeSnapshot,
      cancellationPolicy: .observeTaskCancellation
    ) {
    case .valid:
      break
    case .cancelled:
      return .cancelled
    case .missing:
      return .itemMissing
    case .changed:
      return .itemChanged
    case .unsafe:
      return .itemUnsafe
    case .unavailable:
      return .unavailable
    }

    // This no-follow lookup is intentionally the last filesystem operation in
    // the successful validation path.
    guard let sourceComponent = DescriptorPathComponent(Self.sourceNameBytes) else {
      return .unavailable
    }
    do {
      _ = try dependencies.readNamed(
        scope.heldRootDescriptor,
        sourceComponent,
        .observeTaskCancellation
      )
      return .sourceOccupied
    } catch is CancellationError {
      return .cancelled
    } catch let error where descriptorRestorePOSIXCode(error) == ENOENT {
      return .valid(treeSnapshot)
    } catch {
      return .unavailable
    }
  }

  private func validateParents(
    _ scope: DescriptorNPMQuarantineRestoreScope,
    session: DescriptorQuarantineRestoreJournalSession,
    mutationIsExpected: Bool,
    cancellationPolicy explicitCancellationPolicy: DescriptorCancellationPolicy? = nil
  ) -> DescriptorRestoreParentValidation {
    guard dependencies.currentAccountUID() == scope.recoveryRequest.accountUID else {
      return .changed
    }
    do {
      let policy: DescriptorCancellationPolicy =
        explicitCancellationPolicy
        ?? (mutationIsExpected ? .ignoreTaskCancellation : .observeTaskCancellation)
      let heldRoot = try dependencies.readDescriptor(scope.heldRootDescriptor, policy)
      let namedRoot = try dependencies.readAbsoluteRoot(
        scope.recoveryRequest.absoluteRootComponents,
        scope.recoveryRequest.homeComponentCount,
        policy
      )
      guard
        restoreParentSnapshot(
          heldRoot,
          matches: session.rootSnapshotAfterIntent,
          historicalBinding: session.intent.npmRootBinding,
          mutationIsExpected: mutationIsExpected,
          requiredMode: nil
        ),
        heldRoot.ownerUID == scope.recoveryRequest.accountUID,
        currentNamedSnapshot(namedRoot, matches: heldRoot),
        try !dependencies.hasExtendedACL(scope.heldRootDescriptor)
      else {
        return .changed
      }

      let heldQuarantineRoot = try dependencies.readDescriptor(
        scope.heldQuarantineRootDescriptor,
        policy
      )
      guard
        let quarantineRootComponent = DescriptorPathComponent(
          DescriptorExclusiveQuarantineMover.quarantineRootBytes
        )
      else {
        return .changed
      }
      let namedQuarantineRoot = try dependencies.readNamed(
        scope.heldRootDescriptor,
        quarantineRootComponent,
        policy
      )
      guard
        restoreParentSnapshot(
          heldQuarantineRoot,
          matches: session.quarantineRootSnapshotAfterIntent,
          historicalBinding: session.intent.quarantineRootBinding,
          mutationIsExpected: mutationIsExpected,
          requiredMode: mode_t(0o700)
        ),
        heldQuarantineRoot.ownerUID == scope.recoveryRequest.accountUID,
        heldQuarantineRoot.identity.device == heldRoot.identity.device,
        currentNamedSnapshot(namedQuarantineRoot, matches: heldQuarantineRoot),
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

  private func validateItem(
    _ scope: DescriptorNPMQuarantineRestoreScope,
    session: DescriptorQuarantineRestoreJournalSession,
    expectedMutationState: DescriptorStatSnapshot?,
    cancellationPolicy: DescriptorCancellationPolicy
  ) -> DescriptorRestoreItemValidation {
    guard let itemComponent = DescriptorPathComponent(session.intent.quarantineItemComponent) else {
      return .changed
    }
    do {
      let held = try dependencies.readDescriptor(
        scope.heldQuarantinedItemDescriptor,
        cancellationPolicy
      )
      let named = try dependencies.readNamed(
        scope.heldQuarantineRootDescriptor,
        itemComponent,
        cancellationPolicy
      )
      guard
        restoreHistoricalBinding(held, matches: session.intent.candidateBinding),
        currentNamedSnapshot(named, matches: held)
      else {
        return .changed
      }
      if let expectedMutationState {
        guard
          held.sameProtectedDescendantState(as: expectedMutationState),
          held.permissionMode == expectedMutationState.permissionMode,
          held.flags == expectedMutationState.flags
        else {
          return .changed
        }
      }
      guard
        held.kind == .directory,
        held.ownerUID == scope.recoveryRequest.accountUID,
        held.permissionMode & mode_t(0o022) == 0,
        held.flags == 0,
        try !dependencies.hasExtendedACL(scope.heldQuarantinedItemDescriptor)
      else {
        return .unsafe
      }
      return .valid(held)
    } catch is CancellationError {
      return .cancelled
    } catch let error where descriptorRestorePOSIXCode(error) == ENOENT {
      return .missing
    } catch {
      return .unavailable
    }
  }

  private func reconcile(
    _ scope: DescriptorNPMQuarantineRestoreScope,
    session: DescriptorQuarantineRestoreJournalSession,
    parentMutationIsExpected: Bool
  ) -> DescriptorRestoreNamespaceTruth {
    let parentsAreValid: Bool
    switch validateParents(
      scope,
      session: session,
      mutationIsExpected: parentMutationIsExpected,
      cancellationPolicy: .ignoreTaskCancellation
    ) {
    case .valid:
      parentsAreValid = true
    case .cancelled, .changed, .unsupported, .unavailable:
      parentsAreValid = false
    }

    let heldItemSnapshot: DescriptorStatSnapshot?
    do {
      let held = try dependencies.readDescriptor(
        scope.heldQuarantinedItemDescriptor,
        .ignoreTaskCancellation
      )
      let hasNoExtendedACL = try !dependencies.hasExtendedACL(
        scope.heldQuarantinedItemDescriptor
      )
      let heldItemIsExpected =
        restoreHistoricalBinding(held, matches: session.intent.candidateBinding)
        && held.kind == .directory
        && held.ownerUID == scope.recoveryRequest.accountUID
        && held.permissionMode & mode_t(0o022) == 0
        && held.flags == 0
        && hasNoExtendedACL
      heldItemSnapshot = heldItemIsExpected ? held : nil
    } catch {
      heldItemSnapshot = nil
    }

    let source = observeName(
      parentDescriptor: scope.heldRootDescriptor,
      componentBytes: Self.sourceNameBytes,
      expected: session.intent.candidateBinding,
      heldItemSnapshot: heldItemSnapshot
    )
    let quarantineItem = observeName(
      parentDescriptor: scope.heldQuarantineRootDescriptor,
      componentBytes: session.intent.quarantineItemComponent,
      expected: session.intent.candidateBinding,
      heldItemSnapshot: heldItemSnapshot
    )
    return DescriptorRestoreNamespaceTruth(
      parentsAreValid: parentsAreValid,
      heldItemIsExpected: heldItemSnapshot != nil,
      source: source,
      quarantineItem: quarantineItem,
      intent: session.intent
    )
  }

  private func observeName(
    parentDescriptor: Int32,
    componentBytes: [UInt8],
    expected: QuarantineJournalFileBindingV1,
    heldItemSnapshot: DescriptorStatSnapshot?
  ) -> DescriptorRestoreNamedTruth {
    guard let component = DescriptorPathComponent(componentBytes) else {
      return DescriptorRestoreNamedTruth(binding: .unavailable, observedIdentity: nil)
    }
    do {
      let snapshot = try dependencies.readNamed(
        parentDescriptor,
        component,
        .ignoreTaskCancellation
      )
      let isExpected =
        restoreHistoricalBinding(snapshot, matches: expected)
        && heldItemSnapshot.map { currentNamedSnapshot(snapshot, matches: $0) } == true
      return DescriptorRestoreNamedTruth(
        binding: isExpected ? .expected : .other,
        observedIdentity: snapshot.identity
      )
    } catch let error where descriptorRestorePOSIXCode(error) == ENOENT {
      return DescriptorRestoreNamedTruth(binding: .missing, observedIdentity: nil)
    } catch {
      return DescriptorRestoreNamedTruth(binding: .unavailable, observedIdentity: nil)
    }
  }

  private func mapFinish(
    _ result: DescriptorQuarantineRestoreJournalFinishResult,
    requestedOutcome: DescriptorQuarantineRestoreJournalTerminalOutcome,
    session: DescriptorQuarantineRestoreJournalSession,
    pendingReport: CleanupQuarantineRestoreReport
  ) -> CleanupQuarantineRestoreReport {
    switch result {
    case .receiptRecorded(let receipt)
    where receiptMatches(receipt, requestedOutcome: requestedOutcome, session: session):
      return pendingReport.replacing(
        durabilityState: .receiptRecorded(
          restoreTransactionID: receipt.restoreTransactionID,
          producedByRecovery: receipt.producedByRecovery
        ))
    case .receiptRecorded, .invalidSession:
      return pendingReport.replacing(
        status: durabilityFailureStatus(for: pendingReport.status),
        durabilityState: .unresolved(restoreTransactionID: session.restoreTransactionID)
      )
    case .recoveryRequired(let transactionID):
      guard transactionID == session.restoreTransactionID else {
        return pendingReport.replacing(
          status: durabilityFailureStatus(for: pendingReport.status),
          durabilityState: .unresolved(restoreTransactionID: nil)
        )
      }
      return pendingReport.replacing(
        status: requestedOutcome == .unresolved
          ? pendingReport.status
          : durabilityFailureStatus(for: pendingReport.status),
        durabilityState: .intentRecorded(restoreTransactionID: transactionID)
      )
    case .unresolved(let transactionID):
      let diagnosticTransactionID =
        transactionID == session.restoreTransactionID ? transactionID : nil
      return pendingReport.replacing(
        status: requestedOutcome == .unresolved
          ? pendingReport.status
          : durabilityFailureStatus(for: pendingReport.status),
        durabilityState: .unresolved(restoreTransactionID: diagnosticTransactionID)
      )
    }
  }

  private func receiptMatches(
    _ receipt: QuarantineRestoreJournalReceiptV1,
    requestedOutcome: DescriptorQuarantineRestoreJournalTerminalOutcome,
    session: DescriptorQuarantineRestoreJournalSession
  ) -> Bool {
    do {
      try QuarantineRestoreJournalV1Codec.validate(
        receipt,
        matching: session.intent,
        canonicalIntentBytes: session.canonicalIntentBytes
      )
    } catch {
      return false
    }
    guard !receipt.producedByRecovery else { return false }
    switch (requestedOutcome, receipt.outcome) {
    case (
      .notRestored(let expectedOccupied),
      .notRestored
    ):
      return receipt.sourceNameWasOccupied == expectedOccupied
        && !receipt.quarantineNameWasRecreated
    case (
      .restored(let expectedRecreated),
      .restored
    ):
      return receipt.quarantineNameWasRecreated == expectedRecreated
        && !receipt.sourceNameWasOccupied
    case (.unresolved, _), (.notRestored, .restored), (.restored, .notRestored):
      return false
    }
  }

  private func durabilityFailureStatus(
    for status: CleanupQuarantineRestoreStatus
  ) -> CleanupQuarantineRestoreStatus {
    let location: CleanupQuarantineLocation?
    switch status {
    case .manualRecoveryRequired(let value, _):
      location = value
    case .notRestored, .restored:
      location = nil
    }
    return .manualRecoveryRequired(
      quarantineLocation: location,
      reason: .durabilityRecordingFailed
    )
  }

  private func manualRecoveryStatus(
    for truth: DescriptorRestoreNamespaceTruth,
    fallback: CleanupQuarantineRestoreStatus
  ) -> CleanupQuarantineRestoreStatus {
    if !truth.parentsAreValid {
      return .manualRecoveryRequired(
        quarantineLocation: truth.quarantineLocation,
        reason: .parentBindingChanged
      )
    }
    if truth.source.binding == .unavailable {
      return .manualRecoveryRequired(
        quarantineLocation: truth.quarantineLocation,
        reason: .sourceCouldNotBeVerified
      )
    }
    if truth.quarantineItem.binding == .unavailable || !truth.heldItemIsExpected {
      return .manualRecoveryRequired(
        quarantineLocation: truth.quarantineLocation,
        reason: .quarantineItemCouldNotBeVerified
      )
    }
    if case .manualRecoveryRequired = fallback { return fallback }
    return .manualRecoveryRequired(
      quarantineLocation: truth.quarantineLocation,
      reason: .renameOutcomeIndeterminate
    )
  }

  private func quarantineLocation(
    intent: QuarantineRestoreJournalIntentV1,
    observedIdentity: FileIdentity?
  ) -> CleanupQuarantineLocation? {
    guard DescriptorPathComponent(intent.quarantineItemComponent) != nil else { return nil }
    return CleanupQuarantineLocation(
      relativePath: ScanRelativePath(
        rawComponents: [
          DescriptorExclusiveQuarantineMover.quarantineRootBytes,
          intent.quarantineItemComponent,
        ]),
      observedIdentity: observedIdentity
    )
  }
}

private enum DescriptorRestoreValidation {
  case valid(DescriptorStatSnapshot)
  case cancelled
  case sourceOccupied
  case parentChanged
  case itemMissing
  case itemChanged
  case itemUnsafe
  case traversalLimitExceeded
  case unsupported
  case unavailable
}

private enum DescriptorRestoreParentValidation {
  case valid
  case cancelled
  case changed
  case unsupported
  case unavailable
}

private enum DescriptorRestoreItemValidation {
  case valid(DescriptorStatSnapshot)
  case cancelled
  case missing
  case changed
  case unsafe
  case unavailable
}

private enum DescriptorRestoreNamedBinding: Equatable {
  case missing
  case expected
  case other
  case unavailable
}

private struct DescriptorRestoreNamedTruth {
  let binding: DescriptorRestoreNamedBinding
  let observedIdentity: FileIdentity?
}

private enum DescriptorRestoreTerminalTruth {
  case notRestored(sourceNameWasOccupied: Bool)
  case restored(quarantineNameWasRecreated: Bool)
  case unresolved
}

private struct DescriptorRestoreNamespaceTruth {
  let parentsAreValid: Bool
  let heldItemIsExpected: Bool
  let source: DescriptorRestoreNamedTruth
  let quarantineItem: DescriptorRestoreNamedTruth
  let intent: QuarantineRestoreJournalIntentV1

  var terminalOutcome: DescriptorRestoreTerminalTruth {
    guard parentsAreValid, heldItemIsExpected else { return .unresolved }
    switch (source.binding, quarantineItem.binding) {
    case (.missing, .expected):
      return .notRestored(sourceNameWasOccupied: false)
    case (.other, .expected):
      return .notRestored(sourceNameWasOccupied: true)
    case (.expected, .missing):
      return .restored(quarantineNameWasRecreated: false)
    case (.expected, .other):
      return .restored(quarantineNameWasRecreated: true)
    default:
      return .unresolved
    }
  }

  var quarantineLocation: CleanupQuarantineLocation? {
    guard DescriptorPathComponent(intent.quarantineItemComponent) != nil else { return nil }
    switch quarantineItem.binding {
    case .missing, .unavailable:
      return nil
    case .expected, .other:
      return CleanupQuarantineLocation(
        relativePath: ScanRelativePath(
          rawComponents: [
            DescriptorExclusiveQuarantineMover.quarantineRootBytes,
            intent.quarantineItemComponent,
          ]),
        observedIdentity: quarantineItem.observedIdentity
      )
    }
  }
}

private func restoreParentSnapshot(
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
    observed.flags == 0,
    observed.permissionMode & mode_t(0o022) == 0,
    restoreHistoricalBinding(observed, matches: historicalBinding)
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

private func currentNamedSnapshot(
  _ named: DescriptorStatSnapshot,
  matches held: DescriptorStatSnapshot
) -> Bool {
  named.sameProtectedDescendantState(as: held)
    && named.kind == held.kind
    && named.permissionMode == held.permissionMode
    && named.flags == held.flags
}

private func restoreHistoricalBinding(
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

private func descriptorRestoreCurrentAccountUID() -> uid_t? {
  let real = Darwin.getuid()
  guard real != 0, real == Darwin.geteuid() else { return nil }
  return real
}

private func descriptorRestoreSupportsResolveBeneathRename() -> Bool {
  ProcessInfo.processInfo.isOperatingSystemAtLeast(
    OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
  )
}

private func descriptorRestoreValidateTree(
  descriptor: Int32,
  parentDescriptor: Int32,
  component: DescriptorPathComponent,
  expected: DescriptorStatSnapshot,
  rootDevice: UInt64,
  accountUID: uid_t
) throws {
  _ = try DescriptorNPMCacheTreeValidator(
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

private func descriptorRestoreVolumeCapabilities(
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
    return .failure(descriptorRestoreFailure(for: errno))
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
    ))
}

private func descriptorRestoreRenameExclusive(
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

private func descriptorRestorePOSIXCode(_ error: Error) -> Int32? {
  if case DescriptorObservationError.posix(let code) = error { return code }
  let nsError = error as NSError
  guard nsError.domain == NSPOSIXErrorDomain else { return nil }
  return Int32(exactly: nsError.code)
}

private func descriptorRestoreFailure(
  for error: Error
) -> CleanupQuarantineSystemFailure {
  if let observation = error as? DescriptorObservationError {
    switch observation {
    case .bindingChanged, .crossedVolume:
      return .pathChanged
    case .markerEntryLimitExceeded, .protectedDescendantLimitExceeded:
      return .resourceLimit
    case .posix(let code):
      return descriptorRestoreFailure(for: code)
    }
  }
  if error is CancellationError { return .pathChanged }
  if let code = descriptorRestorePOSIXCode(error) {
    return descriptorRestoreFailure(for: code)
  }
  return .unspecified
}

private func descriptorRestoreFailure(
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
