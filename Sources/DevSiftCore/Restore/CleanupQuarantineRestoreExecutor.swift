import Foundation

/// Internal transaction boundary for one explicitly confirmed manual restore.
///
/// Authorization consumption is the only throwing step. After the claim is
/// consumed, every preflight, journal, and rename outcome is reduced to a
/// bounded non-Codable report.
struct CleanupQuarantineRestoreExecutor: Sendable {
  typealias ExecuteClaim =
    @Sendable (CleanupQuarantineRestoreExecutionClaim) -> Result<
      CleanupQuarantineRestoreReport,
      DescriptorNPMQuarantineRestorePreflightFailure
    >

  private let executeClaim: ExecuteClaim

  init(
    preflight: DescriptorNPMQuarantineRestorePreflight =
      DescriptorNPMQuarantineRestorePreflight(),
    restorer: DescriptorExclusiveQuarantineRestorer =
      DescriptorExclusiveQuarantineRestorer()
  ) {
    executeClaim = { claim in
      preflight.executeValidatedClaim(claim, using: restorer)
    }
  }

  init(executeClaim: @escaping ExecuteClaim) {
    self.executeClaim = executeClaim
  }

  func execute(
    _ authorization: CleanupQuarantineRestoreAuthorization
  ) async throws -> CleanupQuarantineRestoreReport {
    let claim = try await authorization.consumeForExecution()
    switch executeClaim(claim) {
    case .success(let report):
      return report
    case .failure(let failure):
      return report(for: claim, failure: failure)
    }
  }

  private func report(
    for claim: CleanupQuarantineRestoreExecutionClaim,
    failure: DescriptorNPMQuarantineRestorePreflightFailure
  ) -> CleanupQuarantineRestoreReport {
    let intent = claim.evidence.restoreIntent
    let identity = reportIdentity(for: claim)
    let status: CleanupQuarantineRestoreStatus
    let durability: CleanupQuarantineRestoreDurabilityState

    switch failure {
    case .cancelled:
      status = .notRestored(.cancelled)
      durability = .notRecorded
    case .invalidCurrentAccount:
      status = .notRestored(.invalidCurrentAccount)
      durability = .notRecorded
    case .homeUnavailable(let systemFailure),
      .rootUnavailable(let systemFailure),
      .quarantineRootUnavailable(let systemFailure):
      status = .notRestored(.trustedRootUnavailable(systemFailure))
      durability = .notRecorded
    case .homeUnsafe, .rootUnsafe, .quarantineRootUnsafe:
      status = .notRestored(.trustedRootChanged)
      durability = .notRecorded
    case .restore(let restoreFailure):
      (status, durability) = reportState(for: restoreFailure)
    case .invalidHome, .invalidQuarantineTransactionID, .restoreIdentifierUnavailable,
      .restoreIdentifierCollisionLimitExceeded, .authorization, .invalidClaim:
      status = .notRestored(.invalidClaim)
      durability = .notRecorded
    }

    return CleanupQuarantineRestoreReport(
      quarantineTransactionID: intent.quarantineTransactionID,
      restoreTransactionID: intent.restoreTransactionID,
      path: ScanRelativePath(rawComponents: intent.sourceComponents),
      ruleRevision: identity,
      status: status,
      durabilityState: durability
    )
  }

  private func reportState(
    for failure: DescriptorQuarantineRestoreFailure
  ) -> (CleanupQuarantineRestoreStatus, CleanupQuarantineRestoreDurabilityState) {
    switch failure {
    case .cancelled:
      return (.notRestored(.cancelled), .notRecorded)
    case .invalidClaim:
      return (.notRestored(.invalidClaim), .notRecorded)
    case .transactionNotFound:
      return (.notRestored(.originalTransactionUnavailable), .notRecorded)
    case .transactionNotRestorable:
      return (.notRestored(.originalTransactionNotRestorable), .notRecorded)
    case .alreadyRestored:
      return (.notRestored(.alreadyRestored), .notRecorded)
    case .sourceNameOccupied:
      return (.notRestored(.sourceNameOccupied), .notRecorded)
    case .quarantinedItemMissing:
      return (.notRestored(.quarantinedItemMissing), .notRecorded)
    case .quarantinedItemChanged:
      return (.notRestored(.quarantinedItemChanged), .notRecorded)
    case .quarantinedItemUnsafe:
      return (.notRestored(.quarantinedItemUnsafe), .notRecorded)
    case .traversalLimitExceeded:
      return (.notRestored(.traversalLimitExceeded), .notRecorded)
    case .exclusiveRenameUnsupported:
      return (.notRestored(.exclusiveRenameUnsupported), .notRecorded)
    case .renameRejected(let systemFailure):
      return (.notRestored(.renameRejected(systemFailure)), .notRecorded)
    case .journal(.busy):
      return (.notRestored(.quarantineJournalBusy), .notRecorded)
    case .journal(.unavailable(let systemFailure)):
      return (.notRestored(.quarantineJournalUnavailable(systemFailure)), .notRecorded)
    case .journal(.unsafe):
      return (
        .manualRecoveryRequired(
          quarantineLocation: nil,
          reason: .quarantineJournalUnsafe
        ),
        .unresolved(restoreTransactionID: nil)
      )
    case .journal(.recoveryRequired(let transactionID)):
      return (
        .manualRecoveryRequired(
          quarantineLocation: nil,
          reason: .quarantineJournalUnsafe
        ),
        .unresolved(restoreTransactionID: transactionID)
      )
    }
  }

  private func reportIdentity(
    for claim: CleanupQuarantineRestoreExecutionClaim
  ) -> RuleRevision {
    if let intent = try? QuarantineJournalV1Codec.decodeIntent(
      claim.evidence.canonicalQuarantineIntentBytes
    ),
      let identifier = RuleIdentifier(rawValue: intent.policy.npmRule.identifier),
      let version = RuleVersion(rawValue: intent.policy.npmRule.version)
    {
      return RuleRevision(identifier: identifier, version: version)
    }

    guard
      let identifier = RuleIdentifier(rawValue: "devsift.cache.npm"),
      let version = RuleVersion(rawValue: 5)
    else {
      preconditionFailure("The pinned npm restore report revision is invalid")
    }
    return RuleRevision(identifier: identifier, version: version)
  }
}
