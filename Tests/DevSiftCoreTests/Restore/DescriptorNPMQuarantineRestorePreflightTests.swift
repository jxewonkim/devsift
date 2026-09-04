import Darwin
import Foundation
import Testing

@testable import DevSiftCore

@Suite("Descriptor npm quarantine restore preflight", .serialized)
struct DescriptorNPMQuarantineRestorePreflightTests {
  @Test("Prepare generates a lowercase Core identifier and returns exact authorization")
  func prepareGeneratesIdentifierAndAuthorization() throws {
    let fixture = try RestorePreflightFixture()
    defer { fixture.remove() }
    let probe = RestorePreflightPrepareProbe()
    let preflight = fixture.preflight(
      nonceBytes: { attempt in
        #expect(attempt == 0)
        return [UInt8](repeating: 0xAB, count: 16)
      },
      journal: fixture.preparationJournal(probe: probe)
    )

    let result = preflight.prepare(
      quarantineTransactionID: fixture.quarantineTransactionID
    )

    let session: CleanupQuarantineRestoreAuthorizationSession
    switch result {
    case .success(let value):
      session = value
    case .failure(let failure):
      Issue.record("prepare unexpectedly failed: \(failure)")
      return
    }
    let expectedRestoreID = String(repeating: "ab", count: 16)
    #expect(
      session.confirmationRequest.subject.quarantineTransactionID
        == fixture.quarantineTransactionID
    )
    #expect(session.confirmationRequest.subject.restoreTransactionID == expectedRestoreID)
    #expect(session.confirmationRequest.subject.originalPath.description == "_cacache")
    #expect(
      session.confirmationRequest.subject.quarantineItemPath.rawComponents
        == [
          DescriptorExclusiveQuarantineMover.quarantineRootBytes,
          fixture.quarantineItemComponent,
        ]
    )

    let observation = probe.observation
    #expect(observation.callCount == 1)
    #expect(observation.quarantineTransactionIDs == [fixture.quarantineTransactionID])
    #expect(observation.restoreTransactionIDs == [expectedRestoreID])
    #expect(observation.descriptorsWereOpen)
    #expect(observation.usedExactFixedRoot)
  }

  @Test("Restore identifier collisions are capped at sixteen attempts")
  func restoreIdentifierCollisionLimit() throws {
    let fixture = try RestorePreflightFixture()
    defer { fixture.remove() }
    let probe = RestorePreflightPrepareProbe()
    let journal = DescriptorQuarantineRestoreJournal(
      prepare: { request in
        probe.record(request)
        return .failure(.invalidClaim)
      },
      begin: { _ in .failure(.invalidClaim) },
      finish: { _, _, _ in .invalidSession }
    )
    let preflight = fixture.preflight(
      nonceBytes: { attempt in
        [UInt8](repeating: UInt8(attempt + 1), count: 16)
      },
      journal: journal
    )

    expectRestorePreflightFailure(
      .restoreIdentifierCollisionLimitExceeded,
      from: preflight.prepare(quarantineTransactionID: fixture.quarantineTransactionID)
    )
    #expect(probe.observation.callCount == 16)
    #expect(Set(probe.observation.restoreTransactionIDs).count == 16)
  }

  @Test("Malformed nonce output cannot become a restore identifier")
  func malformedNonceIsBounded() throws {
    let fixture = try RestorePreflightFixture()
    defer { fixture.remove() }
    let probe = RestorePreflightPrepareProbe()
    let preflight = fixture.preflight(
      nonceBytes: { _ in [UInt8](repeating: 0x11, count: 15) },
      journal: fixture.preparationJournal(probe: probe)
    )

    expectRestorePreflightFailure(
      .restoreIdentifierUnavailable,
      from: preflight.prepare(quarantineTransactionID: fixture.quarantineTransactionID)
    )
    #expect(probe.observation.callCount == 0)
  }

  @Test("Caller-selected or malformed quarantine identifiers are rejected before discovery")
  func invalidQuarantineIdentifierIsRejected() {
    let discoveryProbe = RestorePreflightInvocationProbe()
    let preflight = DescriptorNPMQuarantineRestorePreflight(
      dependencies: DescriptorNPMQuarantineRestorePreflightDependencies(
        rawHomeProvider: {
          discoveryProbe.record()
          return .known(Array("/private/tmp/should-not-be-opened".utf8))
        }
      )
    )

    expectRestorePreflightFailure(
      .invalidQuarantineTransactionID,
      from: preflight.prepare(quarantineTransactionID: "../not-a-transaction")
    )
    #expect(discoveryProbe.callCount == 0)
  }

  @Test("Cancellation is honored before journal preparation")
  func cancellationBeforeJournalPreparation() throws {
    let fixture = try RestorePreflightFixture()
    defer { fixture.remove() }
    let probe = RestorePreflightPrepareProbe()
    let preflight = fixture.preflight(
      checkpoint: { throw CancellationError() },
      journal: fixture.preparationJournal(probe: probe)
    )

    expectRestorePreflightFailure(
      .cancelled,
      from: preflight.prepare(quarantineTransactionID: fixture.quarantineTransactionID)
    )
    #expect(probe.observation.callCount == 0)
  }

  @Test(
    "Missing fixed roots produce bounded failures before journal preparation",
    arguments: RestorePreflightMissingRoot.allCases
  )
  func missingFixedRoot(_ missingRoot: RestorePreflightMissingRoot) throws {
    let fixture = try RestorePreflightMissingRootFixture(missing: missingRoot)
    defer { fixture.remove() }
    let probe = RestorePreflightPrepareProbe()
    let preflight = DescriptorNPMQuarantineRestorePreflight(
      dependencies: DescriptorNPMQuarantineRestorePreflightDependencies(
        rawHomeProvider: { .known(fixture.rawHome) },
        accountUIDProvider: { .known(Darwin.getuid()) },
        journal: fixture.unusedJournal(probe: probe)
      )
    )

    let result = preflight.prepare(
      quarantineTransactionID: String(repeating: "a", count: 32)
    )
    switch missingRoot {
    case .npm:
      expectRestorePreflightFailure(.rootUnavailable(.pathChanged), from: result)
    case .quarantine:
      expectRestorePreflightFailure(.quarantineRootUnavailable(.pathChanged), from: result)
    }
    #expect(probe.observation.callCount == 0)
  }

  @Test(
    "Parents are revalidated immediately before journal preparation",
    arguments: RestorePreflightParentMutation.allCases
  )
  func finalParentRevalidationRejectsModeChange(
    _ mutation: RestorePreflightParentMutation
  ) throws {
    let fixture = try RestorePreflightFixture()
    defer { fixture.remove() }
    let probe = RestorePreflightPrepareProbe()
    let targetURL: URL
    switch mutation {
    case .home:
      targetURL = fixture.homeURL
    case .npm:
      targetURL = fixture.rootURL
    case .quarantine:
      targetURL = fixture.quarantineURL
    }
    let preflight = fixture.preflight(
      journal: fixture.preparationJournal(probe: probe),
      hooks: DescriptorNPMQuarantineRestorePreflightHooks(
        beforeFinalParentValidation: {
          guard Darwin.chmod(targetURL.path, 0o755) == 0 else {
            throw RestorePreflightTestError.posix(errno)
          }
        }
      )
    )

    expectRestorePreflightFailure(
      mutation.expectedFailure,
      from: preflight.prepare(quarantineTransactionID: fixture.quarantineTransactionID)
    )
    #expect(probe.observation.callCount == 0)
  }

  @Test("Execute opens the exact receipt-bound item for the synchronous restorer call")
  func executeUsesExactHeldItemDescriptor() async throws {
    let fixture = try RestorePreflightFixture()
    defer { fixture.remove() }
    let preflight = fixture.preflight(
      nonceBytes: { _ in [UInt8](repeating: 0xBC, count: 16) },
      journal: fixture.preparationJournal(probe: RestorePreflightPrepareProbe())
    )
    let session: CleanupQuarantineRestoreAuthorizationSession
    switch preflight.prepare(quarantineTransactionID: fixture.quarantineTransactionID) {
    case .success(let value):
      session = value
    case .failure(let failure):
      Issue.record("prepare unexpectedly failed: \(failure)")
      return
    }
    let confirmation = CleanupQuarantineRestoreUserConfirmation(
      request: session.confirmationRequest,
      statement: session.confirmationRequest.requiredStatement
    )
    let authorization = try await session.authorize(using: confirmation)
    let claim = try await authorization.consumeForExecution()
    let beginProbe = RestorePreflightBeginProbe(
      expectedIntent: fixture.intent,
      expectedItemComponent: fixture.quarantineItemComponent
    )
    let restorerJournal = DescriptorQuarantineRestoreJournal(
      prepare: { _ in .failure(.invalidClaim) },
      begin: { request in
        beginProbe.record(request)
        return .failure(.exclusiveRenameUnsupported)
      },
      finish: { _, _, _ in .invalidSession }
    )
    let restorer = DescriptorExclusiveQuarantineRestorer(
      dependencies: DescriptorExclusiveQuarantineRestorerDependencies(
        currentAccountUID: { Darwin.getuid() },
        supportsResolveBeneathRename: { true },
        journal: restorerJournal
      )
    )

    let result = preflight.executeValidatedClaim(claim, using: restorer)

    switch result {
    case .success(let report):
      #expect(report.status == .notRestored(.exclusiveRenameUnsupported))
      #expect(report.durabilityState == .notRecorded)
    case .failure(let failure):
      Issue.record("execute preflight unexpectedly failed: \(failure)")
    }
    let observation = beginProbe.observation
    #expect(observation.callCount == 1)
    #expect(observation.allDescriptorsWereOpen)
    #expect(observation.parentsWereExact)
    #expect(observation.itemMatchedReceiptBinding)
    #expect(observation.itemHadExpectedName)
  }

  @Test("Execute accepts safe current candidate metadata after quarantine")
  func executeAcceptsSafeCurrentCandidateMetadata() async throws {
    let fixture = try RestorePreflightFixture()
    defer { fixture.remove() }
    let preflight = fixture.preflight(
      journal: fixture.preparationJournal(probe: RestorePreflightPrepareProbe())
    )
    let session: CleanupQuarantineRestoreAuthorizationSession
    switch preflight.prepare(quarantineTransactionID: fixture.quarantineTransactionID) {
    case .success(let value):
      session = value
    case .failure(let failure):
      Issue.record("prepare unexpectedly failed: \(failure)")
      return
    }
    let authorization = try await session.authorize(
      using: CleanupQuarantineRestoreUserConfirmation(
        request: session.confirmationRequest,
        statement: session.confirmationRequest.requiredStatement
      ))
    let claim = try await authorization.consumeForExecution()
    try descriptorJournalTestChmod(fixture.quarantineItemURL, mode: 0o500)

    let beginProbe = RestorePreflightInvocationProbe()
    let restorer = DescriptorExclusiveQuarantineRestorer(
      dependencies: DescriptorExclusiveQuarantineRestorerDependencies(
        currentAccountUID: { Darwin.getuid() },
        supportsResolveBeneathRename: { true },
        journal: DescriptorQuarantineRestoreJournal(
          prepare: { _ in .failure(.invalidClaim) },
          begin: { _ in
            beginProbe.record()
            return .failure(.exclusiveRenameUnsupported)
          },
          finish: { _, _, _ in .invalidSession }
        )
      )
    )

    let result = preflight.executeValidatedClaim(claim, using: restorer)

    switch result {
    case .success(let report):
      #expect(report.status == .notRestored(.exclusiveRenameUnsupported))
      #expect(report.durabilityState == .notRecorded)
    case .failure(let failure):
      Issue.record("execute preflight unexpectedly failed: \(failure)")
    }
    #expect(beginProbe.callCount == 1)
  }
}

enum RestorePreflightMissingRoot: CaseIterable, Sendable {
  case npm
  case quarantine
}

enum RestorePreflightParentMutation: CaseIterable, Sendable {
  case home
  case npm
  case quarantine

  var expectedFailure: DescriptorNPMQuarantineRestorePreflightFailure {
    switch self {
    case .home:
      return .homeUnsafe
    case .npm:
      return .rootUnsafe
    case .quarantine:
      return .quarantineRootUnsafe
    }
  }
}

private enum RestorePreflightTestError: Error {
  case invalidFixture
  case posix(Int32)
}

private struct RestorePreflightEvidenceSource: Sendable {
  let canonicalIntentBytes: Data
  let canonicalReceiptBytes: Data

  func evidence(
    restoreTransactionID: String
  ) throws -> CleanupQuarantineRestorePreparedEvidence {
    let restoreIntent = try QuarantineRestoreJournalV1Codec.makeIntent(
      restoreTransactionID: restoreTransactionID,
      canonicalQuarantineIntentBytes: canonicalIntentBytes,
      canonicalQuarantineReceiptBytes: canonicalReceiptBytes
    )
    return CleanupQuarantineRestorePreparedEvidence(
      canonicalQuarantineIntentBytes: canonicalIntentBytes,
      canonicalQuarantineReceiptBytes: canonicalReceiptBytes,
      restoreIntent: restoreIntent
    )
  }
}

private final class RestorePreflightFixture {
  let filesystem: DescriptorJournalTestFixture
  let intent: QuarantineJournalIntentV1
  let evidenceSource: RestorePreflightEvidenceSource
  let quarantineItemComponent: [UInt8]
  let quarantineItemURL: URL

  var quarantineTransactionID: String { intent.transactionID }
  var homeURL: URL { filesystem.baseURL }
  var rootURL: URL { filesystem.rootURL }
  var quarantineURL: URL { filesystem.quarantineURL }
  var rawHome: [UInt8] { Array(filesystem.baseURL.path.utf8) }

  init() throws {
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
    let intent = try filesystem.intent(destinationSeed: 0x100)
    let selectedOrdinal = 3
    let quarantineItemComponent = intent.destinationComponents[selectedOrdinal]
    guard
      let quarantineItemName = String(bytes: quarantineItemComponent, encoding: .utf8)
    else {
      filesystem.remove()
      throw RestorePreflightTestError.invalidFixture
    }
    let quarantineItemURL = filesystem.quarantineURL.appendingPathComponent(
      quarantineItemName,
      isDirectory: true
    )
    let canonicalIntentBytes = try QuarantineJournalV1Codec.encode(intent)
    let receipt = try QuarantineJournalV1Codec.makeReceipt(
      outcome: .quarantined,
      selectedDestinationOrdinal: selectedOrdinal,
      producedByRecovery: false,
      canonicalIntentBytes: canonicalIntentBytes
    )
    let canonicalReceiptBytes = try QuarantineJournalV1Codec.encode(
      receipt,
      matchingIntentBytes: canonicalIntentBytes
    )
    try FileManager.default.moveItem(at: filesystem.candidateURL, to: quarantineItemURL)

    self.filesystem = filesystem
    self.intent = intent
    self.evidenceSource = RestorePreflightEvidenceSource(
      canonicalIntentBytes: canonicalIntentBytes,
      canonicalReceiptBytes: canonicalReceiptBytes
    )
    self.quarantineItemComponent = quarantineItemComponent
    self.quarantineItemURL = quarantineItemURL
  }

  func remove() {
    filesystem.remove()
  }

  func preflight(
    checkpoint: @escaping DescriptorNPMQuarantineRestorePreflightDependencies.Checkpoint = {},
    nonceBytes: @escaping DescriptorNPMQuarantineRestorePreflightDependencies.NonceProvider = {
      _ in [UInt8](repeating: 0xCD, count: 16)
    },
    journal: DescriptorQuarantineRestoreJournal,
    hooks: DescriptorNPMQuarantineRestorePreflightHooks =
      DescriptorNPMQuarantineRestorePreflightHooks()
  ) -> DescriptorNPMQuarantineRestorePreflight {
    let rawHome = self.rawHome
    return DescriptorNPMQuarantineRestorePreflight(
      dependencies: DescriptorNPMQuarantineRestorePreflightDependencies(
        checkpoint: checkpoint,
        rawHomeProvider: { .known(rawHome) },
        accountUIDProvider: { .known(Darwin.getuid()) },
        nonceBytes: nonceBytes,
        journal: journal,
        hooks: hooks
      )
    )
  }

  func preparationJournal(
    probe: RestorePreflightPrepareProbe
  ) -> DescriptorQuarantineRestoreJournal {
    let evidenceSource = self.evidenceSource
    return DescriptorQuarantineRestoreJournal(
      prepare: { request in
        probe.record(request)
        do {
          return .success(
            try evidenceSource.evidence(
              restoreTransactionID: request.restoreTransactionID
            ))
        } catch {
          return .failure(.invalidClaim)
        }
      },
      begin: { _ in .failure(.invalidClaim) },
      finish: { _, _, _ in .invalidSession }
    )
  }
}

private final class RestorePreflightMissingRootFixture: @unchecked Sendable {
  let homeURL: URL
  let rawHome: [UInt8]

  init(missing: RestorePreflightMissingRoot) throws {
    homeURL = URL(
      fileURLWithPath: "/private/tmp/devsift-restore-preflight-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: false)
    try descriptorJournalTestChmod(homeURL, mode: 0o700)
    if missing == .quarantine {
      let npmURL = homeURL.appendingPathComponent(".npm", isDirectory: true)
      try FileManager.default.createDirectory(at: npmURL, withIntermediateDirectories: false)
      try descriptorJournalTestChmod(npmURL, mode: 0o700)
    }
    rawHome = Array(homeURL.path.utf8)
  }

  func unusedJournal(
    probe: RestorePreflightPrepareProbe
  ) -> DescriptorQuarantineRestoreJournal {
    DescriptorQuarantineRestoreJournal(
      prepare: { request in
        probe.record(request)
        return .failure(.invalidClaim)
      },
      begin: { _ in .failure(.invalidClaim) },
      finish: { _, _, _ in .invalidSession }
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: homeURL)
  }
}

private struct RestorePreflightPrepareObservation: Sendable {
  let callCount: Int
  let quarantineTransactionIDs: [String]
  let restoreTransactionIDs: [String]
  let descriptorsWereOpen: Bool
  let usedExactFixedRoot: Bool
}

private final class RestorePreflightPrepareProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var callCount = 0
  private var quarantineTransactionIDs: [String] = []
  private var restoreTransactionIDs: [String] = []
  private var descriptorsWereOpen = true
  private var usedExactFixedRoot = true

  func record(_ request: DescriptorQuarantineRestorePreparationRequest) {
    var rootInformation = stat()
    var quarantineInformation = stat()
    let rootWasOpen = Darwin.fstat(request.recoveryRequest.rootDescriptor, &rootInformation) == 0
    let quarantineWasOpen =
      Darwin.fstat(request.recoveryRequest.quarantineRootDescriptor, &quarantineInformation) == 0
    let exactRoot =
      request.recoveryRequest.quarantineRootComponent.bytes
      == DescriptorExclusiveQuarantineMover.quarantineRootBytes

    lock.lock()
    callCount += 1
    quarantineTransactionIDs.append(request.quarantineTransactionID)
    restoreTransactionIDs.append(request.restoreTransactionID)
    descriptorsWereOpen = descriptorsWereOpen && rootWasOpen && quarantineWasOpen
    usedExactFixedRoot = usedExactFixedRoot && exactRoot
    lock.unlock()
  }

  var observation: RestorePreflightPrepareObservation {
    lock.lock()
    defer { lock.unlock() }
    return RestorePreflightPrepareObservation(
      callCount: callCount,
      quarantineTransactionIDs: quarantineTransactionIDs,
      restoreTransactionIDs: restoreTransactionIDs,
      descriptorsWereOpen: descriptorsWereOpen,
      usedExactFixedRoot: usedExactFixedRoot
    )
  }
}

private struct RestorePreflightBeginObservation: Sendable {
  let callCount: Int
  let allDescriptorsWereOpen: Bool
  let parentsWereExact: Bool
  let itemMatchedReceiptBinding: Bool
  let itemHadExpectedName: Bool
}

private final class RestorePreflightBeginProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let expectedIntent: QuarantineJournalIntentV1
  private let expectedItemComponent: [UInt8]
  private var recordedCallCount = 0
  private var allDescriptorsWereOpen = false
  private var parentsWereExact = false
  private var itemMatchedReceiptBinding = false
  private var itemHadExpectedName = false

  init(
    expectedIntent: QuarantineJournalIntentV1,
    expectedItemComponent: [UInt8]
  ) {
    self.expectedIntent = expectedIntent
    self.expectedItemComponent = expectedItemComponent
  }

  func record(_ request: DescriptorQuarantineRestoreJournalBeginRequest) {
    let root = try? DescriptorStatSnapshot.read(
      from: request.recoveryRequest.rootDescriptor,
      cancellationPolicy: .ignoreTaskCancellation
    )
    let quarantine = try? DescriptorStatSnapshot.read(
      from: request.recoveryRequest.quarantineRootDescriptor,
      cancellationPolicy: .ignoreTaskCancellation
    )
    let item = try? DescriptorStatSnapshot.read(
      from: request.quarantinedItemDescriptor,
      cancellationPolicy: .ignoreTaskCancellation
    )
    let itemComponent = DescriptorPathComponent(expectedItemComponent)!
    let namedItem = try? DescriptorStatSnapshot.read(
      at: request.recoveryRequest.quarantineRootDescriptor,
      component: itemComponent,
      cancellationPolicy: .ignoreTaskCancellation
    )

    lock.lock()
    recordedCallCount += 1
    allDescriptorsWereOpen = root != nil && quarantine != nil && item != nil
    parentsWereExact =
      root.map { restorePreflightMatchesHistorical($0, expectedIntent.npmRootBinding) } ?? false
      && (quarantine.map {
        restorePreflightMatchesHistorical($0, expectedIntent.quarantineRootBinding)
      } ?? false)
    itemMatchedReceiptBinding =
      item.flatMap(QuarantineJournalFileBindingV1.init(snapshot:))
      == expectedIntent.candidateBinding
    itemHadExpectedName =
      item != nil && namedItem != nil
      && item!.sameBinding(as: namedItem!)
      && item!.sameMutationState(as: namedItem!)
    lock.unlock()
  }

  var observation: RestorePreflightBeginObservation {
    lock.lock()
    defer { lock.unlock() }
    return RestorePreflightBeginObservation(
      callCount: recordedCallCount,
      allDescriptorsWereOpen: allDescriptorsWereOpen,
      parentsWereExact: parentsWereExact,
      itemMatchedReceiptBinding: itemMatchedReceiptBinding,
      itemHadExpectedName: itemHadExpectedName
    )
  }
}

private final class RestorePreflightInvocationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedCallCount = 0

  func record() {
    lock.lock()
    recordedCallCount += 1
    lock.unlock()
  }

  var callCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return recordedCallCount
  }
}

private func restorePreflightMatchesHistorical(
  _ snapshot: DescriptorStatSnapshot,
  _ binding: QuarantineJournalFileBindingV1
) -> Bool {
  snapshot.identity.device == binding.device
    && snapshot.identity.inode == binding.inode
    && snapshot.generation == binding.generation
    && snapshot.birthSeconds == binding.birthSeconds
    && snapshot.birthNanoseconds == binding.birthNanoseconds
    && snapshot.kind == binding.kind
    && snapshot.ownerUID == binding.ownerUID
}

private func expectRestorePreflightFailure<Success>(
  _ expected: DescriptorNPMQuarantineRestorePreflightFailure,
  from result: Result<Success, DescriptorNPMQuarantineRestorePreflightFailure>,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  switch result {
  case .success:
    Issue.record("Expected restore preflight failure \(expected)", sourceLocation: sourceLocation)
  case .failure(let failure):
    #expect(failure == expected, sourceLocation: sourceLocation)
  }
}
