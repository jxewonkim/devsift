public protocol CleanupPlanning: Sendable {
  func makeManifest(_ request: CleanupManifestRequest) throws -> CleanupManifest
}

/// Converts explicit candidate selections into an immutable dry-run manifest.
///
/// The planner is a pure value transformation. It never opens a path, performs
/// filesystem I/O, approves an entry, or grants mutation authority.
public struct CleanupPlanner: CleanupPlanning, Sendable {
  public init() {}

  public func makeManifest(_ request: CleanupManifestRequest) throws -> CleanupManifest {
    try Task.checkCancellation()

    guard request.selections.count <= CleanupPlanningLimits.maximumSelections else {
      throw CleanupPlanningError.tooManySelections(
        maximum: CleanupPlanningLimits.maximumSelections,
        actual: request.selections.count
      )
    }

    do {
      try request.classificationReport.validate(for: request.classificationRequest)
    } catch let error as RuleClassificationReportValidationError {
      throw CleanupPlanningError.invalidClassificationReport(error)
    } catch {
      throw CleanupPlanningError.classificationValidationFailed
    }
    guard request.classificationReport.isSourceBound(to: request.classificationRequest) else {
      throw CleanupPlanningError.classificationReportIsNotSourceBound
    }
    guard let policyProvenance = request.classificationReport.policyProvenance else {
      throw CleanupPlanningError.missingPolicyProvenance
    }

    try Task.checkCancellation()

    let report = request.classificationRequest.report
    guard
      report.isComplete,
      report.root.isComplete,
      !report.root.sizeOverflowed,
      report.root.unknownAllocatedItemCount == 0
    else {
      throw CleanupPlanningError.incompleteScan
    }
    guard let rootIdentity = report.root.scanTimeIdentity else {
      throw CleanupPlanningError.missingRootIdentity
    }

    var observedSelections = Set<ScanRelativePath>()
    for selection in request.selections {
      try Task.checkCancellation()
      try validateSelectionPath(selection.path)
      guard observedSelections.insert(selection.path).inserted else {
        throw CleanupPlanningError.duplicateSelection(selection.path)
      }
    }

    let orderedSelections = request.selections.sorted { left, right in
      if left.path != right.path {
        return left.path < right.path
      }
      return left.ruleRevision < right.ruleRevision
    }

    var summariesByPath: [ScanRelativePath: [ScanItemSummary]] = [:]
    summariesByPath.reserveCapacity(report.topLevelItems.count)
    for summary in report.topLevelItems {
      try Task.checkCancellation()
      summariesByPath[summary.path, default: []].append(summary)
    }

    var evaluationsByPath: [ScanRelativePath: RuleEvaluation] = [:]
    evaluationsByPath.reserveCapacity(request.classificationReport.evaluations.count)
    for evaluation in request.classificationReport.evaluations {
      try Task.checkCancellation()
      evaluationsByPath[evaluation.path] = evaluation
    }

    var entries: [CleanupManifestEntry] = []
    entries.reserveCapacity(orderedSelections.count)

    for selection in orderedSelections {
      try Task.checkCancellation()

      guard let summaries = summariesByPath[selection.path] else {
        throw CleanupPlanningError.selectionNotFound(selection.path)
      }
      guard summaries.count == 1, let summary = summaries.first else {
        throw CleanupPlanningError.ambiguousSelection(selection.path)
      }
      guard let evaluation = evaluationsByPath[selection.path] else {
        throw CleanupPlanningError.selectionNotFound(selection.path)
      }

      guard
        evaluation.matchState == .matched,
        evaluation.disposition == .reclaimable || evaluation.disposition == .reviewRequired
      else {
        throw CleanupPlanningError.ineligibleCandidate(
          path: selection.path,
          matchState: evaluation.matchState,
          disposition: evaluation.disposition
        )
      }
      guard
        evaluation.rule == selection.ruleRevision,
        evaluation.matchingRules == [selection.ruleRevision]
      else {
        throw CleanupPlanningError.ruleRevisionMismatch(
          path: selection.path,
          selected: selection.ruleRevision,
          classified: evaluation.rule
        )
      }
      guard summary.kind == .directory else {
        throw CleanupPlanningError.unsupportedCandidateKind(
          path: selection.path,
          kind: summary.kind
        )
      }
      guard
        summary.isComplete,
        summary.unknownAllocatedItemCount == 0,
        !summary.sizeOverflowed,
        report.hardLinkAccountingIsComplete
      else {
        throw CleanupPlanningError.incompleteCandidateObservation(selection.path)
      }
      guard let candidateIdentity = summary.scanTimeIdentity else {
        throw CleanupPlanningError.missingCandidateIdentity(selection.path)
      }
      guard candidateIdentity.device == rootIdentity.device else {
        throw CleanupPlanningError.candidateDeviceMismatch(selection.path)
      }

      let identityFinding = evaluation.findings.first { finding in
        finding.identifier == AutomaticCheckIdentifier.identityMatchesScan
      }
      guard identityFinding?.state == .satisfied else {
        throw CleanupPlanningError.identityEvidenceNotSatisfied(selection.path)
      }
      if let blockingFinding = evaluation.findings.first(where: { finding in
        finding.state != .satisfied
      }) {
        throw CleanupPlanningError.evidenceNotSatisfied(
          path: selection.path,
          finding: blockingFinding.identifier
        )
      }

      guard
        summary.hardLinkExclusiveAllocatedBytes <= summary.recursiveSize.allocatedBytes
      else {
        throw CleanupPlanningError.invalidSize(selection.path)
      }

      let size = CleanupManifestSizeObservation(summary: summary)
      entries.append(
        CleanupManifestEntry(
          path: selection.path,
          expectedKind: summary.kind,
          expectedIdentity: candidateIdentity,
          ruleRevision: selection.ruleRevision,
          disposition: evaluation.disposition,
          reproducibility: evaluation.reproducibility,
          displayName: evaluation.displayName,
          responsibleTool: evaluation.responsibleTool,
          classificationExplanation: evaluation.explanation,
          findings: evaluation.findings,
          size: size
        )
      )
    }

    let manifest = try CleanupManifest(
      policyProvenance: policyProvenance,
      classificationReferenceUnixSeconds: request.classificationReport.referenceUnixSeconds,
      expectedRootIdentity: rootIdentity,
      entries: entries
    )
    try Task.checkCancellation()
    return manifest
  }

  private func validateSelectionPath(_ path: ScanRelativePath) throws {
    guard path.rawComponents.count == 1 else {
      throw CleanupPlanningError.invalidSelectionPath(path: path, issue: .notTopLevel)
    }
    let component = path.rawComponents[0]
    guard !component.isEmpty else {
      throw CleanupPlanningError.invalidSelectionPath(path: path, issue: .emptyComponent)
    }
    guard component != [0x2E] else {
      throw CleanupPlanningError.invalidSelectionPath(
        path: path,
        issue: .currentDirectoryComponent
      )
    }
    guard component != [0x2E, 0x2E] else {
      throw CleanupPlanningError.invalidSelectionPath(
        path: path,
        issue: .parentDirectoryComponent
      )
    }
    guard !component.contains(0) else {
      throw CleanupPlanningError.invalidSelectionPath(path: path, issue: .containsNullByte)
    }
    guard !component.contains(0x2F) else {
      throw CleanupPlanningError.invalidSelectionPath(
        path: path,
        issue: .containsPathSeparator
      )
    }
    guard component.count <= CleanupPlanningLimits.maximumCandidateComponentBytes else {
      throw CleanupPlanningError.invalidSelectionPath(
        path: path,
        issue: .componentTooLong(
          maximum: CleanupPlanningLimits.maximumCandidateComponentBytes,
          actual: component.count
        )
      )
    }
  }
}
