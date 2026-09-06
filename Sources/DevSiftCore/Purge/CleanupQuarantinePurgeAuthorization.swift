import Foundation

/// The two separately confirmed irreversible purge paths.
enum CleanupQuarantinePurgeAttemptKind: String, CaseIterable, Hashable, Sendable {
  case initial
  case explicitRetry = "explicit-retry"
}

/// The exact assertion required before one receipt-bound purge pass.
///
/// These statements are intentionally distinct. A confirmation for initial
/// staging cannot authorize deletion of an interrupted work tree, and a retry
/// confirmation cannot authorize a new staging rename.
enum CleanupQuarantinePurgeConfirmationStatement: String, CaseIterable, Hashable, Sendable {
  /// Permanently delete the current receipt-bound quarantined contents. The
  /// caller accepts the restore cutoff and partial-deletion model, asserts npm
  /// and other work using the item are stopped, accepts unobserved activity and
  /// post-quarantine changes, and accepts that observed capacity may increase
  /// by zero bytes or be unavailable.
  case initialPermanentDeletionRisksAccepted =
    "permanently-delete-current-receipt-bound-quarantined-contents-with-restore-cutoff-and-partial-deletion-risk-npm-and-other-work-stopped-unobserved-activity-and-post-quarantine-change-risk-capacity-may-increase-by-zero-or-be-unavailable-accepted"

  /// Continue permanent deletion of the exact staged remainder. The caller
  /// accepts that restore is already unavailable and deletion may remain
  /// partial, asserts npm and other work using the item are stopped, accepts
  /// unobserved activity and post-quarantine changes, and accepts that observed
  /// capacity may increase by zero bytes or be unavailable.
  case explicitRetryPermanentDeletionRisksAccepted =
    "continue-permanent-deletion-of-exact-receipt-bound-staged-remainder-with-restore-unavailable-and-partial-deletion-risk-npm-and-other-work-stopped-unobserved-activity-and-post-quarantine-change-risk-capacity-may-increase-by-zero-or-be-unavailable-accepted"

  var attemptKind: CleanupQuarantinePurgeAttemptKind {
    switch self {
    case .initialPermanentDeletionRisksAccepted:
      .initial
    case .explicitRetryPermanentDeletionRisksAccepted:
      .explicitRetry
    }
  }

  var policyRevision: UInt32 { 1 }
}

/// Canonical evidence for a new purge intent that has not yet been published.
struct CleanupQuarantinePurgeInitialPreparedEvidence: Equatable, Sendable {
  let canonicalQuarantineIntentBytes: Data
  let canonicalQuarantineReceiptBytes: Data
  let purgeIntent: QuarantinePurgeJournalIntentV1
}

/// Canonical evidence for an existing receipt-less purge intent and the exact
/// work object currently selected for an explicitly authorized retry.
/// `currentWorkBinding` cannot represent ACL state; the descriptor-relative
/// executor must always recheck the named and opened work directory's ACL
/// inline before it attempts any mutation.
struct CleanupQuarantinePurgeRetryPreparedEvidence: Equatable, Sendable {
  let canonicalQuarantineIntentBytes: Data
  let canonicalQuarantineReceiptBytes: Data
  let purgeIntent: QuarantinePurgeJournalIntentV1
  let canonicalPurgeIntentBytes: Data
  let currentWorkBinding: QuarantineJournalFileBindingV1
}

/// Exact internal inventory evidence retained for one purge authorization.
///
/// This enum is deliberately not authority and not `Codable`. Its case fixes
/// whether execution may publish and stage a new intent or may only continue
/// deleting an already staged work tree.
enum CleanupQuarantinePurgePreparedEvidence: Equatable, Sendable {
  case initial(CleanupQuarantinePurgeInitialPreparedEvidence)
  case explicitRetry(CleanupQuarantinePurgeRetryPreparedEvidence)

  var attemptKind: CleanupQuarantinePurgeAttemptKind {
    switch self {
    case .initial:
      .initial
    case .explicitRetry:
      .explicitRetry
    }
  }

  fileprivate var purgeIntent: QuarantinePurgeJournalIntentV1 {
    switch self {
    case .initial(let evidence):
      evidence.purgeIntent
    case .explicitRetry(let evidence):
      evidence.purgeIntent
    }
  }
}

/// The deliberately bounded subject shown for permanent-deletion consent.
/// Exact record bytes, identifiers, paths, and managed components stay inside
/// the process-local attempt state.
struct CleanupQuarantinePurgeConfirmationSubject: Hashable, Sendable {
  let responsibleTool: String
  let originalName: String
}

/// Process-local identity for one exact purge authorization attempt.
///
/// Reference identity is not serialized and is not an authenticity secret.
private final class CleanupQuarantinePurgeAttemptIdentity: Sendable {}

/// Core-issued request for one exact irreversible purge assertion.
///
/// Equality includes process-local identity, so a same-looking request from a
/// different attempt cannot be substituted.
struct CleanupQuarantinePurgeConfirmationRequest: Hashable, Sendable {
  let attemptKind: CleanupQuarantinePurgeAttemptKind
  let requiredStatement: CleanupQuarantinePurgeConfirmationStatement
  let subject: CleanupQuarantinePurgeConfirmationSubject

  fileprivate let attemptIdentity: CleanupQuarantinePurgeAttemptIdentity

  static func == (
    left: CleanupQuarantinePurgeConfirmationRequest,
    right: CleanupQuarantinePurgeConfirmationRequest
  ) -> Bool {
    left.attemptIdentity === right.attemptIdentity
      && left.attemptKind == right.attemptKind
      && left.requiredStatement == right.requiredStatement
      && left.subject == right.subject
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(attemptIdentity))
    hasher.combine(attemptKind)
    hasher.combine(requiredStatement)
    hasher.combine(subject)
  }
}

/// One explicit caller assertion tied to one exact process-local request.
///
/// It is neither observed process activity nor standalone filesystem authority.
struct CleanupQuarantinePurgeUserConfirmation: Hashable, Sendable {
  let request: CleanupQuarantinePurgeConfirmationRequest
  let statement: CleanupQuarantinePurgeConfirmationStatement
}

enum CleanupQuarantinePurgeAuthorizationError: Error, Equatable, Sendable {
  case invalidPreparedEvidence
  case confirmationDoesNotBelongToAttempt
  case confirmationStatementMismatch
  case attemptAlreadyAuthorized
  case attemptCancelled
}

protocol CleanupQuarantinePurgeAuthorizing: Sendable {
  func beginAttempt(
    for evidence: CleanupQuarantinePurgePreparedEvidence
  ) throws -> CleanupQuarantinePurgeAuthorizationSession
}

/// One process-local purge attempt retaining exact, normalized evidence.
struct CleanupQuarantinePurgeAuthorizationSession: Sendable {
  let confirmationRequest: CleanupQuarantinePurgeConfirmationRequest

  fileprivate let attemptIdentity: CleanupQuarantinePurgeAttemptIdentity
  fileprivate let state: CleanupQuarantinePurgeAttemptState

  /// Atomically issues this attempt's only purge authorization.
  func authorize(
    using confirmation: CleanupQuarantinePurgeUserConfirmation
  ) async throws -> CleanupQuarantinePurgeAuthorization {
    try await state.issue(using: confirmation)
    return CleanupQuarantinePurgeAuthorization(
      attemptKind: confirmationRequest.attemptKind,
      attemptIdentity: attemptIdentity,
      state: state
    )
  }

  /// Irreversibly cancels an open or issued attempt. It cannot revoke a claim
  /// the future internal purge executor already consumed.
  func cancel() async {
    await state.cancel()
  }
}

/// Process-local, single-use authority for one exact receipt-bound purge pass.
///
/// It grants no path-based mutation capability. The future descriptor-relative
/// executor must consume it and revalidate every retained journal and
/// filesystem fact inline while holding the shared journal lock.
struct CleanupQuarantinePurgeAuthorization: Sendable {
  static let currentContractVersion: UInt32 = 1

  let contractVersion: UInt32
  let attemptKind: CleanupQuarantinePurgeAttemptKind

  var isSingleUse: Bool { true }
  var authorizesPurgeOnly: Bool { true }
  var authorizesPermanentDeletion: Bool { true }
  var authorizesRestore: Bool { false }
  var authorizesOverwrite: Bool { false }
  var authorizesArbitraryPaths: Bool { false }
  var authorizesActiveCacheDeletion: Bool { false }
  var authorizesOnlyExactStagedWorkTree: Bool { true }
  var requiresInlineFilesystemRevalidation: Bool { true }
  var requiresInlineACLRevalidation: Bool { true }
  var grantsStandaloneFilesystemMutationAuthority: Bool { false }
  var usesWallClockFreshness: Bool { false }

  fileprivate let attemptIdentity: CleanupQuarantinePurgeAttemptIdentity
  fileprivate let state: CleanupQuarantinePurgeAttemptState

  fileprivate init(
    contractVersion: UInt32 = CleanupQuarantinePurgeAuthorization.currentContractVersion,
    attemptKind: CleanupQuarantinePurgeAttemptKind,
    attemptIdentity: CleanupQuarantinePurgeAttemptIdentity,
    state: CleanupQuarantinePurgeAttemptState
  ) {
    self.contractVersion = contractVersion
    self.attemptKind = attemptKind
    self.attemptIdentity = attemptIdentity
    self.state = state
  }

  /// Internal handoff reserved for the descriptor-relative purge executor.
  /// Every copy shares one atomic consumption state.
  func consumeForExecution() async throws -> CleanupQuarantinePurgeExecutionClaim {
    try await state.consume(
      contractVersion: contractVersion,
      attemptKind: attemptKind,
      attemptIdentity: attemptIdentity
    )
  }
}

/// Validates exact prepared journal evidence and begins an authorization
/// attempt without filesystem access or wall-clock freshness.
struct CleanupQuarantinePurgeAuthorizer: CleanupQuarantinePurgeAuthorizing, Sendable {
  func beginAttempt(
    for evidence: CleanupQuarantinePurgePreparedEvidence
  ) throws -> CleanupQuarantinePurgeAuthorizationSession {
    try Task.checkCancellation()
    let normalizedEvidence = try normalize(evidence)
    try Task.checkCancellation()

    let attemptIdentity = CleanupQuarantinePurgeAttemptIdentity()
    let attemptKind = normalizedEvidence.attemptKind
    let requiredStatement = requiredStatement(for: attemptKind)
    guard
      requiredStatement.policyRevision
        == normalizedEvidence.purgeIntent.purgePolicyRevision
    else {
      throw CleanupQuarantinePurgeAuthorizationError.invalidPreparedEvidence
    }
    let request = CleanupQuarantinePurgeConfirmationRequest(
      attemptKind: attemptKind,
      requiredStatement: requiredStatement,
      subject: CleanupQuarantinePurgeConfirmationSubject(
        responsibleTool: "npm",
        originalName: "_cacache"
      ),
      attemptIdentity: attemptIdentity
    )
    let state = CleanupQuarantinePurgeAttemptState(
      evidence: normalizedEvidence,
      request: request,
      attemptIdentity: attemptIdentity
    )
    try Task.checkCancellation()
    return CleanupQuarantinePurgeAuthorizationSession(
      confirmationRequest: request,
      attemptIdentity: attemptIdentity,
      state: state
    )
  }

  private func normalize(
    _ evidence: CleanupQuarantinePurgePreparedEvidence
  ) throws -> CleanupQuarantinePurgePreparedEvidence {
    do {
      switch evidence {
      case .initial(let initial):
        let derivedIntent = try QuarantinePurgeJournalV1Codec.makeIntent(
          purgeTransactionID: initial.purgeIntent.purgeTransactionID,
          capacityBefore: initial.purgeIntent.capacityBefore,
          canonicalQuarantineIntentBytes: initial.canonicalQuarantineIntentBytes,
          canonicalQuarantineReceiptBytes: initial.canonicalQuarantineReceiptBytes
        )
        guard derivedIntent == initial.purgeIntent else {
          throw CleanupQuarantinePurgeAuthorizationError.invalidPreparedEvidence
        }
        return .initial(
          CleanupQuarantinePurgeInitialPreparedEvidence(
            canonicalQuarantineIntentBytes: initial.canonicalQuarantineIntentBytes,
            canonicalQuarantineReceiptBytes: initial.canonicalQuarantineReceiptBytes,
            purgeIntent: derivedIntent
          )
        )

      case .explicitRetry(let retry):
        let decodedIntent = try QuarantinePurgeJournalV1Codec.decodeIntent(
          retry.canonicalPurgeIntentBytes,
          matchingQuarantineIntentBytes: retry.canonicalQuarantineIntentBytes,
          matchingQuarantineReceiptBytes: retry.canonicalQuarantineReceiptBytes
        )
        guard
          decodedIntent == retry.purgeIntent,
          workBinding(retry.currentWorkBinding, matches: decodedIntent.candidateBinding)
        else {
          throw CleanupQuarantinePurgeAuthorizationError.invalidPreparedEvidence
        }
        return .explicitRetry(
          CleanupQuarantinePurgeRetryPreparedEvidence(
            canonicalQuarantineIntentBytes: retry.canonicalQuarantineIntentBytes,
            canonicalQuarantineReceiptBytes: retry.canonicalQuarantineReceiptBytes,
            purgeIntent: decodedIntent,
            canonicalPurgeIntentBytes: retry.canonicalPurgeIntentBytes,
            currentWorkBinding: retry.currentWorkBinding
          )
        )
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw CleanupQuarantinePurgeAuthorizationError.invalidPreparedEvidence
    }
  }

  private func requiredStatement(
    for attemptKind: CleanupQuarantinePurgeAttemptKind
  ) -> CleanupQuarantinePurgeConfirmationStatement {
    switch attemptKind {
    case .initial:
      .initialPermanentDeletionRisksAccepted
    case .explicitRetry:
      .explicitRetryPermanentDeletionRisksAccepted
    }
  }

  private func workBinding(
    _ current: QuarantineJournalFileBindingV1,
    matches historical: QuarantineJournalFileBindingV1
  ) -> Bool {
    current.device == historical.device
      && current.inode == historical.inode
      && current.generation == historical.generation
      && current.birthSeconds == historical.birthSeconds
      && current.birthNanoseconds == historical.birthNanoseconds
      && current.kind == .directory
      && current.kind == historical.kind
      && current.ownerUID != 0
      && current.ownerUID == historical.ownerUID
      && current.permissionMode <= 0o7777
      && current.permissionMode & 0o022 == 0
      && current.flags == 0
      && current.linkCount >= 2
  }
}

enum CleanupQuarantinePurgeAuthorizationConsumptionError: Error, Equatable, Sendable {
  case unsupportedContractVersion
  case authorizationDoesNotBelongToAttempt
  case authorizationAlreadyConsumed
  case authorizationCancelled
}

/// Exact retained evidence released only after the atomic single-use
/// transition. This remains internal with its future sole purge executor.
struct CleanupQuarantinePurgeExecutionClaim: Sendable {
  let attemptKind: CleanupQuarantinePurgeAttemptKind
  let evidence: CleanupQuarantinePurgePreparedEvidence
  let confirmation: CleanupQuarantinePurgeUserConfirmation

  fileprivate init(
    attemptKind: CleanupQuarantinePurgeAttemptKind,
    evidence: CleanupQuarantinePurgePreparedEvidence,
    confirmation: CleanupQuarantinePurgeUserConfirmation
  ) {
    self.attemptKind = attemptKind
    self.evidence = evidence
    self.confirmation = confirmation
  }
}

private actor CleanupQuarantinePurgeAttemptState {
  private enum Phase {
    case open
    case issued
    case consumed
    case cancelled
  }

  private let attemptIdentity: CleanupQuarantinePurgeAttemptIdentity
  private let attemptKind: CleanupQuarantinePurgeAttemptKind
  private var request: CleanupQuarantinePurgeConfirmationRequest?
  private var phase: Phase = .open
  private var evidence: CleanupQuarantinePurgePreparedEvidence?
  private var issuedConfirmation: CleanupQuarantinePurgeUserConfirmation?

  init(
    evidence: CleanupQuarantinePurgePreparedEvidence,
    request: CleanupQuarantinePurgeConfirmationRequest,
    attemptIdentity: CleanupQuarantinePurgeAttemptIdentity
  ) {
    self.evidence = evidence
    self.request = request
    self.attemptIdentity = attemptIdentity
    attemptKind = evidence.attemptKind
  }

  func issue(
    using confirmation: CleanupQuarantinePurgeUserConfirmation
  ) throws {
    guard !Task.isCancelled else {
      cancelRetainedState()
      throw CancellationError()
    }

    switch phase {
    case .open:
      break
    case .issued, .consumed:
      throw CleanupQuarantinePurgeAuthorizationError.attemptAlreadyAuthorized
    case .cancelled:
      throw CleanupQuarantinePurgeAuthorizationError.attemptCancelled
    }

    guard let request else {
      cancelRetainedState()
      throw CleanupQuarantinePurgeAuthorizationError.attemptCancelled
    }
    guard confirmation.request.attemptIdentity === attemptIdentity else {
      throw CleanupQuarantinePurgeAuthorizationError.confirmationDoesNotBelongToAttempt
    }
    guard confirmation.request == request else {
      throw CleanupQuarantinePurgeAuthorizationError.confirmationDoesNotBelongToAttempt
    }
    guard
      confirmation.statement == request.requiredStatement,
      confirmation.statement.attemptKind == attemptKind
    else {
      throw CleanupQuarantinePurgeAuthorizationError.confirmationStatementMismatch
    }
    guard !Task.isCancelled else {
      cancelRetainedState()
      throw CancellationError()
    }

    issuedConfirmation = confirmation
    self.request = nil
    phase = .issued
  }

  func consume(
    contractVersion: UInt32,
    attemptKind suppliedAttemptKind: CleanupQuarantinePurgeAttemptKind,
    attemptIdentity suppliedIdentity: CleanupQuarantinePurgeAttemptIdentity
  ) throws -> CleanupQuarantinePurgeExecutionClaim {
    guard !Task.isCancelled else {
      cancelRetainedState()
      throw CancellationError()
    }
    guard contractVersion == CleanupQuarantinePurgeAuthorization.currentContractVersion else {
      throw CleanupQuarantinePurgeAuthorizationConsumptionError.unsupportedContractVersion
    }
    guard suppliedIdentity === attemptIdentity,
      suppliedAttemptKind == attemptKind
    else {
      throw CleanupQuarantinePurgeAuthorizationConsumptionError
        .authorizationDoesNotBelongToAttempt
    }

    switch phase {
    case .open:
      throw CleanupQuarantinePurgeAuthorizationConsumptionError
        .authorizationDoesNotBelongToAttempt
    case .issued:
      break
    case .consumed:
      throw CleanupQuarantinePurgeAuthorizationConsumptionError.authorizationAlreadyConsumed
    case .cancelled:
      throw CleanupQuarantinePurgeAuthorizationConsumptionError.authorizationCancelled
    }

    guard let evidence, let issuedConfirmation else {
      cancelRetainedState()
      throw CleanupQuarantinePurgeAuthorizationConsumptionError.authorizationCancelled
    }
    phase = .consumed
    self.evidence = nil
    self.issuedConfirmation = nil
    return CleanupQuarantinePurgeExecutionClaim(
      attemptKind: attemptKind,
      evidence: evidence,
      confirmation: issuedConfirmation
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
      evidence = nil
      issuedConfirmation = nil
    case .consumed, .cancelled:
      break
    }
  }
}
