import Darwin
import Foundation
import Testing

@testable import DevSiftCore

@Suite("Descriptor quarantine recovery", .serialized)
struct DescriptorQuarantineRecoveryTests {
  @Test("A pending intent with the expected source records recovered not-moved")
  func recoversNotMoved() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )
    try abandonIntent(fixture, journal: journal)

    let summary = try requireRecovery(journal.recover(fixture.recoveryRequest()))

    #expect(summary.recoveredReceipts.count == 1)
    #expect(summary.recoveredReceipts[0].outcome == .notMoved)
    #expect(summary.recoveredReceipts[0].producedByRecovery)
    #expect(FileManager.default.fileExists(atPath: fixture.candidateURL.path))
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.recordURL(".receipt-v1-\(fixture.transactionID)").path
      ))
  }

  @Test("A pending intent with one expected destination records recovered quarantine")
  func recoversQuarantinedMove() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )
    let intent = try fixture.intent()
    try abandonIntent(fixture, journal: journal)
    try moveCandidate(fixture, to: intent.destinationComponents[4])

    let summary = try requireRecovery(journal.recover(fixture.recoveryRequest()))

    #expect(summary.recoveredReceipts.count == 1)
    #expect(summary.recoveredReceipts[0].outcome == .quarantined)
    #expect(summary.recoveredReceipts[0].selectedDestinationOrdinal == 4)
    #expect(!summary.recoveredReceipts[0].sourceNameWasRecreated)
    #expect(summary.recoveredReceipts[0].producedByRecovery)
  }

  @Test("Recovery records a recreated source without adopting it")
  func recoversQuarantineWithRecreatedSource() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )
    let intent = try fixture.intent()
    try abandonIntent(fixture, journal: journal)
    try moveCandidate(fixture, to: intent.destinationComponents[2])
    try FileManager.default.createDirectory(
      at: fixture.candidateURL,
      withIntermediateDirectories: false
    )
    try descriptorJournalTestChmod(fixture.candidateURL, mode: 0o700)

    let summary = try requireRecovery(journal.recover(fixture.recoveryRequest()))

    #expect(summary.recoveredReceipts.count == 1)
    #expect(summary.recoveredReceipts[0].outcome == .quarantined)
    #expect(summary.recoveredReceipts[0].selectedDestinationOrdinal == 2)
    #expect(summary.recoveredReceipts[0].sourceNameWasRecreated)
    #expect(FileManager.default.fileExists(atPath: fixture.candidateURL.path))
  }

  @Test("An ambiguous pending namespace stays receipt-less")
  func ambiguousPendingIntentBlocks() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )
    try abandonIntent(fixture, journal: journal)
    let unplanned = fixture.baseURL.appendingPathComponent("unplanned", isDirectory: true)
    try FileManager.default.moveItem(at: fixture.candidateURL, to: unplanned)

    #expect(
      journal.recover(fixture.recoveryRequest())
        == .failure(.recoveryRequired(transactionID: fixture.transactionID))
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.recordURL(".receipt-v1-\(fixture.transactionID)").path
      ))
    #expect(FileManager.default.fileExists(atPath: unplanned.path))
  }

  @Test("A canonical intent stage is inert and preserved")
  func intentStageIsInert() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    try prepareExistingLock(fixture)
    let intent = try fixture.intent()
    let stageURL = fixture.recordURL(".intent-stage-v1-\(fixture.transactionID)")
    try writeRecord(try QuarantineJournalV1Codec.encode(intent), to: stageURL)
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )

    let summary = try requireRecovery(journal.recover(fixture.recoveryRequest()))

    #expect(summary.recoveredReceipts.isEmpty)
    #expect(summary.validatedTransactionCount == 0)
    #expect(FileManager.default.fileExists(atPath: stageURL.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.recordURL(".intent-v1-\(fixture.transactionID)").path
      ))
  }

  @Test("A canonical historical-policy intent stage remains inert")
  func historicalPolicyIntentStageIsInert() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    try prepareExistingLock(fixture)
    let historicalBytes = try historicalIntentBytes(fixture.intent())
    let historicalIntent = try QuarantineJournalV1Codec.decodeIntent(historicalBytes)
    let stageURL = fixture.recordURL(".intent-stage-v1-\(fixture.transactionID)")
    try writeRecord(historicalBytes, to: stageURL)
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )

    let summary = try requireRecovery(journal.recover(fixture.recoveryRequest()))

    #expect(historicalIntent.policy == descriptorJournalTestHistoricalPolicy())
    #expect(summary.validatedTransactionCount == 0)
    #expect(summary.recoveredReceipts.isEmpty)
    #expect(try Data(contentsOf: stageURL) == historicalBytes)
  }

  @Test("Malformed staged state blocks recovery without deleting it")
  func malformedStageBlocks() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    try prepareExistingLock(fixture)
    let stageURL = fixture.recordURL(".intent-stage-v1-\(fixture.transactionID)")
    try writeRecord(Data("{}".utf8), to: stageURL)
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )

    #expect(journal.recover(fixture.recoveryRequest()) == .failure(.unsafe))
    #expect(try Data(contentsOf: stageURL) == Data("{}".utf8))
  }

  @Test("A matching receipt stage is promoted only after terminal truth is proved")
  func promotesMatchingReceiptStage() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )
    var session: DescriptorQuarantineJournalSession? = try fixture.requireSession(from: journal)
    let intentBytes = session!.canonicalIntentBytes
    let receipt = try QuarantineJournalV1Codec.makeReceipt(
      outcome: .notMoved,
      producedByRecovery: false,
      canonicalIntentBytes: intentBytes
    )
    let receiptBytes = try QuarantineJournalV1Codec.encode(
      receipt,
      matchingIntentBytes: intentBytes
    )
    let stageURL = fixture.recordURL(".receipt-stage-v1-\(fixture.transactionID)")
    try writeRecord(receiptBytes, to: stageURL)
    session = nil

    let summary = try requireRecovery(journal.recover(fixture.recoveryRequest()))

    #expect(summary.recoveredReceipts == [receipt])
    #expect(!summary.recoveredReceipts[0].producedByRecovery)
    #expect(!FileManager.default.fileExists(atPath: stageURL.path))
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.recordURL(".receipt-v1-\(fixture.transactionID)").path
      ))
  }

  @Test("A receipt stage that conflicts with live truth is preserved without promotion")
  func receiptStageTruthMismatchBlocksWithoutMutation() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )
    var session: DescriptorQuarantineJournalSession? = try fixture.requireSession(from: journal)
    let intent = session!.intent
    let intentBytes = session!.canonicalIntentBytes
    let receipt = try QuarantineJournalV1Codec.makeReceipt(
      outcome: .notMoved,
      producedByRecovery: false,
      canonicalIntentBytes: intentBytes
    )
    let receiptBytes = try QuarantineJournalV1Codec.encode(
      receipt,
      matchingIntentBytes: intentBytes
    )
    let intentURL = fixture.recordURL(".intent-v1-\(fixture.transactionID)")
    let stageURL = fixture.recordURL(".receipt-stage-v1-\(fixture.transactionID)")
    let finalURL = fixture.recordURL(".receipt-v1-\(fixture.transactionID)")
    try writeRecord(receiptBytes, to: stageURL)
    try moveCandidate(fixture, to: intent.destinationComponents[4])
    let destination = try #require(DescriptorPathComponent(intent.destinationComponents[4]))
    let destinationURL = fixture.quarantineURL.appendingPathComponent(
      try #require(String(bytes: destination.bytes, encoding: .utf8))
    )
    let namesBefore = try FileManager.default.contentsOfDirectory(
      atPath: fixture.quarantineURL.path
    ).sorted()
    session = nil

    #expect(
      journal.recover(fixture.recoveryRequest())
        == .failure(.recoveryRequired(transactionID: fixture.transactionID))
    )
    #expect(try Data(contentsOf: intentURL) == intentBytes)
    #expect(try Data(contentsOf: stageURL) == receiptBytes)
    #expect(!FileManager.default.fileExists(atPath: finalURL.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.candidateURL.path))
    #expect(FileManager.default.fileExists(atPath: destinationURL.path))
    let destinationSnapshot = try DescriptorStatSnapshot.read(
      at: fixture.quarantineDescriptor,
      component: destination,
      cancellationPolicy: .ignoreTaskCancellation
    )
    #expect(
      QuarantineJournalFileBindingV1(snapshot: destinationSnapshot) == intent.candidateBinding)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.quarantineURL.path).sorted()
        == namesBefore
    )
  }

  @Test(
    "Pending-intent recovery fails closed at every full-sync position",
    arguments: [1, 2, 3, 4, 5, 6, 7, 8, 9]
  )
  func pendingIntentRecoveryFullSyncFailureSweep(failurePosition: Int) throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let setupJournal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )
    try abandonIntent(fixture, journal: setupJournal)
    let intentURL = fixture.recordURL(".intent-v1-\(fixture.transactionID)")
    let intentBytes = try Data(contentsOf: intentURL)
    let syncs = DescriptorJournalTestSyncProbe(failingCall: failurePosition)
    let recoveryJournal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies(fullSync: { descriptor in
        syncs.result(for: descriptor)
      })
    )

    #expect(recoveryFails(recoveryJournal.recover(fixture.recoveryRequest())))

    let expectedCallCount =
      [1, 5].contains(failurePosition)
      ? failurePosition + 1
      : failurePosition
    #expect(syncs.descriptors.count == expectedCallCount)
    #expect(try Data(contentsOf: intentURL) == intentBytes)
    try expectCanonicalReceiptIfPresent(
      fixture,
      matchingIntentBytes: intentBytes,
      producedByRecovery: true
    )
    #expect(FileManager.default.fileExists(atPath: fixture.candidateURL.path))
  }

  @Test(
    "Receipt-stage promotion fails closed at every full-sync position",
    arguments: [1, 2, 3, 4, 5, 6, 7, 8, 9]
  )
  func receiptStagePromotionFullSyncFailureSweep(failurePosition: Int) throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let setupJournal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )
    var session: DescriptorQuarantineJournalSession? = try fixture.requireSession(
      from: setupJournal
    )
    let intentBytes = session!.canonicalIntentBytes
    let receipt = try QuarantineJournalV1Codec.makeReceipt(
      outcome: .notMoved,
      producedByRecovery: false,
      canonicalIntentBytes: intentBytes
    )
    let receiptBytes = try QuarantineJournalV1Codec.encode(
      receipt,
      matchingIntentBytes: intentBytes
    )
    try writeRecord(
      receiptBytes,
      to: fixture.recordURL(".receipt-stage-v1-\(fixture.transactionID)")
    )
    session = nil
    let syncs = DescriptorJournalTestSyncProbe(failingCall: failurePosition)
    let recoveryJournal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies(fullSync: { descriptor in
        syncs.result(for: descriptor)
      })
    )

    #expect(recoveryFails(recoveryJournal.recover(fixture.recoveryRequest())))

    let expectedCallCount =
      [1, 5].contains(failurePosition)
      ? failurePosition + 1
      : failurePosition
    #expect(syncs.descriptors.count == expectedCallCount)
    #expect(
      try Data(contentsOf: fixture.recordURL(".intent-v1-\(fixture.transactionID)"))
        == intentBytes
    )
    try expectCanonicalReceiptIfPresent(
      fixture,
      matchingIntentBytes: intentBytes,
      producedByRecovery: false
    )
    #expect(FileManager.default.fileExists(atPath: fixture.candidateURL.path))
  }

  @Test("A completed receipt remains historical when the later namespace changes")
  func completedReceiptDoesNotReassertLiveTruth() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )
    let session = try fixture.requireSession(from: journal)
    guard
      case .receiptRecorded = journal.finish(
        session,
        outcome: .notMoved,
        namespaceMutationMayHaveBeenInvoked: false
      )
    else {
      Issue.record("could not prepare completed receipt")
      return
    }
    try FileManager.default.moveItem(
      at: fixture.candidateURL,
      to: fixture.baseURL.appendingPathComponent("changed", isDirectory: true)
    )

    let summary = try requireRecovery(journal.recover(fixture.recoveryRequest()))

    #expect(summary.validatedTransactionCount == 1)
    #expect(summary.recoveredReceipts.isEmpty)
  }

  @Test("A completed historical-policy transaction remains readable")
  func completedHistoricalPolicyReceiptValidates() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    try prepareExistingLock(fixture)
    let intentBytes = try historicalIntentBytes(fixture.intent())
    let receipt = try QuarantineJournalV1Codec.makeReceipt(
      outcome: .notMoved,
      producedByRecovery: false,
      canonicalIntentBytes: intentBytes
    )
    let receiptBytes = try QuarantineJournalV1Codec.encode(
      receipt,
      matchingIntentBytes: intentBytes
    )
    try writeRecord(
      intentBytes,
      to: fixture.recordURL(".intent-v1-\(fixture.transactionID)")
    )
    try writeRecord(
      receiptBytes,
      to: fixture.recordURL(".receipt-v1-\(fixture.transactionID)")
    )
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )

    let summary = try requireRecovery(journal.recover(fixture.recoveryRequest()))

    #expect(summary.validatedTransactionCount == 1)
    #expect(summary.recoveredReceipts.isEmpty)
    #expect(
      try QuarantineJournalV1Codec.decodeIntent(intentBytes).policy
        == descriptorJournalTestHistoricalPolicy()
    )
  }

  @Test("A historical receipt accepts a later stricter safe npm-root mode")
  func completedReceiptAcceptsSafeRootModeChange() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer {
      try? descriptorJournalTestChmod(fixture.rootURL, mode: 0o700)
      fixture.remove()
    }
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )
    let session = try fixture.requireSession(from: journal)
    guard
      case .receiptRecorded = journal.finish(
        session,
        outcome: .notMoved,
        namespaceMutationMayHaveBeenInvoked: false
      )
    else {
      Issue.record("could not prepare completed receipt")
      return
    }
    try descriptorJournalTestChmod(fixture.rootURL, mode: 0o500)

    let summary = try requireRecovery(journal.recover(fixture.recoveryRequest()))

    #expect(summary.validatedTransactionCount == 1)
    #expect(summary.recoveredReceipts.isEmpty)
  }

  @Test("A historical receipt still rejects replacement of its bound npm root")
  func completedReceiptRejectsRootIdentityReplacement() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let setupJournal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )
    let session = try fixture.requireSession(from: setupJournal)
    guard
      case .receiptRecorded = setupJournal.finish(
        session,
        outcome: .notMoved,
        namespaceMutationMayHaveBeenInvoked: false
      )
    else {
      Issue.record("could not prepare completed receipt")
      return
    }
    let intentName = ".intent-v1-\(fixture.transactionID)"
    let receiptName = ".receipt-v1-\(fixture.transactionID)"
    let intentBytes = try Data(contentsOf: fixture.recordURL(intentName))
    let receiptBytes = try Data(contentsOf: fixture.recordURL(receiptName))
    let displacedRoot = fixture.baseURL.appendingPathComponent("displaced-npm")
    try FileManager.default.moveItem(at: fixture.rootURL, to: displacedRoot)
    try FileManager.default.createDirectory(
      at: fixture.rootURL,
      withIntermediateDirectories: false
    )
    try descriptorJournalTestChmod(fixture.rootURL, mode: 0o700)
    try FileManager.default.createDirectory(
      at: fixture.quarantineURL,
      withIntermediateDirectories: false
    )
    try descriptorJournalTestChmod(fixture.quarantineURL, mode: 0o700)
    try prepareExistingLock(fixture)
    try writeRecord(intentBytes, to: fixture.recordURL(intentName))
    try writeRecord(receiptBytes, to: fixture.recordURL(receiptName))
    let rawHome = Array(fixture.baseURL.path.utf8)
    let startup = DescriptorNPMQuarantineRecovery(
      journal: DescriptorQuarantineJournal(
        dependencies: descriptorJournalTestDependencies()
      ),
      rawHomeProvider: { .known(rawHome) },
      accountUIDProvider: { .known(Darwin.getuid()) },
      supportsDurableMutation: { true }
    )

    #expect(startup.recover() == .failure(.unsafe))
    #expect(
      try Data(
        contentsOf:
          displacedRoot
          .appendingPathComponent(".devsift-quarantine-v1")
          .appendingPathComponent(intentName)
      ) == intentBytes
    )
    #expect(
      try Data(
        contentsOf:
          displacedRoot
          .appendingPathComponent(".devsift-quarantine-v1")
          .appendingPathComponent(receiptName)
      ) == receiptBytes
    )
    #expect(try Data(contentsOf: fixture.recordURL(intentName)) == intentBytes)
    #expect(try Data(contentsOf: fixture.recordURL(receiptName)) == receiptBytes)
    #expect(
      FileManager.default.fileExists(
        atPath: displacedRoot.appendingPathComponent("_cacache").path
      )
    )
  }

  @Test("Startup recovery reaches a moved candidate without preflight")
  func startupRecoveryDoesNotRequireCandidateName() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )
    let intent = try fixture.intent()
    try abandonIntent(fixture, journal: journal)
    try moveCandidate(fixture, to: intent.destinationComponents[0])
    let rawHome = Array(fixture.baseURL.path.utf8)
    let startup = DescriptorNPMQuarantineRecovery(
      journal: journal,
      rawHomeProvider: { .known(rawHome) },
      accountUIDProvider: { .known(Darwin.getuid()) },
      supportsDurableMutation: { true }
    )

    let summary = try requireRecovery(startup.recover())

    #expect(summary.recoveredReceipts.count == 1)
    #expect(summary.recoveredReceipts[0].outcome == .quarantined)
  }

  @Test("Startup recovery does not create a missing quarantine root")
  func startupRecoveryDoesNotCreateQuarantineRoot() throws {
    let fixture = try DescriptorJournalTestFixture(createQuarantine: false)
    defer { fixture.remove() }
    let recoveryCalls = DescriptorJournalTestCounter()
    let rawHome = Array(fixture.baseURL.path.utf8)
    let startup = DescriptorNPMQuarantineRecovery(
      journal: descriptorJournalInjectedRecovery(counter: recoveryCalls),
      rawHomeProvider: { .known(rawHome) },
      accountUIDProvider: { .known(Darwin.getuid()) },
      supportsDurableMutation: { true }
    )

    let summary = try requireRecovery(startup.recover())

    #expect(summary.validatedTransactionCount == 0)
    #expect(recoveryCalls.callCount == 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.quarantineURL.path))
  }

  @Test("The startup OS gate runs before journal mutation")
  func startupRecoveryHonorsMutationGate() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let recoveryCalls = DescriptorJournalTestCounter()
    let rawHome = Array(fixture.baseURL.path.utf8)
    let startup = DescriptorNPMQuarantineRecovery(
      journal: descriptorJournalInjectedRecovery(counter: recoveryCalls),
      rawHomeProvider: { .known(rawHome) },
      accountUIDProvider: { .known(Darwin.getuid()) },
      supportsDurableMutation: { false }
    )

    #expect(startup.recover() == .failure(.unavailable(.unsupported)))
    #expect(recoveryCalls.callCount == 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.recordURL(".lock-v1").path))
  }

  @Test("Startup recovery permits an ACL on the enclosing home only")
  func startupRecoveryAllowsProtectedHomeACL() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    try installCurrentUserReadACL(at: fixture.baseURL)
    let rawHome = Array(fixture.baseURL.path.utf8)
    let startup = DescriptorNPMQuarantineRecovery(
      journal: DescriptorQuarantineJournal(
        dependencies: descriptorJournalTestDependencies()
      ),
      rawHomeProvider: { .known(rawHome) },
      accountUIDProvider: { .known(Darwin.getuid()) },
      supportsDurableMutation: { true }
    )

    let summary = try requireRecovery(startup.recover())

    #expect(summary.validatedTransactionCount == 0)
    #expect(FileManager.default.fileExists(atPath: fixture.recordURL(".lock-v1").path))
  }

  @Test("A nonempty journal without its lock is preserved and rejected")
  func missingLockWithExistingStateBlocksWithoutBootstrapMutation() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let existingURL = fixture.recordURL("unmanaged-existing-state")
    let existingBytes = Data("sentinel".utf8)
    try writeRecord(existingBytes, to: existingURL)
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )

    #expect(journal.recover(fixture.recoveryRequest()) == .failure(.unsafe))
    #expect(try Data(contentsOf: existingURL) == existingBytes)
    #expect(!FileManager.default.fileExists(atPath: fixture.recordURL(".lock-v1").path))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.quarantineURL.path)
        == ["unmanaged-existing-state"]
    )
  }

  @Test("A quarantine-root mutation during inventory read fails closed")
  func inventoryRootMutationFailsClosed() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    try prepareExistingLock(fixture)
    let firstIntent = try fixture.intent()
    let firstBytes = try QuarantineJournalV1Codec.encode(firstIntent)
    let firstURL = fixture.recordURL(".intent-stage-v1-\(fixture.transactionID)")
    try writeRecord(firstBytes, to: firstURL)
    let secondID = String(repeating: "b", count: 32)
    let secondIntent = try fixture.intent(transactionID: secondID, destinationSeed: 100)
    let secondBytes = try QuarantineJournalV1Codec.encode(secondIntent)
    let secondURL = fixture.recordURL(".intent-stage-v1-\(secondID)")
    let mutation = DescriptorJournalTestOneShot()
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies(
        hooks: DescriptorQuarantineJournalHooks(
          didEnumerateInventory: {
            mutation.run {
              try? secondBytes.write(to: secondURL, options: [])
              try? descriptorJournalTestChmod(secondURL, mode: 0o600)
            }
          }
        )
      )
    )

    #expect(journal.recover(fixture.recoveryRequest()) == .failure(.unsafe))
    #expect(try Data(contentsOf: firstURL) == firstBytes)
    #expect(try Data(contentsOf: secondURL) == secondBytes)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.recordURL(".receipt-v1-\(fixture.transactionID)").path
      )
    )
    #expect(FileManager.default.fileExists(atPath: fixture.candidateURL.path))
  }

  @Test("A symlink record fails closed without touching its target")
  func symlinkRecordFailsClosed() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    try prepareExistingLock(fixture)
    let target = fixture.baseURL.appendingPathComponent("record-target")
    let targetBytes = Data("outside-sentinel".utf8)
    try targetBytes.write(to: target)
    let stage = fixture.recordURL(".intent-stage-v1-\(fixture.transactionID)")
    try FileManager.default.createSymbolicLink(
      atPath: stage.path,
      withDestinationPath: target.path
    )
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )

    #expect(recoveryFails(journal.recover(fixture.recoveryRequest())))
    #expect(try Data(contentsOf: target) == targetBytes)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: stage.path) == target.path)
    #expect(FileManager.default.fileExists(atPath: fixture.candidateURL.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.recordURL(".receipt-v1-\(fixture.transactionID)").path
      ))
  }

  @Test("A hard-linked record fails closed and preserves both names")
  func hardLinkedRecordFailsClosed() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    try prepareExistingLock(fixture)
    let intent = try fixture.intent()
    let bytes = try QuarantineJournalV1Codec.encode(intent)
    let stage = fixture.recordURL(".intent-stage-v1-\(fixture.transactionID)")
    let outsideLink = fixture.baseURL.appendingPathComponent("outside-hard-link")
    try writeRecord(bytes, to: stage)
    guard Darwin.link(stage.path, outsideLink.path) == 0 else {
      throw DescriptorJournalTestError.posix(errno)
    }
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )

    #expect(journal.recover(fixture.recoveryRequest()) == .failure(.unsafe))
    #expect(try Data(contentsOf: stage) == bytes)
    #expect(try Data(contentsOf: outsideLink) == bytes)
    #expect(FileManager.default.fileExists(atPath: fixture.candidateURL.path))
  }

  @Test("A record with permissive mode fails closed and is not rewritten")
  func permissiveRecordModeFailsClosed() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    try prepareExistingLock(fixture)
    let intent = try fixture.intent()
    let bytes = try QuarantineJournalV1Codec.encode(intent)
    let stage = fixture.recordURL(".intent-stage-v1-\(fixture.transactionID)")
    try writeRecord(bytes, to: stage)
    try descriptorJournalTestChmod(stage, mode: 0o644)
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )

    #expect(journal.recover(fixture.recoveryRequest()) == .failure(.unsafe))
    #expect(try Data(contentsOf: stage) == bytes)
    #expect(try descriptorJournalTestMode(at: stage) == mode_t(0o644))
    #expect(FileManager.default.fileExists(atPath: fixture.candidateURL.path))
  }

  @Test("A record with a real extended ACL fails closed and is preserved")
  func extendedACLRecordFailsClosed() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    try prepareExistingLock(fixture)
    let intent = try fixture.intent()
    let bytes = try QuarantineJournalV1Codec.encode(intent)
    let stage = fixture.recordURL(".intent-stage-v1-\(fixture.transactionID)")
    try writeRecord(bytes, to: stage)
    try installCurrentUserReadACL(at: stage)
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )

    #expect(journal.recover(fixture.recoveryRequest()) == .failure(.unsafe))
    #expect(try Data(contentsOf: stage) == bytes)
    let descriptor = Darwin.open(stage.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw DescriptorJournalTestError.posix(errno) }
    defer { descriptorCloseIgnoringErrors(descriptor) }
    #expect(try descriptorHasExtendedACL(descriptor))
    #expect(FileManager.default.fileExists(atPath: fixture.candidateURL.path))
  }

  @Test("An orphan final receipt blocks and remains byte-for-byte intact")
  func orphanReceiptBlocks() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    try prepareExistingLock(fixture)
    let intentBytes = try QuarantineJournalV1Codec.encode(fixture.intent())
    let receipt = try QuarantineJournalV1Codec.makeReceipt(
      outcome: .notMoved,
      producedByRecovery: false,
      canonicalIntentBytes: intentBytes
    )
    let receiptBytes = try QuarantineJournalV1Codec.encode(
      receipt,
      matchingIntentBytes: intentBytes
    )
    let receiptURL = fixture.recordURL(".receipt-v1-\(fixture.transactionID)")
    try writeRecord(receiptBytes, to: receiptURL)
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )

    #expect(journal.recover(fixture.recoveryRequest()) == .failure(.unsafe))
    #expect(try Data(contentsOf: receiptURL) == receiptBytes)
    #expect(FileManager.default.fileExists(atPath: fixture.candidateURL.path))
  }

  @Test("An orphan staged receipt blocks and is never promoted")
  func orphanReceiptStageBlocks() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    try prepareExistingLock(fixture)
    let intentBytes = try QuarantineJournalV1Codec.encode(fixture.intent())
    let receipt = try QuarantineJournalV1Codec.makeReceipt(
      outcome: .notMoved,
      producedByRecovery: false,
      canonicalIntentBytes: intentBytes
    )
    let receiptBytes = try QuarantineJournalV1Codec.encode(
      receipt,
      matchingIntentBytes: intentBytes
    )
    let stageURL = fixture.recordURL(".receipt-stage-v1-\(fixture.transactionID)")
    try writeRecord(receiptBytes, to: stageURL)
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )

    #expect(journal.recover(fixture.recoveryRequest()) == .failure(.unsafe))
    #expect(try Data(contentsOf: stageURL) == receiptBytes)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.recordURL(".receipt-v1-\(fixture.transactionID)").path
      ))
  }

  @Test("A final receipt and receipt stage conflict without overwriting either")
  func finalAndStagedReceiptConflict() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )
    let session = try fixture.requireSession(from: journal)
    guard
      case .receiptRecorded = journal.finish(
        session,
        outcome: .notMoved,
        namespaceMutationMayHaveBeenInvoked: false
      )
    else {
      Issue.record("could not prepare completed receipt")
      return
    }
    let finalURL = fixture.recordURL(".receipt-v1-\(fixture.transactionID)")
    let finalBytes = try Data(contentsOf: finalURL)
    let stageURL = fixture.recordURL(".receipt-stage-v1-\(fixture.transactionID)")
    try writeRecord(finalBytes, to: stageURL)

    #expect(journal.recover(fixture.recoveryRequest()) == .failure(.unsafe))
    #expect(try Data(contentsOf: finalURL) == finalBytes)
    #expect(try Data(contentsOf: stageURL) == finalBytes)
  }

  @Test("Multiple pending final intents block before any receipt publication")
  func multiplePendingIntentsBlockWithoutMutation() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    try prepareExistingLock(fixture)
    let firstIntent = try fixture.intent()
    let secondIntent = try fixture.intent(
      transactionID: String(repeating: "b", count: 32),
      destinationSeed: 100
    )
    let firstBytes = try QuarantineJournalV1Codec.encode(firstIntent)
    let secondBytes = try QuarantineJournalV1Codec.encode(secondIntent)
    let firstURL = fixture.recordURL(".intent-v1-\(firstIntent.transactionID)")
    let secondURL = fixture.recordURL(".intent-v1-\(secondIntent.transactionID)")
    try writeRecord(firstBytes, to: firstURL)
    try writeRecord(secondBytes, to: secondURL)
    let publicationEvents = DescriptorJournalTestCounter()
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies(
        hooks: DescriptorQuarantineJournalHooks(
          willPublishStage: { _, _ in _ = publicationEvents.result() }
        )
      )
    )

    #expect(journal.recover(fixture.recoveryRequest()) == .failure(.unsafe))
    #expect(publicationEvents.callCount == 0)
    #expect(try Data(contentsOf: firstURL) == firstBytes)
    #expect(try Data(contentsOf: secondURL) == secondBytes)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.quarantineURL.path).sorted()
        == [
          ".intent-v1-\(firstIntent.transactionID)",
          ".intent-v1-\(secondIntent.transactionID)",
          ".lock-v1",
        ]
    )
    #expect(FileManager.default.fileExists(atPath: fixture.candidateURL.path))
  }

  @Test("A historical not-moved receipt cannot poison a later quarantine transaction")
  func sequentialTransactionsRemainRecoverable() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )
    let first = try fixture.requireSession(from: journal)
    guard
      case .receiptRecorded = journal.finish(
        first,
        outcome: .notMoved,
        namespaceMutationMayHaveBeenInvoked: false
      )
    else {
      Issue.record("could not record the first transaction")
      return
    }

    let secondIntent = try fixture.intent(
      transactionID: String(repeating: "b", count: 32),
      destinationSeed: 100
    )
    let second: DescriptorQuarantineJournalSession
    switch journal.begin(fixture.beginRequest(intent: secondIntent)) {
    case .success(let session):
      second = session
    case .failure(let failure):
      Issue.record("second begin failed: \(failure)")
      return
    }
    try moveCandidate(fixture, to: secondIntent.destinationComponents[3])
    guard
      case .receiptRecorded = journal.finish(
        second,
        outcome: .quarantined(
          selectedDestinationOrdinal: 3,
          sourceNameWasRecreated: false
        ),
        namespaceMutationMayHaveBeenInvoked: true
      )
    else {
      Issue.record("could not record the second transaction")
      return
    }

    let summary = try requireRecovery(journal.recover(fixture.recoveryRequest()))

    #expect(summary.validatedTransactionCount == 2)
    #expect(summary.recoveredReceipts.isEmpty)
  }

  @Test("The recovery inventory accepts exactly 4,096 managed entries")
  func inventoryAcceptsExactEntryBound() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    try prepareExistingLock(fixture)
    let templateIntent = try fixture.intent()
    let templateBytes = try QuarantineJournalV1Codec.encode(templateIntent)
    for ordinal in 1...4_095 {
      let transactionID = descriptorJournalTestTransactionID(ordinal)
      let bytes = try replacingTransactionID(
        in: templateBytes,
        from: templateIntent.transactionID,
        to: transactionID
      )
      try writeRecord(
        bytes,
        to: fixture.recordURL(".intent-stage-v1-\(transactionID)")
      )
    }
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )

    let summary = try requireRecovery(journal.recover(fixture.recoveryRequest()))

    #expect(summary.validatedTransactionCount == 0)
    #expect(summary.recoveredReceipts.isEmpty)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.quarantineURL.path).count
        == 4_096
    )
  }

  @Test("A canonical receipt stage promotes count-neutrally at 4,096 entries")
  func receiptStagePromotionAtExactEntryBound() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    try prepareExistingLock(fixture)
    let intent = try fixture.intent()
    let intentBytes = try QuarantineJournalV1Codec.encode(intent)
    let receipt = try QuarantineJournalV1Codec.makeReceipt(
      outcome: .notMoved,
      producedByRecovery: false,
      canonicalIntentBytes: intentBytes
    )
    let receiptBytes = try QuarantineJournalV1Codec.encode(
      receipt,
      matchingIntentBytes: intentBytes
    )
    let intentURL = fixture.recordURL(".intent-v1-\(fixture.transactionID)")
    let stageURL = fixture.recordURL(".receipt-stage-v1-\(fixture.transactionID)")
    let finalURL = fixture.recordURL(".receipt-v1-\(fixture.transactionID)")
    try writeRecord(intentBytes, to: intentURL)
    try writeRecord(receiptBytes, to: stageURL)
    try populateCanonicalIntentStages(fixture, count: 4_093)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.quarantineURL.path).count
        == 4_096
    )
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )

    let summary = try requireRecovery(journal.recover(fixture.recoveryRequest()))

    #expect(summary.recoveredReceipts == [receipt])
    #expect(summary.validatedTransactionCount == 1)
    #expect(!FileManager.default.fileExists(atPath: stageURL.path))
    #expect(try Data(contentsOf: finalURL) == receiptBytes)
    #expect(try Data(contentsOf: intentURL) == intentBytes)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.quarantineURL.path).count
        == 4_096
    )
    #expect(FileManager.default.fileExists(atPath: fixture.candidateURL.path))
  }

  @Test("The 4,097th recovery entry fails with the resource limit and preserves all names")
  func inventoryRejectsEntryBeyondBound() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    try prepareExistingLock(fixture)
    for ordinal in 1...4_096 {
      let transactionID = descriptorJournalTestTransactionID(ordinal)
      let created = FileManager.default.createFile(
        atPath: fixture.recordURL(".intent-stage-v1-\(transactionID)").path,
        contents: Data(),
        attributes: [.posixPermissions: 0o600]
      )
      guard created else { throw DescriptorJournalTestError.invalidSnapshot }
    }
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )

    #expect(
      journal.recover(fixture.recoveryRequest())
        == .failure(.unavailable(.resourceLimit))
    )
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.quarantineURL.path).count
        == 4_097
    )
    #expect(FileManager.default.fileExists(atPath: fixture.candidateURL.path))
  }

  @Test("A new transaction reserves intent, item, and receipt capacity before publication")
  func newTransactionRejectsInsufficientTerminalCapacity() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    try prepareExistingLock(fixture)
    try populateCanonicalIntentStages(fixture, count: 4_093)
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )

    switch journal.begin(fixture.beginRequest()) {
    case .failure(.unavailable(.resourceLimit)):
      break
    case .failure(let failure):
      Issue.record("unexpected failure: \(failure)")
    case .success:
      Issue.record("begin failed to reserve worst-case terminal capacity")
    }

    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.recordURL(".intent-v1-\(fixture.transactionID)").path
      )
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.recordURL(".intent-stage-v1-\(fixture.transactionID)").path
      )
    )
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.quarantineURL.path).count
        == 4_094
    )
    #expect(FileManager.default.fileExists(atPath: fixture.candidateURL.path))
  }

  @Test("A new transaction admits the exact 4,096-entry terminal peak")
  func newTransactionAcceptsExactTerminalCapacity() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    try prepareExistingLock(fixture)
    try populateCanonicalIntentStages(fixture, count: 4_092)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.quarantineURL.path).count
        == 4_093
    )
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )
    var session: DescriptorQuarantineJournalSession?

    switch journal.begin(fixture.beginRequest()) {
    case .success(let value):
      session = value
    case .failure(let failure):
      Issue.record("exact terminal capacity was rejected: \(failure)")
      return
    }

    #expect(session?.transactionID == fixture.transactionID)
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.recordURL(".intent-v1-\(fixture.transactionID)").path
      )
    )
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.quarantineURL.path).count
        == 4_094
    )
    #expect(FileManager.default.fileExists(atPath: fixture.candidateURL.path))
    session = nil
  }

  @Test("Recovery at capacity leaves a pending intent receipt-less")
  func pendingIntentRejectsReceiptBeyondCapacity() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    try prepareExistingLock(fixture)
    let intent = try fixture.intent()
    let intentBytes = try QuarantineJournalV1Codec.encode(intent)
    try writeRecord(
      intentBytes,
      to: fixture.recordURL(".intent-v1-\(fixture.transactionID)")
    )
    try populateCanonicalIntentStages(fixture, count: 4_094)
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )

    #expect(
      journal.recover(fixture.recoveryRequest())
        == .failure(.unavailable(.resourceLimit))
    )
    #expect(
      try Data(contentsOf: fixture.recordURL(".intent-v1-\(fixture.transactionID)"))
        == intentBytes
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.recordURL(".receipt-stage-v1-\(fixture.transactionID)").path
      )
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.recordURL(".receipt-v1-\(fixture.transactionID)").path
      )
    )
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.quarantineURL.path).count
        == 4_096
    )
    #expect(FileManager.default.fileExists(atPath: fixture.candidateURL.path))
  }
}

private func abandonIntent(
  _ fixture: DescriptorJournalTestFixture,
  journal: DescriptorQuarantineJournal
) throws {
  var session: DescriptorQuarantineJournalSession? = try fixture.requireSession(from: journal)
  #expect(session != nil)
  session = nil
}

private func requireRecovery(
  _ result: DescriptorQuarantineJournalRecoveryResult
) throws -> DescriptorQuarantineJournalRecoverySummary {
  switch result {
  case .success(let summary):
    return summary
  case .failure(let failure):
    throw DescriptorJournalTestError.begin(failure)
  }
}

private func recoveryFails(_ result: DescriptorQuarantineJournalRecoveryResult) -> Bool {
  guard case .failure = result else { return false }
  return true
}

private func moveCandidate(
  _ fixture: DescriptorJournalTestFixture,
  to destinationBytes: [UInt8]
) throws {
  guard let source = DescriptorPathComponent(Array("_cacache".utf8)),
    let destination = DescriptorPathComponent(destinationBytes)
  else {
    throw DescriptorJournalTestError.invalidPath
  }
  var failureCode = Int32(EINVAL)
  let result = source.withCString { sourcePointer in
    destination.withCString { destinationPointer in
      let status = Darwin.renameat(
        fixture.rootDescriptor,
        sourcePointer,
        fixture.quarantineDescriptor,
        destinationPointer
      )
      if status != 0 { failureCode = errno }
      return status
    }
  }
  guard result == 0 else { throw DescriptorJournalTestError.posix(failureCode) }
}

private func writeRecord(_ bytes: Data, to url: URL) throws {
  try bytes.write(to: url, options: [])
  try descriptorJournalTestChmod(url, mode: 0o600)
}

private func prepareExistingLock(_ fixture: DescriptorJournalTestFixture) throws {
  try writeRecord(Data(), to: fixture.recordURL(".lock-v1"))
}

private func expectCanonicalReceiptIfPresent(
  _ fixture: DescriptorJournalTestFixture,
  matchingIntentBytes intentBytes: Data,
  producedByRecovery: Bool
) throws {
  let stageURL = fixture.recordURL(".receipt-stage-v1-\(fixture.transactionID)")
  let finalURL = fixture.recordURL(".receipt-v1-\(fixture.transactionID)")
  let existingURLs = [stageURL, finalURL].filter {
    FileManager.default.fileExists(atPath: $0.path)
  }
  #expect(existingURLs.count <= 1)
  for url in existingURLs {
    let receipt = try QuarantineJournalV1Codec.decodeReceipt(
      Data(contentsOf: url),
      matchingIntentBytes: intentBytes
    )
    #expect(receipt.producedByRecovery == producedByRecovery)
  }
}

private func populateCanonicalIntentStages(
  _ fixture: DescriptorJournalTestFixture,
  count: Int
) throws {
  let templateIntent = try fixture.intent()
  let templateBytes = try QuarantineJournalV1Codec.encode(templateIntent)
  for ordinal in 1...count {
    let transactionID = descriptorJournalTestTransactionID(ordinal)
    let bytes = try replacingTransactionID(
      in: templateBytes,
      from: templateIntent.transactionID,
      to: transactionID
    )
    try writeRecord(
      bytes,
      to: fixture.recordURL(".intent-stage-v1-\(transactionID)")
    )
  }
}

private func descriptorJournalTestMode(at url: URL) throws -> mode_t {
  var information = stat()
  guard Darwin.lstat(url.path, &information) == 0 else {
    throw DescriptorJournalTestError.posix(errno)
  }
  return information.st_mode & mode_t(0o7777)
}

private func descriptorJournalTestTransactionID(_ ordinal: Int) -> String {
  String(format: "%032llx", UInt64(ordinal))
}

private func replacingTransactionID(
  in template: Data,
  from oldTransactionID: String,
  to newTransactionID: String
) throws -> Data {
  var bytes = template
  let oldBytes = Data(oldTransactionID.utf8)
  guard let range = bytes.range(of: oldBytes),
    bytes[range.upperBound...].range(of: oldBytes) == nil,
    newTransactionID.utf8.count == oldTransactionID.utf8.count
  else {
    throw DescriptorJournalTestError.invalidSnapshot
  }
  bytes.replaceSubrange(range, with: newTransactionID.utf8)
  return bytes
}

private func historicalIntentBytes(_ intent: QuarantineJournalIntentV1) throws -> Data {
  var bytes = try QuarantineJournalV1Codec.encode(intent)
  let current = QuarantineJournalPolicyV1.current.catalog
  let historical = descriptorJournalTestHistoricalPolicy().catalog
  let currentField = Data(
    "\"catalogRevision\":{\"identifier\":\"\(current.identifier)\",\"version\":\"\(current.version)\"}"
      .utf8
  )
  let historicalField = Data(
    "\"catalogRevision\":{\"identifier\":\"\(historical.identifier)\",\"version\":\"\(historical.version)\"}"
      .utf8
  )
  guard let range = bytes.range(of: currentField) else {
    throw DescriptorJournalTestError.invalidSnapshot
  }
  bytes.replaceSubrange(range, with: historicalField)
  return bytes
}

private func descriptorJournalInjectedRecovery(
  counter: DescriptorJournalTestCounter
) -> DescriptorQuarantineJournal {
  DescriptorQuarantineJournal(
    begin: { _ in .failure(.unsafe) },
    finish: { _, _, _ in .invalidSession },
    recover: { _ in
      _ = counter.result()
      return .success(
        DescriptorQuarantineJournalRecoverySummary(
          recoveredReceipts: [],
          validatedTransactionCount: 0
        ))
    }
  )
}
