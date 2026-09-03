import Testing

@testable import DevSiftCore

@Suite("Cleanup approval filesystem boundary")
struct CleanupApproverSafetyTests {
  @Test("Review, confirmation, and approval leave fixture boundaries unchanged")
  func noFilesystemMutation() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }
    try fixture.write("candidate/payload.bin", bytes: [1, 2, 3])
    try fixture.write("sentinel.bin", bytes: [4, 5, 6], under: fixture.outside)
    let beforeRoot = try treeSnapshot(at: fixture.root)
    let beforeOutside = try treeSnapshot(at: fixture.outside)
    let source = try await approvalTestSource(
      rawNames: [Array("candidate".utf8)],
      root: fixture.root
    )
    let approver = CleanupApprover()

    let session = try approver.beginReview(source.manifestRequest)
    let confirmations = try approvalConfirmations(from: session)
    let approval = try approver.approve(
      CleanupApprovalRequest(
        session: session,
        confirmations: confirmations
      )
    )

    #expect(approval.sourceRoot == fixture.root)
    #expect(try treeSnapshot(at: fixture.root) == beforeRoot)
    #expect(try treeSnapshot(at: fixture.outside) == beforeOutside)
  }
}
