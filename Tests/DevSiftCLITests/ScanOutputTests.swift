import DevSiftCore
import Foundation
import Testing

@testable import DevSiftCLI
@testable import DevSiftCore

@Suite("CLI scan output")
struct ScanOutputTests {
  @Test("Human output is deterministic, size-sorted and root-relative")
  func humanOutputGolden() {
    let large = CLITestReportFactory.item(
      rawComponents: [Array("large".utf8)],
      kind: .directory,
      logicalBytes: 2_048,
      allocatedBytes: 4_096,
      hardLinkExclusiveAllocatedBytes: 3_072
    )
    let special = CLITestReportFactory.item(
      rawComponents: [Array("small\n\"\\path".utf8)],
      kind: .regularFile,
      logicalBytes: 512,
      allocatedBytes: 1_024,
      hardLinkExclusiveAllocatedBytes: 512,
      counts: CLITestReportFactory.counts(regularFiles: 1, directories: 0)
    )
    let root = CLITestReportFactory.item(
      logicalBytes: 3_000,
      allocatedBytes: 6_144,
      hardLinkExclusiveAllocatedBytes: 5_120,
      counts: CLITestReportFactory.counts(
        regularFiles: 2,
        directories: 1,
        symbolicLinks: 1,
        duplicateHardLinks: 1
      ),
      unknownAllocatedItemCount: 1,
      possibleSharedContentFileCount: 2,
      sharedContentMetadataUnavailableCount: 3,
      unobservedHardLinkFileCount: 4,
      nonExclusiveHardLinkFileCount: 5
    )
    let report = CLITestReportFactory.report(
      root: root,
      topLevelItems: [special, large]
    )

    let output = ScanTextRenderer.render(report: report)
    let expected = #"""
      DevSift scan (read-only)
      Path scope: selected root (reported as ".")
      Scan completeness: complete

      Observed root summary:
        Observed apparent allocated: 6.0 KiB (6144 B)
        Observed hard-link-exclusive allocated: 5.0 KiB (5120 B)
        Observed logical: 2.9 KiB (3000 B)
        Observed entries: 4
        Regular files: 2
        Directories: 1
        Symbolic links: 1
        Other entries: 0
        Duplicate hard links: 1

      Accounting uncertainty:
        Unknown allocated sizes: 1
        Possible shared-content files: 2
        Shared-content metadata unavailable: 3
        Hard-link groups with unobserved links: 4
        Non-exclusive hard-link paths: 5
        Note: observed allocation is not guaranteed reclaimable space; hard-link-exclusive accounting adjusts regular-file hard links only.

      Top-level items (2, largest apparent allocation first):
      - 4.0 KiB (4096 B) apparent | 3.0 KiB (3072 B) hard-link-exclusive | directory | complete | "large"
      - 1.0 KiB (1024 B) apparent | 512 B hard-link-exclusive | regular-file | complete | "small\n\"\\path"

      Issues: 0 recorded, 0 suppressed
      """# + "\n"

    #expect(output == expected)
  }

  @Test("Partial warnings and issue paths cannot control the terminal")
  func partialOutputIsTerminalSafe() {
    let issue = ScanIssue(
      path: ScanRelativePath(rawComponents: [Array("bad\u{001B}[31m\nname".utf8)]),
      operation: .readMetadata,
      reason: .permissionDenied,
      impact: .entrySkipped,
      systemCode: 13
    )
    let report = CLITestReportFactory.report(
      root: CLITestReportFactory.item(isComplete: false),
      topLevelItemCount: 12,
      topLevelItemsWereSuppressed: true,
      hardLinkAccountingIsComplete: false,
      traversalDetailsWereDiscarded: true,
      issues: [issue],
      suppressedIssueCount: 3
    )

    let output = ScanTextRenderer.render(report: report)

    #expect(output.contains("Scan completeness: partial"))
    #expect(output.contains("Top-level items: unavailable (traversal details discarded)"))
    #expect(output.contains("Root summary: unavailable (descendant details discarded)"))
    #expect(output.contains("The root summary is incomplete."))
    #expect(output.contains("The global entry limit was reached"))
    #expect(output.contains("exceeded their output bound") == false)
    #expect(output.contains("Hard-link-exclusive accounting is incomplete") == false)
    #expect(output.contains("3 additional issues were suppressed."))
    #expect(output.contains(#""bad\u{001B}[31m\nname""#))
    #expect(output.unicodeScalars.contains("\u{001B}") == false)
  }

  @Test("Human path escaping distinguishes literal escapes from raw invalid bytes")
  func byteAwareHumanPaths() {
    let literal = ScanRelativePath(rawComponents: [Array("\\xFF".utf8)])
    let invalid = ScanRelativePath(rawComponents: [[0xFF]])

    #expect(TerminalText.quoted(path: literal) == #""\\xFF""#)
    #expect(TerminalText.quoted(path: invalid) == #""\xFF""#)
    #expect(TerminalText.quoted(path: literal) != TerminalText.quoted(path: invalid))
  }

  @Test("Invisible Unicode format characters are escaped")
  func invisibleUnicodeIsEscaped() {
    let value = "left\u{200B}right\u{FEFF}\u{2028}\u{2029}"
    let output = TerminalText.escaped(value)

    #expect(output == "left\\u{200B}right\\u{FEFF}\\u{2028}\\u{2029}")
    #expect(output.contains("\u{200B}") == false)
    #expect(output.contains("\u{FEFF}") == false)
    #expect(output.contains("\u{2028}") == false)
    #expect(output.contains("\u{2029}") == false)
  }

  @Test("IEC formatting has stable boundaries and preserves exact bytes")
  func byteFormatting() {
    #expect(IECByteCountFormatter.string(from: 0) == "0 B")
    #expect(IECByteCountFormatter.string(from: 1_023) == "1023 B")
    #expect(IECByteCountFormatter.string(from: 1_024) == "1.0 KiB (1024 B)")
    #expect(IECByteCountFormatter.string(from: 1 << 20) == "1.0 MiB (1048576 B)")
    #expect(
      IECByteCountFormatter.string(from: UInt64.max)
        == "16.0 EiB (18446744073709551615 B)"
    )
  }

  @Test("Text withholds every size in an overflowed summary")
  func overflowText() {
    let overflowedItem = CLITestReportFactory.item(
      rawComponents: [Array("overflowed".utf8)],
      logicalBytes: .max,
      allocatedBytes: .max,
      hardLinkExclusiveAllocatedBytes: .max,
      sizeOverflowed: true,
      isComplete: false
    )
    let report = CLITestReportFactory.report(
      root: CLITestReportFactory.item(
        logicalBytes: .max,
        allocatedBytes: .max,
        hardLinkExclusiveAllocatedBytes: .max,
        sizeOverflowed: true,
        isComplete: false
      ),
      topLevelItems: [overflowedItem],
      suppressedIssueCount: 2
    )

    let output = ScanTextRenderer.render(report: report)

    #expect(output.contains("Observed apparent allocated: unavailable (size overflow)"))
    #expect(output.contains("Observed logical: unavailable (size overflow)"))
    #expect(output.contains("unavailable (size overflow) apparent"))
    #expect(output.contains("exact saturated values are unavailable"))
    #expect(output.contains("16.0 EiB") == false)
  }

  @Test("JSON v2 round-trips every integer and summary accounting flag")
  func jsonRoundTripAndDeterminism() throws {
    let rawPath: [UInt8] = [0xFF, 0x00, 0x5C]
    let root = CLITestReportFactory.item(
      logicalBytes: UInt64.max,
      allocatedBytes: UInt64.max,
      hardLinkExclusiveAllocatedBytes: UInt64.max,
      counts: CLITestReportFactory.counts(
        regularFiles: UInt64.max,
        directories: 0,
        duplicateHardLinks: UInt64.max
      ),
      unknownAllocatedItemCount: UInt64.max,
      possibleSharedContentFileCount: UInt64.max,
      sharedContentMetadataUnavailableCount: UInt64.max,
      unobservedHardLinkFileCount: UInt64.max,
      nonExclusiveHardLinkFileCount: UInt64.max,
      sizeOverflowed: true,
      isComplete: false
    )
    let item = CLITestReportFactory.item(
      rawComponents: [rawPath],
      kind: .regularFile,
      counts: CLITestReportFactory.counts(regularFiles: 1, directories: 0)
    )
    let issues = [
      ScanIssue(
        path: item.path,
        operation: .measureSize,
        reason: .invalidMetadata,
        impact: .estimateDegraded
      ),
      ScanIssue(
        path: ScanRelativePath(rawComponents: [Array("line\nname".utf8)]),
        operation: .readMetadata,
        reason: .ioFailure,
        impact: .entrySkipped,
        systemCode: 5
      ),
    ]
    let report = CLITestReportFactory.report(
      root: root,
      topLevelItems: [item],
      topLevelItemsWereSuppressed: false,
      hardLinkAccountingIsComplete: false,
      traversalDetailsWereDiscarded: true,
      issues: issues,
      suppressedIssueCount: UInt64.max
    )
    let limits = ScanLimits(
      maximumDepth: .max,
      maximumRecordedIssues: .max,
      maximumEntries: .max,
      maximumTopLevelItems: .max,
      maximumTrackedHardLinkEntries: .max,
      maximumTrackedHardLinkPathBytes: .max
    )

    let first = try ScanJSONRenderer.render(report: report, limits: limits)
    let second = try ScanJSONRenderer.render(report: report, limits: limits)
    let data = try #require(first.data(using: .utf8))
    let decoded = try JSONDecoder().decode(ScanJSONDocumentV2.self, from: data)

    #expect(first == second)
    #expect(first.hasSuffix("\n"))
    #expect(first.hasSuffix("\n\n") == false)
    #expect(decoded == ScanJSONDocumentV2(report: report, limits: limits))
    #expect(decoded.schema == "devsift.scan")
    #expect(decoded.schemaVersion == 2)
    #expect(decoded.pathStyle == "root-relative")
    #expect(decoded.report.root.recursiveSize.logicalBytes == String(UInt64.max))
    #expect(decoded.report.root.sizeOverflowed)
    #expect(decoded.report.root.counts.regularFiles == String(UInt64.max))
    #expect(decoded.report.topLevelItems.first?.path.rawComponentsBase64 == ["/wBc"])
    #expect(decoded.report.issues.first?.systemCode == nil)
    #expect(decoded.report.issues.last?.systemCode == 5)
    #expect(first.contains("\"systemCode\" : null"))
    try assertJSONV2KeySets(data)
  }

  private func assertJSONV2KeySets(_ data: Data) throws {
    let object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(
      Set(object.keys) == [
        "schema", "schemaVersion", "devsiftVersion", "safetyMode", "pathStyle", "limits",
        "report",
      ]
    )

    let limits = try #require(object["limits"] as? [String: Any])
    #expect(
      Set(limits.keys) == [
        "maximumDepth", "maximumRecordedIssues", "maximumEntries", "maximumTopLevelItems",
        "maximumTrackedHardLinkEntries", "maximumTrackedHardLinkPathBytes",
      ]
    )

    let report = try #require(object["report"] as? [String: Any])
    #expect(
      Set(report.keys) == [
        "isComplete", "root", "topLevelItems", "topLevelItemCount",
        "topLevelItemsWereSuppressed", "hardLinkAccountingIsComplete",
        "traversalDetailsWereDiscarded", "issues", "suppressedIssueCount",
      ]
    )

    let root = try #require(report["root"] as? [String: Any])
    let items = try #require(report["topLevelItems"] as? [[String: Any]])
    let item = try #require(items.first)
    let itemKeys: Set<String> = [
      "path", "kind", "recursiveSize", "hardLinkExclusiveAllocatedBytes", "counts",
      "unknownAllocatedItemCount", "possibleSharedContentFileCount",
      "sharedContentMetadataUnavailableCount", "unobservedHardLinkFileCount",
      "nonExclusiveHardLinkFileCount", "sizeOverflowed", "isComplete",
    ]
    #expect(Set(root.keys) == itemKeys)
    #expect(Set(item.keys) == itemKeys)

    let path = try #require(item["path"] as? [String: Any])
    #expect(Set(path.keys) == ["display", "rawComponentsBase64"])
    let size = try #require(item["recursiveSize"] as? [String: Any])
    #expect(Set(size.keys) == ["logicalBytes", "allocatedBytes"])
    let counts = try #require(item["counts"] as? [String: Any])
    #expect(
      Set(counts.keys) == [
        "regularFiles", "directories", "symbolicLinks", "other", "duplicateHardLinks", "total",
      ]
    )

    let issues = try #require(report["issues"] as? [[String: Any]])
    for issue in issues {
      #expect(Set(issue.keys) == ["path", "operation", "reason", "impact", "systemCode"])
    }
  }
}
