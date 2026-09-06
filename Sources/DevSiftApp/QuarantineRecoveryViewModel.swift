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

enum QuarantineRecoveryPurgeState: Equatable, Sendable {
  case idle
  case preparing(QuarantineRecoveryPurgeTarget)
  case awaitingConfirmation(QuarantineRecoveryPurgeConfirmationPresentation)
  case cancellingConfirmation
  case purging(QuarantineRecoveryPurgeTarget)
  case finished(QuarantineRecoveryPurgeResultPresentation)
  case failed(QuarantineRecoveryIssuePresentation)

  var operationIsActive: Bool {
    switch self {
    case .preparing, .cancellingConfirmation, .purging:
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
  private(set) var purgeState: QuarantineRecoveryPurgeState = .idle

  @ObservationIgnored private let workflow: any QuarantineRecoveryWorkflowHandling
  @ObservationIgnored private var itemHandles:
    [QuarantineRecoveryRowID: QuarantineRecoveryWorkflowItemHandle] = [:]
  @ObservationIgnored private var purgeRetryHandles:
    [QuarantineRecoveryPurgeRetryRowID: QuarantineRecoveryWorkflowPurgeRetryHandle] = [:]
  @ObservationIgnored private var preparedRestore: QuarantineRecoveryPreparedRestore?
  @ObservationIgnored private var preparedPurge: QuarantineRecoveryPreparedPurge?
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
    return restoreState.operationIsActive || purgeState.operationIsActive
  }

  var canStartRestore: Bool {
    guard case .loaded = inventoryState else {
      return false
    }
    return allowsNewAction
  }

  var canStartInitialPurge: Bool {
    guard case .loaded = inventoryState else {
      return false
    }
    return allowsNewAction
  }

  var canStartPurgeRetry: Bool {
    guard case .loaded = inventoryState else {
      return false
    }
    return allowsNewAction
  }

  var refreshDiscardsPendingConfirmation: Bool {
    if case .awaitingConfirmation = restoreState {
      return true
    }
    if case .awaitingConfirmation = purgeState {
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
    purgeState = .idle
    preparedRestore = nil
    preparedPurge = nil
    itemHandles.removeAll(keepingCapacity: true)
    purgeRetryHandles.removeAll(keepingCapacity: true)

    let workflow = workflow
    let task = Task { [weak self] in
      await workflow.cancelPendingAction()
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
      allowsNewAction
    else {
      return nil
    }

    let operation = beginOperation()
    purgeState = .idle
    restoreState = .preparing(rowID)
    preparedRestore = nil
    preparedPurge = nil
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

  @discardableResult
  func requestInitialPurge(
    for rowID: QuarantineRecoveryRowID
  ) -> Task<Void, Never>? {
    guard
      case .loaded(let inventory) = inventoryState,
      inventory.rows.first(where: { $0.id == rowID })?.canPurge == true,
      let itemHandle = itemHandles[rowID],
      allowsNewAction
    else {
      return nil
    }

    let target = QuarantineRecoveryPurgeTarget.initial(rowID)
    let operation = beginOperation()
    restoreState = .idle
    purgeState = .preparing(target)
    preparedRestore = nil
    preparedPurge = nil
    let workflow = workflow
    let task = Task { [weak self] in
      let result = await workflow.beginInitialPurge(for: itemHandle)
      guard !Task.isCancelled else {
        return
      }
      self?.finishPurgePreparation(
        result,
        target: target,
        operation: operation
      )
    }
    operationTask = task
    return task
  }

  @discardableResult
  func requestPurgeRetry(
    for rowID: QuarantineRecoveryPurgeRetryRowID
  ) -> Task<Void, Never>? {
    guard
      case .loaded(let inventory) = inventoryState,
      inventory.purgeRetryRows.first(where: { $0.id == rowID })?.canRetry == true,
      let retryHandle = purgeRetryHandles[rowID],
      allowsNewAction
    else {
      return nil
    }

    let target = QuarantineRecoveryPurgeTarget.explicitRetry(rowID)
    let operation = beginOperation()
    restoreState = .idle
    purgeState = .preparing(target)
    preparedRestore = nil
    preparedPurge = nil
    let workflow = workflow
    let task = Task { [weak self] in
      let result = await workflow.beginPurgeRetry(for: retryHandle)
      guard !Task.isCancelled else {
        return
      }
      self?.finishPurgePreparation(
        result,
        target: target,
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
    purgeState = .idle
    restoreState = .restoring(confirmation.rowID)
    let workflow = workflow
    let task = Task { [weak self] in
      let execution = await workflow.authorizeAndRestore(
        preparedRestore.handle,
        statement: preparedRestore.requiredStatement
      )
      if self?.operationGeneration == operation {
        self?.inventoryState = .loading
      }
      let refreshedInventory = await Self.reconcileAfterExecution(using: workflow)
      guard self?.operationGeneration == operation else { return }

      self?.preparedRestore = nil
      self?.finishInventoryLoad(
        refreshedInventory,
        operation: operation,
        preserveRestoreState: true,
        preservePurgeState: true
      )
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
    }
    operationTask = task
    return task
  }

  /// The exact statement is itself the permanent-deletion acknowledgement.
  /// The remaining three booleans independently cover the other irreversible
  /// risks represented in Core's attempt-bound statement.
  @discardableResult
  func confirmAndPurge(
    confirmationID: QuarantineRecoveryPurgeConfirmationID,
    exactPermanentDeletionStatementWasConfirmed: Bool,
    restoreCutoffAndPartialDeletionWereAccepted: Bool,
    workWasStoppedAndActivityRisksWereAccepted: Bool,
    capacityAndSecureEraseLimitsWereAccepted: Bool
  ) -> Task<Void, Never>? {
    guard
      exactPermanentDeletionStatementWasConfirmed,
      restoreCutoffAndPartialDeletionWereAccepted,
      workWasStoppedAndActivityRisksWereAccepted,
      capacityAndSecureEraseLimitsWereAccepted,
      case .awaitingConfirmation(let confirmation) = purgeState,
      confirmation.id == confirmationID,
      let preparedPurge,
      preparedPurge.attemptKind == confirmation.attemptKind,
      preparedPurge.requiredStatement == confirmation.requiredStatement
    else {
      return nil
    }

    let operation = beginOperation()
    restoreState = .idle
    purgeState = .purging(confirmation.target)
    let workflow = workflow
    let task = Task { [weak self] in
      let execution = await workflow.authorizeAndPurge(
        preparedPurge.handle,
        statement: preparedPurge.requiredStatement
      )
      if self?.operationGeneration == operation {
        self?.inventoryState = .loading
      }
      let refreshedInventory = await Self.reconcileAfterExecution(using: workflow)
      guard self?.operationGeneration == operation else { return }

      self?.preparedPurge = nil
      self?.finishInventoryLoad(
        refreshedInventory,
        operation: operation,
        preserveRestoreState: true,
        preservePurgeState: true
      )
      switch execution {
      case .success(let result):
        self?.purgeState = .finished(
          QuarantineRecoveryPurgeResultPresentation(result: result)
        )
      case .failure(let failure):
        self?.purgeState = .failed(
          QuarantineRecoveryIssuePresentation(purgeWorkflowFailure: failure)
        )
      }
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
      await workflow.cancelPendingAction()
      guard !Task.isCancelled, self?.operationGeneration == operation else {
        return
      }
      self?.restoreState = .idle
      self?.operationTask = nil
    }
    operationTask = task
    return task
  }

  @discardableResult
  func cancelPurgeConfirmation(
    _ confirmationID: QuarantineRecoveryPurgeConfirmationID
  ) -> Task<Void, Never>? {
    guard
      case .awaitingConfirmation(let confirmation) = purgeState,
      confirmation.id == confirmationID
    else {
      return nil
    }
    let operation = beginOperation()
    preparedPurge = nil
    purgeState = .cancellingConfirmation
    let workflow = workflow
    let task = Task { [weak self] in
      await workflow.cancelPendingAction()
      guard !Task.isCancelled, self?.operationGeneration == operation else {
        return
      }
      self?.purgeState = .idle
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

  func dismissPurgeStatus() {
    guard case .finished = purgeState else {
      if case .failed = purgeState {
        purgeState = .idle
      }
      return
    }
    purgeState = .idle
  }

  func stopForDismissal() {
    invalidateOperation()
    inventoryState = .notLoaded
    restoreState = .idle
    purgeState = .idle
    preparedRestore = nil
    preparedPurge = nil
    itemHandles.removeAll(keepingCapacity: false)
    purgeRetryHandles.removeAll(keepingCapacity: false)
    let workflow = workflow
    Task {
      await workflow.cancelPendingAction()
    }
  }

  private var allowsNewAction: Bool {
    let restoreAllowsAction: Bool
    switch restoreState {
    case .idle, .finished, .failed:
      restoreAllowsAction = true
    case .preparing, .awaitingConfirmation, .cancellingConfirmation, .restoring:
      restoreAllowsAction = false
    }
    guard restoreAllowsAction else { return false }

    switch purgeState {
    case .idle, .finished, .failed:
      return true
    case .preparing, .awaitingConfirmation, .cancellingConfirmation, .purging:
      return false
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
    preserveRestoreState: Bool = false,
    preservePurgeState: Bool = false
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
      purgeRetryHandles = Dictionary(
        uniqueKeysWithValues: zip(presentation.purgeRetryRows, inventory.purgeRetries).map {
          row, item in
          (row.id, item.handle)
        }
      )
      inventoryState = .loaded(presentation)

    case .failure(let failure):
      itemHandles.removeAll(keepingCapacity: true)
      purgeRetryHandles.removeAll(keepingCapacity: true)
      inventoryState = .failed(
        QuarantineRecoveryIssuePresentation(loadFailure: failure)
      )
    }

    if !preserveRestoreState {
      restoreState = .idle
    }
    if !preservePurgeState {
      purgeState = .idle
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

  private func finishPurgePreparation(
    _ result: Result<QuarantineRecoveryPreparedPurge, QuarantinePurgePreparationFailure>,
    target: QuarantineRecoveryPurgeTarget,
    operation: UInt64
  ) {
    guard operationGeneration == operation else {
      return
    }

    switch result {
    case .success(let preparedPurge):
      let targetMatchesAttempt: Bool
      switch (target, preparedPurge.attemptKind) {
      case (.initial, .initial), (.explicitRetry, .explicitRetry):
        targetMatchesAttempt = true
      default:
        targetMatchesAttempt = false
      }
      guard targetMatchesAttempt else {
        self.preparedPurge = nil
        purgeState = .failed(
          QuarantineRecoveryIssuePresentation(
            purgePreparationFailure: .authorization(.invalidPreparedEvidence)
          ))
        let workflow = workflow
        Task {
          await workflow.cancelPendingAction()
        }
        operationTask = nil
        return
      }

      self.preparedPurge = preparedPurge
      purgeState = .awaitingConfirmation(
        QuarantineRecoveryPurgeConfirmationPresentation(
          target: target,
          confirmationID: QuarantineRecoveryPurgeConfirmationID(
            identity: QuarantineRecoveryPurgeConfirmationIdentity()
          ),
          preparedPurge: preparedPurge
        ))
    case .failure(let failure):
      preparedPurge = nil
      purgeState = .failed(
        QuarantineRecoveryIssuePresentation(purgePreparationFailure: failure)
      )
    }
    operationTask = nil
  }

  nonisolated private static func reconcileAfterExecution(
    using workflow: any QuarantineRecoveryWorkflowHandling
  ) async -> Result<QuarantineRecoveryWorkflowInventory, QuarantineInventoryLoadFailure> {
    await Task.detached {
      await workflow.reconcileAndLoadInventory()
    }.value
  }
}
