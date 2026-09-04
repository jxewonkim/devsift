import Darwin
import Foundation
import Testing

@testable import DevSiftCore

@Suite("Descriptor quarantine restore recovery", .serialized)
struct DescriptorQuarantineRestoreRecoveryTests {
  @Test(
    "Pending restore intents record each observational terminal outcome",
    arguments: RestoreRecoveryTerminalScenario.allCases
  )
  func recoversTerminalOutcome(_ scenario: RestoreRecoveryTerminalScenario) throws {
    let fixture = try DescriptorRestoreRecoveryFixture()
    defer { fixture.remove() }
    try fixture.arrange(scenario)

    let summary = try requireRestoreRecovery(
      fixture.journal.recover(fixture.filesystem.recoveryRequest())
    )

    let receipt = try #require(summary.recoveredRestoreReceipts.first)
    #expect(summary.recoveredRestoreReceipts.count == 1)
    #expect(summary.recoveredReceipts.isEmpty)
    #expect(summary.validatedTransactionCount == 1)
    #expect(summary.validatedRestoreTransactionCount == 1)
    #expect(receipt.restoreTransactionID == fixture.restoreTransactionID)
    #expect(receipt.outcome == scenario.receiptOutcome)
    #expect(receipt.sourceNameWasOccupied == scenario.sourceNameWasOccupied)
    #expect(receipt.quarantineNameWasRecreated == scenario.quarantineNameWasRecreated)
    #expect(receipt.producedByRecovery)
    #expect(!FileManager.default.fileExists(atPath: fixture.restoreReceiptStageURL.path))
    #expect(FileManager.default.fileExists(atPath: fixture.restoreReceiptURL.path))
    #expect(
      try QuarantineRestoreJournalV1Codec.decodeReceipt(
        Data(contentsOf: fixture.restoreReceiptURL),
        matchingIntentBytes: fixture.restoreIntentBytes
      ) == receipt
    )
  }

  @Test(
    "Ambiguous restore namespaces stay receipt-less and unchanged",
    arguments: RestoreRecoveryAmbiguousScenario.allCases
  )
  func preservesAmbiguousNamespace(_ scenario: RestoreRecoveryAmbiguousScenario) throws {
    let fixture = try DescriptorRestoreRecoveryFixture()
    defer { fixture.remove() }
    let displacedItem = try fixture.arrange(scenario)
    let namesBefore = try fixture.quarantineNames()

    #expect(
      fixture.journal.recover(fixture.filesystem.recoveryRequest())
        == .failure(.recoveryRequired(transactionID: fixture.restoreTransactionID))
    )
    #expect(try fixture.quarantineNames() == namesBefore)
    #expect(try Data(contentsOf: fixture.restoreIntentURL) == fixture.restoreIntentBytes)
    #expect(!FileManager.default.fileExists(atPath: fixture.restoreReceiptStageURL.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.restoreReceiptURL.path))
    #expect(FileManager.default.fileExists(atPath: displacedItem.path))
    #expect(
      FileManager.default.fileExists(atPath: fixture.filesystem.candidateURL.path)
        == scenario.hasSourceOccupant
    )
  }

  @Test("A matching restore receipt stage is promoted without changing its provenance")
  func promotesMatchingRestoreReceiptStage() throws {
    let fixture = try DescriptorRestoreRecoveryFixture()
    defer { fixture.remove() }
    let receipt = try QuarantineRestoreJournalV1Codec.makeReceipt(
      outcome: .notRestored,
      sourceNameWasOccupied: false,
      producedByRecovery: false,
      canonicalRestoreIntentBytes: fixture.restoreIntentBytes
    )
    let receiptBytes = try QuarantineRestoreJournalV1Codec.encode(
      receipt,
      matchingIntentBytes: fixture.restoreIntentBytes
    )
    try restoreRecoveryWriteRecord(receiptBytes, to: fixture.restoreReceiptStageURL)

    let summary = try requireRestoreRecovery(
      fixture.journal.recover(fixture.filesystem.recoveryRequest())
    )

    #expect(summary.recoveredRestoreReceipts == [receipt])
    #expect(!summary.recoveredRestoreReceipts[0].producedByRecovery)
    #expect(summary.validatedRestoreTransactionCount == 1)
    #expect(!FileManager.default.fileExists(atPath: fixture.restoreReceiptStageURL.path))
    #expect(try Data(contentsOf: fixture.restoreReceiptURL) == receiptBytes)
  }

  @Test("A quarantine intent and restore intent cannot both remain pending")
  func rejectsMixedPendingIntentsWithoutPublication() throws {
    let fixture = try DescriptorRestoreRecoveryFixture()
    defer { fixture.remove() }
    let pendingTransactionID = String(repeating: "b", count: 32)
    let pendingIntent = try fixture.filesystem.intent(
      transactionID: pendingTransactionID,
      destinationSeed: 128
    )
    let pendingBytes = try QuarantineJournalV1Codec.encode(pendingIntent)
    let pendingURL = fixture.filesystem.recordURL(".intent-v1-\(pendingTransactionID)")
    try restoreRecoveryWriteRecord(pendingBytes, to: pendingURL)
    let namesBefore = try fixture.quarantineNames()

    #expect(fixture.journal.recover(fixture.filesystem.recoveryRequest()) == .failure(.unsafe))
    #expect(try fixture.quarantineNames() == namesBefore)
    #expect(try Data(contentsOf: pendingURL) == pendingBytes)
    #expect(try Data(contentsOf: fixture.restoreIntentURL) == fixture.restoreIntentBytes)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.filesystem.recordURL(".receipt-v1-\(pendingTransactionID)").path
      ))
    #expect(!FileManager.default.fileExists(atPath: fixture.restoreReceiptURL.path))
  }

  @Test("A not-restored receipt permits a fresh confirmed retry")
  func notRestoredReceiptPermitsRetryPreparation() throws {
    let fixture = try DescriptorRestoreRecoveryFixture()
    defer { fixture.remove() }
    let summary = try requireRestoreRecovery(
      fixture.journal.recover(fixture.filesystem.recoveryRequest())
    )
    #expect(summary.recoveredRestoreReceipts.first?.outcome == .notRestored)

    let retryTransactionID = String(repeating: "d", count: 32)
    let restoreJournal = DescriptorQuarantineRestoreJournal(dependencies: fixture.dependencies)
    let result = restoreJournal.prepare(
      DescriptorQuarantineRestorePreparationRequest(
        recoveryRequest: fixture.filesystem.recoveryRequest(),
        quarantineTransactionID: fixture.quarantineIntent.transactionID,
        restoreTransactionID: retryTransactionID
      ))

    switch result {
    case .success(let evidence):
      #expect(evidence.restoreIntent.restoreTransactionID == retryTransactionID)
      #expect(
        evidence.restoreIntent.quarantineTransactionID == fixture.quarantineIntent.transactionID)
    case .failure(let failure):
      Issue.record("retry preparation failed: \(failure)")
    }
  }

  @Test("A restored receipt permanently refuses another restore attempt")
  func restoredReceiptRefusesRetryPreparation() throws {
    let fixture = try DescriptorRestoreRecoveryFixture()
    defer { fixture.remove() }
    try fixture.arrange(.restored)
    let summary = try requireRestoreRecovery(
      fixture.journal.recover(fixture.filesystem.recoveryRequest())
    )
    #expect(summary.recoveredRestoreReceipts.first?.outcome == .restored)

    let restoreJournal = DescriptorQuarantineRestoreJournal(dependencies: fixture.dependencies)
    #expect(
      restoreJournal.prepare(
        DescriptorQuarantineRestorePreparationRequest(
          recoveryRequest: fixture.filesystem.recoveryRequest(),
          quarantineTransactionID: fixture.quarantineIntent.transactionID,
          restoreTransactionID: String(repeating: "d", count: 32)
        )) == .failure(.alreadyRestored)
    )
  }

  @Test("Safe current metadata drift does not poison a pending restore")
  func safeCurrentMetadataDriftRemainsRecoverable() throws {
    let fixture = try DescriptorRestoreRecoveryFixture()
    defer { fixture.remove() }
    try descriptorJournalTestChmod(fixture.filesystem.rootURL, mode: 0o750)
    try descriptorJournalTestChmod(fixture.quarantineItemURL, mode: 0o500)

    let summary = try requireRestoreRecovery(
      fixture.journal.recover(fixture.filesystem.recoveryRequest())
    )

    #expect(summary.recoveredRestoreReceipts.count == 1)
    #expect(summary.recoveredRestoreReceipts.first?.outcome == .notRestored)
    #expect(summary.recoveredRestoreReceipts.first?.producedByRecovery == true)
  }

  @Test("An unsafe tree cannot publish a restore intent")
  func unsafeTreeIsRejectedBeforeRestoreIntentPublication() async throws {
    let fixture = try DescriptorRestoreRecoveryFixture(publishRestoreIntent: false)
    defer { fixture.remove() }
    let restoreJournal = DescriptorQuarantineRestoreJournal(dependencies: fixture.dependencies)
    let preparation = restoreJournal.prepare(
      DescriptorQuarantineRestorePreparationRequest(
        recoveryRequest: fixture.filesystem.recoveryRequest(),
        quarantineTransactionID: fixture.quarantineIntent.transactionID,
        restoreTransactionID: fixture.restoreTransactionID
      ))
    let evidence: CleanupQuarantineRestorePreparedEvidence
    switch preparation {
    case .success(let value):
      evidence = value
    case .failure(let failure):
      Issue.record("restore preparation unexpectedly failed: \(failure)")
      return
    }
    let authorizationSession = try CleanupQuarantineRestoreAuthorizer().beginAttempt(for: evidence)
    let confirmation = CleanupQuarantineRestoreUserConfirmation(
      request: authorizationSession.confirmationRequest,
      statement: authorizationSession.confirmationRequest.requiredStatement
    )
    let authorization = try await authorizationSession.authorize(using: confirmation)
    let claim = try await authorization.consumeForExecution()

    let unexpected = fixture.quarantineItemURL.appendingPathComponent(
      "unexpected-entry",
      isDirectory: false
    )
    try Data([0x01]).write(to: unexpected, options: [])
    try descriptorJournalTestChmod(unexpected, mode: 0o600)
    let itemDescriptor = Darwin.open(
      fixture.quarantineItemURL.path,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard itemDescriptor >= 0 else {
      throw RestoreRecoveryTestError.posix(errno)
    }
    defer { descriptorCloseIgnoringErrors(itemDescriptor) }

    let result = restoreJournal.begin(
      DescriptorQuarantineRestoreJournalBeginRequest(
        recoveryRequest: fixture.filesystem.recoveryRequest(),
        quarantinedItemDescriptor: itemDescriptor,
        claim: claim
      ))

    switch result {
    case .failure(.quarantinedItemUnsafe):
      break
    case .success:
      Issue.record("unsafe tree unexpectedly published a restore intent")
    case .failure(let failure):
      Issue.record("unexpected restore begin failure: \(failure)")
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.restoreIntentURL.path))
    #expect(
      !FileManager.default.fileExists(
        atPath:
          fixture.filesystem.recordURL(
            ".restore-intent-stage-v1-\(fixture.restoreTransactionID)"
          ).path
      ))
  }
}

enum RestoreRecoveryTerminalScenario: CaseIterable, Sendable {
  case notRestored
  case notRestoredWithOccupiedSource
  case restored
  case restoredWithRecreatedQuarantineName

  var receiptOutcome: QuarantineRestoreJournalReceiptOutcomeV1 {
    switch self {
    case .notRestored, .notRestoredWithOccupiedSource:
      return .notRestored
    case .restored, .restoredWithRecreatedQuarantineName:
      return .restored
    }
  }

  var sourceNameWasOccupied: Bool {
    self == .notRestoredWithOccupiedSource
  }

  var quarantineNameWasRecreated: Bool {
    self == .restoredWithRecreatedQuarantineName
  }
}

enum RestoreRecoveryAmbiguousScenario: CaseIterable, Sendable {
  case bothNamesMissing
  case occupiedSourceAndMissingQuarantineItem

  var hasSourceOccupant: Bool {
    self == .occupiedSourceAndMissingQuarantineItem
  }
}

private final class DescriptorRestoreRecoveryFixture {
  let filesystem: DescriptorJournalTestFixture
  let dependencies: DescriptorQuarantineJournalDependencies
  let journal: DescriptorQuarantineJournal
  let quarantineIntent: QuarantineJournalIntentV1
  let quarantineIntentBytes: Data
  let quarantineReceiptBytes: Data
  let restoreTransactionID = String(repeating: "c", count: 32)
  let restoreIntent: QuarantineRestoreJournalIntentV1
  let restoreIntentBytes: Data
  let quarantineItemURL: URL

  var restoreIntentURL: URL {
    filesystem.recordURL(".restore-intent-v1-\(restoreTransactionID)")
  }

  var restoreReceiptStageURL: URL {
    filesystem.recordURL(".restore-receipt-stage-v1-\(restoreTransactionID)")
  }

  var restoreReceiptURL: URL {
    filesystem.recordURL(".restore-receipt-v1-\(restoreTransactionID)")
  }

  init(publishRestoreIntent: Bool = true) throws {
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
    let selectedOrdinal = 4
    let quarantineItemURL = try restoreRecoveryURL(
      parent: filesystem.quarantineURL,
      componentBytes: session.intent.destinationComponents[selectedOrdinal]
    )
    try FileManager.default.moveItem(at: filesystem.candidateURL, to: quarantineItemURL)
    let receipt: QuarantineJournalReceiptV1
    switch journal.finish(
      session,
      outcome: .quarantined(
        selectedDestinationOrdinal: selectedOrdinal,
        sourceNameWasRecreated: false
      ),
      namespaceMutationMayHaveBeenInvoked: true
    ) {
    case .receiptRecorded(let value):
      receipt = value
    case .recoveryRequired(let transactionID):
      throw RestoreRecoveryTestError.unexpectedResult("quarantine recovery \(transactionID)")
    case .unresolved(let transactionID):
      throw RestoreRecoveryTestError.unexpectedResult("quarantine unresolved \(transactionID)")
    case .invalidSession:
      throw RestoreRecoveryTestError.unexpectedResult("invalid quarantine session")
    }

    let quarantineIntentBytes = session.canonicalIntentBytes
    let quarantineReceiptURL = filesystem.recordURL(
      ".receipt-v1-\(session.intent.transactionID)"
    )
    let quarantineReceiptBytes = try Data(contentsOf: quarantineReceiptURL)
    guard
      try QuarantineJournalV1Codec.decodeReceipt(
        quarantineReceiptBytes,
        matchingIntentBytes: quarantineIntentBytes
      ) == receipt
    else {
      throw RestoreRecoveryTestError.invalidRecord
    }
    let restoreIntent = try QuarantineRestoreJournalV1Codec.makeIntent(
      restoreTransactionID: restoreTransactionID,
      canonicalQuarantineIntentBytes: quarantineIntentBytes,
      canonicalQuarantineReceiptBytes: quarantineReceiptBytes
    )
    let restoreIntentBytes = try QuarantineRestoreJournalV1Codec.encode(
      restoreIntent,
      matchingQuarantineIntentBytes: quarantineIntentBytes,
      matchingQuarantineReceiptBytes: quarantineReceiptBytes
    )
    if publishRestoreIntent {
      try restoreRecoveryWriteRecord(
        restoreIntentBytes,
        to: filesystem.recordURL(".restore-intent-v1-\(restoreTransactionID)")
      )
    }

    self.filesystem = filesystem
    self.dependencies = dependencies
    self.journal = journal
    quarantineIntent = session.intent
    self.quarantineIntentBytes = quarantineIntentBytes
    self.quarantineReceiptBytes = quarantineReceiptBytes
    self.restoreIntent = restoreIntent
    self.restoreIntentBytes = restoreIntentBytes
    self.quarantineItemURL = quarantineItemURL
  }

  func arrange(_ scenario: RestoreRecoveryTerminalScenario) throws {
    switch scenario {
    case .notRestored:
      break
    case .notRestoredWithOccupiedSource:
      try createDirectory(at: filesystem.candidateURL)
    case .restored:
      try FileManager.default.moveItem(at: quarantineItemURL, to: filesystem.candidateURL)
    case .restoredWithRecreatedQuarantineName:
      try FileManager.default.moveItem(at: quarantineItemURL, to: filesystem.candidateURL)
      try createDirectory(at: quarantineItemURL)
    }
  }

  func arrange(_ scenario: RestoreRecoveryAmbiguousScenario) throws -> URL {
    let displacedItem = filesystem.baseURL.appendingPathComponent(
      "displaced-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.moveItem(at: quarantineItemURL, to: displacedItem)
    if scenario.hasSourceOccupant {
      try createDirectory(at: filesystem.candidateURL)
    }
    return displacedItem
  }

  func quarantineNames() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: filesystem.quarantineURL.path).sorted()
  }

  func remove() {
    filesystem.remove()
  }

  private func createDirectory(at url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    try descriptorJournalTestChmod(url, mode: 0o700)
  }
}

private enum RestoreRecoveryTestError: Error {
  case invalidPath
  case invalidRecord
  case unexpectedResult(String)
  case recovery(DescriptorQuarantineJournalFailure)
  case posix(Int32)
}

private func restoreRecoveryURL(parent: URL, componentBytes: [UInt8]) throws -> URL {
  guard let component = String(bytes: componentBytes, encoding: .utf8) else {
    throw RestoreRecoveryTestError.invalidPath
  }
  return parent.appendingPathComponent(component, isDirectory: true)
}

private func restoreRecoveryWriteRecord(_ bytes: Data, to url: URL) throws {
  try bytes.write(to: url, options: [])
  try descriptorJournalTestChmod(url, mode: 0o600)
}

private func requireRestoreRecovery(
  _ result: DescriptorQuarantineJournalRecoveryResult
) throws -> DescriptorQuarantineJournalRecoverySummary {
  switch result {
  case .success(let summary):
    return summary
  case .failure(let failure):
    throw RestoreRecoveryTestError.recovery(failure)
  }
}
