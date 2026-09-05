import DevSiftCore
import Foundation
import Testing

@testable import DevSiftApp
@testable import DevSiftCore

@Suite("Core quarantine recovery adapter")
struct QuarantineRecoveryWorkflowAdapterTests {
  @Test("A new reconciliation cancels and rejects the old prepared handle")
  func reconciliationRejectsStalePreparedHandle() async throws {
    let quarantineTransactionID = String(repeating: "1", count: 32)
    let evidence = try adapterRestoreAuthorizationEvidence(
      quarantineTransactionID: quarantineTransactionID
    )
    let entry = DescriptorQuarantineInventoryEntry(
      quarantineTransactionID: quarantineTransactionID,
      canonicalQuarantineIntentBytes: evidence.canonicalQuarantineIntentBytes,
      canonicalQuarantineReceiptBytes: evidence.canonicalQuarantineReceiptBytes,
      sourceState: .missing,
      itemState: .available,
      quarantineReceiptWasProducedByRecovery: false
    )
    let executionCount = RecoveryAdapterCounter()
    let coreWorkflow = QuarantineInventoryRestoreWorkflow(
      loadInventory: { .success([entry]) },
      prepareRestore: { _ in
        do {
          return .success(
            try CleanupQuarantineRestoreAuthorizer().beginAttempt(for: evidence)
          )
        } catch {
          return .failure(.authorization(.invalidPreparedEvidence))
        }
      },
      executeRestore: { _ in
        executionCount.increment()
        throw CancellationError()
      }
    )
    let adapter = CoreQuarantineRecoveryWorkflowAdapter(workflow: coreWorkflow)
    let firstInventory = try requireAdapterInventory(
      await adapter.reconcileAndLoadInventory()
    )
    let prepared = try requireAdapterPreparedRestore(
      await adapter.beginRestore(for: firstInventory.items[0].handle)
    )

    _ = await adapter.reconcileAndLoadInventory()
    let staleResult = await adapter.authorizeAndRestore(
      prepared.handle,
      statement: prepared.requiredStatement
    )

    #expect(
      staleResult
        == .failure(.authorization(.confirmationDoesNotBelongToAttempt))
    )
    #expect(executionCount.value == 0)
  }

  @Test("Adapter-visible values do not reflect the journal transaction ID")
  func projectionsHideTransactionID() async throws {
    let quarantineTransactionID = String(repeating: "b", count: 32)
    let entry = DescriptorQuarantineInventoryEntry(
      quarantineTransactionID: quarantineTransactionID,
      canonicalQuarantineIntentBytes: Data("intent".utf8),
      canonicalQuarantineReceiptBytes: Data("receipt".utf8),
      sourceState: .missing,
      itemState: .available,
      quarantineReceiptWasProducedByRecovery: true
    )
    let coreWorkflow = QuarantineInventoryRestoreWorkflow(
      loadInventory: { .success([entry]) },
      prepareRestore: { _ in .failure(.invalidClaim) },
      executeRestore: { _ in throw CancellationError() }
    )
    let adapter = CoreQuarantineRecoveryWorkflowAdapter(workflow: coreWorkflow)
    let inventory = try requireAdapterInventory(
      await adapter.reconcileAndLoadInventory()
    )

    #expect(inventory.items.count == 1)
    #expect(inventory.items[0].responsibleTool == "npm")
    #expect(inventory.items[0].originalName == "_cacache")
    #expect(!String(reflecting: inventory).contains(quarantineTransactionID))
    #expect(!String(reflecting: inventory.items[0].handle).contains(quarantineTransactionID))
  }
}

private func requireAdapterInventory(
  _ result: Result<QuarantineRecoveryWorkflowInventory, QuarantineInventoryLoadFailure>
) throws -> QuarantineRecoveryWorkflowInventory {
  switch result {
  case .success(let inventory):
    return inventory
  case .failure(let failure):
    Issue.record("Unexpected inventory failure: \(failure)")
    throw RecoveryAdapterTestError.unexpectedInventoryFailure
  }
}

private func requireAdapterPreparedRestore(
  _ result: Result<QuarantineRecoveryPreparedRestore, QuarantineRestorePreparationFailure>
) throws -> QuarantineRecoveryPreparedRestore {
  switch result {
  case .success(let prepared):
    return prepared
  case .failure(let failure):
    Issue.record("Unexpected restore preparation failure: \(failure)")
    throw RecoveryAdapterTestError.unexpectedPreparationFailure
  }
}

private func adapterRestoreAuthorizationEvidence(
  quarantineTransactionID: String
) throws -> CleanupQuarantineRestorePreparedEvidence {
  let intent = QuarantineJournalIntentV1(
    transactionID: quarantineTransactionID,
    npmRootBinding: adapterRestoreBinding(inode: 10),
    quarantineRootBinding: adapterRestoreBinding(inode: 20),
    candidateBinding: adapterRestoreBinding(inode: 30),
    sourceComponents: [Array("_cacache".utf8)],
    destinationComponents: (0..<QuarantineJournalIntentV1.destinationCount).map {
      adapterRestoreItemComponent($0)
    }
  )
  let intentBytes = try QuarantineJournalV1Codec.encode(intent)
  let receipt = try QuarantineJournalV1Codec.makeReceipt(
    outcome: .quarantined,
    selectedDestinationOrdinal: 3,
    producedByRecovery: false,
    canonicalIntentBytes: intentBytes
  )
  let receiptBytes = try QuarantineJournalV1Codec.encode(
    receipt,
    matchingIntentBytes: intentBytes
  )
  let restoreIntent = try QuarantineRestoreJournalV1Codec.makeIntent(
    restoreTransactionID: String(repeating: "a", count: 32),
    canonicalQuarantineIntentBytes: intentBytes,
    canonicalQuarantineReceiptBytes: receiptBytes
  )
  return CleanupQuarantineRestorePreparedEvidence(
    canonicalQuarantineIntentBytes: intentBytes,
    canonicalQuarantineReceiptBytes: receiptBytes,
    restoreIntent: restoreIntent
  )
}

private func adapterRestoreBinding(
  inode: UInt64
) -> QuarantineJournalFileBindingV1 {
  QuarantineJournalFileBindingV1(
    device: 7,
    inode: inode,
    generation: 11,
    birthSeconds: 1_725_000_000,
    birthNanoseconds: 123_456_789,
    kind: .directory,
    ownerUID: 501,
    permissionMode: 0o700,
    flags: 0,
    linkCount: 2
  )
}

private func adapterRestoreItemComponent(_ ordinal: Int) -> [UInt8] {
  let suffix = String(ordinal + 1, radix: 16)
  return Array("item-v1-\(String(repeating: "0", count: 32 - suffix.count))\(suffix)".utf8)
}

private final class RecoveryAdapterCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}

private enum RecoveryAdapterTestError: Error {
  case unexpectedInventoryFailure
  case unexpectedPreparationFailure
}
