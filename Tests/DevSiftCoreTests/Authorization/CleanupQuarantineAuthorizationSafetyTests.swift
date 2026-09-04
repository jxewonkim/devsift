import Testing

@testable import DevSiftCore

@Suite("Cleanup quarantine authorization filesystem boundary")
struct CleanupQuarantineAuthorizationSafetyTests {
  @Test("Attempt issuance and consumption leave synthetic fixture boundaries unchanged")
  func noFilesystemIOOrMutation() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }
    try fixture.write("candidate/payload.bin", bytes: [1, 2, 3])
    try fixture.write("outside-sentinel.bin", bytes: [4, 5, 6], under: fixture.outside)
    let beforeRoot = try treeSnapshot(at: fixture.root)
    let beforeOutside = try treeSnapshot(at: fixture.outside)
    let value = try await authorizationPendingApproval(root: fixture.root)

    let session = try syntheticAuthorizationSession(for: value.approval)
    let authorization = try await session.authorize(
      using: authorizationAttestation(for: session)
    )
    _ = try await authorization.consumeForExecution()

    #expect(try treeSnapshot(at: fixture.root) == beforeRoot)
    #expect(try treeSnapshot(at: fixture.outside) == beforeOutside)
  }
}
