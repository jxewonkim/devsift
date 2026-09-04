import Darwin
import Foundation
import Testing

@testable import DevSiftCore

@Suite("Descriptor exclusive quarantine mover")
struct DescriptorExclusiveQuarantineMoverTests {
  @Test("An approved cache moves exclusively into a private root without deletion")
  func happyPath() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let unrelated = try fixture.scannerFixture.write(
      "unrelated", bytes: [0xAA], under: fixture.root)
    let outside = try fixture.scannerFixture.write(
      "outside-sentinel",
      bytes: [0xBB],
      under: fixture.scannerFixture.outside
    )
    let claim = try await fixture.makeClaim()
    let expectedIdentity = claim.approval.reviewedManifest.entries[0].expectedIdentity
    let outsideBefore = try treeSnapshot(at: fixture.scannerFixture.outside)
    let unrelatedBefore = try NodeSnapshot.read(from: unrelated)

    let report = try move(
      claim,
      fixture: fixture,
      mover: supportedExecutionTestMover(nonceBytes: { _ in [UInt8](repeating: 0x11, count: 16) })
    )
    let location = try quarantinedLocation(from: report, sourceNameWasRecreated: false)
    let destination = try locationURL(location, root: fixture.root)
    let quarantineRoot = fixture.root.appendingPathComponent(".devsift-quarantine-v1")

    #expect(!FileManager.default.fileExists(atPath: fixture.candidate.path))
    #expect(try fileIdentity(at: destination) == expectedIdentity)
    #expect(
      try Data(
        contentsOf: destination.appendingPathComponent(
          "content-v2/sha512/aa/bb/0123456789abcdef"
        )
      ) == Data([1, 2, 3])
    )
    #expect(try NodeSnapshot.read(from: quarantineRoot).mode & mode_t(0o7777) == mode_t(0o700))
    #expect(try NodeSnapshot.read(from: unrelated) == unrelatedBefore)
    #expect(try Data(contentsOf: outside) == Data([0xBB]))
    #expect(try treeSnapshot(at: fixture.scannerFixture.outside) == outsideBefore)
    #expect(report.quarantineRootMutation == .created)
    #expect(!report.cancellationWasObservedAfterRename)
    #expect(!report.isDurablyRecorded)
    #expect(!report.isCrashRecoverable)
    #expect(!report.performedPermanentDeletion)
  }

  @Test("The production capability and ACL adapters permit an APFS fixture move")
  func productionAdaptersHappyPath() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()

    let report = try move(
      claim,
      fixture: fixture,
      mover: DescriptorExclusiveQuarantineMover()
    )

    let supportsResolveBeneathRename = ProcessInfo.processInfo.isOperatingSystemAtLeast(
      OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
    )
    guard supportsResolveBeneathRename else {
      #expect(report.status == .notMoved(.exclusiveRenameUnsupported))
      #expect(report.quarantineRootMutation == .none)
      #expect(FileManager.default.fileExists(atPath: fixture.candidate.path))
      #expect(
        !FileManager.default.fileExists(
          atPath: fixture.root.appendingPathComponent(".devsift-quarantine-v1").path
        ))
      return
    }

    let location = try quarantinedLocation(from: report, sourceNameWasRecreated: false)

    #expect(!FileManager.default.fileExists(atPath: fixture.candidate.path))
    #expect(
      FileManager.default.fileExists(atPath: try locationURL(location, root: fixture.root).path))
  }

  @Test("Missing beneath-root rename support blocks every namespace mutation")
  func unsupportedResolveBeneathRename() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let mkdirState = MoverTestState()
    let renameState = MoverTestState()
    let mover = supportedExecutionTestMover(
      supportsResolveBeneathRename: { false },
      makeQuarantineRoot: { _, _ in
        mkdirState.incrementCallCount()
        return .created
      },
      renameExclusive: { _, _, _, _, _ in
        renameState.incrementCallCount()
        return .succeeded
      }
    )

    let report = try move(claim, fixture: fixture, mover: mover)

    #expect(report.status == .notMoved(.exclusiveRenameUnsupported))
    #expect(report.quarantineRootMutation == .none)
    #expect(mkdirState.callCount == 0)
    #expect(renameState.callCount == 0)
    #expect(FileManager.default.fileExists(atPath: fixture.candidate.path))
    #expect(!report.performedPermanentDeletion)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent(".devsift-quarantine-v1").path
      ))
  }

  @Test("Cancellation immediately before rename cannot move the source")
  func cancellationImmediatelyBeforeRename() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let state = MoverTestState()
    let hooks = DescriptorExclusiveQuarantineMoverHooks(
      afterFinalSourceValidationBeforeRename: { _ in state.setFlag(true) }
    )
    let mover = supportedExecutionTestMover(
      renameExclusive: { _, _, _, _, _ in
        state.incrementCallCount()
        return .succeeded
      },
      cancellationIsRequested: { state.flag },
      hooks: hooks
    )

    let report = try move(claim, fixture: fixture, mover: mover)

    #expect(report.status == .notMoved(.cancelled))
    #expect(state.callCount == 0)
    #expect(FileManager.default.fileExists(atPath: fixture.candidate.path))
    #expect(!report.performedPermanentDeletion)
  }

  @Test("Cancellation after rename is latched without hiding the moved result")
  func cancellationAfterRename() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let state = MoverTestState()
    let hooks = DescriptorExclusiveQuarantineMoverHooks(
      afterRenameReturn: { _, result in
        if result == .succeeded { state.setFlag(true) }
      }
    )
    let mover = supportedExecutionTestMover(
      nonceBytes: { _ in [UInt8](repeating: 0x22, count: 16) },
      cancellationIsRequested: { state.flag },
      hooks: hooks
    )

    let report = try move(claim, fixture: fixture, mover: mover)
    let location = try quarantinedLocation(from: report, sourceNameWasRecreated: false)

    #expect(report.cancellationWasObservedAfterRename)
    #expect(!FileManager.default.fileExists(atPath: fixture.candidate.path))
    #expect(
      FileManager.default.fileExists(atPath: try locationURL(location, root: fixture.root).path))
  }

  @Test("Sixteen occupied destinations are preserved and exhaust the fixed retry bound")
  func destinationCollisionBound() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let quarantineRoot = try fixture.scannerFixture.makeDirectory(
      ".devsift-quarantine-v1",
      under: fixture.root
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: quarantineRoot.path
    )
    var occupied: [(URL, Data)] = []
    for attempt in 0..<DescriptorExclusiveQuarantineMover.maximumDestinationAttempts {
      let bytes = Data([UInt8(attempt), 0xA5])
      let nonce = try #require(deterministicNonce(attempt))
      let url = try fixture.scannerFixture.write(
        destinationName(nonce: nonce),
        bytes: Array(bytes),
        under: quarantineRoot
      )
      occupied.append((url, bytes))
    }

    let report = try move(
      claim,
      fixture: fixture,
      mover: supportedExecutionTestMover(nonceBytes: deterministicNonce)
    )

    #expect(report.status == .notMoved(.destinationCollisionLimitExceeded))
    #expect(FileManager.default.fileExists(atPath: fixture.candidate.path))
    for (url, expected) in occupied {
      #expect(try Data(contentsOf: url) == expected)
    }
    #expect(report.quarantineRootMutation == .none)
    #expect(!report.performedPermanentDeletion)
  }

  @Test(
    "A symlink, file, or permissive quarantine root fails closed",
    arguments: [
      UnsafeQuarantineRootKind.symbolicLink,
      .regularFile,
      .permissiveDirectory,
    ])
  func unsafeQuarantineRoot(kind: UnsafeQuarantineRootKind) async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let root = fixture.root.appendingPathComponent(".devsift-quarantine-v1")
    switch kind {
    case .symbolicLink:
      try FileManager.default.createSymbolicLink(
        at: root,
        withDestinationURL: fixture.scannerFixture.outside
      )
    case .regularFile:
      try Data([7]).write(to: root)
    case .permissiveDirectory:
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
    }

    let report = try move(claim, fixture: fixture, mover: supportedExecutionTestMover())

    switch kind {
    case .symbolicLink, .regularFile:
      guard case .notMoved(.quarantineRootUnavailable) = report.status else {
        Issue.record("Expected an unavailable quarantine root, received \(report.status)")
        return
      }
    case .permissiveDirectory:
      #expect(report.status == .notMoved(.quarantineRootUnsafe))
    }
    #expect(FileManager.default.fileExists(atPath: fixture.candidate.path))
    #expect(!report.performedPermanentDeletion)
  }

  @Test("Missing exclusive-rename capability blocks mutation")
  func unsupportedVolumeCapability() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let mover = supportedExecutionTestMover(
      volumeCapabilities: {
        .success(
          DescriptorQuarantineVolumeCapabilities(
            supportsExclusiveRename: false,
            supportsPOSIXPermissions: true
          )
        )
      }
    )

    let report = try move(claim, fixture: fixture, mover: mover)

    #expect(report.status == .notMoved(.exclusiveRenameUnsupported))
    #expect(report.quarantineRootMutation == .created)
    #expect(FileManager.default.fileExists(atPath: fixture.candidate.path))
  }

  @Test("Missing POSIX permission capability blocks mutation")
  func unsupportedPOSIXPermissionCapability() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let mover = supportedExecutionTestMover(
      volumeCapabilities: {
        .success(
          DescriptorQuarantineVolumeCapabilities(
            supportsExclusiveRename: true,
            supportsPOSIXPermissions: false
          )
        )
      }
    )

    let report = try move(claim, fixture: fixture, mover: mover)

    #expect(report.status == .notMoved(.exclusiveRenameUnsupported))
    #expect(FileManager.default.fileExists(atPath: fixture.candidate.path))
    #expect(!report.performedPermanentDeletion)
  }

  @Test("A final validation read failure is not mislabeled as a rename rejection")
  func preRenameValidationUnavailable() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let capabilityState = MoverTestState()
    let renameState = MoverTestState()
    let mover = supportedExecutionTestMover(
      volumeCapabilities: {
        let call = capabilityState.nextCallCount()
        guard call > 1 else {
          return .success(
            DescriptorQuarantineVolumeCapabilities(
              supportsExclusiveRename: true,
              supportsPOSIXPermissions: true
            )
          )
        }
        return .failure(.inputOutput)
      },
      renameExclusive: { _, _, _, _, _ in
        renameState.incrementCallCount()
        return .succeeded
      }
    )

    let report = try move(claim, fixture: fixture, mover: mover)

    #expect(report.status == .notMoved(.preRenameValidationUnavailable(.inputOutput)))
    #expect(capabilityState.callCount == 2)
    #expect(renameState.callCount == 0)
    #expect(FileManager.default.fileExists(atPath: fixture.candidate.path))
    #expect(!report.performedPermanentDeletion)
  }

  @Test("Injected extended ACL evidence blocks the quarantine root")
  func injectedExtendedACL() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()

    let report = try move(
      claim,
      fixture: fixture,
      mover: supportedExecutionTestMover(hasExtendedACL: { .success(true) })
    )

    #expect(report.status == .notMoved(.quarantineRootUnsafe))
    #expect(FileManager.default.fileExists(atPath: fixture.candidate.path))
    #expect(!report.performedPermanentDeletion)
  }

  @Test("The production ACL adapter rejects a real extended ACL")
  func productionExtendedACL() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let quarantineRoot = try fixture.scannerFixture.makeDirectory(
      ".devsift-quarantine-v1",
      under: fixture.root
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: quarantineRoot.path
    )
    try installCurrentUserReadACL(at: quarantineRoot)

    let report = try move(
      claim,
      fixture: fixture,
      mover: DescriptorExclusiveQuarantineMover()
    )

    #expect(report.status == .notMoved(.quarantineRootUnsafe))
    #expect(FileManager.default.fileExists(atPath: fixture.candidate.path))
    #expect(!report.performedPermanentDeletion)
  }

  @Test("An indeterminate mkdir failure is reported once without rename")
  func mkdirEIOIsIndeterminate() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let mkdirState = MoverTestState()
    let renameState = MoverTestState()
    let mover = supportedExecutionTestMover(
      makeQuarantineRoot: { _, _ in
        mkdirState.incrementCallCount()
        return .failed(EIO)
      },
      renameExclusive: { _, _, _, _, _ in
        renameState.incrementCallCount()
        return .succeeded
      }
    )

    let report = try move(claim, fixture: fixture, mover: mover)

    #expect(report.status == .notMoved(.quarantineRootUnavailable(.inputOutput)))
    #expect(report.quarantineRootMutation == .indeterminate)
    #expect(mkdirState.callCount == 1)
    #expect(renameState.callCount == 0)
    #expect(FileManager.default.fileExists(atPath: fixture.candidate.path))
  }

  @Test("A definite EIO rename failure is reported without blind retry")
  func renameEIODoesNotRetry() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let state = MoverTestState()
    let mover = supportedExecutionTestMover(renameExclusive: { _, _, _, _, flags in
      state.incrementCallCount()
      if flags != DescriptorExclusiveQuarantineMover.renameFlags {
        state.record(MoverTestError.invalidRenameFlags)
      }
      return .failed(EIO)
    })

    let report = try move(claim, fixture: fixture, mover: mover)

    #expect(report.status == .notMoved(.renameRejected(.inputOutput)))
    try #require(state.errorDescription == nil)
    #expect(state.callCount == 1)
    #expect(FileManager.default.fileExists(atPath: fixture.candidate.path))
    #expect(!report.performedPermanentDeletion)
  }

  @Test("A definite EXDEV rename failure is reported without blind retry")
  func renameEXDEVDoesNotRetry() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let state = MoverTestState()
    let mover = supportedExecutionTestMover(renameExclusive: { _, _, _, _, flags in
      state.incrementCallCount()
      if flags != DescriptorExclusiveQuarantineMover.renameFlags {
        state.record(MoverTestError.invalidRenameFlags)
      }
      return .failed(EXDEV)
    })

    let report = try move(claim, fixture: fixture, mover: mover)

    try #require(state.errorDescription == nil)
    #expect(report.status == .notMoved(.renameRejected(.crossDevice)))
    #expect(state.callCount == 1)
    #expect(FileManager.default.fileExists(atPath: fixture.candidate.path))
    #expect(!report.performedPermanentDeletion)
  }

  @Test("A last-instant source replacement is surfaced for manual recovery")
  func sourceReplacementBeforeSyscall() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let unrelated = try fixture.scannerFixture.write(
      "unrelated", bytes: [0x31], under: fixture.root)
    let outsideBefore = try treeSnapshot(at: fixture.scannerFixture.outside)
    let claim = try await fixture.makeClaim()
    let approvedIdentity = claim.approval.reviewedManifest.entries[0].expectedIdentity
    let savedApproved = fixture.root.appendingPathComponent("approved-still-here")
    let state = MoverTestState()
    let hooks = DescriptorExclusiveQuarantineMoverHooks(
      afterFinalSourceValidationBeforeRename: { _ in
        do {
          try FileManager.default.moveItem(at: fixture.candidate, to: savedApproved)
          try FileManager.default.createDirectory(
            at: fixture.candidate,
            withIntermediateDirectories: false
          )
          try Data([0xDE, 0xAD]).write(
            to: fixture.candidate.appendingPathComponent("wrong-object")
          )
        } catch {
          state.record(error)
        }
      }
    )
    let mover = supportedExecutionTestMover(
      nonceBytes: { _ in [UInt8](repeating: 0x33, count: 16) },
      hooks: hooks
    )

    let report = try move(claim, fixture: fixture, mover: mover)
    try #require(state.errorDescription == nil)
    let recovery = try manualRecovery(from: report)
    let location = try #require(recovery.location)
    let destination = try locationURL(location, root: fixture.root)

    #expect(recovery.reason == .destinationCouldNotBeVerified)
    #expect(location.relativePath.rawComponents.count == 2)
    #expect(
      location.relativePath.rawComponents[0]
        == DescriptorExclusiveQuarantineMover.quarantineRootBytes)
    #expect(!FileManager.default.fileExists(atPath: fixture.candidate.path))
    #expect(try fileIdentity(at: savedApproved) == approvedIdentity)
    #expect(
      try Data(contentsOf: destination.appendingPathComponent("wrong-object"))
        == Data([0xDE, 0xAD]))
    #expect(try Data(contentsOf: unrelated) == Data([0x31]))
    #expect(try treeSnapshot(at: fixture.scannerFixture.outside) == outsideBefore)
    #expect(!report.performedPermanentDeletion)
  }

  @Test("A quarantine-root reparent cannot move the candidate outside its approved root")
  func quarantineRootReparentBeforeSyscall() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let quarantineRoot = fixture.root.appendingPathComponent(".devsift-quarantine-v1")
    let detachedRoot = fixture.scannerFixture.outside.appendingPathComponent(
      "detached-quarantine"
    )
    let state = MoverTestState()
    let hooks = DescriptorExclusiveQuarantineMoverHooks(
      afterFinalSourceValidationBeforeRename: { _ in
        do {
          try FileManager.default.moveItem(at: quarantineRoot, to: detachedRoot)
        } catch {
          state.record(error)
        }
      }
    )

    let report = try move(
      claim,
      fixture: fixture,
      mover: supportedExecutionTestMover(
        nonceBytes: { _ in [UInt8](repeating: 0x3A, count: 16) },
        hooks: hooks
      )
    )
    try #require(state.errorDescription == nil)
    let recovery = try manualRecovery(from: report)

    #expect(recovery.reason == .parentBindingChanged)
    #expect(recovery.location == nil)
    #expect(FileManager.default.fileExists(atPath: fixture.candidate.path))
    #expect(!FileManager.default.fileExists(atPath: quarantineRoot.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: detachedRoot.path).isEmpty)
    #expect(report.quarantineRootMutation == .created)
    #expect(!report.performedPermanentDeletion)
  }

  @Test("A same-account quarantine-root replacement cannot become a false success")
  func quarantineRootReplacementBeforeSyscall() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let approvedIdentity = claim.approval.reviewedManifest.entries[0].expectedIdentity
    let quarantineRoot = fixture.root.appendingPathComponent(".devsift-quarantine-v1")
    let detachedRoot = fixture.scannerFixture.outside.appendingPathComponent(
      "detached-quarantine"
    )
    let state = MoverTestState()
    let hooks = DescriptorExclusiveQuarantineMoverHooks(
      afterFinalSourceValidationBeforeRename: { _ in
        do {
          try FileManager.default.moveItem(at: quarantineRoot, to: detachedRoot)
          try FileManager.default.createDirectory(
            at: quarantineRoot,
            withIntermediateDirectories: false
          )
          try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: quarantineRoot.path
          )
        } catch {
          state.record(error)
        }
      }
    )

    let report = try move(
      claim,
      fixture: fixture,
      mover: supportedExecutionTestMover(
        nonceBytes: { _ in [UInt8](repeating: 0x3B, count: 16) },
        hooks: hooks
      )
    )
    try #require(state.errorDescription == nil)
    let recovery = try manualRecovery(from: report)
    let replacementNames = try FileManager.default.contentsOfDirectory(atPath: quarantineRoot.path)
    let replacementName = try #require(replacementNames.first)
    let movedObject = quarantineRoot.appendingPathComponent(replacementName)

    #expect(recovery.reason == .parentBindingChanged)
    #expect(recovery.location == nil)
    #expect(replacementNames.count == 1)
    #expect(!FileManager.default.fileExists(atPath: fixture.candidate.path))
    #expect(try fileIdentity(at: movedObject) == approvedIdentity)
    #expect(try FileManager.default.contentsOfDirectory(atPath: detachedRoot.path).isEmpty)
    #expect(report.quarantineRootMutation == .created)
    #expect(!report.performedPermanentDeletion)
  }

  @Test("A recreated source is retained beside the quarantined approved object")
  func sourceRecreatedAfterRename() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let state = MoverTestState()
    let hooks = DescriptorExclusiveQuarantineMoverHooks(
      afterRenameReturn: { _, result in
        guard result == .succeeded else { return }
        do {
          try FileManager.default.createDirectory(
            at: fixture.candidate,
            withIntermediateDirectories: false
          )
          try Data([0x44]).write(to: fixture.candidate.appendingPathComponent("new-source"))
        } catch {
          state.record(error)
        }
      }
    )

    let report = try move(
      claim,
      fixture: fixture,
      mover: supportedExecutionTestMover(
        nonceBytes: { _ in [UInt8](repeating: 0x44, count: 16) },
        hooks: hooks
      )
    )
    try #require(state.errorDescription == nil)
    let location = try quarantinedLocation(from: report, sourceNameWasRecreated: true)

    #expect(
      try Data(contentsOf: fixture.candidate.appendingPathComponent("new-source")) == Data([0x44]))
    #expect(
      FileManager.default.fileExists(atPath: try locationURL(location, root: fixture.root).path))
    #expect(!report.performedPermanentDeletion)
  }

  @Test("A post-rename metadata mismatch can roll back without replacing anything")
  func successfulRollback() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let approvedIdentity = claim.approval.reviewedManifest.entries[0].expectedIdentity
    let originalMode = try NodeSnapshot.read(from: fixture.candidate).mode & mode_t(0o7777)
    let mismatchMode = originalMode == mode_t(0o700) ? 0o755 : 0o700
    let destination = deterministicDestination(0x66, root: fixture.root)
    let state = MoverTestState()
    let hooks = DescriptorExclusiveQuarantineMoverHooks(
      afterRenameReturn: { _, result in
        guard result == .succeeded else { return }
        do {
          try FileManager.default.setAttributes(
            [.posixPermissions: mismatchMode],
            ofItemAtPath: destination.path
          )
        } catch {
          state.record(error)
        }
      },
      beforeRollback: {
        do {
          try FileManager.default.setAttributes(
            [.posixPermissions: Int(originalMode)],
            ofItemAtPath: destination.path
          )
        } catch {
          state.record(error)
        }
      }
    )

    let report = try move(
      claim,
      fixture: fixture,
      mover: supportedExecutionTestMover(
        nonceBytes: { _ in [UInt8](repeating: 0x66, count: 16) },
        hooks: hooks
      )
    )

    try #require(state.errorDescription == nil)
    #expect(report.status == .rolledBack(.movedObjectDidNotMatchApproval))
    #expect(try fileIdentity(at: fixture.candidate) == approvedIdentity)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(
      try Data(
        contentsOf: fixture.candidate.appendingPathComponent(
          "content-v2/sha512/aa/bb/0123456789abcdef"
        )
      ) == Data([1, 2, 3])
    )
    #expect(!report.performedPermanentDeletion)
  }

  @Test("A restored candidate with changed security metadata requires recovery")
  func restoredCandidateMismatch() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let approvedIdentity = claim.approval.reviewedManifest.entries[0].expectedIdentity
    let originalMode = try NodeSnapshot.read(from: fixture.candidate).mode & mode_t(0o7777)
    let mismatchMode = originalMode == mode_t(0o700) ? 0o755 : 0o700
    let destination = deterministicDestination(0x67, root: fixture.root)
    let state = MoverTestState()
    let hooks = DescriptorExclusiveQuarantineMoverHooks(
      afterRenameReturn: { _, result in
        guard result == .succeeded else { return }
        do {
          try FileManager.default.setAttributes(
            [.posixPermissions: mismatchMode],
            ofItemAtPath: destination.path
          )
        } catch {
          state.record(error)
        }
      }
    )

    let report = try move(
      claim,
      fixture: fixture,
      mover: supportedExecutionTestMover(
        nonceBytes: { _ in [UInt8](repeating: 0x67, count: 16) },
        hooks: hooks
      )
    )
    try #require(state.errorDescription == nil)
    let recovery = try manualRecovery(from: report)

    #expect(recovery.reason == .restoredObjectDidNotMatchApproval)
    #expect(recovery.location == nil)
    #expect(try fileIdentity(at: fixture.candidate) == approvedIdentity)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(!report.performedPermanentDeletion)
  }

  @Test("Cancellation observed during rollback validation is latched")
  func rollbackValidationCancellationLatch() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let originalMode = try NodeSnapshot.read(from: fixture.candidate).mode & mode_t(0o7777)
    let mismatchMode = originalMode == mode_t(0o700) ? 0o755 : 0o700
    let destination = deterministicDestination(0x68, root: fixture.root)
    let state = MoverTestState()
    let hooks = DescriptorExclusiveQuarantineMoverHooks(
      afterRenameReturn: { _, result in
        guard result == .succeeded else { return }
        do {
          try FileManager.default.setAttributes(
            [.posixPermissions: mismatchMode],
            ofItemAtPath: destination.path
          )
        } catch {
          state.record(error)
        }
      },
      beforeRollback: {
        do {
          try FileManager.default.setAttributes(
            [.posixPermissions: Int(originalMode)],
            ofItemAtPath: destination.path
          )
        } catch {
          state.record(error)
        }
      }
    )
    let mover = supportedExecutionTestMover(
      nonceBytes: { _ in [UInt8](repeating: 0x68, count: 16) },
      hasExtendedACL: {
        if state.nextCallCount() == 4 { state.setFlag(true) }
        return .success(false)
      },
      cancellationIsRequested: { state.flag },
      hooks: hooks
    )

    let report = try move(claim, fixture: fixture, mover: mover)
    try #require(state.errorDescription == nil)

    #expect(report.status == .rolledBack(.movedObjectDidNotMatchApproval))
    #expect(report.cancellationWasObservedAfterRename)
    #expect(state.callCount >= 4)
    #expect(FileManager.default.fileExists(atPath: fixture.candidate.path))
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(!report.performedPermanentDeletion)
  }

  @Test("A failed reverse syscall cannot claim another actor's completed rollback")
  func rollbackAttributionRace() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let approvedIdentity = claim.approval.reviewedManifest.entries[0].expectedIdentity
    let originalMode = try NodeSnapshot.read(from: fixture.candidate).mode & mode_t(0o7777)
    let mismatchMode = originalMode == mode_t(0o700) ? 0o755 : 0o700
    let destination = deterministicDestination(0x6A, root: fixture.root)
    let state = MoverTestState()
    let hooks = DescriptorExclusiveQuarantineMoverHooks(
      afterRenameReturn: { _, result in
        guard result == .succeeded else { return }
        do {
          try FileManager.default.setAttributes(
            [.posixPermissions: mismatchMode],
            ofItemAtPath: destination.path
          )
        } catch {
          state.record(error)
        }
      },
      beforeRollback: {
        do {
          try FileManager.default.setAttributes(
            [.posixPermissions: Int(originalMode)],
            ofItemAtPath: destination.path
          )
          try FileManager.default.moveItem(at: destination, to: fixture.candidate)
        } catch {
          state.record(error)
        }
      }
    )
    let mover = supportedExecutionTestMover(
      nonceBytes: { _ in [UInt8](repeating: 0x6A, count: 16) },
      renameExclusive: { from, fromName, to, toName, flags in
        let call = state.nextCallCount()
        guard call > 1 else {
          return testRenameExclusive(from, fromName, to, toName, flags)
        }
        return .failed(EIO)
      },
      hooks: hooks
    )

    let report = try move(claim, fixture: fixture, mover: mover)
    try #require(state.errorDescription == nil)
    let recovery = try manualRecovery(from: report)

    #expect(recovery.reason == .rollbackOutcomeIndeterminate)
    #expect(recovery.location == nil)
    #expect(state.callCount == 2)
    #expect(try fileIdentity(at: fixture.candidate) == approvedIdentity)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(!report.performedPermanentDeletion)
  }

  @Test("An EIO rollback preserves the approved destination for manual recovery")
  func rollbackEIO() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let approvedIdentity = claim.approval.reviewedManifest.entries[0].expectedIdentity
    let originalMode = try NodeSnapshot.read(from: fixture.candidate).mode & mode_t(0o7777)
    let mismatchMode = originalMode == mode_t(0o700) ? 0o755 : 0o700
    let destination = deterministicDestination(0x77, root: fixture.root)
    let state = MoverTestState()
    let hooks = DescriptorExclusiveQuarantineMoverHooks(
      afterRenameReturn: { _, result in
        guard result == .succeeded else { return }
        do {
          try FileManager.default.setAttributes(
            [.posixPermissions: mismatchMode],
            ofItemAtPath: destination.path
          )
        } catch {
          state.record(error)
        }
      }
    )
    let mover = supportedExecutionTestMover(
      nonceBytes: { _ in [UInt8](repeating: 0x77, count: 16) },
      renameExclusive: { from, fromName, to, toName, flags in
        let call = state.nextCallCount()
        if flags != DescriptorExclusiveQuarantineMover.renameFlags {
          state.record(MoverTestError.invalidRenameFlags)
        }
        if call == 1 {
          return testRenameExclusive(from, fromName, to, toName, flags)
        }
        return .failed(EIO)
      },
      hooks: hooks
    )

    let report = try move(claim, fixture: fixture, mover: mover)
    try #require(state.errorDescription == nil)
    let recovery = try manualRecovery(from: report)
    let location = try #require(recovery.location)

    #expect(recovery.reason == .rollbackOutcomeIndeterminate)
    #expect(state.callCount == 2)
    #expect(!FileManager.default.fileExists(atPath: fixture.candidate.path))
    #expect(try fileIdentity(at: try locationURL(location, root: fixture.root)) == approvedIdentity)
    #expect(!report.performedPermanentDeletion)
  }

  @Test("Rollback never overwrites a source recreated at its final hook")
  func rollbackPreservesRecreatedSource() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let approvedIdentity = claim.approval.reviewedManifest.entries[0].expectedIdentity
    let originalMode = try NodeSnapshot.read(from: fixture.candidate).mode & mode_t(0o7777)
    let mismatchMode = originalMode == mode_t(0o700) ? 0o755 : 0o700
    let destination = deterministicDestination(0x88, root: fixture.root)
    let state = MoverTestState()
    let hooks = DescriptorExclusiveQuarantineMoverHooks(
      afterRenameReturn: { _, result in
        guard result == .succeeded else { return }
        do {
          try FileManager.default.setAttributes(
            [.posixPermissions: mismatchMode],
            ofItemAtPath: destination.path
          )
        } catch {
          state.record(error)
        }
      },
      beforeRollback: {
        do {
          try FileManager.default.createDirectory(
            at: fixture.candidate,
            withIntermediateDirectories: false
          )
          try Data([0x99]).write(
            to: fixture.candidate.appendingPathComponent("recreated-source")
          )
        } catch {
          state.record(error)
        }
      }
    )
    let mover = supportedExecutionTestMover(
      nonceBytes: { _ in [UInt8](repeating: 0x88, count: 16) },
      renameExclusive: { from, fromName, to, toName, flags in
        _ = state.nextCallCount()
        if flags != DescriptorExclusiveQuarantineMover.renameFlags {
          state.record(MoverTestError.invalidRenameFlags)
        }
        return testRenameExclusive(from, fromName, to, toName, flags)
      },
      hooks: hooks
    )

    let report = try move(claim, fixture: fixture, mover: mover)
    try #require(state.errorDescription == nil)
    let recovery = try manualRecovery(from: report)
    let location = try #require(recovery.location)

    #expect(recovery.reason == .sourceNameOccupied)
    #expect(state.callCount == 2)
    #expect(
      try Data(contentsOf: fixture.candidate.appendingPathComponent("recreated-source"))
        == Data([0x99])
    )
    #expect(try fileIdentity(at: try locationURL(location, root: fixture.root)) == approvedIdentity)
    #expect(!report.performedPermanentDeletion)
  }

  @Test("A destination swap at rollback cannot be mistaken for the approved inode")
  func rollbackDestinationSwap() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let approvedIdentity = claim.approval.reviewedManifest.entries[0].expectedIdentity
    let originalMode = try NodeSnapshot.read(from: fixture.candidate).mode & mode_t(0o7777)
    let mismatchMode = originalMode == mode_t(0o700) ? 0o755 : 0o700
    let destination = deterministicDestination(0xAA, root: fixture.root)
    let savedApproved = fixture.root.appendingPathComponent(
      ".devsift-quarantine-v1/approved-still-held"
    )
    let state = MoverTestState()
    let hooks = DescriptorExclusiveQuarantineMoverHooks(
      afterRenameReturn: { _, result in
        guard result == .succeeded else { return }
        do {
          try FileManager.default.setAttributes(
            [.posixPermissions: mismatchMode],
            ofItemAtPath: destination.path
          )
        } catch {
          state.record(error)
        }
      },
      beforeRollback: {
        do {
          try FileManager.default.moveItem(at: destination, to: savedApproved)
          try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: false
          )
          try Data([0xAB]).write(to: destination.appendingPathComponent("replacement"))
        } catch {
          state.record(error)
        }
      }
    )
    let mover = supportedExecutionTestMover(
      nonceBytes: { _ in [UInt8](repeating: 0xAA, count: 16) },
      renameExclusive: { from, fromName, to, toName, flags in
        _ = state.nextCallCount()
        if flags != DescriptorExclusiveQuarantineMover.renameFlags {
          state.record(MoverTestError.invalidRenameFlags)
        }
        return testRenameExclusive(from, fromName, to, toName, flags)
      },
      hooks: hooks
    )

    let report = try move(claim, fixture: fixture, mover: mover)
    try #require(state.errorDescription == nil)
    let recovery = try manualRecovery(from: report)

    #expect(recovery.reason == .sourceNameOccupied)
    #expect(recovery.location == nil)
    #expect(state.callCount == 2)
    #expect(try fileIdentity(at: savedApproved) == approvedIdentity)
    #expect(
      try Data(contentsOf: fixture.candidate.appendingPathComponent("replacement"))
        == Data([0xAB])
    )
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(!report.performedPermanentDeletion)
  }

  @Test("A quarantine-root reparent before rollback cannot be reported as restored")
  func rollbackQuarantineRootReparent() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let approvedIdentity = claim.approval.reviewedManifest.entries[0].expectedIdentity
    let originalMode = try NodeSnapshot.read(from: fixture.candidate).mode & mode_t(0o7777)
    let mismatchMode = originalMode == mode_t(0o700) ? 0o755 : 0o700
    let quarantineRoot = fixture.root.appendingPathComponent(".devsift-quarantine-v1")
    let destination = deterministicDestination(0xAB, root: fixture.root)
    let detachedRoot = fixture.scannerFixture.outside.appendingPathComponent(
      "rollback-detached-quarantine"
    )
    let state = MoverTestState()
    let hooks = DescriptorExclusiveQuarantineMoverHooks(
      afterRenameReturn: { _, result in
        guard result == .succeeded else { return }
        do {
          try FileManager.default.setAttributes(
            [.posixPermissions: mismatchMode],
            ofItemAtPath: destination.path
          )
        } catch {
          state.record(error)
        }
      },
      beforeRollback: {
        do {
          try FileManager.default.moveItem(at: quarantineRoot, to: detachedRoot)
        } catch {
          state.record(error)
        }
      }
    )

    let report = try move(
      claim,
      fixture: fixture,
      mover: supportedExecutionTestMover(
        nonceBytes: { _ in [UInt8](repeating: 0xAB, count: 16) },
        hooks: hooks
      )
    )
    try #require(state.errorDescription == nil)
    let recovery = try manualRecovery(from: report)
    let detachedDestination = detachedRoot.appendingPathComponent(destination.lastPathComponent)

    #expect(recovery.reason == .parentBindingChanged)
    #expect(recovery.location == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.candidate.path))
    #expect(try fileIdentity(at: detachedDestination) == approvedIdentity)
    #expect(!FileManager.default.fileExists(atPath: quarantineRoot.path))
    #expect(!report.performedPermanentDeletion)
  }
}

enum UnsafeQuarantineRootKind: Sendable {
  case symbolicLink
  case regularFile
  case permissiveDirectory
}

func supportedExecutionTestMover(
  supportsResolveBeneathRename: @escaping @Sendable () -> Bool = { true },
  makeQuarantineRoot:
    @escaping @Sendable (
      Int32,
      DescriptorPathComponent
    ) -> DescriptorQuarantineMkdirResult = testMakeQuarantineRoot,
  nonceBytes: @escaping @Sendable (Int) -> [UInt8]? = deterministicNonce,
  volumeCapabilities:
    @escaping @Sendable () -> DescriptorQuarantineDependencyResult<
      DescriptorQuarantineVolumeCapabilities
    > = {
      .success(
        DescriptorQuarantineVolumeCapabilities(
          supportsExclusiveRename: true,
          supportsPOSIXPermissions: true
        )
      )
    },
  hasExtendedACL: @escaping @Sendable () -> DescriptorQuarantineDependencyResult<Bool> = {
    .success(false)
  },
  renameExclusive: (
    @Sendable (
      Int32,
      DescriptorQuarantineRelativePath,
      Int32,
      DescriptorQuarantineRelativePath,
      UInt32
    ) -> DescriptorExclusiveRenameResult
  )? = nil,
  cancellationIsRequested: @escaping @Sendable () -> Bool = { false },
  hooks: DescriptorExclusiveQuarantineMoverHooks = DescriptorExclusiveQuarantineMoverHooks()
) -> DescriptorExclusiveQuarantineMover {
  if let renameExclusive {
    return DescriptorExclusiveQuarantineMover(
      dependencies: DescriptorExclusiveQuarantineMoverDependencies(
        supportsResolveBeneathRename: supportsResolveBeneathRename,
        makeQuarantineRoot: makeQuarantineRoot,
        nonceBytes: nonceBytes,
        volumeCapabilities: { _ in volumeCapabilities() },
        hasExtendedACL: { _ in hasExtendedACL() },
        renameExclusive: renameExclusive,
        cancellationIsRequested: cancellationIsRequested,
        hooks: hooks
      )
    )
  }
  return DescriptorExclusiveQuarantineMover(
    dependencies: DescriptorExclusiveQuarantineMoverDependencies(
      supportsResolveBeneathRename: supportsResolveBeneathRename,
      makeQuarantineRoot: makeQuarantineRoot,
      nonceBytes: nonceBytes,
      volumeCapabilities: { _ in volumeCapabilities() },
      hasExtendedACL: { _ in hasExtendedACL() },
      cancellationIsRequested: cancellationIsRequested,
      hooks: hooks
    )
  )
}

private func testMakeQuarantineRoot(
  _ parentDescriptor: Int32,
  _ component: DescriptorPathComponent
) -> DescriptorQuarantineMkdirResult {
  var failureCode: Int32 = EINVAL
  let result = component.withCString { pointer in
    let status = Darwin.mkdirat(parentDescriptor, pointer, mode_t(0o700))
    if status != 0 { failureCode = errno }
    return status
  }
  if result == 0 { return .created }
  if failureCode == EEXIST { return .alreadyExists }
  return .failed(failureCode)
}

private func move(
  _ claim: CleanupQuarantineExecutionClaim,
  fixture: NPMQuarantinePreflightFixture,
  mover: DescriptorExclusiveQuarantineMover
) throws -> CleanupQuarantineExecutionReport {
  switch fixture.preflight().moveValidatedCandidate(claim: claim, using: mover) {
  case .success(let report):
    return report
  case .failure(let failure):
    throw MoverTestError.preflight(failure)
  }
}

private func quarantinedLocation(
  from report: CleanupQuarantineExecutionReport,
  sourceNameWasRecreated: Bool
) throws -> CleanupQuarantineLocation {
  guard
    case .quarantinedAwaitingReceipt(let location, let recreated) = report.status,
    recreated == sourceNameWasRecreated
  else {
    throw MoverTestError.unexpectedStatus
  }
  return location
}

private func manualRecovery(
  from report: CleanupQuarantineExecutionReport
) throws -> (location: CleanupQuarantineLocation?, reason: CleanupQuarantineManualRecoveryReason) {
  guard case .manualRecoveryRequired(let location, let reason) = report.status else {
    throw MoverTestError.unexpectedStatus
  }
  return (location, reason)
}

private func locationURL(_ location: CleanupQuarantineLocation, root: URL) throws -> URL {
  try location.relativePath.rawComponents.reduce(root) { result, bytes in
    guard let component = String(bytes: bytes, encoding: .utf8) else {
      throw MoverTestError.invalidLocation
    }
    return result.appendingPathComponent(component)
  }
}

private func deterministicNonce(_ attempt: Int) -> [UInt8]? {
  guard (0...255).contains(attempt) else { return nil }
  return [UInt8](repeating: UInt8(attempt), count: 16)
}

private func destinationName(nonce: [UInt8]) -> String {
  let hex = nonce.map { String(format: "%02x", $0) }.joined()
  return "item-v1-\(hex)"
}

private func deterministicDestination(_ byte: UInt8, root: URL) -> URL {
  root.appendingPathComponent(".devsift-quarantine-v1")
    .appendingPathComponent(destinationName(nonce: [UInt8](repeating: byte, count: 16)))
}

private func testRenameExclusive(
  _ fromDescriptor: Int32,
  _ fromComponent: DescriptorQuarantineRelativePath,
  _ toDescriptor: Int32,
  _ toComponent: DescriptorQuarantineRelativePath,
  _ flags: UInt32
) -> DescriptorExclusiveRenameResult {
  var failureCode: Int32 = EINVAL
  let result = fromComponent.withCString { fromPointer in
    toComponent.withCString { toPointer in
      let status = Darwin.renameatx_np(
        fromDescriptor,
        fromPointer,
        toDescriptor,
        toPointer,
        flags
      )
      if status != 0 { failureCode = errno }
      return status
    }
  }
  return result == 0 ? .succeeded : .failed(failureCode)
}

private func fileIdentity(at url: URL) throws -> FileIdentity {
  var information = stat()
  let status = url.withUnsafeFileSystemRepresentation { path in
    path.map { Darwin.lstat($0, &information) } ?? -1
  }
  guard status == 0 else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
  return FileIdentity(
    device: UInt64(bitPattern: Int64(information.st_dev)),
    inode: UInt64(information.st_ino)
  )
}

private enum MoverTestError: Error {
  case preflight(DescriptorNPMQuarantinePreflightFailure)
  case unexpectedStatus
  case invalidLocation
  case invalidRenameFlags
}

private final class MoverTestState: @unchecked Sendable {
  private let lock = NSLock()
  private var storedFlag = false
  private var storedCallCount = 0
  private var storedErrorDescription: String?

  var flag: Bool { lock.withLock { storedFlag } }
  var callCount: Int { lock.withLock { storedCallCount } }
  var errorDescription: String? { lock.withLock { storedErrorDescription } }

  func setFlag(_ value: Bool) {
    lock.withLock { storedFlag = value }
  }

  func incrementCallCount() {
    lock.withLock { storedCallCount += 1 }
  }

  func nextCallCount() -> Int {
    lock.withLock {
      storedCallCount += 1
      return storedCallCount
    }
  }

  func record(_ error: Error) {
    lock.withLock { storedErrorDescription = String(describing: error) }
  }
}
