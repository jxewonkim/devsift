import DevSiftCore
import Foundation

/// App-local boundary for the explicit recovery workflow.
///
/// Implementations return only process-local handles and bounded Core states.
/// They never accept a filesystem root, path, journal transaction identifier,
/// purge request, deletion request, or overwrite authority.
protocol QuarantineRecoveryWorkflowHandling: Sendable {
  func reconcileAndLoadInventory() async
    -> Result<QuarantineRecoveryWorkflowInventory, QuarantineInventoryLoadFailure>

  func beginRestore(
    for item: QuarantineRecoveryWorkflowItemHandle
  ) async -> Result<QuarantineRecoveryPreparedRestore, QuarantineRestorePreparationFailure>

  func authorizeAndRestore(
    _ preparedRestore: QuarantineRecoveryPreparedRestoreHandle,
    statement: QuarantineRestoreConfirmationStatement
  ) async -> Result<
    QuarantineRecoveryWorkflowExecutionResult,
    QuarantineRecoveryWorkflowExecutionFailure
  >

  func beginInitialPurge(
    for item: QuarantineRecoveryWorkflowItemHandle
  ) async -> Result<QuarantineRecoveryPreparedPurge, QuarantinePurgePreparationFailure>

  func beginPurgeRetry(
    for item: QuarantineRecoveryWorkflowPurgeRetryHandle
  ) async -> Result<QuarantineRecoveryPreparedPurge, QuarantinePurgePreparationFailure>

  func authorizeAndPurge(
    _ preparedPurge: QuarantineRecoveryPreparedPurgeHandle,
    statement: QuarantinePurgeConfirmationStatement
  ) async -> Result<
    QuarantineRecoveryWorkflowPurgeExecutionResult,
    QuarantineRecoveryWorkflowPurgeExecutionFailure
  >

  func cancelPendingRestore() async
  func cancelPendingAction() async
}

/// Source-compatible defaults keep restore-only test and preview workflows
/// inert if they have not opted into the irreversible purge boundary.
extension QuarantineRecoveryWorkflowHandling {
  func beginInitialPurge(
    for item: QuarantineRecoveryWorkflowItemHandle
  ) async -> Result<QuarantineRecoveryPreparedPurge, QuarantinePurgePreparationFailure> {
    .failure(.invalidInventoryReference)
  }

  func beginPurgeRetry(
    for item: QuarantineRecoveryWorkflowPurgeRetryHandle
  ) async -> Result<QuarantineRecoveryPreparedPurge, QuarantinePurgePreparationFailure> {
    .failure(.invalidInventoryReference)
  }

  func authorizeAndPurge(
    _ preparedPurge: QuarantineRecoveryPreparedPurgeHandle,
    statement: QuarantinePurgeConfirmationStatement
  ) async -> Result<
    QuarantineRecoveryWorkflowPurgeExecutionResult,
    QuarantineRecoveryWorkflowPurgeExecutionFailure
  > {
    .failure(.execution(.invalidAuthorization))
  }

  func cancelPendingAction() async {
    await cancelPendingRestore()
  }
}

final class QuarantineRecoveryInventoryIdentity: Sendable {}

/// A process-local selector that cannot reveal or be converted to a journal ID.
struct QuarantineRecoveryWorkflowItemHandle: CustomReflectable, Hashable, Sendable {
  private let identity: QuarantineRecoveryInventoryIdentity
  private let ordinal: Int

  init(identity: QuarantineRecoveryInventoryIdentity, ordinal: Int) {
    self.identity = identity
    self.ordinal = ordinal
  }

  static func == (
    left: QuarantineRecoveryWorkflowItemHandle,
    right: QuarantineRecoveryWorkflowItemHandle
  ) -> Bool {
    left.identity === right.identity && left.ordinal == right.ordinal
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(identity))
    hasher.combine(ordinal)
  }

  var customMirror: Mirror {
    Mirror(self, children: ["opaque": true])
  }
}

struct QuarantineRecoveryWorkflowInventoryItem: Equatable, Sendable {
  let handle: QuarantineRecoveryWorkflowItemHandle
  let responsibleTool: String
  let originalName: String
  let readiness: QuarantineInventoryRestoreReadiness
  let purgeReadiness: QuarantineInventoryPurgeReadiness
  let quarantineReceiptWasProducedByRecovery: Bool

  init(
    handle: QuarantineRecoveryWorkflowItemHandle,
    responsibleTool: String,
    originalName: String,
    readiness: QuarantineInventoryRestoreReadiness,
    purgeReadiness: QuarantineInventoryPurgeReadiness? = nil,
    quarantineReceiptWasProducedByRecovery: Bool
  ) {
    self.handle = handle
    self.responsibleTool = responsibleTool
    self.originalName = originalName
    self.readiness = readiness
    self.purgeReadiness =
      purgeReadiness
      ?? QuarantineInventoryPurgeReadiness(
        quarantinedItem: readiness.quarantinedItem
      )
    self.quarantineReceiptWasProducedByRecovery =
      quarantineReceiptWasProducedByRecovery
  }
}

final class QuarantineRecoveryPurgeRetryInventoryIdentity: Sendable {}

/// A process-local selector for a separately confirmed staged purge retry.
struct QuarantineRecoveryWorkflowPurgeRetryHandle: CustomReflectable, Hashable, Sendable {
  private let identity: QuarantineRecoveryPurgeRetryInventoryIdentity
  private let ordinal: Int

  init(identity: QuarantineRecoveryPurgeRetryInventoryIdentity, ordinal: Int) {
    self.identity = identity
    self.ordinal = ordinal
  }

  static func == (
    left: QuarantineRecoveryWorkflowPurgeRetryHandle,
    right: QuarantineRecoveryWorkflowPurgeRetryHandle
  ) -> Bool {
    left.identity === right.identity && left.ordinal == right.ordinal
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(identity))
    hasher.combine(ordinal)
  }

  var customMirror: Mirror {
    Mirror(self, children: ["opaque": true])
  }
}

struct QuarantineRecoveryWorkflowPurgeRetryItem: Equatable, Sendable {
  let handle: QuarantineRecoveryWorkflowPurgeRetryHandle
  let responsibleTool: String
  let originalName: String
}

struct QuarantineRecoveryWorkflowInventory: CustomReflectable, Sendable {
  let items: [QuarantineRecoveryWorkflowInventoryItem]
  let purgeRetries: [QuarantineRecoveryWorkflowPurgeRetryItem]

  init(
    items: [QuarantineRecoveryWorkflowInventoryItem],
    purgeRetries: [QuarantineRecoveryWorkflowPurgeRetryItem] = []
  ) {
    self.items = items
    self.purgeRetries = purgeRetries
  }

  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "itemCount": items.count,
        "purgeRetryCount": purgeRetries.count,
      ]
    )
  }
}

final class QuarantineRecoveryAttemptIdentity: Sendable {}

struct QuarantineRecoveryPreparedRestoreHandle: CustomReflectable, Hashable, Sendable {
  private let identity: QuarantineRecoveryAttemptIdentity

  init(identity: QuarantineRecoveryAttemptIdentity) {
    self.identity = identity
  }

  static func == (
    left: QuarantineRecoveryPreparedRestoreHandle,
    right: QuarantineRecoveryPreparedRestoreHandle
  ) -> Bool {
    left.identity === right.identity
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(identity))
  }

  var customMirror: Mirror {
    Mirror(self, children: ["opaque": true])
  }
}

struct QuarantineRecoveryPreparedRestore: CustomReflectable, Sendable {
  let handle: QuarantineRecoveryPreparedRestoreHandle
  let requiredStatement: QuarantineRestoreConfirmationStatement
  let responsibleTool: String
  let originalName: String

  var customMirror: Mirror {
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

final class QuarantineRecoveryPurgeAttemptIdentity: Sendable {}

struct QuarantineRecoveryPreparedPurgeHandle: CustomReflectable, Hashable, Sendable {
  private let identity: QuarantineRecoveryPurgeAttemptIdentity

  init(identity: QuarantineRecoveryPurgeAttemptIdentity) {
    self.identity = identity
  }

  static func == (
    left: QuarantineRecoveryPreparedPurgeHandle,
    right: QuarantineRecoveryPreparedPurgeHandle
  ) -> Bool {
    left.identity === right.identity
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(identity))
  }

  var customMirror: Mirror {
    Mirror(self, children: ["opaque": true])
  }
}

struct QuarantineRecoveryPreparedPurge: CustomReflectable, Sendable {
  let handle: QuarantineRecoveryPreparedPurgeHandle
  let attemptKind: QuarantinePurgeAttemptKind
  let requiredStatement: QuarantinePurgeConfirmationStatement
  let responsibleTool: String
  let originalName: String

  var customMirror: Mirror {
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

struct QuarantineRecoveryWorkflowExecutionResult: Equatable, Sendable {
  let status: QuarantineRestoreExecutionStatus
  let durability: QuarantineRestoreDurability
  let cancellationWasObservedAfterRename: Bool
  let isDurablyRestored: Bool
  let performedPermanentDeletion: Bool
  let overwroteExistingItem: Bool

  init(
    status: QuarantineRestoreExecutionStatus,
    durability: QuarantineRestoreDurability,
    cancellationWasObservedAfterRename: Bool,
    isDurablyRestored: Bool,
    performedPermanentDeletion: Bool = false,
    overwroteExistingItem: Bool = false
  ) {
    self.status = status
    self.durability = durability
    self.cancellationWasObservedAfterRename = cancellationWasObservedAfterRename
    self.isDurablyRestored = isDurablyRestored
    self.performedPermanentDeletion = performedPermanentDeletion
    self.overwroteExistingItem = overwroteExistingItem
  }

  init(_ outcome: QuarantineRestoreExecutionOutcome) {
    self.init(
      status: outcome.status,
      durability: outcome.durability,
      cancellationWasObservedAfterRename: outcome.cancellationWasObservedAfterRename,
      isDurablyRestored: outcome.isDurablyRestored,
      performedPermanentDeletion: outcome.performedPermanentDeletion,
      overwroteExistingItem: outcome.overwroteExistingItem
    )
  }
}

enum QuarantineRecoveryWorkflowExecutionFailure: Error, Equatable, Sendable {
  case authorization(QuarantineRestoreAuthorizationFailure)
  case execution(QuarantineRestoreExecutionFailure)
}

struct QuarantineRecoveryWorkflowPurgeExecutionResult: Equatable, Sendable {
  let attemptKind: QuarantinePurgeAttemptKind
  let status: QuarantinePurgeExecutionStatus
  let durability: QuarantinePurgeDurability
  let capacityObservationProvenance: QuarantinePurgeCapacityObservationProvenance?
  let observedCapacityChange: QuarantinePurgeCapacityChange
  let observedUnlinkCount: UInt64
  let cancellationWasObserved: Bool
  let isDurablyTerminal: Bool
  let isCrashRecoverable: Bool
  let performedPermanentDeletion: Bool
  let requiresExplicitRetry: Bool

  init(_ outcome: QuarantinePurgeExecutionOutcome) {
    attemptKind = outcome.attemptKind
    status = outcome.status
    durability = outcome.durability
    capacityObservationProvenance = outcome.capacityObservationProvenance
    observedCapacityChange = outcome.observedCapacityChange
    observedUnlinkCount = outcome.observedUnlinkCount
    cancellationWasObserved = outcome.cancellationWasObserved
    isDurablyTerminal = outcome.isDurablyTerminal
    isCrashRecoverable = outcome.isCrashRecoverable
    performedPermanentDeletion = outcome.performedPermanentDeletion
    requiresExplicitRetry = outcome.requiresExplicitRetry
  }

  init(
    attemptKind: QuarantinePurgeAttemptKind,
    status: QuarantinePurgeExecutionStatus,
    durability: QuarantinePurgeDurability,
    capacityObservationProvenance: QuarantinePurgeCapacityObservationProvenance? = nil,
    observedCapacityChange: QuarantinePurgeCapacityChange = .unavailable,
    observedUnlinkCount: UInt64 = 0,
    cancellationWasObserved: Bool = false,
    isDurablyTerminal: Bool,
    isCrashRecoverable: Bool,
    performedPermanentDeletion: Bool,
    requiresExplicitRetry: Bool
  ) {
    self.attemptKind = attemptKind
    self.status = status
    self.durability = durability
    self.capacityObservationProvenance = capacityObservationProvenance
    self.observedCapacityChange = observedCapacityChange
    self.observedUnlinkCount = observedUnlinkCount
    self.cancellationWasObserved = cancellationWasObserved
    self.isDurablyTerminal = isDurablyTerminal
    self.isCrashRecoverable = isCrashRecoverable
    self.performedPermanentDeletion = performedPermanentDeletion
    self.requiresExplicitRetry = requiresExplicitRetry
  }
}

enum QuarantineRecoveryWorkflowPurgeExecutionFailure: Error, Equatable, Sendable {
  case authorization(QuarantinePurgeAuthorizationFailure)
  case execution(QuarantinePurgeExecutionFailure)
}

/// Production adapter. Actor isolation keeps Core's synchronous journal load
/// and preflight work off the main actor while retaining the exact Core
/// inventory snapshot, item references, and authorization session.
actor CoreQuarantineRecoveryWorkflowAdapter: QuarantineRecoveryWorkflowHandling {
  private struct PendingRestore: Sendable {
    let handle: QuarantineRecoveryPreparedRestoreHandle
    let session: QuarantineRestoreAuthorizationSession
  }

  private struct PendingPurge: Sendable {
    let handle: QuarantineRecoveryPreparedPurgeHandle
    let session: QuarantinePurgeAuthorizationSession
  }

  private enum PendingAction: Sendable {
    case restore(PendingRestore)
    case purge(PendingPurge)
  }

  private let workflow: QuarantineInventoryRestoreWorkflow
  private var inventorySession: QuarantineInventorySession?
  private var itemReferences:
    [QuarantineRecoveryWorkflowItemHandle: QuarantineInventoryItemReference] = [:]
  private var purgeRetryReferences:
    [QuarantineRecoveryWorkflowPurgeRetryHandle: QuarantineInventoryPurgeRetryReference] = [:]
  private var pendingAction: PendingAction?
  private var authorizationIsInProgress = false
  private var stateGeneration: UInt64 = 0

  init(workflow: QuarantineInventoryRestoreWorkflow = QuarantineInventoryRestoreWorkflow()) {
    self.workflow = workflow
  }

  func reconcileAndLoadInventory() async
    -> Result<QuarantineRecoveryWorkflowInventory, QuarantineInventoryLoadFailure>
  {
    let operation = advanceStateGeneration()
    let supersededAction = detachPendingAction()
    clearInventory()
    await cancel(supersededAction)
    guard operation == stateGeneration else {
      return .failure(.cancelled)
    }

    switch workflow.reconcileAndLoadInventory() {
    case .success(let session):
      let identity = QuarantineRecoveryInventoryIdentity()
      let items = session.items.enumerated().map { ordinal, item in
        let handle = QuarantineRecoveryWorkflowItemHandle(
          identity: identity,
          ordinal: ordinal
        )
        itemReferences[handle] = item.reference
        return QuarantineRecoveryWorkflowInventoryItem(
          handle: handle,
          responsibleTool: item.responsibleTool,
          originalName: item.originalName,
          readiness: item.readiness,
          purgeReadiness: item.purgeReadiness,
          quarantineReceiptWasProducedByRecovery:
            item.quarantineReceiptWasProducedByRecovery
        )
      }
      let purgeRetryIdentity = QuarantineRecoveryPurgeRetryInventoryIdentity()
      let purgeRetries = session.purgeRetries.enumerated().map { ordinal, item in
        let handle = QuarantineRecoveryWorkflowPurgeRetryHandle(
          identity: purgeRetryIdentity,
          ordinal: ordinal
        )
        purgeRetryReferences[handle] = item.reference
        return QuarantineRecoveryWorkflowPurgeRetryItem(
          handle: handle,
          responsibleTool: item.responsibleTool,
          originalName: item.originalName
        )
      }
      inventorySession = session
      return .success(
        QuarantineRecoveryWorkflowInventory(
          items: items,
          purgeRetries: purgeRetries
        ))

    case .failure(let failure):
      return .failure(failure)
    }
  }

  func beginRestore(
    for item: QuarantineRecoveryWorkflowItemHandle
  ) async -> Result<QuarantineRecoveryPreparedRestore, QuarantineRestorePreparationFailure> {
    let operation = advanceStateGeneration()
    let supersededAction = detachPendingAction()
    await cancel(supersededAction)
    guard operation == stateGeneration else {
      return .failure(.cancelled)
    }

    guard let inventorySession, let reference = itemReferences[item] else {
      return .failure(.invalidInventoryReference)
    }

    switch workflow.beginRestore(from: inventorySession, item: reference) {
    case .success(let session):
      let handle = QuarantineRecoveryPreparedRestoreHandle(
        identity: QuarantineRecoveryAttemptIdentity()
      )
      pendingAction = .restore(PendingRestore(handle: handle, session: session))
      let request = session.confirmationRequest
      return .success(
        QuarantineRecoveryPreparedRestore(
          handle: handle,
          requiredStatement: request.requiredStatement,
          responsibleTool: request.responsibleTool,
          originalName: request.originalName
        )
      )

    case .failure(let failure):
      return .failure(failure)
    }
  }

  func beginInitialPurge(
    for item: QuarantineRecoveryWorkflowItemHandle
  ) async -> Result<QuarantineRecoveryPreparedPurge, QuarantinePurgePreparationFailure> {
    let operation = advanceStateGeneration()
    let supersededAction = detachPendingAction()
    await cancel(supersededAction)
    guard operation == stateGeneration else {
      return .failure(.cancelled)
    }

    guard let inventorySession, let reference = itemReferences[item] else {
      return .failure(.invalidInventoryReference)
    }

    return preparePurge(
      workflow.beginInitialPurge(from: inventorySession, item: reference)
    )
  }

  func beginPurgeRetry(
    for item: QuarantineRecoveryWorkflowPurgeRetryHandle
  ) async -> Result<QuarantineRecoveryPreparedPurge, QuarantinePurgePreparationFailure> {
    let operation = advanceStateGeneration()
    let supersededAction = detachPendingAction()
    await cancel(supersededAction)
    guard operation == stateGeneration else {
      return .failure(.cancelled)
    }

    guard let inventorySession, let reference = purgeRetryReferences[item] else {
      return .failure(.invalidInventoryReference)
    }

    return preparePurge(
      workflow.beginPurgeRetry(from: inventorySession, retry: reference)
    )
  }

  func authorizeAndRestore(
    _ preparedRestore: QuarantineRecoveryPreparedRestoreHandle,
    statement: QuarantineRestoreConfirmationStatement
  ) async -> Result<
    QuarantineRecoveryWorkflowExecutionResult,
    QuarantineRecoveryWorkflowExecutionFailure
  > {
    guard
      case .restore(let pendingRestore)? = pendingAction,
      pendingRestore.handle == preparedRestore,
      !authorizationIsInProgress
    else {
      return .failure(.authorization(.confirmationDoesNotBelongToAttempt))
    }

    let request = pendingRestore.session.confirmationRequest
    guard statement == request.requiredStatement else {
      await cancelPendingRestore()
      return .failure(.authorization(.confirmationStatementMismatch))
    }

    authorizationIsInProgress = true
    let operation = stateGeneration
    let session = pendingRestore.session

    return await withTaskCancellationHandler {
      do {
        try Task.checkCancellation()
        let authorization = try await session.authorize(
          using: QuarantineRestoreUserConfirmation(
            request: request,
            statement: statement
          )
        )
        try Task.checkCancellation()

        guard
          case .restore(let current)? = self.pendingAction,
          current.handle == preparedRestore,
          self.authorizationIsInProgress,
          self.stateGeneration == operation
        else {
          await session.cancel()
          return .failure(.authorization(.cancelled))
        }

        let execution = await workflow.execute(authorization)
        finishAttempt(ifCurrent: preparedRestore)
        return
          execution
          .map(QuarantineRecoveryWorkflowExecutionResult.init)
          .mapError { .execution($0) }
      } catch is CancellationError {
        await session.cancel()
        finishAttempt(ifCurrent: preparedRestore)
        return .failure(.authorization(.cancelled))
      } catch let failure as QuarantineRestoreAuthorizationFailure {
        await session.cancel()
        finishAttempt(ifCurrent: preparedRestore)
        return .failure(.authorization(failure))
      } catch {
        await session.cancel()
        finishAttempt(ifCurrent: preparedRestore)
        return .failure(.authorization(.invalidPreparedEvidence))
      }
    } onCancel: {
      Task {
        await session.cancel()
      }
    }
  }

  func authorizeAndPurge(
    _ preparedPurge: QuarantineRecoveryPreparedPurgeHandle,
    statement: QuarantinePurgeConfirmationStatement
  ) async -> Result<
    QuarantineRecoveryWorkflowPurgeExecutionResult,
    QuarantineRecoveryWorkflowPurgeExecutionFailure
  > {
    guard
      case .purge(let pendingPurge)? = pendingAction,
      pendingPurge.handle == preparedPurge,
      !authorizationIsInProgress
    else {
      return .failure(.authorization(.confirmationDoesNotBelongToAttempt))
    }

    let request = pendingPurge.session.confirmationRequest
    guard statement == request.requiredStatement else {
      await cancelPendingAction()
      return .failure(.authorization(.confirmationStatementMismatch))
    }

    authorizationIsInProgress = true
    let operation = stateGeneration
    let session = pendingPurge.session

    return await withTaskCancellationHandler {
      do {
        try Task.checkCancellation()
        let authorization = try await session.authorize(
          using: QuarantinePurgeUserConfirmation(
            request: request,
            statement: statement
          ))
        try Task.checkCancellation()

        guard
          case .purge(let current)? = self.pendingAction,
          current.handle == preparedPurge,
          self.authorizationIsInProgress,
          self.stateGeneration == operation
        else {
          await session.cancel()
          return .failure(.authorization(.cancelled))
        }

        let execution = await workflow.executePurge(authorization)
        finishAttempt(ifCurrent: preparedPurge)
        return
          execution
          .map(QuarantineRecoveryWorkflowPurgeExecutionResult.init)
          .mapError { .execution($0) }
      } catch is CancellationError {
        await session.cancel()
        finishAttempt(ifCurrent: preparedPurge)
        return .failure(.authorization(.cancelled))
      } catch let failure as QuarantinePurgeAuthorizationFailure {
        await session.cancel()
        finishAttempt(ifCurrent: preparedPurge)
        return .failure(.authorization(failure))
      } catch {
        await session.cancel()
        finishAttempt(ifCurrent: preparedPurge)
        return .failure(.authorization(.invalidPreparedEvidence))
      }
    } onCancel: {
      Task {
        await session.cancel()
      }
    }
  }

  func cancelPendingRestore() async {
    await cancelPendingAction()
  }

  func cancelPendingAction() async {
    advanceStateGeneration()
    let action = detachPendingAction()
    await cancel(action)
  }

  @discardableResult
  private func advanceStateGeneration() -> UInt64 {
    stateGeneration &+= 1
    return stateGeneration
  }

  private func detachPendingAction() -> PendingAction? {
    let action = pendingAction
    pendingAction = nil
    authorizationIsInProgress = false
    return action
  }

  private func cancel(_ action: PendingAction?) async {
    switch action {
    case .restore(let restore):
      await restore.session.cancel()
    case .purge(let purge):
      await purge.session.cancel()
    case nil:
      break
    }
  }

  private func clearInventory() {
    inventorySession = nil
    itemReferences.removeAll(keepingCapacity: true)
    purgeRetryReferences.removeAll(keepingCapacity: true)
  }

  private func preparePurge(
    _ result: Result<QuarantinePurgeAuthorizationSession, QuarantinePurgePreparationFailure>
  ) -> Result<QuarantineRecoveryPreparedPurge, QuarantinePurgePreparationFailure> {
    switch result {
    case .success(let session):
      let handle = QuarantineRecoveryPreparedPurgeHandle(
        identity: QuarantineRecoveryPurgeAttemptIdentity()
      )
      pendingAction = .purge(PendingPurge(handle: handle, session: session))
      let request = session.confirmationRequest
      return .success(
        QuarantineRecoveryPreparedPurge(
          handle: handle,
          attemptKind: request.attemptKind,
          requiredStatement: request.requiredStatement,
          responsibleTool: request.responsibleTool,
          originalName: request.originalName
        ))
    case .failure(let failure):
      return .failure(failure)
    }
  }

  private func finishAttempt(
    ifCurrent handle: QuarantineRecoveryPreparedRestoreHandle
  ) {
    guard case .restore(let restore)? = pendingAction,
      restore.handle == handle
    else {
      return
    }
    pendingAction = nil
    authorizationIsInProgress = false
  }

  private func finishAttempt(
    ifCurrent handle: QuarantineRecoveryPreparedPurgeHandle
  ) {
    guard case .purge(let purge)? = pendingAction,
      purge.handle == handle
    else {
      return
    }
    pendingAction = nil
    authorizationIsInProgress = false
  }
}
