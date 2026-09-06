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

/// The only package-visible bridge to Core's bounded quarantine inventory,
/// restore primitives, and non-authorizing initial-purge selection.
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

  private let loadInventory: LoadInventory
  private let prepareRestore: PrepareRestore
  private let executeRestore: ExecuteRestore

  package init() {
    let loader = DescriptorNPMQuarantineInventoryLoader()
    let preflight = DescriptorNPMQuarantineRestorePreflight()
    let executor = CleanupQuarantineRestoreExecutor()
    loadInventory = { loader.reconcileAndLoadInventory() }
    prepareRestore = {
      preflight.prepare(
        quarantineTransactionID: $0.quarantineTransactionID,
        expectedCanonicalIntentBytes: $0.canonicalQuarantineIntentBytes,
        expectedCanonicalReceiptBytes: $0.canonicalQuarantineReceiptBytes
      )
    }
    executeRestore = { try await executor.execute($0) }
  }

  init(
    loadInventory: @escaping LoadInventory,
    prepareRestore: @escaping PrepareRestore,
    executeRestore: @escaping ExecuteRestore
  ) {
    self.loadInventory = loadInventory
    self.prepareRestore = prepareRestore
    self.executeRestore = executeRestore
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
