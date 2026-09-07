import Foundation
import Testing

@testable import DevSiftCore

@Suite("Product status")
struct DevSiftStatusTests {
  @Test("Product version matches repository metadata")
  func productVersionMatchesRepositoryMetadata() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let versionFile = repositoryRoot.appendingPathComponent("VERSION")
    let storedVersion = try String(contentsOf: versionFile, encoding: .utf8)

    #expect(DevSiftStatus.current.version == "0.3.0-alpha.2")
    #expect(storedVersion == DevSiftStatus.current.version + "\n")
  }

  @Test("The foundation build is scan-only")
  func foundationIsScanOnly() {
    let status = DevSiftStatus.current

    #expect(status.safetyMode == .scanOnly)
    #expect(status.safetyMode.allowsFilesystemMutation == false)
  }

  @Test("The status summary is deterministic")
  func summaryIsDeterministic() {
    let status = DevSiftStatus(version: "1.2.3", safetyMode: .scanOnly)

    #expect(status.summary == "DevSift 1.2.3 (scan-only)")
  }
}
