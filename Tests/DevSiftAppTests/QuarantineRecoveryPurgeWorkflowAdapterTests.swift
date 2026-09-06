import Foundation
import Testing

@testable import DevSiftApp
@testable import DevSiftCore

@Suite("Core quarantine permanent deletion app adapter")
struct QuarantineRecoveryPurgeWorkflowAdapterTests {
  @Test("Initial and retry handles dispatch only their exact Core statements")
  func initialAndRetryDispatchAreDistinct() async throws {
    let fixtures = try appAdapterPurgeFixtures()
    let calls = AppAdapterPurgeCallProbe()
    let executor = CleanupQuarantinePurgeExecutor(
      testingInitialClaim: { _ in
        calls.recordInitialExecution()
        return .terminalReceipt(
          outcome: .itemAbsent,
          producedByRecovery: false,
          capacityObservationProvenance: .initialAttempt,
          observedCapacityChange: .increase(amount: 4_096),
          observedUnlinkCount: 1,
          cancellationWasObserved: false
        )
      },
      testingRetryClaim: { _ in
        calls.recordRetryExecution()
        return .explicitRetryRequired(
          reason: .treeChanged,
          observedUnlinkCount: 1,
          cancellationWasObserved: false
        )
      }
    )
    let adapter = CoreQuarantineRecoveryWorkflowAdapter(
      workflow: appAdapterPurgeWorkflow(
        fixtures: fixtures,
        execute: { try await executor.execute($0) }
      ))
    let inventory = try appAdapterInventory(await adapter.reconcileAndLoadInventory())

    let initial = try appAdapterPreparedPurge(
      await adapter.beginInitialPurge(for: inventory.items[0].handle)
    )
    #expect(initial.attemptKind == .initial)
    #expect(initial.requiredStatement == .initialPermanentDeletionRisksAccepted)
    let initialResult = try appAdapterPurgeResult(
      await adapter.authorizeAndPurge(
        initial.handle,
        statement: initial.requiredStatement
      ))
    #expect(initialResult.attemptKind == .initial)
    #expect(initialResult.status == .itemAbsent)
    #expect(initialResult.isDurablyTerminal)
    #expect(calls.initialExecutionCount == 1)

    let retry = try appAdapterPreparedPurge(
      await adapter.beginPurgeRetry(for: inventory.purgeRetries[0].handle)
    )
    #expect(retry.attemptKind == .explicitRetry)
    #expect(retry.requiredStatement == .explicitRetryPermanentDeletionRisksAccepted)
    #expect(retry.requiredStatement != initial.requiredStatement)
    let retryResult = try appAdapterPurgeResult(
      await adapter.authorizeAndPurge(
        retry.handle,
        statement: retry.requiredStatement
      ))
    #expect(retryResult.attemptKind == .explicitRetry)
    #expect(retryResult.requiresExplicitRetry)
    #expect(calls.retryExecutionCount == 1)
  }

  @Test("A prepared handle executes once and every retained copy is rejected")
  func preparedHandleIsSingleUse() async throws {
    let fixtures = try appAdapterPurgeFixtures()
    let calls = AppAdapterPurgeCallProbe()
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
        return .manualRecoveryRequired(
          .invalidExecutionResult,
          observedUnlinkCount: 0,
          cancellationWasObserved: false
        )
      }
    )
    let adapter = CoreQuarantineRecoveryWorkflowAdapter(
      workflow: appAdapterPurgeWorkflow(
        fixtures: fixtures,
        execute: { try await executor.execute($0) }
      ))
    let inventory = try appAdapterInventory(await adapter.reconcileAndLoadInventory())
    let prepared = try appAdapterPreparedPurge(
      await adapter.beginInitialPurge(for: inventory.items[0].handle)
    )
    let retainedCopy = prepared.handle

    _ = try appAdapterPurgeResult(
      await adapter.authorizeAndPurge(
        prepared.handle,
        statement: prepared.requiredStatement
      ))
    let duplicate = await adapter.authorizeAndPurge(
      retainedCopy,
      statement: prepared.requiredStatement
    )

    #expect(
      duplicate
        == .failure(.authorization(.confirmationDoesNotBelongToAttempt))
    )
    #expect(calls.initialExecutionCount == 1)
  }

  @Test("Preparing a retry cancels and rejects the previous initial handle")
  func crossAttemptHandleIsRejected() async throws {
    let fixtures = try appAdapterPurgeFixtures()
    let calls = AppAdapterPurgeCallProbe()
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
          observedUnlinkCount: 0,
          cancellationWasObserved: false
        )
      }
    )
    let adapter = CoreQuarantineRecoveryWorkflowAdapter(
      workflow: appAdapterPurgeWorkflow(
        fixtures: fixtures,
        execute: { try await executor.execute($0) }
      ))
    let inventory = try appAdapterInventory(await adapter.reconcileAndLoadInventory())
    let initial = try appAdapterPreparedPurge(
      await adapter.beginInitialPurge(for: inventory.items[0].handle)
    )
    let retry = try appAdapterPreparedPurge(
      await adapter.beginPurgeRetry(for: inventory.purgeRetries[0].handle)
    )

    #expect(
      await adapter.authorizeAndPurge(
        initial.handle,
        statement: initial.requiredStatement
      ) == .failure(.authorization(.confirmationDoesNotBelongToAttempt))
    )
    _ = try appAdapterPurgeResult(
      await adapter.authorizeAndPurge(
        retry.handle,
        statement: retry.requiredStatement
      ))
    #expect(calls.initialExecutionCount == 0)
    #expect(calls.retryExecutionCount == 1)
  }

  @Test("Adapter-visible values do not reflect retained journal evidence")
  func projectedValuesArePrivacyBounded() async throws {
    let fixtures = try appAdapterPurgeFixtures()
    let adapter = CoreQuarantineRecoveryWorkflowAdapter(
      workflow: appAdapterPurgeWorkflow(
        fixtures: fixtures,
        execute: { _ in throw CancellationError() }
      ))
    let inventory = try appAdapterInventory(await adapter.reconcileAndLoadInventory())
    let initial = try appAdapterPreparedPurge(
      await adapter.beginInitialPurge(for: inventory.items[0].handle)
    )
    let descriptions = [
      String(reflecting: inventory),
      String(reflecting: inventory.items[0].handle),
      String(reflecting: inventory.purgeRetries[0].handle),
      String(reflecting: initial),
      String(reflecting: initial.handle),
    ]
    let forbidden = [
      fixtures.initialQuarantineTransactionID,
      fixtures.initialPurgeTransactionID,
      fixtures.retryQuarantineTransactionID,
      fixtures.retryPurgeTransactionID,
      "item-v1-",
      "purge-work-v1-",
      "canonicalPurge",
      "candidateBinding",
      "/Users/",
    ]

    for description in descriptions {
      for fragment in forbidden {
        #expect(!description.contains(fragment))
      }
    }
  }
}

private struct AppAdapterPurgeFixtures: Sendable {
  let initialQuarantineTransactionID: String
  let initialPurgeTransactionID: String
  let retryQuarantineTransactionID: String
  let retryPurgeTransactionID: String
  let initialEvidence: CleanupQuarantinePurgePreparedEvidence
  let retryEvidence: CleanupQuarantinePurgePreparedEvidence
  let entries: [DescriptorQuarantineInventoryEntry]
}

private func appAdapterPurgeFixtures() throws -> AppAdapterPurgeFixtures {
  let initialQuarantineTransactionID = String(repeating: "3", count: 32)
  let initialPurgeTransactionID = String(repeating: "c", count: 32)
  let retryQuarantineTransactionID = String(repeating: "4", count: 32)
  let retryPurgeTransactionID = String(repeating: "d", count: 32)
  let initial = try appAdapterPurgeEvidence(
    attemptKind: .initial,
    quarantineTransactionID: initialQuarantineTransactionID,
    purgeTransactionID: initialPurgeTransactionID
  )
  let retry = try appAdapterPurgeEvidence(
    attemptKind: .explicitRetry,
    quarantineTransactionID: retryQuarantineTransactionID,
    purgeTransactionID: retryPurgeTransactionID
  )
  return AppAdapterPurgeFixtures(
    initialQuarantineTransactionID: initialQuarantineTransactionID,
    initialPurgeTransactionID: initialPurgeTransactionID,
    retryQuarantineTransactionID: retryQuarantineTransactionID,
    retryPurgeTransactionID: retryPurgeTransactionID,
    initialEvidence: initial,
    retryEvidence: retry,
    entries: [
      appAdapterInventoryEntry(from: initial, itemState: .available),
      appAdapterInventoryEntry(from: retry, itemState: .missing),
    ]
  )
}

private func appAdapterPurgeWorkflow(
  fixtures: AppAdapterPurgeFixtures,
  execute: @escaping QuarantineInventoryRestoreWorkflow.ExecutePurge
) -> QuarantineInventoryRestoreWorkflow {
  QuarantineInventoryRestoreWorkflow(
    loadInventory: { .success(fixtures.entries) },
    prepareRestore: { _ in .failure(.invalidClaim) },
    executeRestore: { _ in throw CancellationError() },
    prepareInitialPurge: { _ in appAdapterBeginAuthorization(for: fixtures.initialEvidence) },
    preparePurgeRetry: { _ in appAdapterBeginAuthorization(for: fixtures.retryEvidence) },
    executePurge: execute
  )
}

private func appAdapterBeginAuthorization(
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

private func appAdapterPurgeEvidence(
  attemptKind: CleanupQuarantinePurgeAttemptKind,
  quarantineTransactionID: String,
  purgeTransactionID: String
) throws -> CleanupQuarantinePurgePreparedEvidence {
  let quarantineIntent = QuarantineJournalIntentV1(
    transactionID: quarantineTransactionID,
    npmRootBinding: appAdapterBinding(inode: 10, linkCount: 3),
    quarantineRootBinding: appAdapterBinding(inode: 20, linkCount: 3),
    candidateBinding: appAdapterBinding(inode: 30, linkCount: 5),
    sourceComponents: [Array("_cacache".utf8)],
    destinationComponents: (0..<QuarantineJournalIntentV1.destinationCount).map {
      appAdapterItemComponent($0)
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
        currentWorkBinding: appAdapterBinding(
          inode: 30,
          permissionMode: 0o755,
          linkCount: 2
        )
      ))
  }
}

private func appAdapterInventoryEntry(
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

private func appAdapterBinding(
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

private func appAdapterItemComponent(_ ordinal: Int) -> [UInt8] {
  let suffix = String(ordinal + 1, radix: 16)
  return Array("item-v1-\(String(repeating: "0", count: 32 - suffix.count))\(suffix)".utf8)
}

private func appAdapterInventory(
  _ result: Result<QuarantineRecoveryWorkflowInventory, QuarantineInventoryLoadFailure>
) throws -> QuarantineRecoveryWorkflowInventory {
  switch result {
  case .success(let inventory):
    return inventory
  case .failure(let failure):
    throw AppAdapterPurgeTestError.inventory(failure)
  }
}

private func appAdapterPreparedPurge(
  _ result: Result<QuarantineRecoveryPreparedPurge, QuarantinePurgePreparationFailure>
) throws -> QuarantineRecoveryPreparedPurge {
  switch result {
  case .success(let prepared):
    return prepared
  case .failure(let failure):
    throw AppAdapterPurgeTestError.preparation(failure)
  }
}

private func appAdapterPurgeResult(
  _ result: Result<
    QuarantineRecoveryWorkflowPurgeExecutionResult,
    QuarantineRecoveryWorkflowPurgeExecutionFailure
  >
) throws -> QuarantineRecoveryWorkflowPurgeExecutionResult {
  switch result {
  case .success(let outcome):
    return outcome
  case .failure(let failure):
    throw AppAdapterPurgeTestError.execution(failure)
  }
}

private enum AppAdapterPurgeTestError: Error {
  case inventory(QuarantineInventoryLoadFailure)
  case preparation(QuarantinePurgePreparationFailure)
  case execution(QuarantineRecoveryWorkflowPurgeExecutionFailure)
}

private final class AppAdapterPurgeCallProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var initialExecutions = 0
  private var retryExecutions = 0

  var initialExecutionCount: Int { locked { initialExecutions } }
  var retryExecutionCount: Int { locked { retryExecutions } }

  func recordInitialExecution() { locked { initialExecutions += 1 } }
  func recordRetryExecution() { locked { retryExecutions += 1 } }

  private func locked<Result>(_ body: () -> Result) -> Result {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}
