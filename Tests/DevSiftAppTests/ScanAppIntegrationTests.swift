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

  @Test("The dashboard exposes scanned age evidence without weakening protection")
  func recognizedAgeEvidenceRemainsProtected() async throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent("DevSiftAppAgeTests-\(UUID().uuidString)", isDirectory: true)
    let root = container.appendingPathComponent("root", isDirectory: true)
    let uv = root.appendingPathComponent("uv", isDirectory: true)
    let outside = container.appendingPathComponent("outside.txt")
    try FileManager.default.createDirectory(at: uv, withIntermediateDirectories: true)
    try Data("outside-sentinel".utf8).write(to: outside)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 100)],
      ofItemAtPath: uv.path
    )
    defer { try? FileManager.default.removeItem(at: container) }

    let uvAttributesBeforeScan = try FileManager.default.attributesOfItem(atPath: uv.path)
    let uvModificationDateBeforeScan = try #require(
      uvAttributesBeforeScan[.modificationDate] as? Date
    )
    let beforeOutside = try Data(contentsOf: outside)
    let model = ScanViewModel(
      scanner: AllocatedSizeScanner(),
      securityScope: SecurityScopeSpy(startResult: false),
      referenceUnixSeconds: { 100 + 7 * 24 * 60 * 60 }
    )

    await model.startScan(at: root).value

    guard case .result(_, let presentation) = model.phase else {
      Issue.record("Expected the real scanner and classifier to return a result")
      return
    }
    let uvRow = try #require(
      presentation.items.first {
        $0.id.rawComponents == [Array("uv".utf8)]
      }
    )
    let age = try #require(
      uvRow.policy.findings.first {
        $0.identifier.rawValue == "age-requirement"
      }
    )

    #expect(age.kind == .age)
    #expect(age.state == .satisfied)
    #expect(uvRow.policy.matchState == .possibleMatch)
    #expect(uvRow.policy.disposition == .protected)
    #expect(uvRow.policy.isMalformed == false)
    #expect(
      uvRow.policy.findings.contains {
        $0.identifier.rawValue == "activity-requirement"
          && $0.state == .unknown(.notCollected)
      }
    )
    #expect(try Data(contentsOf: outside) == beforeOutside)
    let uvAttributesAfterScan = try FileManager.default.attributesOfItem(atPath: uv.path)
    #expect(uvAttributesAfterScan[.modificationDate] as? Date == uvModificationDateBeforeScan)
  }
}
