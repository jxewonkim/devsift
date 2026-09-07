import DevSiftCore
import Foundation

enum QuarantineRecoveryPresentationTone: Equatable, Sendable {
  case neutral
  case success
  case warning
  case failure
}

struct QuarantineRecoveryRowID: CustomReflectable, Hashable, Sendable {
  let inventoryGeneration: UInt64
  let ordinal: Int

  var customMirror: Mirror {
    Mirror(self, children: ["opaqueRow": true])
  }
}

struct QuarantineRecoveryPurgeRetryRowID: CustomReflectable, Hashable, Sendable {
  let inventoryGeneration: UInt64
  let ordinal: Int

  var customMirror: Mirror {
    Mirror(self, children: ["opaqueRetryRow": true])
  }
}

final class QuarantineRecoveryConfirmationIdentity: Sendable {}

struct QuarantineRecoveryConfirmationID: CustomReflectable, Hashable, Sendable {
  private let identity: QuarantineRecoveryConfirmationIdentity

  init(identity: QuarantineRecoveryConfirmationIdentity) {
    self.identity = identity
  }

  static func == (
    left: QuarantineRecoveryConfirmationID,
    right: QuarantineRecoveryConfirmationID
  ) -> Bool {
    left.identity === right.identity
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(identity))
  }

  var customMirror: Mirror {
    Mirror(self, children: ["opaqueConfirmation": true])
  }
}

final class QuarantineRecoveryPurgeConfirmationIdentity: Sendable {}

struct QuarantineRecoveryPurgeConfirmationID: CustomReflectable, Hashable, Sendable {
  private let identity: QuarantineRecoveryPurgeConfirmationIdentity

  init(identity: QuarantineRecoveryPurgeConfirmationIdentity) {
    self.identity = identity
  }

  static func == (
    left: QuarantineRecoveryPurgeConfirmationID,
    right: QuarantineRecoveryPurgeConfirmationID
  ) -> Bool {
    left.identity === right.identity
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(identity))
  }

  var customMirror: Mirror {
    Mirror(self, children: ["opaquePurgeConfirmation": true])
  }
}

enum QuarantineRecoveryPurgeTarget: Equatable, Sendable {
  case initial(QuarantineRecoveryRowID)
  case explicitRetry(QuarantineRecoveryPurgeRetryRowID)
}

struct QuarantineRecoveryInventoryPresentation: Equatable, Sendable {
  let rows: [QuarantineRecoveryInventoryRowPresentation]
  let purgeRetryRows: [QuarantineRecoveryPurgeRetryRowPresentation]

  var isEmpty: Bool {
    rows.isEmpty && purgeRetryRows.isEmpty
  }

  static func prepare(
    inventory: QuarantineRecoveryWorkflowInventory,
    generation: UInt64
  ) -> QuarantineRecoveryInventoryPresentation {
    QuarantineRecoveryInventoryPresentation(
      rows: inventory.items.enumerated().map { ordinal, item in
        QuarantineRecoveryInventoryRowPresentation(
          id: QuarantineRecoveryRowID(
            inventoryGeneration: generation,
            ordinal: ordinal
          ),
          responsibleTool: SafeDisplayText.scalarSafe(item.responsibleTool),
          originalName: SafeDisplayText.scalarSafe(item.originalName),
          source: QuarantineRecoverySourcePresentation(item.readiness.originalSource),
          quarantinedItem: QuarantineRecoveryItemStatePresentation(
            item.readiness.quarantinedItem
          ),
          canRestore: item.readiness.canRestore,
          canPurge: item.purgeReadiness.canPurge,
          receiptWasProducedByRecovery: item.quarantineReceiptWasProducedByRecovery
        )
      },
      purgeRetryRows: inventory.purgeRetries.enumerated().map { ordinal, item in
        QuarantineRecoveryPurgeRetryRowPresentation(
          id: QuarantineRecoveryPurgeRetryRowID(
            inventoryGeneration: generation,
            ordinal: ordinal
          ),
          responsibleTool: SafeDisplayText.scalarSafe(item.responsibleTool),
          originalName: SafeDisplayText.scalarSafe(item.originalName)
        )
      }
    )
  }
}

struct QuarantineRecoveryInventoryRowPresentation: Equatable, Identifiable, Sendable {
  let id: QuarantineRecoveryRowID
  let responsibleTool: String
  let originalName: String
  let source: QuarantineRecoverySourcePresentation
  let quarantinedItem: QuarantineRecoveryItemStatePresentation
  let canRestore: Bool
  let canPurge: Bool
  let receiptWasProducedByRecovery: Bool

  var restoreAvailabilityMessage: String {
    if canRestore {
      return "Ready to restore without overwriting an existing item."
    }
    if source.tone != .success {
      return source.message
    }
    return quarantinedItem.message
  }

  var purgeAvailabilityMessage: String {
    if canPurge {
      return "Ready to prepare permanent deletion of the exact quarantined contents."
    }
    return quarantinedItem.message
  }
}

struct QuarantineRecoveryPurgeRetryRowPresentation: Equatable, Identifiable, Sendable {
  let id: QuarantineRecoveryPurgeRetryRowID
  let responsibleTool: String
  let originalName: String

  let canRetry = true

  var retryAvailabilityMessage: String {
    "A staged deletion remainder is available for a separately confirmed retry. Restore is no longer available for this item."
  }
}

struct QuarantineRecoverySourcePresentation: Equatable, Sendable {
  let title: String
  let message: String
  let tone: QuarantineRecoveryPresentationTone

  init(_ state: QuarantineInventoryOriginalSourceState) {
    switch state {
    case .missing:
      title = "Original location is clear"
      message = "The original _cacache name is currently unoccupied."
      tone = .success
    case .expectedObjectPresent:
      title = "Cache already present"
      message = "The original location contains the previously expected object. Restore is blocked."
      tone = .warning
    case .otherObjectPresent:
      title = "Original location occupied"
      message = "Another object now uses the original name. DevSift will not overwrite it."
      tone = .failure
    }
  }
}

struct QuarantineRecoveryItemStatePresentation: Equatable, Sendable {
  let title: String
  let message: String
  let tone: QuarantineRecoveryPresentationTone

  init(_ state: QuarantineInventoryItemState) {
    switch state {
    case .available:
      title = "Quarantined contents available"
      message = "The current quarantined contents passed the bounded inventory checks."
      tone = .success
    case .missing:
      title = "Quarantined contents missing"
      message = "The recorded quarantined item is no longer available."
      tone = .failure
    case .changed:
      title = "Quarantined contents changed"
      message = "The quarantined contents no longer match the recorded restore evidence."
      tone = .warning
    case .unsafe:
      title = "Quarantined contents unsafe"
      message = "The item or one of its trusted parent bindings did not pass validation."
      tone = .failure
    case .traversalLimitExceeded:
      title = "Validation limit reached"
      message = "The bounded safety traversal ended before the item could be approved."
      tone = .warning
    }
  }
}

struct QuarantineRecoveryConfirmationPresentation: Equatable, Sendable {
  let id: QuarantineRecoveryConfirmationID
  let rowID: QuarantineRecoveryRowID
  let responsibleTool: String
  let originalName: String
  let requiredStatement: QuarantineRestoreConfirmationStatement

  var requiredStatementIdentifier: String {
    requiredStatement.rawValue
  }

  init(
    rowID: QuarantineRecoveryRowID,
    confirmationID: QuarantineRecoveryConfirmationID,
    preparedRestore: QuarantineRecoveryPreparedRestore
  ) {
    id = confirmationID
    self.rowID = rowID
    responsibleTool = SafeDisplayText.scalarSafe(preparedRestore.responsibleTool)
    originalName = SafeDisplayText.scalarSafe(preparedRestore.originalName)
    requiredStatement = preparedRestore.requiredStatement
  }
}

struct QuarantineRecoveryPurgeConfirmationPresentation: Equatable, Sendable {
  let id: QuarantineRecoveryPurgeConfirmationID
  let target: QuarantineRecoveryPurgeTarget
  let attemptKind: QuarantinePurgeAttemptKind
  let responsibleTool: String
  let originalName: String
  let requiredStatement: QuarantinePurgeConfirmationStatement

  var requiredStatementIdentifier: String {
    requiredStatement.rawValue
  }

  var isExplicitRetry: Bool {
    attemptKind == .explicitRetry
  }

  var dataRemanenceDisclosure: String {
    "This is not secure erase: APFS snapshots or clones, backups, open file descriptors, and storage-device behavior may retain data or blocks."
  }

  init(
    target: QuarantineRecoveryPurgeTarget,
    confirmationID: QuarantineRecoveryPurgeConfirmationID,
    preparedPurge: QuarantineRecoveryPreparedPurge
  ) {
    id = confirmationID
    self.target = target
    attemptKind = preparedPurge.attemptKind
    responsibleTool = SafeDisplayText.scalarSafe(preparedPurge.responsibleTool)
    originalName = SafeDisplayText.scalarSafe(preparedPurge.originalName)
    requiredStatement = preparedPurge.requiredStatement
  }
}

struct QuarantineRecoveryIssuePresentation: Equatable, Sendable {
  let title: String
  let message: String
  let tone: QuarantineRecoveryPresentationTone

  init(loadFailure: QuarantineInventoryLoadFailure) {
    tone = loadFailure == .cancelled ? .neutral : .failure
    switch loadFailure {
    case .cancelled:
      title = "Inventory load cancelled"
      message =
        "The load stopped before a current inventory was published. Open recovery again to reconcile the latest durable journal state."
    case .busy:
      title = "Recovery journal is busy"
      message = "Another recovery operation holds the journal lock. Try again after it finishes."
    case .unsupportedPlatform:
      title = "Recovery is unavailable"
      message = "This recoverable operation requires macOS 26 or newer."
    case .trustedLocationUnavailable:
      title = "Recovery location unavailable"
      message = "DevSift could not open its trusted npm recovery location."
    case .trustedLocationUnsafe:
      title = "Recovery location rejected"
      message = "The trusted npm recovery location did not pass safety validation."
    case .manualRecoveryRequired:
      title = "Manual recovery required"
      message =
        "The journal contains an unresolved operation that DevSift cannot safely resolve automatically."
    }
  }

  init(preparationFailure: QuarantineRestorePreparationFailure) {
    tone = preparationFailure == .cancelled ? .neutral : .failure
    title = "Restore could not be prepared"
    switch preparationFailure {
    case .invalidInventoryReference, .inventoryChanged:
      message = "The inventory changed. Refresh it before attempting another restore."
    case .sourceOccupied:
      message = "The original _cacache name is occupied. DevSift will not overwrite it."
    case .quarantinedItemMissing:
      message = "The recorded quarantined contents are no longer available."
    case .quarantinedItemChanged:
      message = "The quarantined contents changed after this inventory was loaded."
    case .quarantinedItemUnsafe:
      message = "The quarantined item or a trusted parent binding failed validation."
    case .traversalLimitExceeded:
      message = "The bounded validation limit was reached before restore could be approved."
    case .busy:
      message = "Another recovery operation holds the journal lock."
    case .unsupportedPlatform:
      message = "This recoverable operation requires macOS 26 or newer."
    case .trustedLocationUnavailable:
      message = "DevSift could not open its trusted npm recovery location."
    case .trustedLocationUnsafe:
      message = "The trusted npm recovery location did not pass safety validation."
    case .manualRecoveryRequired:
      message = "The journal requires manual recovery before another restore can begin."
    case .cancelled:
      message = "The restore preparation was cancelled without changing files."
    }
  }

  init(workflowFailure: QuarantineRecoveryWorkflowExecutionFailure) {
    switch workflowFailure {
    case .authorization(let failure):
      tone = failure == .cancelled || failure == .attemptCancelled ? .neutral : .failure
      title = "Restore authorization rejected"
      switch failure {
      case .confirmationDoesNotBelongToAttempt:
        message = "The confirmation did not belong to the current restore attempt."
      case .confirmationStatementMismatch:
        message = "The confirmation did not match the exact statement requested by Core."
      case .attemptAlreadyAuthorized:
        message = "This one-time restore attempt was already authorized."
      case .attemptCancelled, .cancelled:
        message = "The restore attempt was cancelled."
      case .invalidPreparedEvidence:
        message = "The prepared restore evidence was no longer valid. Refresh the inventory."
      }

    case .execution(let failure):
      tone = failure == .cancelled || failure == .authorizationCancelled ? .neutral : .failure
      title = "Restore did not execute"
      switch failure {
      case .invalidAuthorization:
        message = "Core rejected the one-time restore authorization."
      case .authorizationAlreadyConsumed:
        message = "The one-time restore authorization was already used."
      case .authorizationCancelled, .cancelled:
        message = "The restore execution was cancelled."
      }
    }
  }

  init(purgePreparationFailure: QuarantinePurgePreparationFailure) {
    title = "Permanent deletion could not be prepared"
    switch purgePreparationFailure {
    case .cancelled:
      tone = .neutral
      message = "The deletion preparation was cancelled without granting purge authority."
    case .invalidInventoryReference, .inventoryChanged, .journalRecordMissing,
      .journalRecordChanged:
      tone = .failure
      message = "The reconciled inventory changed. Refresh it before choosing another action."
    case .unsupportedPlatform:
      tone = .failure
      message = "Protected permanent deletion is unavailable on this platform."
    case .invalidCurrentAccount, .trustedLocationChanged:
      tone = .failure
      message = "The current account or a trusted recovery binding changed."
    case .trustedLocationUnavailable:
      tone = .failure
      message = "DevSift could not open its trusted npm recovery location."
    case .journalRecordUnsafe:
      tone = .failure
      message = "The durable recovery records did not pass safety validation."
    case .quarantinedItemMissing:
      tone = .failure
      message = "The exact quarantined contents are no longer available."
    case .quarantinedItemChanged:
      tone = .failure
      message = "The quarantined contents changed after this inventory was loaded."
    case .quarantinedItemUnsafe:
      tone = .failure
      message = "The quarantined item or a trusted parent binding failed validation."
    case .purgeWorkMissing:
      tone = .failure
      message = "The exact staged deletion remainder is no longer available."
    case .purgeWorkChanged:
      tone = .failure
      message = "The staged deletion remainder changed after this inventory was loaded."
    case .purgeWorkUnsafe, .purgeWorkNameOccupied:
      tone = .failure
      message = "The staged deletion remainder or its managed name failed validation."
    case .traversalLimitExceeded:
      tone = .failure
      message = "The bounded safety traversal ended before deletion could be approved."
    case .capacityObservation:
      tone = .failure
      message =
        "Core could not obtain the required same-volume capacity sample, so no new purge intent was authorized."
    case .purgeIdentifierUnavailable:
      tone = .failure
      message = "Core could not allocate bounded internal state for this deletion attempt."
    case .authorization(let failure):
      tone = failure == .cancelled || failure == .attemptCancelled ? .neutral : .failure
      message = Self.purgeAuthorizationMessage(failure)
    }
  }

  init(purgeWorkflowFailure: QuarantineRecoveryWorkflowPurgeExecutionFailure) {
    switch purgeWorkflowFailure {
    case .authorization(let failure):
      tone = failure == .cancelled || failure == .attemptCancelled ? .neutral : .failure
      title = "Permanent deletion authorization rejected"
      message = Self.purgeAuthorizationMessage(failure)
    case .execution(let failure):
      tone = failure == .cancelled || failure == .authorizationCancelled ? .neutral : .failure
      title = "Permanent deletion did not execute"
      switch failure {
      case .invalidAuthorization:
        message = "Core rejected the one-time permanent deletion authorization."
      case .authorizationAlreadyConsumed:
        message = "The one-time permanent deletion authorization was already used."
      case .authorizationCancelled, .cancelled:
        message =
          "The execution was cancelled. The refreshed inventory is the authority for any next action."
      }
    }
  }

  private static func purgeAuthorizationMessage(
    _ failure: QuarantinePurgeAuthorizationFailure
  ) -> String {
    switch failure {
    case .confirmationDoesNotBelongToAttempt:
      "The confirmation did not belong to the current permanent deletion attempt."
    case .confirmationStatementMismatch:
      "The confirmation did not match the exact statement requested by Core."
    case .attemptAlreadyAuthorized:
      "This one-time permanent deletion attempt was already authorized."
    case .attemptCancelled, .cancelled:
      "The permanent deletion attempt was cancelled."
    case .invalidPreparedEvidence:
      "The prepared permanent deletion evidence was no longer valid. Refresh the inventory."
    }
  }
}

struct QuarantineRecoveryResultPresentation: Equatable, Sendable {
  let title: String
  let message: String
  let durabilityMessage: String
  let cancellationMessage: String?
  let tone: QuarantineRecoveryPresentationTone
  let isDurablyRestored: Bool
  let performedPermanentDeletion: Bool
  let overwroteExistingItem: Bool

  init(result: QuarantineRecoveryWorkflowExecutionResult) {
    isDurablyRestored = result.isDurablyRestored
    performedPermanentDeletion = result.performedPermanentDeletion
    overwroteExistingItem = result.overwroteExistingItem
    cancellationMessage =
      result.cancellationWasObservedAfterRename
      ? "Cancellation arrived after a rename; Core completed bounded reconciliation before reporting this result."
      : nil

    switch result.status {
    case .restored(let quarantineNameWasRecreated):
      if result.isDurablyRestored && !result.performedPermanentDeletion
        && !result.overwroteExistingItem
      {
        title = "Cache restored"
        message =
          quarantineNameWasRecreated
          ? "The current quarantined contents were restored without overwrite, but another object now occupies the former quarantine item name. Review the refreshed inventory before taking another action."
          : "The current quarantined contents were restored without overwrite."
        tone = .success
      } else {
        title = "Restore needs verification"
        message =
          "Core reported a restore without complete terminal safety evidence. Review the refreshed inventory before taking another action."
        tone = .warning
      }

    case .notRestored(let reason):
      title = "Cache was not restored"
      message = Self.notRestoredMessage(reason)
      tone = reason == .cancelled ? .neutral : .failure

    case .manualRecoveryRequired(let reason):
      title = "Manual recovery required"
      message = Self.manualRecoveryMessage(reason)
      tone = .warning
    }

    durabilityMessage = Self.durabilityMessage(result.durability)
  }

  private static func notRestoredMessage(_ reason: QuarantineRestoreNotRestoredReason) -> String {
    switch reason {
    case .cancelled:
      "The operation was cancelled and Core did not report a completed restore."
    case .invalidAuthorization:
      "The one-time authorization did not match the current restore attempt."
    case .invalidCurrentAccount:
      "The current account no longer matches the account bound to this recovery operation."
    case .trustedLocationUnavailable:
      "The trusted npm recovery location was unavailable."
    case .trustedLocationChanged:
      "A trusted parent binding changed after restore preparation."
    case .unsupported:
      "The filesystem cannot perform the required protected restore rename."
    case .inventoryChanged:
      "The journal inventory changed before the restore executed."
    case .alreadyRestored:
      "This item was already restored."
    case .sourceOccupied:
      "The original _cacache name is occupied. DevSift did not overwrite it."
    case .quarantinedItemMissing:
      "The recorded quarantined contents are missing."
    case .quarantinedItemChanged:
      "The quarantined contents changed after authorization."
    case .quarantinedItemUnsafe:
      "The quarantined item failed the final safety validation."
    case .traversalLimitExceeded:
      "The bounded final validation reached its traversal limit."
    case .journalBusy:
      "Another recovery operation holds the journal lock."
    case .journalUnavailable:
      "The recovery journal was unavailable."
    case .renameRejected:
      "The filesystem rejected the protected restore rename."
    }
  }

  private static func manualRecoveryMessage(
    _ reason: QuarantineRestoreManualRecoveryReason
  ) -> String {
    switch reason {
    case .quarantineJournalUnsafe:
      "The quarantine journal no longer has a trusted structure."
    case .durabilityRecordingFailed:
      "The filesystem change may have completed, but a durable terminal receipt could not be recorded."
    case .renameOutcomeIndeterminate:
      "Core could not determine the final outcome of the protected rename."
    case .parentBindingChanged:
      "A trusted parent binding changed during the restore."
    case .sourceCouldNotBeVerified:
      "The original cache location could not be verified after the restore attempt."
    case .quarantineItemCouldNotBeVerified:
      "The quarantined item could not be verified after the restore attempt."
    }
  }

  private static func durabilityMessage(_ durability: QuarantineRestoreDurability) -> String {
    switch durability {
    case .notRecorded:
      "No restore intent or terminal receipt was recorded."
    case .intentRecorded:
      "A restore intent was recorded, but no terminal receipt is available yet."
    case .receiptRecorded(let producedByRecovery):
      producedByRecovery
        ? "A terminal restore receipt was completed by journal recovery."
        : "A terminal restore receipt was durably recorded."
    case .unresolved:
      "The journal durability state is unresolved."
    }
  }
}

struct QuarantineRecoveryPurgeResultPresentation: Equatable, Sendable {
  let attemptKind: QuarantinePurgeAttemptKind
  let title: String
  let message: String
  let durabilityMessage: String
  let capacityMessage: String
  let observedUnlinkMessage: String
  let limitationsMessage: String
  let cancellationMessage: String?
  let tone: QuarantineRecoveryPresentationTone
  let isDurablyTerminal: Bool
  let performedPermanentDeletion: Bool
  let requiresExplicitRetry: Bool

  init(result: QuarantineRecoveryWorkflowPurgeExecutionResult) {
    attemptKind = result.attemptKind
    isDurablyTerminal = result.isDurablyTerminal
    performedPermanentDeletion = result.performedPermanentDeletion
    requiresExplicitRetry = result.requiresExplicitRetry
    durabilityMessage = Self.durabilityMessage(result.durability)
    capacityMessage = Self.capacityMessage(result.observedCapacityChange)
    observedUnlinkMessage = Self.observedUnlinkMessage(result.observedUnlinkCount)
    limitationsMessage =
      "Observed absence and capacity change do not prove secure erasure, attribution, or reclaimed storage."
    cancellationMessage =
      result.cancellationWasObserved
      ? "Cancellation was observed during this pass. Core's bounded result and the refreshed inventory determine the safe next action."
      : nil

    switch result.status {
    case .noMutation(let reason):
      title = "No permanent deletion was performed"
      message = Self.noMutationMessage(reason)
      tone = reason == .cancelled ? .neutral : .failure
    case .notPurged:
      title = "Quarantined contents were not purged"
      message =
        "A terminal receipt records that this attempt did not stage or delete the item. Use the refreshed inventory before choosing another action."
      tone = .neutral
    case .observationalRecoveryRequired(let reason):
      title = "Journal reconciliation required"
      message = Self.recoveryMessage(reason)
      tone = .warning
    case .explicitRetryRequired(let progress, let reason):
      title = "Permanent deletion is incomplete"
      message =
        "\(Self.progressMessage(progress)) \(Self.retryMessage(reason)) Restore is unavailable for the staged remainder; continuing requires a separate explicit confirmation from the refreshed inventory."
      tone = .warning
    case .itemAbsent:
      title =
        result.isDurablyTerminal
        ? "Quarantined item is durably recorded absent" : "Quarantined item is absent"
      message =
        "Core observed the receipt-bound quarantine and staged-work names absent and recorded the bounded outcome."
      tone = result.isDurablyTerminal ? .success : .warning
    case .manualRecoveryRequired(let reason):
      title = "Manual recovery required"
      message = Self.manualRecoveryMessage(reason)
      tone = .warning
    }
  }

  private static func noMutationMessage(_ reason: QuarantinePurgeNoMutationReason) -> String {
    switch reason {
    case .cancelled:
      "The pass was cancelled before a new irreversible namespace operation was reported."
    case .invalidAuthorization:
      "The one-time authorization did not match the current permanent deletion attempt."
    case .unsupportedPlatform, .exclusiveRenameUnsupported:
      "The platform cannot perform the required protected permanent deletion operation."
    case .invalidCurrentAccount:
      "The current account no longer matches the account bound to this recovery operation."
    case .trustedLocationUnavailable:
      "The trusted npm recovery location was unavailable."
    case .trustedLocationChanged:
      "A trusted recovery binding changed after confirmation."
    case .journalRecordMissing, .journalRecordChanged:
      "The durable journal evidence changed before execution."
    case .journalRecordUnsafe:
      "The durable journal evidence did not pass safety validation."
    case .quarantinedItemMissing:
      "The exact quarantined item was no longer available."
    case .quarantinedItemChanged:
      "The quarantined contents changed after confirmation."
    case .quarantinedItemUnsafe:
      "The quarantined item failed final safety validation."
    case .purgeWorkMissing:
      "The exact staged deletion remainder was no longer available."
    case .purgeWorkChanged:
      "The staged deletion remainder changed after confirmation."
    case .purgeWorkUnsafe, .purgeWorkNameOccupied:
      "The staged deletion remainder or its managed name failed validation."
    case .traversalLimitExceeded:
      "The bounded final traversal reached its safety limit."
    case .capacityObservationUnavailable:
      "Core could not obtain the mandatory pre-intent capacity observation."
    case .purgeIdentifierUnavailable:
      "Core could not allocate bounded internal state for this attempt."
    case .originalTransactionUnavailable, .originalTransactionNotPurgeable:
      "The original quarantine transaction is no longer eligible for permanent deletion."
    case .alreadyPurged:
      "A terminal permanent deletion receipt already exists for this item."
    case .quarantineJournalBusy:
      "Another recovery operation holds the journal lock."
    case .quarantineJournalUnavailable:
      "The recovery journal was unavailable."
    case .renameRejected:
      "The filesystem rejected the protected staging rename."
    }
  }

  private static func progressMessage(_ progress: QuarantinePurgeProgress) -> String {
    switch progress {
    case .stagedWithNoUnlinkObserved:
      "Core staged the exact item but did not observe an unlink linearization in this pass."
    case .unlinkProgressObserved:
      "Core observed bounded unlink progress, but an exact staged remainder still exists."
    }
  }

  private static func retryMessage(_ reason: QuarantinePurgeRetryReason) -> String {
    switch reason {
    case .cancelled:
      "The pass stopped after cancellation was observed."
    case .namespaceChanged:
      "The managed quarantine namespace changed during the pass."
    case .treeChanged:
      "The staged tree changed during the pass."
    case .treeUnsafe:
      "The staged tree did not pass a safety recheck."
    case .traversalLimitExceeded:
      "The bounded traversal limit was reached."
    case .synchronizationLimitExceeded:
      "The bounded synchronization pass limit was reached."
    case .observationUnavailable:
      "A required descriptor-relative observation was unavailable."
    case .unlinkRejected:
      "The filesystem rejected a bounded unlink operation."
    case .synchronizationFailed:
      "The filesystem could not durably synchronize the observed progress."
    }
  }

  private static func recoveryMessage(_ reason: QuarantinePurgeRecoveryReason) -> String {
    switch reason {
    case .stagingNotCommitted:
      "A durable intent exists, but Core did not observe the staging rename committed. Refresh to reconcile the exact namespace state."
    case .stagingMayHaveBeenInvoked:
      "A staging rename may have been invoked. Refresh to reconcile the exact namespace state before another action."
    case .journalRequiresReconciliation:
      "The durable purge journal must be reconciled before another action can be offered."
    }
  }

  private static func manualRecoveryMessage(
    _ reason: QuarantinePurgeManualRecoveryReason
  ) -> String {
    switch reason {
    case .invalidExecutionResult, .invalidTerminalReceipt,
      .invalidTerminalizationSession:
      "Core rejected inconsistent terminal deletion evidence."
    case .journalUnsafe:
      "The recovery journal no longer has a trusted structure."
    case .recordsChanged:
      "The durable records changed during terminal verification."
    case .parentBindingChanged:
      "A trusted parent binding changed during permanent deletion."
    case .namespaceAmbiguous:
      "Core could not determine a unique safe quarantine namespace outcome."
    case .workTreeChanged:
      "The staged deletion remainder changed during terminal verification."
    case .workTreeUnsafe:
      "The staged deletion remainder failed terminal safety validation."
    case .traversalLimitExceeded:
      "The bounded terminal verification reached its traversal limit."
    case .durabilityUnresolved:
      "Filesystem changes may have occurred, but Core could not establish durable terminal evidence."
    }
  }

  private static func durabilityMessage(_ durability: QuarantinePurgeDurability) -> String {
    switch durability {
    case .notRecorded:
      return "No permanent deletion intent or terminal receipt was recorded."
    case .intentRecorded:
      return "A permanent deletion intent is durable, but no terminal receipt is available yet."
    case .terminalReceiptRecorded(let outcome, let producedByRecovery):
      let outcomeDescription =
        outcome == .itemAbsent ? "item-absent" : "not-purged"
      return producedByRecovery
        ? "Journal recovery completed a terminal \(outcomeDescription) receipt."
        : "A terminal \(outcomeDescription) receipt was durably recorded."
    case .unresolved:
      return "The permanent deletion journal durability state is unresolved."
    }
  }

  private static func capacityMessage(_ change: QuarantinePurgeCapacityChange) -> String {
    switch change {
    case .increase(let amount):
      "Observed same-volume available capacity increased by \(formattedByteCount(amount)); this change is not attributed to DevSift."
    case .unchanged:
      "Observed same-volume available capacity was unchanged. A zero-byte increase is a valid outcome."
    case .decrease(let amount):
      "Observed same-volume available capacity decreased by \(formattedByteCount(amount)); concurrent system activity may affect this value."
    case .unavailable:
      "A trusted post-attempt capacity comparison was unavailable."
    }
  }

  private static func observedUnlinkMessage(_ count: UInt64) -> String {
    guard count > 0 else {
      return "Core did not report an observed unlink linearization during this pass."
    }
    return
      "Core invoked unlink and then observed \(count.formatted()) filesystem \(count == 1 ? "name" : "names") absent during this pass."
  }

  private static func formattedByteCount(_ count: UInt64) -> String {
    guard let signedCount = Int64(exactly: count) else {
      return "more than the UI can format"
    }
    return ByteCountFormatter.string(fromByteCount: signedCount, countStyle: .file)
  }
}
