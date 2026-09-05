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

  func cancelPendingRestore() async
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
  let quarantineReceiptWasProducedByRecovery: Bool
}

struct QuarantineRecoveryWorkflowInventory: CustomReflectable, Sendable {
  let items: [QuarantineRecoveryWorkflowInventoryItem]

  var customMirror: Mirror {
    Mirror(self, children: ["itemCount": items.count])
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

/// Production adapter. Actor isolation keeps Core's synchronous journal load
/// and preflight work off the main actor while retaining the exact Core
/// inventory snapshot, item references, and authorization session.
actor CoreQuarantineRecoveryWorkflowAdapter: QuarantineRecoveryWorkflowHandling {
  private struct PendingRestore: Sendable {
    let handle: QuarantineRecoveryPreparedRestoreHandle
    let session: QuarantineRestoreAuthorizationSession
  }

  private let workflow: QuarantineInventoryRestoreWorkflow
  private var inventorySession: QuarantineInventorySession?
  private var itemReferences:
    [QuarantineRecoveryWorkflowItemHandle: QuarantineInventoryItemReference] = [:]
  private var pendingRestore: PendingRestore?
  private var authorizingHandle: QuarantineRecoveryPreparedRestoreHandle?
  private var stateGeneration: UInt64 = 0

  init(workflow: QuarantineInventoryRestoreWorkflow = QuarantineInventoryRestoreWorkflow()) {
    self.workflow = workflow
  }

  func reconcileAndLoadInventory() async
    -> Result<QuarantineRecoveryWorkflowInventory, QuarantineInventoryLoadFailure>
  {
    let operation = advanceStateGeneration()
    let supersededSession = detachPendingRestore()
    clearInventory()
    await supersededSession?.cancel()
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
          quarantineReceiptWasProducedByRecovery:
            item.quarantineReceiptWasProducedByRecovery
        )
      }
      inventorySession = session
      return .success(QuarantineRecoveryWorkflowInventory(items: items))

    case .failure(let failure):
      return .failure(failure)
    }
  }

  func beginRestore(
    for item: QuarantineRecoveryWorkflowItemHandle
  ) async -> Result<QuarantineRecoveryPreparedRestore, QuarantineRestorePreparationFailure> {
    let operation = advanceStateGeneration()
    let supersededSession = detachPendingRestore()
    await supersededSession?.cancel()
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
      pendingRestore = PendingRestore(handle: handle, session: session)
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

  func authorizeAndRestore(
    _ preparedRestore: QuarantineRecoveryPreparedRestoreHandle,
    statement: QuarantineRestoreConfirmationStatement
  ) async -> Result<
    QuarantineRecoveryWorkflowExecutionResult,
    QuarantineRecoveryWorkflowExecutionFailure
  > {
    guard
      let pendingRestore,
      pendingRestore.handle == preparedRestore,
      authorizingHandle == nil
    else {
      return .failure(.authorization(.confirmationDoesNotBelongToAttempt))
    }

    let request = pendingRestore.session.confirmationRequest
    guard statement == request.requiredStatement else {
      await cancelPendingRestore()
      return .failure(.authorization(.confirmationStatementMismatch))
    }

    authorizingHandle = preparedRestore
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
          self.pendingRestore?.handle == preparedRestore,
          self.authorizingHandle == preparedRestore,
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

  func cancelPendingRestore() async {
    advanceStateGeneration()
    let session = detachPendingRestore()
    await session?.cancel()
  }

  @discardableResult
  private func advanceStateGeneration() -> UInt64 {
    stateGeneration &+= 1
    return stateGeneration
  }

  private func detachPendingRestore() -> QuarantineRestoreAuthorizationSession? {
    let session = pendingRestore?.session
    pendingRestore = nil
    authorizingHandle = nil
    return session
  }

  private func clearInventory() {
    inventorySession = nil
    itemReferences.removeAll(keepingCapacity: true)
  }

  private func finishAttempt(
    ifCurrent handle: QuarantineRecoveryPreparedRestoreHandle
  ) {
    guard pendingRestore?.handle == handle else {
      return
    }
    pendingRestore = nil
    authorizingHandle = nil
  }
}
