import Foundation

package enum QuarantineInventoryOriginalSourceState: Equatable, Sendable {
  case missing
  case expectedObjectPresent
  case otherObjectPresent
}

package enum QuarantineInventoryItemState: Equatable, Sendable {
  case available
  case missing
  case changed
  case unsafe
  case traversalLimitExceeded
}

package struct QuarantineInventoryRestoreReadiness: Equatable, Sendable {
  package let originalSource: QuarantineInventoryOriginalSourceState
  package let quarantinedItem: QuarantineInventoryItemState

  package init(
    originalSource: QuarantineInventoryOriginalSourceState,
    quarantinedItem: QuarantineInventoryItemState
  ) {
    self.originalSource = originalSource
    self.quarantinedItem = quarantinedItem
  }

  package var canRestore: Bool {
    originalSource == .missing && quarantinedItem == .available
  }
}

/// Bounded initial-purge readiness for one already validated inventory row.
///
/// The current `_cacache` source state is intentionally absent. Purge targets
/// only the exact receipt-bound quarantined item represented by this row.
package struct QuarantineInventoryPurgeReadiness: Equatable, Sendable {
  package let quarantinedItem: QuarantineInventoryItemState

  package init(quarantinedItem: QuarantineInventoryItemState) {
    self.quarantinedItem = quarantinedItem
  }

  package var canPurge: Bool {
    quarantinedItem == .available
  }
}

private final class QuarantineInventorySessionIdentity: Sendable {}

/// An inventory-session-bound selector. Its journal transaction identifier is
/// deliberately inaccessible outside DevSiftCore.
package struct QuarantineInventoryItemReference: CustomReflectable, Hashable, Sendable {
  fileprivate let ordinal: Int
  fileprivate let sessionIdentity: QuarantineInventorySessionIdentity

  package static func == (
    left: QuarantineInventoryItemReference,
    right: QuarantineInventoryItemReference
  ) -> Bool {
    left.sessionIdentity === right.sessionIdentity
      && left.ordinal == right.ordinal
  }

  package func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(sessionIdentity))
    hasher.combine(ordinal)
  }

  package var customMirror: Mirror {
    Mirror(self, children: ["opaque": true])
  }
}

package struct QuarantineInventoryItem: Equatable, Sendable {
  package let reference: QuarantineInventoryItemReference
  package let responsibleTool: String
  package let originalName: String
  package let readiness: QuarantineInventoryRestoreReadiness
  package let purgeReadiness: QuarantineInventoryPurgeReadiness
  package let quarantineReceiptWasProducedByRecovery: Bool
}

/// One resolved initial-purge selection from an exact inventory session.
///
/// This value is not authorization and exposes no transaction identifier,
/// record bytes, path, managed item name, work name, or descriptor. Its
/// retained Core-internal entry is only input for a later descriptor-backed
/// purge preflight, which must reread and revalidate the exact evidence.
package struct QuarantineInventoryInitialPurgeSelection: CustomReflectable, Sendable {
  let entry: DescriptorQuarantineInventoryEntry
  fileprivate let sessionIdentity: QuarantineInventorySessionIdentity
  fileprivate let ordinal: Int

  package var isAuthorization: Bool { false }
  package var authorizesPermanentDeletion: Bool { false }

  package var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "opaque": true,
        "isAuthorization": isAuthorization,
        "authorizesPermanentDeletion": authorizesPermanentDeletion,
      ]
    )
  }
}

/// Session-bound selector for the one exact staged purge remainder. It exposes
/// neither a transaction identifier, managed work name, path, nor binding.
package struct QuarantineInventoryPurgeRetryReference: CustomReflectable, Hashable, Sendable {
  fileprivate let ordinal: Int
  fileprivate let sessionIdentity: QuarantineInventorySessionIdentity

  package static func == (
    left: QuarantineInventoryPurgeRetryReference,
    right: QuarantineInventoryPurgeRetryReference
  ) -> Bool {
    left.sessionIdentity === right.sessionIdentity && left.ordinal == right.ordinal
  }

  package func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(sessionIdentity))
    hasher.combine(ordinal)
  }

  package var customMirror: Mirror {
    Mirror(self, children: ["opaque": true])
  }
}

package struct QuarantineInventoryPurgeRetryItem: Equatable, Sendable {
  package let reference: QuarantineInventoryPurgeRetryReference
  package let responsibleTool: String
  package let originalName: String
}

/// A resolved, non-authorizing retry selection retained only inside Core.
package struct QuarantineInventoryPurgeRetrySelection: CustomReflectable, Sendable {
  let entry: DescriptorQuarantinePurgeRetryInventoryEntry
  fileprivate let sessionIdentity: QuarantineInventorySessionIdentity
  fileprivate let ordinal: Int

  package var isAuthorization: Bool { false }
  package var authorizesPermanentDeletion: Bool { false }

  package var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "opaque": true,
        "isAuthorization": isAuthorization,
        "authorizesPermanentDeletion": authorizesPermanentDeletion,
      ]
    )
  }
}

/// A non-Codable, process-local inventory snapshot. References from one
/// snapshot cannot be substituted into another, even when their visible rows
/// are identical.
package struct QuarantineInventorySession: CustomReflectable, Sendable {
  package let items: [QuarantineInventoryItem]
  package let purgeRetries: [QuarantineInventoryPurgeRetryItem]

  fileprivate let sessionIdentity: QuarantineInventorySessionIdentity
  fileprivate let entries: [DescriptorQuarantineInventoryEntry]

  fileprivate init(entries: [DescriptorQuarantineInventoryEntry]) {
    let identity = QuarantineInventorySessionIdentity()
    sessionIdentity = identity
    self.entries = entries
    items = entries.enumerated().map { ordinal, entry in
      QuarantineInventoryItem(
        reference: QuarantineInventoryItemReference(
          ordinal: ordinal,
          sessionIdentity: identity
        ),
        responsibleTool: "npm",
        originalName: "_cacache",
        readiness: QuarantineInventoryRestoreReadiness(
          originalSource: QuarantineInventoryOriginalSourceState(entry.sourceState),
          quarantinedItem: QuarantineInventoryItemState(entry.itemState)
        ),
        purgeReadiness: QuarantineInventoryPurgeReadiness(
          quarantinedItem: QuarantineInventoryItemState(entry.itemState)
        ),
        quarantineReceiptWasProducedByRecovery:
          entry.quarantineReceiptWasProducedByRecovery
      )
    }
    purgeRetries = entries.enumerated().compactMap { ordinal, entry in
      guard entry.purgeRetry != nil else { return nil }
      return QuarantineInventoryPurgeRetryItem(
        reference: QuarantineInventoryPurgeRetryReference(
          ordinal: ordinal,
          sessionIdentity: identity
        ),
        responsibleTool: "npm",
        originalName: "_cacache"
      )
    }
  }

  fileprivate func entry(
    for reference: QuarantineInventoryItemReference
  ) -> DescriptorQuarantineInventoryEntry? {
    guard reference.sessionIdentity === sessionIdentity,
      items.indices.contains(reference.ordinal),
      items[reference.ordinal].reference == reference
    else {
      return nil
    }
    return entries[reference.ordinal]
  }

  fileprivate func purgeRetryEntry(
    for reference: QuarantineInventoryPurgeRetryReference
  ) -> DescriptorQuarantinePurgeRetryInventoryEntry? {
    guard reference.sessionIdentity === sessionIdentity,
      entries.indices.contains(reference.ordinal),
      purgeRetries.contains(where: { $0.reference == reference })
    else {
      return nil
    }
    return entries[reference.ordinal].purgeRetry
  }

  package var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "itemCount": items.count,
        "purgeRetryCount": purgeRetries.count,
      ]
    )
  }
}

package enum QuarantineInventoryLoadFailure: Error, Equatable, Sendable {
  case cancelled
  case busy
  case unsupportedPlatform
  case trustedLocationUnavailable
  case trustedLocationUnsafe
  case manualRecoveryRequired
}

package enum QuarantineInventoryPurgeSelectionFailure: Error, Equatable, Sendable {
  case invalidInventoryReference
  case quarantinedItemMissing
  case quarantinedItemChanged
  case quarantinedItemUnsafe
  case traversalLimitExceeded
}

package enum QuarantineRestorePreparationFailure: Error, Equatable, Sendable {
  case invalidInventoryReference
  case inventoryChanged
  case sourceOccupied
  case quarantinedItemMissing
  case quarantinedItemChanged
  case quarantinedItemUnsafe
  case traversalLimitExceeded
  case busy
  case unsupportedPlatform
  case trustedLocationUnavailable
  case trustedLocationUnsafe
  case manualRecoveryRequired
  case cancelled
}

package enum QuarantineRestoreConfirmationStatement: String, Hashable, Sendable {
  case
    restoreCurrentQuarantinedContentsWithoutOverwriteWithNPMStoppedAndChangesAccepted =
    "restore-current-quarantined-contents-to-original-cacache-without-overwrite-with-npm-stopped-and-post-quarantine-changes-accepted"
}

package struct QuarantineRestoreConfirmationRequest: CustomReflectable, Hashable, Sendable {
  package let requiredStatement: QuarantineRestoreConfirmationStatement
  package let responsibleTool: String
  package let originalName: String

  fileprivate let underlying: CleanupQuarantineRestoreConfirmationRequest

  package static func == (
    left: QuarantineRestoreConfirmationRequest,
    right: QuarantineRestoreConfirmationRequest
  ) -> Bool {
    left.underlying == right.underlying
      && left.requiredStatement == right.requiredStatement
      && left.responsibleTool == right.responsibleTool
      && left.originalName == right.originalName
  }

  package func hash(into hasher: inout Hasher) {
    hasher.combine(underlying)
    hasher.combine(requiredStatement)
    hasher.combine(responsibleTool)
    hasher.combine(originalName)
  }

  package var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "requiredStatement": requiredStatement.rawValue,
        "responsibleTool": responsibleTool,
        "originalName": originalName,
      ]
    )
  }
}

package struct QuarantineRestoreUserConfirmation: Hashable, Sendable {
  package let request: QuarantineRestoreConfirmationRequest
  package let statement: QuarantineRestoreConfirmationStatement

  package init(
    request: QuarantineRestoreConfirmationRequest,
    statement: QuarantineRestoreConfirmationStatement
  ) {
    self.request = request
    self.statement = statement
  }
}

package enum QuarantineRestoreAuthorizationFailure: Error, Equatable, Sendable {
  case confirmationDoesNotBelongToAttempt
  case confirmationStatementMismatch
  case attemptAlreadyAuthorized
  case attemptCancelled
  case invalidPreparedEvidence
  case cancelled
}

package struct QuarantineRestoreAuthorization: CustomReflectable, Sendable {
  package var isSingleUse: Bool { true }
  package var authorizesRestoreOnly: Bool { true }
  package var authorizesPermanentDeletion: Bool { false }
  package var authorizesOverwrite: Bool { false }

  fileprivate let underlying: CleanupQuarantineRestoreAuthorization

  package var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "isSingleUse": isSingleUse,
        "authorizesRestoreOnly": authorizesRestoreOnly,
        "authorizesPermanentDeletion": authorizesPermanentDeletion,
        "authorizesOverwrite": authorizesOverwrite,
      ]
    )
  }
}

package struct QuarantineRestoreAuthorizationSession: CustomReflectable, Sendable {
  package let confirmationRequest: QuarantineRestoreConfirmationRequest

  fileprivate let underlying: CleanupQuarantineRestoreAuthorizationSession

  fileprivate init(_ underlying: CleanupQuarantineRestoreAuthorizationSession) {
    self.underlying = underlying
    confirmationRequest = QuarantineRestoreConfirmationRequest(
      requiredStatement:
        .restoreCurrentQuarantinedContentsWithoutOverwriteWithNPMStoppedAndChangesAccepted,
      responsibleTool: underlying.confirmationRequest.subject.responsibleTool,
      originalName: "_cacache",
      underlying: underlying.confirmationRequest
    )
  }

  package func authorize(
    using confirmation: QuarantineRestoreUserConfirmation
  ) async throws -> QuarantineRestoreAuthorization {
    guard confirmation.request.underlying == confirmationRequest.underlying else {
      throw QuarantineRestoreAuthorizationFailure.confirmationDoesNotBelongToAttempt
    }
    guard confirmation.statement == confirmationRequest.requiredStatement else {
      throw QuarantineRestoreAuthorizationFailure.confirmationStatementMismatch
    }

    do {
      let authorization = try await underlying.authorize(
        using: CleanupQuarantineRestoreUserConfirmation(
          request: underlying.confirmationRequest,
          statement: underlying.confirmationRequest.requiredStatement
        )
      )
      return QuarantineRestoreAuthorization(underlying: authorization)
    } catch is CancellationError {
      throw QuarantineRestoreAuthorizationFailure.cancelled
    } catch let failure as CleanupQuarantineRestoreAuthorizationError {
      throw QuarantineRestoreAuthorizationFailure(failure)
    } catch {
      throw QuarantineRestoreAuthorizationFailure.invalidPreparedEvidence
    }
  }

  package func cancel() async {
    await underlying.cancel()
  }

  package var customMirror: Mirror {
    Mirror(self, children: ["confirmationRequest": confirmationRequest])
  }
}

package enum QuarantineRestoreNotRestoredReason: Equatable, Sendable {
  case cancelled
  case invalidAuthorization
  case invalidCurrentAccount
  case trustedLocationUnavailable
  case trustedLocationChanged
  case unsupported
  case inventoryChanged
  case alreadyRestored
  case sourceOccupied
  case quarantinedItemMissing
  case quarantinedItemChanged
  case quarantinedItemUnsafe
  case traversalLimitExceeded
  case journalBusy
  case journalUnavailable
  case renameRejected
}

package enum QuarantineRestoreManualRecoveryReason: Equatable, Sendable {
  case quarantineJournalUnsafe
  case durabilityRecordingFailed
  case renameOutcomeIndeterminate
  case parentBindingChanged
  case sourceCouldNotBeVerified
  case quarantineItemCouldNotBeVerified
}

package enum QuarantineRestoreExecutionStatus: Equatable, Sendable {
  case notRestored(QuarantineRestoreNotRestoredReason)
  case restored(quarantineNameWasRecreated: Bool)
  case manualRecoveryRequired(QuarantineRestoreManualRecoveryReason)
}

package enum QuarantineRestoreDurability: Equatable, Sendable {
  case notRecorded
  case intentRecorded
  case receiptRecorded(producedByRecovery: Bool)
  case unresolved
}

package struct QuarantineRestoreExecutionOutcome: Equatable, Sendable {
  package let status: QuarantineRestoreExecutionStatus
  package let durability: QuarantineRestoreDurability
  package let cancellationWasObservedAfterRename: Bool

  package var isDurablyRestored: Bool {
    guard case .restored = status, case .receiptRecorded = durability else {
      return false
    }
    return true
  }

  package var performedPermanentDeletion: Bool { false }
  package var overwroteExistingItem: Bool { false }
}

package enum QuarantineRestoreExecutionFailure: Error, Equatable, Sendable {
  case invalidAuthorization
  case authorizationAlreadyConsumed
  case authorizationCancelled
  case cancelled
}

package enum QuarantinePurgeAttemptKind: String, Hashable, Sendable {
  case initial
  case explicitRetry = "explicit-retry"
}

/// The exact, attempt-specific assertion required before irreversible work.
/// Initial staging and continuation of an existing remainder deliberately use
/// different statements and cannot authorize one another.
package enum QuarantinePurgeConfirmationStatement: String, Hashable, Sendable {
  case initialPermanentDeletionRisksAccepted =
    "permanently-delete-current-receipt-bound-quarantined-contents-with-restore-cutoff-and-partial-deletion-risk-npm-and-other-work-stopped-unobserved-activity-and-post-quarantine-change-risk-capacity-may-increase-by-zero-or-be-unavailable-accepted"
  case explicitRetryPermanentDeletionRisksAccepted =
    "continue-permanent-deletion-of-exact-receipt-bound-staged-remainder-with-restore-unavailable-and-partial-deletion-risk-npm-and-other-work-stopped-unobserved-activity-and-post-quarantine-change-risk-capacity-may-increase-by-zero-or-be-unavailable-accepted"
}

package struct QuarantinePurgeConfirmationRequest: CustomReflectable, Hashable, Sendable {
  package let attemptKind: QuarantinePurgeAttemptKind
  package let requiredStatement: QuarantinePurgeConfirmationStatement
  package let responsibleTool: String
  package let originalName: String

  fileprivate let underlying: CleanupQuarantinePurgeConfirmationRequest

  package static func == (
    left: QuarantinePurgeConfirmationRequest,
    right: QuarantinePurgeConfirmationRequest
  ) -> Bool {
    left.underlying == right.underlying
      && left.attemptKind == right.attemptKind
      && left.requiredStatement == right.requiredStatement
      && left.responsibleTool == right.responsibleTool
      && left.originalName == right.originalName
  }

  package func hash(into hasher: inout Hasher) {
    hasher.combine(underlying)
    hasher.combine(attemptKind)
    hasher.combine(requiredStatement)
    hasher.combine(responsibleTool)
    hasher.combine(originalName)
  }

  package var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "attemptKind": attemptKind.rawValue,
        "requiredStatement": requiredStatement.rawValue,
        "responsibleTool": responsibleTool,
        "originalName": originalName,
      ]
    )
  }
}

package struct QuarantinePurgeUserConfirmation: CustomReflectable, Hashable, Sendable {
  package let request: QuarantinePurgeConfirmationRequest
  package let statement: QuarantinePurgeConfirmationStatement

  package init(
    request: QuarantinePurgeConfirmationRequest,
    statement: QuarantinePurgeConfirmationStatement
  ) {
    self.request = request
    self.statement = statement
  }

  package var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "request": request,
        "statement": statement.rawValue,
      ]
    )
  }
}

package enum QuarantinePurgeAuthorizationFailure: Error, Equatable, Sendable {
  case confirmationDoesNotBelongToAttempt
  case confirmationStatementMismatch
  case attemptAlreadyAuthorized
  case attemptCancelled
  case invalidPreparedEvidence
  case cancelled
}

/// Process-local, single-use authority for one exact receipt-bound purge pass.
/// It deliberately carries no caller-selected path or standalone filesystem
/// mutation capability.
package struct QuarantinePurgeAuthorization: CustomReflectable, Sendable {
  package var attemptKind: QuarantinePurgeAttemptKind {
    QuarantinePurgeAttemptKind(underlying.attemptKind)
  }

  package var isSingleUse: Bool { underlying.isSingleUse }
  package var authorizesPurgeOnly: Bool { underlying.authorizesPurgeOnly }
  package var authorizesPermanentDeletion: Bool { underlying.authorizesPermanentDeletion }
  package var authorizesRestore: Bool { underlying.authorizesRestore }
  package var authorizesOverwrite: Bool { underlying.authorizesOverwrite }
  package var authorizesArbitraryPaths: Bool { underlying.authorizesArbitraryPaths }
  package var authorizesActiveCacheDeletion: Bool { underlying.authorizesActiveCacheDeletion }
  package var authorizesOnlyExactStagedWorkTree: Bool {
    underlying.authorizesOnlyExactStagedWorkTree
  }
  package var requiresInlineFilesystemRevalidation: Bool {
    underlying.requiresInlineFilesystemRevalidation
  }
  package var requiresInlineACLRevalidation: Bool {
    underlying.requiresInlineACLRevalidation
  }
  package var grantsStandaloneFilesystemMutationAuthority: Bool {
    underlying.grantsStandaloneFilesystemMutationAuthority
  }
  package var usesWallClockFreshness: Bool { underlying.usesWallClockFreshness }

  fileprivate let underlying: CleanupQuarantinePurgeAuthorization

  package var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "attemptKind": attemptKind.rawValue,
        "isSingleUse": isSingleUse,
        "authorizesPurgeOnly": authorizesPurgeOnly,
        "authorizesPermanentDeletion": authorizesPermanentDeletion,
        "authorizesRestore": authorizesRestore,
        "authorizesOverwrite": authorizesOverwrite,
        "authorizesArbitraryPaths": authorizesArbitraryPaths,
        "authorizesActiveCacheDeletion": authorizesActiveCacheDeletion,
        "authorizesOnlyExactStagedWorkTree": authorizesOnlyExactStagedWorkTree,
        "requiresInlineFilesystemRevalidation": requiresInlineFilesystemRevalidation,
        "requiresInlineACLRevalidation": requiresInlineACLRevalidation,
        "grantsStandaloneFilesystemMutationAuthority":
          grantsStandaloneFilesystemMutationAuthority,
        "usesWallClockFreshness": usesWallClockFreshness,
      ]
    )
  }
}

package struct QuarantinePurgeAuthorizationSession: CustomReflectable, Sendable {
  package let confirmationRequest: QuarantinePurgeConfirmationRequest

  fileprivate let underlying: CleanupQuarantinePurgeAuthorizationSession

  fileprivate init(_ underlying: CleanupQuarantinePurgeAuthorizationSession) {
    self.underlying = underlying
    confirmationRequest = QuarantinePurgeConfirmationRequest(underlying.confirmationRequest)
  }

  package func authorize(
    using confirmation: QuarantinePurgeUserConfirmation
  ) async throws -> QuarantinePurgeAuthorization {
    guard confirmation.request.underlying == confirmationRequest.underlying else {
      throw QuarantinePurgeAuthorizationFailure.confirmationDoesNotBelongToAttempt
    }
    guard confirmation.statement == confirmationRequest.requiredStatement else {
      throw QuarantinePurgeAuthorizationFailure.confirmationStatementMismatch
    }

    do {
      let authorization = try await underlying.authorize(
        using: CleanupQuarantinePurgeUserConfirmation(
          request: underlying.confirmationRequest,
          statement: underlying.confirmationRequest.requiredStatement
        ))
      return QuarantinePurgeAuthorization(underlying: authorization)
    } catch is CancellationError {
      throw QuarantinePurgeAuthorizationFailure.cancelled
    } catch let failure as CleanupQuarantinePurgeAuthorizationError {
      throw QuarantinePurgeAuthorizationFailure(failure)
    } catch {
      throw QuarantinePurgeAuthorizationFailure.invalidPreparedEvidence
    }
  }

  package func cancel() async {
    await underlying.cancel()
  }

  package var customMirror: Mirror {
    Mirror(self, children: ["confirmationRequest": confirmationRequest])
  }
}

package enum QuarantinePurgeSystemFailure: String, Equatable, Sendable {
  case permissionDenied = "permission-denied"
  case pathChanged = "path-changed"
  case unsupported
  case crossDevice = "cross-device"
  case readOnlyFileSystem = "read-only-filesystem"
  case noSpace = "no-space"
  case resourceLimit = "resource-limit"
  case invalidMetadata = "invalid-metadata"
  case inputOutput = "input-output"
  case destinationExists = "destination-exists"
  case unspecified
}

package enum QuarantinePurgeCapacityObservationFailure: Equatable, Sendable {
  case unavailable(QuarantinePurgeSystemFailure)
  case expectedDeviceMismatch
  case expectedVolumeMismatch
  case invalidFileSystemStatistics
  case availableByteCountOverflow
}

package enum QuarantinePurgePreparationFailure: Error, Equatable, Sendable {
  case invalidInventoryReference
  case inventoryChanged
  case cancelled
  case unsupportedPlatform
  case invalidCurrentAccount
  case trustedLocationUnavailable(QuarantinePurgeSystemFailure)
  case trustedLocationChanged
  case journalRecordMissing
  case journalRecordChanged
  case journalRecordUnsafe
  case quarantinedItemMissing
  case quarantinedItemChanged
  case quarantinedItemUnsafe
  case purgeWorkMissing
  case purgeWorkChanged
  case purgeWorkUnsafe
  case purgeWorkNameOccupied
  case traversalLimitExceeded
  case capacityObservation(QuarantinePurgeCapacityObservationFailure)
  case purgeIdentifierUnavailable
  case authorization(QuarantinePurgeAuthorizationFailure)
}

package enum QuarantinePurgeTerminalReceiptOutcome: String, Equatable, Sendable {
  case notPurged = "not-purged"
  case itemAbsent = "item-absent"
}

package enum QuarantinePurgeNoMutationReason: Equatable, Sendable {
  case cancelled
  case invalidAuthorization
  case unsupportedPlatform
  case invalidCurrentAccount
  case trustedLocationUnavailable(QuarantinePurgeSystemFailure)
  case trustedLocationChanged
  case journalRecordMissing
  case journalRecordChanged
  case journalRecordUnsafe
  case quarantinedItemMissing
  case quarantinedItemChanged
  case quarantinedItemUnsafe
  case purgeWorkMissing
  case purgeWorkChanged
  case purgeWorkUnsafe
  case purgeWorkNameOccupied
  case traversalLimitExceeded
  case capacityObservationUnavailable
  case purgeIdentifierUnavailable
  case originalTransactionUnavailable
  case originalTransactionNotPurgeable
  case alreadyPurged
  case quarantineJournalBusy
  case quarantineJournalUnavailable(QuarantinePurgeSystemFailure)
  case exclusiveRenameUnsupported
  case renameRejected(QuarantinePurgeSystemFailure)
}

package enum QuarantinePurgeProgress: String, Equatable, Sendable {
  case stagedWithNoUnlinkObserved = "staged-with-no-unlink-observed"
  case unlinkProgressObserved = "unlink-progress-observed"
}

package enum QuarantinePurgeRetryReason: Equatable, Sendable {
  case cancelled
  case namespaceChanged
  case treeChanged
  case treeUnsafe
  case traversalLimitExceeded
  case synchronizationLimitExceeded
  case observationUnavailable(QuarantinePurgeSystemFailure)
  case unlinkRejected(QuarantinePurgeSystemFailure)
  case synchronizationFailed(QuarantinePurgeSystemFailure)
}

package enum QuarantinePurgeRecoveryReason: String, Equatable, Sendable {
  case stagingNotCommitted = "staging-not-committed"
  case stagingMayHaveBeenInvoked = "staging-may-have-been-invoked"
  case journalRequiresReconciliation = "journal-requires-reconciliation"
}

package enum QuarantinePurgeManualRecoveryReason: String, Equatable, Sendable {
  case invalidExecutionResult = "invalid-execution-result"
  case invalidTerminalReceipt = "invalid-terminal-receipt"
  case invalidTerminalizationSession = "invalid-terminalization-session"
  case journalUnsafe = "journal-unsafe"
  case recordsChanged = "records-changed"
  case parentBindingChanged = "parent-binding-changed"
  case namespaceAmbiguous = "namespace-ambiguous"
  case workTreeChanged = "work-tree-changed"
  case workTreeUnsafe = "work-tree-unsafe"
  case traversalLimitExceeded = "traversal-limit-exceeded"
  case durabilityUnresolved = "durability-unresolved"
}

package enum QuarantinePurgeExecutionStatus: Equatable, Sendable {
  case noMutation(QuarantinePurgeNoMutationReason)
  case notPurged
  case observationalRecoveryRequired(QuarantinePurgeRecoveryReason)
  case explicitRetryRequired(
    progress: QuarantinePurgeProgress,
    reason: QuarantinePurgeRetryReason
  )
  case itemAbsent
  case manualRecoveryRequired(QuarantinePurgeManualRecoveryReason)
}

package enum QuarantinePurgeDurability: Equatable, Sendable {
  case notRecorded
  case intentRecorded
  case terminalReceiptRecorded(
    outcome: QuarantinePurgeTerminalReceiptOutcome,
    producedByRecovery: Bool
  )
  case unresolved

  package var isDurablyTerminal: Bool {
    guard case .terminalReceiptRecorded = self else { return false }
    return true
  }

  package var isCrashRecoverable: Bool {
    switch self {
    case .intentRecorded, .terminalReceiptRecorded:
      return true
    case .notRecorded, .unresolved:
      return false
    }
  }
}

package enum QuarantinePurgeCapacityObservationProvenance: String, Equatable, Sendable {
  case initialAttempt = "initial-attempt"
  case explicitRetry = "explicit-retry"
  case recovery
}

package enum QuarantinePurgeCapacityChange: Equatable, Sendable {
  case increase(amount: UInt64)
  case unchanged
  case decrease(amount: UInt64)
  case unavailable
}

/// Privacy-bounded result for one separately confirmed purge pass. Capacity
/// change is observational and is never attributed to DevSift.
package struct QuarantinePurgeExecutionOutcome: CustomReflectable, Equatable, Sendable {
  package let attemptKind: QuarantinePurgeAttemptKind
  package let status: QuarantinePurgeExecutionStatus
  package let durability: QuarantinePurgeDurability
  package let capacityObservationProvenance: QuarantinePurgeCapacityObservationProvenance?
  package let observedCapacityChange: QuarantinePurgeCapacityChange
  package let observedUnlinkCount: UInt64
  package let cancellationWasObserved: Bool

  package var isDurablyTerminal: Bool { durability.isDurablyTerminal }
  package var isCrashRecoverable: Bool { durability.isCrashRecoverable }
  package var performedPermanentDeletion: Bool { observedUnlinkCount > 0 }

  package var requiresExplicitRetry: Bool {
    guard case .explicitRetryRequired = status else { return false }
    return true
  }

  package var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "attemptKind": attemptKind.rawValue,
        "status": status,
        "durability": durability,
        "capacityObservationProvenance": capacityObservationProvenance?.rawValue as Any,
        "observedCapacityChange": observedCapacityChange,
        "observedUnlinkCount": observedUnlinkCount,
        "cancellationWasObserved": cancellationWasObserved,
      ]
    )
  }
}

package enum QuarantinePurgeExecutionFailure: Error, Equatable, Sendable {
  case invalidAuthorization
  case authorizationAlreadyConsumed
  case authorizationCancelled
  case cancelled
}

/// The only package-visible bridge to Core's bounded quarantine inventory,
/// restore primitives, and receipt-bound purge primitives.
/// Production initialization accepts no root, transaction identifier, item
/// path, journal bytes, or purge authority.
package struct QuarantineInventoryRestoreWorkflow: Sendable {
  typealias LoadInventory = @Sendable () -> DescriptorQuarantineInventoryResult
  typealias PrepareRestore =
    @Sendable (DescriptorQuarantineInventoryEntry) -> Result<
      CleanupQuarantineRestoreAuthorizationSession,
      DescriptorNPMQuarantineRestorePreflightFailure
    >
  typealias ExecuteRestore =
    @Sendable (
      CleanupQuarantineRestoreAuthorization
    ) async throws -> CleanupQuarantineRestoreReport
  typealias PrepareInitialPurge =
    @Sendable (QuarantineInventoryInitialPurgeSelection) -> Result<
      CleanupQuarantinePurgeAuthorizationSession,
      DescriptorNPMQuarantinePurgePreflightFailure
    >
  typealias PreparePurgeRetry =
    @Sendable (QuarantineInventoryPurgeRetrySelection) -> Result<
      CleanupQuarantinePurgeAuthorizationSession,
      DescriptorNPMQuarantinePurgePreflightFailure
    >
  typealias ExecutePurge =
    @Sendable (
      CleanupQuarantinePurgeAuthorization
    ) async throws -> CleanupQuarantinePurgeReport

  private let loadInventory: LoadInventory
  private let prepareRestore: PrepareRestore
  private let executeRestore: ExecuteRestore
  private let prepareInitialPurge: PrepareInitialPurge
  private let preparePurgeRetry: PreparePurgeRetry
  private let executeAuthorizedPurge: ExecutePurge

  package init() {
    let loader = DescriptorNPMQuarantineInventoryLoader()
    let restorePreflight = DescriptorNPMQuarantineRestorePreflight()
    let restoreExecutor = CleanupQuarantineRestoreExecutor()
    let purgePreflight = DescriptorNPMQuarantinePurgePreflight()
    let purgeExecutor = CleanupQuarantinePurgeExecutor()
    loadInventory = { loader.reconcileAndLoadInventory() }
    prepareRestore = {
      restorePreflight.prepare(
        quarantineTransactionID: $0.quarantineTransactionID,
        expectedCanonicalIntentBytes: $0.canonicalQuarantineIntentBytes,
        expectedCanonicalReceiptBytes: $0.canonicalQuarantineReceiptBytes
      )
    }
    executeRestore = { try await restoreExecutor.execute($0) }
    prepareInitialPurge = { purgePreflight.prepareInitial($0) }
    preparePurgeRetry = { purgePreflight.prepareExplicitRetry($0) }
    executeAuthorizedPurge = { try await purgeExecutor.execute($0) }
  }

  init(
    loadInventory: @escaping LoadInventory,
    prepareRestore: @escaping PrepareRestore,
    executeRestore: @escaping ExecuteRestore
  ) {
    self.init(
      loadInventory: loadInventory,
      prepareRestore: prepareRestore,
      executeRestore: executeRestore,
      prepareInitialPurge: { _ in .failure(.invalidSelection) },
      preparePurgeRetry: { _ in .failure(.invalidSelection) },
      executePurge: { _ in
        throw CleanupQuarantinePurgeAuthorizationConsumptionError.authorizationCancelled
      }
    )
  }

  init(
    loadInventory: @escaping LoadInventory,
    prepareRestore: @escaping PrepareRestore,
    executeRestore: @escaping ExecuteRestore,
    prepareInitialPurge: @escaping PrepareInitialPurge,
    preparePurgeRetry: @escaping PreparePurgeRetry,
    executePurge: @escaping ExecutePurge
  ) {
    self.loadInventory = loadInventory
    self.prepareRestore = prepareRestore
    self.executeRestore = executeRestore
    self.prepareInitialPurge = prepareInitialPurge
    self.preparePurgeRetry = preparePurgeRetry
    executeAuthorizedPurge = executePurge
  }

  package func reconcileAndLoadInventory()
    -> Result<QuarantineInventorySession, QuarantineInventoryLoadFailure>
  {
    switch loadInventory() {
    case .success(let entries):
      return .success(QuarantineInventorySession(entries: entries))
    case .failure(let failure):
      return .failure(QuarantineInventoryLoadFailure(failure))
    }
  }

  package func beginRestore(
    from inventory: QuarantineInventorySession,
    item reference: QuarantineInventoryItemReference
  ) -> Result<QuarantineRestoreAuthorizationSession, QuarantineRestorePreparationFailure> {
    guard let entry = inventory.entry(for: reference) else {
      return .failure(.invalidInventoryReference)
    }
    guard let item = inventory.items.first(where: { $0.reference == reference }) else {
      return .failure(.invalidInventoryReference)
    }
    guard item.readiness.canRestore else {
      return .failure(QuarantineRestorePreparationFailure(item.readiness))
    }

    switch prepareRestore(entry) {
    case .success(let session):
      return .success(QuarantineRestoreAuthorizationSession(session))
    case .failure(let failure):
      return .failure(QuarantineRestorePreparationFailure(failure))
    }
  }

  /// Resolves one exact session-owned inventory reference for a future initial
  /// purge preflight. This performs no authorization or filesystem mutation.
  package func selectForInitialPurge(
    from inventory: QuarantineInventorySession,
    item reference: QuarantineInventoryItemReference
  ) -> Result<QuarantineInventoryInitialPurgeSelection, QuarantineInventoryPurgeSelectionFailure> {
    guard let entry = inventory.entry(for: reference) else {
      return .failure(.invalidInventoryReference)
    }
    guard let item = inventory.items.first(where: { $0.reference == reference }) else {
      return .failure(.invalidInventoryReference)
    }

    switch item.purgeReadiness.quarantinedItem {
    case .available:
      return .success(
        QuarantineInventoryInitialPurgeSelection(
          entry: entry,
          sessionIdentity: inventory.sessionIdentity,
          ordinal: reference.ordinal
        ))
    case .missing:
      return .failure(.quarantinedItemMissing)
    case .changed:
      return .failure(.quarantinedItemChanged)
    case .unsafe:
      return .failure(.quarantinedItemUnsafe)
    case .traversalLimitExceeded:
      return .failure(.traversalLimitExceeded)
    }
  }

  /// Resolves the one exact staged remainder from this inventory session. The
  /// result still carries no authority and performs no filesystem mutation.
  package func selectForPurgeRetry(
    from inventory: QuarantineInventorySession,
    retry reference: QuarantineInventoryPurgeRetryReference
  ) -> Result<QuarantineInventoryPurgeRetrySelection, QuarantineInventoryPurgeSelectionFailure> {
    guard let entry = inventory.purgeRetryEntry(for: reference) else {
      return .failure(.invalidInventoryReference)
    }
    return .success(
      QuarantineInventoryPurgeRetrySelection(
        entry: entry,
        sessionIdentity: inventory.sessionIdentity,
        ordinal: reference.ordinal
      ))
  }

  /// Revalidates and prepares one exact inventory-owned item for a new purge
  /// attempt. The active npm cache is never an input to this operation.
  package func beginInitialPurge(
    from inventory: QuarantineInventorySession,
    item reference: QuarantineInventoryItemReference
  ) -> Result<QuarantinePurgeAuthorizationSession, QuarantinePurgePreparationFailure> {
    let selection: QuarantineInventoryInitialPurgeSelection
    switch selectForInitialPurge(from: inventory, item: reference) {
    case .success(let resolved):
      selection = resolved
    case .failure(let failure):
      return .failure(QuarantinePurgePreparationFailure(failure))
    }

    switch prepareInitialPurge(selection) {
    case .success(let session):
      return .success(QuarantinePurgeAuthorizationSession(session))
    case .failure(let failure):
      return .failure(QuarantinePurgePreparationFailure(failure))
    }
  }

  /// Revalidates and prepares the exact staged remainder represented by one
  /// retry row. It never creates a new purge intent or staging name.
  package func beginPurgeRetry(
    from inventory: QuarantineInventorySession,
    retry reference: QuarantineInventoryPurgeRetryReference
  ) -> Result<QuarantinePurgeAuthorizationSession, QuarantinePurgePreparationFailure> {
    let selection: QuarantineInventoryPurgeRetrySelection
    switch selectForPurgeRetry(from: inventory, retry: reference) {
    case .success(let resolved):
      selection = resolved
    case .failure(let failure):
      return .failure(QuarantinePurgePreparationFailure(failure))
    }

    switch preparePurgeRetry(selection) {
    case .success(let session):
      return .success(QuarantinePurgeAuthorizationSession(session))
    case .failure(let failure):
      return .failure(QuarantinePurgePreparationFailure(failure))
    }
  }

  package func execute(
    _ authorization: QuarantineRestoreAuthorization
  ) async -> Result<QuarantineRestoreExecutionOutcome, QuarantineRestoreExecutionFailure> {
    do {
      let report = try await executeRestore(authorization.underlying)
      return .success(QuarantineRestoreExecutionOutcome(report))
    } catch is CancellationError {
      return .failure(.cancelled)
    } catch let failure as CleanupQuarantineRestoreAuthorizationConsumptionError {
      return .failure(QuarantineRestoreExecutionFailure(failure))
    } catch {
      return .failure(.invalidAuthorization)
    }
  }

  /// Consumes one Core-issued purge authority. Every authorization copy shares
  /// the same atomic single-use state.
  package func executePurge(
    _ authorization: QuarantinePurgeAuthorization
  ) async -> Result<QuarantinePurgeExecutionOutcome, QuarantinePurgeExecutionFailure> {
    do {
      let report = try await executeAuthorizedPurge(authorization.underlying)
      return .success(QuarantinePurgeExecutionOutcome(report))
    } catch is CancellationError {
      return .failure(.cancelled)
    } catch let failure as CleanupQuarantinePurgeAuthorizationConsumptionError {
      return .failure(QuarantinePurgeExecutionFailure(failure))
    } catch {
      return .failure(.invalidAuthorization)
    }
  }
}

extension QuarantineInventoryOriginalSourceState {
  fileprivate init(_ state: DescriptorQuarantineInventorySourceState) {
    switch state {
    case .missing:
      self = .missing
    case .expectedObjectPresent:
      self = .expectedObjectPresent
    case .otherObjectPresent:
      self = .otherObjectPresent
    }
  }
}

extension QuarantineInventoryItemState {
  fileprivate init(_ state: DescriptorQuarantineInventoryItemState) {
    switch state {
    case .available:
      self = .available
    case .missing:
      self = .missing
    case .changed:
      self = .changed
    case .unsafe:
      self = .unsafe
    case .traversalLimitExceeded:
      self = .traversalLimitExceeded
    }
  }
}

extension QuarantineInventoryLoadFailure {
  fileprivate init(_ failure: DescriptorQuarantineInventoryFailure) {
    switch failure {
    case .cancelled:
      self = .cancelled
    case .journal(.busy):
      self = .busy
    case .journal(.unsafe):
      self = .trustedLocationUnsafe
    case .journal(.unavailable(.unsupported)):
      self = .unsupportedPlatform
    case .journal(.unavailable):
      self = .trustedLocationUnavailable
    case .journal(.recoveryRequired):
      self = .manualRecoveryRequired
    }
  }
}

extension QuarantineRestorePreparationFailure {
  fileprivate init(_ readiness: QuarantineInventoryRestoreReadiness) {
    if readiness.originalSource != .missing {
      self = .sourceOccupied
      return
    }
    switch readiness.quarantinedItem {
    case .available:
      self = .inventoryChanged
    case .missing:
      self = .quarantinedItemMissing
    case .changed:
      self = .quarantinedItemChanged
    case .unsafe:
      self = .quarantinedItemUnsafe
    case .traversalLimitExceeded:
      self = .traversalLimitExceeded
    }
  }

  fileprivate init(_ failure: DescriptorNPMQuarantineRestorePreflightFailure) {
    switch failure {
    case .cancelled:
      self = .cancelled
    case .invalidCurrentAccount, .invalidHome:
      self = .trustedLocationUnsafe
    case .invalidQuarantineTransactionID, .restoreIdentifierUnavailable,
      .restoreIdentifierCollisionLimitExceeded, .authorization, .invalidClaim:
      self = .inventoryChanged
    case .homeUnavailable, .rootUnavailable, .quarantineRootUnavailable:
      self = .trustedLocationUnavailable
    case .homeUnsafe, .rootUnsafe, .quarantineRootUnsafe:
      self = .trustedLocationUnsafe
    case .restore(let failure):
      self = QuarantineRestorePreparationFailure(failure)
    }
  }

  fileprivate init(_ failure: DescriptorQuarantineRestoreFailure) {
    switch failure {
    case .cancelled:
      self = .cancelled
    case .journal(.busy):
      self = .busy
    case .journal(.unsafe):
      self = .trustedLocationUnsafe
    case .journal(.unavailable(.unsupported)), .exclusiveRenameUnsupported:
      self = .unsupportedPlatform
    case .journal(.unavailable):
      self = .trustedLocationUnavailable
    case .journal(.recoveryRequired):
      self = .manualRecoveryRequired
    case .invalidClaim, .transactionNotFound, .transactionNotRestorable, .alreadyRestored:
      self = .inventoryChanged
    case .sourceNameOccupied:
      self = .sourceOccupied
    case .quarantinedItemMissing:
      self = .quarantinedItemMissing
    case .quarantinedItemChanged:
      self = .quarantinedItemChanged
    case .quarantinedItemUnsafe:
      self = .quarantinedItemUnsafe
    case .traversalLimitExceeded:
      self = .traversalLimitExceeded
    case .renameRejected:
      self = .trustedLocationUnavailable
    }
  }
}

extension QuarantineRestoreAuthorizationFailure {
  fileprivate init(_ failure: CleanupQuarantineRestoreAuthorizationError) {
    switch failure {
    case .invalidPreparedEvidence:
      self = .invalidPreparedEvidence
    case .confirmationDoesNotBelongToAttempt:
      self = .confirmationDoesNotBelongToAttempt
    case .confirmationStatementMismatch:
      self = .confirmationStatementMismatch
    case .attemptAlreadyAuthorized:
      self = .attemptAlreadyAuthorized
    case .attemptCancelled:
      self = .attemptCancelled
    }
  }
}

extension QuarantineRestoreExecutionFailure {
  fileprivate init(_ failure: CleanupQuarantineRestoreAuthorizationConsumptionError) {
    switch failure {
    case .unsupportedContractVersion, .authorizationDoesNotBelongToAttempt:
      self = .invalidAuthorization
    case .authorizationAlreadyConsumed:
      self = .authorizationAlreadyConsumed
    case .authorizationCancelled:
      self = .authorizationCancelled
    }
  }
}

extension QuarantineRestoreExecutionOutcome {
  fileprivate init(_ report: CleanupQuarantineRestoreReport) {
    status = QuarantineRestoreExecutionStatus(report.status)
    durability = QuarantineRestoreDurability(report.durabilityState)
    cancellationWasObservedAfterRename = report.cancellationWasObservedAfterRename
  }
}

extension QuarantineRestoreExecutionStatus {
  fileprivate init(_ status: CleanupQuarantineRestoreStatus) {
    switch status {
    case .notRestored(let reason):
      self = .notRestored(QuarantineRestoreNotRestoredReason(reason))
    case .restored(_, let quarantineNameWasRecreated):
      self = .restored(quarantineNameWasRecreated: quarantineNameWasRecreated)
    case .manualRecoveryRequired(_, let reason):
      self = .manualRecoveryRequired(QuarantineRestoreManualRecoveryReason(reason))
    }
  }
}

extension QuarantineRestoreNotRestoredReason {
  fileprivate init(_ reason: CleanupQuarantineRestoreNotRestoredReason) {
    switch reason {
    case .cancelled:
      self = .cancelled
    case .invalidClaim:
      self = .invalidAuthorization
    case .invalidCurrentAccount:
      self = .invalidCurrentAccount
    case .trustedRootUnavailable:
      self = .trustedLocationUnavailable
    case .trustedRootChanged:
      self = .trustedLocationChanged
    case .unsupported, .exclusiveRenameUnsupported:
      self = .unsupported
    case .originalTransactionUnavailable, .originalTransactionNotRestorable:
      self = .inventoryChanged
    case .alreadyRestored:
      self = .alreadyRestored
    case .sourceNameOccupied:
      self = .sourceOccupied
    case .quarantinedItemMissing:
      self = .quarantinedItemMissing
    case .quarantinedItemChanged:
      self = .quarantinedItemChanged
    case .quarantinedItemUnsafe:
      self = .quarantinedItemUnsafe
    case .traversalLimitExceeded:
      self = .traversalLimitExceeded
    case .quarantineJournalBusy:
      self = .journalBusy
    case .quarantineJournalUnavailable:
      self = .journalUnavailable
    case .renameRejected:
      self = .renameRejected
    }
  }
}

extension QuarantineRestoreManualRecoveryReason {
  fileprivate init(_ reason: CleanupQuarantineRestoreManualRecoveryReason) {
    switch reason {
    case .quarantineJournalUnsafe:
      self = .quarantineJournalUnsafe
    case .durabilityRecordingFailed:
      self = .durabilityRecordingFailed
    case .renameOutcomeIndeterminate:
      self = .renameOutcomeIndeterminate
    case .parentBindingChanged:
      self = .parentBindingChanged
    case .sourceCouldNotBeVerified:
      self = .sourceCouldNotBeVerified
    case .quarantineItemCouldNotBeVerified:
      self = .quarantineItemCouldNotBeVerified
    }
  }
}

extension QuarantineRestoreDurability {
  fileprivate init(_ state: CleanupQuarantineRestoreDurabilityState) {
    switch state {
    case .notRecorded:
      self = .notRecorded
    case .intentRecorded:
      self = .intentRecorded
    case .receiptRecorded(_, let producedByRecovery):
      self = .receiptRecorded(producedByRecovery: producedByRecovery)
    case .unresolved:
      self = .unresolved
    }
  }
}

extension QuarantinePurgeAttemptKind {
  fileprivate init(_ kind: CleanupQuarantinePurgeAttemptKind) {
    switch kind {
    case .initial:
      self = .initial
    case .explicitRetry:
      self = .explicitRetry
    }
  }
}

extension QuarantinePurgeConfirmationStatement {
  fileprivate init(_ statement: CleanupQuarantinePurgeConfirmationStatement) {
    switch statement {
    case .initialPermanentDeletionRisksAccepted:
      self = .initialPermanentDeletionRisksAccepted
    case .explicitRetryPermanentDeletionRisksAccepted:
      self = .explicitRetryPermanentDeletionRisksAccepted
    }
  }
}

extension QuarantinePurgeConfirmationRequest {
  fileprivate init(_ request: CleanupQuarantinePurgeConfirmationRequest) {
    attemptKind = QuarantinePurgeAttemptKind(request.attemptKind)
    requiredStatement = QuarantinePurgeConfirmationStatement(request.requiredStatement)
    responsibleTool = request.subject.responsibleTool
    originalName = request.subject.originalName
    underlying = request
  }
}

extension QuarantinePurgeAuthorizationFailure {
  fileprivate init(_ failure: CleanupQuarantinePurgeAuthorizationError) {
    switch failure {
    case .invalidPreparedEvidence:
      self = .invalidPreparedEvidence
    case .confirmationDoesNotBelongToAttempt:
      self = .confirmationDoesNotBelongToAttempt
    case .confirmationStatementMismatch:
      self = .confirmationStatementMismatch
    case .attemptAlreadyAuthorized:
      self = .attemptAlreadyAuthorized
    case .attemptCancelled:
      self = .attemptCancelled
    }
  }
}

extension QuarantinePurgeSystemFailure {
  fileprivate init(_ failure: CleanupQuarantineSystemFailure) {
    switch failure {
    case .permissionDenied:
      self = .permissionDenied
    case .pathChanged:
      self = .pathChanged
    case .unsupported:
      self = .unsupported
    case .crossDevice:
      self = .crossDevice
    case .readOnlyFileSystem:
      self = .readOnlyFileSystem
    case .noSpace:
      self = .noSpace
    case .resourceLimit:
      self = .resourceLimit
    case .invalidMetadata:
      self = .invalidMetadata
    case .inputOutput:
      self = .inputOutput
    case .destinationExists:
      self = .destinationExists
    case .unspecified:
      self = .unspecified
    }
  }
}

extension QuarantinePurgeCapacityObservationFailure {
  fileprivate init(_ failure: DescriptorQuarantinePurgeCapacityObservationFailure) {
    switch failure {
    case .unavailable(let systemFailure):
      self = .unavailable(QuarantinePurgeSystemFailure(systemFailure))
    case .expectedDeviceMismatch:
      self = .expectedDeviceMismatch
    case .expectedVolumeMismatch:
      self = .expectedVolumeMismatch
    case .invalidFileSystemStatistics:
      self = .invalidFileSystemStatistics
    case .availableByteCountOverflow:
      self = .availableByteCountOverflow
    }
  }
}

extension QuarantinePurgePreparationFailure {
  fileprivate init(_ failure: QuarantineInventoryPurgeSelectionFailure) {
    switch failure {
    case .invalidInventoryReference:
      self = .invalidInventoryReference
    case .quarantinedItemMissing:
      self = .quarantinedItemMissing
    case .quarantinedItemChanged:
      self = .quarantinedItemChanged
    case .quarantinedItemUnsafe:
      self = .quarantinedItemUnsafe
    case .traversalLimitExceeded:
      self = .traversalLimitExceeded
    }
  }

  fileprivate init(_ failure: DescriptorNPMQuarantinePurgePreflightFailure) {
    switch failure {
    case .cancelled:
      self = .cancelled
    case .unsupportedPlatform:
      self = .unsupportedPlatform
    case .invalidSelection, .invalidClaim:
      self = .inventoryChanged
    case .invalidCurrentAccount:
      self = .invalidCurrentAccount
    case .invalidHome:
      self = .trustedLocationUnavailable(.invalidMetadata)
    case .homeUnavailable(let systemFailure), .rootUnavailable(let systemFailure),
      .quarantineRootUnavailable(let systemFailure):
      self = .trustedLocationUnavailable(QuarantinePurgeSystemFailure(systemFailure))
    case .homeUnsafe, .rootUnsafe, .quarantineRootUnsafe:
      self = .trustedLocationChanged
    case .journalRecordMissing:
      self = .journalRecordMissing
    case .journalRecordChanged:
      self = .journalRecordChanged
    case .journalRecordUnsafe:
      self = .journalRecordUnsafe
    case .quarantinedItemMissing:
      self = .quarantinedItemMissing
    case .quarantinedItemChanged:
      self = .quarantinedItemChanged
    case .quarantinedItemUnsafe:
      self = .quarantinedItemUnsafe
    case .purgeWorkMissing:
      self = .purgeWorkMissing
    case .purgeWorkChanged:
      self = .purgeWorkChanged
    case .purgeWorkUnsafe:
      self = .purgeWorkUnsafe
    case .purgeWorkNameOccupied:
      self = .purgeWorkNameOccupied
    case .traversalLimitExceeded:
      self = .traversalLimitExceeded
    case .capacityObservation(let failure):
      self = .capacityObservation(QuarantinePurgeCapacityObservationFailure(failure))
    case .purgeIdentifierUnavailable, .purgeIdentifierCollisionLimitExceeded:
      self = .purgeIdentifierUnavailable
    case .authorization(let failure):
      self = .authorization(QuarantinePurgeAuthorizationFailure(failure))
    }
  }
}

extension QuarantinePurgeExecutionFailure {
  fileprivate init(_ failure: CleanupQuarantinePurgeAuthorizationConsumptionError) {
    switch failure {
    case .unsupportedContractVersion, .authorizationDoesNotBelongToAttempt:
      self = .invalidAuthorization
    case .authorizationAlreadyConsumed:
      self = .authorizationAlreadyConsumed
    case .authorizationCancelled:
      self = .authorizationCancelled
    }
  }
}

extension QuarantinePurgeTerminalReceiptOutcome {
  fileprivate init(_ outcome: CleanupQuarantinePurgeTerminalReceiptOutcome) {
    switch outcome {
    case .notPurged:
      self = .notPurged
    case .itemAbsent:
      self = .itemAbsent
    }
  }
}

extension QuarantinePurgeNoMutationReason {
  fileprivate init(_ reason: CleanupQuarantinePurgeNoMutationReason) {
    switch reason {
    case .cancelled:
      self = .cancelled
    case .invalidClaim:
      self = .invalidAuthorization
    case .unsupportedPlatform:
      self = .unsupportedPlatform
    case .invalidCurrentAccount:
      self = .invalidCurrentAccount
    case .trustedRootUnavailable(let failure):
      self = .trustedLocationUnavailable(QuarantinePurgeSystemFailure(failure))
    case .trustedRootChanged:
      self = .trustedLocationChanged
    case .journalRecordMissing:
      self = .journalRecordMissing
    case .journalRecordChanged:
      self = .journalRecordChanged
    case .journalRecordUnsafe:
      self = .journalRecordUnsafe
    case .quarantinedItemMissing:
      self = .quarantinedItemMissing
    case .quarantinedItemChanged:
      self = .quarantinedItemChanged
    case .quarantinedItemUnsafe:
      self = .quarantinedItemUnsafe
    case .purgeWorkMissing:
      self = .purgeWorkMissing
    case .purgeWorkChanged:
      self = .purgeWorkChanged
    case .purgeWorkUnsafe:
      self = .purgeWorkUnsafe
    case .purgeWorkNameOccupied:
      self = .purgeWorkNameOccupied
    case .traversalLimitExceeded:
      self = .traversalLimitExceeded
    case .capacityObservationUnavailable:
      self = .capacityObservationUnavailable
    case .purgeIdentifierUnavailable:
      self = .purgeIdentifierUnavailable
    case .originalTransactionUnavailable:
      self = .originalTransactionUnavailable
    case .originalTransactionNotPurgeable:
      self = .originalTransactionNotPurgeable
    case .alreadyPurged:
      self = .alreadyPurged
    case .quarantineJournalBusy:
      self = .quarantineJournalBusy
    case .quarantineJournalUnavailable(let failure):
      self = .quarantineJournalUnavailable(QuarantinePurgeSystemFailure(failure))
    case .exclusiveRenameUnsupported:
      self = .exclusiveRenameUnsupported
    case .renameRejected(let failure):
      self = .renameRejected(QuarantinePurgeSystemFailure(failure))
    }
  }
}

extension QuarantinePurgeProgress {
  fileprivate init(_ progress: CleanupQuarantinePurgeProgress) {
    switch progress {
    case .stagedWithNoUnlinkObserved:
      self = .stagedWithNoUnlinkObserved
    case .unlinkProgressObserved:
      self = .unlinkProgressObserved
    }
  }
}

extension QuarantinePurgeRetryReason {
  fileprivate init(_ reason: CleanupQuarantinePurgeRetryReason) {
    switch reason {
    case .cancelled:
      self = .cancelled
    case .namespaceChanged:
      self = .namespaceChanged
    case .treeChanged:
      self = .treeChanged
    case .treeUnsafe:
      self = .treeUnsafe
    case .traversalLimitExceeded:
      self = .traversalLimitExceeded
    case .synchronizationLimitExceeded:
      self = .synchronizationLimitExceeded
    case .observationUnavailable(let failure):
      self = .observationUnavailable(QuarantinePurgeSystemFailure(failure))
    case .unlinkRejected(let failure):
      self = .unlinkRejected(QuarantinePurgeSystemFailure(failure))
    case .synchronizationFailed(let failure):
      self = .synchronizationFailed(QuarantinePurgeSystemFailure(failure))
    }
  }
}

extension QuarantinePurgeRecoveryReason {
  fileprivate init(_ reason: CleanupQuarantinePurgeRecoveryReason) {
    switch reason {
    case .stagingNotCommitted:
      self = .stagingNotCommitted
    case .stagingMayHaveBeenInvoked:
      self = .stagingMayHaveBeenInvoked
    case .journalRequiresReconciliation:
      self = .journalRequiresReconciliation
    }
  }
}

extension QuarantinePurgeManualRecoveryReason {
  fileprivate init(_ reason: CleanupQuarantinePurgeManualRecoveryReason) {
    switch reason {
    case .invalidExecutionResult:
      self = .invalidExecutionResult
    case .invalidTerminalReceipt:
      self = .invalidTerminalReceipt
    case .invalidTerminalizationSession:
      self = .invalidTerminalizationSession
    case .journalUnsafe:
      self = .journalUnsafe
    case .recordsChanged:
      self = .recordsChanged
    case .parentBindingChanged:
      self = .parentBindingChanged
    case .namespaceAmbiguous:
      self = .namespaceAmbiguous
    case .workTreeChanged:
      self = .workTreeChanged
    case .workTreeUnsafe:
      self = .workTreeUnsafe
    case .traversalLimitExceeded:
      self = .traversalLimitExceeded
    case .durabilityUnresolved:
      self = .durabilityUnresolved
    }
  }
}

extension QuarantinePurgeExecutionStatus {
  fileprivate init(_ status: CleanupQuarantinePurgeStatus) {
    switch status {
    case .noMutation(let reason):
      self = .noMutation(QuarantinePurgeNoMutationReason(reason))
    case .notPurged:
      self = .notPurged
    case .observationalRecoveryRequired(let reason):
      self = .observationalRecoveryRequired(QuarantinePurgeRecoveryReason(reason))
    case .explicitRetryRequired(let progress, let reason):
      self = .explicitRetryRequired(
        progress: QuarantinePurgeProgress(progress),
        reason: QuarantinePurgeRetryReason(reason)
      )
    case .itemAbsent:
      self = .itemAbsent
    case .manualRecoveryRequired(let reason):
      self = .manualRecoveryRequired(QuarantinePurgeManualRecoveryReason(reason))
    }
  }
}

extension QuarantinePurgeDurability {
  fileprivate init(_ state: CleanupQuarantinePurgeDurabilityState) {
    switch state {
    case .notRecorded:
      self = .notRecorded
    case .intentRecorded:
      self = .intentRecorded
    case .terminalReceiptRecorded(let outcome, let producedByRecovery):
      self = .terminalReceiptRecorded(
        outcome: QuarantinePurgeTerminalReceiptOutcome(outcome),
        producedByRecovery: producedByRecovery
      )
    case .unresolved:
      self = .unresolved
    }
  }
}

extension QuarantinePurgeCapacityObservationProvenance {
  fileprivate init(_ provenance: QuarantinePurgeCapacityObservationProvenanceV1) {
    switch provenance {
    case .initialAttempt:
      self = .initialAttempt
    case .explicitRetry:
      self = .explicitRetry
    case .recovery:
      self = .recovery
    }
  }
}

extension QuarantinePurgeCapacityChange {
  fileprivate init(_ change: QuarantinePurgeObservedCapacityChange) {
    switch change {
    case .increase(let amount):
      self = .increase(amount: amount)
    case .unchanged:
      self = .unchanged
    case .decrease(let amount):
      self = .decrease(amount: amount)
    case .unavailable:
      self = .unavailable
    }
  }
}

extension QuarantinePurgeExecutionOutcome {
  fileprivate init(_ report: CleanupQuarantinePurgeReport) {
    attemptKind = QuarantinePurgeAttemptKind(report.attemptKind)
    status = QuarantinePurgeExecutionStatus(report.status)
    durability = QuarantinePurgeDurability(report.durabilityState)
    capacityObservationProvenance = report.capacityObservationProvenance.map {
      QuarantinePurgeCapacityObservationProvenance($0)
    }
    observedCapacityChange = QuarantinePurgeCapacityChange(report.observedCapacityChange)
    observedUnlinkCount = report.observedUnlinkCount
    cancellationWasObserved = report.cancellationWasObserved
  }
}
