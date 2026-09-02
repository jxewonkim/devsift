import DevSiftCore
import Foundation
import Testing

@testable import DevSiftApp

@MainActor
@Suite("Scan dashboard Core integration")
struct ScanAppIntegrationTests {
  @Test("The dashboard scans only an explicit synthetic fixture without mutation")
  func syntheticFixtureScan() async throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent("DevSiftAppTests-\(UUID().uuidString)", isDirectory: true)
    let root = container.appendingPathComponent("root", isDirectory: true)
    let outside = container.appendingPathComponent("outside.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("inside".utf8).write(to: root.appendingPathComponent("inside.txt"))
    try Data("outside-sentinel".utf8).write(to: outside)
    defer { try? FileManager.default.removeItem(at: container) }

    let beforeInside = try Data(contentsOf: root.appendingPathComponent("inside.txt"))
    let beforeOutside = try Data(contentsOf: outside)
    let model = ScanViewModel(
      scanner: AllocatedSizeScanner(),
      securityScope: SecurityScopeSpy(startResult: false)
    )

    await model.startScan(at: root).value

    guard case .result(let resultRoot, let presentation) = model.phase else {
      Issue.record("Expected the real scanner to return a result")
      return
    }
    #expect(resultRoot == root)
    #expect(presentation.report.root.counts.regularFiles == 1)
    #expect(presentation.items.first?.id.rawComponents == [Array("inside.txt".utf8)])
    #expect(presentation.items.first?.policy.matchState == .unrecognized)
    #expect(presentation.items.first?.policy.disposition == .protected)
    #expect(try Data(contentsOf: root.appendingPathComponent("inside.txt")) == beforeInside)
    #expect(try Data(contentsOf: outside) == beforeOutside)
  }
}
