import Foundation
import Testing

@testable import DevSiftCore

@Suite("Package quarantine purge facade")
struct QuarantinePurgeFacadeTests {
  @Test("Initial and retry references remain bound to one inventory session")
  func staleReferencesAreRejectedBeforePreparation() throws {
    let fixtures = try facadePurgeFixtures()
    let calls = FacadePurgeCallProbe()
    let workflow = facadePurgeWorkflow(
      entries: fixtures.entries,
      prepareInitial: { _ in
        calls.recordInitialPreparation()
        return .failure(.invalidSelection)
      },
      prepareRetry: { _ in
        calls.recordRetryPreparation()
        return .failure(.invalidSelection)
      }
    )
    let first = try facadeInventory(workflow.reconcileAndLoadInventory())
    let refreshed = try facadeInventory(workflow.reconcileAndLoadInventory())

    facadeExpectPreparationFailure(
      .invalidInventoryReference,
      workflow.beginInitialPurge(from: first, item: refreshed.items[0].reference)
    )
    facadeExpectPreparationFailure(
      .invalidInventoryReference,
      workflow.beginPurgeRetry(from: first, retry: refreshed.purgeRetries[0].reference)
    )
    #expect(calls.initialPreparationCount == 0)
    #expect(calls.retryPreparationCount == 0)
  }

  @Test("Initial and explicit retry expose distinct attempt-bound statements")
  func preparationBranchesAndStatementsAreDistinct() throws {
    let fixtures = try facadePurgeFixtures()
    let calls = FacadePurgeCallProbe()
    let workflow = facadePurgeWorkflow(
      entries: fixtures.entries,
      prepareInitial: { _ in
        calls.recordInitialPreparation()
        return facadeBeginAuthorization(for: fixtures.initialEvidence)
      },
      prepareRetry: { _ in
        calls.recordRetryPreparation()
        return facadeBeginAuthorization(for: fixtures.retryEvidence)
      }
    )
    let inventory = try facadeInventory(workflow.reconcileAndLoadInventory())

    let initial = try facadePurgeSession(
      workflow.beginInitialPurge(from: inventory, item: inventory.items[0].reference)
    )
    let retry = try facadePurgeSession(
      workflow.beginPurgeRetry(from: inventory, retry: inventory.purgeRetries[0].reference)
    )

    #expect(calls.initialPreparationCount == 1)
    #expect(calls.retryPreparationCount == 1)
    #expect(initial.confirmationRequest.attemptKind == .initial)
    #expect(retry.confirmationRequest.attemptKind == .explicitRetry)
    #expect(
      initial.confirmationRequest.requiredStatement == .initialPermanentDeletionRisksAccepted
    )
    #expect(
      retry.confirmationRequest.requiredStatement
        == .explicitRetryPermanentDeletionRisksAccepted
    )
    #expect(
      initial.confirmationRequest.requiredStatement
        != retry.confirmationRequest.requiredStatement
    )
    #expect(initial.confirmationRequest != retry.confirmationRequest)
    #expect(initial.confirmationRequest.responsibleTool == "npm")
    #expect(initial.confirmationRequest.originalName == "_cacache")
  }

  @Test("Purge authority is narrow and executor dispatch consumes every copy once")
  func authorityPropertiesAndExecutionBranches() async throws {
    let fixtures = try facadePurgeFixtures()
    let calls = FacadePurgeCallProbe()
    let executor = CleanupQuarantinePurgeExecutor(
      testingInitialClaim: { _ in
        calls.recordInitialExecution()
        return .noMutation(
          .unsupportedPlatform,
          durableIntentAlreadyExists: false,
          cancellationWasObserved: false
        )
      },
      testingRetryClaim: { _ in
        calls.recordRetryExecution()
        return .explicitRetryRequired(
          reason: .treeChanged,
          observedUnlinkCount: 1,
          cancellationWasObserved: true
        )
      }
    )
    let workflow = facadePurgeWorkflow(
      entries: fixtures.entries,
      prepareInitial: { _ in facadeBeginAuthorization(for: fixtures.initialEvidence) },
      prepareRetry: { _ in facadeBeginAuthorization(for: fixtures.retryEvidence) },
      execute: { try await executor.execute($0) }
    )
    let inventory = try facadeInventory(workflow.reconcileAndLoadInventory())
    let initialSession = try facadePurgeSession(
      workflow.beginInitialPurge(from: inventory, item: inventory.items[0].reference)
    )
    let retrySession = try facadePurgeSession(
      workflow.beginPurgeRetry(from: inventory, retry: inventory.purgeRetries[0].reference)
    )

    await facadeExpectAuthorizationFailure(.confirmationStatementMismatch) {
      _ = try await initialSession.authorize(
        using: QuarantinePurgeUserConfirmation(
          request: initialSession.confirmationRequest,
          statement: .explicitRetryPermanentDeletionRisksAccepted
        ))
    }

    let initialAuthorization = try await facadeAuthorize(initialSession)
    let initialCopy = initialAuthorization
    let retryAuthorization = try await facadeAuthorize(retrySession)

    #expect(initialAuthorization.attemptKind == .initial)
    #expect(retryAuthorization.attemptKind == .explicitRetry)
    #expect(initialAuthorization.isSingleUse)
    #expect(initialAuthorization.authorizesPurgeOnly)
    #expect(initialAuthorization.authorizesPermanentDeletion)
    #expect(!initialAuthorization.authorizesRestore)
    #expect(!initialAuthorization.authorizesOverwrite)
    #expect(!initialAuthorization.authorizesArbitraryPaths)
    #expect(!initialAuthorization.authorizesActiveCacheDeletion)
    #expect(initialAuthorization.authorizesOnlyExactStagedWorkTree)
    #expect(initialAuthorization.requiresInlineFilesystemRevalidation)
    #expect(initialAuthorization.requiresInlineACLRevalidation)
    #expect(!initialAuthorization.grantsStandaloneFilesystemMutationAuthority)
    #expect(!initialAuthorization.usesWallClockFreshness)

    let initialOutcome = try facadePurgeOutcome(
      await workflow.executePurge(initialAuthorization)
    )
    #expect(initialOutcome.attemptKind == .initial)
    #expect(initialOutcome.status == .noMutation(.unsupportedPlatform))
    #expect(initialOutcome.durability == .notRecorded)
    #expect(!initialOutcome.isCrashRecoverable)
    #expect(!initialOutcome.performedPermanentDeletion)

    let retryOutcome = try facadePurgeOutcome(await workflow.executePurge(retryAuthorization))
    #expect(retryOutcome.attemptKind == .explicitRetry)
    #expect(
      retryOutcome.status
        == .explicitRetryRequired(progress: .unlinkProgressObserved, reason: .treeChanged)
    )
    #expect(retryOutcome.durability == .intentRecorded)
    #expect(retryOutcome.isCrashRecoverable)
    #expect(retryOutcome.performedPermanentDeletion)
    #expect(retryOutcome.requiresExplicitRetry)
    #expect(retryOutcome.cancellationWasObserved)
    #expect(calls.initialExecutionCount == 1)
    #expect(calls.retryExecutionCount == 1)

    facadeExpectExecutionFailure(
      .authorizationAlreadyConsumed,
      await workflow.executePurge(initialCopy)
    )
    #expect(calls.initialExecutionCount == 1)

    let cancelledSession = try facadePurgeSession(
      workflow.beginInitialPurge(from: inventory, item: inventory.items[0].reference)
    )
    await cancelledSession.cancel()
    await facadeExpectAuthorizationFailure(.attemptCancelled) {
      _ = try await facadeAuthorize(cancelledSession)
    }
  }

  @Test("Terminal receipt projection preserves bounded capacity evidence")
  func terminalReceiptAndCapacityProjection() async throws {
    let fixtures = try facadePurgeFixtures()
    let executor = CleanupQuarantinePurgeExecutor(
      testingInitialClaim: { _ in
        .terminalReceipt(
          outcome: .itemAbsent,
          producedByRecovery: false,
          capacityObservationProvenance: .initialAttempt,
          observedCapacityChange: .increase(amount: 8_192),
          observedUnlinkCount: 3,
          cancellationWasObserved: false
        )
      },
      testingRetryClaim: { _ in
        .manualRecoveryRequired(
          .invalidExecutionResult,
          observedUnlinkCount: 0,
          cancellationWasObserved: false
        )
      }
    )
    let workflow = facadePurgeWorkflow(
      entries: fixtures.entries,
      prepareInitial: { _ in facadeBeginAuthorization(for: fixtures.initialEvidence) },
      prepareRetry: { _ in facadeBeginAuthorization(for: fixtures.retryEvidence) },
      execute: { try await executor.execute($0) }
    )
    let inventory = try facadeInventory(workflow.reconcileAndLoadInventory())
    let session = try facadePurgeSession(
      workflow.beginInitialPurge(from: inventory, item: inventory.items[0].reference)
    )
    let outcome = try facadePurgeOutcome(
      await workflow.executePurge(try await facadeAuthorize(session))
    )

    #expect(outcome.status == .itemAbsent)
    #expect(
      outcome.durability
        == .terminalReceiptRecorded(outcome: .itemAbsent, producedByRecovery: false)
    )
    #expect(outcome.capacityObservationProvenance == .initialAttempt)
    #expect(outcome.observedCapacityChange == .increase(amount: 8_192))
    #expect(outcome.observedUnlinkCount == 3)
    #expect(outcome.isDurablyTerminal)
    #expect(outcome.isCrashRecoverable)
    #expect(outcome.performedPermanentDeletion)
    #expect(!outcome.requiresExplicitRetry)
  }

  @Test("Every purge preparation failure is projected into a bounded category")
  func preparationFailureMapping() throws {
    let fixtures = try facadePurgeFixtures()
    let cases:
      [(
        DescriptorNPMQuarantinePurgePreflightFailure,
        QuarantinePurgePreparationFailure
      )] = [
        (.cancelled, .cancelled),
        (.unsupportedPlatform, .unsupportedPlatform),
        (.invalidSelection, .inventoryChanged),
        (.invalidClaim, .inventoryChanged),
        (.invalidCurrentAccount, .invalidCurrentAccount),
        (.invalidHome, .trustedLocationUnavailable(.invalidMetadata)),
        (.homeUnavailable(.permissionDenied), .trustedLocationUnavailable(.permissionDenied)),
        (.rootUnavailable(.noSpace), .trustedLocationUnavailable(.noSpace)),
        (.quarantineRootUnavailable(.inputOutput), .trustedLocationUnavailable(.inputOutput)),
        (.homeUnsafe, .trustedLocationChanged),
        (.rootUnsafe, .trustedLocationChanged),
        (.quarantineRootUnsafe, .trustedLocationChanged),
        (.journalRecordMissing, .journalRecordMissing),
        (.journalRecordChanged, .journalRecordChanged),
        (.journalRecordUnsafe, .journalRecordUnsafe),
        (.quarantinedItemMissing, .quarantinedItemMissing),
        (.quarantinedItemChanged, .quarantinedItemChanged),
        (.quarantinedItemUnsafe, .quarantinedItemUnsafe),
        (.purgeWorkMissing, .purgeWorkMissing),
        (.purgeWorkChanged, .purgeWorkChanged),
        (.purgeWorkUnsafe, .purgeWorkUnsafe),
        (.purgeWorkNameOccupied, .purgeWorkNameOccupied),
        (.traversalLimitExceeded, .traversalLimitExceeded),
        (
          .capacityObservation(.unavailable(.readOnlyFileSystem)),
          .capacityObservation(.unavailable(.readOnlyFileSystem))
        ),
        (
          .capacityObservation(.expectedDeviceMismatch),
          .capacityObservation(.expectedDeviceMismatch)
        ),
        (
          .capacityObservation(.expectedVolumeMismatch),
          .capacityObservation(.expectedVolumeMismatch)
        ),
        (
          .capacityObservation(.invalidFileSystemStatistics),
          .capacityObservation(.invalidFileSystemStatistics)
        ),
        (
          .capacityObservation(.availableByteCountOverflow),
          .capacityObservation(.availableByteCountOverflow)
        ),
        (.purgeIdentifierUnavailable, .purgeIdentifierUnavailable),
        (.purgeIdentifierCollisionLimitExceeded, .purgeIdentifierUnavailable),
        (
          .authorization(.invalidPreparedEvidence),
          .authorization(.invalidPreparedEvidence)
        ),
        (
          .authorization(.confirmationDoesNotBelongToAttempt),
          .authorization(.confirmationDoesNotBelongToAttempt)
        ),
        (
          .authorization(.confirmationStatementMismatch),
          .authorization(.confirmationStatementMismatch)
        ),
        (
          .authorization(.attemptAlreadyAuthorized),
          .authorization(.attemptAlreadyAuthorized)
        ),
        (
          .authorization(.attemptCancelled),
          .authorization(.attemptCancelled)
        ),
      ]

    for (internalFailure, expected) in cases {
      let workflow = facadePurgeWorkflow(
        entries: fixtures.entries,
        prepareInitial: { _ in .failure(internalFailure) },
        prepareRetry: { _ in .failure(.invalidSelection) }
      )
      let inventory = try facadeInventory(workflow.reconcileAndLoadInventory())
      facadeExpectPreparationFailure(
        expected,
        workflow.beginInitialPurge(from: inventory, item: inventory.items[0].reference)
      )
    }
  }

  @Test("Authorization-consumption failures remain bounded")
  func executionFailureMapping() async throws {
    let fixtures = try facadePurgeFixtures()
    let cases: [(FacadeInjectedExecutionFailure, QuarantinePurgeExecutionFailure)] = [
      (.unsupportedContractVersion, .invalidAuthorization),
      (.wrongAttempt, .invalidAuthorization),
      (.alreadyConsumed, .authorizationAlreadyConsumed),
      (.authorizationCancelled, .authorizationCancelled),
      (.taskCancelled, .cancelled),
      (.unexpected, .invalidAuthorization),
    ]

    for (injected, expected) in cases {
      let workflow = facadePurgeWorkflow(
        entries: fixtures.entries,
        prepareInitial: { _ in facadeBeginAuthorization(for: fixtures.initialEvidence) },
        prepareRetry: { _ in facadeBeginAuthorization(for: fixtures.retryEvidence) },
        execute: { _ in try injected.throwFailure() }
      )
      let inventory = try facadeInventory(workflow.reconcileAndLoadInventory())
      let session = try facadePurgeSession(
        workflow.beginInitialPurge(from: inventory, item: inventory.items[0].reference)
      )
      let authorization = try await facadeAuthorize(session)
      facadeExpectExecutionFailure(expected, await workflow.executePurge(authorization))
    }
  }

  @Test("Package purge values do not reflect retained journal or filesystem evidence")
  func packageValuesArePrivacyBounded() async throws {
    let fixtures = try facadePurgeFixtures()
    let executor = CleanupQuarantinePurgeExecutor(
      testingInitialClaim: { _ in
        .terminalReceipt(
          outcome: .itemAbsent,
          producedByRecovery: false,
          capacityObservationProvenance: .initialAttempt,
          observedCapacityChange: .unchanged,
          observedUnlinkCount: 1,
          cancellationWasObserved: false
        )
      },
      testingRetryClaim: { _ in
        .manualRecoveryRequired(
          .invalidExecutionResult,
          observedUnlinkCount: 0,
          cancellationWasObserved: false
        )
      }
    )
    let workflow = facadePurgeWorkflow(
      entries: fixtures.entries,
      prepareInitial: { _ in facadeBeginAuthorization(for: fixtures.initialEvidence) },
      prepareRetry: { _ in facadeBeginAuthorization(for: fixtures.retryEvidence) },
      execute: { try await executor.execute($0) }
    )
    let inventory = try facadeInventory(workflow.reconcileAndLoadInventory())
    let session = try facadePurgeSession(
      workflow.beginInitialPurge(from: inventory, item: inventory.items[0].reference)
    )
    let confirmation = QuarantinePurgeUserConfirmation(
      request: session.confirmationRequest,
      statement: session.confirmationRequest.requiredStatement
    )
    let authorization = try await session.authorize(using: confirmation)
    let outcome = try facadePurgeOutcome(await workflow.executePurge(authorization))
    let descriptions = [
      String(reflecting: session.confirmationRequest),
      String(reflecting: confirmation),
      String(reflecting: session),
      String(reflecting: authorization),
      String(reflecting: outcome),
      String(describing: session),
      String(describing: authorization),
      String(describing: outcome),
    ]
    let forbiddenFragments = [
      fixtures.quarantineTransactionID,
      fixtures.purgeTransactionID,
      "item-v1-",
      "purge-work-v1-",
      "canonicalQuarantine",
      "canonicalPurge",
      "candidateBinding",
      "npmRootBinding",
      "quarantineRootBinding",
      "inode",
      "device",
    ]

    for description in descriptions {
      for fragment in forbiddenFragments {
        #expect(!description.contains(fragment))
      }
    }
    #expect(!facadeIsEncodable(session))
    #expect(!facadeIsEncodable(authorization))
    #expect(!facadeIsEncodable(outcome))
  }
}

private struct FacadePurgeFixtures: Sendable {
  let quarantineTransactionID: String
  let purgeTransactionID: String
  let initialEvidence: CleanupQuarantinePurgePreparedEvidence
  let retryEvidence: CleanupQuarantinePurgePreparedEvidence
  let entries: [DescriptorQuarantineInventoryEntry]
}

private func facadePurgeFixtures() throws -> FacadePurgeFixtures {
  let initial = try facadePurgeEvidence(
    attemptKind: .initial,
    quarantineTransactionID: String(repeating: "1", count: 32),
    purgeTransactionID: String(repeating: "a", count: 32)
  )
  let retry = try facadePurgeEvidence(
    attemptKind: .explicitRetry,
    quarantineTransactionID: String(repeating: "2", count: 32),
    purgeTransactionID: String(repeating: "b", count: 32)
  )
  return FacadePurgeFixtures(
    quarantineTransactionID: String(repeating: "1", count: 32),
    purgeTransactionID: String(repeating: "a", count: 32),
    initialEvidence: initial,
    retryEvidence: retry,
    entries: [
      facadeInventoryEntry(from: initial, itemState: .available),
      facadeInventoryEntry(from: retry, itemState: .missing),
    ]
  )
}

private func facadePurgeWorkflow(
  entries: [DescriptorQuarantineInventoryEntry],
  prepareInitial: @escaping QuarantineInventoryRestoreWorkflow.PrepareInitialPurge,
  prepareRetry: @escaping QuarantineInventoryRestoreWorkflow.PreparePurgeRetry,
  execute: @escaping QuarantineInventoryRestoreWorkflow.ExecutePurge = { _ in
    throw CleanupQuarantinePurgeAuthorizationConsumptionError.authorizationCancelled
  }
) -> QuarantineInventoryRestoreWorkflow {
  QuarantineInventoryRestoreWorkflow(
    loadInventory: { .success(entries) },
    prepareRestore: { _ in .failure(.invalidClaim) },
    executeRestore: { _ in throw CancellationError() },
    prepareInitialPurge: prepareInitial,
    preparePurgeRetry: prepareRetry,
    executePurge: execute
  )
}

private func facadeBeginAuthorization(
  for evidence: CleanupQuarantinePurgePreparedEvidence
) -> Result<
  CleanupQuarantinePurgeAuthorizationSession,
  DescriptorNPMQuarantinePurgePreflightFailure
> {
  do {
    return .success(try CleanupQuarantinePurgeAuthorizer().beginAttempt(for: evidence))
  } catch is CancellationError {
    return .failure(.cancelled)
  } catch let failure as CleanupQuarantinePurgeAuthorizationError {
    return .failure(.authorization(failure))
  } catch {
    return .failure(.invalidSelection)
  }
}

private func facadeAuthorize(
  _ session: QuarantinePurgeAuthorizationSession
) async throws -> QuarantinePurgeAuthorization {
  try await session.authorize(
    using: QuarantinePurgeUserConfirmation(
      request: session.confirmationRequest,
      statement: session.confirmationRequest.requiredStatement
    ))
}

private func facadePurgeEvidence(
  attemptKind: CleanupQuarantinePurgeAttemptKind,
  quarantineTransactionID: String,
  purgeTransactionID: String
) throws -> CleanupQuarantinePurgePreparedEvidence {
  let quarantineIntent = QuarantineJournalIntentV1(
    transactionID: quarantineTransactionID,
    npmRootBinding: facadeBinding(inode: 10, linkCount: 3),
    quarantineRootBinding: facadeBinding(inode: 20, linkCount: 3),
    candidateBinding: facadeBinding(inode: 30, linkCount: 5),
    sourceComponents: [Array("_cacache".utf8)],
    destinationComponents: (0..<QuarantineJournalIntentV1.destinationCount).map {
      facadeItemComponent($0)
    }
  )
  let quarantineIntentBytes = try QuarantineJournalV1Codec.encode(quarantineIntent)
  let quarantineReceipt = try QuarantineJournalV1Codec.makeReceipt(
    outcome: .quarantined,
    selectedDestinationOrdinal: 3,
    producedByRecovery: false,
    canonicalIntentBytes: quarantineIntentBytes
  )
  let quarantineReceiptBytes = try QuarantineJournalV1Codec.encode(
    quarantineReceipt,
    matchingIntentBytes: quarantineIntentBytes
  )
  let purgeIntent = try QuarantinePurgeJournalV1Codec.makeIntent(
    purgeTransactionID: purgeTransactionID,
    capacityBefore: QuarantinePurgeCapacityObservationV1(
      volumeIdentity: QuarantinePurgeVolumeIdentityV1(
        device: 7,
        fileSystemIDFirst: -2,
        fileSystemIDSecond: 9
      ),
      availableBytes: 4_096
    ),
    canonicalQuarantineIntentBytes: quarantineIntentBytes,
    canonicalQuarantineReceiptBytes: quarantineReceiptBytes
  )

  switch attemptKind {
  case .initial:
    return .initial(
      CleanupQuarantinePurgeInitialPreparedEvidence(
        canonicalQuarantineIntentBytes: quarantineIntentBytes,
        canonicalQuarantineReceiptBytes: quarantineReceiptBytes,
        purgeIntent: purgeIntent
      ))
  case .explicitRetry:
    let purgeIntentBytes = try QuarantinePurgeJournalV1Codec.encode(
      purgeIntent,
      matchingQuarantineIntentBytes: quarantineIntentBytes,
      matchingQuarantineReceiptBytes: quarantineReceiptBytes
    )
    return .explicitRetry(
      CleanupQuarantinePurgeRetryPreparedEvidence(
        canonicalQuarantineIntentBytes: quarantineIntentBytes,
        canonicalQuarantineReceiptBytes: quarantineReceiptBytes,
        purgeIntent: purgeIntent,
        canonicalPurgeIntentBytes: purgeIntentBytes,
        currentWorkBinding: facadeBinding(inode: 30, permissionMode: 0o755, linkCount: 2)
      ))
  }
}

private func facadeInventoryEntry(
  from evidence: CleanupQuarantinePurgePreparedEvidence,
  itemState: DescriptorQuarantineInventoryItemState
) -> DescriptorQuarantineInventoryEntry {
  switch evidence {
  case .initial(let initial):
    return DescriptorQuarantineInventoryEntry(
      quarantineTransactionID: initial.purgeIntent.quarantineTransactionID,
      canonicalQuarantineIntentBytes: initial.canonicalQuarantineIntentBytes,
      canonicalQuarantineReceiptBytes: initial.canonicalQuarantineReceiptBytes,
      sourceState: .missing,
      itemState: itemState,
      quarantineReceiptWasProducedByRecovery: false
    )
  case .explicitRetry(let retry):
    return DescriptorQuarantineInventoryEntry(
      quarantineTransactionID: retry.purgeIntent.quarantineTransactionID,
      canonicalQuarantineIntentBytes: retry.canonicalQuarantineIntentBytes,
      canonicalQuarantineReceiptBytes: retry.canonicalQuarantineReceiptBytes,
      sourceState: .missing,
      itemState: itemState,
      quarantineReceiptWasProducedByRecovery: false,
      purgeRetry: DescriptorQuarantinePurgeRetryInventoryEntry(
        canonicalQuarantineIntentBytes: retry.canonicalQuarantineIntentBytes,
        canonicalQuarantineReceiptBytes: retry.canonicalQuarantineReceiptBytes,
        purgeIntent: retry.purgeIntent,
        canonicalPurgeIntentBytes: retry.canonicalPurgeIntentBytes,
        currentWorkBinding: retry.currentWorkBinding
      )
    )
  }
}

private func facadeBinding(
  inode: UInt64,
  permissionMode: UInt32 = 0o700,
  linkCount: UInt64
) -> QuarantineJournalFileBindingV1 {
  QuarantineJournalFileBindingV1(
    device: 7,
    inode: inode,
    generation: 11,
    birthSeconds: 1_725_000_000,
    birthNanoseconds: 123_456_789,
    kind: .directory,
    ownerUID: 501,
    permissionMode: permissionMode,
    flags: 0,
    linkCount: linkCount
  )
}

private func facadeItemComponent(_ ordinal: Int) -> [UInt8] {
  let suffix = String(ordinal + 1, radix: 16)
  return Array("item-v1-\(String(repeating: "0", count: 32 - suffix.count))\(suffix)".utf8)
}

private func facadeInventory(
  _ result: Result<QuarantineInventorySession, QuarantineInventoryLoadFailure>
) throws -> QuarantineInventorySession {
  switch result {
  case .success(let inventory):
    return inventory
  case .failure(let failure):
    throw FacadePurgeTestError.inventory(failure)
  }
}

private func facadePurgeSession(
  _ result: Result<QuarantinePurgeAuthorizationSession, QuarantinePurgePreparationFailure>
) throws -> QuarantinePurgeAuthorizationSession {
  switch result {
  case .success(let session):
    return session
  case .failure(let failure):
    throw FacadePurgeTestError.preparation(failure)
  }
}

private func facadePurgeOutcome(
  _ result: Result<QuarantinePurgeExecutionOutcome, QuarantinePurgeExecutionFailure>
) throws -> QuarantinePurgeExecutionOutcome {
  switch result {
  case .success(let outcome):
    return outcome
  case .failure(let failure):
    throw FacadePurgeTestError.execution(failure)
  }
}

private func facadeExpectPreparationFailure(
  _ expected: QuarantinePurgePreparationFailure,
  _ result: Result<QuarantinePurgeAuthorizationSession, QuarantinePurgePreparationFailure>
) {
  switch result {
  case .success:
    Issue.record("Expected purge preparation failure \(expected)")
  case .failure(let failure):
    #expect(failure == expected)
  }
}

private func facadeExpectExecutionFailure(
  _ expected: QuarantinePurgeExecutionFailure,
  _ result: Result<QuarantinePurgeExecutionOutcome, QuarantinePurgeExecutionFailure>
) {
  switch result {
  case .success:
    Issue.record("Expected purge execution failure \(expected)")
  case .failure(let failure):
    #expect(failure == expected)
  }
}

private func facadeExpectAuthorizationFailure(
  _ expected: QuarantinePurgeAuthorizationFailure,
  _ operation: () async throws -> Void
) async {
  do {
    try await operation()
    Issue.record("Expected purge authorization failure \(expected)")
  } catch let failure as QuarantinePurgeAuthorizationFailure {
    #expect(failure == expected)
  } catch {
    Issue.record("Unexpected purge authorization error: \(error)")
  }
}

private func facadeIsEncodable(_ value: Any) -> Bool {
  value is any Encodable
}

private enum FacadeInjectedExecutionFailure: Sendable {
  case unsupportedContractVersion
  case wrongAttempt
  case alreadyConsumed
  case authorizationCancelled
  case taskCancelled
  case unexpected

  func throwFailure() throws -> CleanupQuarantinePurgeReport {
    switch self {
    case .unsupportedContractVersion:
      throw CleanupQuarantinePurgeAuthorizationConsumptionError.unsupportedContractVersion
    case .wrongAttempt:
      throw CleanupQuarantinePurgeAuthorizationConsumptionError
        .authorizationDoesNotBelongToAttempt
    case .alreadyConsumed:
      throw CleanupQuarantinePurgeAuthorizationConsumptionError.authorizationAlreadyConsumed
    case .authorizationCancelled:
      throw CleanupQuarantinePurgeAuthorizationConsumptionError.authorizationCancelled
    case .taskCancelled:
      throw CancellationError()
    case .unexpected:
      throw FacadePurgeTestError.unexpected
    }
  }
}

private enum FacadePurgeTestError: Error {
  case inventory(QuarantineInventoryLoadFailure)
  case preparation(QuarantinePurgePreparationFailure)
  case execution(QuarantinePurgeExecutionFailure)
  case unexpected
}

private final class FacadePurgeCallProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var initialPreparations = 0
  private var retryPreparations = 0
  private var initialExecutions = 0
  private var retryExecutions = 0

  var initialPreparationCount: Int { locked { initialPreparations } }
  var retryPreparationCount: Int { locked { retryPreparations } }
  var initialExecutionCount: Int { locked { initialExecutions } }
  var retryExecutionCount: Int { locked { retryExecutions } }

  func recordInitialPreparation() { locked { initialPreparations += 1 } }
  func recordRetryPreparation() { locked { retryPreparations += 1 } }
  func recordInitialExecution() { locked { initialExecutions += 1 } }
  func recordRetryExecution() { locked { retryExecutions += 1 } }

  private func locked<Result>(_ body: () -> Result) -> Result {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}
