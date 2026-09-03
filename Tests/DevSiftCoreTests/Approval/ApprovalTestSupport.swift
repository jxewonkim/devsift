import Foundation
import Testing

@testable import DevSiftCore

let approvalTestRuleDefinition = syntheticDefinition(
  id: "devsift.test.approval-session"
)

struct ApprovalTestSource {
  let classificationRequest: RuleClassificationRequest
  let classificationReport: RuleClassificationReport
  let selections: [CleanupCandidateSelection]

  var manifestRequest: CleanupManifestRequest {
    request(selections: selections)
  }

  func request(
    selections: [CleanupCandidateSelection]
  ) -> CleanupManifestRequest {
    CleanupManifestRequest(
      classificationRequest: classificationRequest,
      classificationReport: classificationReport,
      selections: selections
    )
  }
}

func approvalTestSource(
  rawNames: [[UInt8]] = [Array("a-cache".utf8), Array("b-cache".utf8)],
  root: URL = URL(fileURLWithPath: "/synthetic/ApprovalRoot", isDirectory: true)
) async throws -> ApprovalTestSource {
  let candidates = rawNames.enumerated().map { index, rawName in
    PlanningTestCandidate(
      rawName: rawName,
      identity: FileIdentity(device: 42, inode: UInt64(index + 2)),
      recursiveSize: StorageSize(
        logicalBytes: UInt64((index + 1) * 2_000),
        allocatedBytes: UInt64((index + 1) * 1_500)
      ),
      hardLinkExclusiveAllocatedBytes: UInt64((index + 1) * 1_250)
    )
  }
  let scenario = try await makePlanningTestScenario(
    candidates: candidates,
    rules: [SyntheticRule(definition: approvalTestRuleDefinition)]
  )
  let classificationRequest = RuleClassificationRequest(
    root: root,
    report: scenario.classificationRequest.report,
    referenceUnixSeconds: scenario.classificationRequest.referenceUnixSeconds
  )
  let classificationReport = scenario.classificationReport.binding(
    to: classificationRequest
  )
  let selections = candidates.map { candidate in
    CleanupCandidateSelection(
      path: candidate.path,
      ruleRevision: approvalTestRuleDefinition.revision
    )
  }

  return ApprovalTestSource(
    classificationRequest: classificationRequest,
    classificationReport: classificationReport,
    selections: selections
  )
}

func approvalConfirmations(
  from session: CleanupApprovalReviewSession
) throws -> [CleanupApprovalEntryConfirmation] {
  try session.entryReferences.map { reference in
    try session.confirm(reference)
  }
}

func expectApprovalError(
  _ expected: CleanupApprovalError,
  sourceLocation: SourceLocation = #_sourceLocation,
  performing operation: () throws -> Void
) {
  do {
    try operation()
    Issue.record(
      "Expected cleanup approval error \(expected)",
      sourceLocation: sourceLocation
    )
  } catch let error as CleanupApprovalError {
    #expect(error == expected, sourceLocation: sourceLocation)
  } catch {
    Issue.record(
      "Unexpected cleanup approval error \(error)",
      sourceLocation: sourceLocation
    )
  }
}

func expectApprovalPlanningError(
  _ expected: CleanupPlanningError,
  sourceLocation: SourceLocation = #_sourceLocation,
  performing operation: () throws -> Void
) {
  do {
    try operation()
    Issue.record(
      "Expected cleanup planning error \(expected)",
      sourceLocation: sourceLocation
    )
  } catch let error as CleanupPlanningError {
    #expect(error == expected, sourceLocation: sourceLocation)
  } catch {
    Issue.record(
      "Unexpected cleanup planning error \(error)",
      sourceLocation: sourceLocation
    )
  }
}

func isEncodableApprovalValue(_ value: Any) -> Bool {
  value is any Encodable
}
