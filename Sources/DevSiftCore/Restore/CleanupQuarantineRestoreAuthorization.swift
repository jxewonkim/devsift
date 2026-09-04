import Foundation

/// The explicit assertion required for one exact manual npm-cache restore.
///
/// Constructing this value does not authenticate the caller or prove that npm
/// is inactive. It records only the caller's assertion for one process-local
/// attempt.
enum CleanupQuarantineRestoreConfirmationStatement: String, CaseIterable, Hashable, Sendable {
  /// Restore the contents currently present at the receipt-bound quarantine
  /// item to its original `_cacache` name without overwriting any occupant. The
  /// caller asserts npm is stopped and accepts that the item's contents may
  /// have changed since quarantine.
  case
    restoreCurrentQuarantinedContentsToOriginalCacacheWithoutOverwriteWithNPMStoppedAndPostQuarantineChangesAccepted =
    "restore-current-quarantined-contents-to-original-cacache-without-overwrite-with-npm-stopped-and-post-quarantine-changes-accepted"

  var policyRevision: UInt32 {
    switch self {
    case .restoreCurrentQuarantinedContentsToOriginalCacacheWithoutOverwriteWithNPMStoppedAndPostQuarantineChangesAccepted:
      1
    }
  }
}

/// Canonical journal evidence prepared by the internal restore inventory.
///
/// This value is deliberately not authority. The authorizer decodes the exact
/// quarantine record bytes again and independently derives the restore intent
/// before it creates an attempt.
struct CleanupQuarantineRestorePreparedEvidence: Equatable, Sendable {
  let canonicalQuarantineIntentBytes: Data
  let canonicalQuarantineReceiptBytes: Data
  let restoreIntent: QuarantineRestoreJournalIntentV1
}

/// The bounded, exact subject shown for one restore confirmation.
struct CleanupQuarantineRestoreConfirmationSubject: Hashable, Sendable {
  let restoreTransactionID: String
  let quarantineTransactionID: String
  let originalPath: ScanRelativePath
  let quarantineItemPath: ScanRelativePath
  let responsibleTool: String
}

/// Process-local identity for one restore authorization attempt.
///
/// Reference identity is not serialized and is not an authenticity secret.
private final class CleanupQuarantineRestoreAttemptIdentity: Sendable {}

/// Core-issued request for an explicit assertion about one exact restore.
///
/// Equality includes process-local identity. A request with identical visible
/// fields from another attempt is therefore not substitutable.
struct CleanupQuarantineRestoreConfirmationRequest: Hashable, Sendable {
  let requiredStatement: CleanupQuarantineRestoreConfirmationStatement
  let subject: CleanupQuarantineRestoreConfirmationSubject

  fileprivate let attemptIdentity: CleanupQuarantineRestoreAttemptIdentity

  static func == (
    left: CleanupQuarantineRestoreConfirmationRequest,
    right: CleanupQuarantineRestoreConfirmationRequest
  ) -> Bool {
    left.attemptIdentity === right.attemptIdentity
      && left.requiredStatement == right.requiredStatement
      && left.subject == right.subject
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(attemptIdentity))
    hasher.combine(requiredStatement)
    hasher.combine(subject)
  }
}

/// An explicit caller assertion created for one exact restore request.
///
/// It is process-local and non-serializable. It is not observed npm activity,
/// proof of human action, or standalone filesystem authority.
struct CleanupQuarantineRestoreUserConfirmation: Hashable, Sendable {
  let request: CleanupQuarantineRestoreConfirmationRequest
  let statement: CleanupQuarantineRestoreConfirmationStatement
}

/// Stable failures at the process-local restore authorization boundary.
enum CleanupQuarantineRestoreAuthorizationError: Error, Equatable, Sendable {
  case invalidPreparedEvidence
  case confirmationDoesNotBelongToAttempt
  case confirmationStatementMismatch
  case attemptAlreadyAuthorized
  case attemptCancelled
}

protocol CleanupQuarantineRestoreAuthorizing: Sendable {
  func beginAttempt(
    for evidence: CleanupQuarantineRestorePreparedEvidence
  ) throws -> CleanupQuarantineRestoreAuthorizationSession
}

/// One process-local restore attempt retaining exact, revalidated evidence.
struct CleanupQuarantineRestoreAuthorizationSession: Sendable {
  let confirmationRequest: CleanupQuarantineRestoreConfirmationRequest

  fileprivate let attemptIdentity: CleanupQuarantineRestoreAttemptIdentity
  fileprivate let state: CleanupQuarantineRestoreAttemptState

  /// Atomically issues this attempt's only restore authorization.
  func authorize(
    using confirmation: CleanupQuarantineRestoreUserConfirmation
  ) async throws -> CleanupQuarantineRestoreAuthorization {
    try await state.issue(using: confirmation)
    return CleanupQuarantineRestoreAuthorization(
      attemptIdentity: attemptIdentity,
      state: state
    )
  }

  /// Irreversibly cancels an open or issued attempt. Cancellation cannot undo
  /// an authorization which the internal executor already consumed.
  func cancel() async {
    await state.cancel()
  }
}

/// Process-local, single-use authority to attempt one exact manual restore.
///
/// It grants no standalone filesystem access. Its internal consumer must still
/// reopen and revalidate all journal and filesystem facts while descriptors and
/// the shared journal lock remain held.
struct CleanupQuarantineRestoreAuthorization: Sendable {
  static let currentContractVersion: UInt32 = 1

  let contractVersion: UInt32

  var isSingleUse: Bool { true }
  var authorizesRestoreOnly: Bool { true }
  var authorizesPermanentDeletion: Bool { false }
  var authorizesOverwrite: Bool { false }
  var requiresInlineFilesystemRevalidation: Bool { true }
  var grantsStandaloneFilesystemMutationAuthority: Bool { false }
  var usesWallClockFreshness: Bool { false }

  fileprivate let attemptIdentity: CleanupQuarantineRestoreAttemptIdentity
  fileprivate let state: CleanupQuarantineRestoreAttemptState

  fileprivate init(
    contractVersion: UInt32 = CleanupQuarantineRestoreAuthorization.currentContractVersion,
    attemptIdentity: CleanupQuarantineRestoreAttemptIdentity,
    state: CleanupQuarantineRestoreAttemptState
  ) {
    self.contractVersion = contractVersion
    self.attemptIdentity = attemptIdentity
    self.state = state
  }

  /// Internal handoff reserved for the descriptor-relative restore executor.
  /// Every authorization copy shares one atomic consumption state.
  func consumeForExecution() async throws -> CleanupQuarantineRestoreExecutionClaim {
    try await state.consume(
      contractVersion: contractVersion,
      attemptIdentity: attemptIdentity
    )
  }
}

/// Validates prepared journal evidence and begins process-local restore
/// authorization without reading a clock or accessing the filesystem.
struct CleanupQuarantineRestoreAuthorizer: CleanupQuarantineRestoreAuthorizing, Sendable {
  private static let requiredStatement =
    CleanupQuarantineRestoreConfirmationStatement
    .restoreCurrentQuarantinedContentsToOriginalCacacheWithoutOverwriteWithNPMStoppedAndPostQuarantineChangesAccepted

  func beginAttempt(
    for evidence: CleanupQuarantineRestorePreparedEvidence
  ) throws -> CleanupQuarantineRestoreAuthorizationSession {
    try Task.checkCancellation()

    let normalizedEvidence: CleanupQuarantineRestorePreparedEvidence
    do {
      let quarantineIntent = try QuarantineJournalV1Codec.decodeIntent(
        evidence.canonicalQuarantineIntentBytes
      )
      let quarantineReceipt = try QuarantineJournalV1Codec.decodeReceipt(
        evidence.canonicalQuarantineReceiptBytes,
        matchingIntentBytes: evidence.canonicalQuarantineIntentBytes
      )
      guard quarantineReceipt.outcome == .quarantined else {
        throw CleanupQuarantineRestoreAuthorizationError.invalidPreparedEvidence
      }

      try QuarantineRestoreJournalV1Codec.validate(
        evidence.restoreIntent,
        canonicalQuarantineIntentBytes: evidence.canonicalQuarantineIntentBytes,
        canonicalQuarantineReceiptBytes: evidence.canonicalQuarantineReceiptBytes
      )
      let derivedIntent = try QuarantineRestoreJournalV1Codec.makeIntent(
        restoreTransactionID: evidence.restoreIntent.restoreTransactionID,
        canonicalQuarantineIntentBytes: evidence.canonicalQuarantineIntentBytes,
        canonicalQuarantineReceiptBytes: evidence.canonicalQuarantineReceiptBytes
      )
      guard
        derivedIntent == evidence.restoreIntent,
        derivedIntent.quarantineTransactionID == quarantineIntent.transactionID,
        derivedIntent.sourceComponents == quarantineIntent.sourceComponents
      else {
        throw CleanupQuarantineRestoreAuthorizationError.invalidPreparedEvidence
      }
      normalizedEvidence = CleanupQuarantineRestorePreparedEvidence(
        canonicalQuarantineIntentBytes: evidence.canonicalQuarantineIntentBytes,
        canonicalQuarantineReceiptBytes: evidence.canonicalQuarantineReceiptBytes,
        restoreIntent: derivedIntent
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw CleanupQuarantineRestoreAuthorizationError.invalidPreparedEvidence
    }

    try Task.checkCancellation()
    let attemptIdentity = CleanupQuarantineRestoreAttemptIdentity()
    let intent = normalizedEvidence.restoreIntent
    let request = CleanupQuarantineRestoreConfirmationRequest(
      requiredStatement: Self.requiredStatement,
      subject: CleanupQuarantineRestoreConfirmationSubject(
        restoreTransactionID: intent.restoreTransactionID,
        quarantineTransactionID: intent.quarantineTransactionID,
        originalPath: ScanRelativePath(rawComponents: intent.sourceComponents),
        quarantineItemPath: ScanRelativePath(
          rawComponents: [
            DescriptorExclusiveQuarantineMover.quarantineRootBytes,
            intent.quarantineItemComponent,
          ]
        ),
        responsibleTool: "npm"
      ),
      attemptIdentity: attemptIdentity
    )
    let state = CleanupQuarantineRestoreAttemptState(
      evidence: normalizedEvidence,
      request: request,
      attemptIdentity: attemptIdentity
    )
    try Task.checkCancellation()
    return CleanupQuarantineRestoreAuthorizationSession(
      confirmationRequest: request,
      attemptIdentity: attemptIdentity,
      state: state
    )
  }
}

enum CleanupQuarantineRestoreAuthorizationConsumptionError: Error, Equatable, Sendable {
  case unsupportedContractVersion
  case authorizationDoesNotBelongToAttempt
  case authorizationAlreadyConsumed
  case authorizationCancelled
}

/// Exact retained evidence released only after the authorization's atomic
/// single-use transition. This remains internal with its future sole executor.
struct CleanupQuarantineRestoreExecutionClaim: Sendable {
  let evidence: CleanupQuarantineRestorePreparedEvidence
  let confirmation: CleanupQuarantineRestoreUserConfirmation

  fileprivate init(
    evidence: CleanupQuarantineRestorePreparedEvidence,
    confirmation: CleanupQuarantineRestoreUserConfirmation
  ) {
    self.evidence = evidence
    self.confirmation = confirmation
  }
}

private actor CleanupQuarantineRestoreAttemptState {
  private enum Phase {
    case open
    case issued
    case consumed
    case cancelled
  }

  private let attemptIdentity: CleanupQuarantineRestoreAttemptIdentity
  private var request: CleanupQuarantineRestoreConfirmationRequest?
  private var phase: Phase = .open
  private var evidence: CleanupQuarantineRestorePreparedEvidence?
  private var issuedConfirmation: CleanupQuarantineRestoreUserConfirmation?

  init(
    evidence: CleanupQuarantineRestorePreparedEvidence,
    request: CleanupQuarantineRestoreConfirmationRequest,
    attemptIdentity: CleanupQuarantineRestoreAttemptIdentity
  ) {
    self.evidence = evidence
    self.request = request
    self.attemptIdentity = attemptIdentity
  }

  func issue(
    using confirmation: CleanupQuarantineRestoreUserConfirmation
  ) throws {
    guard !Task.isCancelled else {
      cancelRetainedState()
      throw CancellationError()
    }

    switch phase {
    case .open:
      break
    case .issued, .consumed:
      throw CleanupQuarantineRestoreAuthorizationError.attemptAlreadyAuthorized
    case .cancelled:
      throw CleanupQuarantineRestoreAuthorizationError.attemptCancelled
    }

    guard let request else {
      cancelRetainedState()
      throw CleanupQuarantineRestoreAuthorizationError.attemptCancelled
    }
    guard confirmation.request.attemptIdentity === attemptIdentity else {
      throw CleanupQuarantineRestoreAuthorizationError.confirmationDoesNotBelongToAttempt
    }
    guard confirmation.request == request else {
      throw CleanupQuarantineRestoreAuthorizationError.confirmationDoesNotBelongToAttempt
    }
    guard confirmation.statement == request.requiredStatement else {
      throw CleanupQuarantineRestoreAuthorizationError.confirmationStatementMismatch
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
    attemptIdentity suppliedIdentity: CleanupQuarantineRestoreAttemptIdentity
  ) throws -> CleanupQuarantineRestoreExecutionClaim {
    guard !Task.isCancelled else {
      cancelRetainedState()
      throw CancellationError()
    }
    guard contractVersion == CleanupQuarantineRestoreAuthorization.currentContractVersion else {
      throw CleanupQuarantineRestoreAuthorizationConsumptionError.unsupportedContractVersion
    }
    guard suppliedIdentity === attemptIdentity else {
      throw CleanupQuarantineRestoreAuthorizationConsumptionError
        .authorizationDoesNotBelongToAttempt
    }

    switch phase {
    case .open:
      throw CleanupQuarantineRestoreAuthorizationConsumptionError
        .authorizationDoesNotBelongToAttempt
    case .issued:
      break
    case .consumed:
      throw CleanupQuarantineRestoreAuthorizationConsumptionError.authorizationAlreadyConsumed
    case .cancelled:
      throw CleanupQuarantineRestoreAuthorizationConsumptionError.authorizationCancelled
    }

    guard let evidence, let issuedConfirmation else {
      cancelRetainedState()
      throw CleanupQuarantineRestoreAuthorizationConsumptionError.authorizationCancelled
    }
    phase = .consumed
    self.evidence = nil
    self.issuedConfirmation = nil
    return CleanupQuarantineRestoreExecutionClaim(
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
