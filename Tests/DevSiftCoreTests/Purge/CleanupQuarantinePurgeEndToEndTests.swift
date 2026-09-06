import Darwin
import Foundation
import Testing

@testable import DevSiftCore

@Suite("Cleanup quarantine purge end to end", .serialized)
struct CleanupQuarantinePurgeEndToEndTests {
  @Test("Initial purge deletes only the selected synthetic quarantine tree")
  func initialPurgePreservesARecreatedActiveCache() async throws {
    let fixture = try DescriptorPurgeInventoryFixture()
    defer { fixture.remove() }

    let entries: [DescriptorQuarantineInventoryEntry]
    switch descriptorJournalReconcileAndLoadInventory(
      fixture.filesystem.recoveryRequest(),
      dependencies: fixture.dependencies
    ) {
    case .success(let value):
      entries = value
    case .failure(let failure):
      throw PurgeEndToEndTestError.inventory(failure)
    }
    // Recreate an unrelated active cache after inventory loading. Purge is
    // bound only to Q and must neither open nor remove this current name.
    try FileManager.default.createDirectory(
      at: fixture.filesystem.candidateURL,
      withIntermediateDirectories: false
    )
    let liveSentinel = fixture.filesystem.candidateURL.appendingPathComponent("live-sentinel")
    try Data([7, 11, 13]).write(to: liveSentinel)

    let rawHome = Array(fixture.filesystem.baseURL.path.utf8)
    let capacityObserver = purgeEndToEndCapacityObserver()
    let preflight = DescriptorNPMQuarantinePurgePreflight(
      dependencies: DescriptorNPMQuarantinePurgePreflightDependencies(
        checkpoint: {},
        rawHomeProvider: { .known(rawHome) },
        accountUIDProvider: { .known(Darwin.getuid()) },
        nonceBytes: { _ in [UInt8](repeating: 0xA1, count: 16) },
        supportsDurablePurge: { true },
        capacityObserver: capacityObserver
      )
    )
    var journalDependencies = fixture.dependencies
    journalDependencies.purgeCapacityObserver = capacityObserver
    let stager = DescriptorExclusiveQuarantinePurgeStager(
      dependencies: DescriptorExclusiveQuarantinePurgeStagerDependencies(
        currentAccountUID: { Darwin.getuid() },
        supportsResolveBeneathRename: { true },
        volumeCapabilities: { _ in
          .success(
            DescriptorQuarantineVolumeCapabilities(
              supportsExclusiveRename: true,
              supportsPOSIXPermissions: true
            ))
        },
        renameExclusive: purgeEndToEndRename,
        fullSync: { _ in nil },
        journal: DescriptorQuarantinePurgeJournal(
          dependencies: DescriptorQuarantinePurgeJournalDependencies(
            journal: journalDependencies
          ))
      ))
    let executor = CleanupQuarantinePurgeExecutor(
      preflight: preflight,
      stager: stager,
      retryJournal: DescriptorQuarantinePurgeRetryJournal(
        dependencies: journalDependencies
      ),
      unlinkEngine: DescriptorNPMPurgeUnlinkEngine(
        dependencies: DescriptorNPMPurgeUnlinkDependencies(fullSync: { _ in nil })
      ),
      terminalizer: DescriptorQuarantinePurgeTerminalizer(
        dependencies: journalDependencies
      )
    )

    let inventoryWorkflow = QuarantineInventoryRestoreWorkflow(
      loadInventory: { .success(entries) },
      prepareRestore: { _ in .failure(.invalidClaim) },
      executeRestore: { _ in throw CancellationError() },
      prepareInitialPurge: { preflight.prepareInitial($0) },
      preparePurgeRetry: { preflight.prepareExplicitRetry($0) },
      executePurge: { try await executor.execute($0) }
    )
    let inventory = try purgeEndToEndInventory(
      inventoryWorkflow.reconcileAndLoadInventory()
    )
    let item = try #require(inventory.items.first)
    let authorizationSession = try purgeEndToEndAuthorizationSession(
      inventoryWorkflow.beginInitialPurge(
        from: inventory,
        item: item.reference
      ))
    let request = authorizationSession.confirmationRequest
    let authorization = try await authorizationSession.authorize(
      using: QuarantinePurgeUserConfirmation(
        request: request,
        statement: request.requiredStatement
      ))
    let report = try purgeEndToEndOutcome(
      await inventoryWorkflow.executePurge(authorization)
    )

    #expect(report.status == .itemAbsent)
    #expect(
      report.durability
        == .terminalReceiptRecorded(outcome: .itemAbsent, producedByRecovery: false)
    )
    #expect(report.performedPermanentDeletion)
    #expect(report.observedUnlinkCount == 3)
    #expect(!FileManager.default.fileExists(atPath: fixture.quarantineItemURL.path))
    #expect(FileManager.default.fileExists(atPath: fixture.filesystem.candidateURL.path))
    #expect(try Data(contentsOf: liveSentinel) == Data([7, 11, 13]))

    let names = try fixture.quarantineNames()
    #expect(!names.contains(where: { $0.hasPrefix(".purge-work-v1-") }))
    #expect(names.count(where: { $0.hasPrefix(".purge-intent-v1-") }) == 1)
    #expect(names.count(where: { $0.hasPrefix(".purge-receipt-v1-") }) == 1)
  }

  @Test("Explicit retry deletes the exact staged remainder without a second intent")
  func explicitRetryPreservesARecreatedActiveCache() async throws {
    let fixture = try DescriptorPurgeInventoryFixture()
    defer { fixture.remove() }
    try fixture.arrange(.work)

    let entries: [DescriptorQuarantineInventoryEntry]
    switch descriptorJournalReconcileAndLoadInventory(
      fixture.filesystem.recoveryRequest(),
      dependencies: fixture.dependencies
    ) {
    case .success(let value):
      entries = value
    case .failure(let failure):
      throw PurgeEndToEndTestError.inventory(failure)
    }
    try FileManager.default.createDirectory(
      at: fixture.filesystem.candidateURL,
      withIntermediateDirectories: false
    )
    let liveSentinel = fixture.filesystem.candidateURL.appendingPathComponent("live-sentinel")
    try Data([17, 19, 23]).write(to: liveSentinel)

    let rawHome = Array(fixture.filesystem.baseURL.path.utf8)
    let capacityObserver = purgeEndToEndCapacityObserver()
    let preflight = DescriptorNPMQuarantinePurgePreflight(
      dependencies: DescriptorNPMQuarantinePurgePreflightDependencies(
        checkpoint: {},
        rawHomeProvider: { .known(rawHome) },
        accountUIDProvider: { .known(Darwin.getuid()) },
        supportsDurablePurge: { true },
        capacityObserver: capacityObserver
      ))
    var journalDependencies = fixture.dependencies
    journalDependencies.purgeCapacityObserver = capacityObserver
    let executor = CleanupQuarantinePurgeExecutor(
      preflight: preflight,
      retryJournal: DescriptorQuarantinePurgeRetryJournal(
        dependencies: journalDependencies
      ),
      unlinkEngine: DescriptorNPMPurgeUnlinkEngine(
        dependencies: DescriptorNPMPurgeUnlinkDependencies(fullSync: { _ in nil })
      ),
      terminalizer: DescriptorQuarantinePurgeTerminalizer(
        dependencies: journalDependencies
      )
    )
    let inventoryWorkflow = QuarantineInventoryRestoreWorkflow(
      loadInventory: { .success(entries) },
      prepareRestore: { _ in .failure(.invalidClaim) },
      executeRestore: { _ in throw CancellationError() },
      prepareInitialPurge: { preflight.prepareInitial($0) },
      preparePurgeRetry: { preflight.prepareExplicitRetry($0) },
      executePurge: { try await executor.execute($0) }
    )
    let inventory = try purgeEndToEndInventory(
      inventoryWorkflow.reconcileAndLoadInventory()
    )
    let retryItem = try #require(inventory.purgeRetries.first)
    let authorizationSession = try purgeEndToEndAuthorizationSession(
      inventoryWorkflow.beginPurgeRetry(
        from: inventory,
        retry: retryItem.reference
      ))
    let request = authorizationSession.confirmationRequest
    let authorization = try await authorizationSession.authorize(
      using: QuarantinePurgeUserConfirmation(
        request: request,
        statement: request.requiredStatement
      ))
    let report = try purgeEndToEndOutcome(
      await inventoryWorkflow.executePurge(authorization)
    )

    #expect(report.attemptKind == .explicitRetry)
    #expect(report.status == .itemAbsent)
    #expect(report.performedPermanentDeletion)
    #expect(report.observedUnlinkCount == 3)
    #expect(FileManager.default.fileExists(atPath: fixture.filesystem.candidateURL.path))
    #expect(try Data(contentsOf: liveSentinel) == Data([17, 19, 23]))

    let names = try fixture.quarantineNames()
    #expect(!names.contains(where: { $0.hasPrefix(".purge-work-v1-") }))
    #expect(names.count(where: { $0.hasPrefix(".purge-intent-v1-") }) == 1)
    #expect(names.count(where: { $0.hasPrefix(".purge-receipt-v1-") }) == 1)
  }
}

private enum PurgeEndToEndTestError: Error {
  case inventory(DescriptorQuarantineInventoryFailure)
  case workflow(QuarantineInventoryLoadFailure)
  case preparation(QuarantinePurgePreparationFailure)
  case execution(QuarantinePurgeExecutionFailure)
}

private func purgeEndToEndInventory(
  _ result: Result<QuarantineInventorySession, QuarantineInventoryLoadFailure>
) throws -> QuarantineInventorySession {
  switch result {
  case .success(let inventory):
    return inventory
  case .failure(let failure):
    throw PurgeEndToEndTestError.workflow(failure)
  }
}

private func purgeEndToEndAuthorizationSession(
  _ result: Result<QuarantinePurgeAuthorizationSession, QuarantinePurgePreparationFailure>
) throws -> QuarantinePurgeAuthorizationSession {
  switch result {
  case .success(let session):
    return session
  case .failure(let failure):
    throw PurgeEndToEndTestError.preparation(failure)
  }
}

private func purgeEndToEndOutcome(
  _ result: Result<QuarantinePurgeExecutionOutcome, QuarantinePurgeExecutionFailure>
) throws -> QuarantinePurgeExecutionOutcome {
  switch result {
  case .success(let outcome):
    return outcome
  case .failure(let failure):
    throw PurgeEndToEndTestError.execution(failure)
  }
}

private func purgeEndToEndCapacityObserver() -> DescriptorQuarantinePurgeCapacityObserver {
  DescriptorQuarantinePurgeCapacityObserver(
    dependencies: DescriptorQuarantinePurgeCapacityObserverDependencies(
      fstat: { descriptor in
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
          return .failure(DescriptorQuarantinePurgeCapacityPOSIXError(code: errno))
        }
        return .success(
          DescriptorQuarantinePurgeFStatValue(
            device: UInt64(information.st_dev)
          ))
      },
      fstatfs: { _ in
        .success(
          DescriptorQuarantinePurgeFStatFSValue(
            blockSize: 1,
            availableBlockCount: 1_000_000,
            fileSystemIDFirst: 101,
            fileSystemIDSecond: 103
          ))
      }
    ))
}

private func purgeEndToEndRename(
  fromDescriptor: Int32,
  fromPath: DescriptorQuarantineRelativePath,
  toDescriptor: Int32,
  toPath: DescriptorQuarantineRelativePath,
  flags: UInt32
) -> DescriptorExclusiveRenameResult {
  let supportsResolveBeneath = ProcessInfo.processInfo.isOperatingSystemAtLeast(
    OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
  )
  let effectiveFlags =
    supportsResolveBeneath
    ? flags
    : flags & ~DescriptorExclusiveQuarantineMover.resolveBeneathRenameFlag
  var failureCode: Int32 = EINVAL
  let status = fromPath.withCString { fromPointer in
    toPath.withCString { toPointer in
      let result = Darwin.renameatx_np(
        fromDescriptor,
        fromPointer,
        toDescriptor,
        toPointer,
        effectiveFlags
      )
      if result != 0 { failureCode = errno }
      return result
    }
  }
  return status == 0 ? .succeeded : .failed(failureCode)
}
