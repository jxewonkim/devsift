import Testing

@testable import DevSiftCore

@Suite("Cleanup quarantine execution report contract")
struct CleanupQuarantineExecutionContractTests {
  @Test("Version two distinguishes receipt, intent, and unresolved durability")
  func durableBoundary() throws {
    let revision = RuleRevision(
      identifier: try #require(RuleIdentifier(rawValue: "devsift.cache.npm")),
      version: try #require(RuleVersion(rawValue: 5))
    )
    let location = CleanupQuarantineLocation(
      relativePath: ScanRelativePath(
        rawComponents: [
          Array(".devsift-quarantine-v1".utf8),
          Array("item-v1-00112233445566778899aabbccddeeff".utf8),
        ]
      ),
      observedIdentity: FileIdentity(device: 7, inode: 11)
    )
    let report = CleanupQuarantineExecutionReport(
      path: ScanRelativePath(rawComponents: [Array("_cacache".utf8)]),
      ruleRevision: revision,
      status: .quarantined(
        location: location,
        sourceNameWasRecreated: false
      ),
      durabilityState: .receiptRecorded(
        transactionID: "00112233445566778899aabbccddeeff",
        producedByRecovery: false
      ),
      quarantineRootMutation: .created,
      cancellationWasObservedAfterRename: true
    )

    #expect(report.contractVersion == 2)
    #expect(report.path.rawComponents == [Array("_cacache".utf8)])
    #expect(location.relativePath.rawComponents.count == 2)
    #expect(report.isDurablyRecorded)
    #expect(report.isCrashRecoverable)
    #expect(!report.performedPermanentDeletion)
    #expect(!(report as Any is any Encodable))
    #expect(!(location as Any is any Encodable))
    #expect(!(report.status as Any is any Encodable))
  }

  @Test("Only a terminal receipt is durably recorded")
  func durabilityStates() throws {
    let revision = RuleRevision(
      identifier: try #require(RuleIdentifier(rawValue: "devsift.cache.npm")),
      version: try #require(RuleVersion(rawValue: 5))
    )
    let path = ScanRelativePath(rawComponents: [Array("_cacache".utf8)])

    for (state, durable, recoverable) in [
      (CleanupQuarantineDurabilityState.notRecorded, false, false),
      (.intentRecorded(transactionID: "00"), false, true),
      (.receiptRecorded(transactionID: "00", producedByRecovery: true), true, true),
      (.unresolved(transactionID: "00"), false, false),
      (.unresolved(transactionID: nil), false, false),
    ] {
      let report = CleanupQuarantineExecutionReport(
        path: path,
        ruleRevision: revision,
        status: .notMoved(.cancelled),
        durabilityState: state,
        quarantineRootMutation: .none
      )
      #expect(report.isDurablyRecorded == durable)
      #expect(report.isCrashRecoverable == recoverable)
      #expect(!report.performedPermanentDeletion)
    }
  }

  @Test("Replacing evidence preserves the report's originating contract version")
  func replacingPreservesContractVersion() throws {
    let report = CleanupQuarantineExecutionReport(
      contractVersion: 1,
      path: ScanRelativePath(rawComponents: [Array("_cacache".utf8)]),
      ruleRevision: RuleRevision(
        identifier: try #require(RuleIdentifier(rawValue: "devsift.cache.npm")),
        version: try #require(RuleVersion(rawValue: 5))
      ),
      status: .notMoved(.cancelled),
      quarantineRootMutation: .none
    )

    let replaced = report.replacing(
      durabilityState: .unresolved(transactionID: String(repeating: "a", count: 32))
    )

    #expect(replaced.contractVersion == 1)
  }
}
