import Darwin
import Foundation
import Testing

@testable import DevSiftCore

@Suite("Descriptor quarantine purge inventory", .serialized)
struct DescriptorQuarantinePurgeInventoryTests {
  @Test(
    "All five purge namespace names are recognized without being mutated",
    arguments: PurgeManagedNameScenario.allCases
  )
  func recognizesManagedNames(_ scenario: PurgeManagedNameScenario) throws {
    let fixture = try DescriptorPurgeInventoryFixture()
    defer { fixture.remove() }
    try fixture.arrange(scenario)
    let namesBefore = try fixture.quarantineNames()

    let result = fixture.journal.recover(fixture.filesystem.recoveryRequest())

    switch scenario {
    case .intentStage, .receiptFinal:
      _ = try requirePurgeInventoryRecovery(result)
    case .intentFinal, .receiptStage, .work:
      #expect(
        result
          == .failure(
            .recoveryRequired(transactionID: fixture.purgeTransactionID)
          ))
    }
    #expect(try fixture.quarantineNames() == namesBefore)
  }

  @Test(
    "Every conflicting or orphaned purge stage and final combination fails closed",
    arguments: PurgeInventoryConflictScenario.allCases
  )
  func rejectsConflictingRecords(_ scenario: PurgeInventoryConflictScenario) throws {
    let fixture = try DescriptorPurgeInventoryFixture()
    defer { fixture.remove() }
    try fixture.arrange(scenario)
    let namesBefore = try fixture.quarantineNames()

    #expect(
      fixture.journal.recover(fixture.filesystem.recoveryRequest())
        == .failure(.unsafe)
    )
    #expect(try fixture.quarantineNames() == namesBefore)
  }

  @Test("A structurally canonical purge intent must bind the exact quarantine pair")
  func rejectsPurgeIntentWithDifferentQuarantineDigest() throws {
    let fixture = try DescriptorPurgeInventoryFixture()
    defer { fixture.remove() }
    var mismatchedDigest = fixture.purgeIntent.quarantineReceiptDigest
    mismatchedDigest[0] ^= 0xff
    let mismatchedIntent = QuarantinePurgeJournalIntentV1(
      purgeTransactionID: fixture.purgeIntent.purgeTransactionID,
      quarantineTransactionID: fixture.purgeIntent.quarantineTransactionID,
      quarantineIntentDigest: fixture.purgeIntent.quarantineIntentDigest,
      quarantineReceiptDigest: mismatchedDigest,
      npmRootBinding: fixture.purgeIntent.npmRootBinding,
      quarantineRootBinding: fixture.purgeIntent.quarantineRootBinding,
      candidateBinding: fixture.purgeIntent.candidateBinding,
      sourceComponents: fixture.purgeIntent.sourceComponents,
      quarantineItemComponent: fixture.purgeIntent.quarantineItemComponent,
      purgeWorkComponent: fixture.purgeIntent.purgeWorkComponent,
      purgePolicyRevision: fixture.purgeIntent.purgePolicyRevision,
      capacityBefore: fixture.purgeIntent.capacityBefore
    )
    try fixture.writePurgeIntent(
      try QuarantinePurgeJournalV1Codec.encode(mismatchedIntent),
      staged: false
    )

    #expect(
      fixture.journal.recover(fixture.filesystem.recoveryRequest())
        == .failure(.unsafe)
    )
  }

  @Test("A canonical purge receipt must bind the exact final purge intent bytes")
  func rejectsPurgeReceiptWithDifferentIntentDigest() throws {
    let fixture = try DescriptorPurgeInventoryFixture()
    defer { fixture.remove() }
    try fixture.writePurgeIntent(fixture.purgeIntentBytes, staged: false)
    let receipt = try fixture.purgeReceipt(outcome: .notPurged)
    var mismatchedDigest = receipt.purgeIntentDigest
    mismatchedDigest[0] ^= 0xff
    let mismatchedReceipt = QuarantinePurgeJournalReceiptV1(
      purgeTransactionID: receipt.purgeTransactionID,
      purgeIntentDigest: mismatchedDigest,
      outcome: receipt.outcome,
      quarantineNameWasRecreated: receipt.quarantineNameWasRecreated,
      producedByRecovery: receipt.producedByRecovery,
      capacityObservationProvenance: receipt.capacityObservationProvenance,
      capacityAfter: receipt.capacityAfter
    )
    try fixture.writePurgeReceipt(
      try QuarantinePurgeJournalV1Codec.encode(mismatchedReceipt),
      staged: false
    )

    #expect(
      fixture.journal.recover(fixture.filesystem.recoveryRequest())
        == .failure(.unsafe)
    )
  }

  @Test("A purge intent and restore intent cannot both remain pending")
  func rejectsPurgeAndRestorePendingIntents() throws {
    let fixture = try DescriptorPurgeInventoryFixture()
    defer { fixture.remove() }
    try fixture.writePurgeIntent(fixture.purgeIntentBytes, staged: false)
    try fixture.writeRestoreIntent()

    #expect(
      fixture.journal.recover(fixture.filesystem.recoveryRequest())
        == .failure(.unsafe)
    )
  }

  @Test("A purge intent and quarantine intent cannot both remain pending")
  func rejectsPurgeAndQuarantinePendingIntents() throws {
    let fixture = try DescriptorPurgeInventoryFixture()
    defer { fixture.remove() }
    try fixture.writePurgeIntent(fixture.purgeIntentBytes, staged: false)
    try fixture.writePendingQuarantineIntent()

    #expect(
      fixture.journal.recover(fixture.filesystem.recoveryRequest())
        == .failure(.unsafe)
    )
  }

  @Test(
    "A purge transaction ID cannot reuse a quarantine or restore transaction ID",
    arguments: PurgeCrossFamilyIdentifierScenario.allCases
  )
  func rejectsCrossFamilyPurgeIdentifierReuse(
    _ scenario: PurgeCrossFamilyIdentifierScenario
  ) throws {
    let fixture = try DescriptorPurgeInventoryFixture()
    defer { fixture.remove() }
    try fixture.writePurgeIntent(fixture.purgeIntentBytes, staged: false)
    try fixture.writeInertCrossFamilyRecord(scenario)

    #expect(
      fixture.journal.recover(fixture.filesystem.recoveryRequest())
        == .failure(.unsafe)
    )
  }

  @Test("Multiple terminal item-absent receipts for one quarantine transaction are unsafe")
  func rejectsDuplicateItemAbsentReceipts() throws {
    let fixture = try DescriptorPurgeInventoryFixture()
    defer { fixture.remove() }
    try FileManager.default.removeItem(at: fixture.quarantineItemURL)
    try fixture.writeCompletedPurge(
      intent: fixture.purgeIntent,
      intentBytes: fixture.purgeIntentBytes,
      outcome: .itemAbsent
    )
    let alternate = try fixture.alternatePurgeIntent()
    try fixture.writeCompletedPurge(
      intent: alternate.intent,
      intentBytes: alternate.bytes,
      outcome: .itemAbsent
    )

    #expect(
      fixture.journal.recover(fixture.filesystem.recoveryRequest())
        == .failure(.unsafe)
    )
  }

  @Test("Canonical not-purged history permits another completed attempt and restore")
  func allowsNotPurgedHistoryAndRestore() throws {
    let fixture = try DescriptorPurgeInventoryFixture()
    defer { fixture.remove() }
    try fixture.writeCompletedPurge(
      intent: fixture.purgeIntent,
      intentBytes: fixture.purgeIntentBytes,
      outcome: .notPurged
    )
    let alternate = try fixture.alternatePurgeIntent()
    try fixture.writeCompletedPurge(
      intent: alternate.intent,
      intentBytes: alternate.bytes,
      outcome: .notPurged
    )

    _ = try requirePurgeInventoryRecovery(
      fixture.journal.recover(fixture.filesystem.recoveryRequest())
    )
    switch fixture.restoreJournal.prepare(fixture.restorePreparationRequest()) {
    case .success:
      break
    case .failure(let failure):
      Issue.record("not-purged history unexpectedly blocked restore: \(failure)")
    }
  }

  @Test("A pending purge intent blocks restore until purge reconciliation")
  func pendingPurgeBlocksRestore() throws {
    let fixture = try DescriptorPurgeInventoryFixture()
    defer { fixture.remove() }
    try fixture.writePurgeIntent(fixture.purgeIntentBytes, staged: false)

    #expect(
      fixture.restoreJournal.prepare(fixture.restorePreparationRequest())
        == .failure(
          .journal(
            .recoveryRequired(transactionID: fixture.purgeTransactionID)
          ))
    )
  }

  @Test("A purge-work item blocks inventory projection and restore")
  func purgeWorkBlocksInventoryAndRestore() throws {
    let fixture = try DescriptorPurgeInventoryFixture()
    defer { fixture.remove() }
    try fixture.arrange(.work)

    #expect(
      descriptorJournalReconcileAndLoadInventory(
        fixture.filesystem.recoveryRequest(),
        dependencies: fixture.dependencies
      )
        == .failure(
          .journal(
            .recoveryRequired(transactionID: fixture.purgeTransactionID)
          ))
    )
    #expect(
      fixture.restoreJournal.prepare(fixture.restorePreparationRequest())
        == .failure(
          .journal(
            .recoveryRequired(transactionID: fixture.purgeTransactionID)
          ))
    )
  }

  @Test("A terminal item-absent receipt permanently blocks restore")
  func itemAbsentPurgeBlocksRestore() throws {
    let fixture = try DescriptorPurgeInventoryFixture()
    defer { fixture.remove() }
    try FileManager.default.removeItem(at: fixture.quarantineItemURL)
    try fixture.writeCompletedPurge(
      intent: fixture.purgeIntent,
      intentBytes: fixture.purgeIntentBytes,
      outcome: .itemAbsent
    )

    _ = try requirePurgeInventoryRecovery(
      fixture.journal.recover(fixture.filesystem.recoveryRequest())
    )
    #expect(
      fixture.restoreJournal.prepare(fixture.restorePreparationRequest())
        == .failure(.transactionNotRestorable)
    )
  }
}

enum PurgeManagedNameScenario: CaseIterable, Sendable {
  case intentStage
  case intentFinal
  case receiptStage
  case receiptFinal
  case work
}

enum PurgeInventoryConflictScenario: CaseIterable, Sendable {
  case intentStageAndFinal
  case receiptStageAndFinal
  case workAndReceiptStage
  case workAndReceiptFinal
  case orphanReceiptStage
  case orphanReceiptFinal
  case orphanWork
}

enum PurgeCrossFamilyIdentifierScenario: CaseIterable, Sendable {
  case quarantine
  case restore
}

private final class DescriptorPurgeInventoryFixture {
  let filesystem: DescriptorJournalTestFixture
  let dependencies: DescriptorQuarantineJournalDependencies
  let journal: DescriptorQuarantineJournal
  let restoreJournal: DescriptorQuarantineRestoreJournal
  let quarantineIntent: QuarantineJournalIntentV1
  let quarantineIntentBytes: Data
  let quarantineReceiptBytes: Data
  let quarantineItemURL: URL
  let purgeTransactionID: String
  let alternatePurgeTransactionID: String
  let restoreTransactionID: String
  let pendingQuarantineTransactionID: String
  let purgeIntent: QuarantinePurgeJournalIntentV1
  let purgeIntentBytes: Data

  init() throws {
    let purgeTransactionID = String(repeating: "b", count: 32)
    let alternatePurgeTransactionID = String(repeating: "c", count: 32)
    let restoreTransactionID = String(repeating: "d", count: 32)
    let pendingQuarantineTransactionID = String(repeating: "e", count: 32)
    let filesystem = try DescriptorJournalTestFixture()
    for requiredName in ["content-v2", "index-v5"] {
      let requiredDirectory = filesystem.candidateURL.appendingPathComponent(
        requiredName,
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: requiredDirectory,
        withIntermediateDirectories: false
      )
      try descriptorJournalTestChmod(requiredDirectory, mode: 0o700)
    }
    let dependencies = descriptorJournalTestDependencies()
    let journal = DescriptorQuarantineJournal(dependencies: dependencies)
    let session = try filesystem.requireSession(from: journal)
    let selectedDestinationOrdinal = 4
    let quarantineItemURL = try purgeInventoryURL(
      parent: filesystem.quarantineURL,
      componentBytes: session.intent.destinationComponents[selectedDestinationOrdinal]
    )
    try FileManager.default.moveItem(at: filesystem.candidateURL, to: quarantineItemURL)
    switch journal.finish(
      session,
      outcome: .quarantined(
        selectedDestinationOrdinal: selectedDestinationOrdinal,
        sourceNameWasRecreated: false
      ),
      namespaceMutationMayHaveBeenInvoked: true
    ) {
    case .receiptRecorded:
      break
    case .recoveryRequired(let transactionID):
      throw PurgeInventoryTestError.unexpectedResult("quarantine recovery \(transactionID)")
    case .unresolved(let transactionID):
      throw PurgeInventoryTestError.unexpectedResult("quarantine unresolved \(transactionID)")
    case .invalidSession:
      throw PurgeInventoryTestError.unexpectedResult("invalid quarantine session")
    }

    let quarantineIntentBytes = session.canonicalIntentBytes
    let quarantineReceiptBytes = try Data(
      contentsOf: filesystem.recordURL(".receipt-v1-\(session.intent.transactionID)")
    )
    let purgeIntent = try QuarantinePurgeJournalV1Codec.makeIntent(
      purgeTransactionID: purgeTransactionID,
      capacityBefore: purgeCapacityObservation(for: session.intent),
      canonicalQuarantineIntentBytes: quarantineIntentBytes,
      canonicalQuarantineReceiptBytes: quarantineReceiptBytes
    )
    let purgeIntentBytes = try QuarantinePurgeJournalV1Codec.encode(
      purgeIntent,
      matchingQuarantineIntentBytes: quarantineIntentBytes,
      matchingQuarantineReceiptBytes: quarantineReceiptBytes
    )

    self.filesystem = filesystem
    self.dependencies = dependencies
    self.journal = journal
    restoreJournal = DescriptorQuarantineRestoreJournal(dependencies: dependencies)
    quarantineIntent = session.intent
    self.quarantineIntentBytes = quarantineIntentBytes
    self.quarantineReceiptBytes = quarantineReceiptBytes
    self.quarantineItemURL = quarantineItemURL
    self.purgeTransactionID = purgeTransactionID
    self.alternatePurgeTransactionID = alternatePurgeTransactionID
    self.restoreTransactionID = restoreTransactionID
    self.pendingQuarantineTransactionID = pendingQuarantineTransactionID
    self.purgeIntent = purgeIntent
    self.purgeIntentBytes = purgeIntentBytes
  }

  func arrange(_ scenario: PurgeManagedNameScenario) throws {
    switch scenario {
    case .intentStage:
      try writePurgeIntent(purgeIntentBytes, staged: true)
    case .intentFinal:
      try writePurgeIntent(purgeIntentBytes, staged: false)
    case .receiptStage:
      try writePurgeIntent(purgeIntentBytes, staged: false)
      try writePurgeReceipt(
        try purgeReceiptBytes(outcome: .notPurged, intentBytes: purgeIntentBytes),
        staged: true
      )
    case .receiptFinal:
      try writeCompletedPurge(
        intent: purgeIntent,
        intentBytes: purgeIntentBytes,
        outcome: .notPurged
      )
    case .work:
      try writePurgeIntent(purgeIntentBytes, staged: false)
      try FileManager.default.moveItem(at: quarantineItemURL, to: purgeWorkURL(for: purgeIntent))
    }
  }

  func arrange(_ scenario: PurgeInventoryConflictScenario) throws {
    switch scenario {
    case .intentStageAndFinal:
      try writePurgeIntent(purgeIntentBytes, staged: true)
      try writePurgeIntent(purgeIntentBytes, staged: false)
    case .receiptStageAndFinal:
      try writePurgeIntent(purgeIntentBytes, staged: false)
      let receiptBytes = try purgeReceiptBytes(
        outcome: .notPurged,
        intentBytes: purgeIntentBytes
      )
      try writePurgeReceipt(receiptBytes, staged: true)
      try writePurgeReceipt(receiptBytes, staged: false)
    case .workAndReceiptStage:
      try writePurgeIntent(purgeIntentBytes, staged: false)
      try FileManager.default.moveItem(at: quarantineItemURL, to: purgeWorkURL(for: purgeIntent))
      try writePurgeReceipt(
        try purgeReceiptBytes(outcome: .itemAbsent, intentBytes: purgeIntentBytes),
        staged: true
      )
    case .workAndReceiptFinal:
      try writePurgeIntent(purgeIntentBytes, staged: false)
      try FileManager.default.moveItem(at: quarantineItemURL, to: purgeWorkURL(for: purgeIntent))
      try writePurgeReceipt(
        try purgeReceiptBytes(outcome: .itemAbsent, intentBytes: purgeIntentBytes),
        staged: false
      )
    case .orphanReceiptStage:
      try writePurgeReceipt(
        try purgeReceiptBytes(outcome: .notPurged, intentBytes: purgeIntentBytes),
        staged: true
      )
    case .orphanReceiptFinal:
      try writePurgeReceipt(
        try purgeReceiptBytes(outcome: .notPurged, intentBytes: purgeIntentBytes),
        staged: false
      )
    case .orphanWork:
      try FileManager.default.createDirectory(
        at: purgeWorkURL(for: purgeIntent),
        withIntermediateDirectories: false
      )
      try descriptorJournalTestChmod(purgeWorkURL(for: purgeIntent), mode: 0o700)
    }
  }

  func alternatePurgeIntent() throws -> (
    intent: QuarantinePurgeJournalIntentV1,
    bytes: Data
  ) {
    let intent = try QuarantinePurgeJournalV1Codec.makeIntent(
      purgeTransactionID: alternatePurgeTransactionID,
      capacityBefore: purgeCapacityObservation(for: quarantineIntent),
      canonicalQuarantineIntentBytes: quarantineIntentBytes,
      canonicalQuarantineReceiptBytes: quarantineReceiptBytes
    )
    return (
      intent,
      try QuarantinePurgeJournalV1Codec.encode(
        intent,
        matchingQuarantineIntentBytes: quarantineIntentBytes,
        matchingQuarantineReceiptBytes: quarantineReceiptBytes
      )
    )
  }

  func purgeReceipt(
    outcome: QuarantinePurgeJournalReceiptOutcomeV1,
    intentBytes: Data? = nil
  ) throws -> QuarantinePurgeJournalReceiptV1 {
    try QuarantinePurgeJournalV1Codec.makeReceipt(
      outcome: outcome,
      producedByRecovery: false,
      capacityObservationProvenance: .initialAttempt,
      capacityAfter: .unavailable,
      canonicalPurgeIntentBytes: intentBytes ?? purgeIntentBytes
    )
  }

  func purgeReceiptBytes(
    outcome: QuarantinePurgeJournalReceiptOutcomeV1,
    intentBytes: Data
  ) throws -> Data {
    let receipt = try purgeReceipt(outcome: outcome, intentBytes: intentBytes)
    return try QuarantinePurgeJournalV1Codec.encode(
      receipt,
      matchingIntentBytes: intentBytes
    )
  }

  func writeCompletedPurge(
    intent: QuarantinePurgeJournalIntentV1,
    intentBytes: Data,
    outcome: QuarantinePurgeJournalReceiptOutcomeV1
  ) throws {
    try writePurgeIntent(intentBytes, staged: false, transactionID: intent.purgeTransactionID)
    try writePurgeReceipt(
      try purgeReceiptBytes(outcome: outcome, intentBytes: intentBytes),
      staged: false,
      transactionID: intent.purgeTransactionID
    )
  }

  func writePurgeIntent(
    _ bytes: Data,
    staged: Bool,
    transactionID: String? = nil
  ) throws {
    let prefix = staged ? ".purge-intent-stage-v1-" : ".purge-intent-v1-"
    try purgeInventoryWriteRecord(
      bytes,
      to: filesystem.recordURL("\(prefix)\(transactionID ?? purgeTransactionID)")
    )
  }

  func writePurgeReceipt(
    _ bytes: Data,
    staged: Bool,
    transactionID: String? = nil
  ) throws {
    let prefix = staged ? ".purge-receipt-stage-v1-" : ".purge-receipt-v1-"
    try purgeInventoryWriteRecord(
      bytes,
      to: filesystem.recordURL("\(prefix)\(transactionID ?? purgeTransactionID)")
    )
  }

  func writeRestoreIntent() throws {
    let intent = try QuarantineRestoreJournalV1Codec.makeIntent(
      restoreTransactionID: restoreTransactionID,
      canonicalQuarantineIntentBytes: quarantineIntentBytes,
      canonicalQuarantineReceiptBytes: quarantineReceiptBytes
    )
    let bytes = try QuarantineRestoreJournalV1Codec.encode(
      intent,
      matchingQuarantineIntentBytes: quarantineIntentBytes,
      matchingQuarantineReceiptBytes: quarantineReceiptBytes
    )
    try purgeInventoryWriteRecord(
      bytes,
      to: filesystem.recordURL(".restore-intent-v1-\(restoreTransactionID)")
    )
  }

  func writePendingQuarantineIntent() throws {
    let intent = try filesystem.intent(
      transactionID: pendingQuarantineTransactionID,
      destinationSeed: 1_000
    )
    try purgeInventoryWriteRecord(
      try QuarantineJournalV1Codec.encode(intent),
      to: filesystem.recordURL(".intent-v1-\(pendingQuarantineTransactionID)")
    )
  }

  func writeInertCrossFamilyRecord(
    _ scenario: PurgeCrossFamilyIdentifierScenario
  ) throws {
    switch scenario {
    case .quarantine:
      let intent = try filesystem.intent(
        transactionID: purgeTransactionID,
        destinationSeed: 2_000
      )
      try purgeInventoryWriteRecord(
        try QuarantineJournalV1Codec.encode(intent),
        to: filesystem.recordURL(".intent-stage-v1-\(purgeTransactionID)")
      )
    case .restore:
      let intent = try QuarantineRestoreJournalV1Codec.makeIntent(
        restoreTransactionID: purgeTransactionID,
        canonicalQuarantineIntentBytes: quarantineIntentBytes,
        canonicalQuarantineReceiptBytes: quarantineReceiptBytes
      )
      let bytes = try QuarantineRestoreJournalV1Codec.encode(
        intent,
        matchingQuarantineIntentBytes: quarantineIntentBytes,
        matchingQuarantineReceiptBytes: quarantineReceiptBytes
      )
      try purgeInventoryWriteRecord(
        bytes,
        to: filesystem.recordURL(".restore-intent-stage-v1-\(purgeTransactionID)")
      )
    }
  }

  func restorePreparationRequest() -> DescriptorQuarantineRestorePreparationRequest {
    DescriptorQuarantineRestorePreparationRequest(
      recoveryRequest: filesystem.recoveryRequest(),
      quarantineTransactionID: quarantineIntent.transactionID,
      restoreTransactionID: restoreTransactionID,
      expectedCanonicalQuarantineIntentBytes: quarantineIntentBytes,
      expectedCanonicalQuarantineReceiptBytes: quarantineReceiptBytes
    )
  }

  func purgeWorkURL(for intent: QuarantinePurgeJournalIntentV1) throws -> URL {
    try purgeInventoryURL(
      parent: filesystem.quarantineURL,
      componentBytes: intent.purgeWorkComponent
    )
  }

  func quarantineNames() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: filesystem.quarantineURL.path).sorted()
  }

  func remove() {
    filesystem.remove()
  }
}

private enum PurgeInventoryTestError: Error {
  case invalidPath
  case recovery(DescriptorQuarantineJournalFailure)
  case unexpectedResult(String)
}

private func purgeCapacityObservation(
  for intent: QuarantineJournalIntentV1
) -> QuarantinePurgeCapacityObservationV1 {
  QuarantinePurgeCapacityObservationV1(
    volumeIdentity: QuarantinePurgeVolumeIdentityV1(
      device: intent.candidateBinding.device,
      fileSystemIDFirst: 17,
      fileSystemIDSecond: 23
    ),
    availableBytes: 1_000_000
  )
}

private func purgeInventoryURL(parent: URL, componentBytes: [UInt8]) throws -> URL {
  guard let component = String(bytes: componentBytes, encoding: .utf8) else {
    throw PurgeInventoryTestError.invalidPath
  }
  return parent.appendingPathComponent(component)
}

private func purgeInventoryWriteRecord(_ bytes: Data, to url: URL) throws {
  try bytes.write(to: url, options: [])
  try descriptorJournalTestChmod(url, mode: 0o600)
}

private func requirePurgeInventoryRecovery(
  _ result: DescriptorQuarantineJournalRecoveryResult
) throws -> DescriptorQuarantineJournalRecoverySummary {
  switch result {
  case .success(let summary):
    return summary
  case .failure(let failure):
    throw PurgeInventoryTestError.recovery(failure)
  }
}
