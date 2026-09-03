import Foundation
import Testing

@testable import DevSiftCore

@Suite("Cleanup planner fail-closed boundaries")
struct CleanupPlannerFailureTests {
  @Test("Classification output is validated again before planning")
  func invalidClassificationReport() async throws {
    let uv = PlanningTestCandidate(
      rawName: Array("uv".utf8),
      identity: FileIdentity(device: 42, inode: 2)
    )
    let scenario = try await makePlanningTestScenario(candidates: [uv])
    let selection = scenario.selection(for: uv.path)
    let wrongReference = scenario.classificationRequest.referenceUnixSeconds + 1
    let tamperedReference = planningClassificationReport(
      scenario.classificationReport,
      referenceUnixSeconds: wrongReference
    )

    expectPlanningError(
      .invalidClassificationReport(
        .referenceTimeMismatch(
          expected: scenario.classificationRequest.referenceUnixSeconds,
          actual: wrongReference
        )
      ),
      request: scenario.manifestRequest(
        selections: [selection],
        classificationReport: tamperedReference
      )
    )

    let evaluation = scenario.classificationReport.evaluations[0]
    let firstFinding = evaluation.findings[0]
    let failedFinding = RuleFinding(
      identifier: firstFinding.identifier,
      kind: firstFinding.kind,
      state: .failed,
      explanation: firstFinding.explanation
    )
    let tamperedFindings = [failedFinding] + evaluation.findings.dropFirst()
    let tamperedEvaluation = planningEvaluation(evaluation, findings: tamperedFindings)
    let tamperedReport = planningClassificationReport(
      scenario.classificationReport,
      evaluations: [tamperedEvaluation]
    )

    expectPlanningError(
      .invalidClassificationReport(
        .semanticInvariant(path: uv.path, invariant: .matchedFindings)
      ),
      request: scenario.manifestRequest(
        selections: [selection],
        classificationReport: tamperedReport
      )
    )
  }

  @Test("Partial scans and missing root identities cannot produce drafts")
  func rootPreconditions() async throws {
    let rootIdentity = FileIdentity(device: 42, inode: 1)
    let partialReport = ScanReport(
      root: ruleSummary(
        rawComponents: [],
        scanTimeIdentity: rootIdentity,
        isComplete: false
      ),
      topLevelItems: [],
      topLevelItemCount: 0,
      topLevelItemsWereSuppressed: false,
      hardLinkAccountingIsComplete: false,
      traversalDetailsWereDiscarded: false,
      issues: [],
      suppressedIssueCount: 0
    )
    let partialClassificationRequest = RuleClassificationRequest(
      root: URL(fileURLWithPath: "/synthetic/Caches", isDirectory: true),
      report: partialReport,
      referenceUnixSeconds: 100
    )
    let emptyClassificationReport = RuleClassificationReport(
      referenceUnixSeconds: 100,
      evaluations: [],
      policyProvenance: try builtInTestPolicyProvenance(),
      sourceBinding: nil
    ).binding(to: partialClassificationRequest)
    expectPlanningError(
      .incompleteScan,
      request: CleanupManifestRequest(
        classificationRequest: partialClassificationRequest,
        classificationReport: emptyClassificationReport,
        selections: []
      )
    )

    let missingIdentity = try await makePlanningTestScenario(
      candidates: [],
      rootIdentity: nil
    )
    expectPlanningError(
      .missingRootIdentity,
      request: missingIdentity.manifestRequest(selections: [])
    )
  }

  @Test("Planning requires an exact classifier source-request binding")
  func sourceRequestBinding() async throws {
    let sourceCandidate = PlanningTestCandidate(
      rawName: Array("uv".utf8),
      identity: FileIdentity(device: 42, inode: 2),
      recursiveSize: StorageSize(logicalBytes: 1_000, allocatedBytes: 900),
      hardLinkExclusiveAllocatedBytes: 800
    )
    let changedCandidate = PlanningTestCandidate(
      rawName: Array("uv".utf8),
      identity: FileIdentity(device: 42, inode: 3),
      recursiveSize: StorageSize(logicalBytes: 2_000, allocatedBytes: 1_900),
      hardLinkExclusiveAllocatedBytes: 1_800
    )
    let source = try await makePlanningTestScenario(candidates: [sourceCandidate])
    let changed = try await makePlanningTestScenario(candidates: [changedCandidate])
    let selection = source.selection(for: sourceCandidate.path)

    expectPlanningError(
      .invalidClassificationReport(.sourceRequestMismatch),
      request: CleanupManifestRequest(
        classificationRequest: changed.classificationRequest,
        classificationReport: source.classificationReport,
        selections: [selection]
      )
    )

    let changedSizeCandidate = PlanningTestCandidate(
      rawName: Array("uv".utf8),
      identity: sourceCandidate.identity,
      recursiveSize: StorageSize(logicalBytes: 1_001, allocatedBytes: 901),
      hardLinkExclusiveAllocatedBytes: 801,
      possibleSharedContentFileCount: 1
    )
    let changedSize = try await makePlanningTestScenario(candidates: [changedSizeCandidate])
    expectPlanningError(
      .invalidClassificationReport(.sourceRequestMismatch),
      request: CleanupManifestRequest(
        classificationRequest: changedSize.classificationRequest,
        classificationReport: source.classificationReport,
        selections: [selection]
      )
    )

    let changedRootRequest = RuleClassificationRequest(
      root: URL(fileURLWithPath: "/synthetic/OtherCaches", isDirectory: true),
      report: source.classificationRequest.report,
      referenceUnixSeconds: source.classificationRequest.referenceUnixSeconds
    )
    expectPlanningError(
      .invalidClassificationReport(.sourceRequestMismatch),
      request: CleanupManifestRequest(
        classificationRequest: changedRootRequest,
        classificationReport: source.classificationReport,
        selections: [selection]
      )
    )

    let unboundReport = RuleClassificationReport(
      referenceUnixSeconds: source.classificationReport.referenceUnixSeconds,
      evaluations: source.classificationReport.evaluations
    )
    expectPlanningError(
      .classificationReportIsNotSourceBound,
      request: source.manifestRequest(
        selections: [selection],
        classificationReport: unboundReport
      )
    )
  }

  @Test("Planning requires classifier-sealed policy provenance and declared rules")
  func policyProvenance() async throws {
    let candidate = PlanningTestCandidate(
      rawName: Array("candidate".utf8),
      identity: FileIdentity(device: 42, inode: 2)
    )
    let definition = syntheticDefinition(id: "devsift.test.policy-candidate")
    let rule = SyntheticRule(definition: definition)
    let scenario = try await makePlanningTestScenario(
      candidates: [candidate],
      rules: [rule]
    )
    let selection = scenario.selection(for: candidate.path)

    let presentationClassifier = try ExplainableRuleClassifier(rules: [rule])
    let unprovenanced = try await presentationClassifier.classify(
      observations: [candidate.observation],
      referenceUnixSeconds: scenario.classificationRequest.referenceUnixSeconds
    ).binding(to: scenario.classificationRequest)
    #expect(unprovenanced.isSourceBound(to: scenario.classificationRequest))
    expectPlanningError(
      .missingPolicyProvenance,
      request: scenario.manifestRequest(
        selections: [selection],
        classificationReport: unprovenanced
      )
    )

    let emptyRoster = try RulePolicyProvenance(
      classificationContractRevision: ExplainableRuleClassifier.classificationContractRevision,
      catalogRevision: planningTestCatalogRevision,
      ruleRevisions: []
    )
    let undeclaredRule = RuleClassificationReport(
      referenceUnixSeconds: scenario.classificationReport.referenceUnixSeconds,
      evaluations: scenario.classificationReport.evaluations,
      policyProvenance: emptyRoster,
      sourceBinding: nil
    ).binding(to: scenario.classificationRequest)
    expectPlanningError(
      .invalidClassificationReport(
        .undeclaredPolicyRuleRevision(
          path: candidate.path,
          revision: definition.revision
        )
      ),
      request: scenario.manifestRequest(
        selections: [selection],
        classificationReport: undeclaredRule
      )
    )

    let editedProvenance = try RulePolicyProvenance(
      classificationContractRevision: ExplainableRuleClassifier.classificationContractRevision,
      catalogRevision: RuleRevision(
        identifier: planningTestCatalogRevision.identifier,
        version: testRuleVersion(2)
      ),
      ruleRevisions: [definition.revision]
    )
    let editedAfterBinding = RuleClassificationReport(
      referenceUnixSeconds: scenario.classificationReport.referenceUnixSeconds,
      evaluations: scenario.classificationReport.evaluations,
      policyProvenance: editedProvenance,
      sourceBinding: scenario.classificationReport.sourceBinding
    )
    expectPlanningError(
      .invalidClassificationReport(.sourcePolicyProvenanceMismatch),
      request: scenario.manifestRequest(
        selections: [selection],
        classificationReport: editedAfterBinding
      )
    )
  }

  @Test("Duplicate, missing, ambiguous, and stale selections fail atomically")
  func selectionBinding() async throws {
    let uv = PlanningTestCandidate(
      rawName: Array("uv".utf8),
      identity: FileIdentity(device: 42, inode: 2)
    )
    let scenario = try await makePlanningTestScenario(candidates: [uv])
    let selection = scenario.selection(for: uv.path)

    expectPlanningError(
      .duplicateSelection(uv.path),
      request: scenario.manifestRequest(selections: [selection, selection])
    )

    let missingPath = ScanRelativePath(rawComponents: [Array("missing".utf8)])
    expectPlanningError(
      .selectionNotFound(missingPath),
      request: scenario.manifestRequest(
        selections: [
          CleanupCandidateSelection(path: missingPath, ruleRevision: selection.ruleRevision)
        ]
      )
    )

    let staleRevision = RuleRevision(
      identifier: selection.ruleRevision.identifier,
      version: testRuleVersion(selection.ruleRevision.version.rawValue + 1)
    )
    expectPlanningError(
      .ruleRevisionMismatch(
        path: uv.path,
        selected: staleRevision,
        classified: selection.ruleRevision
      ),
      request: scenario.manifestRequest(
        selections: [CleanupCandidateSelection(path: uv.path, ruleRevision: staleRevision)]
      )
    )

    let duplicateCandidates = [
      PlanningTestCandidate(
        rawName: Array("duplicate".utf8),
        identity: FileIdentity(device: 42, inode: 3)
      ),
      PlanningTestCandidate(
        rawName: Array("duplicate".utf8),
        identity: FileIdentity(device: 42, inode: 4)
      ),
    ]
    let duplicateScenario = try await makePlanningTestScenario(
      candidates: duplicateCandidates,
      rules: [SyntheticRule(definition: syntheticDefinition(id: "devsift.test.duplicate"))]
    )
    let duplicatePath = duplicateCandidates[0].path
    expectPlanningError(
      .ambiguousSelection(duplicatePath),
      request: duplicateScenario.manifestRequest(
        selections: [CleanupCandidateSelection(path: duplicatePath, ruleRevision: staleRevision)]
      )
    )
  }

  @Test("A selected protected decision rejects the complete request")
  func protectedSelection() async throws {
    let blockedFacts = RuleObservationFacts(
      trustedLocation: .unknown(.notCollected),
      toolOwnership: .known(true),
      generatedContentMarker: .known(true),
      newestContentModificationUnixSeconds: .known(0),
      activity: .known(.inactive),
      protectedDescendantPresent: .known(false),
      siblingPackageManifestPresent: .known(true)
    )
    let uv = PlanningTestCandidate(
      rawName: Array("uv".utf8),
      identity: FileIdentity(device: 42, inode: 2)
    )
    let npm = PlanningTestCandidate(
      rawName: Array("_cacache".utf8),
      identity: FileIdentity(device: 42, inode: 3),
      facts: blockedFacts
    )
    let scenario = try await makePlanningTestScenario(candidates: [uv, npm])
    let npmSelection = scenario.selection(for: npm.path)

    expectPlanningError(
      .ineligibleCandidate(
        path: npm.path,
        matchState: .possibleMatch,
        disposition: .protected
      ),
      request: scenario.manifestRequest(
        selections: [scenario.selection(for: uv.path), npmSelection]
      )
    )
  }

  @Test("Every non-matched policy state remains ineligible")
  func nonMatchedStates() async throws {
    let ordinary = PlanningTestCandidate(
      rawName: Array("ordinary".utf8),
      identity: FileIdentity(device: 42, inode: 2)
    )
    let unrecognized = try await makePlanningTestScenario(candidates: [ordinary])

    let conflictRules: [any ExplainableRule] = [
      SyntheticRule(definition: syntheticDefinition(id: "devsift.test.conflict-a")),
      SyntheticRule(definition: syntheticDefinition(id: "devsift.test.conflict-b")),
    ]
    let conflict = try await makePlanningTestScenario(
      candidates: [ordinary],
      rules: conflictRules
    )

    let malformed = SyntheticRule(
      definition: syntheticDefinition(id: "devsift.test.invalid"),
      findings: []
    )
    let invalid = try await makePlanningTestScenario(
      candidates: [ordinary],
      rules: [malformed]
    )
    let placeholderRevision = syntheticDefinition(id: "devsift.test.selection").revision

    let cases: [(PlanningTestScenario, RuleMatchState)] = [
      (unrecognized, .unrecognized),
      (conflict, .conflict),
      (invalid, .invalidRule),
    ]
    for (scenario, expectedState) in cases {
      expectPlanningError(
        .ineligibleCandidate(
          path: ordinary.path,
          matchState: expectedState,
          disposition: .protected
        ),
        request: scenario.manifestRequest(
          selections: [
            CleanupCandidateSelection(
              path: ordinary.path,
              ruleRevision: placeholderRevision
            )
          ]
        )
      )
    }
  }

  @Test("Hostile raw path components are rejected before lookup")
  func invalidSelectionPaths() async throws {
    let uv = PlanningTestCandidate(
      rawName: Array("uv".utf8),
      identity: FileIdentity(device: 42, inode: 2)
    )
    let scenario = try await makePlanningTestScenario(candidates: [uv])
    let revision = scenario.selection(for: uv.path).ruleRevision
    let cases: [(ScanRelativePath, CleanupPlanPathIssue)] = [
      (.root, .notTopLevel),
      (ScanRelativePath(rawComponents: [[0x61], [0x62]]), .notTopLevel),
      (ScanRelativePath(rawComponents: [[]]), .emptyComponent),
      (ScanRelativePath(rawComponents: [[0x2E]]), .currentDirectoryComponent),
      (ScanRelativePath(rawComponents: [[0x2E, 0x2E]]), .parentDirectoryComponent),
      (ScanRelativePath(rawComponents: [[0x61, 0, 0x62]]), .containsNullByte),
      (ScanRelativePath(rawComponents: [[0x61, 0x2F, 0x62]]), .containsPathSeparator),
      (
        ScanRelativePath(
          rawComponents: [
            Array(repeating: 0x61, count: CleanupPlanningLimits.maximumCandidateComponentBytes + 1)
          ]
        ),
        .componentTooLong(
          maximum: CleanupPlanningLimits.maximumCandidateComponentBytes,
          actual: CleanupPlanningLimits.maximumCandidateComponentBytes + 1
        )
      ),
    ]

    for (path, issue) in cases {
      expectPlanningError(
        .invalidSelectionPath(path: path, issue: issue),
        request: scenario.manifestRequest(
          selections: [CleanupCandidateSelection(path: path, ruleRevision: revision)]
        )
      )
    }
  }

  @Test("Only complete same-device directory observations can be planned")
  func identityAndKindBoundaries() async throws {
    let definition = syntheticDefinition(id: "devsift.test.boundary")
    let file = PlanningTestCandidate(
      rawName: Array("file".utf8),
      identity: FileIdentity(device: 42, inode: 2),
      kind: .regularFile
    )
    let fileScenario = try await makePlanningTestScenario(
      candidates: [file],
      rules: [SyntheticRule(definition: definition)]
    )
    expectPlanningError(
      .unsupportedCandidateKind(path: file.path, kind: .regularFile),
      request: fileScenario.manifestRequest(selections: [fileScenario.selection(for: file.path)])
    )

    let missingIdentity = PlanningTestCandidate(
      rawName: Array("missing-identity".utf8),
      identity: nil
    )
    let missingScenario = try await makePlanningTestScenario(
      candidates: [missingIdentity],
      rules: [SyntheticRule(definition: definition)]
    )
    expectPlanningError(
      .invalidClassificationReport(
        .inconsistentScanTimeIdentityCoverage(missingIdentity.path)
      ),
      request: missingScenario.manifestRequest(
        selections: [
          CleanupCandidateSelection(path: missingIdentity.path, ruleRevision: definition.revision)
        ]
      )
    )

    let otherDevice = PlanningTestCandidate(
      rawName: Array("other-device".utf8),
      identity: FileIdentity(device: 99, inode: 3)
    )
    let otherDeviceScenario = try await makePlanningTestScenario(
      candidates: [otherDevice],
      rules: [SyntheticRule(definition: definition)]
    )
    expectPlanningError(
      .invalidClassificationReport(.scanTimeIdentityDeviceMismatch(otherDevice.path)),
      request: otherDeviceScenario.manifestRequest(
        selections: [otherDeviceScenario.selection(for: otherDevice.path)]
      )
    )
  }

  @Test("Invalid size relationships and aggregate overflow fail closed")
  func sizeBoundaries() async throws {
    let definition = syntheticDefinition(id: "devsift.test.size")
    let invalid = PlanningTestCandidate(
      rawName: Array("invalid-size".utf8),
      identity: FileIdentity(device: 42, inode: 2),
      recursiveSize: StorageSize(logicalBytes: 10, allocatedBytes: 10),
      hardLinkExclusiveAllocatedBytes: 11
    )
    let invalidScenario = try await makePlanningTestScenario(
      candidates: [invalid],
      rules: [SyntheticRule(definition: definition)]
    )
    expectPlanningError(
      .invalidSize(invalid.path),
      request: invalidScenario.manifestRequest(
        selections: [invalidScenario.selection(for: invalid.path)]
      )
    )

    let maximum = PlanningTestCandidate(
      rawName: Array("a".utf8),
      identity: FileIdentity(device: 42, inode: 3),
      recursiveSize: StorageSize(logicalBytes: 0, allocatedBytes: UInt64.max),
      hardLinkExclusiveAllocatedBytes: 0
    )
    let one = PlanningTestCandidate(
      rawName: Array("b".utf8),
      identity: FileIdentity(device: 42, inode: 4),
      recursiveSize: StorageSize(logicalBytes: 0, allocatedBytes: 1),
      hardLinkExclusiveAllocatedBytes: 0
    )
    let overflowScenario = try await makePlanningTestScenario(
      candidates: [maximum, one],
      rules: [SyntheticRule(definition: definition)]
    )
    let selections = overflowScenario.classificationReport.evaluations.map { evaluation in
      CleanupCandidateSelection(path: evaluation.path, ruleRevision: definition.revision)
    }
    expectPlanningError(
      .totalOverflow(.observedAllocatedBytes),
      request: overflowScenario.manifestRequest(selections: selections)
    )

    let counterMaximum = PlanningTestCandidate(
      rawName: Array("c".utf8),
      identity: FileIdentity(device: 42, inode: 5),
      recursiveSize: .zero,
      hardLinkExclusiveAllocatedBytes: 0,
      possibleSharedContentFileCount: UInt64.max
    )
    let counterOne = PlanningTestCandidate(
      rawName: Array("d".utf8),
      identity: FileIdentity(device: 42, inode: 6),
      recursiveSize: .zero,
      hardLinkExclusiveAllocatedBytes: 0,
      possibleSharedContentFileCount: 1
    )
    let counterScenario = try await makePlanningTestScenario(
      candidates: [counterMaximum, counterOne],
      rules: [SyntheticRule(definition: definition)]
    )
    let counterSelections = counterScenario.classificationReport.evaluations.map { evaluation in
      CleanupCandidateSelection(path: evaluation.path, ruleRevision: definition.revision)
    }
    expectPlanningError(
      .totalOverflow(.possibleSharedContentFileCount),
      request: counterScenario.manifestRequest(selections: counterSelections)
    )
  }

  @Test("Selection count is bounded before duplicate processing")
  func selectionLimit() async throws {
    let uv = PlanningTestCandidate(
      rawName: Array("uv".utf8),
      identity: FileIdentity(device: 42, inode: 2)
    )
    let scenario = try await makePlanningTestScenario(candidates: [uv])
    let selection = scenario.selection(for: uv.path)
    let selections = Array(
      repeating: selection,
      count: CleanupPlanningLimits.maximumSelections + 1
    )

    expectPlanningError(
      .tooManySelections(
        maximum: CleanupPlanningLimits.maximumSelections,
        actual: CleanupPlanningLimits.maximumSelections + 1
      ),
      request: scenario.manifestRequest(selections: selections)
    )
  }

  @Test("Planning leaves selected and outside fixture trees unchanged")
  func noFilesystemMutation() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }
    try fixture.write("candidate/payload.bin", bytes: [1, 2, 3])
    try fixture.write("sentinel.bin", bytes: [4, 5, 6], under: fixture.outside)

    let beforeRoot = try treeSnapshot(at: fixture.root)
    let beforeOutside = try treeSnapshot(at: fixture.outside)
    let uv = PlanningTestCandidate(
      rawName: Array("uv".utf8),
      identity: FileIdentity(device: 42, inode: 2)
    )
    let scenario = try await makePlanningTestScenario(candidates: [uv])
    let boundClassificationRequest = RuleClassificationRequest(
      root: fixture.root,
      report: scenario.classificationRequest.report,
      referenceUnixSeconds: scenario.classificationRequest.referenceUnixSeconds
    )
    let boundClassificationReport = scenario.classificationReport.binding(
      to: boundClassificationRequest
    )
    let selection = scenario.selection(for: uv.path)
    let request = CleanupManifestRequest(
      classificationRequest: boundClassificationRequest,
      classificationReport: boundClassificationReport,
      selections: [selection]
    )
    _ = try CleanupPlanner().makeManifest(request)

    expectPlanningError(
      .duplicateSelection(uv.path),
      request: CleanupManifestRequest(
        classificationRequest: boundClassificationRequest,
        classificationReport: boundClassificationReport,
        selections: [selection, selection]
      )
    )

    #expect(try treeSnapshot(at: fixture.root) == beforeRoot)
    #expect(try treeSnapshot(at: fixture.outside) == beforeOutside)
  }

  @Test("The public scan and classification pipeline cannot plan unknown real evidence")
  func publicPipelineRemainsProtected() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }
    try fixture.makeDirectory("uv")
    try fixture.write("uv/payload.bin", bytes: [1, 2, 3])
    let before = try treeSnapshot(at: fixture.container)

    let scanReport = try await AllocatedSizeScanner().scan(root: fixture.root)
    let classificationRequest = RuleClassificationRequest(
      root: fixture.root,
      report: scanReport,
      referenceUnixSeconds: 2_000_000
    )
    let classificationReport = try await ExplainableRuleClassifier().classify(
      classificationRequest
    )
    let evaluation = try #require(classificationReport.evaluations.first)
    let revision = try #require(evaluation.rule)

    #expect(classificationReport.isSourceBound(to: classificationRequest))
    #expect(evaluation.matchState == .possibleMatch)
    #expect(evaluation.disposition == .protected)
    expectPlanningError(
      .ineligibleCandidate(
        path: evaluation.path,
        matchState: .possibleMatch,
        disposition: .protected
      ),
      request: CleanupManifestRequest(
        classificationRequest: classificationRequest,
        classificationReport: classificationReport,
        selections: [
          CleanupCandidateSelection(path: evaluation.path, ruleRevision: revision)
        ]
      )
    )
    #expect(try treeSnapshot(at: fixture.container) == before)
  }

  @Test("A cancelled task cannot produce a manifest")
  func cancellation() async throws {
    let scenario = try await makePlanningTestScenario(candidates: [])
    let request = scenario.manifestRequest(selections: [])
    let task = Task {
      withUnsafeCurrentTask { currentTask in
        currentTask?.cancel()
      }
      return try CleanupPlanner().makeManifest(request)
    }

    switch await task.result {
    case .success:
      Issue.record("A cancelled planner unexpectedly returned a manifest")
    case .failure(let error):
      #expect(error is CancellationError)
    }
  }
}

private func expectPlanningError(
  _ expected: CleanupPlanningError,
  request: CleanupManifestRequest
) {
  do {
    _ = try CleanupPlanner().makeManifest(request)
    Issue.record("Expected planning to fail with \(expected)")
  } catch let error as CleanupPlanningError {
    #expect(error == expected)
  } catch {
    Issue.record("Unexpected planning error: \(error)")
  }
}
