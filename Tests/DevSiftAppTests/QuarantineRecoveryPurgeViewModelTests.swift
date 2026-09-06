import DevSiftCore
import Testing

@testable import DevSiftApp

@MainActor
@Suite("Quarantine permanent deletion view model")
struct QuarantineRecoveryPurgeViewModelTests {
  @Test("Initial purge requires all four acknowledgements and refreshes inventory")
  func initialPurgeRequiresAllAcknowledgements() async {
    let workflow = ScriptedPurgeWorkflow(
      inventories: [
        .success(purgeWorkflowInventory(includeRetry: true)),
        .success(QuarantineRecoveryWorkflowInventory(items: [])),
      ],
      initialPreparation: .success(preparedPurge(kind: .initial)),
      execution: .success(durableItemAbsentResult(kind: .initial))
    )
    let viewModel = QuarantineRecoveryViewModel(workflow: workflow)
    await viewModel.loadInventory().value
    guard case .loaded(let inventory) = viewModel.inventoryState,
      let preparation = viewModel.requestInitialPurge(for: inventory.rows[0].id)
    else {
      Issue.record("Expected an initial purge preparation")
      return
    }
    await preparation.value
    guard case .awaitingConfirmation(let confirmation) = viewModel.purgeState else {
      Issue.record("Expected an initial purge confirmation")
      return
    }

    #expect(confirmation.attemptKind == .initial)
    #expect(
      confirmation.requiredStatement
        == .initialPermanentDeletionRisksAccepted
    )
    #expect(
      viewModel.confirmAndPurge(
        confirmationID: confirmation.id,
        exactPermanentDeletionStatementWasConfirmed: false,
        restoreCutoffAndPartialDeletionWereAccepted: true,
        workWasStoppedAndActivityRisksWereAccepted: true,
        capacityAndSecureEraseLimitsWereAccepted: true
      ) == nil
    )
    #expect(
      viewModel.confirmAndPurge(
        confirmationID: confirmation.id,
        exactPermanentDeletionStatementWasConfirmed: true,
        restoreCutoffAndPartialDeletionWereAccepted: false,
        workWasStoppedAndActivityRisksWereAccepted: true,
        capacityAndSecureEraseLimitsWereAccepted: true
      ) == nil
    )
    #expect(
      viewModel.confirmAndPurge(
        confirmationID: confirmation.id,
        exactPermanentDeletionStatementWasConfirmed: true,
        restoreCutoffAndPartialDeletionWereAccepted: true,
        workWasStoppedAndActivityRisksWereAccepted: false,
        capacityAndSecureEraseLimitsWereAccepted: true
      ) == nil
    )
    #expect(
      viewModel.confirmAndPurge(
        confirmationID: confirmation.id,
        exactPermanentDeletionStatementWasConfirmed: true,
        restoreCutoffAndPartialDeletionWereAccepted: true,
        workWasStoppedAndActivityRisksWereAccepted: true,
        capacityAndSecureEraseLimitsWereAccepted: false
      ) == nil
    )
    #expect(await workflow.executionCount == 0)

    guard
      let execution = viewModel.confirmAndPurge(
        confirmationID: confirmation.id,
        exactPermanentDeletionStatementWasConfirmed: true,
        restoreCutoffAndPartialDeletionWereAccepted: true,
        workWasStoppedAndActivityRisksWereAccepted: true,
        capacityAndSecureEraseLimitsWereAccepted: true
      )
    else {
      Issue.record("Expected a fully acknowledged purge")
      return
    }
    await execution.value

    #expect(await workflow.executionCount == 1)
    #expect(await workflow.loadCount == 2)
    #expect(await workflow.lastStatement == .initialPermanentDeletionRisksAccepted)
    guard case .finished(let result) = viewModel.purgeState else {
      Issue.record("Expected the purge result after the mandatory refresh")
      return
    }
    #expect(result.tone == .success)
    #expect(result.isDurablyTerminal)
    guard case .loaded(let refreshed) = viewModel.inventoryState else {
      Issue.record("Expected a refreshed inventory")
      return
    }
    #expect(refreshed.isEmpty)
  }

  @Test("Restore, initial purge, and explicit retry are mutually exclusive")
  func actionsAreMutuallyExclusive() async {
    let workflow = ScriptedPurgeWorkflow(
      inventories: [.success(purgeWorkflowInventory(includeRetry: true))],
      initialPreparation: .success(preparedPurge(kind: .initial))
    )
    let viewModel = QuarantineRecoveryViewModel(workflow: workflow)
    await viewModel.loadInventory().value
    guard case .loaded(let inventory) = viewModel.inventoryState,
      let preparation = viewModel.requestInitialPurge(for: inventory.rows[0].id)
    else {
      Issue.record("Expected initial purge preparation")
      return
    }
    await preparation.value
    guard case .awaitingConfirmation = viewModel.purgeState else {
      Issue.record("Expected a pending purge confirmation")
      return
    }

    #expect(viewModel.requestRestore(for: inventory.rows[0].id) == nil)
    #expect(viewModel.requestPurgeRetry(for: inventory.purgeRetryRows[0].id) == nil)
    #expect(!viewModel.canStartRestore)
    #expect(!viewModel.canStartInitialPurge)
    #expect(!viewModel.canStartPurgeRetry)
    #expect(await workflow.restorePreparationCount == 0)
    #expect(await workflow.retryPreparationCount == 0)
  }

  @Test("Explicit retry has its own statement and refreshes after execution failure")
  func explicitRetryIsSeparateAndFailureRefreshes() async {
    let workflow = ScriptedPurgeWorkflow(
      inventories: [
        .success(purgeWorkflowInventory(includeRetry: true)),
        .failure(.busy),
      ],
      retryPreparation: .success(preparedPurge(kind: .explicitRetry)),
      execution: .failure(.execution(.authorizationAlreadyConsumed))
    )
    let viewModel = QuarantineRecoveryViewModel(workflow: workflow)
    await viewModel.loadInventory().value
    guard case .loaded(let inventory) = viewModel.inventoryState,
      let preparation = viewModel.requestPurgeRetry(for: inventory.purgeRetryRows[0].id)
    else {
      Issue.record("Expected an explicit retry preparation")
      return
    }
    await preparation.value
    guard case .awaitingConfirmation(let confirmation) = viewModel.purgeState else {
      Issue.record("Expected an explicit retry confirmation")
      return
    }

    #expect(confirmation.isExplicitRetry)
    #expect(
      confirmation.requiredStatement
        == .explicitRetryPermanentDeletionRisksAccepted
    )
    #expect(
      confirmation.requiredStatement
        != .initialPermanentDeletionRisksAccepted
    )
    guard let execution = fullyConfirm(viewModel, confirmation: confirmation) else {
      Issue.record("Expected explicit retry execution")
      return
    }
    await execution.value

    #expect(await workflow.loadCount == 2)
    #expect(await workflow.lastStatement == .explicitRetryPermanentDeletionRisksAccepted)
    guard case .failed(let issue) = viewModel.purgeState else {
      Issue.record("Expected the bounded execution failure to remain visible")
      return
    }
    #expect(issue.title.contains("did not execute"))
    guard case .failed(let refreshIssue) = viewModel.inventoryState else {
      Issue.record("Expected the failed fresh reconciliation to be published")
      return
    }
    #expect(refreshIssue.title.contains("busy"))
  }

  @Test("Cancelling a confirmation invalidates the prepared purge")
  func cancellationInvalidatesPreparedPurge() async {
    let workflow = ScriptedPurgeWorkflow(
      inventories: [.success(purgeWorkflowInventory())],
      initialPreparation: .success(preparedPurge(kind: .initial))
    )
    let viewModel = QuarantineRecoveryViewModel(workflow: workflow)
    await viewModel.loadInventory().value
    guard case .loaded(let inventory) = viewModel.inventoryState,
      let preparation = viewModel.requestInitialPurge(for: inventory.rows[0].id)
    else {
      Issue.record("Expected purge preparation")
      return
    }
    await preparation.value
    guard case .awaitingConfirmation(let confirmation) = viewModel.purgeState,
      let cancellation = viewModel.cancelPurgeConfirmation(confirmation.id)
    else {
      Issue.record("Expected a cancellable confirmation")
      return
    }
    await cancellation.value

    #expect(viewModel.purgeState == .idle)
    #expect(await workflow.cancellationCount >= 1)
    #expect(fullyConfirm(viewModel, confirmation: confirmation) == nil)
    #expect(await workflow.executionCount == 0)
  }

  @Test("A cancellation observed after staging is shown after a fresh inventory")
  func lateCancellationResultIsNotHidden() async {
    let workflow = ScriptedPurgeWorkflow(
      inventories: [
        .success(purgeWorkflowInventory()),
        .success(purgeWorkflowInventory(includeRetry: true)),
      ],
      initialPreparation: .success(preparedPurge(kind: .initial)),
      execution: .success(retryRequiredResult())
    )
    let viewModel = QuarantineRecoveryViewModel(workflow: workflow)
    await viewModel.loadInventory().value
    guard case .loaded(let inventory) = viewModel.inventoryState,
      let preparation = viewModel.requestInitialPurge(for: inventory.rows[0].id)
    else {
      Issue.record("Expected purge preparation")
      return
    }
    await preparation.value
    guard case .awaitingConfirmation(let confirmation) = viewModel.purgeState,
      let execution = fullyConfirm(viewModel, confirmation: confirmation)
    else {
      Issue.record("Expected purge execution")
      return
    }
    await execution.value

    #expect(await workflow.loadCount == 2)
    guard case .finished(let result) = viewModel.purgeState else {
      Issue.record("Expected Core's cancellation-aware result")
      return
    }
    #expect(result.requiresExplicitRetry)
    #expect(result.cancellationMessage != nil)
    guard case .loaded(let refreshed) = viewModel.inventoryState else {
      Issue.record("Expected the refreshed retry inventory")
      return
    }
    #expect(refreshed.purgeRetryRows.count == 1)
  }
}

private actor ScriptedPurgeWorkflow: QuarantineRecoveryWorkflowHandling {
  private var inventories:
    [Result<QuarantineRecoveryWorkflowInventory, QuarantineInventoryLoadFailure>]
  private let initialPreparation:
    Result<QuarantineRecoveryPreparedPurge, QuarantinePurgePreparationFailure>
  private let retryPreparation:
    Result<QuarantineRecoveryPreparedPurge, QuarantinePurgePreparationFailure>
  private let execution:
    Result<
      QuarantineRecoveryWorkflowPurgeExecutionResult,
      QuarantineRecoveryWorkflowPurgeExecutionFailure
    >
  private(set) var loadCount = 0
  private(set) var restorePreparationCount = 0
  private(set) var initialPreparationCount = 0
  private(set) var retryPreparationCount = 0
  private(set) var executionCount = 0
  private(set) var cancellationCount = 0
  private(set) var lastStatement: QuarantinePurgeConfirmationStatement?

  init(
    inventories: [Result<QuarantineRecoveryWorkflowInventory, QuarantineInventoryLoadFailure>],
    initialPreparation: Result<
      QuarantineRecoveryPreparedPurge,
      QuarantinePurgePreparationFailure
    > = .failure(.invalidInventoryReference),
    retryPreparation: Result<
      QuarantineRecoveryPreparedPurge,
      QuarantinePurgePreparationFailure
    > = .failure(.invalidInventoryReference),
    execution: Result<
      QuarantineRecoveryWorkflowPurgeExecutionResult,
      QuarantineRecoveryWorkflowPurgeExecutionFailure
    > = .failure(.execution(.cancelled))
  ) {
    self.inventories = inventories
    self.initialPreparation = initialPreparation
    self.retryPreparation = retryPreparation
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
    restorePreparationCount += 1
    return .failure(.inventoryChanged)
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

  func beginInitialPurge(
    for item: QuarantineRecoveryWorkflowItemHandle
  ) -> Result<QuarantineRecoveryPreparedPurge, QuarantinePurgePreparationFailure> {
    initialPreparationCount += 1
    return initialPreparation
  }

  func beginPurgeRetry(
    for item: QuarantineRecoveryWorkflowPurgeRetryHandle
  ) -> Result<QuarantineRecoveryPreparedPurge, QuarantinePurgePreparationFailure> {
    retryPreparationCount += 1
    return retryPreparation
  }

  func authorizeAndPurge(
    _ preparedPurge: QuarantineRecoveryPreparedPurgeHandle,
    statement: QuarantinePurgeConfirmationStatement
  ) -> Result<
    QuarantineRecoveryWorkflowPurgeExecutionResult,
    QuarantineRecoveryWorkflowPurgeExecutionFailure
  > {
    executionCount += 1
    lastStatement = statement
    return execution
  }

  func cancelPendingRestore() {
    cancellationCount += 1
  }
}

@MainActor
private func fullyConfirm(
  _ viewModel: QuarantineRecoveryViewModel,
  confirmation: QuarantineRecoveryPurgeConfirmationPresentation
) -> Task<Void, Never>? {
  viewModel.confirmAndPurge(
    confirmationID: confirmation.id,
    exactPermanentDeletionStatementWasConfirmed: true,
    restoreCutoffAndPartialDeletionWereAccepted: true,
    workWasStoppedAndActivityRisksWereAccepted: true,
    capacityAndSecureEraseLimitsWereAccepted: true
  )
}

private func purgeWorkflowInventory(
  includeRetry: Bool = false
) -> QuarantineRecoveryWorkflowInventory {
  let itemIdentity = QuarantineRecoveryInventoryIdentity()
  let retryIdentity = QuarantineRecoveryPurgeRetryInventoryIdentity()
  let readiness = QuarantineInventoryRestoreReadiness(
    originalSource: .missing,
    quarantinedItem: .available
  )
  return QuarantineRecoveryWorkflowInventory(
    items: [
      QuarantineRecoveryWorkflowInventoryItem(
        handle: QuarantineRecoveryWorkflowItemHandle(identity: itemIdentity, ordinal: 0),
        responsibleTool: "npm",
        originalName: "_cacache",
        readiness: readiness,
        purgeReadiness: QuarantineInventoryPurgeReadiness(quarantinedItem: .available),
        quarantineReceiptWasProducedByRecovery: false
      )
    ],
    purgeRetries:
      includeRetry
      ? [
        QuarantineRecoveryWorkflowPurgeRetryItem(
          handle: QuarantineRecoveryWorkflowPurgeRetryHandle(
            identity: retryIdentity,
            ordinal: 0
          ),
          responsibleTool: "npm",
          originalName: "_cacache"
        )
      ] : []
  )
}

private func preparedPurge(
  kind: QuarantinePurgeAttemptKind
) -> QuarantineRecoveryPreparedPurge {
  QuarantineRecoveryPreparedPurge(
    handle: QuarantineRecoveryPreparedPurgeHandle(
      identity: QuarantineRecoveryPurgeAttemptIdentity()
    ),
    attemptKind: kind,
    requiredStatement:
      kind == .initial
      ? .initialPermanentDeletionRisksAccepted
      : .explicitRetryPermanentDeletionRisksAccepted,
    responsibleTool: "npm",
    originalName: "_cacache"
  )
}

private func durableItemAbsentResult(
  kind: QuarantinePurgeAttemptKind
) -> QuarantineRecoveryWorkflowPurgeExecutionResult {
  QuarantineRecoveryWorkflowPurgeExecutionResult(
    attemptKind: kind,
    status: .itemAbsent,
    durability: .terminalReceiptRecorded(
      outcome: .itemAbsent,
      producedByRecovery: false
    ),
    capacityObservationProvenance:
      kind == .initial ? .initialAttempt : .explicitRetry,
    observedCapacityChange: .increase(amount: 4_096),
    observedUnlinkCount: 2,
    isDurablyTerminal: true,
    isCrashRecoverable: true,
    performedPermanentDeletion: true,
    requiresExplicitRetry: false
  )
}

private func retryRequiredResult() -> QuarantineRecoveryWorkflowPurgeExecutionResult {
  QuarantineRecoveryWorkflowPurgeExecutionResult(
    attemptKind: .initial,
    status: .explicitRetryRequired(
      progress: .unlinkProgressObserved,
      reason: .cancelled
    ),
    durability: .intentRecorded,
    observedUnlinkCount: 1,
    cancellationWasObserved: true,
    isDurablyTerminal: false,
    isCrashRecoverable: true,
    performedPermanentDeletion: true,
    requiresExplicitRetry: true
  )
}
