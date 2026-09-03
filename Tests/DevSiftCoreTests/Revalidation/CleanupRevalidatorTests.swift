import Foundation
import Testing

@testable import DevSiftCore

@Suite("Cleanup execution revalidation")
struct CleanupRevalidatorTests {
  @Test("A revalidator receives only the approved root and returns canonical eligible diagnostics")
  func stableEligibleFlow() async throws {
    let (source, approval) = try await revalidationApproval()
    let scanLog = RevalidationRequestLog<ScanRequest>()
    let classificationLog = RevalidationRequestLog<RuleClassificationRequest>()
    let revalidator = CleanupRevalidator(
      scanner: RevalidationStubScanner { request in
        await scanLog.append(request)
        return source.classificationRequest.report
      },
      classifier: RevalidationStubClassifier { request in
        await classificationLog.append(request)
        return boundRevalidationReport(request: request, source: source)
      },
      referenceTime: { 2_000_000 },
      supportedPolicyProvenance: approval.reviewedManifest.policyProvenance
    )

    let report = try await revalidator.revalidate(approval)

    #expect(await scanLog.snapshot().map(\.root) == [approval.sourceRoot])
    #expect(await classificationLog.snapshot().map(\.root) == [approval.sourceRoot])
    #expect(report.contractVersion == CleanupRevalidationReport.currentContractVersion)
    #expect(report.observedRootIdentity == approval.reviewedManifest.expectedRootIdentity)
    #expect(report.policyProvenance == approval.reviewedManifest.policyProvenance)
    #expect(report.referenceUnixSeconds == 2_000_000)
    #expect(report.entries.map(\.path) == approval.reviewedManifest.entries.map(\.path))
    #expect(
      report.entries.map(\.ruleRevision) == approval.reviewedManifest.entries.map(\.ruleRevision))
    #expect(report.entries.allSatisfy { $0.status == .eligibleAtObservation })
    #expect(report.isFullyEligibleAtObservation)
    #expect(!report.grantsFilesystemMutationAuthority)
    #expect(report.requiresImmediateExecutionRevalidation)
    #expect(!isEncodableRevalidationValue(report))
  }

  @Test("The default built-in composition rejects a fresh observation with uncollected evidence")
  func defaultBuiltInFailsClosedOnUncollectedEvidence() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }
    try fixture.makeDirectory("uv")
    try fixture.write("sentinel", bytes: [9], under: fixture.outside)
    let beforeRoot = try treeSnapshot(at: fixture.root)
    let beforeOutside = try treeSnapshot(at: fixture.outside)
    let scanReport = try await AllocatedSizeScanner().scan(root: fixture.root)
    let candidate = try #require(scanReport.topLevelItems.first)
    let referenceUnixSeconds: Int64 = 2_000_000
    let classificationRequest = RuleClassificationRequest(
      root: fixture.root,
      report: scanReport,
      referenceUnixSeconds: referenceUnixSeconds
    )
    let classificationReport = try await ExplainableRuleClassifier().classify(
      observations: [
        RuleObservation(
          summary: candidate,
          selectedRootBasename: .known(Array("root".utf8)),
          integrity: completeRuleIntegrity(),
          facts: satisfiedRuleFacts()
        )
      ],
      referenceUnixSeconds: referenceUnixSeconds
    ).binding(to: classificationRequest)
    let manifestRequest = CleanupManifestRequest(
      classificationRequest: classificationRequest,
      classificationReport: classificationReport,
      selections: [
        CleanupCandidateSelection(
          path: candidate.path,
          ruleRevision: try #require(classificationReport.evaluations.first?.rule)
        )
      ]
    )
    let approver = CleanupApprover()
    let session = try approver.beginReview(manifestRequest)
    let approval = try approver.approve(
      CleanupApprovalRequest(
        session: session,
        confirmations: try approvalConfirmations(from: session)
      )
    )

    let result = try await CleanupRevalidator().revalidate(approval)

    #expect(result.entries.count == 1)
    guard case .rejected(.blockingFinding) = result.entries[0].status else {
      Issue.record("Missing fresh rule evidence unexpectedly became eligible")
      return
    }
    #expect(!result.isFullyEligibleAtObservation)
    #expect(try treeSnapshot(at: fixture.root) == beforeRoot)
    #expect(try treeSnapshot(at: fixture.outside) == beforeOutside)
  }

  @Test(
    "A real fresh scan reports removed and outside symlink candidates without following or mutating"
  )
  func realScannerCandidateChangesStayContained() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }
    try fixture.write("a-cache/payload", bytes: [1])
    try fixture.write("b-cache/payload", bytes: [2])
    try fixture.write("outside-sentinel", bytes: [3], under: fixture.outside)
    let approval = try await actualSyntheticRevalidationApproval(
      root: fixture.root,
      rawNames: [Array("a-cache".utf8), Array("b-cache".utf8)]
    )
    let revalidator = try actualSyntheticRevalidator(
      supportedPolicyProvenance: approval.reviewedManifest.policyProvenance
    )

    let stable = try await revalidator.revalidate(approval)
    #expect(stable.isFullyEligibleAtObservation)

    try FileManager.default.removeItem(at: fixture.url(for: "a-cache"))
    try FileManager.default.removeItem(at: fixture.url(for: "b-cache"))
    try fixture.makeSymbolicLink("b-cache", destination: fixture.outside)
    let beforeFreshRoot = try treeSnapshot(at: fixture.root)
    let beforeOutside = try treeSnapshot(at: fixture.outside)

    let changed = try await revalidator.revalidate(approval)

    #expect(changed.entries.map(\.path) == approval.reviewedManifest.entries.map(\.path))
    #expect(changed.entries[0].status == .rejected(.candidateMissing))
    #expect(
      changed.entries[1].status
        == .rejected(.candidateKindChanged(expected: .directory, observed: .symbolicLink))
    )
    #expect(try treeSnapshot(at: fixture.root) == beforeFreshRoot)
    #expect(try treeSnapshot(at: fixture.outside) == beforeOutside)
  }

  @Test("Missing, replaced, and symbolic-link candidates fail closed without mutation")
  func candidateChangesDoNotMutate() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }
    try fixture.write("a-cache/payload", bytes: [1])
    try fixture.write("b-cache/payload", bytes: [2])
    try fixture.write("sentinel", bytes: [3], under: fixture.outside)
    let beforeRoot = try treeSnapshot(at: fixture.root)
    let beforeOutside = try treeSnapshot(at: fixture.outside)
    let (source, approval) = try await revalidationApproval(root: fixture.root)
    let original = source.classificationRequest.report.topLevelItems
    let replacement = revalidationSummary(
      original[1],
      identity: FileIdentity(device: 42, inode: 99)
    )
    let symlink = revalidationSummary(original[0], kind: .symbolicLink)
    let report = revalidationReport(
      source.classificationRequest.report, items: [symlink, replacement])
    let revalidator = CleanupRevalidator(
      scanner: RevalidationStubScanner { _ in report },
      classifier: RevalidationStubClassifier { request in
        boundRevalidationReport(request: request, source: source)
      },
      referenceTime: { 2_000_000 },
      supportedPolicyProvenance: approval.reviewedManifest.policyProvenance
    )

    let result = try await revalidator.revalidate(approval)

    #expect(result.entries.map(\.path) == approval.reviewedManifest.entries.map(\.path))
    #expect(
      result.entries.map(\.status)
        == [
          .rejected(.candidateKindChanged(expected: .directory, observed: .symbolicLink)),
          .rejected(.candidateIdentityChanged),
        ]
    )
    #expect(!result.isFullyEligibleAtObservation)
    #expect(try treeSnapshot(at: fixture.root) == beforeRoot)
    #expect(try treeSnapshot(at: fixture.outside) == beforeOutside)
  }

  @Test("A missing candidate and incomplete fresh observation are entry diagnostics")
  func missingAndIncompleteObservations() async throws {
    let (source, approval) = try await revalidationApproval(rawNames: [Array("candidate".utf8)])
    let missingReport = revalidationReport(source.classificationRequest.report, items: [])
    let missing = CleanupRevalidator(
      scanner: RevalidationStubScanner { _ in missingReport },
      classifier: RevalidationStubClassifier { request in
        boundRevalidationReport(request: request, source: source, evaluations: [])
      },
      referenceTime: { 2_000_000 },
      supportedPolicyProvenance: approval.reviewedManifest.policyProvenance
    )
    let incompleteReport = revalidationReport(
      source.classificationRequest.report,
      rootIsComplete: false
    )
    let incomplete = CleanupRevalidator(
      scanner: RevalidationStubScanner { _ in incompleteReport },
      classifier: RevalidationStubClassifier { _ in
        Issue.record("The classifier must not run for an incomplete scan")
        throw CancellationError()
      },
      referenceTime: { 2_000_001 },
      supportedPolicyProvenance: approval.reviewedManifest.policyProvenance
    )

    let missingResult = try await missing.revalidate(approval)
    let incompleteResult = try await incomplete.revalidate(approval)

    #expect(missingResult.entries.map(\.status) == [.rejected(.candidateMissing)])
    #expect(incompleteResult.entries.map(\.status) == [.rejected(.sourceObservationIncomplete)])
  }

  @Test("Root replacement fails globally before classification")
  func rootIdentityReplacementFailsGlobally() async throws {
    let (source, approval) = try await revalidationApproval(rawNames: [Array("candidate".utf8)])
    let replacementRoot = revalidationSummary(
      source.classificationRequest.report.root,
      identity: FileIdentity(device: 42, inode: 999)
    )
    let report = revalidationReport(source.classificationRequest.report, root: replacementRoot)
    let classifierLog = RevalidationRequestLog<RuleClassificationRequest>()
    let revalidator = CleanupRevalidator(
      scanner: RevalidationStubScanner { _ in report },
      classifier: RevalidationStubClassifier { request in
        await classifierLog.append(request)
        return boundRevalidationReport(request: request, source: source)
      },
      referenceTime: { 2_000_000 },
      supportedPolicyProvenance: approval.reviewedManifest.policyProvenance
    )

    await expectRevalidationError(.rootIdentityChanged) {
      _ = try await revalidator.revalidate(approval)
    }
    #expect(await classifierLog.snapshot().isEmpty)
  }

  @Test("Partial results preserve approved canonical order")
  func partialResultsRemainCanonical() async throws {
    let (source, approval) = try await revalidationApproval()
    let retained = try #require(source.classificationRequest.report.topLevelItems.first)
    let report = revalidationReport(source.classificationRequest.report, items: [retained])
    let retainedEvaluation = try #require(source.classificationReport.evaluations.first)
    let revalidator = CleanupRevalidator(
      scanner: RevalidationStubScanner { _ in report },
      classifier: RevalidationStubClassifier { request in
        boundRevalidationReport(request: request, source: source, evaluations: [retainedEvaluation])
      },
      referenceTime: { 2_000_000 },
      supportedPolicyProvenance: approval.reviewedManifest.policyProvenance
    )

    let result = try await revalidator.revalidate(approval)

    #expect(result.entries.map(\.path) == approval.reviewedManifest.entries.map(\.path))
    #expect(result.entries[0].status == .eligibleAtObservation)
    #expect(result.entries[1].status == .rejected(.candidateMissing))
  }

  @Test("Unsupported approval policy is rejected before scanning")
  func unsupportedApprovalPolicyAvoidsIO() async throws {
    let (_, approval) = try await revalidationApproval()
    let scanLog = RevalidationRequestLog<ScanRequest>()
    let revalidator = CleanupRevalidator(
      scanner: RevalidationStubScanner { request in
        await scanLog.append(request)
        throw NSError(domain: "test", code: 1)
      },
      classifier: RevalidationStubClassifier { _ in
        throw NSError(domain: "test", code: 2)
      },
      referenceTime: { 2_000_000 },
      supportedPolicyProvenance: try builtInTestPolicyProvenance()
    )

    await expectRevalidationError(.unsupportedApprovalPolicy) {
      _ = try await revalidator.revalidate(approval)
    }
    #expect(await scanLog.snapshot().isEmpty)
  }

  @Test("Malformed and unbound dependency output is rejected")
  func dependencyOutputFailures() async throws {
    let (source, approval) = try await revalidationApproval(rawNames: [Array("candidate".utf8)])
    let invalidScan = ScanReport(
      root: source.classificationRequest.report.root,
      topLevelItems: source.classificationRequest.report.topLevelItems,
      topLevelItemCount: 99,
      topLevelItemsWereSuppressed: false,
      hardLinkAccountingIsComplete: true,
      traversalDetailsWereDiscarded: false,
      issues: [],
      suppressedIssueCount: 0
    )
    let malformedScanner = CleanupRevalidator(
      scanner: RevalidationStubScanner { _ in invalidScan },
      classifier: RevalidationStubClassifier { _ in
        Issue.record("The classifier must not run for a malformed scan")
        throw CancellationError()
      },
      referenceTime: { 2_000_000 },
      supportedPolicyProvenance: approval.reviewedManifest.policyProvenance
    )
    let unboundClassifier = CleanupRevalidator(
      scanner: RevalidationStubScanner { _ in source.classificationRequest.report },
      classifier: RevalidationStubClassifier { request in
        RuleClassificationReport(
          referenceUnixSeconds: request.referenceUnixSeconds,
          evaluations: source.classificationReport.evaluations,
          policyProvenance: source.classificationReport.policyProvenance,
          sourceBinding: nil
        )
      },
      referenceTime: { 2_000_001 },
      supportedPolicyProvenance: approval.reviewedManifest.policyProvenance
    )

    await expectRevalidationError(.invalidScanReport) {
      _ = try await malformedScanner.revalidate(approval)
    }
    await expectRevalidationError(.classificationReportIsNotSourceBound) {
      _ = try await unboundClassifier.revalidate(approval)
    }
  }

  @Test("Fresh rule, finding, and stable policy changes reject individual entries")
  func freshPolicyChangesRejectEntries() async throws {
    let (source, approval) = try await revalidationApproval(rawNames: [Array("candidate".utf8)])
    let original = try #require(source.classificationReport.evaluations.first)
    let ruleChanged = RuleEvaluation(
      path: original.path,
      rule: nil,
      matchingRules: [],
      displayName: original.displayName,
      responsibleTool: original.responsibleTool,
      matchState: .unrecognized,
      disposition: .protected,
      reproducibility: .unknown,
      findings: [
        RuleFinding(
          identifier: AutomaticCheckIdentifier.lexicalRecognition,
          kind: .lexicalRecognition,
          state: .failed,
          explanation: "The new policy does not recognize this candidate."
        )
      ],
      explanation: "The candidate is not recognized by the current policy."
    )
    let blockingIdentifier = testCheckIdentifier("synthetic-evidence")
    let blockedFindings = original.findings.map { finding in
      finding.identifier == blockingIdentifier
        ? RuleFinding(
          identifier: finding.identifier,
          kind: finding.kind,
          state: .failed,
          explanation: finding.explanation
        ) : finding
    }
    let blocked = revalidationEvaluation(
      original,
      matchState: .possibleMatch,
      disposition: .protected,
      findings: blockedFindings
    )
    let policyChanged = revalidationEvaluation(original, displayName: "Renamed policy result")
    let make: @Sendable (RuleEvaluation) -> CleanupRevalidator = { evaluation in
      CleanupRevalidator(
        scanner: RevalidationStubScanner { _ in source.classificationRequest.report },
        classifier: RevalidationStubClassifier { request in
          boundRevalidationReport(request: request, source: source, evaluations: [evaluation])
        },
        referenceTime: { 2_000_000 },
        supportedPolicyProvenance: approval.reviewedManifest.policyProvenance
      )
    }

    let ruleResult = try await make(ruleChanged).revalidate(approval)
    let blockedResult = try await make(blocked).revalidate(approval)
    let policyResult = try await make(policyChanged).revalidate(approval)

    #expect(
      ruleResult.entries[0].status
        == CleanupRevalidationStatus.rejected(
          CleanupRevalidationRejection.ruleRevisionChanged(
            expected: approval.reviewedManifest.entries[0].ruleRevision, observed: nil))
    )
    #expect(
      blockedResult.entries[0].status
        == CleanupRevalidationStatus.rejected(
          CleanupRevalidationRejection.blockingFinding(blockingIdentifier))
    )
    #expect(
      policyResult.entries[0].status
        == CleanupRevalidationStatus.rejected(
          CleanupRevalidationRejection.policyDecisionChanged)
    )
  }

  @Test("Cancellation is propagated before dependencies run")
  func preCancellation() async throws {
    let (_, approval) = try await revalidationApproval()
    let scanLog = RevalidationRequestLog<ScanRequest>()
    let revalidator = CleanupRevalidator(
      scanner: RevalidationStubScanner { request in
        await scanLog.append(request)
        throw NSError(domain: "test", code: 1)
      },
      classifier: RevalidationStubClassifier { _ in
        throw NSError(domain: "test", code: 2)
      },
      referenceTime: { 2_000_000 },
      supportedPolicyProvenance: approval.reviewedManifest.policyProvenance
    )
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await revalidator.revalidate(approval)
    }

    await expectCancellation {
      _ = try await task.value
    }
    #expect(await scanLog.snapshot().isEmpty)
  }

  @Test("Repeated diagnostic observation is non-mutating and deterministic")
  func repeatabilityAndNoMutation() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }
    try fixture.write("candidate/payload", bytes: [1])
    try fixture.write("sentinel", bytes: [2], under: fixture.outside)
    let beforeRoot = try treeSnapshot(at: fixture.root)
    let beforeOutside = try treeSnapshot(at: fixture.outside)
    let (source, approval) = try await revalidationApproval(
      rawNames: [Array("candidate".utf8)],
      root: fixture.root
    )
    let revalidator = CleanupRevalidator(
      scanner: RevalidationStubScanner { _ in source.classificationRequest.report },
      classifier: RevalidationStubClassifier { request in
        boundRevalidationReport(request: request, source: source)
      },
      referenceTime: { 2_000_000 },
      supportedPolicyProvenance: approval.reviewedManifest.policyProvenance
    )

    let first = try await revalidator.revalidate(approval)
    let second = try await revalidator.revalidate(approval)

    #expect(first == second)
    #expect(try treeSnapshot(at: fixture.root) == beforeRoot)
    #expect(try treeSnapshot(at: fixture.outside) == beforeOutside)
  }
}
