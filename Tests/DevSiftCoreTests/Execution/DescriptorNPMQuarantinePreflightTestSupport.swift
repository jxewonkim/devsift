import Darwin
import Foundation

@testable import DevSiftCore

struct NPMQuarantinePreflightFixture {
  let scannerFixture: ScannerFixture
  let home: URL
  let root: URL
  let candidate: URL
  let referenceUnixSeconds: Int64

  init(referenceUnixSeconds: Int64 = 2_000_000) throws {
    scannerFixture = try ScannerFixture()
    home = try resolvedNPMPreflightFixtureURL(
      scannerFixture.makeDirectory("home", under: scannerFixture.container)
    )
    root = try scannerFixture.makeDirectory(".npm", under: home)
    candidate = try scannerFixture.makeDirectory("_cacache", under: root)
    self.referenceUnixSeconds = referenceUnixSeconds

    _ = try scannerFixture.makeDirectory("content-v2/sha512/aa/bb", under: candidate)
    _ = try scannerFixture.write(
      "content-v2/sha512/aa/bb/0123456789abcdef",
      bytes: [1, 2, 3],
      under: candidate
    )
    _ = try scannerFixture.makeDirectory("index-v5/aa/bb", under: candidate)
    _ = try scannerFixture.write(
      "index-v5/aa/bb/0123456789abcdef0123456789abcdef0123456789abcdef0123456789ab",
      bytes: [4, 5],
      under: candidate
    )
    _ = try scannerFixture.makeDirectory("tmp", under: candidate)
    try setTreeModificationTime(100)
  }

  func remove() {
    scannerFixture.remove()
  }

  func setTreeModificationTime(_ unixSeconds: Int64) throws {
    guard
      let enumerator = FileManager.default.enumerator(
        at: candidate,
        includingPropertiesForKeys: nil
      )
    else {
      return
    }
    var descendants: [URL] = []
    while let url = enumerator.nextObject() as? URL {
      descendants.append(url)
    }
    for url in descendants.reversed() {
      try scannerFixture.setModificationTime(unixSeconds, for: url)
    }
    try scannerFixture.setModificationTime(unixSeconds, for: candidate)
  }

  func makeAuthorization() async throws -> CleanupQuarantineAuthorization {
    let approval = try await makeApproval()
    return try await makeAuthorization(for: approval)
  }

  func makeApproval() async throws -> CleanupApproval {
    let scan = try await AllocatedSizeScanner().scan(root: root)
    let request = RuleClassificationRequest(
      root: root,
      report: scan,
      referenceUnixSeconds: referenceUnixSeconds
    )
    let observations = scan.topLevelItems.map { summary in
      RuleObservation(
        summary: summary,
        selectedRootBasename: .known(Array(".npm".utf8)),
        integrity: completeRuleIntegrity(),
        facts: satisfiedRuleFacts(
          modificationUnixSeconds: summary.newestContentModificationUnixSeconds ?? -1,
          activity: .unknown(.notCollected),
        )
      )
    }
    let classifier = ExplainableRuleClassifier()
    let classification = try await classifier.classify(
      observations: observations,
      referenceUnixSeconds: referenceUnixSeconds
    ).binding(to: request)
    let npmRevision = try npmPreflightRevision("devsift.cache.npm", 5)
    let manifestRequest = CleanupManifestRequest(
      classificationRequest: request,
      classificationReport: classification,
      selections: [
        CleanupCandidateSelection(
          path: ScanRelativePath(rawComponents: [Array("_cacache".utf8)]),
          ruleRevision: npmRevision
        )
      ]
    )
    let approver = CleanupApprover()
    let review = try approver.beginReview(manifestRequest)
    return try approver.approve(
      CleanupApprovalRequest(
        session: review,
        confirmations: try approvalConfirmations(from: review),
        preconditionReviewAcknowledgements: try approvalPreconditionReviewAcknowledgements(
          from: review
        )
      )
    )
  }

  func makeAuthorization(
    for approval: CleanupApproval
  ) async throws -> CleanupQuarantineAuthorization {
    let session = try CleanupQuarantineAuthorizer().beginAttempt(for: approval)
    return try await session.authorize(
      using: CleanupQuarantineUserAttestation(
        request: session.attestationRequest,
        statement: session.attestationRequest.requiredStatement
      )
    )
  }

  func makeClaim() async throws -> CleanupQuarantineExecutionClaim {
    try await makeAuthorization().consumeForExecution()
  }

  func preflight(
    accountUIDProvider: @escaping DescriptorNPMQuarantinePreflight.AccountUIDProvider = {
      .known(Darwin.getuid())
    },
    clock: DescriptorNPMQuarantinePreflight.Clock? = nil,
    limits: DescriptorNPMQuarantineTraversalLimits = .defaults,
    checkpoint: @escaping DescriptorNPMQuarantinePreflight.Checkpoint = {},
    beforeOpeningCandidate: @escaping DescriptorNPMQuarantinePreflight.Hook = {},
    beforeFinalValidation: @escaping DescriptorNPMQuarantinePreflight.Hook = {}
  ) -> DescriptorNPMQuarantinePreflight {
    let defaultReferenceUnixSeconds = referenceUnixSeconds
    return DescriptorNPMQuarantinePreflight(
      checkpoint: checkpoint,
      rawHomeProvider: { .known(rawNPMPreflightPathBytes(home)) },
      accountUIDProvider: accountUIDProvider,
      clock: clock ?? { defaultReferenceUnixSeconds },
      limits: limits,
      beforeOpeningCandidate: beforeOpeningCandidate,
      beforeFinalValidation: beforeFinalValidation
    )
  }
}

func rawNPMPreflightPathBytes(_ url: URL) -> [UInt8] {
  url.withUnsafeFileSystemRepresentation { representation in
    guard let representation else { return [] }
    return Array(UnsafeBufferPointer(start: representation, count: strlen(representation))).map {
      UInt8(bitPattern: $0)
    }
  }
}

func installCurrentUserReadACL(at url: URL) throws {
  var acl: acl_t? = Darwin.acl_init(1)
  guard acl != nil else {
    throw aclFixtureError(errno)
  }
  defer {
    if let acl { _ = Darwin.acl_free(UnsafeMutableRawPointer(acl)) }
  }

  var entry: acl_entry_t?
  guard Darwin.acl_create_entry(&acl, &entry) == 0, let entry else {
    throw aclFixtureError(errno)
  }
  guard Darwin.acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0 else {
    throw aclFixtureError(errno)
  }

  var identifier = UUID().uuid
  guard testMbrUIDToUUID(Darwin.getuid(), &identifier) == 0 else {
    throw aclFixtureError(errno)
  }
  let qualifierResult = withUnsafePointer(to: &identifier) { pointer in
    Darwin.acl_set_qualifier(entry, pointer)
  }
  guard qualifierResult == 0 else {
    throw aclFixtureError(errno)
  }

  var permissions: acl_permset_t?
  guard
    Darwin.acl_get_permset(entry, &permissions) == 0,
    let permissions,
    Darwin.acl_add_perm(permissions, ACL_READ_DATA) == 0
  else {
    throw aclFixtureError(errno)
  }

  var failureCode = EINVAL
  let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
    guard let path, let acl else { return -1 }
    let status = Darwin.acl_set_file(path, ACL_TYPE_EXTENDED, acl)
    if status != 0 { failureCode = errno }
    return status
  }
  guard result == 0 else {
    throw aclFixtureError(failureCode)
  }
}

@_silgen_name("mbr_uid_to_uuid")
private func testMbrUIDToUUID(
  _ userID: uid_t,
  _ identifier: UnsafeMutablePointer<uuid_t>
) -> Int32

private func aclFixtureError(_ code: Int32) -> NSError {
  NSError(domain: "DevSiftExecutionACLFixture", code: Int(code))
}

private func npmPreflightRevision(
  _ identifier: String,
  _ version: UInt32
) throws -> RuleRevision {
  guard
    let identifier = RuleIdentifier(rawValue: identifier),
    let version = RuleVersion(rawValue: version)
  else {
    throw NSError(domain: "NPMQuarantinePreflightFixture", code: 1)
  }
  return RuleRevision(identifier: identifier, version: version)
}

private func resolvedNPMPreflightFixtureURL(_ url: URL) throws -> URL {
  var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
  var failureCode: Int32 = EINVAL
  let succeeded = url.withUnsafeFileSystemRepresentation { path in
    guard let path else { return false }
    guard Darwin.realpath(path, &buffer) != nil else {
      failureCode = errno
      return false
    }
    return true
  }
  guard succeeded else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(failureCode))
  }
  return buffer.withUnsafeBufferPointer { bytes in
    URL(
      fileURLWithFileSystemRepresentation: bytes.baseAddress!,
      isDirectory: true,
      relativeTo: nil
    )
  }
}
