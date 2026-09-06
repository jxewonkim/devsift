import Darwin
import Foundation

/// Privacy-bounded semantic handoff between the descriptor pipeline and the
/// report projection. Tests inject this layer without gaining a filesystem
/// mutation primitive.
enum CleanupQuarantinePurgeClaimExecutionOutcome: Equatable, Sendable {
  case noMutation(
    CleanupQuarantinePurgeNoMutationReason,
    durableIntentAlreadyExists: Bool,
    cancellationWasObserved: Bool
  )
  case observationalRecoveryRequired(
    CleanupQuarantinePurgeRecoveryReason,
    cancellationWasObserved: Bool
  )
  case terminalReceipt(
    outcome: CleanupQuarantinePurgeTerminalReceiptOutcome,
    producedByRecovery: Bool,
    capacityObservationProvenance: QuarantinePurgeCapacityObservationProvenanceV1,
    observedCapacityChange: QuarantinePurgeObservedCapacityChange,
    observedUnlinkCount: UInt64,
    cancellationWasObserved: Bool
  )
  case explicitRetryRequired(
    reason: CleanupQuarantinePurgeRetryReason,
    observedUnlinkCount: UInt64,
    cancellationWasObserved: Bool
  )
  case manualRecoveryRequired(
    CleanupQuarantinePurgeManualRecoveryReason,
    observedUnlinkCount: UInt64,
    cancellationWasObserved: Bool
  )
}

/// Internal transaction boundary for one exact, separately confirmed purge.
///
/// `execute` is the sole production entry point. Its first operation consumes
/// the process-local authority exactly once. No overload accepts a path,
/// managed component, transaction identifier, unlink request, or execution
/// claim from a caller.
struct CleanupQuarantinePurgeExecutor: Sendable {
  typealias ExecuteConsumedClaim =
    @Sendable (
      CleanupQuarantinePurgeExecutionClaim
    ) -> CleanupQuarantinePurgeClaimExecutionOutcome

  /// A synchronous handoff for an intent that was durably published but whose
  /// stager did not retain a journal session. The held preflight scope lets the
  /// recovery layer be connected without ever projecting its descriptors or
  /// identifiers into the report.
  typealias ResolveIntentRecorded =
    @Sendable (
      DescriptorNPMQuarantinePurgeStagingScope,
      DescriptorQuarantinePurgeFailure,
      Bool
    ) -> CleanupQuarantinePurgeClaimExecutionOutcome

  private let executeInitialClaim: ExecuteConsumedClaim
  private let executeRetryClaim: ExecuteConsumedClaim

  init(
    preflight: DescriptorNPMQuarantinePurgePreflight =
      DescriptorNPMQuarantinePurgePreflight(),
    stager: DescriptorExclusiveQuarantinePurgeStager =
      DescriptorExclusiveQuarantinePurgeStager(),
    retryJournal: DescriptorQuarantinePurgeRetryJournal =
      DescriptorQuarantinePurgeRetryJournal(),
    unlinkEngine: DescriptorNPMPurgeUnlinkEngine =
      DescriptorNPMPurgeUnlinkEngine(),
    terminalizer: DescriptorQuarantinePurgeTerminalizer =
      DescriptorQuarantinePurgeTerminalizer(),
    resolveIntentRecorded: @escaping ResolveIntentRecorded =
      cleanupQuarantinePurgeResolveRecordedIntentByRecovery
  ) {
    executeInitialClaim = { claim in
      Self.executeInitial(
        claim,
        preflight: preflight,
        stager: stager,
        unlinkEngine: unlinkEngine,
        terminalizer: terminalizer,
        resolveIntentRecorded: resolveIntentRecorded
      )
    }
    executeRetryClaim = { claim in
      Self.executeRetry(
        claim,
        preflight: preflight,
        retryJournal: retryJournal,
        unlinkEngine: unlinkEngine,
        terminalizer: terminalizer
      )
    }
  }

  /// Test-only composition seam. The closures receive a claim only after the
  /// same production authorization consumption boundary has succeeded.
  init(
    testingInitialClaim: @escaping ExecuteConsumedClaim,
    testingRetryClaim: @escaping ExecuteConsumedClaim
  ) {
    executeInitialClaim = testingInitialClaim
    executeRetryClaim = testingRetryClaim
  }

  func execute(
    _ authorization: CleanupQuarantinePurgeAuthorization
  ) async throws -> CleanupQuarantinePurgeReport {
    let claim = try await authorization.consumeForExecution()
    let outcome: CleanupQuarantinePurgeClaimExecutionOutcome
    switch claim.attemptKind {
    case .initial:
      outcome = executeInitialClaim(claim)
    case .explicitRetry:
      outcome = executeRetryClaim(claim)
    }
    return Self.makeReport(for: claim, outcome: outcome)
  }

  private static func executeInitial(
    _ claim: CleanupQuarantinePurgeExecutionClaim,
    preflight: DescriptorNPMQuarantinePurgePreflight,
    stager: DescriptorExclusiveQuarantinePurgeStager,
    unlinkEngine: DescriptorNPMPurgeUnlinkEngine,
    terminalizer: DescriptorQuarantinePurgeTerminalizer,
    resolveIntentRecorded: ResolveIntentRecorded
  ) -> CleanupQuarantinePurgeClaimExecutionOutcome {
    let result = preflight.withValidatedInitialClaim(claim) { scope in
      switch stager.stage(scope) {
      case .notStaged(let failure):
        return outcome(
          for: failure,
          durableIntentAlreadyExists: false
        )

      case .intentRecorded(
        let failure,
        purgeTransactionID: _, let stagingRenameWasInvoked
      ):
        return resolveIntentRecorded(
          scope,
          failure,
          stagingRenameWasInvoked
        )

      case .notStagedAfterIntent(let notStagedWork):
        return terminalizeNotStagedAttempt(
          notStagedWork.journalSession,
          cancellationWasObserved:
            notStagedWork.failure == .cancelled || Task.isCancelled,
          using: terminalizer
        )

      case .staged(let stagedWork):
        let cancellationWasObserved =
          stagedWork.cancellationWasObservedAfterRename || Task.isCancelled
        if cancellationWasObserved {
          return terminalizeStagedAttempt(
            stagedWork.journalSession,
            provenance: .initialAttempt,
            retryReason: .cancelled,
            observedUnlinkCount: 0,
            cancellationWasObserved: true,
            using: terminalizer
          )
        }

        guard
          let request = unlinkRequest(
            quarantineRootDescriptor: scope.heldQuarantineRootDescriptor,
            purgeWorkDescriptor: scope.heldQuarantinedItemDescriptor,
            session: stagedWork.journalSession,
            attemptKind: .initial
          )
        else {
          return terminalizeStagedAttempt(
            stagedWork.journalSession,
            provenance: .initialAttempt,
            retryReason: .treeUnsafe,
            observedUnlinkCount: 0,
            cancellationWasObserved: false,
            using: terminalizer
          )
        }
        let unlinkReport = unlinkEngine.execute(request)
        return terminalize(
          unlinkReport,
          session: stagedWork.journalSession,
          provenance: .initialAttempt,
          using: terminalizer
        )

      case .unresolved(purgeTransactionID: _):
        return .manualRecoveryRequired(
          .durabilityUnresolved,
          observedUnlinkCount: 0,
          cancellationWasObserved: Task.isCancelled
        )
      }
    }

    switch result {
    case .success(let outcome):
      return outcome
    case .failure(let failure):
      return .noMutation(
        noMutationReason(for: failure),
        durableIntentAlreadyExists: false,
        cancellationWasObserved: failure == .cancelled
      )
    }
  }

  private static func executeRetry(
    _ claim: CleanupQuarantinePurgeExecutionClaim,
    preflight: DescriptorNPMQuarantinePurgePreflight,
    retryJournal: DescriptorQuarantinePurgeRetryJournal,
    unlinkEngine: DescriptorNPMPurgeUnlinkEngine,
    terminalizer: DescriptorQuarantinePurgeTerminalizer
  ) -> CleanupQuarantinePurgeClaimExecutionOutcome {
    let result = preflight.withValidatedRetryClaim(claim) { scope in
      let retryResult = retryJournal.begin(
        DescriptorQuarantinePurgeRetryJournalRequest(
          recoveryRequest: scope.recoveryRequest,
          purgeWorkDescriptor: scope.heldPurgeWorkDescriptor,
          claim: scope.claim
        ))
      switch retryResult {
      case .failure(let failure):
        return outcome(
          for: failure,
          durableIntentAlreadyExists: true
        )

      case .success(let retrySession):
        if Task.isCancelled {
          return terminalizeStagedAttempt(
            retrySession.journalSession,
            provenance: .explicitRetry,
            retryReason: .cancelled,
            observedUnlinkCount: 0,
            cancellationWasObserved: true,
            using: terminalizer
          )
        }
        guard
          let request = unlinkRequest(
            quarantineRootDescriptor: scope.heldQuarantineRootDescriptor,
            purgeWorkDescriptor: scope.heldPurgeWorkDescriptor,
            session: retrySession.journalSession,
            attemptKind: .retry
          )
        else {
          return terminalizeStagedAttempt(
            retrySession.journalSession,
            provenance: .explicitRetry,
            retryReason: .treeUnsafe,
            observedUnlinkCount: 0,
            cancellationWasObserved: false,
            using: terminalizer
          )
        }
        let unlinkReport = unlinkEngine.execute(request)
        return terminalize(
          unlinkReport,
          session: retrySession.journalSession,
          provenance: .explicitRetry,
          using: terminalizer
        )
      }
    }

    switch result {
    case .success(let outcome):
      return outcome
    case .failure(let failure):
      if failure == .invalidClaim {
        return .manualRecoveryRequired(
          .invalidExecutionResult,
          observedUnlinkCount: 0,
          cancellationWasObserved: false
        )
      }
      return .noMutation(
        noMutationReason(for: failure),
        durableIntentAlreadyExists: true,
        cancellationWasObserved: failure == .cancelled
      )
    }
  }

  /// The unlink request is derived only after a lock-owning journal session is
  /// obtained. Descriptors come from the synchronous preflight scope and every
  /// other field comes from the canonical session intent.
  private static func unlinkRequest(
    quarantineRootDescriptor: Int32,
    purgeWorkDescriptor: Int32,
    session: DescriptorQuarantinePurgeJournalSession,
    attemptKind: DescriptorNPMPurgeUnlinkAttemptKind
  ) -> DescriptorNPMPurgeUnlinkRequest? {
    let expectedAuthorizationKind: CleanupQuarantinePurgeAttemptKind =
      attemptKind == .initial ? .initial : .explicitRetry
    let intent = session.intent
    guard session.attemptKind == expectedAuthorizationKind,
      intent.resourceBounds == .current,
      let purgeWorkComponent = DescriptorPathComponent(intent.purgeWorkComponent),
      let accountUID = uid_t(exactly: intent.candidateBinding.ownerUID),
      accountUID != 0,
      intent.candidateBinding.kind == .directory,
      intent.candidateBinding.device == intent.npmRootBinding.device,
      intent.purgeWorkComponent != Array("_cacache".utf8)
    else {
      return nil
    }
    return DescriptorNPMPurgeUnlinkRequest(
      quarantineRootDescriptor: quarantineRootDescriptor,
      purgeWorkDescriptor: purgeWorkDescriptor,
      purgeWorkComponent: purgeWorkComponent,
      historicalCandidateBinding: intent.candidateBinding,
      accountUID: accountUID,
      rootDevice: intent.npmRootBinding.device,
      attemptKind: attemptKind,
      resourceBounds: intent.resourceBounds
    )
  }

  private static func terminalize(
    _ unlinkReport: DescriptorNPMPurgeUnlinkReport,
    session: DescriptorQuarantinePurgeJournalSession,
    provenance: QuarantinePurgeCapacityObservationProvenanceV1,
    using terminalizer: DescriptorQuarantinePurgeTerminalizer
  ) -> CleanupQuarantinePurgeClaimExecutionOutcome {
    let fallbackRetryReason: CleanupQuarantinePurgeRetryReason
    switch unlinkReport.status {
    case .itemAbsent:
      fallbackRetryReason = .namespaceChanged
    case .synchronizedPartial(let reason), .durabilityUnresolved(let reason):
      fallbackRetryReason = retryReason(for: reason)
    }
    return terminalizeStagedAttempt(
      session,
      provenance: provenance,
      retryReason: fallbackRetryReason,
      observedUnlinkCount: unlinkReport.observedAbsentNameCount,
      cancellationWasObserved: unlinkReport.cancellationWasRequested,
      using: terminalizer
    )
  }

  /// Terminalization is attempted after every staged result, including a late
  /// cancellation, synchronized partial result, and durability-unresolved
  /// engine result. Namespace truth can have changed after the engine returned;
  /// only the terminalizer may publish the receipt or declare a safe remainder.
  private static func terminalizeStagedAttempt(
    _ session: DescriptorQuarantinePurgeJournalSession,
    provenance: QuarantinePurgeCapacityObservationProvenanceV1,
    retryReason: CleanupQuarantinePurgeRetryReason,
    observedUnlinkCount: UInt64,
    cancellationWasObserved: Bool,
    using terminalizer: DescriptorQuarantinePurgeTerminalizer
  ) -> CleanupQuarantinePurgeClaimExecutionOutcome {
    terminalizeAttempt(
      session,
      requestedOutcome: .itemAbsent,
      provenance: provenance,
      retryReason: retryReason,
      observedUnlinkCount: observedUnlinkCount,
      cancellationWasObserved: cancellationWasObserved,
      using: terminalizer
    )
  }

  /// Ready for the stager's session-bearing conclusive-not-staged handoff.
  /// That handoff must request `notPurged`; it must never run the unlink engine.
  private static func terminalizeNotStagedAttempt(
    _ session: DescriptorQuarantinePurgeJournalSession,
    cancellationWasObserved: Bool,
    using terminalizer: DescriptorQuarantinePurgeTerminalizer
  ) -> CleanupQuarantinePurgeClaimExecutionOutcome {
    terminalizeAttempt(
      session,
      requestedOutcome: .notPurged,
      provenance: .initialAttempt,
      retryReason: .namespaceChanged,
      observedUnlinkCount: 0,
      cancellationWasObserved: cancellationWasObserved,
      using: terminalizer
    )
  }

  private static func terminalizeAttempt(
    _ session: DescriptorQuarantinePurgeJournalSession,
    requestedOutcome: DescriptorQuarantinePurgeTerminalOutcome,
    provenance: QuarantinePurgeCapacityObservationProvenanceV1,
    retryReason: CleanupQuarantinePurgeRetryReason,
    observedUnlinkCount: UInt64,
    cancellationWasObserved: Bool,
    using terminalizer: DescriptorQuarantinePurgeTerminalizer
  ) -> CleanupQuarantinePurgeClaimExecutionOutcome {
    let result = terminalizer.terminalize(
      DescriptorQuarantinePurgeTerminalizationRequest(
        journalSession: session,
        outcome: requestedOutcome,
        capacityObservationProvenance: provenance
      ))
    switch result {
    case .receiptRecorded(let receipt, observedCapacityChange: let capacityChange):
      let expectedReceiptOutcome: QuarantinePurgeJournalReceiptOutcomeV1 =
        requestedOutcome == .itemAbsent ? .itemAbsent : .notPurged
      let boundedReceiptOutcome: CleanupQuarantinePurgeTerminalReceiptOutcome =
        requestedOutcome == .itemAbsent ? .itemAbsent : .notPurged
      guard
        receipt.outcome == expectedReceiptOutcome,
        receipt.purgeTransactionID == session.purgeTransactionID,
        receipt.capacityObservationProvenance == provenance,
        !receipt.producedByRecovery,
        (try? QuarantinePurgeJournalV1Codec.encode(
          receipt,
          matchingIntentBytes: session.canonicalIntentBytes
        )) != nil,
        DescriptorQuarantinePurgeCapacityObserver.compare(
          observationBefore: session.intent.capacityBefore,
          observationAfter: receipt.capacityAfter
        ) == capacityChange
      else {
        return .manualRecoveryRequired(
          .invalidTerminalReceipt,
          observedUnlinkCount: observedUnlinkCount,
          cancellationWasObserved: cancellationWasObserved
        )
      }
      return .terminalReceipt(
        outcome: boundedReceiptOutcome,
        producedByRecovery: false,
        capacityObservationProvenance: provenance,
        observedCapacityChange: capacityChange,
        observedUnlinkCount: observedUnlinkCount,
        cancellationWasObserved: cancellationWasObserved
      )

    case .retryRequired:
      return .explicitRetryRequired(
        reason: retryReason,
        observedUnlinkCount: observedUnlinkCount,
        cancellationWasObserved: cancellationWasObserved
      )

    case .manualRecoveryRequired(let reason):
      return .manualRecoveryRequired(
        manualRecoveryReason(for: reason),
        observedUnlinkCount: observedUnlinkCount,
        cancellationWasObserved: cancellationWasObserved
      )

    case .invalidSession:
      return .manualRecoveryRequired(
        .invalidTerminalizationSession,
        observedUnlinkCount: observedUnlinkCount,
        cancellationWasObserved: cancellationWasObserved
      )
    }
  }

  private static func makeReport(
    for claim: CleanupQuarantinePurgeExecutionClaim,
    outcome: CleanupQuarantinePurgeClaimExecutionOutcome
  ) -> CleanupQuarantinePurgeReport {
    let maximumObservedUnlinkCount: UInt64
    let bounds = purgeIntent(for: claim).resourceBounds
    let (derivedMaximum, overflow) = bounds.maximumEntries.addingReportingOverflow(1)
    if overflow {
      maximumObservedUnlinkCount = 0
    } else {
      maximumObservedUnlinkCount = derivedMaximum
    }

    func invalidResult(
      cancellationWasObserved: Bool = false
    ) -> CleanupQuarantinePurgeReport {
      CleanupQuarantinePurgeReport(
        attemptKind: claim.attemptKind,
        status: .manualRecoveryRequired(.invalidExecutionResult),
        durabilityState: .unresolved,
        observedUnlinkCount: 0,
        cancellationWasObserved: cancellationWasObserved
      )
    }

    switch outcome {
    case .noMutation(
      let reason, let durableIntentAlreadyExists, let cancellationWasObserved
    ):
      guard durableIntentAlreadyExists == (claim.attemptKind == .explicitRetry) else {
        return invalidResult(cancellationWasObserved: cancellationWasObserved)
      }
      return CleanupQuarantinePurgeReport(
        attemptKind: claim.attemptKind,
        status: .noMutation(reason),
        durabilityState: durableIntentAlreadyExists ? .intentRecorded : .notRecorded,
        cancellationWasObserved: cancellationWasObserved
      )

    case .observationalRecoveryRequired(
      let reason, let cancellationWasObserved
    ):
      return CleanupQuarantinePurgeReport(
        attemptKind: claim.attemptKind,
        status: .observationalRecoveryRequired(reason),
        durabilityState: .intentRecorded,
        cancellationWasObserved: cancellationWasObserved
      )

    case .terminalReceipt(
      outcome: let receiptOutcome, let producedByRecovery,
      capacityObservationProvenance: let provenance,
      observedCapacityChange: let capacityChange, let observedUnlinkCount,
      let cancellationWasObserved
    ):
      guard observedUnlinkCount <= maximumObservedUnlinkCount,
        !(receiptOutcome == .notPurged && observedUnlinkCount != 0),
        !(receiptOutcome == .notPurged && claim.attemptKind != .initial),
        (producedByRecovery && provenance == .recovery)
          || (!producedByRecovery && provenance == expectedProvenance(for: claim.attemptKind))
      else {
        return invalidResult(cancellationWasObserved: cancellationWasObserved)
      }
      let status: CleanupQuarantinePurgeStatus =
        receiptOutcome == .itemAbsent ? .itemAbsent : .notPurged
      return CleanupQuarantinePurgeReport(
        attemptKind: claim.attemptKind,
        status: status,
        durabilityState: .terminalReceiptRecorded(
          outcome: receiptOutcome,
          producedByRecovery: producedByRecovery
        ),
        capacityObservationProvenance: provenance,
        observedCapacityChange: capacityChange,
        observedUnlinkCount: observedUnlinkCount,
        cancellationWasObserved: cancellationWasObserved
      )

    case .explicitRetryRequired(
      let reason, let observedUnlinkCount, let cancellationWasObserved
    ):
      guard observedUnlinkCount <= maximumObservedUnlinkCount else {
        return invalidResult(cancellationWasObserved: cancellationWasObserved)
      }
      let progress: CleanupQuarantinePurgeProgress =
        observedUnlinkCount == 0 ? .stagedWithNoUnlinkObserved : .unlinkProgressObserved
      return CleanupQuarantinePurgeReport(
        attemptKind: claim.attemptKind,
        status: .explicitRetryRequired(progress: progress, reason: reason),
        durabilityState: .intentRecorded,
        observedUnlinkCount: observedUnlinkCount,
        cancellationWasObserved: cancellationWasObserved
      )

    case .manualRecoveryRequired(
      let reason, let observedUnlinkCount, let cancellationWasObserved
    ):
      guard observedUnlinkCount <= maximumObservedUnlinkCount else {
        return invalidResult(cancellationWasObserved: cancellationWasObserved)
      }
      return CleanupQuarantinePurgeReport(
        attemptKind: claim.attemptKind,
        status: .manualRecoveryRequired(reason),
        durabilityState: .unresolved,
        observedUnlinkCount: observedUnlinkCount,
        cancellationWasObserved: cancellationWasObserved
      )
    }
  }

  private static func purgeIntent(
    for claim: CleanupQuarantinePurgeExecutionClaim
  ) -> QuarantinePurgeJournalIntentV1 {
    switch claim.evidence {
    case .initial(let evidence):
      evidence.purgeIntent
    case .explicitRetry(let evidence):
      evidence.purgeIntent
    }
  }

  private static func expectedProvenance(
    for attemptKind: CleanupQuarantinePurgeAttemptKind
  ) -> QuarantinePurgeCapacityObservationProvenanceV1 {
    switch attemptKind {
    case .initial:
      .initialAttempt
    case .explicitRetry:
      .explicitRetry
    }
  }

  private static func outcome(
    for failure: DescriptorQuarantinePurgeFailure,
    durableIntentAlreadyExists: Bool
  ) -> CleanupQuarantinePurgeClaimExecutionOutcome {
    switch failure {
    case .journal(.unsafe):
      return .manualRecoveryRequired(
        .journalUnsafe,
        observedUnlinkCount: 0,
        cancellationWasObserved: false
      )
    case .journal(.recoveryRequired(transactionID: _)):
      if durableIntentAlreadyExists {
        return .observationalRecoveryRequired(
          .journalRequiresReconciliation,
          cancellationWasObserved: false
        )
      }
      return .noMutation(
        .journalRecordUnsafe,
        durableIntentAlreadyExists: false,
        cancellationWasObserved: false
      )
    default:
      return .noMutation(
        noMutationReason(for: failure),
        durableIntentAlreadyExists: durableIntentAlreadyExists,
        cancellationWasObserved: failure == .cancelled
      )
    }
  }

  private static func noMutationReason(
    for failure: DescriptorNPMQuarantinePurgePreflightFailure
  ) -> CleanupQuarantinePurgeNoMutationReason {
    switch failure {
    case .cancelled:
      .cancelled
    case .unsupportedPlatform:
      .unsupportedPlatform
    case .invalidCurrentAccount:
      .invalidCurrentAccount
    case .invalidHome:
      .trustedRootUnavailable(.invalidMetadata)
    case .homeUnavailable(let systemFailure),
      .rootUnavailable(let systemFailure),
      .quarantineRootUnavailable(let systemFailure):
      .trustedRootUnavailable(systemFailure)
    case .homeUnsafe, .rootUnsafe, .quarantineRootUnsafe:
      .trustedRootChanged
    case .journalRecordMissing:
      .journalRecordMissing
    case .journalRecordChanged:
      .journalRecordChanged
    case .journalRecordUnsafe:
      .journalRecordUnsafe
    case .quarantinedItemMissing:
      .quarantinedItemMissing
    case .quarantinedItemChanged:
      .quarantinedItemChanged
    case .quarantinedItemUnsafe:
      .quarantinedItemUnsafe
    case .purgeWorkMissing:
      .purgeWorkMissing
    case .purgeWorkChanged:
      .purgeWorkChanged
    case .purgeWorkUnsafe:
      .purgeWorkUnsafe
    case .purgeWorkNameOccupied:
      .purgeWorkNameOccupied
    case .traversalLimitExceeded:
      .traversalLimitExceeded
    case .capacityObservation:
      .capacityObservationUnavailable
    case .purgeIdentifierUnavailable, .purgeIdentifierCollisionLimitExceeded:
      .purgeIdentifierUnavailable
    case .invalidSelection, .invalidClaim, .authorization:
      .invalidClaim
    }
  }

  private static func noMutationReason(
    for failure: DescriptorQuarantinePurgeFailure
  ) -> CleanupQuarantinePurgeNoMutationReason {
    switch failure {
    case .cancelled:
      .cancelled
    case .invalidClaim:
      .invalidClaim
    case .transactionNotFound:
      .originalTransactionUnavailable
    case .transactionNotPurgeable:
      .originalTransactionNotPurgeable
    case .alreadyPurged:
      .alreadyPurged
    case .quarantinedItemMissing:
      .quarantinedItemMissing
    case .quarantinedItemChanged:
      .quarantinedItemChanged
    case .quarantinedItemUnsafe:
      .quarantinedItemUnsafe
    case .workNameOccupied:
      .purgeWorkNameOccupied
    case .traversalLimitExceeded:
      .traversalLimitExceeded
    case .exclusiveRenameUnsupported:
      .exclusiveRenameUnsupported
    case .renameRejected(let systemFailure):
      .renameRejected(systemFailure)
    case .journal(.busy):
      .quarantineJournalBusy
    case .journal(.unavailable(let systemFailure)):
      .quarantineJournalUnavailable(systemFailure)
    case .journal(.unsafe), .journal(.recoveryRequired(transactionID: _)):
      .journalRecordUnsafe
    }
  }

  private static func retryReason(
    for reason: DescriptorNPMPurgeUnlinkStopReason
  ) -> CleanupQuarantinePurgeRetryReason {
    switch reason {
    case .cancelled:
      .cancelled
    case .treeChanged, .invalidRequest, .preflightValidationFailed(.rootBindingMismatch),
      .preflightValidationFailed(.treeChanged):
      .treeChanged
    case .treeUnsafe, .preflightValidationFailed(.treeUnsafe),
      .preflightValidationFailed(.layoutMismatch):
      .treeUnsafe
    case .traversalLimitExceeded, .preflightValidationFailed(.invalidLimits),
      .preflightValidationFailed(.traversalLimitExceeded):
      .traversalLimitExceeded
    case .synchronizationLimitExceeded:
      .synchronizationLimitExceeded
    case .observationUnavailable(let systemFailure):
      .observationUnavailable(systemFailure)
    case .unlinkFailed(let systemFailure):
      .unlinkRejected(systemFailure)
    case .synchronizationFailed(let systemFailure):
      .synchronizationFailed(systemFailure)
    }
  }

  private static func manualRecoveryReason(
    for reason: DescriptorQuarantinePurgeManualRecoveryReason
  ) -> CleanupQuarantinePurgeManualRecoveryReason {
    switch reason {
    case .invalidRequest:
      .invalidExecutionResult
    case .journalUnsafe:
      .journalUnsafe
    case .recordsChanged:
      .recordsChanged
    case .parentBindingChanged:
      .parentBindingChanged
    case .namespaceAmbiguous:
      .namespaceAmbiguous
    case .workTreeChanged:
      .workTreeChanged
    case .workTreeUnsafe:
      .workTreeUnsafe
    case .traversalLimitExceeded:
      .traversalLimitExceeded
    case .durabilityUnresolved:
      .durabilityUnresolved
    }
  }
}

private func cleanupQuarantinePurgeResolveRecordedIntentByRecovery(
  _ scope: DescriptorNPMQuarantinePurgeStagingScope,
  _ failure: DescriptorQuarantinePurgeFailure,
  _ stagingRenameWasInvoked: Bool
) -> CleanupQuarantinePurgeClaimExecutionOutcome {
  _ = scope
  let reason: CleanupQuarantinePurgeRecoveryReason
  if case .journal(.recoveryRequired(transactionID: _)) = failure {
    reason = .journalRequiresReconciliation
  } else if stagingRenameWasInvoked {
    reason = .stagingMayHaveBeenInvoked
  } else {
    reason = .stagingNotCommitted
  }
  return .observationalRecoveryRequired(
    reason,
    cancellationWasObserved: failure == .cancelled
  )
}
