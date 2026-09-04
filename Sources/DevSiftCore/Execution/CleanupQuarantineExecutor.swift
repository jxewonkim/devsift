/// Internal transaction boundary for one authorized quarantine attempt.
///
/// Authorization consumption is the only throwing portion. Once the claim is
/// consumed, execution always returns a bounded report, including when the
/// caller is cancelled while a namespace mutation may be in flight.
struct CleanupQuarantineExecutor: Sendable {
  private let preflight: DescriptorNPMQuarantinePreflight
  private let mover: DescriptorExclusiveQuarantineMover

  init(
    preflight: DescriptorNPMQuarantinePreflight = DescriptorNPMQuarantinePreflight(),
    mover: DescriptorExclusiveQuarantineMover = DescriptorExclusiveQuarantineMover()
  ) {
    self.preflight = preflight
    self.mover = mover
  }

  func execute(
    _ authorization: CleanupQuarantineAuthorization
  ) async throws -> CleanupQuarantineExecutionReport {
    let claim = try await authorization.consumeForExecution()
    return executeConsumedClaim(claim)
  }

  private func executeConsumedClaim(
    _ claim: CleanupQuarantineExecutionClaim
  ) -> CleanupQuarantineExecutionReport {
    let identity = reportIdentity(for: claim)
    let result = preflight.moveValidatedCandidate(claim: claim, using: mover)

    switch result {
    case .success(let report):
      return report
    case .failure(let failure):
      return CleanupQuarantineExecutionReport(
        path: identity.path,
        ruleRevision: identity.ruleRevision,
        status: .notMoved(notMovedReason(for: failure)),
        quarantineRootMutation: .none
      )
    }
  }

  private func reportIdentity(
    for claim: CleanupQuarantineExecutionClaim
  ) -> (path: ScanRelativePath, ruleRevision: RuleRevision) {
    if let entry = claim.approval.reviewedManifest.entries.first {
      return (entry.path, entry.ruleRevision)
    }

    // Claims are produced only by the exact built-in authorization policy, so
    // this fallback is defensive against a future in-module contract change.
    let identifier = RuleIdentifier(rawValue: "devsift.cache.npm")!
    let version = RuleVersion(rawValue: 5)!
    return (.root, RuleRevision(identifier: identifier, version: version))
  }

  private func notMovedReason(
    for failure: DescriptorNPMQuarantinePreflightFailure
  ) -> CleanupQuarantineNotMovedReason {
    switch failure {
    case .cancelled:
      return .cancelled
    case .invalidClaim:
      return .invalidClaim
    case .invalidCurrentAccount:
      return .invalidCurrentAccount
    case .invalidHome:
      return .trustedRootUnavailable(.invalidMetadata)
    case .sourceRootMismatch:
      return .unsupportedPolicy
    case .rootUnavailable(let failure):
      return .trustedRootUnavailable(failure)
    case .rootChanged:
      return .trustedRootChanged
    case .candidateMissing:
      return .candidateMissing
    case .candidateChanged:
      return .candidateChanged
    case .candidateUnsafe, .layoutMismatch:
      return .candidateUnsafe
    case .traversalLimitExceeded:
      return .traversalLimitExceeded
    case .ageRequirementNotSatisfied:
      return .ageRequirementNotSatisfied
    }
  }
}
