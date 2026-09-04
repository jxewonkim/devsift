import Foundation

public protocol CleanupRevalidating: Sendable {
  /// Freshly reobserves an approval without granting mutation authority.
  ///
  /// The approval is the sole source input. In particular, a caller cannot
  /// substitute a separately supplied root or manifest.
  func revalidate(_ approval: CleanupApproval) async throws -> CleanupRevalidationReport
}

/// Reobserves a complete approval under the currently supported policy.
///
/// The default composition performs a fresh allocated-size scan and built-in
/// explainable classification. It does not persist, move, delete, or open an
/// execution capability for any entry.
public struct CleanupRevalidator: CleanupRevalidating, Sendable {
  typealias ReferenceTime = @Sendable () -> Int64

  private let scanner: any FileSystemScanning
  private let classifier: any RuleClassifying
  private let referenceTime: ReferenceTime
  private let supportedPolicyProvenance: RulePolicyProvenance

  public init() {
    scanner = AllocatedSizeScanner()
    classifier = ExplainableRuleClassifier()
    referenceTime = {
      Int64(Date().timeIntervalSince1970.rounded(.down))
    }
    supportedPolicyProvenance = .currentBuiltIn
  }

  init(
    scanner: any FileSystemScanning,
    classifier: any RuleClassifying,
    referenceTime: @escaping ReferenceTime,
    supportedPolicyProvenance: RulePolicyProvenance
  ) {
    self.scanner = scanner
    self.classifier = classifier
    self.referenceTime = referenceTime
    self.supportedPolicyProvenance = supportedPolicyProvenance
  }

  public func revalidate(
    _ approval: CleanupApproval
  ) async throws -> CleanupRevalidationReport {
    do {
      return try await revalidateChecked(approval)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as CleanupRevalidationError {
      throw error
    } catch {
      // No arbitrary dependency or implementation error crosses this public
      // boundary. Unexpected failures fail closed.
      throw CleanupRevalidationError.planningInvariantFailed
    }
  }

  private func revalidateChecked(
    _ approval: CleanupApproval
  ) async throws -> CleanupRevalidationReport {
    try Task.checkCancellation()
    try validateApprovalPreflight(approval)
    try Task.checkCancellation()

    let scanReport: ScanReport
    do {
      scanReport = try await scanner.scan(ScanRequest(root: approval.sourceRoot))
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if Task.isCancelled {
        throw CancellationError()
      }
      throw CleanupRevalidationError.scanFailed
    }

    do {
      try ScanReportPreflight.validate(scanReport)
    } catch {
      throw CleanupRevalidationError.invalidScanReport
    }
    guard scanReport.root.scanTimeIdentity == approval.reviewedManifest.expectedRootIdentity,
      let observedRootIdentity = scanReport.root.scanTimeIdentity
    else {
      throw CleanupRevalidationError.rootIdentityChanged
    }
    try Task.checkCancellation()

    let referenceUnixSeconds = referenceTime()
    try Task.checkCancellation()
    guard scanReport.isComplete else {
      var entries: [CleanupRevalidationEntry] = []
      entries.reserveCapacity(approval.reviewedManifest.entries.count)
      for entry in approval.reviewedManifest.entries {
        try Task.checkCancellation()
        entries.append(result(for: entry, rejecting: .sourceObservationIncomplete))
      }
      return CleanupRevalidationReport(
        observedRootIdentity: observedRootIdentity,
        policyProvenance: supportedPolicyProvenance,
        referenceUnixSeconds: referenceUnixSeconds,
        entries: entries
      )
    }

    let classificationRequest = RuleClassificationRequest(
      root: approval.sourceRoot,
      report: scanReport,
      referenceUnixSeconds: referenceUnixSeconds
    )
    let classificationReport: RuleClassificationReport
    do {
      classificationReport = try await classifier.classify(classificationRequest)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if Task.isCancelled {
        throw CancellationError()
      }
      throw CleanupRevalidationError.classificationFailed
    }

    do {
      try classificationReport.validate(for: classificationRequest)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw CleanupRevalidationError.invalidClassificationReport
    }
    guard classificationReport.isSourceBound(to: classificationRequest) else {
      throw CleanupRevalidationError.classificationReportIsNotSourceBound
    }
    guard
      classificationReport.policyProvenance == supportedPolicyProvenance,
      classificationReport.policyProvenance == approval.reviewedManifest.policyProvenance
    else {
      throw CleanupRevalidationError.unsupportedClassificationPolicy
    }
    try Task.checkCancellation()

    return try makeCompleteReport(
      approval: approval,
      scanReport: scanReport,
      classificationRequest: classificationRequest,
      classificationReport: classificationReport,
      observedRootIdentity: observedRootIdentity
    )
  }

  private func makeCompleteReport(
    approval: CleanupApproval,
    scanReport: ScanReport,
    classificationRequest: RuleClassificationRequest,
    classificationReport: RuleClassificationReport,
    observedRootIdentity: FileIdentity
  ) throws -> CleanupRevalidationReport {
    var summariesByPath: [ScanRelativePath: [ScanItemSummary]] = [:]
    for summary in scanReport.topLevelItems {
      try Task.checkCancellation()
      summariesByPath[summary.path, default: []].append(summary)
    }
    let evaluationsByPath = Dictionary(
      uniqueKeysWithValues: classificationReport.evaluations.map { ($0.path, $0) }
    )

    var statuses: [ScanRelativePath: CleanupRevalidationStatus] = [:]
    var eligibleSelections: [CleanupCandidateSelection] = []
    for entry in approval.reviewedManifest.entries {
      try Task.checkCancellation()
      let status = preliminaryStatus(
        for: entry,
        summaries: summariesByPath[entry.path],
        evaluation: evaluationsByPath[entry.path]
      )
      statuses[entry.path] = status
      switch status {
      case .eligibleAtObservation, .awaitingExecutionPreconditions:
        eligibleSelections.append(
          CleanupCandidateSelection(path: entry.path, ruleRevision: entry.ruleRevision)
        )
      case .rejected:
        break
      }
    }

    let freshManifest: CleanupManifest
    do {
      freshManifest = try CleanupPlanner().makeManifest(
        CleanupManifestRequest(
          classificationRequest: classificationRequest,
          classificationReport: classificationReport,
          selections: eligibleSelections
        )
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw CleanupRevalidationError.planningInvariantFailed
    }
    guard
      freshManifest.policyProvenance == supportedPolicyProvenance,
      freshManifest.expectedRootIdentity == observedRootIdentity,
      freshManifest.entries.count == eligibleSelections.count
    else {
      throw CleanupRevalidationError.planningInvariantFailed
    }

    let freshEntries = Dictionary(
      uniqueKeysWithValues: freshManifest.entries.map { ($0.path, $0) }
    )
    let approvedEntries = Dictionary(
      uniqueKeysWithValues: approval.reviewedManifest.entries.map { ($0.path, $0) }
    )
    for selection in eligibleSelections {
      try Task.checkCancellation()
      guard
        let approved = approvedEntries[selection.path],
        let fresh = freshEntries[selection.path]
      else {
        throw CleanupRevalidationError.planningInvariantFailed
      }
      if !stablePolicyFieldsMatch(approved: approved, fresh: fresh) {
        statuses[selection.path] = .rejected(.policyDecisionChanged)
      }
    }

    var entries: [CleanupRevalidationEntry] = []
    entries.reserveCapacity(approval.reviewedManifest.entries.count)
    for entry in approval.reviewedManifest.entries {
      try Task.checkCancellation()
      entries.append(
        CleanupRevalidationEntry(
          path: entry.path,
          ruleRevision: entry.ruleRevision,
          status: statuses[entry.path] ?? .rejected(.policyDecisionChanged)
        )
      )
    }
    return CleanupRevalidationReport(
      observedRootIdentity: observedRootIdentity,
      policyProvenance: supportedPolicyProvenance,
      referenceUnixSeconds: classificationRequest.referenceUnixSeconds,
      entries: entries
    )
  }

  private func preliminaryStatus(
    for approved: CleanupManifestEntry,
    summaries: [ScanItemSummary]?,
    evaluation: RuleEvaluation?
  ) -> CleanupRevalidationStatus {
    guard let summaries else {
      return .rejected(.candidateMissing)
    }
    guard summaries.count == 1, let summary = summaries.first else {
      return .rejected(.candidateAmbiguous)
    }
    guard summary.kind == approved.expectedKind else {
      return .rejected(
        .candidateKindChanged(expected: approved.expectedKind, observed: summary.kind)
      )
    }
    guard summary.scanTimeIdentity == approved.expectedIdentity else {
      return .rejected(.candidateIdentityChanged)
    }
    guard let evaluation else {
      return .rejected(.policyDecisionChanged)
    }
    guard
      evaluation.rule == approved.ruleRevision,
      evaluation.matchingRules == [approved.ruleRevision]
    else {
      return .rejected(
        .ruleRevisionChanged(expected: approved.ruleRevision, observed: evaluation.rule)
      )
    }
    guard evaluation.deferredExecutionPreconditionsAreWellFormed else {
      return .rejected(.policyDecisionChanged)
    }
    if let blockingFinding = evaluation.nonDeferredBlockingFindings.first {
      return .rejected(.blockingFinding(blockingFinding.identifier))
    }
    guard
      evaluation.deferredExecutionPreconditions
        == approved.deferredExecutionPreconditions
    else {
      return .rejected(.policyDecisionChanged)
    }
    guard
      evaluation.matchState == .matched,
      evaluation.disposition == .reclaimable || evaluation.disposition == .reviewRequired
    else {
      return .rejected(.policyDecisionChanged)
    }
    if !evaluation.deferredExecutionPreconditions.isEmpty {
      return .awaitingExecutionPreconditions(
        evaluation.deferredExecutionPreconditions
      )
    }
    return .eligibleAtObservation
  }

  private func stablePolicyFieldsMatch(
    approved: CleanupManifestEntry,
    fresh: CleanupManifestEntry
  ) -> Bool {
    approved.path == fresh.path
      && approved.expectedKind == fresh.expectedKind
      && approved.expectedIdentity == fresh.expectedIdentity
      && approved.ruleRevision == fresh.ruleRevision
      && approved.disposition == fresh.disposition
      && approved.reproducibility == fresh.reproducibility
      && approved.displayName == fresh.displayName
      && approved.responsibleTool == fresh.responsibleTool
      && approved.classificationExplanation == fresh.classificationExplanation
      && approved.findings == fresh.findings
      && approved.deferredExecutionPreconditions
        == fresh.deferredExecutionPreconditions
  }

  private func validateApprovalPreflight(_ approval: CleanupApproval) throws {
    do {
      try CleanupApprovalValidator.validate(
        approval,
        supportedPolicyProvenance: supportedPolicyProvenance
      )
    } catch let error as CleanupApprovalValidationError {
      switch error {
      case .invalid(let invariant):
        throw CleanupRevalidationError.invalidApproval(invariant)
      case .unsupportedPolicy:
        throw CleanupRevalidationError.unsupportedApprovalPolicy
      }
    }
  }

  private func result(
    for entry: CleanupManifestEntry,
    rejecting reason: CleanupRevalidationRejection
  ) -> CleanupRevalidationEntry {
    CleanupRevalidationEntry(
      path: entry.path,
      ruleRevision: entry.ruleRevision,
      status: .rejected(reason)
    )
  }

}
