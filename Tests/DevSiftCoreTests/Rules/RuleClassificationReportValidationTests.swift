import Foundation
import Testing

@testable import DevSiftCore

@Suite("Rule classification report validation")
struct RuleClassificationReportValidationTests {
  @Test("Default classifier output validates, including duplicate scan identities")
  func validatesDefaultOutput() async throws {
    let uv = ruleSummary(rawComponents: [Array("uv".utf8)])
    let ordinary = ruleSummary(rawComponents: [Array("ordinary".utf8)])
    let request = RuleClassificationRequest(
      root: URL(fileURLWithPath: "/synthetic/Caches", isDirectory: true),
      report: completeScanReport(topLevelItems: [ordinary, uv]),
      referenceUnixSeconds: 1_000_000
    )
    let result = try await ExplainableRuleClassifier().classify(request)
    try result.validate(for: request)

    let duplicateRequest = RuleClassificationRequest(
      root: request.root,
      report: completeScanReport(topLevelItems: [uv, uv]),
      referenceUnixSeconds: request.referenceUnixSeconds
    )
    let duplicateResult = try await ExplainableRuleClassifier().classify(duplicateRequest)
    #expect(duplicateResult.evaluations.first?.matchState == .conflict)
    try duplicateResult.validate(for: duplicateRequest)
  }

  @Test("Default and custom classifier outputs self-validate when protected")
  func classifierSelfValidation() async throws {
    let partialItem = ruleSummary(
      rawComponents: [Array("uv".utf8)],
      isComplete: false,
      unknownAllocatedItemCount: 1,
      sizeOverflowed: true
    )
    let partialScan = ScanReport(
      root: ruleSummary(rawComponents: [], isComplete: false),
      topLevelItems: [partialItem],
      topLevelItemCount: 1,
      topLevelItemsWereSuppressed: false,
      hardLinkAccountingIsComplete: false,
      traversalDetailsWereDiscarded: false,
      issues: [],
      suppressedIssueCount: 1
    )
    let request = RuleClassificationRequest(
      root: URL(fileURLWithPath: "/synthetic/Caches", isDirectory: true),
      report: partialScan,
      referenceUnixSeconds: 100
    )
    let partial = try await ExplainableRuleClassifier().classify(request)
    #expect(partial.evaluations.first?.matchState == .possibleMatch)
    try partial.validate(for: request)

    let malformed = SyntheticRule(
      definition: syntheticDefinition(id: "devsift.validation.malformed"),
      findings: []
    )
    let invalid = try await ExplainableRuleClassifier(rules: [malformed]).classify(request)
    #expect(invalid.evaluations.first?.matchState == .invalidRule)
    #expect(invalid.evaluations.first?.rule == nil)
    #expect(invalid.evaluations.first?.matchingRules.count == 1)
    try invalid.validate(for: request)

    let valid = SyntheticRule(
      definition: syntheticDefinition(id: "devsift.validation.valid")
    )
    let invalidAggregate = try await ExplainableRuleClassifier(
      rules: [valid, malformed]
    ).classify(request)
    #expect(invalidAggregate.evaluations.first?.matchState == .invalidRule)
    #expect(invalidAggregate.evaluations.first?.matchingRules.count == 2)
    try invalidAggregate.validate(for: request)
  }

  @Test("Reference time must exactly match the request")
  func referenceMismatch() {
    let request = validationRequest(names: ["a"], referenceUnixSeconds: 100)
    let report = RuleClassificationReport(
      referenceUnixSeconds: 101,
      evaluations: [validationEvaluation()]
    )

    expectValidationError(
      .referenceTimeMismatch(expected: 100, actual: 101),
      report: report,
      request: request
    )
  }

  @Test("Missing, extra, duplicate, and out-of-order paths are rejected")
  func pathCoverageAndOrder() {
    let request = validationRequest(names: ["a", "b"])
    let a = validationEvaluation(path: validationPath("a"))
    let b = validationEvaluation(path: validationPath("b"))
    let c = validationEvaluation(path: validationPath("c"))

    expectValidationError(
      .missingEvaluation(validationPath("b")),
      report: validationReport([a]),
      request: request
    )
    expectValidationError(
      .extraEvaluation(validationPath("c")),
      report: validationReport([a, c]),
      request: request
    )
    expectValidationError(
      .duplicateEvaluation(validationPath("a")),
      report: validationReport([a, a, b]),
      request: request
    )
    expectValidationError(
      .evaluationsOutOfOrder(previous: validationPath("b"), current: validationPath("a")),
      report: validationReport([b, a]),
      request: request
    )
  }

  @Test("Duplicate input paths accept only the duplicate-observation decision")
  func duplicateInputDecision() {
    let request = RuleClassificationRequest(
      root: URL(fileURLWithPath: "/synthetic", isDirectory: true),
      report: completeScanReport(
        topLevelItems: [
          ruleSummary(rawComponents: [Array("a".utf8)]),
          ruleSummary(rawComponents: [Array("a".utf8)]),
        ]
      ),
      referenceUnixSeconds: 100
    )

    expectSemanticError(
      .duplicateObservationDecision,
      evaluation: validationEvaluation(),
      request: request
    )
  }

  @Test("Only exact direct-child input identities are valid")
  func rejectsNonTopLevelInput() {
    let nested = ScanRelativePath(rawComponents: [Array("a".utf8), Array("b".utf8)])
    let request = RuleClassificationRequest(
      root: URL(fileURLWithPath: "/synthetic", isDirectory: true),
      report: completeScanReport(topLevelItems: [ruleSummary(rawComponents: nested.rawComponents)]),
      referenceUnixSeconds: 100
    )

    expectPreflightError(.inputPathIsNotTopLevel(nested), report: request.report)
    expectValidationError(
      .inputPathIsNotTopLevel(nested),
      report: validationReport([]),
      request: request
    )
  }

  @Test("Scan preflight requires a directory root summary at the root path")
  func scanPreflightRootShape() throws {
    let valid = completeScanReport(topLevelItems: [])
    try ScanReportPreflight.validate(valid)

    let invalidRoots: [(ScanItemSummary, RuleClassificationReportValidationError)] = [
      (
        ruleSummary(rawComponents: [Array("not-root".utf8)]),
        .rootSummaryPathIsNotRoot(validationPath("not-root"))
      ),
      (
        ruleSummary(rawComponents: [], kind: .regularFile),
        .rootSummaryIsNotDirectory(.regularFile)
      ),
    ]

    for (root, expectedError) in invalidRoots {
      let report = ScanReport(
        root: root,
        topLevelItems: [],
        topLevelItemCount: 0,
        topLevelItemsWereSuppressed: false,
        hardLinkAccountingIsComplete: true,
        traversalDetailsWereDiscarded: false,
        issues: [],
        suppressedIssueCount: 0
      )
      let request = RuleClassificationRequest(
        root: URL(fileURLWithPath: "/synthetic", isDirectory: true),
        report: report,
        referenceUnixSeconds: 100
      )

      expectPreflightError(expectedError, report: report)
      expectValidationError(
        expectedError,
        report: validationReport([]),
        request: request
      )
    }
  }

  @Test("Malformed scan report structure is rejected before eligibility")
  func malformedScanReportStructure() {
    let item = ruleSummary(rawComponents: [Array("a".utf8)])
    let partialItem = ruleSummary(
      rawComponents: [Array("a".utf8)],
      isComplete: false
    )
    let root = ruleSummary(rawComponents: [], isComplete: true)
    let issue = ScanIssue(
      path: .root,
      operation: .listDirectory,
      reason: .ioFailure,
      impact: .descendantsSkipped
    )

    let malformedReports: [(ScanReport, RuleClassificationReportValidationError)] = [
      (
        ScanReport(
          root: root,
          topLevelItems: [item],
          topLevelItemCount: 2,
          topLevelItemsWereSuppressed: false,
          hardLinkAccountingIsComplete: true,
          traversalDetailsWereDiscarded: false,
          issues: [],
          suppressedIssueCount: 0
        ),
        .topLevelItemCountMismatch(reported: 2, retained: 1)
      ),
      (
        ScanReport(
          root: ruleSummary(rawComponents: [], isComplete: false),
          topLevelItems: [item],
          topLevelItemCount: 1,
          topLevelItemsWereSuppressed: true,
          hardLinkAccountingIsComplete: false,
          traversalDetailsWereDiscarded: false,
          issues: [],
          suppressedIssueCount: 0
        ),
        .suppressedTopLevelItemsRetained(actual: 1)
      ),
      (
        ScanReport(
          root: ruleSummary(rawComponents: [], isComplete: false),
          topLevelItems: [],
          topLevelItemCount: 0,
          topLevelItemsWereSuppressed: false,
          hardLinkAccountingIsComplete: true,
          traversalDetailsWereDiscarded: true,
          issues: [],
          suppressedIssueCount: 0
        ),
        .discardedTraversalStateIsInconsistent
      ),
      (
        ScanReport(
          root: root,
          topLevelItems: [],
          topLevelItemCount: 0,
          topLevelItemsWereSuppressed: false,
          hardLinkAccountingIsComplete: true,
          traversalDetailsWereDiscarded: false,
          issues: [issue],
          suppressedIssueCount: 0
        ),
        .rootMarkedCompleteWithScanIssues
      ),
      (
        ScanReport(
          root: root,
          topLevelItems: [partialItem],
          topLevelItemCount: 1,
          topLevelItemsWereSuppressed: false,
          hardLinkAccountingIsComplete: true,
          traversalDetailsWereDiscarded: false,
          issues: [],
          suppressedIssueCount: 0
        ),
        .completeReportContainsIncompleteItem(validationPath("a"))
      ),
    ]

    for (scanReport, expectedError) in malformedReports {
      expectValidationError(
        expectedError,
        report: validationReport([]),
        request: RuleClassificationRequest(
          root: URL(fileURLWithPath: "/synthetic", isDirectory: true),
          report: scanReport,
          referenceUnixSeconds: 100
        )
      )
    }
  }

  @Test("Scan-time identity coverage is all-or-none and remains on the root device")
  func scanTimeIdentityStructure() throws {
    let rootIdentity = FileIdentity(device: 10, inode: 20)
    let itemIdentity = FileIdentity(device: 10, inode: 30)
    let otherDeviceIdentity = FileIdentity(device: 11, inode: 30)
    let path = validationPath("a")

    let malformedReports: [(ScanReport, RuleClassificationReportValidationError)] = [
      (
        completeScanReport(
          topLevelItems: [
            ruleSummary(rawComponents: path.rawComponents, scanTimeIdentity: itemIdentity)
          ]
        ),
        .inconsistentScanTimeIdentityCoverage(path)
      ),
      (
        ScanReport(
          root: ruleSummary(rawComponents: [], scanTimeIdentity: rootIdentity),
          topLevelItems: [ruleSummary(rawComponents: path.rawComponents)],
          topLevelItemCount: 1,
          topLevelItemsWereSuppressed: false,
          hardLinkAccountingIsComplete: true,
          traversalDetailsWereDiscarded: false,
          issues: [],
          suppressedIssueCount: 0
        ),
        .inconsistentScanTimeIdentityCoverage(path)
      ),
      (
        ScanReport(
          root: ruleSummary(rawComponents: [], scanTimeIdentity: rootIdentity),
          topLevelItems: [
            ruleSummary(
              rawComponents: path.rawComponents,
              scanTimeIdentity: otherDeviceIdentity
            )
          ],
          topLevelItemCount: 1,
          topLevelItemsWereSuppressed: false,
          hardLinkAccountingIsComplete: true,
          traversalDetailsWereDiscarded: false,
          issues: [],
          suppressedIssueCount: 0
        ),
        .scanTimeIdentityDeviceMismatch(path)
      ),
    ]

    for (scanReport, expectedError) in malformedReports {
      expectPreflightError(expectedError, report: scanReport)
      expectValidationError(
        expectedError,
        report: validationReport([]),
        request: RuleClassificationRequest(
          root: URL(fileURLWithPath: "/synthetic", isDirectory: true),
          report: scanReport,
          referenceUnixSeconds: 100
        )
      )
    }

    let validReport = ScanReport(
      root: ruleSummary(rawComponents: [], scanTimeIdentity: rootIdentity),
      topLevelItems: [
        ruleSummary(rawComponents: path.rawComponents, scanTimeIdentity: itemIdentity),
        ruleSummary(rawComponents: [Array("b".utf8)], scanTimeIdentity: itemIdentity),
      ],
      topLevelItemCount: 2,
      topLevelItemsWereSuppressed: false,
      hardLinkAccountingIsComplete: true,
      traversalDetailsWereDiscarded: false,
      issues: [],
      suppressedIssueCount: 0
    )
    let validRequest = RuleClassificationRequest(
      root: URL(fileURLWithPath: "/synthetic", isDirectory: true),
      report: validReport,
      referenceUnixSeconds: 100
    )
    let validEvaluations = [
      validationEvaluation(path: path),
      validationEvaluation(path: validationPath("b")),
    ]
    try ScanReportPreflight.validate(validReport)
    do {
      try validationReport(validEvaluations).validate(for: validRequest)
    } catch {
      Issue.record("Expected same-device duplicate inode identities to validate: \(error)")
    }
  }

  @Test("Input, evaluation, per-evaluation, and total finding counts are bounded")
  func countBounds() {
    let baseRequest = validationRequest(names: ["a"])
    let baseEvaluation = validationEvaluation()

    let oversizedInput = completeScanReport(
      topLevelItems: Array(
        repeating: ruleSummary(rawComponents: [Array("a".utf8)]),
        count: RuleCatalogLimits.maximumObservations + 1
      )
    )
    expectValidationError(
      .tooManyInputItems(
        maximum: RuleCatalogLimits.maximumObservations,
        actual: RuleCatalogLimits.maximumObservations + 1
      ),
      report: validationReport([]),
      request: RuleClassificationRequest(
        root: baseRequest.root,
        report: oversizedInput,
        referenceUnixSeconds: baseRequest.referenceUnixSeconds
      )
    )

    expectValidationError(
      .tooManyEvaluations(
        maximum: RuleCatalogLimits.maximumObservations,
        actual: RuleCatalogLimits.maximumObservations + 1
      ),
      report: validationReport(
        Array(
          repeating: baseEvaluation,
          count: RuleCatalogLimits.maximumObservations + 1
        )
      ),
      request: baseRequest
    )

    let excessFindings = Array(
      repeating: validationFinding(),
      count: RuleCatalogLimits.maximumFindingsPerEvaluation + 1
    )
    expectValidationError(
      .tooManyFindings(
        path: validationPath("a"),
        maximum: RuleCatalogLimits.maximumFindingsPerEvaluation,
        actual: RuleCatalogLimits.maximumFindingsPerEvaluation + 1
      ),
      report: validationReport([validationEvaluation(findings: excessFindings)]),
      request: baseRequest
    )

    let maximumFindings = (0..<RuleCatalogLimits.maximumFindingsPerEvaluation).map { index in
      validationFinding(identifier: "finding\(index)")
    }
    let denseEvaluation = validationEvaluation(findings: maximumFindings)
    let denseCount =
      RuleCatalogLimits.maximumTotalEvaluationFindings
      / RuleCatalogLimits.maximumFindingsPerEvaluation + 1
    let actualTotal = denseCount * RuleCatalogLimits.maximumFindingsPerEvaluation
    expectValidationError(
      .tooManyTotalFindings(
        maximum: RuleCatalogLimits.maximumTotalEvaluationFindings,
        actual: actualTotal
      ),
      report: validationReport(Array(repeating: denseEvaluation, count: denseCount)),
      request: baseRequest
    )
  }

  @Test("Aggregate matching revisions and report identities are bounded")
  func aggregateIdentityBounds() {
    let revisions = (0..<4).map { index in
      validationRevision("devsift.validation.conflict" + String(index))
    }
    let evaluationCount =
      RuleCatalogLimits.maximumTotalMatchingRuleRevisions / revisions.count + 1
    let names = (0..<evaluationCount).map { String(format: "item-%05d", $0) }
    let items = names.map { name in
      ruleSummary(rawComponents: [Array(name.utf8)])
    }
    let conflicts = names.map { name in
      validationEvaluation(
        path: validationPath(name),
        rule: nil,
        matchingRules: revisions,
        matchState: .conflict,
        disposition: .protected,
        reproducibility: .unknown,
        findings: [
          validationFinding(
            identifier: AutomaticCheckIdentifier.ruleConflict.rawValue,
            kind: .conflict,
            state: .failed
          )
        ]
      )
    }
    expectValidationError(
      .tooManyTotalMatchingRuleRevisions(
        maximum: RuleCatalogLimits.maximumTotalMatchingRuleRevisions,
        actual: evaluationCount * revisions.count
      ),
      report: validationReport(conflicts),
      request: RuleClassificationRequest(
        root: URL(fileURLWithPath: "/synthetic", isDirectory: true),
        report: completeScanReport(topLevelItems: items),
        referenceUnixSeconds: 100
      )
    )

    let longRevisions = (0..<2).map { index in
      let prefix = "r\(index)"
      return validationRevision(prefix + String(repeating: "a", count: 128 - prefix.count))
    }
    let identityBytesPerEvaluation =
      longRevisions.reduce(0) { total, revision in
        total + revision.identifier.rawValue.utf8.count
          + String(revision.version.rawValue).utf8.count
      } + AutomaticCheckIdentifier.ruleConflict.rawValue.utf8.count
    let identityEvaluationCount =
      RuleCatalogLimits.maximumTotalReportIdentityUTF8Bytes / identityBytesPerEvaluation + 1
    let identityNames = (0..<identityEvaluationCount).map {
      String(format: "identity-%05d", $0)
    }
    let identityItems = identityNames.map { name in
      ruleSummary(rawComponents: [Array(name.utf8)])
    }
    let identityConflicts = identityNames.map { name in
      validationEvaluation(
        path: validationPath(name),
        rule: nil,
        matchingRules: longRevisions,
        matchState: .conflict,
        disposition: .protected,
        reproducibility: .unknown,
        findings: [
          validationFinding(
            identifier: AutomaticCheckIdentifier.ruleConflict.rawValue,
            kind: .conflict,
            state: .failed
          )
        ]
      )
    }
    expectValidationError(
      .totalReportIdentityTextTooLong(
        maximumBytes: RuleCatalogLimits.maximumTotalReportIdentityUTF8Bytes
      ),
      report: validationReport(identityConflicts),
      request: RuleClassificationRequest(
        root: URL(fileURLWithPath: "/synthetic", isDirectory: true),
        report: completeScanReport(topLevelItems: identityItems),
        referenceUnixSeconds: 100
      )
    )
  }

  @Test("Metadata, finding text, and total report text are bounded")
  func textBounds() {
    let request = validationRequest(names: ["a"])
    let metadataOverflow = String(
      repeating: "a",
      count: RuleCatalogLimits.maximumEvaluationMetadataUTF8Bytes + 1
    )
    let oversizedMetadataEvaluation = validationEvaluation(displayName: metadataOverflow)
    let actualMetadataBytes =
      oversizedMetadataEvaluation.displayName.utf8.count
      + oversizedMetadataEvaluation.responsibleTool.utf8.count
      + oversizedMetadataEvaluation.explanation.utf8.count
    expectValidationError(
      .metadataTooLarge(
        path: validationPath("a"),
        maximumBytes: RuleCatalogLimits.maximumEvaluationMetadataUTF8Bytes,
        actualBytes: actualMetadataBytes
      ),
      report: validationReport([oversizedMetadataEvaluation]),
      request: request
    )

    let findingOverflow = String(
      repeating: "a",
      count: RuleCatalogLimits.maximumRuntimeFindingTextUTF8Bytes + 1
    )
    expectValidationError(
      .findingTextTooLong(
        path: validationPath("a"),
        finding: testCheckIdentifier("evidence"),
        maximumBytes: RuleCatalogLimits.maximumRuntimeFindingTextUTF8Bytes,
        actualBytes: findingOverflow.utf8.count
      ),
      report: validationReport(
        [
          validationEvaluation(
            findings: [validationFinding(explanation: findingOverflow)]
          )
        ]
      ),
      request: request
    )

    let longMetadata = String(repeating: "m", count: 4_000)
    let longFinding = String(
      repeating: "f",
      count: RuleCatalogLimits.maximumRuntimeFindingTextUTF8Bytes
    )
    let requiredFindings = validationEligibleFindings(explanation: longFinding)
    let customFindingCount =
      RuleCatalogLimits.maximumFindingsPerEvaluation - requiredFindings.count
    let findings =
      requiredFindings
      + (0..<customFindingCount).map { index in
        validationFinding(identifier: "text-finding\(index)", explanation: longFinding)
      }
    let count =
      RuleCatalogLimits.maximumTotalReportTextUTF8Bytes
      / (longMetadata.utf8.count + longFinding.utf8.count * findings.count) + 1
    let names = (0..<count).map { "item\($0)" }.sorted()
    let evaluations = names.map { name in
      validationEvaluation(
        path: validationPath(name),
        displayName: longMetadata,
        findings: findings
      )
    }
    expectValidationError(
      .totalReportTextTooLong(
        maximumBytes: RuleCatalogLimits.maximumTotalReportTextUTF8Bytes
      ),
      report: validationReport(evaluations),
      request: validationRequest(names: names)
    )
  }

  @Test("Possible matches cannot claim a reclaimable disposition")
  func possibleMatchCannotBeReclaimable() {
    let evaluation = validationEvaluation(
      matchState: .possibleMatch,
      disposition: .reclaimable,
      findings: [validationFinding(state: .failed)]
    )
    expectSemanticError(
      .protectedDisposition,
      evaluation: evaluation
    )
  }

  @Test("Matched results require a rule, matching revision, and satisfied findings")
  func matchedSemantics() {
    expectSemanticError(
      .matchedRuleIdentity,
      evaluation: validationEvaluation(rule: nil, matchingRules: [])
    )
    expectSemanticError(
      .matchedRuleIdentity,
      evaluation: validationEvaluation(
        matchingRules: [validationRevision("devsift.validation.other")]
      )
    )
    expectSemanticError(
      .matchedFindings,
      evaluation: validationEvaluation(findings: [])
    )
    expectSemanticError(
      .matchedFindings,
      evaluation: validationEvaluation(findings: [validationFinding(state: .failed)])
    )
    expectSemanticError(
      .reclaimableReproducibility,
      evaluation: validationEvaluation(reproducibility: .conditional)
    )
    expectValidationError(
      .missingCommonFinding(
        path: validationPath("a"),
        finding: AutomaticCheckIdentifier.lexicalRecognition
      ),
      report: validationReport(
        [
          validationEvaluation(
            findings: validationRuleSpecificFindings()
              + [validationFinding(identifier: "custom")]
          )
        ]
      ),
      request: validationRequest(names: ["a"])
    )
  }

  @Test("Matched results require rule-specific positive evidence and an exclusion")
  func matchedEvidenceFloor() {
    expectSemanticError(
      .matchedPositiveEvidence,
      evaluation: validationEvaluation(findings: validationCommonFindings())
    )
    expectSemanticError(
      .matchedExclusion,
      evaluation: validationEvaluation(
        findings: validationCommonFindings()
          + [
            validationFinding(
              identifier: "rule-positive-evidence",
              kind: .positiveEvidence
            )
          ]
      )
    )
    expectSemanticError(
      .matchedPositiveEvidence,
      evaluation: validationEvaluation(
        findings: validationCommonFindings()
          + [
            validationFinding(
              identifier: AutomaticCheckIdentifier.ruleValidity.rawValue,
              kind: .positiveEvidence
            ),
            validationFinding(identifier: "rule-exclusion", kind: .exclusion),
          ]
      )
    )
  }

  @Test("Automatic reproducibility state is bound to the reported reproducibility")
  func reproducibilityBinding() {
    expectSemanticError(
      .matchedReproducibility,
      evaluation: validationEvaluation(
        disposition: .reviewRequired,
        reproducibility: .unknown
      )
    )

    let forgedUnknown = validationEvaluation(
      matchState: .possibleMatch,
      disposition: .protected,
      reproducibility: .unknown,
      findings: validationCommonFindings()
        + [
          validationFinding(
            identifier: "rule-positive-evidence",
            state: .failed
          ),
          validationFinding(identifier: "rule-exclusion", kind: .exclusion),
        ]
    )
    expectValidationError(
      .commonFindingStateMismatch(
        path: validationPath("a"),
        finding: AutomaticCheckIdentifier.reproducibility,
        expected: .unknown(.unspecified),
        actual: .satisfied
      ),
      report: validationReport([forgedUnknown]),
      request: validationRequest(names: ["a"])
    )

    let correctUnknown = validationEvaluation(
      matchState: .possibleMatch,
      disposition: .protected,
      reproducibility: .unknown,
      findings: validationCommonFindings(
        states: [AutomaticCheckIdentifier.reproducibility: .unknown(.unspecified)]
      )
        + [
          validationFinding(
            identifier: "rule-positive-evidence",
            state: .failed
          ),
          validationFinding(identifier: "rule-exclusion", kind: .exclusion),
        ]
    )
    do {
      try validationReport([correctUnknown]).validate(
        for: validationRequest(names: ["a"])
      )
      try validationReport([
        validationEvaluation(
          disposition: .reviewRequired,
          reproducibility: .conditional
        )
      ]).validate(for: validationRequest(names: ["a"]))
    } catch {
      Issue.record("Expected conservative reproducibility reports to validate: \(error)")
    }
  }

  @Test("Common finding kinds and scan-integrity states are request-bound")
  func commonFindingValidation() {
    var wrongKind = validationEligibleFindings()
    wrongKind[0] = validationFinding(
      identifier: AutomaticCheckIdentifier.lexicalRecognition.rawValue,
      kind: .positiveEvidence
    )
    expectValidationError(
      .commonFindingKindMismatch(
        path: validationPath("a"),
        finding: AutomaticCheckIdentifier.lexicalRecognition,
        expected: .lexicalRecognition,
        actual: .positiveEvidence
      ),
      report: validationReport([validationEvaluation(findings: wrongKind)]),
      request: validationRequest(names: ["a"])
    )

    let partialItem = ruleSummary(
      rawComponents: [Array("a".utf8)],
      isComplete: false,
      unknownAllocatedItemCount: 1,
      sizeOverflowed: true
    )
    let partialScan = ScanReport(
      root: ruleSummary(rawComponents: [], isComplete: false),
      topLevelItems: [partialItem],
      topLevelItemCount: 1,
      topLevelItemsWereSuppressed: false,
      hardLinkAccountingIsComplete: false,
      traversalDetailsWereDiscarded: false,
      issues: [],
      suppressedIssueCount: 1
    )
    let request = RuleClassificationRequest(
      root: URL(fileURLWithPath: "/synthetic", isDirectory: true),
      report: partialScan,
      referenceUnixSeconds: 100
    )
    let integrityIdentifiers = [
      AutomaticCheckIdentifier.reportComplete,
      AutomaticCheckIdentifier.itemComplete,
      AutomaticCheckIdentifier.topLevelOutputComplete,
      AutomaticCheckIdentifier.traversalDetailsRetained,
      AutomaticCheckIdentifier.issuesComplete,
      AutomaticCheckIdentifier.allocationKnown,
      AutomaticCheckIdentifier.sizeDidNotOverflow,
      AutomaticCheckIdentifier.hardLinksComplete,
    ]
    let expectedStates: [CheckIdentifier: RuleFindingState] = [
      AutomaticCheckIdentifier.reportComplete: .failed,
      AutomaticCheckIdentifier.itemComplete: .failed,
      AutomaticCheckIdentifier.topLevelOutputComplete: .satisfied,
      AutomaticCheckIdentifier.traversalDetailsRetained: .satisfied,
      AutomaticCheckIdentifier.issuesComplete: .failed,
      AutomaticCheckIdentifier.allocationKnown: .failed,
      AutomaticCheckIdentifier.sizeDidNotOverflow: .failed,
      AutomaticCheckIdentifier.hardLinksComplete: .failed,
    ]

    for identifier in integrityIdentifiers {
      let expectedState = expectedStates[identifier]!
      let forgedState: RuleFindingState = expectedState == .satisfied ? .failed : .satisfied
      var forgedStates = expectedStates
      forgedStates[identifier] = forgedState
      let evaluation = validationEvaluation(
        matchState: .possibleMatch,
        disposition: .protected,
        findings: validationCommonFindings(states: forgedStates)
      )
      expectValidationError(
        .commonFindingStateMismatch(
          path: validationPath("a"),
          finding: identifier,
          expected: expectedState,
          actual: forgedState
        ),
        report: validationReport([evaluation]),
        request: request
      )
    }
  }

  @Test("Finding identifiers and matching revisions are unique and ordered")
  func nestedIdentityValidation() {
    let duplicateFindings = [validationFinding(), validationFinding()]
    expectValidationError(
      .duplicateFindingIdentifier(
        path: validationPath("a"),
        finding: testCheckIdentifier("evidence")
      ),
      report: validationReport([validationEvaluation(findings: duplicateFindings)]),
      request: validationRequest(names: ["a"])
    )

    let first = validationRevision("devsift.validation.first")
    let second = validationRevision("devsift.validation.second")
    for matchingRules in [[second, first], [first, first]] {
      expectValidationError(
        .matchingRulesNotSortedAndUnique(validationPath("a")),
        report: validationReport(
          [
            validationEvaluation(
              rule: nil,
              matchingRules: matchingRules,
              matchState: .conflict,
              disposition: .protected,
              reproducibility: .unknown,
              findings: [
                validationFinding(
                  identifier: "rule-conflict",
                  kind: .conflict,
                  state: .failed
                )
              ]
            )
          ]
        ),
        request: validationRequest(names: ["a"])
      )
    }
  }

  @Test("Malformed conflict, unrecognized, and invalid-rule states are rejected")
  func malformedProtectedStates() {
    let revision = validationRuleRevision
    let other = validationRevision("devsift.validation.other")

    expectSemanticError(
      .conflictRuleIdentity,
      evaluation: validationEvaluation(
        rule: revision,
        matchingRules: [revision, other].sorted(),
        matchState: .conflict,
        disposition: .protected,
        findings: [
          validationFinding(identifier: "rule-conflict", kind: .conflict, state: .failed)
        ]
      )
    )
    expectSemanticError(
      .duplicateObservationDecision,
      evaluation: validationEvaluation(
        rule: nil,
        matchingRules: [],
        matchState: .conflict,
        disposition: .protected,
        findings: [
          validationFinding(
            identifier: AutomaticCheckIdentifier.duplicateObservation.rawValue,
            kind: .conflict,
            state: .failed
          )
        ]
      )
    )
    expectSemanticError(
      .unrecognizedRuleIdentity,
      evaluation: validationEvaluation(
        rule: revision,
        matchingRules: [revision],
        matchState: .unrecognized,
        disposition: .protected,
        findings: [validationFinding(state: .failed)]
      )
    )
    expectSemanticError(
      .unrecognizedDiagnostic,
      evaluation: validationEvaluation(
        rule: nil,
        matchingRules: [],
        matchState: .unrecognized,
        disposition: .protected,
        findings: [validationFinding(state: .failed)]
      )
    )
    expectSemanticError(
      .invalidRuleIdentity,
      evaluation: validationEvaluation(
        rule: nil,
        matchingRules: [],
        matchState: .invalidRule,
        disposition: .protected,
        findings: [
          validationFinding(identifier: "rule-validity", kind: .ruleValidity, state: .failed)
        ]
      )
    )
    expectSemanticError(
      .invalidRuleDiagnostic,
      evaluation: validationEvaluation(
        matchState: .invalidRule,
        disposition: .protected,
        findings: [validationFinding(state: .failed)]
      )
    )
  }

  private func expectSemanticError(
    _ invariant: RuleEvaluationInvariant,
    evaluation: RuleEvaluation,
    request: RuleClassificationRequest = validationRequest(names: ["a"])
  ) {
    expectValidationError(
      .semanticInvariant(path: evaluation.path, invariant: invariant),
      report: validationReport([evaluation]),
      request: request
    )
  }

  private func expectValidationError(
    _ expected: RuleClassificationReportValidationError,
    report: RuleClassificationReport,
    request: RuleClassificationRequest
  ) {
    do {
      try report.validate(for: request)
      Issue.record("Expected validation error \(expected)")
    } catch let error as RuleClassificationReportValidationError {
      #expect(error == expected)
    } catch {
      Issue.record("Expected \(expected), received \(error)")
    }
  }

  private func expectPreflightError(
    _ expected: RuleClassificationReportValidationError,
    report: ScanReport
  ) {
    do {
      try ScanReportPreflight.validate(report)
      Issue.record("Expected scan preflight error \(expected)")
    } catch let error as RuleClassificationReportValidationError {
      #expect(error == expected)
    } catch {
      Issue.record("Expected \(expected), received \(error)")
    }
  }
}

private let validationRuleRevision = RuleRevision(
  identifier: testRuleIdentifier("devsift.validation.rule"),
  version: testRuleVersion()
)

private func validationRevision(_ identifier: String) -> RuleRevision {
  RuleRevision(identifier: testRuleIdentifier(identifier), version: testRuleVersion())
}

private func validationPath(_ name: String) -> ScanRelativePath {
  ScanRelativePath(rawComponents: [Array(name.utf8)])
}

private func validationFinding(
  identifier: String = "evidence",
  kind: RuleFindingKind = .positiveEvidence,
  state: RuleFindingState = .satisfied,
  explanation: String = "The structured evidence is satisfied."
) -> RuleFinding {
  RuleFinding(
    identifier: testCheckIdentifier(identifier),
    kind: kind,
    state: state,
    explanation: explanation
  )
}

private func validationEvaluation(
  path: ScanRelativePath = validationPath("a"),
  rule: RuleRevision? = validationRuleRevision,
  matchingRules: [RuleRevision] = [validationRuleRevision],
  displayName: String = "Validation rule",
  responsibleTool: String = "Validation tool",
  matchState: RuleMatchState = .matched,
  disposition: RuleDisposition = .reclaimable,
  reproducibility: RuleReproducibility = .reproducible,
  findings: [RuleFinding]? = nil,
  explanation: String = "The result is internally consistent."
) -> RuleEvaluation {
  RuleEvaluation(
    path: path,
    rule: rule,
    matchingRules: matchingRules,
    displayName: displayName,
    responsibleTool: responsibleTool,
    matchState: matchState,
    disposition: disposition,
    reproducibility: reproducibility,
    findings: findings ?? validationEligibleFindings(),
    explanation: explanation
  )
}

private func validationCommonFindings(
  explanation: String = "The classifier-owned finding is satisfied.",
  states: [CheckIdentifier: RuleFindingState] = [:]
) -> [RuleFinding] {
  func state(_ identifier: CheckIdentifier) -> RuleFindingState {
    states[identifier] ?? .satisfied
  }

  return [
    validationFinding(
      identifier: AutomaticCheckIdentifier.lexicalRecognition.rawValue,
      kind: .lexicalRecognition,
      state: state(AutomaticCheckIdentifier.lexicalRecognition),
      explanation: explanation
    ),
    validationFinding(
      identifier: AutomaticCheckIdentifier.reproducibility.rawValue,
      kind: .reproducibility,
      state: state(AutomaticCheckIdentifier.reproducibility),
      explanation: explanation
    ),
    validationFinding(
      identifier: AutomaticCheckIdentifier.age.rawValue,
      kind: .age,
      state: state(AutomaticCheckIdentifier.age),
      explanation: explanation
    ),
    validationFinding(
      identifier: AutomaticCheckIdentifier.activity.rawValue,
      kind: .activity,
      state: state(AutomaticCheckIdentifier.activity),
      explanation: explanation
    ),
    validationFinding(
      identifier: AutomaticCheckIdentifier.reportComplete.rawValue,
      kind: .scanIntegrity,
      state: state(AutomaticCheckIdentifier.reportComplete),
      explanation: explanation
    ),
    validationFinding(
      identifier: AutomaticCheckIdentifier.itemComplete.rawValue,
      kind: .scanIntegrity,
      state: state(AutomaticCheckIdentifier.itemComplete),
      explanation: explanation
    ),
    validationFinding(
      identifier: AutomaticCheckIdentifier.topLevelOutputComplete.rawValue,
      kind: .scanIntegrity,
      state: state(AutomaticCheckIdentifier.topLevelOutputComplete),
      explanation: explanation
    ),
    validationFinding(
      identifier: AutomaticCheckIdentifier.traversalDetailsRetained.rawValue,
      kind: .scanIntegrity,
      state: state(AutomaticCheckIdentifier.traversalDetailsRetained),
      explanation: explanation
    ),
    validationFinding(
      identifier: AutomaticCheckIdentifier.issuesComplete.rawValue,
      kind: .scanIntegrity,
      state: state(AutomaticCheckIdentifier.issuesComplete),
      explanation: explanation
    ),
    validationFinding(
      identifier: AutomaticCheckIdentifier.allocationKnown.rawValue,
      kind: .scanIntegrity,
      state: state(AutomaticCheckIdentifier.allocationKnown),
      explanation: explanation
    ),
    validationFinding(
      identifier: AutomaticCheckIdentifier.sizeDidNotOverflow.rawValue,
      kind: .scanIntegrity,
      state: state(AutomaticCheckIdentifier.sizeDidNotOverflow),
      explanation: explanation
    ),
    validationFinding(
      identifier: AutomaticCheckIdentifier.hardLinksComplete.rawValue,
      kind: .scanIntegrity,
      state: state(AutomaticCheckIdentifier.hardLinksComplete),
      explanation: explanation
    ),
  ]
}

private func validationRuleSpecificFindings(
  explanation: String = "The rule-specific finding is satisfied."
) -> [RuleFinding] {
  [
    validationFinding(
      identifier: "rule-positive-evidence",
      kind: .positiveEvidence,
      explanation: explanation
    ),
    validationFinding(
      identifier: "rule-exclusion",
      kind: .exclusion,
      explanation: explanation
    ),
  ]
}

private func validationEligibleFindings(
  explanation: String = "The classifier-owned finding is satisfied."
) -> [RuleFinding] {
  validationCommonFindings(explanation: explanation)
    + validationRuleSpecificFindings(explanation: explanation)
}

private func validationReport(
  _ evaluations: [RuleEvaluation],
  referenceUnixSeconds: Int64 = 100
) -> RuleClassificationReport {
  RuleClassificationReport(
    referenceUnixSeconds: referenceUnixSeconds,
    evaluations: evaluations
  )
}

private func validationRequest(
  names: [String],
  referenceUnixSeconds: Int64 = 100
) -> RuleClassificationRequest {
  RuleClassificationRequest(
    root: URL(fileURLWithPath: "/synthetic", isDirectory: true),
    report: completeScanReport(
      topLevelItems: names.map { name in
        ruleSummary(rawComponents: [Array(name.utf8)])
      }
    ),
    referenceUnixSeconds: referenceUnixSeconds
  )
}
