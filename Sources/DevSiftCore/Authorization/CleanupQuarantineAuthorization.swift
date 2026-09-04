import Foundation

/// The explicit statement required for the currently supported quarantine
/// precondition.
///
/// Creating this value records a caller assertion. It does not authenticate
/// the caller or prove that DevSift observed the responsible tool's activity.
public enum CleanupQuarantineAttestationStatement: String, CaseIterable, Hashable, Sendable {
  case responsibleToolStoppedAndUnobservedActivityRiskAccepted =
    "responsible-tool-stopped-and-unobserved-activity-risk-accepted"

  public var policyRevision: UInt32 {
    switch self {
    case .responsibleToolStoppedAndUnobservedActivityRiskAccepted:
      1
    }
  }
}

/// One canonical pending requirement covered by an attempt-scoped statement.
public struct CleanupQuarantineAttestationSubject: Hashable, Sendable {
  public let ordinal: Int
  public let path: ScanRelativePath
  public let ruleRevision: RuleRevision
  public let responsibleTool: String
  public let precondition: RuleDeferredExecutionPrecondition
}

/// Process-local identity for one authorization attempt.
///
/// Reference identity is deliberately not serialized, persisted, or treated
/// as an authenticity secret.
private final class CleanupQuarantineAttemptIdentity: Sendable {}

/// A Core-issued request for one statement covering the entire canonical set
/// of pending requirements in one exact approval.
///
/// Equality includes process-local attempt identity. A same-looking request
/// from another attempt is therefore not substitutable.
public struct CleanupQuarantineAttestationRequest: Hashable, Sendable {
  public let requiredStatement: CleanupQuarantineAttestationStatement
  public let subjects: [CleanupQuarantineAttestationSubject]

  fileprivate let attemptIdentity: CleanupQuarantineAttemptIdentity

  public static func == (
    left: CleanupQuarantineAttestationRequest,
    right: CleanupQuarantineAttestationRequest
  ) -> Bool {
    left.attemptIdentity === right.attemptIdentity
      && left.requiredStatement == right.requiredStatement
      && left.subjects == right.subjects
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(attemptIdentity))
    hasher.combine(requiredStatement)
    hasher.combine(subjects)
  }
}

/// An explicit caller assertion created for one exact attempt request.
///
/// This value is intentionally process-local and non-serializable. It is not
/// observed activity evidence, caller authentication, or standalone authority
/// to mutate the filesystem.
public struct CleanupQuarantineUserAttestation: Hashable, Sendable {
  public let request: CleanupQuarantineAttestationRequest
  public let statement: CleanupQuarantineAttestationStatement

  public init(
    request: CleanupQuarantineAttestationRequest,
    statement: CleanupQuarantineAttestationStatement
  ) {
    self.request = request
    self.statement = statement
  }
}

/// Stable, bounded failures at the attempt-scoped authorization boundary.
public enum CleanupQuarantineAuthorizationError: Error, Equatable, Sendable {
  case invalidApproval(CleanupApprovalInvariant)
  case unsupportedApprovalPolicy
  case noPendingExecutionPreconditions
  case unsupportedAttestationRequirements
  case attestationDoesNotBelongToAttempt
  case attestationStatementMismatch
  case attemptAlreadyAuthorized
  case attemptCancelled
}

/// Begins process-local quarantine authorization attempts without filesystem
/// access.
public protocol CleanupQuarantineAuthorizing: Sendable {
  func beginAttempt(
    for approval: CleanupApproval
  ) throws -> CleanupQuarantineAuthorizationSession
}

/// A process-local attempt which retains one exact approval and exposes only
/// its fresh attestation request.
public struct CleanupQuarantineAuthorizationSession: Sendable {
  public let attestationRequest: CleanupQuarantineAttestationRequest

  fileprivate let attemptIdentity: CleanupQuarantineAttemptIdentity
  fileprivate let state: CleanupQuarantineAttemptState

  /// Atomically issues this attempt's only authorization.
  ///
  /// The attestation must carry this session's exact request and required
  /// statement. Concurrent or repeated issuance fails closed.
  public func authorize(
    using attestation: CleanupQuarantineUserAttestation
  ) async throws -> CleanupQuarantineAuthorization {
    try await state.issue(using: attestation)
    return CleanupQuarantineAuthorization(
      attemptIdentity: attemptIdentity,
      state: state
    )
  }

  /// Irreversibly cancels an open or issued attempt and releases its retained
  /// approval. Cancellation cannot undo an authorization already consumed by
  /// a future executor.
  public func cancel() async {
    await state.cancel()
  }
}

/// A process-local, single-use authorization record for a recoverable
/// quarantine attempt.
///
/// This value grants no standalone filesystem mutation capability. A future
/// executor must consume it exactly once and still perform descriptor-relative
/// filesystem revalidation immediately before every operation.
public struct CleanupQuarantineAuthorization: Sendable {
  public static let currentContractVersion: UInt32 = 1

  public let contractVersion: UInt32

  public var isSingleUse: Bool { true }
  public var authorizesRecoverableQuarantineOnly: Bool { true }
  public var authorizesPermanentDeletion: Bool { false }
  public var requiresInlineFilesystemRevalidation: Bool { true }
  public var grantsStandaloneFilesystemMutationAuthority: Bool { false }
  public var usesWallClockFreshness: Bool { false }

  fileprivate let attemptIdentity: CleanupQuarantineAttemptIdentity
  fileprivate let state: CleanupQuarantineAttemptState

  fileprivate init(
    contractVersion: UInt32 = CleanupQuarantineAuthorization.currentContractVersion,
    attemptIdentity: CleanupQuarantineAttemptIdentity,
    state: CleanupQuarantineAttemptState
  ) {
    self.contractVersion = contractVersion
    self.attemptIdentity = attemptIdentity
    self.state = state
  }

  /// Internal handoff reserved for a future descriptor-relative executor.
  /// Every copy of this authorization shares the same atomic consumption
  /// state, so exactly one handoff can succeed.
  func consumeForExecution() async throws -> CleanupQuarantineExecutionClaim {
    try await state.consume(
      contractVersion: contractVersion,
      attemptIdentity: attemptIdentity
    )
  }
}

/// Creates authorization attempts from canonical approvals without scanning,
/// observing processes, reading a clock, or mutating the filesystem.
public struct CleanupQuarantineAuthorizer: CleanupQuarantineAuthorizing, Sendable {
  private let supportedPolicyProvenance: RulePolicyProvenance
  private let supportedPolicyMarker: CleanupQuarantineAuthorizationPolicyMarker
  private let supportedAttestationRequirement: CleanupQuarantineAttestationRequirement

  public init() {
    supportedPolicyProvenance = .currentBuiltIn
    supportedPolicyMarker = .authorizationV1BuiltIn
    supportedAttestationRequirement = .authorizationV1BuiltInNPM
  }

  init(
    supportedPolicyProvenance: RulePolicyProvenance,
    supportedClassificationContractRevision: RuleRevision,
    supportedCatalogRevision: RuleRevision,
    supportedRuleRevision: RuleRevision,
    responsibleTool: String
  ) {
    self.supportedPolicyProvenance = supportedPolicyProvenance
    supportedPolicyMarker = CleanupQuarantineAuthorizationPolicyMarker(
      classificationContractRevision: supportedClassificationContractRevision,
      catalogRevision: supportedCatalogRevision
    )
    supportedAttestationRequirement = CleanupQuarantineAttestationRequirement(
      ruleRevision: supportedRuleRevision,
      responsibleTool: responsibleTool,
      precondition: .requiresUserAttestationThatResponsibleToolIsStopped,
      preconditionPolicyRevision: 1,
      statement: .responsibleToolStoppedAndUnobservedActivityRiskAccepted,
      statementPolicyRevision: 1
    )
  }

  public func beginAttempt(
    for approval: CleanupApproval
  ) throws -> CleanupQuarantineAuthorizationSession {
    try Task.checkCancellation()
    do {
      try CleanupApprovalValidator.validate(
        approval,
        supportedPolicyProvenance: supportedPolicyProvenance
      )
    } catch let error as CleanupApprovalValidationError {
      switch error {
      case .invalid(let invariant):
        throw CleanupQuarantineAuthorizationError.invalidApproval(invariant)
      case .unsupportedPolicy:
        throw CleanupQuarantineAuthorizationError.unsupportedApprovalPolicy
      }
    }
    guard
      approval.reviewedManifest.policyProvenance.classificationContractRevision
        == supportedPolicyMarker.classificationContractRevision,
      approval.reviewedManifest.policyProvenance.catalogRevision
        == supportedPolicyMarker.catalogRevision
    else {
      throw CleanupQuarantineAuthorizationError.unsupportedApprovalPolicy
    }

    let subjects = try attestationSubjects(for: approval.reviewedManifest)
    guard !subjects.isEmpty else {
      throw CleanupQuarantineAuthorizationError.noPendingExecutionPreconditions
    }
    try Task.checkCancellation()

    let attemptIdentity = CleanupQuarantineAttemptIdentity()
    let request = CleanupQuarantineAttestationRequest(
      requiredStatement: supportedAttestationRequirement.statement,
      subjects: subjects,
      attemptIdentity: attemptIdentity
    )
    let state = CleanupQuarantineAttemptState(
      approval: approval,
      request: request,
      attemptIdentity: attemptIdentity
    )
    try Task.checkCancellation()
    return CleanupQuarantineAuthorizationSession(
      attestationRequest: request,
      attemptIdentity: attemptIdentity,
      state: state
    )
  }

  private func attestationSubjects(
    for manifest: CleanupManifest
  ) throws -> [CleanupQuarantineAttestationSubject] {
    var subjects: [CleanupQuarantineAttestationSubject] = []
    subjects.reserveCapacity(
      manifest.entries.reduce(into: 0) { count, entry in
        count += entry.deferredExecutionPreconditions.count
      }
    )

    for entry in manifest.entries {
      for precondition in entry.deferredExecutionPreconditions {
        try Task.checkCancellation()
        guard
          entry.ruleRevision == supportedAttestationRequirement.ruleRevision,
          entry.responsibleTool == supportedAttestationRequirement.responsibleTool,
          precondition == supportedAttestationRequirement.precondition,
          precondition.policyRevision
            == supportedAttestationRequirement.preconditionPolicyRevision,
          supportedAttestationRequirement.statement.policyRevision
            == supportedAttestationRequirement.statementPolicyRevision
        else {
          throw CleanupQuarantineAuthorizationError.unsupportedAttestationRequirements
        }
        subjects.append(
          CleanupQuarantineAttestationSubject(
            ordinal: subjects.count,
            path: entry.path,
            ruleRevision: entry.ruleRevision,
            responsibleTool: entry.responsibleTool,
            precondition: precondition
          )
        )
      }
    }
    return subjects
  }
}

private struct CleanupQuarantineAuthorizationPolicyMarker: Sendable {
  let classificationContractRevision: RuleRevision
  let catalogRevision: RuleRevision

  static let authorizationV1BuiltIn = CleanupQuarantineAuthorizationPolicyMarker(
    classificationContractRevision: pinnedAuthorizationRevision(
      identifier: "devsift.classification.explainable",
      version: 3
    ),
    catalogRevision: pinnedAuthorizationRevision(
      identifier: "devsift.builtin-rules",
      version: 6
    )
  )
}

private struct CleanupQuarantineAttestationRequirement: Sendable {
  let ruleRevision: RuleRevision
  let responsibleTool: String
  let precondition: RuleDeferredExecutionPrecondition
  let preconditionPolicyRevision: UInt32
  let statement: CleanupQuarantineAttestationStatement
  let statementPolicyRevision: UInt32

  static let authorizationV1BuiltInNPM = CleanupQuarantineAttestationRequirement(
    ruleRevision: pinnedAuthorizationRevision(
      identifier: "devsift.cache.npm",
      version: 5
    ),
    responsibleTool: "npm",
    precondition: .requiresUserAttestationThatResponsibleToolIsStopped,
    preconditionPolicyRevision: 1,
    statement: .responsibleToolStoppedAndUnobservedActivityRiskAccepted,
    statementPolicyRevision: 1
  )
}

private func pinnedAuthorizationRevision(
  identifier: String,
  version: UInt32
) -> RuleRevision {
  guard
    let identifier = RuleIdentifier(rawValue: identifier),
    let version = RuleVersion(rawValue: version)
  else {
    preconditionFailure("The pinned authorization revision is invalid")
  }
  return RuleRevision(identifier: identifier, version: version)
}

enum CleanupQuarantineAuthorizationConsumptionError: Error, Equatable, Sendable {
  case unsupportedContractVersion
  case authorizationDoesNotBelongToAttempt
  case authorizationAlreadyConsumed
  case authorizationCancelled
}

/// Exact retained values released only after the authorization's atomic
/// single-use transition. This is intentionally internal until an executor
/// exists.
struct CleanupQuarantineExecutionClaim: Sendable {
  let approval: CleanupApproval
  let attestation: CleanupQuarantineUserAttestation

  fileprivate init(
    approval: CleanupApproval,
    attestation: CleanupQuarantineUserAttestation
  ) {
    self.approval = approval
    self.attestation = attestation
  }
}

private actor CleanupQuarantineAttemptState {
  private enum Phase {
    case open
    case issued
    case consumed
    case cancelled
  }

  private let attemptIdentity: CleanupQuarantineAttemptIdentity
  private var request: CleanupQuarantineAttestationRequest?
  private var phase: Phase = .open
  private var approval: CleanupApproval?
  private var issuedAttestation: CleanupQuarantineUserAttestation?

  init(
    approval: CleanupApproval,
    request: CleanupQuarantineAttestationRequest,
    attemptIdentity: CleanupQuarantineAttemptIdentity
  ) {
    self.approval = approval
    self.request = request
    self.attemptIdentity = attemptIdentity
  }

  func issue(
    using attestation: CleanupQuarantineUserAttestation
  ) throws {
    guard !Task.isCancelled else {
      cancelRetainedState()
      throw CancellationError()
    }

    switch phase {
    case .open:
      break
    case .issued, .consumed:
      throw CleanupQuarantineAuthorizationError.attemptAlreadyAuthorized
    case .cancelled:
      throw CleanupQuarantineAuthorizationError.attemptCancelled
    }

    guard let request else {
      cancelRetainedState()
      throw CleanupQuarantineAuthorizationError.attemptCancelled
    }
    guard attestation.request.attemptIdentity === attemptIdentity else {
      throw CleanupQuarantineAuthorizationError.attestationDoesNotBelongToAttempt
    }
    guard attestation.request == request else {
      throw CleanupQuarantineAuthorizationError.attestationDoesNotBelongToAttempt
    }
    guard attestation.statement == request.requiredStatement else {
      throw CleanupQuarantineAuthorizationError.attestationStatementMismatch
    }
    guard !Task.isCancelled else {
      cancelRetainedState()
      throw CancellationError()
    }

    issuedAttestation = attestation
    self.request = nil
    phase = .issued
  }

  func consume(
    contractVersion: UInt32,
    attemptIdentity suppliedIdentity: CleanupQuarantineAttemptIdentity
  ) throws -> CleanupQuarantineExecutionClaim {
    guard !Task.isCancelled else {
      cancelRetainedState()
      throw CancellationError()
    }
    guard contractVersion == CleanupQuarantineAuthorization.currentContractVersion else {
      throw CleanupQuarantineAuthorizationConsumptionError.unsupportedContractVersion
    }
    guard suppliedIdentity === attemptIdentity else {
      throw CleanupQuarantineAuthorizationConsumptionError
        .authorizationDoesNotBelongToAttempt
    }

    switch phase {
    case .open:
      throw CleanupQuarantineAuthorizationConsumptionError
        .authorizationDoesNotBelongToAttempt
    case .issued:
      break
    case .consumed:
      throw CleanupQuarantineAuthorizationConsumptionError.authorizationAlreadyConsumed
    case .cancelled:
      throw CleanupQuarantineAuthorizationConsumptionError.authorizationCancelled
    }

    guard let approval, let issuedAttestation else {
      cancelRetainedState()
      throw CleanupQuarantineAuthorizationConsumptionError.authorizationCancelled
    }
    phase = .consumed
    self.approval = nil
    self.issuedAttestation = nil
    return CleanupQuarantineExecutionClaim(
      approval: approval,
      attestation: issuedAttestation
    )
  }

  func cancel() {
    cancelRetainedState()
  }

  private func cancelRetainedState() {
    switch phase {
    case .open, .issued:
      phase = .cancelled
      request = nil
      approval = nil
      issuedAttestation = nil
    case .consumed, .cancelled:
      break
    }
  }
}
