import DevSiftCore
import Foundation
import Observation

enum QuarantineRecoveryInventoryState: Equatable, Sendable {
  case notLoaded
  case loading
  case loaded(QuarantineRecoveryInventoryPresentation)
  case failed(QuarantineRecoveryIssuePresentation)
}

enum QuarantineRecoveryRestoreState: Equatable, Sendable {
  case idle
  case preparing(QuarantineRecoveryRowID)
  case awaitingConfirmation(QuarantineRecoveryConfirmationPresentation)
  case cancellingConfirmation
  case restoring(QuarantineRecoveryRowID)
  case finished(QuarantineRecoveryResultPresentation)
  case failed(QuarantineRecoveryIssuePresentation)

  var operationIsActive: Bool {
    switch self {
    case .preparing, .cancellingConfirmation, .restoring:
      true
    case .idle, .awaitingConfirmation, .finished, .failed:
      false
    }
  }
}

@MainActor
@Observable
final class QuarantineRecoveryViewModel {
  private(set) var inventoryState: QuarantineRecoveryInventoryState = .notLoaded
  private(set) var restoreState: QuarantineRecoveryRestoreState = .idle

  @ObservationIgnored private let workflow: any QuarantineRecoveryWorkflowHandling
  @ObservationIgnored private var itemHandles:
    [QuarantineRecoveryRowID: QuarantineRecoveryWorkflowItemHandle] = [:]
  @ObservationIgnored private var preparedRestore: QuarantineRecoveryPreparedRestore?
  @ObservationIgnored private var operationGeneration: UInt64 = 0
  @ObservationIgnored private var inventoryGeneration: UInt64 = 0
  @ObservationIgnored private var operationTask: Task<Void, Never>?

  init(
    workflow: any QuarantineRecoveryWorkflowHandling =
      CoreQuarantineRecoveryWorkflowAdapter()
  ) {
    self.workflow = workflow
  }

  var isWorking: Bool {
    if case .loading = inventoryState {
      return true
    }
    return restoreState.operationIsActive
  }

  var canStartRestore: Bool {
    guard case .loaded = inventoryState else {
      return false
    }
    return allowsNewRestoreAttempt
  }

  var refreshDiscardsPendingConfirmation: Bool {
    if case .awaitingConfirmation = restoreState {
      return true
    }
    return false
  }

  /// Starts the reconciliation only in response to an explicit user action.
  /// Merely constructing or presenting this model performs no journal access.
  @discardableResult
  func loadInventory() -> Task<Void, Never> {
    let operation = beginOperation()
    inventoryState = .loading
    restoreState = .idle
    preparedRestore = nil
    itemHandles.removeAll(keepingCapacity: true)

    let workflow = workflow
    let task = Task { [weak self] in
      await workflow.cancelPendingRestore()
      guard !Task.isCancelled else {
        return
      }
      let result = await workflow.reconcileAndLoadInventory()
      guard !Task.isCancelled else {
        return
      }
      self?.finishInventoryLoad(result, operation: operation)
    }
    operationTask = task
    return task
  }

  @discardableResult
  func requestRestore(
    for rowID: QuarantineRecoveryRowID
  ) -> Task<Void, Never>? {
    guard
      case .loaded(let inventory) = inventoryState,
      inventory.rows.first(where: { $0.id == rowID })?.canRestore == true,
      let itemHandle = itemHandles[rowID],
      allowsNewRestoreAttempt
    else {
      return nil
    }

    let operation = beginOperation()
    restoreState = .preparing(rowID)
    preparedRestore = nil
    let workflow = workflow
    let task = Task { [weak self] in
      let result = await workflow.beginRestore(for: itemHandle)
      guard !Task.isCancelled else {
        return
      }
      self?.finishRestorePreparation(
        result,
        rowID: rowID,
        operation: operation
      )
    }
    operationTask = task
    return task
  }

  /// Issues the exact Core-requested statement only after the UI supplies all
  /// three independent acknowledgements for the current prepared attempt.
  @discardableResult
  func confirmAndRestore(
    confirmationID: QuarantineRecoveryConfirmationID,
    exactStatementWasConfirmed: Bool,
    npmWasStopped: Bool,
    postQuarantineChangesWereAccepted: Bool
  ) -> Task<Void, Never>? {
    guard
      exactStatementWasConfirmed,
      npmWasStopped,
      postQuarantineChangesWereAccepted,
      case .awaitingConfirmation(let confirmation) = restoreState,
      confirmation.id == confirmationID,
      let preparedRestore,
      preparedRestore.requiredStatement == confirmation.requiredStatement
    else {
      return nil
    }

    let operation = beginOperation()
    restoreState = .restoring(confirmation.rowID)
    let workflow = workflow
    let task = Task { [weak self] in
      let execution = await withTaskCancellationHandler {
        await workflow.authorizeAndRestore(
          preparedRestore.handle,
          statement: preparedRestore.requiredStatement
        )
      } onCancel: {
        Task {
          await workflow.cancelPendingRestore()
        }
      }
      guard !Task.isCancelled, self?.operationGeneration == operation else {
        return
      }

      self?.preparedRestore = nil
      switch execution {
      case .success(let result):
        self?.restoreState = .finished(
          QuarantineRecoveryResultPresentation(result: result)
        )
      case .failure(let failure):
        self?.restoreState = .failed(
          QuarantineRecoveryIssuePresentation(workflowFailure: failure)
        )
      }

      // Every attempted execution is followed by a fresh reconciliation. The
      // bounded result remains visible even when this refresh itself fails.
      self?.inventoryState = .loading
      let refreshedInventory = await workflow.reconcileAndLoadInventory()
      guard !Task.isCancelled else {
        return
      }
      self?.finishInventoryLoad(
        refreshedInventory,
        operation: operation,
        preserveRestoreState: true
      )
    }
    operationTask = task
    return task
  }

  @discardableResult
  func cancelRestoreConfirmation(
    _ confirmationID: QuarantineRecoveryConfirmationID
  ) -> Task<Void, Never>? {
    guard
      case .awaitingConfirmation(let confirmation) = restoreState,
      confirmation.id == confirmationID
    else {
      return nil
    }
    let operation = beginOperation()
    preparedRestore = nil
    restoreState = .cancellingConfirmation
    let workflow = workflow
    let task = Task { [weak self] in
      await workflow.cancelPendingRestore()
      guard !Task.isCancelled, self?.operationGeneration == operation else {
        return
      }
      self?.restoreState = .idle
      self?.operationTask = nil
    }
    operationTask = task
    return task
  }

  func dismissRestoreStatus() {
    guard case .finished = restoreState else {
      if case .failed = restoreState {
        restoreState = .idle
      }
      return
    }
    restoreState = .idle
  }

  func stopForDismissal() {
    invalidateOperation()
    inventoryState = .notLoaded
    restoreState = .idle
    preparedRestore = nil
    itemHandles.removeAll(keepingCapacity: false)
    let workflow = workflow
    Task {
      await workflow.cancelPendingRestore()
    }
  }

  private var allowsNewRestoreAttempt: Bool {
    switch restoreState {
    case .idle, .finished, .failed:
      true
    case .preparing, .awaitingConfirmation, .cancellingConfirmation, .restoring:
      false
    }
  }

  private func beginOperation() -> UInt64 {
    invalidateOperation()
    return operationGeneration
  }

  private func invalidateOperation() {
    operationGeneration &+= 1
    operationTask?.cancel()
    operationTask = nil
  }

  private func finishInventoryLoad(
    _ result: Result<QuarantineRecoveryWorkflowInventory, QuarantineInventoryLoadFailure>,
    operation: UInt64,
    preserveRestoreState: Bool = false
  ) {
    guard operationGeneration == operation else {
      return
    }

    switch result {
    case .success(let inventory):
      inventoryGeneration &+= 1
      let presentation = QuarantineRecoveryInventoryPresentation.prepare(
        inventory: inventory,
        generation: inventoryGeneration
      )
      itemHandles = Dictionary(
        uniqueKeysWithValues: zip(presentation.rows, inventory.items).map { row, item in
          (row.id, item.handle)
        }
      )
      inventoryState = .loaded(presentation)

    case .failure(let failure):
      itemHandles.removeAll(keepingCapacity: true)
      inventoryState = .failed(
        QuarantineRecoveryIssuePresentation(loadFailure: failure)
      )
    }

    if !preserveRestoreState {
      restoreState = .idle
    }
    operationTask = nil
  }

  private func finishRestorePreparation(
    _ result: Result<QuarantineRecoveryPreparedRestore, QuarantineRestorePreparationFailure>,
    rowID: QuarantineRecoveryRowID,
    operation: UInt64
  ) {
    guard operationGeneration == operation else {
      return
    }

    switch result {
    case .success(let preparedRestore):
      self.preparedRestore = preparedRestore
      restoreState = .awaitingConfirmation(
        QuarantineRecoveryConfirmationPresentation(
          rowID: rowID,
          confirmationID: QuarantineRecoveryConfirmationID(
            identity: QuarantineRecoveryConfirmationIdentity()
          ),
          preparedRestore: preparedRestore
        )
      )
    case .failure(let failure):
      preparedRestore = nil
      restoreState = .failed(
        QuarantineRecoveryIssuePresentation(preparationFailure: failure)
      )
    }
    operationTask = nil
  }
}
