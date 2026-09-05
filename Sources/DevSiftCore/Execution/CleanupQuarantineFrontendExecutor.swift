/// The package-scoped execution boundary used by DevSift's frontends.
///
/// The only input is a Core-issued, single-use authorization. The concrete
/// implementation keeps the descriptor-based executor and its detailed report
/// private to DevSiftCore, and returns only bounded presentation data.
package protocol CleanupQuarantineFrontendExecuting: Sendable {
  func execute(
    _ authorization: CleanupQuarantineAuthorization
  ) async -> CleanupQuarantineFrontendExecutionResult
}

package struct CleanupQuarantineFrontendExecutionResult: Equatable, Sendable {
  package static let currentContractVersion: UInt32 = 1

  package let contractVersion: UInt32
  package let outcome: CleanupQuarantineFrontendOutcome
  package let durabilityEvidence: CleanupQuarantineFrontendDurabilityEvidence
  package let namespaceMutation: CleanupQuarantineFrontendNamespaceMutation
  package let cancellationWasObservedAfterRename: Bool

  package var isDurablyQuarantined: Bool {
    guard case .durablyQuarantined = outcome else {
      return false
    }
    return true
  }

  /// Quarantine is a same-volume namespace move, never permanent deletion.
  package var performedPermanentDeletion: Bool { false }

  /// Moving an item into quarantine does not guarantee any freed disk space.
  package var guaranteedFreedBytes: UInt64 { 0 }

  package init(
    contractVersion: UInt32 = Self.currentContractVersion,
    outcome: CleanupQuarantineFrontendOutcome,
    durabilityEvidence: CleanupQuarantineFrontendDurabilityEvidence,
    namespaceMutation: CleanupQuarantineFrontendNamespaceMutation,
    cancellationWasObservedAfterRename: Bool
  ) {
    self.contractVersion = contractVersion
    self.outcome = outcome
    self.durabilityEvidence = durabilityEvidence
    self.namespaceMutation = namespaceMutation
    self.cancellationWasObservedAfterRename = cancellationWasObservedAfterRename
  }

  fileprivate static func notStarted(
    _ reason: CleanupQuarantineFrontendNotStartedReason
  ) -> CleanupQuarantineFrontendExecutionResult {
    CleanupQuarantineFrontendExecutionResult(
      outcome: .notStarted(reason),
      durabilityEvidence: .notRecorded,
      namespaceMutation: .none,
      cancellationWasObservedAfterRename: false
    )
  }
}

package enum CleanupQuarantineFrontendOutcome: Equatable, Sendable {
  case notStarted(CleanupQuarantineFrontendNotStartedReason)
  case durablyQuarantined(sourceNameWasRecreated: Bool)
  case quarantinedWithoutTerminalReceipt(sourceNameWasRecreated: Bool)
  case notMoved(CleanupQuarantineFrontendNotMovedReason)
  case rolledBack(CleanupQuarantineFrontendRollbackReason)
  case manualRecoveryRequired(
    locationWasObserved: Bool,
    reason: CleanupQuarantineFrontendManualRecoveryReason
  )
}

package enum CleanupQuarantineFrontendNotStartedReason: Equatable, Sendable {
  case cancelled
  case invalidAuthorization
  case authorizationAlreadyConsumed
  case authorizationCancelled
  case executionBoundaryFailed
}

package enum CleanupQuarantineFrontendDurabilityEvidence: Equatable, Sendable {
  case notRecorded
  case intentRecorded(transactionID: String)
  case terminalReceiptRecorded(transactionID: String, producedByRecovery: Bool)
  case unresolved(transactionID: String?)

  package var transactionID: String? {
    switch self {
    case .notRecorded:
      nil
    case .intentRecorded(let transactionID),
      .terminalReceiptRecorded(let transactionID, _):
      transactionID
    case .unresolved(let transactionID):
      transactionID
    }
  }
}

package enum CleanupQuarantineFrontendNamespaceMutation: Equatable, Sendable {
  case none
  case quarantineRootCreated
  case indeterminate
}

package enum CleanupQuarantineFrontendSystemFailure: Equatable, Sendable {
  case permissionDenied
  case pathChanged
  case unsupported
  case crossDevice
  case readOnlyFileSystem
  case noSpace
  case resourceLimit
  case invalidMetadata
  case inputOutput
  case destinationExists
  case unspecified
}

package enum CleanupQuarantineFrontendNotMovedReason: Equatable, Sendable {
  case cancelled
  case invalidClaim
  case unsupportedPolicy
  case invalidCurrentAccount
  case trustedRootUnavailable(CleanupQuarantineFrontendSystemFailure)
  case trustedRootChanged
  case candidateMissing
  case candidateChanged
  case candidateUnsafe
  case traversalLimitExceeded
  case ageRequirementNotSatisfied
  case quarantineRootUnavailable(CleanupQuarantineFrontendSystemFailure)
  case quarantineRootUnsafe
  case exclusiveRenameUnsupported
  case invalidDestinationName
  case destinationCollisionLimitExceeded
  case quarantineJournalBusy
  case quarantineJournalUnavailable(CleanupQuarantineFrontendSystemFailure)
  case preRenameValidationUnavailable(CleanupQuarantineFrontendSystemFailure)
  case renameRejected(CleanupQuarantineFrontendSystemFailure)
}

package enum CleanupQuarantineFrontendRollbackReason: Equatable, Sendable {
  case movedObjectDidNotMatchApproval
  case postMoveValidationUnavailable
}

package enum CleanupQuarantineFrontendManualRecoveryReason: Equatable, Sendable {
  case quarantineJournalUnsafe
  case durabilityRecordingFailed
  case renameOutcomeIndeterminate
  case destinationCouldNotBeVerified
  case parentBindingChanged
  case sourceNameOccupied
  case sourceCouldNotBeVerified
  case restoredObjectDidNotMatchApproval
  case rollbackFailed
  case rollbackOutcomeIndeterminate
}

package struct CleanupQuarantineFrontendExecutor: CleanupQuarantineFrontendExecuting, Sendable {
  private let executor: CleanupQuarantineExecutor

  package init() {
    executor = CleanupQuarantineExecutor()
  }

  init(executor: CleanupQuarantineExecutor) {
    self.executor = executor
  }

  package func execute(
    _ authorization: CleanupQuarantineAuthorization
  ) async -> CleanupQuarantineFrontendExecutionResult {
    do {
      return Self.project(try await executor.execute(authorization))
    } catch is CancellationError {
      return .notStarted(.cancelled)
    } catch let error as CleanupQuarantineAuthorizationConsumptionError {
      return .notStarted(Self.project(error))
    } catch {
      return .notStarted(.executionBoundaryFailed)
    }
  }

  static func project(
    _ report: CleanupQuarantineExecutionReport
  ) -> CleanupQuarantineFrontendExecutionResult {
    let durabilityEvidence = project(report.durabilityState)
    let outcome: CleanupQuarantineFrontendOutcome

    switch report.status {
    case .notMoved(let reason):
      outcome = .notMoved(project(reason))
    case .quarantined(_, let sourceNameWasRecreated):
      if case .terminalReceiptRecorded = durabilityEvidence {
        outcome = .durablyQuarantined(sourceNameWasRecreated: sourceNameWasRecreated)
      } else {
        outcome = .quarantinedWithoutTerminalReceipt(
          sourceNameWasRecreated: sourceNameWasRecreated
        )
      }
    case .rolledBack(let reason):
      outcome = .rolledBack(project(reason))
    case .manualRecoveryRequired(let location, let reason):
      outcome = .manualRecoveryRequired(
        locationWasObserved: location != nil,
        reason: project(reason)
      )
    }

    return CleanupQuarantineFrontendExecutionResult(
      outcome: outcome,
      durabilityEvidence: durabilityEvidence,
      namespaceMutation: project(report.quarantineRootMutation),
      cancellationWasObservedAfterRename: report.cancellationWasObservedAfterRename
    )
  }

  static func project(
    _ error: CleanupQuarantineAuthorizationConsumptionError
  ) -> CleanupQuarantineFrontendNotStartedReason {
    switch error {
    case .unsupportedContractVersion, .authorizationDoesNotBelongToAttempt:
      .invalidAuthorization
    case .authorizationAlreadyConsumed:
      .authorizationAlreadyConsumed
    case .authorizationCancelled:
      .authorizationCancelled
    }
  }

  private static func project(
    _ durabilityState: CleanupQuarantineDurabilityState
  ) -> CleanupQuarantineFrontendDurabilityEvidence {
    switch durabilityState {
    case .notRecorded:
      .notRecorded
    case .intentRecorded(let transactionID):
      .intentRecorded(transactionID: transactionID)
    case .receiptRecorded(let transactionID, let producedByRecovery):
      .terminalReceiptRecorded(
        transactionID: transactionID,
        producedByRecovery: producedByRecovery
      )
    case .unresolved(let transactionID):
      .unresolved(transactionID: transactionID)
    }
  }

  private static func project(
    _ mutation: CleanupQuarantineRootMutation
  ) -> CleanupQuarantineFrontendNamespaceMutation {
    switch mutation {
    case .none:
      .none
    case .created:
      .quarantineRootCreated
    case .indeterminate:
      .indeterminate
    }
  }

  private static func project(
    _ reason: CleanupQuarantineNotMovedReason
  ) -> CleanupQuarantineFrontendNotMovedReason {
    switch reason {
    case .cancelled:
      .cancelled
    case .invalidClaim:
      .invalidClaim
    case .unsupportedPolicy:
      .unsupportedPolicy
    case .invalidCurrentAccount:
      .invalidCurrentAccount
    case .trustedRootUnavailable(let failure):
      .trustedRootUnavailable(project(failure))
    case .trustedRootChanged:
      .trustedRootChanged
    case .candidateMissing:
      .candidateMissing
    case .candidateChanged:
      .candidateChanged
    case .candidateUnsafe:
      .candidateUnsafe
    case .traversalLimitExceeded:
      .traversalLimitExceeded
    case .ageRequirementNotSatisfied:
      .ageRequirementNotSatisfied
    case .quarantineRootUnavailable(let failure):
      .quarantineRootUnavailable(project(failure))
    case .quarantineRootUnsafe:
      .quarantineRootUnsafe
    case .exclusiveRenameUnsupported:
      .exclusiveRenameUnsupported
    case .invalidDestinationName:
      .invalidDestinationName
    case .destinationCollisionLimitExceeded:
      .destinationCollisionLimitExceeded
    case .quarantineJournalBusy:
      .quarantineJournalBusy
    case .quarantineJournalUnavailable(let failure):
      .quarantineJournalUnavailable(project(failure))
    case .preRenameValidationUnavailable(let failure):
      .preRenameValidationUnavailable(project(failure))
    case .renameRejected(let failure):
      .renameRejected(project(failure))
    }
  }

  private static func project(
    _ reason: CleanupQuarantineRollbackReason
  ) -> CleanupQuarantineFrontendRollbackReason {
    switch reason {
    case .movedObjectDidNotMatchApproval:
      .movedObjectDidNotMatchApproval
    case .postMoveValidationUnavailable:
      .postMoveValidationUnavailable
    }
  }

  private static func project(
    _ reason: CleanupQuarantineManualRecoveryReason
  ) -> CleanupQuarantineFrontendManualRecoveryReason {
    switch reason {
    case .quarantineJournalUnsafe:
      .quarantineJournalUnsafe
    case .durabilityRecordingFailed:
      .durabilityRecordingFailed
    case .renameOutcomeIndeterminate:
      .renameOutcomeIndeterminate
    case .destinationCouldNotBeVerified:
      .destinationCouldNotBeVerified
    case .parentBindingChanged:
      .parentBindingChanged
    case .sourceNameOccupied:
      .sourceNameOccupied
    case .sourceCouldNotBeVerified:
      .sourceCouldNotBeVerified
    case .restoredObjectDidNotMatchApproval:
      .restoredObjectDidNotMatchApproval
    case .rollbackFailed:
      .rollbackFailed
    case .rollbackOutcomeIndeterminate:
      .rollbackOutcomeIndeterminate
    }
  }

  private static func project(
    _ failure: CleanupQuarantineSystemFailure
  ) -> CleanupQuarantineFrontendSystemFailure {
    switch failure {
    case .permissionDenied:
      .permissionDenied
    case .pathChanged:
      .pathChanged
    case .unsupported:
      .unsupported
    case .crossDevice:
      .crossDevice
    case .readOnlyFileSystem:
      .readOnlyFileSystem
    case .noSpace:
      .noSpace
    case .resourceLimit:
      .resourceLimit
    case .invalidMetadata:
      .invalidMetadata
    case .inputOutput:
      .inputOutput
    case .destinationExists:
      .destinationExists
    case .unspecified:
      .unspecified
    }
  }
}
