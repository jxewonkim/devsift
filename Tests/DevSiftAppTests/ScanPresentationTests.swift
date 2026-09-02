import DevSiftCore
import Foundation
import Testing

@testable import DevSiftApp
@testable import DevSiftCore

@Suite("Scan dashboard presentation")
struct ScanPresentationTests {
  @Test("Rows sort by allocated bytes then exact raw path bytes")
  func deterministicRowSorting() async throws {
    let invalid = AppTestReportFactory.item(
      rawComponents: [[0xFF]],
      kind: .regularFile,
      allocatedBytes: 4_096
    )
    let letterB = AppTestReportFactory.item(
      rawComponents: [Array("b".utf8)],
      kind: .regularFile,
      allocatedBytes: 4_096
    )
    let largest = AppTestReportFactory.item(
      rawComponents: [Array("largest".utf8)],
      allocatedBytes: 8_192
    )
    let report = AppTestReportFactory.report(topLevelItems: [invalid, letterB, largest])

    let presentation = try await ScanPresentation.prepare(report: report)

    #expect(presentation.items.map(\.id) == [largest.path, letterB.path, invalid.path])
    #expect(presentation.items.last?.displayPath == "\\xFF")
  }

  @Test("Paths escape controls, default-ignorable Unicode, backslashes and invalid bytes")
  func safePaths() {
    let hostile = ScanRelativePath(
      rawComponents: [Array("line\nleft​\\xFF".utf8), [0x66, 0x6F, 0xFF]]
    )

    let display = SafeDisplayText.path(hostile)

    #expect(display == "line\\nleft\\u{200B}\\\\xFF/\\x66\\x6F\\xFF")
    #expect(display.contains("\n") == false)
    #expect(display.contains("​") == false)
    #expect(SafeDisplayText.fileName(of: URL(fileURLWithPath: "/")) == "/")
    #expect(SafeDisplayText.filePath(URL(fileURLWithPath: "/")) == "/")
  }

  @Test("Traversal discard and size overflow make affected metrics unavailable")
  func unavailableMetrics() async throws {
    let discarded = try await ScanPresentation.prepare(
      report: AppTestReportFactory.report(traversalDetailsWereDiscarded: true)
    )
    #expect(discarded.metricsAreAvailable == false)
    #expect(discarded.sizeMetricsAreAvailable == false)
    #expect(discarded.observationIsComplete == false)

    let overflow = ScanIssue(
      path: .root,
      operation: .measureSize,
      reason: .sizeOverflow,
      impact: .estimateDegraded
    )
    let overflowed = try await ScanPresentation.prepare(
      report: AppTestReportFactory.report(
        root: AppTestReportFactory.item(sizeOverflowed: true, isComplete: false),
        issues: [overflow]
      )
    )
    #expect(overflowed.metricsAreAvailable)
    #expect(overflowed.sizeMetricsAreAvailable == false)
    #expect(overflowed.report.root.sizeOverflowed)
    #expect(overflowed.observationIsComplete == false)
  }

  @Test("Unknown allocated sizes make the allocation observation partial")
  func unknownAllocationIsPartial() async throws {
    let item = AppTestReportFactory.item(
      rawComponents: [Array("unknown".utf8)],
      unknownAllocatedItemCount: 1
    )
    let report = AppTestReportFactory.report(
      root: AppTestReportFactory.item(unknownAllocatedItemCount: 1),
      topLevelItems: [item]
    )

    let presentation = try await ScanPresentation.prepare(report: report)

    #expect(report.isComplete)
    #expect(presentation.observationIsComplete == false)
    #expect(presentation.items.first?.observationIsComplete == false)
    #expect(presentation.partialDetailMessages == ["1 entry has unknown allocation."])

    let suppressed = try await ScanPresentation.prepare(
      report: AppTestReportFactory.report(suppressedIssueCount: 1)
    )
    #expect(suppressed.partialDetailMessages == ["1 additional scan issue was not retained."])
  }

  @Test("Byte formatting preserves stable IEC boundaries")
  func byteFormatting() {
    #expect(StorageByteFormatter.string(from: 0) == "0 B")
    #expect(StorageByteFormatter.string(from: 1_023) == "1023 B")
    #expect(StorageByteFormatter.string(from: 1_024) == "1.0 KiB")
    #expect(StorageByteFormatter.string(from: 1 << 20) == "1.0 MiB")
    #expect(StorageByteFormatter.string(from: UInt64.max) == "16.0 EiB")
  }

  @Test("Phase changes provide bounded VoiceOver announcements")
  func accessibilityAnnouncements() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/synthetic-cache", isDirectory: true)
    let complete = try await ScanPresentation.prepare(report: AppTestReportFactory.report())
    let partial = try await ScanPresentation.prepare(
      report: AppTestReportFactory.report(suppressedIssueCount: 1)
    )

    #expect(DashboardAccessibility.announcement(for: .empty) == nil)
    #expect(
      DashboardAccessibility.announcement(for: .scanning(root))
        == "Scanning synthetic-cache. File contents are never opened."
    )
    #expect(
      DashboardAccessibility.announcement(for: .result(root, complete))
        == "Scan complete within configured limits. Results are ready."
    )
    #expect(
      DashboardAccessibility.announcement(for: .result(root, partial))?
        .hasPrefix("Partial scan") == true
    )
    #expect(
      DashboardAccessibility.announcement(for: .cancelled(root))
        == "Scan cancelled. No files were changed."
    )
  }
}
