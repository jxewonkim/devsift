import Darwin
import Foundation
import Testing

@testable import DevSiftCore

@Suite("Descriptor npm purge unlink engine", .serialized)
struct DescriptorNPMPurgeUnlinkEngineTests {
  @Test("Initial attempt removes only the staged synthetic tree in byte order")
  func initialSuccessPreservesOutsideSentinel() throws {
    let fixture = try PurgeUnlinkFixture()
    defer { fixture.remove() }
    let sentinel = try fixture.base.scannerFixture.write(
      "sentinel",
      bytes: [7, 8, 9],
      under: fixture.base.scannerFixture.outside
    )
    let probe = PurgeUnlinkProbe()
    let engine = DescriptorNPMPurgeUnlinkEngine(
      dependencies: DescriptorNPMPurgeUnlinkDependencies(
        fullSync: { _ in nil },
        hooks: probe.hooks()
      )
    )

    let report = engine.execute(fixture.request(attemptKind: .initial))

    #expect(report.status == .itemAbsent)
    #expect(report.observedAbsentNameCount == 11)
    #expect(!report.cancellationWasRequested)
    #expect(report.synchronizationOperationCount == 10)
    #expect(!FileManager.default.fileExists(atPath: fixture.work.path))
    #expect(try Data(contentsOf: sentinel) == Data([7, 8, 9]))

    let removals = probe.observation.unlinkNames
    let contentIndex = try #require(removals.firstIndex(of: "content-v2"))
    let indexIndex = try #require(removals.firstIndex(of: "index-v5"))
    let temporaryIndex = try #require(removals.firstIndex(of: "tmp"))
    #expect(contentIndex < indexIndex)
    #expect(indexIndex < temporaryIndex)
    #expect(removals.last == fixture.workComponentString)
  }

  @Test("A successful return without observed absence is never trusted")
  func successfulReturnStillRequiresReconciliation() throws {
    let fixture = try PurgeUnlinkFixture()
    defer { fixture.remove() }
    let probe = PurgeUnlinkProbe()
    let engine = DescriptorNPMPurgeUnlinkEngine(
      dependencies: DescriptorNPMPurgeUnlinkDependencies(
        unlinkAt: { _, _, _ in nil },
        fullSync: { _ in nil },
        hooks: probe.hooks()
      )
    )

    let report = engine.execute(fixture.request(attemptKind: .initial))

    #expect(report.status == .durabilityUnresolved(reason: .treeChanged))
    #expect(report.observedAbsentNameCount == 0)
    #expect(report.synchronizationOperationCount == 1)
    #expect(probe.observation.unlinkNames.count == 1)
    #expect(FileManager.default.fileExists(atPath: fixture.work.path))
  }

  @Test("Initial attempt refuses a deletion-derived remainder before unlink")
  func initialRequiresCompleteTree() throws {
    let fixture = try PurgeUnlinkFixture()
    defer { fixture.remove() }
    try FileManager.default.removeItem(
      at: fixture.work.appendingPathComponent("content-v2")
    )
    let probe = PurgeUnlinkProbe()
    let engine = DescriptorNPMPurgeUnlinkEngine(
      dependencies: DescriptorNPMPurgeUnlinkDependencies(
        fullSync: { _ in nil },
        hooks: probe.hooks()
      )
    )

    let report = engine.execute(fixture.request(attemptKind: .initial))

    #expect(
      report.status
        == .durabilityUnresolved(
          reason: .preflightValidationFailed(.layoutMismatch)
        )
    )
    #expect(report.observedAbsentNameCount == 0)
    #expect(probe.observation.unlinkNames.isEmpty)
    #expect(FileManager.default.fileExists(atPath: fixture.work.path))
  }

  @Test("Explicit retry accepts and removes a validated remainder")
  func retryAcceptsRemainder() throws {
    let fixture = try PurgeUnlinkFixture()
    defer { fixture.remove() }
    try FileManager.default.removeItem(
      at: fixture.work.appendingPathComponent("content-v2")
    )
    let engine = DescriptorNPMPurgeUnlinkEngine(
      dependencies: DescriptorNPMPurgeUnlinkDependencies(fullSync: { _ in nil })
    )

    let report = engine.execute(fixture.request(attemptKind: .retry))

    #expect(report.status == .itemAbsent)
    #expect(report.observedAbsentNameCount > 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.work.path))
  }

  @Test("An unlink failure stops new removals after synchronizing the dirty parent")
  func unlinkFailureProducesSynchronizedPartial() throws {
    let fixture = try PurgeUnlinkFixture()
    defer { fixture.remove() }
    let probe = PurgeUnlinkProbe()
    let engine = DescriptorNPMPurgeUnlinkEngine(
      dependencies: DescriptorNPMPurgeUnlinkDependencies(
        unlinkAt: { _, _, _ in EACCES },
        fullSync: { descriptor in
          probe.recordFullSync(descriptor)
          return nil
        },
        hooks: probe.hooks()
      )
    )

    let report = engine.execute(fixture.request(attemptKind: .initial))

    #expect(
      report.status
        == .synchronizedPartial(reason: .unlinkFailed(.permissionDenied))
    )
    #expect(report.observedAbsentNameCount == 0)
    #expect(probe.observation.unlinkNames.count == 1)
    #expect(probe.observation.fullSyncDescriptors.count == 1)
    #expect(report.synchronizationOperationCount == 1)
    #expect(FileManager.default.fileExists(atPath: fixture.work.path))
  }

  @Test("Cancellation after one unlink reconciles and synchronizes before stopping")
  func cancellationProducesRetryablePartial() throws {
    let fixture = try PurgeUnlinkFixture()
    defer { fixture.remove() }
    let cancellation = PurgeCancellationProbe()
    let engine = DescriptorNPMPurgeUnlinkEngine(
      dependencies: DescriptorNPMPurgeUnlinkDependencies(
        fullSync: { _ in nil },
        cancellationIsRequested: { cancellation.isRequested },
        hooks: DescriptorNPMPurgeUnlinkHooks(
          didReturnFromUnlink: { _, _, _ in cancellation.request() }
        )
      )
    )

    let partial = engine.execute(fixture.request(attemptKind: .initial))

    #expect(partial.status == .synchronizedPartial(reason: .cancelled))
    #expect(partial.observedAbsentNameCount == 1)
    #expect(partial.cancellationWasRequested)
    #expect(partial.synchronizationOperationCount == 1)
    #expect(FileManager.default.fileExists(atPath: fixture.work.path))

    let retry = DescriptorNPMPurgeUnlinkEngine(
      dependencies: DescriptorNPMPurgeUnlinkDependencies(fullSync: { _ in nil })
    ).execute(fixture.request(attemptKind: .retry))
    #expect(retry.status == .itemAbsent)
    #expect(!FileManager.default.fileExists(atPath: fixture.work.path))
  }

  @Test("Cancellation cannot label an unsafe newly mutated remainder synchronized")
  func cancellationRevalidatesTheCompleteRemainder() throws {
    let fixture = try PurgeUnlinkFixture()
    defer { fixture.remove() }
    let mutation = PurgeCancellationRemainderMutation(workRoot: fixture.work)
    let engine = DescriptorNPMPurgeUnlinkEngine(
      dependencies: DescriptorNPMPurgeUnlinkDependencies(
        fullSync: { _ in nil },
        cancellationIsRequested: { mutation.cancellationIsRequested },
        hooks: DescriptorNPMPurgeUnlinkHooks(
          didReturnFromUnlink: { _, _, _ in mutation.run() }
        )
      )
    )

    let report = engine.execute(fixture.request(attemptKind: .initial))

    #expect(mutation.failureCode == nil)
    #expect(report.status == .durabilityUnresolved(reason: .treeUnsafe))
    #expect(report.observedAbsentNameCount == 1)
    #expect(report.cancellationWasRequested)
    #expect(FileManager.default.fileExists(atPath: fixture.work.path))
  }

  @Test("A failed dirty-directory barrier produces durability-unresolved")
  func synchronizationFailureIsUnresolved() throws {
    let fixture = try PurgeUnlinkFixture()
    defer { fixture.remove() }
    let syncProbe = PurgeFullSyncFailureProbe(results: [EINTR, EINTR, EIO])
    let engine = DescriptorNPMPurgeUnlinkEngine(
      dependencies: DescriptorNPMPurgeUnlinkDependencies(
        fullSync: { descriptor in syncProbe.next(descriptor) }
      )
    )

    let report = engine.execute(fixture.request(attemptKind: .initial))

    #expect(
      report.status
        == .durabilityUnresolved(reason: .synchronizationFailed(.inputOutput))
    )
    #expect(report.observedAbsentNameCount == 1)
    #expect(report.synchronizationOperationCount == 1)
    #expect(syncProbe.observation.descriptors.count == 3)
    #expect(FileManager.default.fileExists(atPath: fixture.work.path))
  }

  @Test("Cancellation before final unlink cannot skip the quarantine-root barrier")
  func finalCancellationStillRequiresParentBarrier() throws {
    let fixture = try PurgeUnlinkFixture()
    defer { fixture.remove() }
    let removal = PurgeFinalRootRemoval(workComponent: fixture.workComponent)
    let quarantineRootDescriptor = fixture.quarantineRootDescriptor
    let engine = DescriptorNPMPurgeUnlinkEngine(
      dependencies: DescriptorNPMPurgeUnlinkDependencies(
        fullSync: { descriptor in
          descriptor == quarantineRootDescriptor ? EIO : nil
        },
        cancellationIsRequested: { removal.cancellationIsRequested },
        hooks: DescriptorNPMPurgeUnlinkHooks(
          beforeUnlink: { parent, component, flags in
            removal.run(parent: parent, component: component, flags: flags)
          }
        )
      )
    )

    let report = engine.execute(fixture.request(attemptKind: .initial))

    #expect(removal.failureCode == nil)
    #expect(removal.didRemove)
    #expect(
      report.status
        == .durabilityUnresolved(reason: .synchronizationFailed(.inputOutput))
    )
    #expect(report.cancellationWasRequested)
    #expect(!FileManager.default.fileExists(atPath: fixture.work.path))
  }

  @Test("A final-name symlink swap never follows or removes the outside sentinel")
  func finalNameSwapPreservesOutsideTree() throws {
    let fixture = try PurgeUnlinkFixture()
    defer { fixture.remove() }
    let sentinel = try fixture.base.scannerFixture.write(
      "race-sentinel",
      bytes: [4, 2],
      under: fixture.base.scannerFixture.outside
    )
    let swap = PurgeFinalNameSwap(
      targetName: "0123456789abcdef",
      replacementName: "fedcba9876543210",
      outsidePath: sentinel.path
    )
    let engine = DescriptorNPMPurgeUnlinkEngine(
      dependencies: DescriptorNPMPurgeUnlinkDependencies(
        fullSync: { _ in nil },
        hooks: DescriptorNPMPurgeUnlinkHooks(
          beforeUnlink: { parent, component, flags in
            swap.run(parent: parent, component: component, flags: flags)
          }
        )
      )
    )

    let report = engine.execute(fixture.request(attemptKind: .initial))

    #expect(swap.observation.didSwap)
    #expect(swap.observation.failureCode == nil)
    #expect(report.status == .durabilityUnresolved(reason: .treeChanged))
    #expect(report.observedAbsentNameCount == 1)
    #expect(try Data(contentsOf: sentinel) == Data([4, 2]))
    #expect(FileManager.default.fileExists(atPath: fixture.work.path))
  }

  @Test("Safe-to-safe work-root mode change after validation blocks every unlink")
  func workRootPermissionRaceFailsClosed() throws {
    let fixture = try PurgeUnlinkFixture()
    defer { fixture.remove() }
    let mutation = PurgeModeMutation(url: fixture.work, mode: 0o700)
    let probe = PurgeUnlinkProbe()
    let engine = DescriptorNPMPurgeUnlinkEngine(
      dependencies: DescriptorNPMPurgeUnlinkDependencies(
        fullSync: { _ in nil },
        hooks: DescriptorNPMPurgeUnlinkHooks(
          didPassAttemptValidator: { mutation.run() },
          beforeUnlink: probe.hooks().beforeUnlink
        )
      )
    )

    let report = engine.execute(fixture.request(attemptKind: .initial))

    #expect(mutation.failureCode == nil)
    #expect(report.status == .durabilityUnresolved(reason: .treeUnsafe))
    #expect(report.observedAbsentNameCount == 0)
    #expect(probe.observation.unlinkNames.isEmpty)
  }

  @Test("Quarantine-root mode race after validation blocks every unlink")
  func quarantineRootPermissionRaceFailsClosed() throws {
    let fixture = try PurgeUnlinkFixture()
    defer { fixture.remove() }
    let mutation = PurgeModeMutation(url: fixture.quarantineRoot, mode: 0o755)
    let probe = PurgeUnlinkProbe()
    let engine = DescriptorNPMPurgeUnlinkEngine(
      dependencies: DescriptorNPMPurgeUnlinkDependencies(
        fullSync: { _ in nil },
        hooks: DescriptorNPMPurgeUnlinkHooks(
          didPassAttemptValidator: { mutation.run() },
          beforeUnlink: probe.hooks().beforeUnlink
        )
      )
    )

    let report = engine.execute(fixture.request(attemptKind: .initial))

    #expect(mutation.failureCode == nil)
    #expect(report.status == .durabilityUnresolved(reason: .treeUnsafe))
    #expect(report.observedAbsentNameCount == 0)
    #expect(probe.observation.unlinkNames.isEmpty)
  }

  @Test("Initial mandatory root removal after preflight blocks every unlink")
  func initialLayoutRaceFailsClosed() throws {
    let fixture = try PurgeUnlinkFixture()
    defer { fixture.remove() }
    let mutation = PurgeRemoveOnce(
      url: fixture.work.appendingPathComponent("content-v2")
    )
    let probe = PurgeUnlinkProbe()
    let engine = DescriptorNPMPurgeUnlinkEngine(
      dependencies: DescriptorNPMPurgeUnlinkDependencies(
        fullSync: { _ in nil },
        hooks: DescriptorNPMPurgeUnlinkHooks(
          didPassAttemptValidator: { mutation.run() },
          beforeUnlink: probe.hooks().beforeUnlink
        )
      )
    )

    let report = engine.execute(fixture.request(attemptKind: .initial))

    #expect(mutation.failureCode == nil)
    #expect(report.status == .durabilityUnresolved(reason: .treeChanged))
    #expect(report.observedAbsentNameCount == 0)
    #expect(probe.observation.unlinkNames.isEmpty)
  }

  @Test("Retry captures a changed but still safe work-root mode for this attempt")
  func retryAcceptsSafeModeChangedBetweenAttempts() throws {
    let fixture = try PurgeUnlinkFixture()
    defer { fixture.remove() }
    let mutation = PurgeModeMutation(url: fixture.work, mode: 0o700)
    mutation.run()
    try #require(mutation.failureCode == nil)

    let report = DescriptorNPMPurgeUnlinkEngine(
      dependencies: DescriptorNPMPurgeUnlinkDependencies(fullSync: { _ in nil })
    ).execute(fixture.request(attemptKind: .retry))

    #expect(report.status == .itemAbsent)
    #expect(!FileManager.default.fileExists(atPath: fixture.work.path))
  }

  @Test("Initial deletion accepts the safe mode validated immediately before staging")
  func initialAcceptsCurrentSafeModeInsteadOfHistoricalMode() throws {
    let fixture = try PurgeUnlinkFixture()
    defer { fixture.remove() }
    let mutation = PurgeModeMutation(url: fixture.work, mode: 0o700)
    mutation.run()
    try #require(mutation.failureCode == nil)

    let report = DescriptorNPMPurgeUnlinkEngine(
      dependencies: DescriptorNPMPurgeUnlinkDependencies(fullSync: { _ in nil })
    ).execute(fixture.request(attemptKind: .initial))

    #expect(report.status == .itemAbsent)
    #expect(!FileManager.default.fileExists(atPath: fixture.work.path))
  }

  @Test("Noncanonical resource bounds fail before validation or unlink")
  func rejectsResourceBoundDrift() throws {
    let fixture = try PurgeUnlinkFixture()
    defer { fixture.remove() }
    let current = QuarantinePurgeJournalResourceBoundsV1.current
    let drifted = QuarantinePurgeJournalResourceBoundsV1(
      maximumEntries: current.maximumEntries - 1,
      maximumDepth: current.maximumDepth,
      maximumEntriesPerDirectory: current.maximumEntriesPerDirectory,
      maximumRawNameBytes: current.maximumRawNameBytes,
      maximumInterruptedSystemCallAttempts: current.maximumInterruptedSystemCallAttempts,
      maximumSynchronizationOperations: current.maximumSynchronizationOperations
    )
    let probe = PurgeUnlinkProbe()
    let report = DescriptorNPMPurgeUnlinkEngine(
      dependencies: DescriptorNPMPurgeUnlinkDependencies(
        fullSync: { _ in nil },
        hooks: probe.hooks()
      )
    ).execute(fixture.request(attemptKind: .initial, resourceBounds: drifted))

    #expect(report.status == .durabilityUnresolved(reason: .invalidRequest))
    #expect(report.observedAbsentNameCount == 0)
    #expect(probe.observation.unlinkNames.isEmpty)
  }
}

private struct PurgeUnlinkProbeObservation: Equatable {
  let unlinkNames: [String]
  let unlinkFlags: [Int32]
  let fullSyncDescriptors: [Int32]
}

private final class PurgeUnlinkProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var unlinkNames: [String] = []
  private var unlinkFlags: [Int32] = []
  private var fullSyncDescriptors: [Int32] = []

  var observation: PurgeUnlinkProbeObservation {
    lock.withLock {
      PurgeUnlinkProbeObservation(
        unlinkNames: unlinkNames,
        unlinkFlags: unlinkFlags,
        fullSyncDescriptors: fullSyncDescriptors
      )
    }
  }

  func hooks() -> DescriptorNPMPurgeUnlinkHooks {
    DescriptorNPMPurgeUnlinkHooks(
      beforeUnlink: { [self] _, component, flags in
        lock.withLock {
          unlinkNames.append(String(decoding: component.bytes, as: UTF8.self))
          unlinkFlags.append(flags)
        }
      }
    )
  }

  func recordFullSync(_ descriptor: Int32) {
    lock.withLock { fullSyncDescriptors.append(descriptor) }
  }
}

private final class PurgeCancellationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var requested = false

  var isRequested: Bool { lock.withLock { requested } }

  func request() {
    lock.withLock { requested = true }
  }
}

private final class PurgeCancellationRemainderMutation: @unchecked Sendable {
  private let lock = NSLock()
  private let workRoot: URL
  private var didRun = false
  private var requested = false
  private var storedFailureCode: Int32?

  init(workRoot: URL) {
    self.workRoot = workRoot
  }

  var cancellationIsRequested: Bool { lock.withLock { requested } }
  var failureCode: Int32? { lock.withLock { storedFailureCode } }

  func run() {
    lock.withLock {
      guard !didRun else { return }
      didRun = true
      let unexpected = workRoot.appendingPathComponent("unexpected-after-unlink")
      let result = unexpected.path.withCString {
        Darwin.symlink("outside-must-not-be-followed", $0)
      }
      if result != 0 { storedFailureCode = errno }
      requested = true
    }
  }
}

private final class PurgeFinalRootRemoval: @unchecked Sendable {
  private let lock = NSLock()
  private let workComponent: DescriptorPathComponent
  private var removed = false
  private var requested = false
  private var storedFailureCode: Int32?

  init(workComponent: DescriptorPathComponent) {
    self.workComponent = workComponent
  }

  var cancellationIsRequested: Bool { lock.withLock { requested } }
  var didRemove: Bool { lock.withLock { removed } }
  var failureCode: Int32? { lock.withLock { storedFailureCode } }

  func run(parent: Int32, component: DescriptorPathComponent, flags: Int32) {
    lock.withLock {
      guard !removed,
        storedFailureCode == nil,
        flags == AT_REMOVEDIR,
        component == workComponent
      else {
        return
      }
      let result = component.withCString { pointer in
        Darwin.unlinkat(parent, pointer, AT_REMOVEDIR)
      }
      if result == 0 {
        removed = true
        requested = true
      } else {
        storedFailureCode = errno
      }
    }
  }
}

private struct PurgeFullSyncFailureObservation: Equatable {
  let descriptors: [Int32]
}

private final class PurgeFullSyncFailureProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var results: [Int32]
  private var descriptors: [Int32] = []

  init(results: [Int32]) {
    self.results = results
  }

  var observation: PurgeFullSyncFailureObservation {
    lock.withLock { PurgeFullSyncFailureObservation(descriptors: descriptors) }
  }

  func next(_ descriptor: Int32) -> Int32? {
    lock.withLock {
      descriptors.append(descriptor)
      guard !results.isEmpty else { return EIO }
      return results.removeFirst()
    }
  }
}

private struct PurgeFinalNameSwapObservation: Equatable {
  let didSwap: Bool
  let failureCode: Int32?
}

private final class PurgeFinalNameSwap: @unchecked Sendable {
  private let lock = NSLock()
  private let targetName: String
  private let replacementName: String
  private let outsidePath: String
  private var didSwap = false
  private var failureCode: Int32?

  init(targetName: String, replacementName: String, outsidePath: String) {
    self.targetName = targetName
    self.replacementName = replacementName
    self.outsidePath = outsidePath
  }

  var observation: PurgeFinalNameSwapObservation {
    lock.withLock {
      PurgeFinalNameSwapObservation(didSwap: didSwap, failureCode: failureCode)
    }
  }

  func run(parent: Int32, component: DescriptorPathComponent, flags: Int32) {
    lock.withLock {
      guard !didSwap,
        failureCode == nil,
        flags == 0,
        component.bytes == Array(targetName.utf8)
      else {
        return
      }
      didSwap = true

      let renameResult = targetName.withCString { source in
        replacementName.withCString { destination in
          Darwin.renameat(parent, source, parent, destination)
        }
      }
      guard renameResult == 0 else {
        failureCode = errno
        return
      }
      let linkResult = outsidePath.withCString { destination in
        targetName.withCString { name in
          Darwin.symlinkat(destination, parent, name)
        }
      }
      if linkResult != 0 { failureCode = errno }
    }
  }
}

private final class PurgeModeMutation: @unchecked Sendable {
  private let lock = NSLock()
  private let path: String
  private let mode: mode_t
  private var storedFailureCode: Int32?

  init(url: URL, mode: mode_t) {
    path = url.path
    self.mode = mode
  }

  var failureCode: Int32? { lock.withLock { storedFailureCode } }

  func run() {
    lock.withLock {
      guard storedFailureCode == nil else { return }
      let result = path.withCString { Darwin.chmod($0, mode) }
      if result != 0 { storedFailureCode = errno }
    }
  }
}

private final class PurgeRemoveOnce: @unchecked Sendable {
  private let lock = NSLock()
  private let url: URL
  private var didRun = false
  private var storedFailureCode: Int32?

  init(url: URL) {
    self.url = url
  }

  var failureCode: Int32? { lock.withLock { storedFailureCode } }

  func run() {
    lock.withLock {
      guard !didRun else { return }
      didRun = true
      do {
        try FileManager.default.removeItem(at: url)
      } catch let error as NSError {
        storedFailureCode = Int32(exactly: error.code) ?? EIO
      }
    }
  }
}

private struct PurgeUnlinkFixture {
  static let workComponentString = ".purge-work-v1-0123456789abcdef0123456789abcdef"

  let base: NPMQuarantinePreflightFixture
  let quarantineRoot: URL
  let work: URL
  let quarantineRootDescriptor: Int32
  let workDescriptor: Int32
  let workComponent: DescriptorPathComponent
  let historicalCandidateBinding: QuarantineJournalFileBindingV1
  let rootDevice: UInt64

  var workComponentString: String { Self.workComponentString }

  init() throws {
    let base = try NPMQuarantinePreflightFixture()
    do {
      let quarantineRoot = try base.scannerFixture.makeDirectory(
        ".devsift-quarantine-v1",
        under: base.root
      )
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: quarantineRoot.path
      )

      let candidateDescriptor = try descriptorOpenRoot(base.candidate)
      let candidateSnapshot: DescriptorStatSnapshot
      do {
        candidateSnapshot = try DescriptorStatSnapshot.read(from: candidateDescriptor)
      } catch {
        descriptorCloseIgnoringErrors(candidateDescriptor)
        throw error
      }
      descriptorCloseIgnoringErrors(candidateDescriptor)
      guard
        let historicalCandidateBinding = QuarantineJournalFileBindingV1(
          snapshot: candidateSnapshot
        ),
        let workComponent = DescriptorPathComponent(Array(Self.workComponentString.utf8))
      else {
        throw NSError(domain: "PurgeUnlinkFixture", code: 1)
      }

      let work = quarantineRoot.appendingPathComponent(Self.workComponentString)
      try FileManager.default.moveItem(at: base.candidate, to: work)

      let quarantineRootDescriptor = try descriptorOpenRoot(quarantineRoot)
      let workDescriptor: Int32
      do {
        workDescriptor = try descriptorOpenTrustedDirectory(
          at: quarantineRootDescriptor,
          component: workComponent
        )
      } catch {
        descriptorCloseIgnoringErrors(quarantineRootDescriptor)
        throw error
      }

      self.base = base
      self.quarantineRoot = quarantineRoot
      self.work = work
      self.quarantineRootDescriptor = quarantineRootDescriptor
      self.workDescriptor = workDescriptor
      self.workComponent = workComponent
      self.historicalCandidateBinding = historicalCandidateBinding
      rootDevice = candidateSnapshot.identity.device
    } catch {
      base.remove()
      throw error
    }
  }

  func request(
    attemptKind: DescriptorNPMPurgeUnlinkAttemptKind,
    resourceBounds: QuarantinePurgeJournalResourceBoundsV1 = .current
  ) -> DescriptorNPMPurgeUnlinkRequest {
    DescriptorNPMPurgeUnlinkRequest(
      quarantineRootDescriptor: quarantineRootDescriptor,
      purgeWorkDescriptor: workDescriptor,
      purgeWorkComponent: workComponent,
      historicalCandidateBinding: historicalCandidateBinding,
      accountUID: Darwin.getuid(),
      rootDevice: rootDevice,
      attemptKind: attemptKind,
      resourceBounds: resourceBounds
    )
  }

  func remove() {
    descriptorCloseIgnoringErrors(workDescriptor)
    descriptorCloseIgnoringErrors(quarantineRootDescriptor)
    base.remove()
  }
}
