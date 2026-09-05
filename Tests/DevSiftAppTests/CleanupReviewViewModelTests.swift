import DevSiftCore
import Foundation
import Testing

@testable import DevSiftApp
@testable import DevSiftCore

@MainActor
@Suite("Cleanup draft review view model")
struct CleanupReviewViewModelTests {
  @Test("An exact eligible selection produces an identity-free review off the main actor")
  func successfulReview() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/app-draft-review", isDirectory: true)
    let report = eligibleReport()
    let classificationRecorder = RuleClassificationRequestRecorder()
    let approver = RecordingCleanupApprover()
    let scope = SecurityScopeSpy()
    let model = ScanViewModel(
      scanner: ImmediateScanner(outcome: .report(report)),
      classifier: SyntheticEligibleRuleClassifier(recorder: classificationRecorder),
      cleanupApprover: approver,
      securityScope: scope,
      referenceUnixSeconds: { 1_000_000 }
    )

    await model.startScan(at: root).value

    guard case .result(_, let presentation) = model.phase else {
      Issue.record("Expected a scan result")
      return
    }
    let selection = try #require(presentation.items.first?.cleanupSelection)
    #expect(model.cleanupReviewPhase == .selecting)
    #expect(model.cleanupCandidateCount == 1)
    #expect(model.selectedCleanupCandidates.isEmpty)
    #expect(model.prepareCleanupReview() == nil)

    let forgedPath = CleanupCandidateSelection(
      path: ScanRelativePath(rawComponents: [Array("forged".utf8)]),
      ruleRevision: selection.ruleRevision
    )
    model.setCleanupCandidate(forgedPath, isIncluded: true)
    #expect(model.selectedCleanupCandidates.isEmpty)

    let mismatchedRevision = CleanupCandidateSelection(
      path: selection.path,
      ruleRevision: RuleRevision(
        identifier: selection.ruleRevision.identifier,
        version: try #require(
          RuleVersion(rawValue: selection.ruleRevision.version.rawValue + 1)
        )
      )
    )
    model.setCleanupCandidate(mismatchedRevision, isIncluded: true)
    #expect(model.selectedCleanupCandidates.isEmpty)

    model.setCleanupCandidate(selection, isIncluded: true)
    #expect(model.selectedCleanupCandidates == [selection])
    #expect(model.canPrepareCleanupReview)

    let task = try #require(model.prepareCleanupReview())
    guard case .preparing(let selectedCount) = model.cleanupReviewPhase else {
      Issue.record("Expected draft preparation")
      return
    }
    #expect(selectedCount == 1)
    await task.value

    guard case .review(let review) = model.cleanupReviewPhase else {
      Issue.record("Expected an in-memory draft review")
      return
    }
    #expect(review.entryCount == 1)
    #expect(review.entries.first?.id == selection.path)
    #expect(review.totals.observedAllocatedBytes == 4_096)
    #expect(approver.snapshot().ranOnMainThread == false)
    let planningRequest = try #require(approver.snapshot().requests.first)
    let classificationRequest = try #require(await classificationRecorder.requests().first)
    #expect(planningRequest.classificationRequest == classificationRequest)
    #expect(planningRequest.classificationReport == presentation.classification)
    #expect(planningRequest.selections == [selection])
    #expect(scope.snapshot() == .init(starts: [root], stops: [root]))

    model.dismissCleanupReview()
    #expect(model.cleanupReviewPhase == .selecting)
    #expect(model.selectedCleanupCandidates == [selection])
    model.clearCleanupCandidates()
    #expect(model.selectedCleanupCandidates.isEmpty)
  }

  @Test("Planner errors fail closed without leaking their payload")
  func planningFailure() async throws {
    let privateRoot = "/private/tmp/PRIVATE-PLANNING-ROOT"
    let root = URL(fileURLWithPath: privateRoot, isDirectory: true)
    let model = ScanViewModel(
      scanner: ImmediateScanner(outcome: .report(eligibleReport())),
      classifier: SyntheticEligibleRuleClassifier(),
      cleanupApprover: FailingCleanupApprover(),
      securityScope: SecurityScopeSpy(),
      referenceUnixSeconds: { 1_000_000 }
    )

    await model.startScan(at: root).value
    guard case .result(_, let presentation) = model.phase else {
      Issue.record("Expected a scan result")
      return
    }
    let selection = try #require(presentation.items.first?.cleanupSelection)
    model.setCleanupCandidate(selection, isIncluded: true)
    await model.prepareCleanupReview()?.value

    guard case .failed(let failure) = model.cleanupReviewPhase else {
      Issue.record("Expected a bounded planning failure")
      return
    }
    #expect(failure == .planning)
    #expect(failure.message.contains(privateRoot) == false)
    #expect(failure.message.contains("PRIVATE-ERROR-PAYLOAD") == false)
    #expect(model.selectedCleanupCandidates == [selection])
    #expect(model.canPrepareCleanupReview)
  }

  @Test("Cancellation immediately discards a frozen review snapshot")
  func planningCancellation() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/cancel-app-draft", isDirectory: true)
    let approver = GatedCleanupApprover()
    let model = ScanViewModel(
      scanner: ImmediateScanner(outcome: .report(eligibleReport())),
      classifier: SyntheticEligibleRuleClassifier(),
      cleanupApprover: approver,
      securityScope: SecurityScopeSpy(),
      referenceUnixSeconds: { 1_000_000 }
    )

    await model.startScan(at: root).value
    guard case .result(_, let presentation) = model.phase else {
      Issue.record("Expected a scan result")
      return
    }
    let selection = try #require(presentation.items.first?.cleanupSelection)
    model.setCleanupCandidate(selection, isIncluded: true)
    let task = try #require(model.prepareCleanupReview())
    try #require(await approver.waitUntilStarted())

    model.setCleanupCandidate(selection, isIncluded: false)
    model.clearCleanupCandidates()
    #expect(model.selectedCleanupCandidates == [selection])

    model.cancelCleanupReviewPreparation()
    #expect(model.cleanupReviewPhase == .selecting)
    #expect(model.selectedCleanupCandidates == [selection])

    approver.resolve()
    await task.value
    #expect(model.cleanupReviewPhase == .selecting)
  }

  @Test("A new scan invalidates selection and ignores a late planner success")
  func newScanInvalidatesPlanning() async throws {
    let firstRoot = URL(fileURLWithPath: "/private/tmp/first-app-draft", isDirectory: true)
    let secondRoot = URL(fileURLWithPath: "/private/tmp/second-app-draft", isDirectory: true)
    let approver = GatedCleanupApprover()
    let scope = SecurityScopeSpy()
    let model = ScanViewModel(
      scanner: ImmediateScanner(outcome: .report(eligibleReport())),
      classifier: SyntheticEligibleRuleClassifier(),
      cleanupApprover: approver,
      securityScope: scope,
      referenceUnixSeconds: { 1_000_000 }
    )

    await model.startScan(at: firstRoot).value
    guard case .result(_, let firstPresentation) = model.phase else {
      Issue.record("Expected the first scan result")
      return
    }
    let selection = try #require(firstPresentation.items.first?.cleanupSelection)
    model.setCleanupCandidate(selection, isIncluded: true)
    let planningTask = try #require(model.prepareCleanupReview())
    try #require(await approver.waitUntilStarted())

    await model.startScan(at: secondRoot).value
    guard case .result(let resultRoot, _) = model.phase else {
      Issue.record("Expected the second scan result")
      return
    }
    #expect(resultRoot == secondRoot)
    #expect(model.cleanupReviewPhase == .selecting)
    #expect(model.selectedCleanupCandidates.isEmpty)

    approver.resolve()
    await planningTask.value
    guard case .result(let finalRoot, _) = model.phase else {
      Issue.record("A late draft must not replace the scan result")
      return
    }
    #expect(finalRoot == secondRoot)
    #expect(model.cleanupReviewPhase == .selecting)
    #expect(model.selectedCleanupCandidates.isEmpty)
    #expect(
      scope.snapshot()
        == .init(starts: [firstRoot, secondRoot], stops: [firstRoot, secondRoot])
    )
  }

  @Test("Window closure discards all planning state")
  func windowClosure() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/window-close-draft", isDirectory: true)
    let model = ScanViewModel(
      scanner: ImmediateScanner(outcome: .report(eligibleReport())),
      classifier: SyntheticEligibleRuleClassifier(),
      securityScope: SecurityScopeSpy(),
      referenceUnixSeconds: { 1_000_000 }
    )

    await model.startScan(at: root).value
    guard case .result(_, let presentation) = model.phase else {
      Issue.record("Expected a scan result")
      return
    }
    let selection = try #require(presentation.items.first?.cleanupSelection)
    model.setCleanupCandidate(selection, isIncluded: true)

    model.stopForWindowClosure()

    #expect(model.cleanupReviewPhase == .unavailable)
    #expect(model.cleanupCandidateCount == 0)
    #expect(model.selectedCleanupCandidates.isEmpty)
  }

  @Test("Draft review announcements state their non-authority boundary")
  func accessibilityAnnouncements() async throws {
    let manifest = try await makeEligibleManifest()
    let review = try CleanupManifestReviewPresentation.prepare(manifest: manifest)

    #expect(
      CleanupReviewAccessibility.announcement(
        from: .selecting,
        to: .preparing(selectedCount: 1)
      ) == "Preparing an in-memory draft for 1 selected item. No files are being changed."
    )
    #expect(
      CleanupReviewAccessibility.announcement(
        from: .preparing(selectedCount: 1),
        to: .review(review)
      ) == "Unapproved draft ready with 1 item. No files were changed."
    )
    #expect(
      CleanupReviewAccessibility.announcement(
        from: .preparing(selectedCount: 1),
        to: .selecting
      ) == "Draft preparation cancelled. No files were changed."
    )
    #expect(
      CleanupReviewAccessibility.announcement(
        from: .selecting,
        to: .failed(.planning)
      ) == "Draft review unavailable. No files were changed."
    )
    #expect(
      CleanupReviewAccessibility.announcement(from: .unavailable, to: .selecting) == nil
    )
  }

  private func eligibleReport() -> ScanReport {
    let device: UInt64 = 42
    let item = AppTestReportFactory.item(
      rawComponents: [Array("uv".utf8)],
      scanTimeIdentity: FileIdentity(device: device, inode: 2),
      logicalBytes: 8_192,
      allocatedBytes: 4_096,
      hardLinkExclusiveAllocatedBytes: 3_072,
      newestContentModificationUnixSeconds: 0
    )
    return AppTestReportFactory.report(
      root: AppTestReportFactory.item(
        scanTimeIdentity: FileIdentity(device: device, inode: 1),
        logicalBytes: 8_192,
        allocatedBytes: 4_096,
        hardLinkExclusiveAllocatedBytes: 3_072,
        newestContentModificationUnixSeconds: 0
      ),
      topLevelItems: [item]
    )
  }

  private func makeEligibleManifest() async throws -> CleanupManifest {
    let request = RuleClassificationRequest(
      root: URL(fileURLWithPath: "/private/tmp/announcement-draft", isDirectory: true),
      report: eligibleReport(),
      referenceUnixSeconds: 1_000_000
    )
    let classifier = SyntheticEligibleRuleClassifier()
    let classification = try await classifier.classify(request)
    let revision = try #require(classification.evaluations.first?.rule)
    return try CleanupPlanner().makeManifest(
      CleanupManifestRequest(
        classificationRequest: request,
        classificationReport: classification,
        selections: [
          CleanupCandidateSelection(
            path: ScanRelativePath(rawComponents: [Array("uv".utf8)]),
            ruleRevision: revision
          )
        ]
      )
    )
  }

}

private final class RecordingCleanupApprover: CleanupApproving, @unchecked Sendable {
  struct Snapshot {
    let requests: [CleanupManifestRequest]
    let ranOnMainThread: Bool?
  }

  private let lock = NSLock()
  private var requests: [CleanupManifestRequest] = []
  private var ranOnMainThread: Bool?

  func beginReview(_ request: CleanupManifestRequest) throws -> CleanupApprovalReviewSession {
    lock.withLock {
      requests.append(request)
      ranOnMainThread = Thread.isMainThread
    }
    return try CleanupApprover().beginReview(request)
  }

  func approve(_ request: CleanupApprovalRequest) throws -> CleanupApproval {
    try CleanupApprover().approve(request)
  }

  func snapshot() -> Snapshot {
    lock.withLock {
      Snapshot(requests: requests, ranOnMainThread: ranOnMainThread)
    }
  }
}

private struct FailingCleanupApprover: CleanupApproving, Sendable {
  func beginReview(_ request: CleanupManifestRequest) throws -> CleanupApprovalReviewSession {
    throw PrivatePlanningError("PRIVATE-ERROR-PAYLOAD")
  }

  func approve(_ request: CleanupApprovalRequest) throws -> CleanupApproval {
    throw PrivatePlanningError("PRIVATE-ERROR-PAYLOAD")
  }
}

private struct PrivatePlanningError: Error {
  let value: String

  init(_ value: String) {
    self.value = value
  }
}

private final class GatedCleanupApprover: CleanupApproving, @unchecked Sendable {
  private let condition = NSCondition()
  private var isStarted = false
  private var isReleased = false

  func beginReview(_ request: CleanupManifestRequest) throws -> CleanupApprovalReviewSession {
    let session = try CleanupApprover().beginReview(request)
    condition.lock()
    isStarted = true
    condition.broadcast()
    while !isReleased {
      condition.wait()
    }
    condition.unlock()
    return session
  }

  func approve(_ request: CleanupApprovalRequest) throws -> CleanupApproval {
    try CleanupApprover().approve(request)
  }

  func waitUntilStarted(timeout: Duration = .seconds(2)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !startedSnapshot() {
      guard clock.now < deadline else {
        return false
      }
      try? await clock.sleep(for: .milliseconds(10))
    }
    return true
  }

  func resolve() {
    condition.lock()
    isReleased = true
    condition.broadcast()
    condition.unlock()
  }

  private func startedSnapshot() -> Bool {
    condition.lock()
    let value = isStarted
    condition.unlock()
    return value
  }
}
