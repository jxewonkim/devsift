import Foundation
import Testing

@testable import DevSiftCore

struct AuthorizationTestApproval {
  let source: ApprovalTestSource
  let approval: CleanupApproval
}

private struct AuthorizationExactNameRule: ExplainableRule {
  let definition: RuleDefinition
  let rawName: [UInt8]

  func assess(_ observation: RuleObservation) -> RuleAssessment {
    guard observation.summary.path.rawComponents == [rawName] else {
      return RuleAssessment(recognition: .unrecognized, findings: [])
    }
    return RuleAssessment(
      recognition: .recognized,
      findings: definition.checks.map { check in
        RuleFinding(
          identifier: check.identifier,
          kind: check.kind == .positiveEvidence ? .positiveEvidence : .exclusion,
          state: .satisfied,
          explanation: check.explanation
        )
      }
    )
  }
}

func authorizationPendingApproval(
  rawNames: [[UInt8]] = [Array("candidate".utf8)],
  root: URL = URL(fileURLWithPath: "/synthetic/AuthorizationRoot", isDirectory: true)
) async throws -> AuthorizationTestApproval {
  let source = try await approvalPendingPreconditionTestSource(
    rawNames: rawNames,
    root: root
  )
  return try authorizationApproval(from: source)
}

func authorizationNonPendingApproval(
  rawNames: [[UInt8]] = [Array("candidate".utf8)],
  root: URL = URL(fileURLWithPath: "/synthetic/AuthorizationRoot", isDirectory: true)
) async throws -> AuthorizationTestApproval {
  let source = try await approvalTestSource(rawNames: rawNames, root: root)
  return try authorizationApproval(from: source)
}

func authorizationBuiltInNPMApproval() async throws -> AuthorizationTestApproval {
  let candidate = PlanningTestCandidate(
    rawName: Array("_cacache".utf8),
    identity: FileIdentity(device: 42, inode: 2),
    facts: satisfiedRuleFacts(activity: .unknown(.notCollected))
  )
  let scenario = try await makePlanningTestScenario(candidates: [candidate])
  let source = ApprovalTestSource(
    classificationRequest: scenario.classificationRequest,
    classificationReport: scenario.classificationReport,
    selections: [scenario.selection(for: candidate.path)]
  )
  return try authorizationApproval(from: source)
}

func authorizationMixedToolPendingApproval() async throws -> AuthorizationTestApproval {
  let firstName = Array("alpha-cache".utf8)
  let secondName = Array("beta-cache".utf8)
  let firstDefinition = authorizationDeferredDefinition(
    identifier: "devsift.test.authorization-alpha",
    responsibleTool: "Alpha tool"
  )
  let secondDefinition = authorizationDeferredDefinition(
    identifier: "devsift.test.authorization-beta",
    responsibleTool: "Beta tool"
  )
  let candidates = [firstName, secondName].enumerated().map { index, rawName in
    PlanningTestCandidate(
      rawName: rawName,
      identity: FileIdentity(device: 42, inode: UInt64(index + 2)),
      facts: satisfiedRuleFacts(activity: .unknown(.notCollected))
    )
  }
  let scenario = try await makePlanningTestScenario(
    candidates: candidates,
    rules: [
      AuthorizationExactNameRule(definition: firstDefinition, rawName: firstName),
      AuthorizationExactNameRule(definition: secondDefinition, rawName: secondName),
    ]
  )
  let source = ApprovalTestSource(
    classificationRequest: scenario.classificationRequest,
    classificationReport: scenario.classificationReport,
    selections: candidates.map { scenario.selection(for: $0.path) }
  )
  return try authorizationApproval(from: source)
}

private func authorizationDeferredDefinition(
  identifier: String,
  responsibleTool: String
) -> RuleDefinition {
  let base = syntheticDefinition(
    id: identifier,
    disposition: .reviewRequired,
    reproducibility: .conditional,
    activity: .mustBeInactiveOrDeferToAttestationWhenUnobserved
  )
  return RuleDefinition(
    revision: base.revision,
    displayName: base.displayName,
    responsibleTool: responsibleTool,
    recognitionExplanation: base.recognitionExplanation,
    eligibleDisposition: base.eligibleDisposition,
    reproducibility: base.reproducibility,
    ageRequirement: base.ageRequirement,
    activityRequirement: base.activityRequirement,
    checks: base.checks
  )
}

private func authorizationApproval(
  from source: ApprovalTestSource
) throws -> AuthorizationTestApproval {
  let approver = CleanupApprover()
  let session = try approver.beginReview(source.manifestRequest)
  let approval = try approver.approve(
    CleanupApprovalRequest(
      session: session,
      confirmations: try approvalConfirmations(from: session),
      preconditionReviewAcknowledgements: try approvalPreconditionReviewAcknowledgements(
        from: session
      )
    )
  )
  return AuthorizationTestApproval(source: source, approval: approval)
}

func syntheticAuthorizationSession(
  for approval: CleanupApproval
) throws -> CleanupQuarantineAuthorizationSession {
  try syntheticAuthorizationAuthorizer(for: approval).beginAttempt(for: approval)
}

func syntheticAuthorizationAuthorizer(
  for approval: CleanupApproval
) -> CleanupQuarantineAuthorizer {
  guard let entry = approval.reviewedManifest.entries.first else {
    preconditionFailure("Authorization test approvals must contain an entry")
  }
  return CleanupQuarantineAuthorizer(
    supportedPolicyProvenance: approval.reviewedManifest.policyProvenance,
    supportedClassificationContractRevision: approval.reviewedManifest.policyProvenance
      .classificationContractRevision,
    supportedCatalogRevision: approval.reviewedManifest.policyProvenance.catalogRevision,
    supportedRuleRevision: entry.ruleRevision,
    responsibleTool: entry.responsibleTool
  )
}

func authorizationAttestation(
  for session: CleanupQuarantineAuthorizationSession
) -> CleanupQuarantineUserAttestation {
  CleanupQuarantineUserAttestation(
    request: session.attestationRequest,
    statement: session.attestationRequest.requiredStatement
  )
}

func expectAuthorizationError(
  _ expected: CleanupQuarantineAuthorizationError,
  sourceLocation: SourceLocation = #_sourceLocation,
  performing operation: () throws -> Void
) {
  do {
    try operation()
    Issue.record(
      "Expected cleanup quarantine authorization error \(expected)",
      sourceLocation: sourceLocation
    )
  } catch let error as CleanupQuarantineAuthorizationError {
    #expect(error == expected, sourceLocation: sourceLocation)
  } catch {
    Issue.record(
      "Unexpected cleanup quarantine authorization error \(error)",
      sourceLocation: sourceLocation
    )
  }
}

func expectAuthorizationError(
  _ expected: CleanupQuarantineAuthorizationError,
  sourceLocation: SourceLocation = #_sourceLocation,
  performing operation: () async throws -> Void
) async {
  do {
    try await operation()
    Issue.record(
      "Expected cleanup quarantine authorization error \(expected)",
      sourceLocation: sourceLocation
    )
  } catch let error as CleanupQuarantineAuthorizationError {
    #expect(error == expected, sourceLocation: sourceLocation)
  } catch {
    Issue.record(
      "Unexpected cleanup quarantine authorization error \(error)",
      sourceLocation: sourceLocation
    )
  }
}

func expectAuthorizationConsumptionError(
  _ expected: CleanupQuarantineAuthorizationConsumptionError,
  sourceLocation: SourceLocation = #_sourceLocation,
  performing operation: () async throws -> Void
) async {
  do {
    try await operation()
    Issue.record(
      "Expected cleanup quarantine consumption error \(expected)",
      sourceLocation: sourceLocation
    )
  } catch let error as CleanupQuarantineAuthorizationConsumptionError {
    #expect(error == expected, sourceLocation: sourceLocation)
  } catch {
    Issue.record(
      "Unexpected cleanup quarantine consumption error \(error)",
      sourceLocation: sourceLocation
    )
  }
}

func expectAuthorizationCancellation(
  sourceLocation: SourceLocation = #_sourceLocation,
  performing operation: () async throws -> Void
) async {
  do {
    try await operation()
    Issue.record("Expected CancellationError", sourceLocation: sourceLocation)
  } catch is CancellationError {
  } catch {
    Issue.record("Unexpected cancellation error \(error)", sourceLocation: sourceLocation)
  }
}

func isEncodableAuthorizationValue(_ value: Any) -> Bool {
  value is any Encodable
}

actor AuthorizationStartGate {
  private let participantCount: Int
  private var arrivedCount = 0
  private var continuations: [CheckedContinuation<Void, Never>] = []

  init(participantCount: Int) {
    self.participantCount = participantCount
    continuations.reserveCapacity(participantCount)
  }

  func arriveAndWait() async {
    await withCheckedContinuation { continuation in
      arrivedCount += 1
      if arrivedCount == participantCount {
        let waiting = continuations
        continuations.removeAll(keepingCapacity: false)
        continuation.resume()
        for continuation in waiting {
          continuation.resume()
        }
      } else {
        continuations.append(continuation)
      }
    }
  }
}

enum AuthorizationRaceOutcome: Sendable {
  case success
  case expectedFailure
  case unexpectedFailure(String)
}

enum AuthorizationIssueCancelOutcome: Sendable {
  case issued(CleanupQuarantineAuthorization)
  case cancelled
  case unexpectedFailure(String)
}

enum AuthorizationConsumeCancelOutcome: Sendable {
  case consumed(CleanupQuarantineExecutionClaim)
  case cancelled
  case unexpectedFailure(String)
}
