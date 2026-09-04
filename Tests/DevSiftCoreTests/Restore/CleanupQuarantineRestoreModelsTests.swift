import Testing

@testable import DevSiftCore

@Suite("Cleanup quarantine restore report contract")
struct CleanupQuarantineRestoreModelsTests {
  @Test("The default report uses restore contract version one")
  func reportContractVersion() throws {
    let expectedRuleRevision = try npmRuleRevision()
    let report = try makeReport(
      status: .notRestored(.cancelled)
    )

    #expect(CleanupQuarantineRestoreReport.currentContractVersion == 1)
    #expect(report.contractVersion == 1)
    #expect(report.quarantineTransactionID == quarantineTransactionID)
    #expect(report.restoreTransactionID == nil)
    #expect(report.path == cacachePath)
    #expect(report.ruleRevision == expectedRuleRevision)
    #expect(!report.cancellationWasObservedAfterRename)
    #expect(!(report as Any is any Encodable))
    #expect(!(report.status as Any is any Encodable))
  }

  @Test("Only a terminal restore receipt is durably recorded")
  func durabilitySemantics() throws {
    let cases: [(CleanupQuarantineRestoreDurabilityState, Bool, Bool)] = [
      (.notRecorded, false, false),
      (.intentRecorded(restoreTransactionID: restoreTransactionID), false, true),
      (
        .receiptRecorded(
          restoreTransactionID: restoreTransactionID,
          producedByRecovery: false
        ),
        true,
        true
      ),
      (
        .receiptRecorded(
          restoreTransactionID: restoreTransactionID,
          producedByRecovery: true
        ),
        true,
        true
      ),
      (.unresolved(restoreTransactionID: restoreTransactionID), false, false),
      (.unresolved(restoreTransactionID: nil), false, false),
    ]

    for (state, expectedDurable, expectedRecoverable) in cases {
      let report = try makeReport(
        status: .notRestored(.cancelled),
        durabilityState: state
      )

      #expect(report.isDurablyRecorded == expectedDurable)
      #expect(report.isCrashRecoverable == expectedRecoverable)
    }
  }

  @Test("A durable receipt distinguishes restored from not restored")
  func restoredAndNotRestoredRemainDistinct() throws {
    let receipt = CleanupQuarantineRestoreDurabilityState.receiptRecorded(
      restoreTransactionID: restoreTransactionID,
      producedByRecovery: false
    )
    let restoredStatus = CleanupQuarantineRestoreStatus.restored(
      source: cacachePath,
      quarantineNameWasRecreated: true
    )
    let notRestoredStatus = CleanupQuarantineRestoreStatus.notRestored(.sourceNameOccupied)
    let restored = try makeReport(
      status: restoredStatus,
      durabilityState: receipt
    )
    let notRestored = try makeReport(
      status: notRestoredStatus,
      durabilityState: receipt
    )
    let restoredWithoutReceipt = try makeReport(
      status: restoredStatus,
      durabilityState: .intentRecorded(restoreTransactionID: restoreTransactionID)
    )

    #expect(restoredStatus != notRestoredStatus)
    #expect(restored.isDurablyRecorded)
    #expect(restored.isDurablyRestored)
    #expect(notRestored.isDurablyRecorded)
    #expect(!notRestored.isDurablyRestored)
    #expect(!restoredWithoutReceipt.isDurablyRecorded)
    #expect(!restoredWithoutReceipt.isDurablyRestored)
  }

  @Test("Restore reports never claim deletion or overwrite")
  func destructiveClaimsRemainFalse() throws {
    let location = CleanupQuarantineLocation(
      relativePath: ScanRelativePath(
        rawComponents: [
          Array(".devsift-quarantine-v1".utf8),
          Array("item-v1-00112233445566778899aabbccddeeff".utf8),
        ]
      ),
      observedIdentity: FileIdentity(device: 7, inode: 11)
    )
    let statuses: [CleanupQuarantineRestoreStatus] = [
      .notRestored(.sourceNameOccupied),
      .restored(source: cacachePath, quarantineNameWasRecreated: false),
      .manualRecoveryRequired(
        quarantineLocation: location,
        reason: .renameOutcomeIndeterminate
      ),
    ]

    for status in statuses {
      let report = try makeReport(status: status)

      #expect(!report.performedPermanentDeletion)
      #expect(!report.overwroteExistingItem)
    }
  }

  @Test("Replacing evidence preserves the originating contract version")
  func replacingPreservesContractVersion() throws {
    let report = try makeReport(
      contractVersion: 41,
      status: .notRestored(.cancelled),
      durabilityState: .notRecorded
    )

    let replaced = report.replacing(
      status: .restored(
        source: cacachePath,
        quarantineNameWasRecreated: false
      ),
      durabilityState: .receiptRecorded(
        restoreTransactionID: restoreTransactionID,
        producedByRecovery: true
      ),
      cancellationWasObservedAfterRename: true
    )

    #expect(replaced.contractVersion == 41)
    #expect(replaced.quarantineTransactionID == report.quarantineTransactionID)
    #expect(replaced.restoreTransactionID == report.restoreTransactionID)
    #expect(replaced.path == report.path)
    #expect(replaced.ruleRevision == report.ruleRevision)
    #expect(replaced.isDurablyRecorded)
    #expect(replaced.isDurablyRestored)
    #expect(replaced.cancellationWasObservedAfterRename)
  }
}

private let quarantineTransactionID = "00112233445566778899aabbccddeeff"
private let restoreTransactionID = "ffeeddccbbaa99887766554433221100"
private let cacachePath = ScanRelativePath(rawComponents: [Array("_cacache".utf8)])

private func npmRuleRevision() throws -> RuleRevision {
  RuleRevision(
    identifier: try #require(RuleIdentifier(rawValue: "devsift.cache.npm")),
    version: try #require(RuleVersion(rawValue: 5))
  )
}

private func makeReport(
  contractVersion: UInt32 = CleanupQuarantineRestoreReport.currentContractVersion,
  status: CleanupQuarantineRestoreStatus,
  durabilityState: CleanupQuarantineRestoreDurabilityState = .notRecorded
) throws -> CleanupQuarantineRestoreReport {
  CleanupQuarantineRestoreReport(
    contractVersion: contractVersion,
    quarantineTransactionID: quarantineTransactionID,
    restoreTransactionID: nil,
    path: cacachePath,
    ruleRevision: try npmRuleRevision(),
    status: status,
    durabilityState: durabilityState
  )
}
