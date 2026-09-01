import Testing

@testable import DevSiftCore

@Suite("Development status")
struct DevSiftStatusTests {
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
