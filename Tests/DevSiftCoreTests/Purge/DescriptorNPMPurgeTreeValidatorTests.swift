import Darwin
import Foundation
import Testing

@testable import DevSiftCore

@Suite("Descriptor npm purge tree validators")
struct DescriptorNPMPurgeTreeValidatorTests {
  @Test("Traversal defaults exactly mirror the canonical journal bounds")
  func canonicalBounds() {
    let bounds = QuarantinePurgeJournalResourceBoundsV1.current
    let limits = DescriptorNPMPurgeTraversalLimits.current

    #expect(DescriptorNPMPurgeTraversalLimits.defaults == limits)
    #expect(UInt64(limits.maximumEntries) == bounds.maximumEntries)
    #expect(UInt32(limits.maximumDepth) == bounds.maximumDepth)
    #expect(UInt64(limits.maximumEntriesPerDirectory) == bounds.maximumEntriesPerDirectory)
    #expect(UInt64(limits.maximumRawNameBytes) == bounds.maximumRawNameBytes)
    #expect(
      UInt32(limits.maximumInterruptedSystemCallAttempts)
        == bounds.maximumInterruptedSystemCallAttempts
    )
  }

  @Test("Complete validation remains stricter than remainder validation")
  func completeAndRemainderAreDistinct() throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }

    let historicalBinding = try withPurgeTreeDescriptors(fixture) {
      parent, item, component, snapshot, binding in
      _ = try DescriptorNPMCompletePurgeTreeValidator(checkpoint: {}).validate(
        descriptor: item,
        namedAt: parent,
        component: component,
        expected: snapshot,
        rootDevice: snapshot.identity.device,
        accountUID: Darwin.getuid()
      )
      _ = try DescriptorNPMPurgeRemainderTreeValidator(checkpoint: {}).validate(
        descriptor: item,
        namedAt: parent,
        component: component,
        expectedBinding: binding,
        rootDevice: snapshot.identity.device,
        accountUID: Darwin.getuid()
      )
      return binding
    }

    try FileManager.default.removeItem(
      at: fixture.candidate.appendingPathComponent("content-v2")
    )
    try FileManager.default.removeItem(
      at: fixture.candidate.appendingPathComponent("index-v5")
    )

    try withPurgeTreeDescriptors(fixture) { parent, item, component, snapshot, _ in
      do {
        _ = try DescriptorNPMCompletePurgeTreeValidator(checkpoint: {}).validate(
          descriptor: item,
          namedAt: parent,
          component: component,
          expected: snapshot,
          rootDevice: snapshot.identity.device,
          accountUID: Darwin.getuid()
        )
        Issue.record("A partial tree must not pass complete validation")
      } catch DescriptorNPMPurgeTreeValidationFailure.layoutMismatch {
      }

      let result = try DescriptorNPMPurgeRemainderTreeValidator(checkpoint: {}).validate(
        descriptor: item,
        namedAt: parent,
        component: component,
        expectedBinding: historicalBinding,
        rootDevice: snapshot.identity.device,
        accountUID: Darwin.getuid()
      )
      #expect(result.entryCount == 1)
      #expect(result.maximumObservedDepth == 1)
    }
  }

  @Test("A fully emptied work root is a valid retry remainder")
  func emptyRemainder() throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    for child in try FileManager.default.contentsOfDirectory(
      at: fixture.candidate,
      includingPropertiesForKeys: nil
    ) {
      try FileManager.default.removeItem(at: child)
    }

    try withPurgeTreeDescriptors(fixture) { parent, item, component, snapshot, binding in
      let result = try DescriptorNPMPurgeRemainderTreeValidator(checkpoint: {}).validate(
        descriptor: item,
        namedAt: parent,
        component: component,
        expectedBinding: binding,
        rootDevice: snapshot.identity.device,
        accountUID: Darwin.getuid()
      )
      #expect(result.entryCount == 0)
      #expect(result.rawNameByteCount == 0)
      #expect(result.maximumObservedDepth == 0)
    }
  }

  @Test("Remainder validation rejects names outside the pinned npm grammar")
  func unexpectedName() throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    _ = try fixture.scannerFixture.write("unexpected", bytes: [1], under: fixture.candidate)

    try expectPurgeTreeFailure(.layoutMismatch, fixture: fixture)
  }

  @Test("Remainder validation rejects symlinks and hard-linked files")
  func unsafeDescendants() throws {
    let symbolicLinkFixture = try NPMQuarantinePreflightFixture()
    defer { symbolicLinkFixture.remove() }
    let content = symbolicLinkFixture.candidate.appendingPathComponent("content-v2")
    try FileManager.default.removeItem(at: content)
    try FileManager.default.createSymbolicLink(
      at: content,
      withDestinationURL: symbolicLinkFixture.scannerFixture.outside
    )
    try expectPurgeTreeFailure(.treeUnsafe, fixture: symbolicLinkFixture)

    let hardLinkFixture = try NPMQuarantinePreflightFixture()
    defer { hardLinkFixture.remove() }
    let tag = try hardLinkFixture.scannerFixture.write(
      "CACHEDIR.TAG",
      bytes: [1],
      under: hardLinkFixture.candidate
    )
    _ = try hardLinkFixture.scannerFixture.makeHardLink(
      "_lastverified",
      source: tag,
      under: hardLinkFixture.candidate
    )
    try expectPurgeTreeFailure(.treeUnsafe, fixture: hardLinkFixture)
  }

  @Test("Remainder validation rejects unsafe mode, flags, and ACL metadata")
  func unsafeMetadata() throws {
    let modeFixture = try NPMQuarantinePreflightFixture()
    defer { modeFixture.remove() }
    let unsafeDirectory = modeFixture.candidate.appendingPathComponent("content-v2")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o777],
      ofItemAtPath: unsafeDirectory.path
    )
    try expectPurgeTreeFailure(.treeUnsafe, fixture: modeFixture)

    let flagFixture = try NPMQuarantinePreflightFixture()
    defer { flagFixture.remove() }
    let flagged = flagFixture.candidate.appendingPathComponent("CACHEDIR.TAG")
    _ = try flagFixture.scannerFixture.write(
      "CACHEDIR.TAG",
      bytes: [1],
      under: flagFixture.candidate
    )
    try setPurgeFixtureFlags(UInt32(UF_HIDDEN), at: flagged)
    try expectPurgeTreeFailure(.treeUnsafe, fixture: flagFixture)

    let aclFixture = try NPMQuarantinePreflightFixture()
    defer { aclFixture.remove() }
    try installCurrentUserReadACL(at: aclFixture.candidate)
    try expectPurgeTreeFailure(.treeUnsafe, fixture: aclFixture)
  }

  @Test("Historical identity is required but deletion-mutated link count is not")
  func historicalRootBinding() throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }

    try withPurgeTreeDescriptors(fixture) { parent, item, component, snapshot, binding in
      let deletionMutatedMetadata = QuarantineJournalFileBindingV1(
        device: binding.device,
        inode: binding.inode,
        generation: binding.generation,
        birthSeconds: binding.birthSeconds,
        birthNanoseconds: binding.birthNanoseconds,
        kind: binding.kind,
        ownerUID: binding.ownerUID,
        permissionMode: binding.permissionMode,
        flags: binding.flags,
        linkCount: binding.linkCount + 100
      )
      _ = try DescriptorNPMPurgeRemainderTreeValidator(checkpoint: {}).validate(
        descriptor: item,
        namedAt: parent,
        component: component,
        expectedBinding: deletionMutatedMetadata,
        rootDevice: snapshot.identity.device,
        accountUID: Darwin.getuid()
      )

      let wrong = QuarantineJournalFileBindingV1(
        device: binding.device,
        inode: binding.inode + 1,
        generation: binding.generation,
        birthSeconds: binding.birthSeconds,
        birthNanoseconds: binding.birthNanoseconds,
        kind: binding.kind,
        ownerUID: binding.ownerUID,
        permissionMode: binding.permissionMode,
        flags: binding.flags,
        linkCount: binding.linkCount
      )
      do {
        _ = try DescriptorNPMPurgeRemainderTreeValidator(checkpoint: {}).validate(
          descriptor: item,
          namedAt: parent,
          component: component,
          expectedBinding: wrong,
          rootDevice: snapshot.identity.device,
          accountUID: Darwin.getuid()
        )
        Issue.record("A different historical root inode must fail")
      } catch let failure as DescriptorNPMPurgeTreeValidationFailure {
        #expect(failure == .rootBindingMismatch)
      }
    }
  }

  @Test("Root device and account ownership remain pinned")
  func rootDeviceAndOwner() throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }

    try withPurgeTreeDescriptors(fixture) { parent, item, component, snapshot, binding in
      for (device, owner) in [
        (snapshot.identity.device + 1, Darwin.getuid()),
        (snapshot.identity.device, Darwin.getuid() + 1),
      ] {
        do {
          _ = try DescriptorNPMPurgeRemainderTreeValidator(checkpoint: {}).validate(
            descriptor: item,
            namedAt: parent,
            component: component,
            expectedBinding: binding,
            rootDevice: device,
            accountUID: owner
          )
          Issue.record("A mismatched device or account must fail")
        } catch let failure as DescriptorNPMPurgeTreeValidationFailure {
          #expect(failure == .rootBindingMismatch)
        }
      }
    }
  }

  @Test("Special nodes are never accepted as cache files")
  func specialNode() throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let fifo = fixture.candidate.appendingPathComponent("CACHEDIR.TAG")
    try makePurgeFixtureFIFO(at: fifo)

    try expectPurgeTreeFailure(.treeUnsafe, fixture: fixture)
  }

  @Test("A replacement of the held work-root name is detected")
  func rootNameSwap() throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let candidate = fixture.candidate
    let displaced = fixture.root.appendingPathComponent("displaced-cacache")
    let swap = PurgeOneShot()

    try withPurgeTreeDescriptors(fixture) { parent, item, component, snapshot, binding in
      do {
        _ = try DescriptorNPMPurgeRemainderTreeValidator(
          checkpoint: {},
          beforeTraversalEntry: { _, _ in
            try swap.run {
              try FileManager.default.moveItem(at: candidate, to: displaced)
              try FileManager.default.createDirectory(
                at: candidate, withIntermediateDirectories: false)
            }
          }
        ).validate(
          descriptor: item,
          namedAt: parent,
          component: component,
          expectedBinding: binding,
          rootDevice: snapshot.identity.device,
          accountUID: Darwin.getuid()
        )
        Issue.record("A replaced work-root name must fail")
      } catch let failure as DescriptorNPMPurgeTreeValidationFailure {
        #expect(failure == .treeChanged)
      }
    }
  }

  @Test("Entry, depth, per-directory, and raw-name bounds fail closed")
  func resourceBounds() throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let limits = [
      DescriptorNPMPurgeTraversalLimits(
        maximumEntries: 1,
        maximumDepth: 32,
        maximumEntriesPerDirectory: 100_000,
        maximumRawNameBytes: 64 * 1_024 * 1_024
      ),
      DescriptorNPMPurgeTraversalLimits(
        maximumEntries: 1_000_000,
        maximumDepth: 2,
        maximumEntriesPerDirectory: 100_000,
        maximumRawNameBytes: 64 * 1_024 * 1_024
      ),
      DescriptorNPMPurgeTraversalLimits(
        maximumEntries: 1_000_000,
        maximumDepth: 32,
        maximumEntriesPerDirectory: 1,
        maximumRawNameBytes: 64 * 1_024 * 1_024
      ),
      DescriptorNPMPurgeTraversalLimits(
        maximumEntries: 1_000_000,
        maximumDepth: 32,
        maximumEntriesPerDirectory: 100_000,
        maximumRawNameBytes: 5
      ),
    ]

    for limit in limits {
      try withPurgeTreeDescriptors(fixture) { parent, item, component, snapshot, binding in
        do {
          _ = try DescriptorNPMPurgeRemainderTreeValidator(
            checkpoint: {},
            limits: limit
          ).validate(
            descriptor: item,
            namedAt: parent,
            component: component,
            expectedBinding: binding,
            rootDevice: snapshot.identity.device,
            accountUID: Darwin.getuid()
          )
          Issue.record("Expected a bounded traversal failure")
        } catch let failure as DescriptorNPMPurgeTreeValidationFailure {
          #expect(failure == .traversalLimitExceeded)
        }
      }
    }
  }

  @Test("Every traversal bound accepts its exact fixture boundary")
  func exactResourceBounds() throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }

    try withPurgeTreeDescriptors(fixture) { parent, item, component, snapshot, binding in
      let observed = try DescriptorNPMPurgeRemainderTreeValidator(checkpoint: {}).validate(
        descriptor: item,
        namedAt: parent,
        component: component,
        expectedBinding: binding,
        rootDevice: snapshot.identity.device,
        accountUID: Darwin.getuid()
      )
      let exact = DescriptorNPMPurgeTraversalLimits(
        maximumEntries: observed.entryCount,
        maximumDepth: observed.maximumObservedDepth,
        maximumEntriesPerDirectory: 3,
        maximumRawNameBytes: observed.rawNameByteCount
      )
      let exactResult = try DescriptorNPMPurgeRemainderTreeValidator(
        checkpoint: {},
        limits: exact
      ).validate(
        descriptor: item,
        namedAt: parent,
        component: component,
        expectedBinding: binding,
        rootDevice: snapshot.identity.device,
        accountUID: Darwin.getuid()
      )
      #expect(exactResult == observed)

      _ = try DescriptorNPMCompletePurgeTreeValidator(
        checkpoint: {},
        limits: exact
      ).validate(
        descriptor: item,
        namedAt: parent,
        component: component,
        expected: snapshot,
        rootDevice: snapshot.identity.device,
        accountUID: Darwin.getuid()
      )
    }
  }

  @Test("The purge traversal visits each directory snapshot in byte-sorted order")
  func deterministicTraversal() throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let recorder = PurgeDepthRecorder()

    try withPurgeTreeDescriptors(fixture) { parent, item, component, snapshot, binding in
      _ = try DescriptorNPMPurgeRemainderTreeValidator(
        checkpoint: {},
        beforeTraversalEntry: { ordinal, depth in
          recorder.record(ordinal: ordinal, depth: depth)
        }
      ).validate(
        descriptor: item,
        namedAt: parent,
        component: component,
        expectedBinding: binding,
        rootDevice: snapshot.identity.device,
        accountUID: Darwin.getuid()
      )
    }

    #expect(recorder.ordinals == Array(1...10))
    #expect(recorder.depths == [1, 2, 3, 4, 5, 1, 2, 3, 4, 1])
  }

  @Test("Invalid syscall retry limits fail before reading the tree")
  func invalidRetryLimit() throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let invalid = DescriptorNPMPurgeTraversalLimits(
      maximumEntries: 1,
      maximumDepth: 1,
      maximumEntriesPerDirectory: 1,
      maximumRawNameBytes: 1,
      maximumInterruptedSystemCallAttempts: 0
    )

    try withPurgeTreeDescriptors(fixture) { parent, item, component, snapshot, binding in
      do {
        _ = try DescriptorNPMPurgeRemainderTreeValidator(
          checkpoint: {},
          limits: invalid
        ).validate(
          descriptor: item,
          namedAt: parent,
          component: component,
          expectedBinding: binding,
          rootDevice: snapshot.identity.device,
          accountUID: Darwin.getuid()
        )
        Issue.record("An invalid retry limit must fail")
      } catch let failure as DescriptorNPMPurgeTreeValidationFailure {
        #expect(failure == .invalidLimits)
      }
    }
  }

  @Test("A cancellation checkpoint stops read-only validation")
  func cancellation() throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }

    try withPurgeTreeDescriptors(fixture) { parent, item, component, snapshot, binding in
      do {
        _ = try DescriptorNPMPurgeRemainderTreeValidator(
          checkpoint: { throw CancellationError() }
        ).validate(
          descriptor: item,
          namedAt: parent,
          component: component,
          expectedBinding: binding,
          rootDevice: snapshot.identity.device,
          accountUID: Darwin.getuid()
        )
        Issue.record("Expected cancellation")
      } catch is CancellationError {
      }
    }
  }
}

private func withPurgeTreeDescriptors<ResultValue>(
  _ fixture: NPMQuarantinePreflightFixture,
  _ body: (
    Int32,
    Int32,
    DescriptorPathComponent,
    DescriptorStatSnapshot,
    QuarantineJournalFileBindingV1
  ) throws -> ResultValue
) throws -> ResultValue {
  let parent = try descriptorOpenRoot(fixture.root)
  defer { descriptorCloseIgnoringErrors(parent) }
  let component = try #require(DescriptorPathComponent(Array("_cacache".utf8)))
  let item = try descriptorOpenTrustedDirectory(at: parent, component: component)
  defer { descriptorCloseIgnoringErrors(item) }
  let snapshot = try DescriptorStatSnapshot.read(from: item)
  let binding = try #require(QuarantineJournalFileBindingV1(snapshot: snapshot))
  return try body(parent, item, component, snapshot, binding)
}

private func expectPurgeTreeFailure(
  _ expected: DescriptorNPMPurgeTreeValidationFailure,
  fixture: NPMQuarantinePreflightFixture,
  sourceLocation: SourceLocation = #_sourceLocation
) throws {
  try withPurgeTreeDescriptors(fixture) { parent, item, component, snapshot, binding in
    do {
      _ = try DescriptorNPMPurgeRemainderTreeValidator(checkpoint: {}).validate(
        descriptor: item,
        namedAt: parent,
        component: component,
        expectedBinding: binding,
        rootDevice: snapshot.identity.device,
        accountUID: Darwin.getuid()
      )
      Issue.record("Expected purge tree failure \(expected)", sourceLocation: sourceLocation)
    } catch let failure as DescriptorNPMPurgeTreeValidationFailure {
      #expect(failure == expected, sourceLocation: sourceLocation)
    }
  }
}

private func setPurgeFixtureFlags(_ flags: UInt32, at url: URL) throws {
  var failureCode = EINVAL
  let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
    guard let path else { return -1 }
    let status = Darwin.chflags(path, flags)
    if status != 0 { failureCode = errno }
    return status
  }
  guard result == 0 else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(failureCode))
  }
}

private func makePurgeFixtureFIFO(at url: URL) throws {
  var failureCode = EINVAL
  let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
    guard let path else { return -1 }
    let status = Darwin.mkfifo(path, 0o600)
    if status != 0 { failureCode = errno }
    return status
  }
  guard result == 0 else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(failureCode))
  }
}

private final class PurgeOneShot: @unchecked Sendable {
  private let lock = NSLock()
  private var hasRun = false

  func run(_ body: () throws -> Void) rethrows {
    let shouldRun = lock.withLock {
      guard !hasRun else { return false }
      hasRun = true
      return true
    }
    if shouldRun {
      try body()
    }
  }
}

private final class PurgeDepthRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedOrdinals: [Int] = []
  private var storedDepths: [Int] = []

  var ordinals: [Int] { lock.withLock { storedOrdinals } }
  var depths: [Int] { lock.withLock { storedDepths } }

  func record(ordinal: Int, depth: Int) {
    lock.withLock {
      storedOrdinals.append(ordinal)
      storedDepths.append(depth)
    }
  }
}
