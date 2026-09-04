import Testing

@testable import DevSiftCore

@Suite("Cleanup quarantine execution report contract")
struct CleanupQuarantineExecutionContractTests {
  @Test("Version one remains process-local, non-durable, and non-deleting")
  func processLocalBoundary() throws {
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
      status: .quarantinedAwaitingReceipt(
        location: location,
        sourceNameWasRecreated: false
      ),
      quarantineRootMutation: .created,
      cancellationWasObservedAfterRename: true
    )

    #expect(report.contractVersion == 1)
    #expect(report.path.rawComponents == [Array("_cacache".utf8)])
    #expect(location.relativePath.rawComponents.count == 2)
    #expect(!report.isDurablyRecorded)
    #expect(!report.isCrashRecoverable)
    #expect(!report.performedPermanentDeletion)
    #expect(!(report as Any is any Encodable))
    #expect(!(location as Any is any Encodable))
    #expect(!(report.status as Any is any Encodable))
  }
}
