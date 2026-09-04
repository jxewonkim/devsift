import Darwin
import Foundation
import Testing

@testable import DevSiftCore

@Suite("Descriptor npm quarantine preflight")
struct DescriptorNPMQuarantinePreflightTests {
  @Test("The pure claim gate rejects a same-shaped unsupported policy")
  func defensiveClaimValidation() async throws {
    let value = try await authorizationPendingApproval(
      rawNames: [Array("_cacache".utf8)]
    )
    let session = try syntheticAuthorizationSession(for: value.approval)
    let authorization = try await session.authorize(
      using: authorizationAttestation(for: session)
    )
    let claim = try await authorization.consumeForExecution()

    expectFailure(
      .invalidClaim,
      from: DescriptorNPMQuarantinePreflight.validateClaim(claim)
    )
  }

  @Test("A complete old cacache validates without exposing descriptors")
  func completeLayout() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let before = try treeSnapshot(at: fixture.scannerFixture.container)

    let result = fixture.preflight().validateCandidate(claim: claim)

    try result.get()
    #expect(try treeSnapshot(at: fixture.scannerFixture.container) == before)
  }

  @Test("Both exact generated marker directories remain mandatory")
  func missingMarker() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    try FileManager.default.removeItem(
      at: fixture.candidate.appendingPathComponent("index-v5")
    )

    expectFailure(
      .layoutMismatch,
      from: fixture.preflight().validateCandidate(claim: claim)
    )
  }

  @Test("An unrecognized raw entry fails the complete cacache grammar")
  func extraEntry() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    _ = try fixture.scannerFixture.write("unexpected", bytes: [9], under: fixture.candidate)

    expectFailure(
      .layoutMismatch,
      from: fixture.preflight().validateCandidate(claim: claim)
    )
  }

  @Test("An allowed name cannot substitute a symbolic link")
  func symbolicLink() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let content = fixture.candidate.appendingPathComponent("content-v2")
    try FileManager.default.removeItem(at: content)
    try FileManager.default.createSymbolicLink(
      at: content,
      withDestinationURL: fixture.scannerFixture.outside
    )

    expectFailure(
      .candidateUnsafe,
      from: fixture.preflight().validateCandidate(claim: claim)
    )
  }

  @Test("Every regular descendant must have exactly one hard link")
  func hardLink() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let tag = try fixture.scannerFixture.write(
      "CACHEDIR.TAG",
      bytes: [1],
      under: fixture.candidate
    )
    _ = try fixture.scannerFixture.makeHardLink(
      "_lastverified",
      source: tag,
      under: fixture.candidate
    )

    expectFailure(
      .candidateUnsafe,
      from: fixture.preflight().validateCandidate(claim: claim)
    )
  }

  @Test("A real extended ACL on the candidate fails closed")
  func candidateExtendedACL() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    try installCurrentUserReadACL(at: fixture.candidate)

    expectFailure(
      .candidateUnsafe,
      from: fixture.preflight().validateCandidate(claim: claim)
    )
  }

  @Test("A real extended ACL on a regular descendant fails closed")
  func descendantExtendedACL() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let leaf = fixture.candidate.appendingPathComponent(
      "content-v2/sha512/aa/bb/0123456789abcdef"
    )
    try installCurrentUserReadACL(at: leaf)

    expectFailure(
      .candidateUnsafe,
      from: fixture.preflight().validateCandidate(claim: claim)
    )
  }

  @Test("A real extended ACL on the npm root fails closed")
  func rootExtendedACL() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    try installCurrentUserReadACL(at: fixture.root)

    expectFailure(
      .rootChanged,
      from: fixture.preflight().validateCandidate(claim: claim)
    )
  }

  @Test(
    "Group or other write access fails closed at every protected level",
    arguments: UnsafeWriteFixtureLocation.allCases
  )
  func nonOwnerWriteAccess(location: UnsafeWriteFixtureLocation) async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let target: URL
    let expected: DescriptorNPMQuarantinePreflightFailure
    switch location {
    case .home:
      target = fixture.home
      expected = .rootChanged
    case .root:
      target = fixture.root
      expected = .rootChanged
    case .candidate:
      target = fixture.candidate
      expected = .candidateUnsafe
    case .descendant:
      target = fixture.candidate.appendingPathComponent(
        "content-v2/sha512/aa/bb/0123456789abcdef"
      )
      expected = .candidateUnsafe
    }
    let originalMode = try NodeSnapshot.read(from: target).mode & mode_t(0o7777)
    try FileManager.default.setAttributes(
      [.posixPermissions: Int(originalMode | mode_t(0o002))],
      ofItemAtPath: target.path
    )

    expectFailure(
      expected,
      from: fixture.preflight().validateCandidate(claim: claim)
    )
  }

  @Test("A nonzero filesystem flag on a descendant fails closed")
  func descendantFilesystemFlag() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let leaf = fixture.candidate.appendingPathComponent(
      "content-v2/sha512/aa/bb/0123456789abcdef"
    )
    try setFixtureFlags(UInt32(UF_HIDDEN), at: leaf)

    expectFailure(
      .candidateUnsafe,
      from: fixture.preflight().validateCandidate(claim: claim)
    )
  }

  @Test("Exactly seven-day-old content satisfies the inclusive age boundary")
  func exactAgeBoundary() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    try fixture.setTreeModificationTime(
      fixture.referenceUnixSeconds - 7 * 24 * 60 * 60
    )
    let claim = try await fixture.makeClaim()

    try fixture.preflight().validateCandidate(claim: claim).get()
  }

  @Test(
    "Future and younger-than-seven-day mtimes fail closed",
    arguments: [
      2_000_001,
      2_000_000 - 7 * 24 * 60 * 60 + 1,
    ])
  func insufficientAge(modificationUnixSeconds: Int64) async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let leaf = fixture.candidate.appendingPathComponent(
      "content-v2/sha512/aa/bb/0123456789abcdef"
    )
    try fixture.scannerFixture.setModificationTime(modificationUnixSeconds, for: leaf)

    expectFailure(
      .ageRequirementNotSatisfied,
      from: fixture.preflight().validateCandidate(claim: claim)
    )
  }

  @Test("Cancellation checkpoints stop before exposing descriptors")
  func cancellation() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()

    expectFailure(
      .cancelled,
      from: fixture.preflight(checkpoint: { throw CancellationError() })
        .validateCandidate(claim: claim)
    )
  }

  @Test(
    "Entry, depth, and raw-name byte bounds fail closed",
    arguments: [
      DescriptorNPMQuarantineTraversalLimits(
        maximumEntries: 2,
        maximumDepth: 32,
        maximumRawNameBytes: 64 * 1_024 * 1_024
      ),
      DescriptorNPMQuarantineTraversalLimits(
        maximumEntries: 1_000_000,
        maximumDepth: 2,
        maximumRawNameBytes: 64 * 1_024 * 1_024
      ),
      DescriptorNPMQuarantineTraversalLimits(
        maximumEntries: 1_000_000,
        maximumDepth: 32,
        maximumRawNameBytes: 5
      ),
    ])
  func traversalBounds(limits: DescriptorNPMQuarantineTraversalLimits) async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()

    expectFailure(
      .traversalLimitExceeded,
      from: fixture.preflight(limits: limits).validateCandidate(claim: claim)
    )
  }

  @Test("A candidate identity swap between name check and open is rejected")
  func identitySwap() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let claim = try await fixture.makeClaim()
    let replacement = fixture.root.appendingPathComponent("replacement")

    let preflight = fixture.preflight(beforeOpeningCandidate: {
      try FileManager.default.moveItem(at: fixture.candidate, to: replacement)
      try FileManager.default.createDirectory(
        at: fixture.candidate, withIntermediateDirectories: false)
    })
    expectFailure(
      .candidateChanged,
      from: preflight.validateCandidate(claim: claim)
    )
  }

  @Test("Root and effective-account ownership policy fail closed")
  func uidPolicy() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let firstClaim = try await fixture.makeClaim()
    expectFailure(
      .invalidCurrentAccount,
      from: fixture.preflight(accountUIDProvider: { .known(0) })
        .validateCandidate(claim: firstClaim)
    )

    let currentUID = Darwin.getuid()
    let wrongUID = currentUID == uid_t.max ? currentUID - 1 : currentUID + 1
    let secondClaim = try await fixture.makeClaim()
    expectFailure(
      .rootChanged,
      from: fixture.preflight(accountUIDProvider: { .known(wrongUID) })
        .validateCandidate(claim: secondClaim)
    )
  }
}

enum UnsafeWriteFixtureLocation: CaseIterable, Sendable {
  case home
  case root
  case candidate
  case descendant
}

private func setFixtureFlags(_ flags: UInt32, at url: URL) throws {
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

private func expectFailure<Success>(
  _ expected: DescriptorNPMQuarantinePreflightFailure,
  from result: Result<Success, DescriptorNPMQuarantinePreflightFailure>,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  switch result {
  case .success:
    Issue.record("Expected preflight failure \(expected)", sourceLocation: sourceLocation)
  case .failure(let actual):
    #expect(actual == expected, sourceLocation: sourceLocation)
  }
}
