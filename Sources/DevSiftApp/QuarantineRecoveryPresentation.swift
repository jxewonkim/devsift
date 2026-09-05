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

struct QuarantineRecoveryInventoryPresentation: Equatable, Sendable {
  let rows: [QuarantineRecoveryInventoryRowPresentation]

  var isEmpty: Bool {
    rows.isEmpty
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
          receiptWasProducedByRecovery: item.quarantineReceiptWasProducedByRecovery
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
