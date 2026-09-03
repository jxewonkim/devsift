import Foundation
import Testing

@testable import DevSiftCore

@Suite("Cleanup approval session fail-closed boundaries")
struct CleanupApproverFailureTests {
  @Test("A session rejects missing, extra, duplicate, and reordered confirmations")
  func exactConfirmationSet() async throws {
    let source = try await approvalTestSource()
    let approver = CleanupApprover()
    let session = try approver.beginReview(source.manifestRequest)
    let confirmations = try approvalConfirmations(from: session)

    expectApprovalError(
      .confirmationCountMismatch(expected: 2, actual: 1)
    ) {
      _ = try approver.approve(
        CleanupApprovalRequest(
          session: session,
          confirmations: Array(confirmations.dropLast())
        )
      )
    }
    expectApprovalError(
      .confirmationCountMismatch(expected: 2, actual: 3)
    ) {
      _ = try approver.approve(
        CleanupApprovalRequest(
          session: session,
          confirmations: confirmations + [confirmations[0]]
        )
      )
    }
    expectApprovalError(.confirmationMismatch(index: 1)) {
      _ = try approver.approve(
        CleanupApprovalRequest(
          session: session,
          confirmations: [confirmations[0], confirmations[0]]
        )
      )
    }
    expectApprovalError(.confirmationMismatch(index: 0)) {
      _ = try approver.approve(
        CleanupApprovalRequest(
          session: session,
          confirmations: confirmations.reversed()
        )
      )
    }
  }

  @Test("A session rejects incomplete or noncanonical precondition review acknowledgements")
  func exactPreconditionReviewAcknowledgementSet() async throws {
    let source = try await approvalPendingPreconditionTestSource()
    let approver = CleanupApprover()
    let session = try approver.beginReview(source.manifestRequest)
    let entryConfirmations = try approvalConfirmations(from: session)
    let preconditionReviewAcknowledgements = try approvalPreconditionReviewAcknowledgements(
      from: session)

    #expect(preconditionReviewAcknowledgements.count == 2)
    expectApprovalError(
      .preconditionReviewAcknowledgementCountMismatch(expected: 2, actual: 0)
    ) {
      _ = try approver.approve(
        CleanupApprovalRequest(
          session: session,
          confirmations: entryConfirmations
        )
      )
    }
    expectApprovalError(
      .preconditionReviewAcknowledgementCountMismatch(expected: 2, actual: 1)
    ) {
      _ = try approver.approve(
        CleanupApprovalRequest(
          session: session,
          confirmations: entryConfirmations,
          preconditionReviewAcknowledgements: Array(preconditionReviewAcknowledgements.dropLast())
        )
      )
    }
    expectApprovalError(
      .preconditionReviewAcknowledgementCountMismatch(expected: 2, actual: 3)
    ) {
      _ = try approver.approve(
        CleanupApprovalRequest(
          session: session,
          confirmations: entryConfirmations,
          preconditionReviewAcknowledgements: preconditionReviewAcknowledgements + [
            preconditionReviewAcknowledgements[0]
          ]
        )
      )
    }
    expectApprovalError(.preconditionReviewAcknowledgementMismatch(index: 1)) {
      _ = try approver.approve(
        CleanupApprovalRequest(
          session: session,
          confirmations: entryConfirmations,
          preconditionReviewAcknowledgements: [
            preconditionReviewAcknowledgements[0], preconditionReviewAcknowledgements[0],
          ]
        )
      )
    }
    expectApprovalError(.preconditionReviewAcknowledgementMismatch(index: 0)) {
      _ = try approver.approve(
        CleanupApprovalRequest(
          session: session,
          confirmations: entryConfirmations,
          preconditionReviewAcknowledgements: preconditionReviewAcknowledgements.reversed()
        )
      )
    }
  }

  @Test("Same-looking references and confirmations cannot cross review sessions")
  func crossSessionSubstitution() async throws {
    let rootA = URL(fileURLWithPath: "/synthetic/RootA", isDirectory: true)
    let rootB = URL(fileURLWithPath: "/synthetic/RootB", isDirectory: true)
    let sourceA = try await approvalTestSource(
      rawNames: [Array("candidate".utf8)],
      root: rootA
    )
    let sourceB = try await approvalTestSource(
      rawNames: [Array("candidate".utf8)],
      root: rootB
    )
    let approver = CleanupApprover()
    let sessionA = try approver.beginReview(sourceA.manifestRequest)
    let sessionB = try approver.beginReview(sourceB.manifestRequest)
    let referenceA = try #require(sessionA.entryReferences.first)
    let referenceB = try #require(sessionB.entryReferences.first)

    #expect(sessionA.sourceRoot != sessionB.sourceRoot)
    #expect(sessionA.reviewedManifest == sessionB.reviewedManifest)
    #expect(referenceA.ordinal == referenceB.ordinal)
    #expect(referenceA.path == referenceB.path)
    #expect(referenceA.ruleRevision == referenceB.ruleRevision)
    #expect(referenceA != referenceB)

    expectApprovalError(.entryReferenceDoesNotBelongToReview) {
      _ = try sessionA.confirm(referenceB)
    }

    let confirmationA = try sessionA.confirm(referenceA)
    let confirmationB = try sessionB.confirm(referenceB)
    #expect(confirmationA.ordinal == confirmationB.ordinal)
    #expect(confirmationA.path == confirmationB.path)
    #expect(confirmationA.ruleRevision == confirmationB.ruleRevision)
    #expect(confirmationA != confirmationB)

    expectApprovalError(.confirmationMismatch(index: 0)) {
      _ = try approver.approve(
        CleanupApprovalRequest(
          session: sessionA,
          confirmations: [confirmationB]
        )
      )
    }

    let approvalA = try approver.approve(
      CleanupApprovalRequest(
        session: sessionA,
        confirmations: [confirmationA]
      )
    )
    let approvalB = try approver.approve(
      CleanupApprovalRequest(
        session: sessionB,
        confirmations: [confirmationB]
      )
    )
    #expect(approvalA.sourceRoot == rootA)
    #expect(approvalB.sourceRoot == rootB)
  }

  @Test("Same-looking precondition review values cannot cross sessions")
  func crossSessionPreconditionSubstitution() async throws {
    let source = try await approvalPendingPreconditionTestSource(
      rawNames: [Array("candidate".utf8)]
    )
    let approver = CleanupApprover()
    let sessionA = try approver.beginReview(source.manifestRequest)
    let sessionB = try approver.beginReview(source.manifestRequest)
    let referenceA = try #require(sessionA.preconditionReferences.first)
    let referenceB = try #require(sessionB.preconditionReferences.first)

    #expect(sessionA.sourceRoot == sessionB.sourceRoot)
    #expect(sessionA.reviewedManifest == sessionB.reviewedManifest)
    #expect(referenceA.ordinal == referenceB.ordinal)
    #expect(referenceA.path == referenceB.path)
    #expect(referenceA.ruleRevision == referenceB.ruleRevision)
    #expect(referenceA.precondition == referenceB.precondition)
    #expect(referenceA != referenceB)

    expectApprovalError(.preconditionReferenceDoesNotBelongToReview) {
      _ = try sessionA.acknowledgePreconditionForReview(referenceB)
    }

    let acknowledgementA = try sessionA.acknowledgePreconditionForReview(referenceA)
    let acknowledgementB = try sessionB.acknowledgePreconditionForReview(referenceB)
    #expect(acknowledgementA.ordinal == acknowledgementB.ordinal)
    #expect(acknowledgementA.path == acknowledgementB.path)
    #expect(acknowledgementA.ruleRevision == acknowledgementB.ruleRevision)
    #expect(acknowledgementA.precondition == acknowledgementB.precondition)
    #expect(acknowledgementA != acknowledgementB)

    expectApprovalError(.preconditionReviewAcknowledgementMismatch(index: 0)) {
      _ = try approver.approve(
        CleanupApprovalRequest(
          session: sessionA,
          confirmations: try approvalConfirmations(from: sessionA),
          preconditionReviewAcknowledgements: [acknowledgementB]
        )
      )
    }

    let approval = try approver.approve(
      CleanupApprovalRequest(
        session: sessionA,
        confirmations: try approvalConfirmations(from: sessionA),
        preconditionReviewAcknowledgements: [acknowledgementA]
      )
    )
    #expect(approval.preconditionReviewAcknowledgements == [acknowledgementA])
  }

  @Test("Approval regenerates and compares the exact reviewed manifest")
  func reviewedManifestRegeneration() async throws {
    let source = try await approvalTestSource(rawNames: [Array("candidate".utf8)])
    let planned = try CleanupPlanner().makeManifest(source.manifestRequest)
    let originalEntry = try #require(planned.entries.first)
    let substitutedEntry = CleanupManifestEntry(
      path: originalEntry.path,
      expectedKind: originalEntry.expectedKind,
      expectedIdentity: originalEntry.expectedIdentity,
      ruleRevision: originalEntry.ruleRevision,
      disposition: originalEntry.disposition,
      reproducibility: originalEntry.reproducibility,
      displayName: originalEntry.displayName + " substituted",
      responsibleTool: originalEntry.responsibleTool,
      classificationExplanation: originalEntry.classificationExplanation,
      findings: originalEntry.findings,
      size: originalEntry.size
    )
    let substitutedManifest = try CleanupManifest(
      policyProvenance: planned.policyProvenance,
      classificationReferenceUnixSeconds: planned.classificationReferenceUnixSeconds,
      expectedRootIdentity: planned.expectedRootIdentity,
      entries: [substitutedEntry]
    )
    let substitutedSession = CleanupApprovalReviewSession(
      sourceRequest: source.manifestRequest,
      reviewedManifest: substitutedManifest
    )
    let request = CleanupApprovalRequest(
      session: substitutedSession,
      confirmations: try approvalConfirmations(from: substitutedSession)
    )

    #expect(substitutedManifest != planned)
    expectApprovalError(.reviewedManifestRegenerationMismatch) {
      _ = try CleanupApprover().approve(request)
    }
  }

  @Test("Approval rejects a reviewed manifest with only its pending precondition removed")
  func preconditionOnlyManifestSubstitution() async throws {
    let source = try await approvalPendingPreconditionTestSource(
      rawNames: [Array("candidate".utf8)]
    )
    let planned = try CleanupPlanner().makeManifest(source.manifestRequest)
    let originalEntry = try #require(planned.entries.first)
    let substitutedEntry = CleanupManifestEntry(
      path: originalEntry.path,
      expectedKind: originalEntry.expectedKind,
      expectedIdentity: originalEntry.expectedIdentity,
      ruleRevision: originalEntry.ruleRevision,
      disposition: originalEntry.disposition,
      reproducibility: originalEntry.reproducibility,
      displayName: originalEntry.displayName,
      responsibleTool: originalEntry.responsibleTool,
      classificationExplanation: originalEntry.classificationExplanation,
      findings: originalEntry.findings,
      deferredExecutionPreconditions: [],
      size: originalEntry.size
    )
    let substitutedManifest = try CleanupManifest(
      policyProvenance: planned.policyProvenance,
      classificationReferenceUnixSeconds: planned.classificationReferenceUnixSeconds,
      expectedRootIdentity: planned.expectedRootIdentity,
      entries: [substitutedEntry]
    )
    let substitutedSession = CleanupApprovalReviewSession(
      sourceRequest: source.manifestRequest,
      reviewedManifest: substitutedManifest
    )
    let request = CleanupApprovalRequest(
      session: substitutedSession,
      confirmations: try approvalConfirmations(from: substitutedSession),
      preconditionReviewAcknowledgements: []
    )

    #expect(
      originalEntry.deferredExecutionPreconditions == [
        .requiresUserAttestationThatResponsibleToolIsStopped
      ])
    #expect(substitutedEntry.deferredExecutionPreconditions.isEmpty)
    #expect(substitutedManifest != planned)
    expectApprovalError(.reviewedManifestRegenerationMismatch) {
      _ = try CleanupApprover().approve(request)
    }
  }

  @Test("An empty source selection cannot begin an approval review")
  func emptySourceSelection() async throws {
    let source = try await approvalTestSource(rawNames: [Array("candidate".utf8)])

    expectApprovalError(.emptyManifest) {
      _ = try CleanupApprover().beginReview(source.request(selections: []))
    }
  }

  @Test("Planner source-binding errors propagate without producing a session")
  func planningErrorsPropagate() async throws {
    let source = try await approvalTestSource(rawNames: [Array("candidate".utf8)])
    let selection = try #require(source.selections.first)

    expectApprovalPlanningError(.duplicateSelection(selection.path)) {
      _ = try CleanupApprover().beginReview(
        source.request(selections: [selection, selection])
      )
    }

    let unboundReport = RuleClassificationReport(
      referenceUnixSeconds: source.classificationReport.referenceUnixSeconds,
      evaluations: source.classificationReport.evaluations,
      policyProvenance: source.classificationReport.policyProvenance,
      sourceBinding: nil
    )
    let unboundSource = CleanupManifestRequest(
      classificationRequest: source.classificationRequest,
      classificationReport: unboundReport,
      selections: [selection]
    )
    expectApprovalPlanningError(.classificationReportIsNotSourceBound) {
      _ = try CleanupApprover().beginReview(unboundSource)
    }
  }

  @Test("Only an absolute, local, unambiguous source root can begin review")
  func invalidSourceRoot() async throws {
    let baseRoot = URL(fileURLWithPath: "/synthetic/base", isDirectory: true)
    let invalidRoots = [
      try #require(URL(string: "https://example.invalid/cache")),
      try #require(URL(string: "file://remote.invalid/cache")),
      try #require(URL(string: "file://user@localhost/cache")),
      try #require(URL(string: "file:///cache?scope=changed")),
      try #require(URL(string: "file:///cache#changed")),
      try #require(URL(string: "file:///cache/%00")),
      URL(fileURLWithPath: "child", relativeTo: baseRoot),
    ]

    for root in invalidRoots {
      let source = try await approvalTestSource(
        rawNames: [Array("candidate".utf8)],
        root: root
      )
      expectApprovalError(.invalidSourceRoot) {
        _ = try CleanupApprover().beginReview(source.manifestRequest)
      }
    }
  }

  @Test("Cancellation prevents both review creation and approval")
  func cancellation() async throws {
    let source = try await approvalPendingPreconditionTestSource(
      rawNames: [Array("candidate".utf8)]
    )
    let approver = CleanupApprover()

    let beginTask = Task {
      withUnsafeCurrentTask { currentTask in
        currentTask?.cancel()
      }
      return try approver.beginReview(source.manifestRequest)
    }
    switch await beginTask.result {
    case .success:
      Issue.record("A cancelled approver unexpectedly began review")
    case .failure(let error):
      #expect(error is CancellationError)
    }

    let session = try approver.beginReview(source.manifestRequest)
    let request = CleanupApprovalRequest(
      session: session,
      confirmations: try approvalConfirmations(from: session),
      preconditionReviewAcknowledgements: try approvalPreconditionReviewAcknowledgements(
        from: session)
    )
    let approvalTask = Task {
      withUnsafeCurrentTask { currentTask in
        currentTask?.cancel()
      }
      return try approver.approve(request)
    }
    switch await approvalTask.result {
    case .success:
      Issue.record("A cancelled approver unexpectedly returned approval")
    case .failure(let error):
      #expect(error is CancellationError)
    }
  }
}
