import DevSiftCore
import Foundation
import Testing

@testable import DevSiftApp
@testable import DevSiftCore

@MainActor
@Suite("Quarantine recovery view model")
struct QuarantineRecoveryViewModelTests {
  @Test("Constructing the recovery screen performs no implicit reconciliation")
  func loadIsExplicit() async {
    let workflow = ScriptedRecoveryWorkflow(
      inventories: [.success(recoveryInventory())]
    )
    let viewModel = QuarantineRecoveryViewModel(workflow: workflow)

    #expect(viewModel.inventoryState == .notLoaded)
    #expect(await workflow.loadCount == 0)

    await viewModel.loadInventory().value

    #expect(await workflow.loadCount == 1)
    guard case .loaded(let inventory) = viewModel.inventoryState else {
      Issue.record("Expected a loaded inventory")
      return
    }
    #expect(inventory.rows.count == 1)
    #expect(inventory.rows[0].canRestore)
    #expect(viewModel.canStartRestore)
  }

  @Test("A blocked readiness row never reaches restore preparation")
  func blockedRowDoesNotPrepare() async {
    let workflow = ScriptedRecoveryWorkflow(
      inventories: [
        .success(
          recoveryInventory(
            readiness: QuarantineInventoryRestoreReadiness(
              originalSource: .otherObjectPresent,
              quarantinedItem: .available
            )
          )
        )
      ]
    )
    let viewModel = QuarantineRecoveryViewModel(workflow: workflow)
    await viewModel.loadInventory().value
    guard case .loaded(let inventory) = viewModel.inventoryState else {
      Issue.record("Expected a loaded inventory")
      return
    }

    #expect(viewModel.requestRestore(for: inventory.rows[0].id) == nil)
    #expect(await workflow.prepareCount == 0)
  }

  @Test("Exact independent acknowledgements authorize once and force a refresh")
  func confirmationAndRefresh() async {
    let prepared = recoveryPreparedRestore()
    let workflow = ScriptedRecoveryWorkflow(
      inventories: [
        .success(recoveryInventory()),
        .success(QuarantineRecoveryWorkflowInventory(items: [])),
      ],
      preparation: .success(prepared),
      execution: .success(durableRestoreResult())
    )
    let viewModel = QuarantineRecoveryViewModel(workflow: workflow)
    await viewModel.loadInventory().value
    guard case .loaded(let inventory) = viewModel.inventoryState else {
      Issue.record("Expected a loaded inventory")
      return
    }

    let rowID = inventory.rows[0].id
    guard let preparationTask = viewModel.requestRestore(for: rowID) else {
      Issue.record("Expected restore preparation to start")
      return
    }
    await preparationTask.value
    guard case .awaitingConfirmation(let confirmation) = viewModel.restoreState else {
      Issue.record("Expected an exact confirmation request")
      return
    }

    #expect(!viewModel.canStartRestore)
    #expect(viewModel.refreshDiscardsPendingConfirmation)
    #expect(
      confirmation.requiredStatementIdentifier
        == "restore-current-quarantined-contents-to-original-cacache-without-overwrite-with-npm-stopped-and-post-quarantine-changes-accepted"
    )
    #expect(
      viewModel.confirmAndRestore(
        confirmationID: confirmation.id,
        exactStatementWasConfirmed: false,
        npmWasStopped: true,
        postQuarantineChangesWereAccepted: true
      ) == nil
    )
    #expect(
      viewModel.confirmAndRestore(
        confirmationID: confirmation.id,
        exactStatementWasConfirmed: true,
        npmWasStopped: false,
        postQuarantineChangesWereAccepted: true
      ) == nil
    )
    #expect(
      viewModel.confirmAndRestore(
        confirmationID: confirmation.id,
        exactStatementWasConfirmed: true,
        npmWasStopped: true,
        postQuarantineChangesWereAccepted: false
      ) == nil
    )
    #expect(await workflow.executionCount == 0)

    guard
      let restoreTask = viewModel.confirmAndRestore(
        confirmationID: confirmation.id,
        exactStatementWasConfirmed: true,
        npmWasStopped: true,
        postQuarantineChangesWereAccepted: true
      )
    else {
      Issue.record("Expected the fully acknowledged restore to start")
      return
    }
    await restoreTask.value

    #expect(await workflow.executionCount == 1)
    #expect(await workflow.loadCount == 2)
    #expect(
      await workflow.lastStatement
        == .restoreCurrentQuarantinedContentsWithoutOverwriteWithNPMStoppedAndChangesAccepted
    )
    guard case .finished(let result) = viewModel.restoreState else {
      Issue.record("Expected the bounded restore result to remain visible")
      return
    }
    #expect(result.tone == .success)
    guard case .loaded(let refreshed) = viewModel.inventoryState else {
      Issue.record("Expected a refreshed inventory")
      return
    }
    #expect(refreshed.isEmpty)
  }

  @Test("A newer load suppresses an older completion")
  func staleLoadIsSuppressed() async throws {
    let workflow = GatedRecoveryWorkflow()
    let viewModel = QuarantineRecoveryViewModel(workflow: workflow)

    let firstTask = viewModel.loadInventory()
    try #require(await workflow.waitUntilLoadCount(1))
    let secondTask = viewModel.loadInventory()
    try #require(await workflow.waitUntilLoadCount(2))

    await workflow.resolveLoad(1, with: .success(recoveryInventory()))
    await workflow.resolveLoad(
      2,
      with: .success(QuarantineRecoveryWorkflowInventory(items: []))
    )
    await firstTask.value
    await secondTask.value

    guard case .loaded(let inventory) = viewModel.inventoryState else {
      Issue.record("Expected the second inventory")
      return
    }
    #expect(inventory.isEmpty)
  }

  @Test("Dismissing recovery cancels and suppresses an outstanding load")
  func dismissalSuppressesCompletion() async throws {
    let workflow = GatedRecoveryWorkflow()
    let viewModel = QuarantineRecoveryViewModel(workflow: workflow)

    let task = viewModel.loadInventory()
    try #require(await workflow.waitUntilLoadCount(1))
    viewModel.stopForDismissal()
    await workflow.resolveLoad(1, with: .success(recoveryInventory()))
    await task.value

    #expect(viewModel.inventoryState == .notLoaded)
    #expect(viewModel.restoreState == .idle)
    #expect(await workflow.waitUntilCancellationCount(1))
  }

  @Test("Refreshing a confirmation discards its prepared authority")
  func refreshDiscardsConfirmation() async {
    let workflow = ScriptedRecoveryWorkflow(
      inventories: [
        .success(recoveryInventory()),
        .success(QuarantineRecoveryWorkflowInventory(items: [])),
      ],
      preparation: .success(recoveryPreparedRestore())
    )
    let viewModel = QuarantineRecoveryViewModel(workflow: workflow)
    await viewModel.loadInventory().value
    guard case .loaded(let inventory) = viewModel.inventoryState,
      let task = viewModel.requestRestore(for: inventory.rows[0].id)
    else {
      Issue.record("Expected a restorable row")
      return
    }
    await task.value
    guard case .awaitingConfirmation = viewModel.restoreState else {
      Issue.record("Expected a pending confirmation")
      return
    }
    let cancellationCountBeforeRefresh = await workflow.cancellationCount

    await viewModel.loadInventory().value

    #expect(await workflow.cancellationCount > cancellationCountBeforeRefresh)
    #expect(viewModel.restoreState == .idle)
    guard case .loaded(let refreshed) = viewModel.inventoryState else {
      Issue.record("Expected a refreshed inventory")
      return
    }
    #expect(refreshed.isEmpty)
  }

  @Test("An in-flight restore rejects duplicate confirmation and cannot publish after dismissal")
  func inFlightRestoreIsSingleAndLateSafe() async throws {
    let workflow = GatedRestoreWorkflow()
    let viewModel = QuarantineRecoveryViewModel(workflow: workflow)
    await viewModel.loadInventory().value
    guard case .loaded(let inventory) = viewModel.inventoryState,
      let preparationTask = viewModel.requestRestore(for: inventory.rows[0].id)
    else {
      Issue.record("Expected a restorable row")
      return
    }
    await preparationTask.value
    guard case .awaitingConfirmation(let confirmation) = viewModel.restoreState else {
      Issue.record("Expected a confirmation")
      return
    }
    guard
      let restoreTask = viewModel.confirmAndRestore(
        confirmationID: confirmation.id,
        exactStatementWasConfirmed: true,
        npmWasStopped: true,
        postQuarantineChangesWereAccepted: true
      )
    else {
      Issue.record("Expected restore execution to start")
      return
    }
    try #require(await workflow.waitUntilExecutionCount(1))

    #expect(
      viewModel.confirmAndRestore(
        confirmationID: confirmation.id,
        exactStatementWasConfirmed: true,
        npmWasStopped: true,
        postQuarantineChangesWereAccepted: true
      ) == nil
    )
    viewModel.stopForDismissal()
    await workflow.resolveExecution(with: .success(durableRestoreResult()))
    await restoreTask.value

    #expect(await workflow.executionCount == 1)
    #expect(viewModel.inventoryState == .notLoaded)
    #expect(viewModel.restoreState == .idle)
    #expect(await workflow.waitUntilCancellationCount(1))
  }

  @Test("A retained confirmation action cannot authorize a later attempt")
  func confirmationIsAttemptBound() async {
    let workflow = ScriptedRecoveryWorkflow(
      inventories: [
        .success(recoveryInventory()),
        .success(QuarantineRecoveryWorkflowInventory(items: [])),
      ],
      preparation: .success(recoveryPreparedRestore()),
      execution: .success(durableRestoreResult())
    )
    let viewModel = QuarantineRecoveryViewModel(workflow: workflow)
    await viewModel.loadInventory().value
    guard case .loaded(let inventory) = viewModel.inventoryState,
      let firstPreparation = viewModel.requestRestore(for: inventory.rows[0].id)
    else {
      Issue.record("Expected a restorable row")
      return
    }
    await firstPreparation.value
    guard case .awaitingConfirmation(let firstConfirmation) = viewModel.restoreState,
      let cancellation = viewModel.cancelRestoreConfirmation(firstConfirmation.id)
    else {
      Issue.record("Expected the first confirmation")
      return
    }
    await cancellation.value

    guard
      let secondPreparation = viewModel.requestRestore(for: inventory.rows[0].id)
    else {
      Issue.record("Expected a second restore preparation")
      return
    }
    await secondPreparation.value
    guard case .awaitingConfirmation(let secondConfirmation) = viewModel.restoreState else {
      Issue.record("Expected the second confirmation")
      return
    }
    #expect(firstConfirmation.id != secondConfirmation.id)

    #expect(
      viewModel.confirmAndRestore(
        confirmationID: firstConfirmation.id,
        exactStatementWasConfirmed: true,
        npmWasStopped: true,
        postQuarantineChangesWereAccepted: true
      ) == nil
    )
    #expect(await workflow.executionCount == 0)

    guard
      let restoreTask = viewModel.confirmAndRestore(
        confirmationID: secondConfirmation.id,
        exactStatementWasConfirmed: true,
        npmWasStopped: true,
        postQuarantineChangesWereAccepted: true
      )
    else {
      Issue.record("Expected the current confirmation to execute")
      return
    }
    await restoreTask.value
    #expect(await workflow.executionCount == 1)
  }
}

private actor ScriptedRecoveryWorkflow: QuarantineRecoveryWorkflowHandling {
  private var inventories:
    [Result<QuarantineRecoveryWorkflowInventory, QuarantineInventoryLoadFailure>]
  private let preparation:
    Result<
      QuarantineRecoveryPreparedRestore,
      QuarantineRestorePreparationFailure
    >
  private let execution:
    Result<
      QuarantineRecoveryWorkflowExecutionResult,
      QuarantineRecoveryWorkflowExecutionFailure
    >
  private(set) var loadCount = 0
  private(set) var prepareCount = 0
  private(set) var executionCount = 0
  private(set) var cancellationCount = 0
  private(set) var lastStatement: QuarantineRestoreConfirmationStatement?

  init(
    inventories: [Result<QuarantineRecoveryWorkflowInventory, QuarantineInventoryLoadFailure>],
    preparation: Result<
      QuarantineRecoveryPreparedRestore,
      QuarantineRestorePreparationFailure
    > = .failure(.inventoryChanged),
    execution: Result<
      QuarantineRecoveryWorkflowExecutionResult,
      QuarantineRecoveryWorkflowExecutionFailure
    > = .failure(.execution(.cancelled))
  ) {
    self.inventories = inventories
    self.preparation = preparation
    self.execution = execution
  }

  func reconcileAndLoadInventory()
    -> Result<QuarantineRecoveryWorkflowInventory, QuarantineInventoryLoadFailure>
  {
    loadCount += 1
    guard !inventories.isEmpty else {
      return .success(QuarantineRecoveryWorkflowInventory(items: []))
    }
    return inventories.removeFirst()
  }

  func beginRestore(
    for item: QuarantineRecoveryWorkflowItemHandle
  ) -> Result<QuarantineRecoveryPreparedRestore, QuarantineRestorePreparationFailure> {
    prepareCount += 1
    return preparation
  }

  func authorizeAndRestore(
    _ preparedRestore: QuarantineRecoveryPreparedRestoreHandle,
    statement: QuarantineRestoreConfirmationStatement
  ) -> Result<
    QuarantineRecoveryWorkflowExecutionResult,
    QuarantineRecoveryWorkflowExecutionFailure
  > {
    executionCount += 1
    lastStatement = statement
    return execution
  }

  func cancelPendingRestore() {
    cancellationCount += 1
  }
}

private actor GatedRecoveryWorkflow: QuarantineRecoveryWorkflowHandling {
  private var loadContinuations:
    [Int: CheckedContinuation<
      Result<QuarantineRecoveryWorkflowInventory, QuarantineInventoryLoadFailure>,
      Never
    >] = [:]
  private(set) var loadCount = 0
  private(set) var cancellationCount = 0

  func reconcileAndLoadInventory() async
    -> Result<QuarantineRecoveryWorkflowInventory, QuarantineInventoryLoadFailure>
  {
    loadCount += 1
    let occurrence = loadCount
    return await withCheckedContinuation { continuation in
      loadContinuations[occurrence] = continuation
    }
  }

  func beginRestore(
    for item: QuarantineRecoveryWorkflowItemHandle
  ) -> Result<QuarantineRecoveryPreparedRestore, QuarantineRestorePreparationFailure> {
    .failure(.inventoryChanged)
  }

  func authorizeAndRestore(
    _ preparedRestore: QuarantineRecoveryPreparedRestoreHandle,
    statement: QuarantineRestoreConfirmationStatement
  ) -> Result<
    QuarantineRecoveryWorkflowExecutionResult,
    QuarantineRecoveryWorkflowExecutionFailure
  > {
    .failure(.execution(.cancelled))
  }

  func cancelPendingRestore() {
    cancellationCount += 1
  }

  func waitUntilLoadCount(_ expected: Int) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
      if loadCount >= expected {
        return true
      }
      try? await clock.sleep(for: .milliseconds(10))
    }
    return false
  }

  func resolveLoad(
    _ occurrence: Int,
    with result: Result<
      QuarantineRecoveryWorkflowInventory,
      QuarantineInventoryLoadFailure
    >
  ) {
    loadContinuations.removeValue(forKey: occurrence)?.resume(returning: result)
  }

  func waitUntilCancellationCount(_ expected: Int) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
      if cancellationCount >= expected {
        return true
      }
      try? await clock.sleep(for: .milliseconds(10))
    }
    return false
  }
}

private actor GatedRestoreWorkflow: QuarantineRecoveryWorkflowHandling {
  private var executionContinuation:
    CheckedContinuation<
      Result<
        QuarantineRecoveryWorkflowExecutionResult,
        QuarantineRecoveryWorkflowExecutionFailure
      >,
      Never
    >?
  private(set) var executionCount = 0
  private(set) var cancellationCount = 0

  func reconcileAndLoadInventory()
    -> Result<QuarantineRecoveryWorkflowInventory, QuarantineInventoryLoadFailure>
  {
    .success(recoveryInventory())
  }

  func beginRestore(
    for item: QuarantineRecoveryWorkflowItemHandle
  ) -> Result<QuarantineRecoveryPreparedRestore, QuarantineRestorePreparationFailure> {
    .success(recoveryPreparedRestore())
  }

  func authorizeAndRestore(
    _ preparedRestore: QuarantineRecoveryPreparedRestoreHandle,
    statement: QuarantineRestoreConfirmationStatement
  ) async -> Result<
    QuarantineRecoveryWorkflowExecutionResult,
    QuarantineRecoveryWorkflowExecutionFailure
  > {
    executionCount += 1
    return await withCheckedContinuation { continuation in
      executionContinuation = continuation
    }
  }

  func cancelPendingRestore() {
    cancellationCount += 1
  }

  func waitUntilExecutionCount(_ expected: Int) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
      if executionCount >= expected {
        return true
      }
      try? await clock.sleep(for: .milliseconds(10))
    }
    return false
  }

  func resolveExecution(
    with result: Result<
      QuarantineRecoveryWorkflowExecutionResult,
      QuarantineRecoveryWorkflowExecutionFailure
    >
  ) {
    executionContinuation?.resume(returning: result)
    executionContinuation = nil
  }

  func waitUntilCancellationCount(_ expected: Int) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
      if cancellationCount >= expected {
        return true
      }
      try? await clock.sleep(for: .milliseconds(10))
    }
    return false
  }
}

private func recoveryInventory(
  readiness: QuarantineInventoryRestoreReadiness = QuarantineInventoryRestoreReadiness(
    originalSource: .missing,
    quarantinedItem: .available
  )
) -> QuarantineRecoveryWorkflowInventory {
  let identity = QuarantineRecoveryInventoryIdentity()
  return QuarantineRecoveryWorkflowInventory(
    items: [
      QuarantineRecoveryWorkflowInventoryItem(
        handle: QuarantineRecoveryWorkflowItemHandle(identity: identity, ordinal: 0),
        responsibleTool: "npm",
        originalName: "_cacache",
        readiness: readiness,
        quarantineReceiptWasProducedByRecovery: false
      )
    ]
  )
}

private func recoveryPreparedRestore() -> QuarantineRecoveryPreparedRestore {
  QuarantineRecoveryPreparedRestore(
    handle: QuarantineRecoveryPreparedRestoreHandle(
      identity: QuarantineRecoveryAttemptIdentity()
    ),
    requiredStatement:
      .restoreCurrentQuarantinedContentsWithoutOverwriteWithNPMStoppedAndChangesAccepted,
    responsibleTool: "npm",
    originalName: "_cacache"
  )
}

private func durableRestoreResult() -> QuarantineRecoveryWorkflowExecutionResult {
  QuarantineRecoveryWorkflowExecutionResult(
    status: .restored(quarantineNameWasRecreated: false),
    durability: .receiptRecorded(producedByRecovery: false),
    cancellationWasObservedAfterRename: false,
    isDurablyRestored: true
  )
}
