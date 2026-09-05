import DevSiftCore
import Foundation
import Testing

@testable import DevSiftApp
@testable import DevSiftCore

@Suite("Cleanup quarantine app workflow")
struct CleanupQuarantineWorkflowTests {
  @Test("A valid review is fully approved, freshly authorized, and executed once")
  func happyPath() async throws {
    let reviewSession = try await makeNPMReviewSession()
    let expected = successfulFrontendResult()
    let executor = RecordingFrontendExecutor(result: expected)
    let workflow = CleanupQuarantineWorkflow(
      approver: CleanupApprover(),
      authorizer: CleanupQuarantineAuthorizer(),
      executor: executor
    )

    let result = await workflow.execute(reviewSession)

    #expect(reviewSession.entryReferences.count == 1)
    #expect(reviewSession.preconditionReferences.count == 1)
    #expect(result == .execution(expected))
    #expect(await executor.executionCount == 1)
  }

  @Test("Cancellation before review performs no authorization or execution")
  func preCancelled() async throws {
    let reviewSession = try await makeNPMReviewSession()
    let executor = RecordingFrontendExecutor(result: successfulFrontendResult())
    let workflow = CleanupQuarantineWorkflow(
      approver: CleanupApprover(),
      authorizer: CleanupQuarantineAuthorizer(),
      executor: executor
    )

    let task = Task {
      withUnsafeCurrentTask { task in
        task?.cancel()
      }
      return await workflow.execute(reviewSession)
    }

    #expect(await task.value == .failed(.cancelled(.reviewConfirmation)))
    #expect(await executor.executionCount == 0)
  }

  @Test("A malformed retained review fails at approval without execution")
  func malformedReview() async throws {
    let fixture = try await makeNPMReviewFixture()
    let malformedManifest = try CleanupManifest(
      policyProvenance: fixture.session.reviewedManifest.policyProvenance,
      classificationReferenceUnixSeconds: fixture.session.reviewedManifest
        .classificationReferenceUnixSeconds,
      expectedRootIdentity: fixture.session.reviewedManifest.expectedRootIdentity,
      entries: []
    )
    let malformedSession = CleanupApprovalReviewSession(
      sourceRequest: fixture.request,
      reviewedManifest: malformedManifest
    )
    let executor = RecordingFrontendExecutor(result: successfulFrontendResult())
    let workflow = CleanupQuarantineWorkflow(
      approver: CleanupApprover(),
      authorizer: CleanupQuarantineAuthorizer(),
      executor: executor
    )

    let result = await workflow.execute(malformedSession)

    #expect(result == .failed(.rejected(.approval)))
    #expect(await executor.executionCount == 0)
  }

  @Test("An approver that rejects a foreign session exposes only its bounded stage")
  func foreignReview() async throws {
    let reviewSession = try await makeNPMReviewSession()
    let executor = RecordingFrontendExecutor(result: successfulFrontendResult())
    let workflow = CleanupQuarantineWorkflow(
      approver: RejectingApprover(),
      authorizer: CleanupQuarantineAuthorizer(),
      executor: executor
    )

    let result = await workflow.execute(reviewSession)

    #expect(result == .failed(.rejected(.approval)))
    #expect(await executor.executionCount == 0)
  }

  @Test("A duplicate authorization issuance fails closed before execution")
  func duplicateAuthorization() async throws {
    let reviewSession = try await makeNPMReviewSession()
    let approval = try approve(reviewSession)
    let authorizationSession = try CleanupQuarantineAuthorizer().beginAttempt(for: approval)
    let request = authorizationSession.attestationRequest
    _ = try await authorizationSession.authorize(
      using: CleanupQuarantineUserAttestation(
        request: request,
        statement: request.requiredStatement
      )
    )
    let executor = RecordingFrontendExecutor(result: successfulFrontendResult())
    let workflow = CleanupQuarantineWorkflow(
      approver: CleanupApprover(),
      authorizer: FixedAuthorizer(session: authorizationSession),
      executor: executor
    )

    let result = await workflow.execute(reviewSession)

    #expect(result == .failed(.rejected(.authorizationIssuance)))
    #expect(await executor.executionCount == 0)
  }

  @Test("A bounded executor rejection remains an execution result")
  func boundedExecutorResult() async throws {
    let reviewSession = try await makeNPMReviewSession()
    let expected = CleanupQuarantineFrontendExecutionResult(
      outcome: .notStarted(.authorizationAlreadyConsumed),
      durabilityEvidence: .notRecorded,
      namespaceMutation: .none,
      cancellationWasObservedAfterRename: false
    )
    let executor = RecordingFrontendExecutor(result: expected)
    let workflow = CleanupQuarantineWorkflow(
      approver: CleanupApprover(),
      authorizer: CleanupQuarantineAuthorizer(),
      executor: executor
    )

    #expect(await workflow.execute(reviewSession) == .execution(expected))
    #expect(await executor.executionCount == 1)
  }
}

private struct NPMReviewFixture {
  let request: CleanupManifestRequest
  let session: CleanupApprovalReviewSession
}

private func makeNPMReviewSession() async throws -> CleanupApprovalReviewSession {
  try await makeNPMReviewFixture().session
}

private func makeNPMReviewFixture() async throws -> NPMReviewFixture {
  let referenceUnixSeconds: Int64 = 1_000_000
  let device: UInt64 = 42
  let candidate = AppTestReportFactory.item(
    rawComponents: [Array("_cacache".utf8)],
    scanTimeIdentity: FileIdentity(device: device, inode: 2),
    logicalBytes: 8_192,
    allocatedBytes: 4_096,
    hardLinkExclusiveAllocatedBytes: 4_096,
    newestContentModificationUnixSeconds: 0
  )
  let report = AppTestReportFactory.report(
    root: AppTestReportFactory.item(
      scanTimeIdentity: FileIdentity(device: device, inode: 1),
      logicalBytes: 8_192,
      allocatedBytes: 4_096,
      hardLinkExclusiveAllocatedBytes: 4_096,
      newestContentModificationUnixSeconds: 0
    ),
    topLevelItems: [candidate]
  )
  let classificationRequest = RuleClassificationRequest(
    root: URL(fileURLWithPath: "/private/tmp/devsift-workflow/.npm", isDirectory: true),
    report: report,
    referenceUnixSeconds: referenceUnixSeconds
  )
  let observation = RuleObservation(
    summary: candidate,
    selectedRootBasename: .known(Array(".npm".utf8)),
    integrity: RuleScanIntegrity(
      reportIsComplete: true,
      itemIsComplete: true,
      topLevelItemsWereSuppressed: false,
      traversalDetailsWereDiscarded: false,
      suppressedIssueCount: 0,
      unknownAllocatedItemCount: 0,
      sizeOverflowed: false,
      hardLinkAccountingIsComplete: true,
      identityMatchesScan: .known(true)
    ),
    facts: RuleObservationFacts(
      trustedLocation: .known(true),
      accountOwnedCacheNamespace: .known(true),
      generatedContentMarker: .known(true),
      newestContentModificationUnixSeconds: .known(0),
      activity: .unknown(.notCollected),
      protectedDescendantPresent: .known(false)
    )
  )
  let classification = try await ExplainableRuleClassifier().classify(
    observations: [observation],
    referenceUnixSeconds: referenceUnixSeconds
  ).binding(to: classificationRequest)
  let evaluation = try #require(classification.evaluations.first)
  let ruleRevision = try #require(evaluation.rule)
  let request = CleanupManifestRequest(
    classificationRequest: classificationRequest,
    classificationReport: classification,
    selections: [CleanupCandidateSelection(path: candidate.path, ruleRevision: ruleRevision)]
  )
  return NPMReviewFixture(
    request: request,
    session: try CleanupApprover().beginReview(request)
  )
}

private func approve(
  _ session: CleanupApprovalReviewSession
) throws -> CleanupApproval {
  let confirmations = try session.entryReferences.map(session.confirm)
  let acknowledgements = try session.preconditionReferences.map(
    session.acknowledgePreconditionForReview
  )
  return try CleanupApprover().approve(
    CleanupApprovalRequest(
      session: session,
      confirmations: confirmations,
      preconditionReviewAcknowledgements: acknowledgements
    )
  )
}

private func successfulFrontendResult() -> CleanupQuarantineFrontendExecutionResult {
  CleanupQuarantineFrontendExecutionResult(
    outcome: .durablyQuarantined(sourceNameWasRecreated: false),
    durabilityEvidence: .terminalReceiptRecorded(producedByRecovery: false),
    namespaceMutation: .quarantineRootCreated,
    cancellationWasObservedAfterRename: false
  )
}

private actor RecordingFrontendExecutor: CleanupQuarantineFrontendExecuting {
  private(set) var executionCount = 0
  private let result: CleanupQuarantineFrontendExecutionResult

  init(result: CleanupQuarantineFrontendExecutionResult) {
    self.result = result
  }

  func execute(
    _ authorization: CleanupQuarantineAuthorization
  ) -> CleanupQuarantineFrontendExecutionResult {
    executionCount += 1
    return result
  }
}

private struct FixedAuthorizer: CleanupQuarantineAuthorizing, Sendable {
  let session: CleanupQuarantineAuthorizationSession

  func beginAttempt(
    for approval: CleanupApproval
  ) throws -> CleanupQuarantineAuthorizationSession {
    session
  }
}

private struct RejectingApprover: CleanupApproving, Sendable {
  func beginReview(
    _ source: CleanupManifestRequest
  ) throws -> CleanupApprovalReviewSession {
    throw CleanupApprovalError.entryReferenceDoesNotBelongToReview
  }

  func approve(_ request: CleanupApprovalRequest) throws -> CleanupApproval {
    throw CleanupApprovalError.entryReferenceDoesNotBelongToReview
  }
}
