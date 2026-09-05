import DevSiftCore

enum CleanupQuarantinePresentationTone: Equatable, Sendable {
  case success
  case warning
  case failure
}

/// A bounded, path-free rendering of one Core quarantine attempt.
///
/// The presentation deliberately does not expose transaction identifiers or
/// claim reclaimed capacity. Inventory refresh remains the source of truth for
/// any later restore action.
struct CleanupQuarantineResultPresentation: Equatable, Sendable {
  let tone: CleanupQuarantinePresentationTone
  let title: String
  let message: String
  let durabilityMessage: String
  let namespaceMessage: String?
  let cancellationMessage: String?
  let performedPermanentDeletion: Bool
  let guaranteedFreedBytes: UInt64

  init(result: CleanupQuarantineFrontendExecutionResult) {
    tone = Self.tone(for: result.outcome)
    title = Self.title(for: result.outcome)
    message = Self.message(for: result.outcome)
    durabilityMessage = Self.durabilityMessage(for: result.durabilityEvidence)
    namespaceMessage = Self.namespaceMessage(for: result.namespaceMutation)
    cancellationMessage =
      result.cancellationWasObservedAfterRename
      ? "Cancellation was requested after the move boundary. DevSift finished reconciliation before reporting this result."
      : nil
    performedPermanentDeletion = result.performedPermanentDeletion
    guaranteedFreedBytes = result.guaranteedFreedBytes
  }

  private static func tone(
    for outcome: CleanupQuarantineFrontendOutcome
  ) -> CleanupQuarantinePresentationTone {
    switch outcome {
    case .durablyQuarantined:
      .success
    case .notStarted, .notMoved:
      .failure
    case .quarantinedWithoutTerminalReceipt, .rolledBack, .manualRecoveryRequired:
      .warning
    }
  }

  private static func title(for outcome: CleanupQuarantineFrontendOutcome) -> String {
    switch outcome {
    case .durablyQuarantined:
      "Moved to quarantine"
    case .quarantinedWithoutTerminalReceipt:
      "Move needs recovery"
    case .notStarted:
      "Quarantine did not start"
    case .notMoved:
      "Item was not moved"
    case .rolledBack:
      "Move was rolled back"
    case .manualRecoveryRequired:
      "Manual recovery is required"
    }
  }

  private static func message(for outcome: CleanupQuarantineFrontendOutcome) -> String {
    switch outcome {
    case .durablyQuarantined(let sourceNameWasRecreated):
      if sourceNameWasRecreated {
        return
          "The reviewed npm cache was durably quarantined, but another object now occupies its original name. Review the recovery inventory before restoring."
      }
      return
        "The reviewed npm cache was moved out of npm's active namespace and a terminal receipt was recorded. It can be considered for an explicit restore."
    case .quarantinedWithoutTerminalReceipt(let sourceNameWasRecreated):
      let suffix =
        sourceNameWasRecreated
        ? " Another object also occupies the original name."
        : ""
      return
        "The item may have moved, but no terminal receipt proves completion. Open recovery inventory before another operation.\(suffix)"
    case .notStarted(let reason):
      return notStartedMessage(reason)
    case .notMoved(let reason):
      return notMovedMessage(reason)
    case .rolledBack(let reason):
      return rollbackMessage(reason)
    case .manualRecoveryRequired(let locationWasObserved, let reason):
      let location =
        locationWasObserved
        ? "A possible quarantine location was observed. "
        : "No trustworthy quarantine location could be reported. "
      return location + manualRecoveryMessage(reason)
    }
  }

  private static func durabilityMessage(
    for evidence: CleanupQuarantineFrontendDurabilityEvidence
  ) -> String {
    switch evidence {
    case .notRecorded:
      "No durable transaction record was established."
    case .intentRecorded:
      "A durable intent exists, but a terminal receipt is still pending."
    case .terminalReceiptRecorded(let producedByRecovery):
      producedByRecovery
        ? "A terminal receipt was validated and completed by recovery."
        : "A terminal receipt was durably recorded."
    case .unresolved:
      "The durable journal is unresolved and blocks another conflicting operation."
    }
  }

  private static func namespaceMessage(
    for mutation: CleanupQuarantineFrontendNamespaceMutation
  ) -> String? {
    switch mutation {
    case .none:
      nil
    case .quarantineRootCreated:
      "DevSift created its private npm quarantine directory during this attempt."
    case .indeterminate:
      "DevSift could not determine whether the private quarantine directory was created."
    }
  }

  private static func notStartedMessage(
    _ reason: CleanupQuarantineFrontendNotStartedReason
  ) -> String {
    switch reason {
    case .cancelled:
      "The attempt was cancelled before execution authority was consumed."
    case .invalidAuthorization:
      "The one-time authorization did not match this execution attempt. Rescan and review again."
    case .authorizationAlreadyConsumed:
      "This one-time authorization was already used. Rescan and review again."
    case .authorizationCancelled:
      "This one-time authorization was cancelled before execution."
    case .executionBoundaryFailed:
      "The bounded execution boundary rejected the attempt. Rescan and review again."
    }
  }

  private static func notMovedMessage(
    _ reason: CleanupQuarantineFrontendNotMovedReason
  ) -> String {
    switch reason {
    case .cancelled:
      "The attempt was cancelled before a move was admitted."
    case .unsupportedPolicy, .invalidClaim:
      "The reviewed plan no longer matches the supported quarantine policy. Rescan and review again."
    case .invalidCurrentAccount:
      "DevSift could not establish a supported non-root account for this operation."
    case .candidateMissing:
      "The reviewed npm cache is no longer present."
    case .candidateChanged, .trustedRootChanged:
      "The reviewed filesystem object changed. Rescan before trying again."
    case .candidateUnsafe, .quarantineRootUnsafe:
      "A filesystem safety check rejected the current cache or quarantine directory."
    case .traversalLimitExceeded:
      "The cache exceeded DevSift's bounded validation limits."
    case .ageRequirementNotSatisfied:
      "The cache no longer satisfies the minimum age requirement."
    case .exclusiveRenameUnsupported:
      "This macOS version or filesystem does not provide the required protected rename operation."
    case .invalidDestinationName, .destinationCollisionLimitExceeded:
      "DevSift could not create a safe, unique quarantine destination."
    case .quarantineJournalBusy:
      "Another DevSift quarantine or restore operation currently holds the journal lock."
    case .trustedRootUnavailable(let failure), .quarantineRootUnavailable(let failure),
      .quarantineJournalUnavailable(let failure),
      .preRenameValidationUnavailable(let failure), .renameRejected(let failure):
      systemFailureMessage(failure)
    }
  }

  private static func rollbackMessage(
    _ reason: CleanupQuarantineFrontendRollbackReason
  ) -> String {
    switch reason {
    case .movedObjectDidNotMatchApproval:
      "Post-move validation did not match the reviewed object, so DevSift safely moved it back."
    case .postMoveValidationUnavailable:
      "Post-move validation was unavailable, so DevSift safely moved the item back."
    }
  }

  private static func manualRecoveryMessage(
    _ reason: CleanupQuarantineFrontendManualRecoveryReason
  ) -> String {
    switch reason {
    case .quarantineJournalUnsafe:
      "The journal failed its safety checks. Do not edit its files; inspect recovery details first."
    case .durabilityRecordingFailed:
      "DevSift could not finish the required durable record. Inspect recovery details before another operation."
    case .renameOutcomeIndeterminate:
      "The rename result is indeterminate. Recovery must inspect the current namespaces."
    case .destinationCouldNotBeVerified:
      "The quarantine destination could not be verified after the move attempt."
    case .parentBindingChanged:
      "A parent directory changed during the operation."
    case .sourceNameOccupied:
      "Another object occupies the original npm cache name. DevSift will not overwrite it."
    case .sourceCouldNotBeVerified:
      "The original npm cache name could not be verified after the move attempt."
    case .restoredObjectDidNotMatchApproval:
      "The object moved back to the source name did not match the reviewed object."
    case .rollbackFailed:
      "A safe rollback could not be completed."
    case .rollbackOutcomeIndeterminate:
      "DevSift could not determine the final rollback state."
    }
  }

  private static func systemFailureMessage(
    _ failure: CleanupQuarantineFrontendSystemFailure
  ) -> String {
    switch failure {
    case .permissionDenied:
      "macOS denied access before a safe move could be completed."
    case .pathChanged:
      "A filesystem path changed during final validation. Rescan before trying again."
    case .unsupported:
      "This macOS version or filesystem does not support the required durable operation."
    case .crossDevice:
      "The source and quarantine directory are not on the same filesystem."
    case .readOnlyFileSystem:
      "The filesystem is read-only."
    case .noSpace:
      "The filesystem has insufficient space for the transaction journal."
    case .resourceLimit:
      "A bounded operating-system or journal resource limit was reached."
    case .invalidMetadata:
      "Required filesystem metadata was invalid or unavailable."
    case .inputOutput:
      "The filesystem reported an input/output failure."
    case .destinationExists:
      "A safe quarantine destination could not be reserved without overwriting."
    case .unspecified:
      "The filesystem rejected the operation without a safe, specific diagnosis."
    }
  }
}

struct CleanupQuarantineFailurePresentation: Equatable, Sendable {
  let title: String
  let message: String

  init(failure: CleanupQuarantineWorkflowStageFailure) {
    title = "Quarantine did not start"
    switch failure {
    case .cancelled(let stage):
      message =
        "The attempt was cancelled during \(Self.name(for: stage)). No execution result was issued; rescan before trying again."
    case .rejected(let stage):
      message =
        "The retained review was rejected during \(Self.name(for: stage)). Rescan and review the current cache again."
    case .failed(let stage):
      message =
        "DevSift could not complete \(Self.name(for: stage)). The underlying error was not retained or displayed."
    }
  }

  private static func name(for stage: CleanupQuarantineWorkflowStage) -> String {
    switch stage {
    case .reviewConfirmation:
      "review confirmation"
    case .approval:
      "approval"
    case .authorizationAttempt:
      "authorization preparation"
    case .authorizationIssuance:
      "one-time authorization"
    }
  }
}
