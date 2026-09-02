import Foundation

extension RuleClassificationReport {
  /// Validates an already-returned classification report against its exact
  /// request. Custom classifiers are trusted in-process code, but callers can
  /// use this method to reject bounded yet structurally inconsistent output.
  public func validate(for request: RuleClassificationRequest) throws {
    guard referenceUnixSeconds == request.referenceUnixSeconds else {
      throw RuleClassificationReportValidationError.referenceTimeMismatch(
        expected: request.referenceUnixSeconds,
        actual: referenceUnixSeconds
      )
    }
    guard request.report.topLevelItems.count <= RuleCatalogLimits.maximumObservations else {
      throw RuleClassificationReportValidationError.tooManyInputItems(
        maximum: RuleCatalogLimits.maximumObservations,
        actual: request.report.topLevelItems.count
      )
    }
    guard evaluations.count <= RuleCatalogLimits.maximumObservations else {
      throw RuleClassificationReportValidationError.tooManyEvaluations(
        maximum: RuleCatalogLimits.maximumObservations,
        actual: evaluations.count
      )
    }
    try validateScanReportStructure(request.report)

    var totalFindingCount = 0
    for evaluation in evaluations {
      guard evaluation.findings.count <= RuleCatalogLimits.maximumFindingsPerEvaluation else {
        throw RuleClassificationReportValidationError.tooManyFindings(
          path: evaluation.path,
          maximum: RuleCatalogLimits.maximumFindingsPerEvaluation,
          actual: evaluation.findings.count
        )
      }
      let (newTotal, overflow) = totalFindingCount.addingReportingOverflow(
        evaluation.findings.count
      )
      totalFindingCount = overflow ? Int.max : newTotal
    }
    guard totalFindingCount <= RuleCatalogLimits.maximumTotalEvaluationFindings else {
      throw RuleClassificationReportValidationError.tooManyTotalFindings(
        maximum: RuleCatalogLimits.maximumTotalEvaluationFindings,
        actual: totalFindingCount
      )
    }

    var expectedPaths = Set<ScanRelativePath>()
    var inputCounts: [ScanRelativePath: Int] = [:]
    var inputItems: [ScanRelativePath: ScanItemSummary] = [:]
    for item in request.report.topLevelItems {
      guard item.path.rawComponents.count == 1 else {
        throw RuleClassificationReportValidationError.inputPathIsNotTopLevel(item.path)
      }
      expectedPaths.insert(item.path)
      inputCounts[item.path, default: 0] += 1
      if inputItems[item.path] == nil {
        inputItems[item.path] = item
      }
    }

    var observedPaths = Set<ScanRelativePath>()
    var previousPath: ScanRelativePath?
    for evaluation in evaluations {
      guard expectedPaths.contains(evaluation.path) else {
        throw RuleClassificationReportValidationError.extraEvaluation(evaluation.path)
      }
      guard observedPaths.insert(evaluation.path).inserted else {
        throw RuleClassificationReportValidationError.duplicateEvaluation(evaluation.path)
      }
      if let previousPath, evaluation.path < previousPath {
        throw RuleClassificationReportValidationError.evaluationsOutOfOrder(
          previous: previousPath,
          current: evaluation.path
        )
      }
      previousPath = evaluation.path
    }

    if let missingPath = expectedPaths.subtracting(observedPaths).sorted().first {
      throw RuleClassificationReportValidationError.missingEvaluation(missingPath)
    }

    var totalTextBytes = 0
    var totalIdentityTextBytes = 0
    var totalMatchingRuleRevisions = 0
    for evaluation in evaluations {
      let inputCount = inputCounts[evaluation.path] ?? 0
      if inputCount > 1 {
        try validateDuplicateObservationDecision(evaluation)
      }
      try validateEvaluation(
        evaluation,
        inputItem: inputCount == 1 ? inputItems[evaluation.path] : nil,
        inputWasDuplicated: inputCount > 1,
        scanReport: request.report,
        totalTextBytes: &totalTextBytes,
        totalIdentityTextBytes: &totalIdentityTextBytes,
        totalMatchingRuleRevisions: &totalMatchingRuleRevisions
      )
    }
  }

  private func validateScanReportStructure(_ report: ScanReport) throws {
    if report.topLevelItemsWereSuppressed {
      guard report.topLevelItems.isEmpty else {
        throw RuleClassificationReportValidationError.suppressedTopLevelItemsRetained(
          actual: report.topLevelItems.count
        )
      }
    } else {
      guard report.topLevelItemCount == UInt64(report.topLevelItems.count) else {
        throw RuleClassificationReportValidationError.topLevelItemCountMismatch(
          reported: report.topLevelItemCount,
          retained: report.topLevelItems.count
        )
      }
    }

    if report.traversalDetailsWereDiscarded {
      guard
        report.topLevelItemsWereSuppressed,
        report.topLevelItems.isEmpty,
        report.topLevelItemCount == 0,
        !report.hardLinkAccountingIsComplete
      else {
        throw RuleClassificationReportValidationError.discardedTraversalStateIsInconsistent
      }
    }

    if report.root.isComplete,
      !report.issues.isEmpty || report.suppressedIssueCount > 0
    {
      throw RuleClassificationReportValidationError.rootMarkedCompleteWithScanIssues
    }

    let incompletePaths = report.topLevelItems
      .filter { !$0.isComplete }
      .map(\.path)
      .sorted()
    if report.isComplete, let incompletePath = incompletePaths.first {
      throw RuleClassificationReportValidationError.completeReportContainsIncompleteItem(
        incompletePath
      )
    }
  }

  private func validateEvaluation(
    _ evaluation: RuleEvaluation,
    inputItem: ScanItemSummary?,
    inputWasDuplicated: Bool,
    scanReport: ScanReport,
    totalTextBytes: inout Int,
    totalIdentityTextBytes: inout Int,
    totalMatchingRuleRevisions: inout Int
  ) throws {
    let metadata: [(RuleEvaluationMetadataField, String)] = [
      (.displayName, evaluation.displayName),
      (.responsibleTool, evaluation.responsibleTool),
      (.explanation, evaluation.explanation),
    ]
    var metadataBytes = 0
    for (_, text) in metadata {
      metadataBytes = saturatingByteSum(metadataBytes, text.utf8.count)
    }
    guard metadataBytes <= RuleCatalogLimits.maximumEvaluationMetadataUTF8Bytes else {
      throw RuleClassificationReportValidationError.metadataTooLarge(
        path: evaluation.path,
        maximumBytes: RuleCatalogLimits.maximumEvaluationMetadataUTF8Bytes,
        actualBytes: metadataBytes
      )
    }
    for (field, text) in metadata {
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw RuleClassificationReportValidationError.emptyMetadata(
          path: evaluation.path,
          field: field
        )
      }
    }
    try addReportTextBytes(metadataBytes, total: &totalTextBytes)

    guard evaluation.matchingRules.count <= RuleCatalogLimits.maximumRules else {
      throw RuleClassificationReportValidationError.tooManyMatchingRules(
        path: evaluation.path,
        maximum: RuleCatalogLimits.maximumRules,
        actual: evaluation.matchingRules.count
      )
    }
    let normalizedMatchingRules = Array(Set(evaluation.matchingRules)).sorted()
    guard normalizedMatchingRules == evaluation.matchingRules else {
      throw RuleClassificationReportValidationError.matchingRulesNotSortedAndUnique(
        evaluation.path
      )
    }
    totalMatchingRuleRevisions = saturatingByteSum(
      totalMatchingRuleRevisions,
      evaluation.matchingRules.count
    )
    guard
      totalMatchingRuleRevisions <= RuleCatalogLimits.maximumTotalMatchingRuleRevisions
    else {
      throw RuleClassificationReportValidationError.tooManyTotalMatchingRuleRevisions(
        maximum: RuleCatalogLimits.maximumTotalMatchingRuleRevisions,
        actual: totalMatchingRuleRevisions
      )
    }
    if let rule = evaluation.rule {
      try addReportIdentityBytes(
        revisionIdentityUTF8Bytes(rule),
        total: &totalIdentityTextBytes
      )
    }
    for matchingRule in evaluation.matchingRules {
      try addReportIdentityBytes(
        revisionIdentityUTF8Bytes(matchingRule),
        total: &totalIdentityTextBytes
      )
    }

    var findingsByIdentifier: [CheckIdentifier: RuleFinding] = [:]
    for finding in evaluation.findings {
      try addReportIdentityBytes(
        finding.identifier.rawValue.utf8.count,
        total: &totalIdentityTextBytes
      )
      let textBytes = finding.explanation.utf8.count
      guard textBytes <= RuleCatalogLimits.maximumRuntimeFindingTextUTF8Bytes else {
        throw RuleClassificationReportValidationError.findingTextTooLong(
          path: evaluation.path,
          finding: finding.identifier,
          maximumBytes: RuleCatalogLimits.maximumRuntimeFindingTextUTF8Bytes,
          actualBytes: textBytes
        )
      }
      guard !finding.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw RuleClassificationReportValidationError.emptyFindingExplanation(
          path: evaluation.path,
          finding: finding.identifier
        )
      }
      guard findingsByIdentifier.updateValue(finding, forKey: finding.identifier) == nil else {
        throw RuleClassificationReportValidationError.duplicateFindingIdentifier(
          path: evaluation.path,
          finding: finding.identifier
        )
      }
      try addReportTextBytes(textBytes, total: &totalTextBytes)
    }

    try validateSemantics(evaluation, inputWasDuplicated: inputWasDuplicated)
    if evaluation.matchState == .matched || evaluation.matchState == .possibleMatch {
      guard let inputItem else {
        throw semanticError(evaluation, .duplicateObservationDecision)
      }
      try validateCommonFindings(
        evaluation,
        inputItem: inputItem,
        scanReport: scanReport,
        findings: findingsByIdentifier
      )
    }
  }

  private func validateSemantics(
    _ evaluation: RuleEvaluation,
    inputWasDuplicated: Bool
  ) throws {
    let hasBlockingFinding = evaluation.findings.contains { finding in
      finding.state != .satisfied
    }

    switch evaluation.matchState {
    case .matched:
      guard evaluation.disposition == .reclaimable || evaluation.disposition == .reviewRequired
      else {
        throw semanticError(evaluation, .matchedDisposition)
      }
      guard let rule = evaluation.rule, evaluation.matchingRules == [rule] else {
        throw semanticError(evaluation, .matchedRuleIdentity)
      }
      guard !evaluation.findings.isEmpty, !hasBlockingFinding else {
        throw semanticError(evaluation, .matchedFindings)
      }
      guard
        evaluation.findings.contains(where: { finding in
          !AutomaticCheckIdentifier.all.contains(finding.identifier)
            && finding.kind == .positiveEvidence
            && finding.state == .satisfied
        })
      else {
        throw semanticError(evaluation, .matchedPositiveEvidence)
      }
      guard
        evaluation.findings.contains(where: { finding in
          !AutomaticCheckIdentifier.all.contains(finding.identifier)
            && finding.kind == .exclusion
            && finding.state == .satisfied
        })
      else {
        throw semanticError(evaluation, .matchedExclusion)
      }
      guard evaluation.reproducibility != .unknown else {
        throw semanticError(evaluation, .matchedReproducibility)
      }
      guard
        evaluation.disposition != .reclaimable
          || evaluation.reproducibility == .reproducible
      else {
        throw semanticError(evaluation, .reclaimableReproducibility)
      }

    case .possibleMatch:
      try validateProtectedDisposition(evaluation)
      guard let rule = evaluation.rule, evaluation.matchingRules == [rule] else {
        throw semanticError(evaluation, .possibleMatchRuleIdentity)
      }
      guard hasBlockingFinding else {
        throw semanticError(evaluation, .blockingFinding)
      }

    case .unrecognized:
      try validateProtectedDisposition(evaluation)
      guard evaluation.rule == nil, evaluation.matchingRules.isEmpty else {
        throw semanticError(evaluation, .unrecognizedRuleIdentity)
      }
      guard
        hasFailedDiagnostic(
          AutomaticCheckIdentifier.lexicalRecognition,
          kind: .lexicalRecognition,
          in: evaluation
        )
      else {
        throw semanticError(evaluation, .unrecognizedDiagnostic)
      }

    case .conflict:
      try validateProtectedDisposition(evaluation)
      guard evaluation.rule == nil,
        evaluation.matchingRules.isEmpty || evaluation.matchingRules.count >= 2
      else {
        throw semanticError(evaluation, .conflictRuleIdentity)
      }
      let diagnostic: CheckIdentifier
      if evaluation.matchingRules.isEmpty {
        guard inputWasDuplicated else {
          throw semanticError(evaluation, .duplicateObservationDecision)
        }
        diagnostic = AutomaticCheckIdentifier.duplicateObservation
      } else {
        diagnostic = AutomaticCheckIdentifier.ruleConflict
      }
      guard hasFailedDiagnostic(diagnostic, kind: .conflict, in: evaluation) else {
        throw semanticError(evaluation, .conflictDiagnostic)
      }
      guard hasBlockingFinding else {
        throw semanticError(evaluation, .blockingFinding)
      }

    case .invalidRule:
      try validateProtectedDisposition(evaluation)
      let identityIsValid: Bool
      if let rule = evaluation.rule {
        identityIsValid = evaluation.matchingRules == [rule]
      } else {
        identityIsValid = !evaluation.matchingRules.isEmpty
      }
      guard identityIsValid else {
        throw semanticError(evaluation, .invalidRuleIdentity)
      }
      guard
        hasBlockingDiagnostic(
          AutomaticCheckIdentifier.ruleValidity,
          kind: .ruleValidity,
          in: evaluation
        )
      else {
        throw semanticError(evaluation, .invalidRuleDiagnostic)
      }
      guard hasBlockingFinding else {
        throw semanticError(evaluation, .blockingFinding)
      }
    }
  }

  private func validateDuplicateObservationDecision(
    _ evaluation: RuleEvaluation
  ) throws {
    guard
      evaluation.matchState == .conflict,
      evaluation.disposition == .protected,
      evaluation.rule == nil,
      evaluation.matchingRules.isEmpty,
      hasFailedDiagnostic(
        AutomaticCheckIdentifier.duplicateObservation,
        kind: .conflict,
        in: evaluation
      )
    else {
      throw semanticError(evaluation, .duplicateObservationDecision)
    }
  }

  private func validateCommonFindings(
    _ evaluation: RuleEvaluation,
    inputItem: ScanItemSummary,
    scanReport: ScanReport,
    findings: [CheckIdentifier: RuleFinding]
  ) throws {
    let commonKinds: [(CheckIdentifier, RuleFindingKind)] = [
      (AutomaticCheckIdentifier.lexicalRecognition, .lexicalRecognition),
      (AutomaticCheckIdentifier.reproducibility, .reproducibility),
      (AutomaticCheckIdentifier.age, .age),
      (AutomaticCheckIdentifier.activity, .activity),
      (AutomaticCheckIdentifier.reportComplete, .scanIntegrity),
      (AutomaticCheckIdentifier.itemComplete, .scanIntegrity),
      (AutomaticCheckIdentifier.topLevelOutputComplete, .scanIntegrity),
      (AutomaticCheckIdentifier.traversalDetailsRetained, .scanIntegrity),
      (AutomaticCheckIdentifier.issuesComplete, .scanIntegrity),
      (AutomaticCheckIdentifier.allocationKnown, .scanIntegrity),
      (AutomaticCheckIdentifier.sizeDidNotOverflow, .scanIntegrity),
      (AutomaticCheckIdentifier.hardLinksComplete, .scanIntegrity),
    ]

    for (identifier, expectedKind) in commonKinds {
      guard let finding = findings[identifier] else {
        throw RuleClassificationReportValidationError.missingCommonFinding(
          path: evaluation.path,
          finding: identifier
        )
      }
      guard finding.kind == expectedKind else {
        throw RuleClassificationReportValidationError.commonFindingKindMismatch(
          path: evaluation.path,
          finding: identifier,
          expected: expectedKind,
          actual: finding.kind
        )
      }
    }

    try validateCommonFindingState(
      AutomaticCheckIdentifier.lexicalRecognition,
      expected: .satisfied,
      evaluation: evaluation,
      findings: findings
    )
    let expectedReproducibilityState: RuleFindingState =
      switch evaluation.reproducibility {
      case .reproducible, .conditional:
        .satisfied
      case .unknown:
        .unknown(.unspecified)
      }
    try validateCommonFindingState(
      AutomaticCheckIdentifier.reproducibility,
      expected: expectedReproducibilityState,
      evaluation: evaluation,
      findings: findings
    )

    let integrityStates: [(CheckIdentifier, RuleFindingState)] = [
      (
        AutomaticCheckIdentifier.reportComplete,
        scanReport.isComplete ? .satisfied : .failed
      ),
      (
        AutomaticCheckIdentifier.itemComplete,
        inputItem.isComplete ? .satisfied : .failed
      ),
      (
        AutomaticCheckIdentifier.topLevelOutputComplete,
        scanReport.topLevelItemsWereSuppressed ? .failed : .satisfied
      ),
      (
        AutomaticCheckIdentifier.traversalDetailsRetained,
        scanReport.traversalDetailsWereDiscarded ? .failed : .satisfied
      ),
      (
        AutomaticCheckIdentifier.issuesComplete,
        scanReport.suppressedIssueCount == 0 ? .satisfied : .failed
      ),
      (
        AutomaticCheckIdentifier.allocationKnown,
        inputItem.unknownAllocatedItemCount == 0 ? .satisfied : .failed
      ),
      (
        AutomaticCheckIdentifier.sizeDidNotOverflow,
        inputItem.sizeOverflowed ? .failed : .satisfied
      ),
      (
        AutomaticCheckIdentifier.hardLinksComplete,
        scanReport.hardLinkAccountingIsComplete ? .satisfied : .failed
      ),
    ]
    for (identifier, expectedState) in integrityStates {
      try validateCommonFindingState(
        identifier,
        expected: expectedState,
        evaluation: evaluation,
        findings: findings
      )
    }
  }

  private func validateCommonFindingState(
    _ identifier: CheckIdentifier,
    expected: RuleFindingState,
    evaluation: RuleEvaluation,
    findings: [CheckIdentifier: RuleFinding]
  ) throws {
    guard let actual = findings[identifier]?.state else {
      throw RuleClassificationReportValidationError.missingCommonFinding(
        path: evaluation.path,
        finding: identifier
      )
    }
    guard actual == expected else {
      throw RuleClassificationReportValidationError.commonFindingStateMismatch(
        path: evaluation.path,
        finding: identifier,
        expected: expected,
        actual: actual
      )
    }
  }

  private func validateProtectedDisposition(_ evaluation: RuleEvaluation) throws {
    guard evaluation.disposition == .protected else {
      throw semanticError(evaluation, .protectedDisposition)
    }
  }

  private func hasBlockingDiagnostic(
    _ identifier: CheckIdentifier,
    kind: RuleFindingKind,
    in evaluation: RuleEvaluation
  ) -> Bool {
    evaluation.findings.contains { finding in
      finding.identifier == identifier
        && finding.kind == kind
        && finding.state != .satisfied
    }
  }

  private func hasFailedDiagnostic(
    _ identifier: CheckIdentifier,
    kind: RuleFindingKind,
    in evaluation: RuleEvaluation
  ) -> Bool {
    evaluation.findings.contains { finding in
      finding.identifier == identifier
        && finding.kind == kind
        && finding.state == .failed
    }
  }

  private func semanticError(
    _ evaluation: RuleEvaluation,
    _ invariant: RuleEvaluationInvariant
  ) -> RuleClassificationReportValidationError {
    .semanticInvariant(path: evaluation.path, invariant: invariant)
  }

  private func addReportTextBytes(_ bytes: Int, total: inout Int) throws {
    total = saturatingByteSum(total, bytes)
    guard total <= RuleCatalogLimits.maximumTotalReportTextUTF8Bytes else {
      throw RuleClassificationReportValidationError.totalReportTextTooLong(
        maximumBytes: RuleCatalogLimits.maximumTotalReportTextUTF8Bytes
      )
    }
  }

  private func addReportIdentityBytes(_ bytes: Int, total: inout Int) throws {
    total = saturatingByteSum(total, bytes)
    guard total <= RuleCatalogLimits.maximumTotalReportIdentityUTF8Bytes else {
      throw RuleClassificationReportValidationError.totalReportIdentityTextTooLong(
        maximumBytes: RuleCatalogLimits.maximumTotalReportIdentityUTF8Bytes
      )
    }
  }

  private func revisionIdentityUTF8Bytes(_ revision: RuleRevision) -> Int {
    saturatingByteSum(
      revision.identifier.rawValue.utf8.count,
      String(revision.version.rawValue).utf8.count
    )
  }

  private func saturatingByteSum(_ left: Int, _ right: Int) -> Int {
    let (sum, overflow) = left.addingReportingOverflow(right)
    return overflow ? Int.max : sum
  }
}
