import DevSiftCore
import Foundation

enum TerminalText {
  static func quoted(_ value: String) -> String {
    "\"\(escaped(value))\""
  }

  static func escaped(_ value: String) -> String {
    var result = ""

    for scalar in value.unicodeScalars {
      switch scalar.value {
      case 0x09:
        result += "\\t"
      case 0x0A:
        result += "\\n"
      case 0x0D:
        result += "\\r"
      case 0x22:
        result += "\\\""
      case 0x5C:
        result += "\\\\"
      case 0x00...0x1F, 0x7F...0x9F:
        result += String(format: "\\u{%04X}", scalar.value)
      default:
        let category = scalar.properties.generalCategory
        if category == .format
          || category == .lineSeparator
          || category == .paragraphSeparator
          || scalar.properties.isDefaultIgnorableCodePoint
        {
          result += String(format: "\\u{%04X}", scalar.value)
        } else {
          result.unicodeScalars.append(scalar)
        }
      }
    }

    return result
  }

  static func quoted(path: ScanRelativePath) -> String {
    guard !path.rawComponents.isEmpty else {
      return quoted(".")
    }

    let components = path.rawComponents.map { bytes -> String in
      if let component = String(bytes: bytes, encoding: .utf8) {
        return escaped(component)
      }
      return bytes.map { String(format: "\\x%02X", $0) }.joined()
    }
    return "\"\(components.joined(separator: "/"))\""
  }
}

enum IECByteCountFormatter {
  private static let units: [(threshold: UInt64, suffix: String)] = [
    (1 << 60, "EiB"),
    (1 << 50, "PiB"),
    (1 << 40, "TiB"),
    (1 << 30, "GiB"),
    (1 << 20, "MiB"),
    (1 << 10, "KiB"),
  ]

  static func string(from bytes: UInt64) -> String {
    guard let unit = units.first(where: { bytes >= $0.threshold }) else {
      return "\(bytes) B"
    }

    let value = Double(bytes) / Double(unit.threshold)
    let scaled = String(
      format: "%.1f",
      locale: Locale(identifier: "en_US_POSIX"),
      value
    )
    return "\(scaled) \(unit.suffix) (\(bytes) B)"
  }
}

enum ScanTextRenderer {
  static func render(report: ScanReport) -> String {
    var lines = [
      "DevSift scan (read-only)",
      "Path scope: selected root (reported as \(TerminalText.quoted(".")))",
      "Scan completeness: \(report.isComplete ? "complete" : "partial")",
      "",
    ]

    appendRootSummary(report, to: &lines)
    lines.append("")
    appendAccountingUncertainty(report, to: &lines)
    lines.append("")

    appendTopLevelItems(report, to: &lines)
    lines.append("")
    appendWarnings(report, to: &lines)
    appendIssues(report, to: &lines)

    return lines.joined(separator: "\n") + "\n"
  }

  private static func appendRootSummary(
    _ report: ScanReport,
    to lines: inout [String]
  ) {
    if report.traversalDetailsWereDiscarded {
      lines.append("Root summary: unavailable (descendant details discarded)")
      lines.append(
        "  Root inode apparent allocated: \(IECByteCountFormatter.string(from: report.root.recursiveSize.allocatedBytes))"
      )
      lines.append(
        "  Root inode logical: \(IECByteCountFormatter.string(from: report.root.recursiveSize.logicalBytes))"
      )
      return
    }

    let hardLinkStatus = report.hardLinkAccountingIsComplete ? "" : " (partial)"
    lines.append("Observed root summary:")
    lines.append(
      "  Observed apparent allocated: \(IECByteCountFormatter.string(from: report.root.recursiveSize.allocatedBytes))"
    )
    lines.append(
      "  Observed hard-link-exclusive allocated: \(IECByteCountFormatter.string(from: report.root.hardLinkExclusiveAllocatedBytes))\(hardLinkStatus)"
    )
    lines.append(
      "  Observed logical: \(IECByteCountFormatter.string(from: report.root.recursiveSize.logicalBytes))"
    )
    lines.append("  Observed entries: \(report.root.counts.total)")
    lines.append("  Regular files: \(report.root.counts.regularFiles)")
    lines.append("  Directories: \(report.root.counts.directories)")
    lines.append("  Symbolic links: \(report.root.counts.symbolicLinks)")
    lines.append("  Other entries: \(report.root.counts.other)")
    lines.append("  Duplicate hard links: \(report.root.counts.duplicateHardLinks)")
  }

  private static func appendAccountingUncertainty(
    _ report: ScanReport,
    to lines: inout [String]
  ) {
    lines.append("Accounting uncertainty:")
    if report.traversalDetailsWereDiscarded {
      lines.append("  Descendant accounting: unavailable")
    } else {
      lines.append("  Unknown allocated sizes: \(report.root.unknownAllocatedItemCount)")
      lines.append(
        "  Possible shared-content files: \(report.root.possibleSharedContentFileCount)"
      )
      lines.append(
        "  Shared-content metadata unavailable: \(report.root.sharedContentMetadataUnavailableCount)"
      )
      lines.append(
        "  Hard-link groups with unobserved links: \(report.root.unobservedHardLinkFileCount)"
      )
      lines.append(
        "  Non-exclusive hard-link paths: \(report.root.nonExclusiveHardLinkFileCount)"
      )
    }
    lines.append(
      "  Note: observed allocation is not guaranteed reclaimable space; hard-link-exclusive accounting adjusts regular-file hard links only."
    )
  }

  private static func appendTopLevelItems(
    _ report: ScanReport,
    to lines: inout [String]
  ) {
    if report.traversalDetailsWereDiscarded {
      lines.append("Top-level items: unavailable (traversal details discarded)")
      return
    }

    if report.topLevelItemsWereSuppressed {
      lines.append("Top-level items: suppressed (\(report.topLevelItemCount) observed)")
      return
    }

    guard !report.topLevelItems.isEmpty else {
      lines.append("Top-level items: none")
      return
    }

    lines.append(
      "Top-level items (\(report.topLevelItemCount), largest apparent allocation first):"
    )

    let sortedItems = report.topLevelItems.sorted { left, right in
      if left.recursiveSize.allocatedBytes != right.recursiveSize.allocatedBytes {
        return left.recursiveSize.allocatedBytes > right.recursiveSize.allocatedBytes
      }
      return left.path < right.path
    }

    for item in sortedItems {
      let status = item.isComplete ? "complete" : "partial"
      let hardLinkStatus =
        report.hardLinkAccountingIsComplete && item.isComplete ? "" : " (partial)"
      lines.append(
        "- \(IECByteCountFormatter.string(from: item.recursiveSize.allocatedBytes)) apparent"
          + " | \(IECByteCountFormatter.string(from: item.hardLinkExclusiveAllocatedBytes)) hard-link-exclusive\(hardLinkStatus)"
          + " | \(item.kind.rawValue) | \(status)"
          + " | \(TerminalText.quoted(path: item.path))"
      )
    }
  }

  private static func appendWarnings(
    _ report: ScanReport,
    to lines: inout [String]
  ) {
    var warnings: [String] = []
    if !report.root.isComplete {
      warnings.append("The root summary is incomplete.")
    }
    if report.traversalDetailsWereDiscarded {
      warnings.append(
        "The global entry limit was reached; descendant summaries, top-level details, and hard-link accounting were discarded."
      )
    } else {
      if report.topLevelItemsWereSuppressed {
        warnings.append("Top-level item details exceeded their output bound and were suppressed.")
      }
      if !report.hardLinkAccountingIsComplete {
        warnings.append("Hard-link-exclusive accounting is incomplete.")
      }
    }
    if report.suppressedIssueCount > 0 {
      warnings.append("\(report.suppressedIssueCount) additional issues were suppressed.")
    }

    guard !warnings.isEmpty else {
      return
    }

    lines.append("Warnings:")
    lines.append(contentsOf: warnings.map { "- \($0)" })
    lines.append("")
  }

  private static func appendIssues(
    _ report: ScanReport,
    to lines: inout [String]
  ) {
    lines.append(
      "Issues: \(report.issues.count) recorded, \(report.suppressedIssueCount) suppressed"
    )

    for issue in report.issues {
      var line =
        "- \(TerminalText.quoted(path: issue.path)): \(issue.operation.rawValue)"
        + " / \(issue.reason.rawValue) / \(issue.impact.rawValue)"
      if let systemCode = issue.systemCode {
        line += " / errno \(systemCode)"
      }
      lines.append(line)
    }
  }
}

enum ScanJSONEncodingError: Error {
  case invalidUTF8
}

enum ScanJSONRenderer {
  static func render(report: ScanReport, limits: ScanLimits) throws -> String {
    let document = ScanJSONDocumentV1(report: report, limits: limits)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(document)

    guard let output = String(data: data, encoding: .utf8) else {
      throw ScanJSONEncodingError.invalidUTF8
    }
    return output + "\n"
  }
}

struct ScanJSONDocumentV1: Codable, Equatable, Sendable {
  let schema: String
  let schemaVersion: Int
  let devsiftVersion: String
  let safetyMode: String
  let pathStyle: String
  let limits: ScanJSONLimitsV1
  let report: ScanJSONReportV1

  init(report: ScanReport, limits: ScanLimits) {
    schema = "devsift.scan"
    schemaVersion = 1
    devsiftVersion = DevSiftStatus.current.version
    safetyMode = DevSiftStatus.current.safetyMode.rawValue
    pathStyle = "root-relative"
    self.limits = ScanJSONLimitsV1(limits: limits)
    self.report = ScanJSONReportV1(report: report)
  }

  enum CodingKeys: String, CodingKey {
    case schema
    case schemaVersion
    case devsiftVersion
    case safetyMode
    case pathStyle
    case limits
    case report
  }
}

struct ScanJSONLimitsV1: Codable, Equatable, Sendable {
  let maximumDepth: String
  let maximumRecordedIssues: String
  let maximumEntries: String
  let maximumTopLevelItems: String
  let maximumTrackedHardLinkEntries: String
  let maximumTrackedHardLinkPathBytes: String

  init(limits: ScanLimits) {
    maximumDepth = String(limits.maximumDepth)
    maximumRecordedIssues = String(limits.maximumRecordedIssues)
    maximumEntries = String(limits.maximumEntries)
    maximumTopLevelItems = String(limits.maximumTopLevelItems)
    maximumTrackedHardLinkEntries = String(limits.maximumTrackedHardLinkEntries)
    maximumTrackedHardLinkPathBytes = String(limits.maximumTrackedHardLinkPathBytes)
  }

  enum CodingKeys: String, CodingKey {
    case maximumDepth
    case maximumRecordedIssues
    case maximumEntries
    case maximumTopLevelItems
    case maximumTrackedHardLinkEntries
    case maximumTrackedHardLinkPathBytes
  }
}

struct ScanJSONReportV1: Codable, Equatable, Sendable {
  let isComplete: Bool
  let root: ScanJSONItemV1
  let topLevelItems: [ScanJSONItemV1]
  let topLevelItemCount: String
  let topLevelItemsWereSuppressed: Bool
  let hardLinkAccountingIsComplete: Bool
  let traversalDetailsWereDiscarded: Bool
  let issues: [ScanJSONIssueV1]
  let suppressedIssueCount: String

  init(report: ScanReport) {
    isComplete = report.isComplete
    root = ScanJSONItemV1(item: report.root)
    topLevelItems = report.topLevelItems.map(ScanJSONItemV1.init)
    topLevelItemCount = String(report.topLevelItemCount)
    topLevelItemsWereSuppressed = report.topLevelItemsWereSuppressed
    hardLinkAccountingIsComplete = report.hardLinkAccountingIsComplete
    traversalDetailsWereDiscarded = report.traversalDetailsWereDiscarded
    issues = report.issues.map(ScanJSONIssueV1.init)
    suppressedIssueCount = String(report.suppressedIssueCount)
  }

  enum CodingKeys: String, CodingKey {
    case isComplete
    case root
    case topLevelItems
    case topLevelItemCount
    case topLevelItemsWereSuppressed
    case hardLinkAccountingIsComplete
    case traversalDetailsWereDiscarded
    case issues
    case suppressedIssueCount
  }
}

struct ScanJSONItemV1: Codable, Equatable, Sendable {
  let path: ScanJSONPathV1
  let kind: String
  let recursiveSize: ScanJSONSizeV1
  let hardLinkExclusiveAllocatedBytes: String
  let counts: ScanJSONCountsV1
  let unknownAllocatedItemCount: String
  let possibleSharedContentFileCount: String
  let sharedContentMetadataUnavailableCount: String
  let unobservedHardLinkFileCount: String
  let nonExclusiveHardLinkFileCount: String
  let isComplete: Bool

  init(item: ScanItemSummary) {
    path = ScanJSONPathV1(path: item.path)
    kind = item.kind.rawValue
    recursiveSize = ScanJSONSizeV1(size: item.recursiveSize)
    hardLinkExclusiveAllocatedBytes = String(item.hardLinkExclusiveAllocatedBytes)
    counts = ScanJSONCountsV1(counts: item.counts)
    unknownAllocatedItemCount = String(item.unknownAllocatedItemCount)
    possibleSharedContentFileCount = String(item.possibleSharedContentFileCount)
    sharedContentMetadataUnavailableCount = String(item.sharedContentMetadataUnavailableCount)
    unobservedHardLinkFileCount = String(item.unobservedHardLinkFileCount)
    nonExclusiveHardLinkFileCount = String(item.nonExclusiveHardLinkFileCount)
    isComplete = item.isComplete
  }

  enum CodingKeys: String, CodingKey {
    case path
    case kind
    case recursiveSize
    case hardLinkExclusiveAllocatedBytes
    case counts
    case unknownAllocatedItemCount
    case possibleSharedContentFileCount
    case sharedContentMetadataUnavailableCount
    case unobservedHardLinkFileCount
    case nonExclusiveHardLinkFileCount
    case isComplete
  }
}

struct ScanJSONPathV1: Codable, Equatable, Sendable {
  let display: String
  let rawComponentsBase64: [String]

  init(path: ScanRelativePath) {
    display = path.description
    rawComponentsBase64 = path.rawComponents.map { Data($0).base64EncodedString() }
  }

  enum CodingKeys: String, CodingKey {
    case display
    case rawComponentsBase64
  }
}

struct ScanJSONSizeV1: Codable, Equatable, Sendable {
  let logicalBytes: String
  let allocatedBytes: String

  init(size: StorageSize) {
    logicalBytes = String(size.logicalBytes)
    allocatedBytes = String(size.allocatedBytes)
  }

  enum CodingKeys: String, CodingKey {
    case logicalBytes
    case allocatedBytes
  }
}

struct ScanJSONCountsV1: Codable, Equatable, Sendable {
  let regularFiles: String
  let directories: String
  let symbolicLinks: String
  let other: String
  let duplicateHardLinks: String
  let total: String

  init(counts: ScanEntryCounts) {
    regularFiles = String(counts.regularFiles)
    directories = String(counts.directories)
    symbolicLinks = String(counts.symbolicLinks)
    other = String(counts.other)
    duplicateHardLinks = String(counts.duplicateHardLinks)
    total = String(counts.total)
  }

  enum CodingKeys: String, CodingKey {
    case regularFiles
    case directories
    case symbolicLinks
    case other
    case duplicateHardLinks
    case total
  }
}

struct ScanJSONIssueV1: Codable, Equatable, Sendable {
  let path: ScanJSONPathV1
  let operation: String
  let reason: String
  let impact: String
  let systemCode: Int32?

  init(issue: ScanIssue) {
    path = ScanJSONPathV1(path: issue.path)
    operation = issue.operation.rawValue
    reason = issue.reason.rawValue
    impact = issue.impact.rawValue
    systemCode = issue.systemCode
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    path = try container.decode(ScanJSONPathV1.self, forKey: .path)
    operation = try container.decode(String.self, forKey: .operation)
    reason = try container.decode(String.self, forKey: .reason)
    impact = try container.decode(String.self, forKey: .impact)
    systemCode = try container.decodeIfPresent(Int32.self, forKey: .systemCode)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(path, forKey: .path)
    try container.encode(operation, forKey: .operation)
    try container.encode(reason, forKey: .reason)
    try container.encode(impact, forKey: .impact)
    if let systemCode {
      try container.encode(systemCode, forKey: .systemCode)
    } else {
      try container.encodeNil(forKey: .systemCode)
    }
  }

  enum CodingKeys: String, CodingKey {
    case path
    case operation
    case reason
    case impact
    case systemCode
  }
}
