import DevSiftCore
import Foundation
import Testing

@testable import DevSiftApp
@testable import DevSiftCore

@MainActor
@Suite("Cleanup quarantine view model")
struct CleanupQuarantineViewModelTests {
  @Test("Unsupported macOS and non-npm reviews never invoke quarantine")
  func unsupportedReviewsDoNotExecute() async throws {
    let npmRoot = URL(
      fileURLWithPath: "/private/tmp/devsift-app-unsupported/.npm",
      isDirectory: true
    )
    let workflow = RecordingCleanupQuarantineWorkflow(
      result: .execution(successfulFrontendResult())
    )
    let npmModel = ScanViewModel(
      scanner: ImmediateScanner(outcome: .report(npmReport())),
      classifier: SyntheticNPMRuleClassifier(),
      cleanupQuarantineWorkflow: workflow,
      securityScope: SecurityScopeSpy(),
      referenceUnixSeconds: { 1_000_000 },
      supportsCleanupQuarantine: { false }
    )

    _ = try await prepareSingleReview(in: npmModel, at: npmRoot)

    #expect(npmModel.cleanupQuarantineAvailability == .requiresMacOS26)
    #expect(
      npmModel.executeReviewedCleanup(
        reviewWasConfirmed: true,
        npmStoppedRiskWasAccepted: true
      ) == nil
    )

    let nonNPMRoot = URL(
      fileURLWithPath: "/private/tmp/devsift-app-non-npm/Caches",
      isDirectory: true
    )
    let nonNPMModel = ScanViewModel(
      scanner: ImmediateScanner(outcome: .report(nonNPMReport())),
      classifier: SyntheticEligibleRuleClassifier(),
      cleanupQuarantineWorkflow: workflow,
      securityScope: SecurityScopeSpy(),
      referenceUnixSeconds: { 1_000_000 },
      supportsCleanupQuarantine: { true }
    )

    _ = try await prepareSingleReview(in: nonNPMModel, at: nonNPMRoot)

    #expect(nonNPMModel.cleanupQuarantineAvailability == .requiresSupportedNPMReview)
    #expect(
      nonNPMModel.executeReviewedCleanup(
        reviewWasConfirmed: true,
        npmStoppedRiskWasAccepted: true
      ) == nil
    )
    #expect(await workflow.executionCount == 0)
  }

  @Test("Both independent confirmations are required without consuming the review")
  func missingConfirmationsDoNotExecute() async throws {
    let root = URL(
      fileURLWithPath: "/private/tmp/devsift-app-confirmations/.npm",
      isDirectory: true
    )
    let workflow = RecordingCleanupQuarantineWorkflow(
      result: .execution(successfulFrontendResult())
    )
    let model = makeNPMModel(root: root, workflow: workflow)

    _ = try await prepareSingleReview(in: model, at: root)

    let attempts = [(false, false), (false, true), (true, false)]
    for (reviewWasConfirmed, npmStoppedRiskWasAccepted) in attempts {
      #expect(
        model.executeReviewedCleanup(
          reviewWasConfirmed: reviewWasConfirmed,
          npmStoppedRiskWasAccepted: npmStoppedRiskWasAccepted
        ) == nil
      )
      guard case .review = model.cleanupReviewPhase else {
        Issue.record("A missing confirmation must retain the current review")
        return
      }
    }
    #expect(await workflow.executionCount == 0)
  }

  @Test("An exact npm review executes once and balances security-scoped access")
  func exactNPMExecutesOnce() async throws {
    let root = URL(
      fileURLWithPath: "/private/tmp/devsift-app-execution/.npm",
      isDirectory: true
    )
    let result = successfulFrontendResult()
    let workflow = GatedCleanupQuarantineWorkflow()
    let scope = SecurityScopeSpy()
    let model = makeNPMModel(root: root, workflow: workflow, securityScope: scope)

    let review = try await prepareSingleReview(in: model, at: root)
    #expect(model.cleanupQuarantineAvailability == .available)

    let task = try #require(
      model.executeReviewedCleanup(
        reviewWasConfirmed: true,
        npmStoppedRiskWasAccepted: true
      )
    )
    #expect(model.cleanupReviewPhase == .executing(review))
    #expect(!model.canRescan)
    try #require(await workflow.waitUntilStarted())

    #expect(
      model.executeReviewedCleanup(
        reviewWasConfirmed: true,
        npmStoppedRiskWasAccepted: true
      ) == nil
    )
    #expect(await workflow.executionCount == 1)
    #expect(scope.snapshot() == .init(starts: [root, root], stops: [root]))

    await workflow.resolve(with: .execution(result))
    await task.value

    #expect(await workflow.executionCount == 1)
    #expect(scope.snapshot() == .init(starts: [root, root], stops: [root, root]))
    #expect(
      model.cleanupReviewPhase
        == .executionResult(CleanupQuarantineResultPresentation(result: result))
    )
  }

  @Test("A workflow-stage failure maps to the bounded failure phase")
  func stageFailureMapping() async throws {
    let root = URL(
      fileURLWithPath: "/private/tmp/devsift-app-failure/.npm",
      isDirectory: true
    )
    let failure = CleanupQuarantineWorkflowStageFailure.rejected(.authorizationAttempt)
    let workflow = RecordingCleanupQuarantineWorkflow(result: .failed(failure))
    let model = makeNPMModel(root: root, workflow: workflow)

    _ = try await prepareSingleReview(in: model, at: root)
    let task = try #require(
      model.executeReviewedCleanup(
        reviewWasConfirmed: true,
        npmStoppedRiskWasAccepted: true
      )
    )
    await task.value

    #expect(model.cleanupReviewPhase == .executionFailed(failure))
    #expect(await workflow.executionCount == 1)
  }

  @Test("A new scan cancels execution and ignores its stale completion")
  func newScanInvalidatesExecution() async throws {
    let firstRoot = URL(
      fileURLWithPath: "/private/tmp/devsift-app-stale-first/.npm",
      isDirectory: true
    )
    let secondRoot = URL(
      fileURLWithPath: "/private/tmp/devsift-app-stale-second/.npm",
      isDirectory: true
    )
    let workflow = GatedCleanupQuarantineWorkflow()
    let scope = SecurityScopeSpy()
    let model = makeNPMModel(root: firstRoot, workflow: workflow, securityScope: scope)

    _ = try await prepareSingleReview(in: model, at: firstRoot)
    let executionTask = try #require(
      model.executeReviewedCleanup(
        reviewWasConfirmed: true,
        npmStoppedRiskWasAccepted: true
      )
    )
    try #require(await workflow.waitUntilStarted())

    await model.startScan(at: secondRoot).value
    guard case .result(let resultRoot, _) = model.phase else {
      Issue.record("Expected the replacement scan result")
      return
    }
    #expect(resultRoot == secondRoot)
    #expect(model.cleanupReviewPhase == .selecting)
    #expect(model.selectedCleanupCandidates.isEmpty)

    await workflow.resolve(with: .execution(successfulFrontendResult()))
    await executionTask.value

    guard case .result(let finalRoot, _) = model.phase else {
      Issue.record("A stale execution must not replace the new scan result")
      return
    }
    #expect(finalRoot == secondRoot)
    #expect(model.cleanupReviewPhase == .selecting)
    #expect(await workflow.cancellationWasObservedAtReturn)
    let scopeSnapshot = scope.snapshot()
    #expect(scopeSnapshot.starts.filter { $0 == firstRoot }.count == 2)
    #expect(scopeSnapshot.stops.filter { $0 == firstRoot }.count == 2)
    #expect(scopeSnapshot.starts.filter { $0 == secondRoot }.count == 1)
    #expect(scopeSnapshot.stops.filter { $0 == secondRoot }.count == 1)
  }

  @Test("Window closure cancels execution and suppresses its late completion")
  func windowClosureInvalidatesExecution() async throws {
    let root = URL(
      fileURLWithPath: "/private/tmp/devsift-app-window-close/.npm",
      isDirectory: true
    )
    let workflow = GatedCleanupQuarantineWorkflow()
    let scope = SecurityScopeSpy()
    let model = makeNPMModel(root: root, workflow: workflow, securityScope: scope)

    _ = try await prepareSingleReview(in: model, at: root)
    let executionTask = try #require(
      model.executeReviewedCleanup(
        reviewWasConfirmed: true,
        npmStoppedRiskWasAccepted: true
      )
    )
    try #require(await workflow.waitUntilStarted())

    model.stopForWindowClosure()
    #expect(model.cleanupReviewPhase == .unavailable)
    #expect(model.cleanupCandidateCount == 0)
    #expect(model.selectedCleanupCandidates.isEmpty)

    await workflow.resolve(with: .failed(.failed(.authorizationIssuance)))
    await executionTask.value

    #expect(model.cleanupReviewPhase == .unavailable)
    #expect(await workflow.cancellationWasObservedAtReturn)
    #expect(scope.snapshot() == .init(starts: [root, root], stops: [root, root]))
  }

  private func makeNPMModel(
    root: URL,
    workflow: any CleanupQuarantineWorkflowExecuting,
    securityScope: any SecurityScopedResourceAccessing = SecurityScopeSpy()
  ) -> ScanViewModel {
    ScanViewModel(
      scanner: ImmediateScanner(outcome: .report(npmReport())),
      classifier: SyntheticNPMRuleClassifier(),
      cleanupQuarantineWorkflow: workflow,
      securityScope: securityScope,
      referenceUnixSeconds: { 1_000_000 },
      supportsCleanupQuarantine: { true }
    )
  }

  private func prepareSingleReview(
    in model: ScanViewModel,
    at root: URL
  ) async throws -> CleanupManifestReviewPresentation {
    await model.startScan(at: root).value
    guard case .result(_, let presentation) = model.phase else {
      Issue.record("Expected a scan result")
      throw TestFixtureError.missingScanResult
    }
    let selection = try #require(presentation.items.first?.cleanupSelection)
    model.setCleanupCandidate(selection, isIncluded: true)
    let planningTask = try #require(model.prepareCleanupReview())
    await planningTask.value
    guard case .review(let review) = model.cleanupReviewPhase else {
      Issue.record("Expected a retained cleanup review")
      throw TestFixtureError.missingCleanupReview
    }
    return review
  }

  private func npmReport() -> ScanReport {
    let device: UInt64 = 42
    let candidate = AppTestReportFactory.item(
      rawComponents: [Array("_cacache".utf8)],
      scanTimeIdentity: FileIdentity(device: device, inode: 2),
      logicalBytes: 8_192,
      allocatedBytes: 4_096,
      hardLinkExclusiveAllocatedBytes: 4_096,
      newestContentModificationUnixSeconds: 0
    )
    return AppTestReportFactory.report(
      root: AppTestReportFactory.item(
        scanTimeIdentity: FileIdentity(device: device, inode: 1),
        logicalBytes: 8_192,
        allocatedBytes: 4_096,
        hardLinkExclusiveAllocatedBytes: 4_096,
        newestContentModificationUnixSeconds: 0
      ),
      topLevelItems: [candidate]
    )
  }

  private func nonNPMReport() -> ScanReport {
    let device: UInt64 = 84
    let candidate = AppTestReportFactory.item(
      rawComponents: [Array("uv".utf8)],
      scanTimeIdentity: FileIdentity(device: device, inode: 2),
      logicalBytes: 8_192,
      allocatedBytes: 4_096,
      hardLinkExclusiveAllocatedBytes: 4_096,
      newestContentModificationUnixSeconds: 0
    )
    return AppTestReportFactory.report(
      root: AppTestReportFactory.item(
        scanTimeIdentity: FileIdentity(device: device, inode: 1),
        logicalBytes: 8_192,
        allocatedBytes: 4_096,
        hardLinkExclusiveAllocatedBytes: 4_096,
        newestContentModificationUnixSeconds: 0
      ),
      topLevelItems: [candidate]
    )
  }
}

private enum TestFixtureError: Error {
  case missingScanResult
  case missingCleanupReview
}

private struct SyntheticNPMRuleClassifier: RuleClassifying, Sendable {
  func classify(
    _ request: RuleClassificationRequest
  ) async throws -> RuleClassificationReport {
    let observations = request.report.topLevelItems.map { summary in
      RuleObservation(
        summary: summary,
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
          newestContentModificationUnixSeconds: .known(
            summary.newestContentModificationUnixSeconds ?? 0
          ),
          activity: .unknown(.notCollected),
          protectedDescendantPresent: .known(false)
        )
      )
    }
    return try await ExplainableRuleClassifier().classify(
      observations: observations,
      referenceUnixSeconds: request.referenceUnixSeconds
    ).binding(to: request)
  }
}

private actor RecordingCleanupQuarantineWorkflow: CleanupQuarantineWorkflowExecuting {
  private(set) var executionCount = 0
  private let result: CleanupQuarantineWorkflowResult

  init(result: CleanupQuarantineWorkflowResult) {
    self.result = result
  }

  func execute(
    _ reviewSession: CleanupApprovalReviewSession
  ) async -> CleanupQuarantineWorkflowResult {
    executionCount += 1
    return result
  }
}

private actor GatedCleanupQuarantineWorkflow: CleanupQuarantineWorkflowExecuting {
  private(set) var executionCount = 0
  private(set) var cancellationWasObservedAtReturn = false
  private var continuation: CheckedContinuation<CleanupQuarantineWorkflowResult, Never>?

  func execute(
    _ reviewSession: CleanupApprovalReviewSession
  ) async -> CleanupQuarantineWorkflowResult {
    executionCount += 1
    let result = await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
    cancellationWasObservedAtReturn = Task.isCancelled
    return result
  }

  func waitUntilStarted(timeout: Duration = .seconds(2)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while executionCount == 0 || continuation == nil {
      guard clock.now < deadline else {
        return false
      }
      try? await clock.sleep(for: .milliseconds(10))
    }
    return true
  }

  func resolve(with result: CleanupQuarantineWorkflowResult) {
    let continuation = continuation
    self.continuation = nil
    continuation?.resume(returning: result)
  }
}

private func successfulFrontendResult() -> CleanupQuarantineFrontendExecutionResult {
  CleanupQuarantineFrontendExecutionResult(
    outcome: .durablyQuarantined(sourceNameWasRecreated: false),
    durabilityEvidence: .terminalReceiptRecorded(producedByRecovery: false),
    namespaceMutation: .none,
    cancellationWasObservedAfterRename: false
  )
}
