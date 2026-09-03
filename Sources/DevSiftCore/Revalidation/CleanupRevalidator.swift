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
    supportedPolicyProvenance = Self.builtInPolicyProvenance
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
      if status == .eligibleAtObservation {
        eligibleSelections.append(
          CleanupCandidateSelection(path: entry.path, ruleRevision: entry.ruleRevision)
        )
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
    if let blockingFinding = evaluation.findings.first(where: { $0.state != .satisfied }) {
      return .rejected(.blockingFinding(blockingFinding.identifier))
    }
    guard
      evaluation.matchState == .matched,
      evaluation.disposition == .reclaimable || evaluation.disposition == .reviewRequired
    else {
      return .rejected(.policyDecisionChanged)
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
  }

  private func validateApprovalPreflight(_ approval: CleanupApproval) throws {
    guard approval.contractVersion == CleanupApproval.currentContractVersion else {
      throw invalid(.approvalContractVersion)
    }
    guard approval.reviewedManifest.contractVersion == CleanupManifest.currentContractVersion else {
      throw invalid(.manifestContractVersion)
    }
    guard LocalFileSystemRootValidator.isValid(approval.sourceRoot) else {
      throw invalid(.invalidSourceRoot)
    }
    let manifest = approval.reviewedManifest
    guard manifest.policyProvenance == supportedPolicyProvenance else {
      throw CleanupRevalidationError.unsupportedApprovalPolicy
    }
    guard !manifest.entries.isEmpty else {
      throw invalid(.emptyManifest)
    }
    guard manifest.entries.count <= CleanupPlanningLimits.maximumSelections else {
      throw invalid(.tooManyEntries)
    }

    let ordered = manifest.entries.sorted(by: manifestEntryOrder)
    guard ordered == manifest.entries else {
      throw invalid(.entriesNotCanonical)
    }
    var paths = Set<ScanRelativePath>()
    for entry in manifest.entries {
      try Task.checkCancellation()
      guard paths.insert(entry.path).inserted else {
        throw invalid(.duplicateEntryPath)
      }
      guard candidatePathIsValid(entry.path) else {
        throw invalid(.invalidEntryPath)
      }
      guard entry.expectedKind == .directory else {
        throw invalid(.unsupportedEntryKind)
      }
      guard entry.expectedIdentity.device == manifest.expectedRootIdentity.device else {
        throw invalid(.entryDeviceMismatch)
      }
      guard manifest.policyProvenance.ruleRevisions.contains(entry.ruleRevision) else {
        throw invalid(.undeclaredRuleRevision)
      }
      guard entry.disposition == .reclaimable || entry.disposition == .reviewRequired else {
        throw invalid(.ineligibleDisposition)
      }
      guard findingsAreValid(entry.findings) else {
        throw invalid(.invalidFindings)
      }
    }
    guard try totalsAreValid(manifest) else {
      throw invalid(.invalidTotals)
    }
  }

  private func findingsAreValid(_ findings: [RuleFinding]) -> Bool {
    guard
      !findings.isEmpty,
      findings.count <= RuleCatalogLimits.maximumFindingsPerEvaluation,
      findings.allSatisfy({ $0.state == .satisfied })
    else {
      return false
    }
    let identifiers = findings.map(\.identifier)
    return identifiers == identifiers.sorted() && Set(identifiers).count == identifiers.count
  }

  private func totalsAreValid(_ manifest: CleanupManifest) throws -> Bool {
    var logical: UInt64 = 0
    var allocated: UInt64 = 0
    var exclusive: UInt64 = 0
    var possibleShared: UInt64 = 0
    var unavailableShared: UInt64 = 0
    var unobservedHardLinks: UInt64 = 0
    var nonExclusiveHardLinks: UInt64 = 0

    for entry in manifest.entries {
      try Task.checkCancellation()
      guard
        add(entry.size.observedLogicalBytes, to: &logical),
        add(entry.size.observedAllocatedBytes, to: &allocated),
        add(entry.size.observedHardLinkExclusiveAllocatedBytes, to: &exclusive),
        add(entry.size.possibleSharedContentFileCount, to: &possibleShared),
        add(entry.size.sharedContentMetadataUnavailableCount, to: &unavailableShared),
        add(entry.size.unobservedHardLinkFileCount, to: &unobservedHardLinks),
        add(entry.size.nonExclusiveHardLinkFileCount, to: &nonExclusiveHardLinks)
      else {
        return false
      }
    }
    return logical == manifest.totals.observedLogicalBytes
      && allocated == manifest.totals.observedAllocatedBytes
      && exclusive == manifest.totals.observedHardLinkExclusiveAllocatedBytes
      && possibleShared == manifest.totals.possibleSharedContentFileCount
      && unavailableShared == manifest.totals.sharedContentMetadataUnavailableCount
      && unobservedHardLinks == manifest.totals.unobservedHardLinkFileCount
      && nonExclusiveHardLinks == manifest.totals.nonExclusiveHardLinkFileCount
  }

  private func add(_ value: UInt64, to total: inout UInt64) -> Bool {
    let (sum, overflow) = total.addingReportingOverflow(value)
    guard !overflow else { return false }
    total = sum
    return true
  }

  private func candidatePathIsValid(_ path: ScanRelativePath) -> Bool {
    guard path.rawComponents.count == 1 else { return false }
    let component = path.rawComponents[0]
    return !component.isEmpty
      && component != [0x2E]
      && component != [0x2E, 0x2E]
      && !component.contains(0)
      && !component.contains(0x2F)
      && component.count <= CleanupPlanningLimits.maximumCandidateComponentBytes
  }

  private func manifestEntryOrder(
    _ left: CleanupManifestEntry,
    _ right: CleanupManifestEntry
  ) -> Bool {
    if left.path != right.path { return left.path < right.path }
    return left.ruleRevision < right.ruleRevision
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

  private func invalid(
    _ invariant: CleanupRevalidationApprovalInvariant
  ) -> CleanupRevalidationError {
    .invalidApproval(invariant)
  }

  private static let builtInPolicyProvenance: RulePolicyProvenance = {
    do {
      return try RulePolicyProvenance(
        classificationContractRevision: ExplainableRuleClassifier.classificationContractRevision,
        catalogRevision: BuiltInRuleCatalog.revision,
        ruleRevisions: BuiltInRuleCatalog.rules.map { $0.definition.revision }
      )
    } catch {
      preconditionFailure("The built-in rule policy provenance is invalid")
    }
  }()
}
