import DevSiftCore
import Foundation

struct ScanItemRow: Hashable, Identifiable, Sendable {
  let summary: ScanItemSummary
  let displayPath: String

  var id: ScanRelativePath {
    summary.path
  }

  var observationIsComplete: Bool {
    summary.isComplete
      && summary.unknownAllocatedItemCount == 0
      && !summary.sizeOverflowed
  }
}

struct ScanPresentation: Equatable, Sendable {
  let report: ScanReport
  let items: [ScanItemRow]

  var metricsAreAvailable: Bool {
    !report.traversalDetailsWereDiscarded
  }

  var sizeMetricsAreAvailable: Bool {
    metricsAreAvailable && !report.root.sizeOverflowed
  }

  var observationIsComplete: Bool {
    report.isComplete
      && report.root.unknownAllocatedItemCount == 0
      && !report.root.sizeOverflowed
  }

  var partialDetailMessages: [String] {
    var messages: [String] = []
    if report.traversalDetailsWereDiscarded {
      messages.append(
        "Earlier descendant totals and scan issues were discarded; their total is unknown."
      )
    }
    if report.topLevelItemsWereSuppressed && !report.traversalDetailsWereDiscarded {
      messages.append("Top-level details exceeded the configured reporting limit.")
    }
    if !report.hardLinkAccountingIsComplete {
      messages.append("Hard-link-adjusted allocation is partial.")
    }
    if report.root.unknownAllocatedItemCount > 0 {
      let noun = report.root.unknownAllocatedItemCount == 1 ? "entry" : "entries"
      let verb = report.root.unknownAllocatedItemCount == 1 ? "has" : "have"
      messages.append(
        "\(report.root.unknownAllocatedItemCount.formatted()) \(noun) \(verb) unknown allocation."
      )
    }
    if report.root.sizeOverflowed {
      messages.append("One or more root size totals overflowed; exact values are unavailable.")
    }
    if report.suppressedIssueCount > 0 {
      let noun = report.suppressedIssueCount == 1 ? "issue" : "issues"
      messages.append(
        "\(report.suppressedIssueCount.formatted()) additional scan \(noun) \(report.suppressedIssueCount == 1 ? "was" : "were") not retained."
      )
    }
    return messages
  }

  static func prepare(report: ScanReport) async throws -> ScanPresentation {
    let worker = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()

      let sortedItems = report.topLevelItems.sorted { left, right in
        if left.recursiveSize.allocatedBytes != right.recursiveSize.allocatedBytes {
          return left.recursiveSize.allocatedBytes > right.recursiveSize.allocatedBytes
        }
        return left.path < right.path
      }
      try Task.checkCancellation()

      return ScanPresentation(
        report: report,
        items: sortedItems.map {
          ScanItemRow(summary: $0, displayPath: SafeDisplayText.path($0.path))
        }
      )
    }

    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
  }
}

enum SafeDisplayText {
  static func path(_ path: ScanRelativePath) -> String {
    guard !path.rawComponents.isEmpty else {
      return "."
    }

    return path.rawComponents.map(component).joined(separator: "/")
  }

  static func fileName(of url: URL) -> String {
    let bytes = fileSystemBytes(of: url)
    guard !bytes.isEmpty else {
      return "/"
    }

    let trimmed = bytes.last == 0x2F ? Array(bytes.dropLast()) : bytes
    guard !trimmed.isEmpty else {
      return "/"
    }
    guard let separator = trimmed.lastIndex(of: 0x2F) else {
      return component(trimmed)
    }
    let name = Array(trimmed[trimmed.index(after: separator)...])
    return name.isEmpty ? "/" : component(name)
  }

  static func filePath(_ url: URL) -> String {
    let bytes = fileSystemBytes(of: url)
    guard !bytes.isEmpty else {
      return "."
    }

    let isAbsolute = bytes.first == 0x2F
    let parts = bytes.split(separator: 0x2F, omittingEmptySubsequences: true)
      .map { component(Array($0)) }
    let rendered = parts.joined(separator: "/")
    return isAbsolute ? "/" + rendered : rendered
  }

  static func scalarSafe(_ value: String) -> String {
    var output = ""
    for scalar in value.unicodeScalars {
      append(scalar, to: &output)
    }
    return output
  }

  private static func component(_ bytes: [UInt8]) -> String {
    guard let value = String(bytes: bytes, encoding: .utf8) else {
      return bytes.map { String(format: "\\x%02X", $0) }.joined()
    }
    return scalarSafe(value)
  }

  private static func append(_ scalar: Unicode.Scalar, to output: inout String) {
    switch scalar {
    case "\\":
      output += "\\\\"
    case "\n":
      output += "\\n"
    case "\r":
      output += "\\r"
    case "\t":
      output += "\\t"
    default:
      let category = scalar.properties.generalCategory
      let mustEscape =
        scalar.properties.isDefaultIgnorableCodePoint
        || category == .control
        || category == .format
        || category == .lineSeparator
        || category == .paragraphSeparator

      if mustEscape {
        output += String(format: "\\u{%04X}", scalar.value)
      } else {
        output.unicodeScalars.append(scalar)
      }
    }
  }

  private static func fileSystemBytes(of url: URL) -> [UInt8] {
    url.withUnsafeFileSystemRepresentation { pointer in
      guard let pointer else {
        return []
      }
      return Array(UnsafeBufferPointer(start: pointer, count: strlen(pointer))).map(UInt8.init)
    }
  }
}

enum StorageByteFormatter {
  private static let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]

  static func string(from bytes: UInt64) -> String {
    guard bytes >= 1_024 else {
      return "\(bytes) B"
    }

    var value = Double(bytes)
    var unitIndex = 0
    while value >= 1_024, unitIndex < units.count - 1 {
      value /= 1_024
      unitIndex += 1
    }

    return String(
      format: "%.1f %@",
      locale: Locale(identifier: "en_US_POSIX"),
      value,
      units[unitIndex]
    )
  }
}

enum DashboardAccessibility {
  static func announcement(for phase: ScanDashboardPhase) -> String? {
    switch phase {
    case .empty:
      nil
    case .scanning(let root):
      "Scanning \(SafeDisplayText.fileName(of: root)). File contents are never opened."
    case .result(_, let presentation):
      presentation.observationIsComplete
        ? "Scan complete within configured limits. Results are ready."
        : "Partial scan. Some entries or accounting details were not observed. Results are ready."
    case .cancelled:
      "Scan cancelled. No files were changed."
    case .failed(_, let failure):
      "\(failure.title). No files were changed."
    }
  }
}

extension FileSystemEntryKind {
  var displayName: String {
    switch self {
    case .regularFile:
      "File"
    case .directory:
      "Folder"
    case .symbolicLink:
      "Symbolic link"
    case .other:
      "Other"
    }
  }

  var systemImage: String {
    switch self {
    case .regularFile:
      "doc"
    case .directory:
      "folder"
    case .symbolicLink:
      "link"
    case .other:
      "questionmark.square"
    }
  }
}

extension ScanIssueReason {
  var displayName: String {
    switch self {
    case .permissionDenied:
      "Permission denied"
    case .disappeared:
      "Item disappeared"
    case .changedDuringScan:
      "Changed during scan"
    case .crossedVolumeBoundary:
      "Volume boundary"
    case .outsideRoot:
      "Outside selected folder"
    case .depthLimitReached:
      "Depth limit reached"
    case .resourceLimit:
      "Resource limit reached"
    case .invalidMetadata:
      "Metadata unavailable"
    case .sizeOverflow:
      "Size overflow"
    case .ioFailure:
      "Input/output failure"
    }
  }
}

extension ScanIssueImpact {
  var displayName: String {
    switch self {
    case .entrySkipped:
      "Item skipped"
    case .descendantsSkipped:
      "Contents skipped"
    case .estimateDegraded:
      "Estimate degraded"
    }
  }
}

extension ScanOperation {
  var displayName: String {
    switch self {
    case .validateRoot:
      "Validate folder"
    case .listDirectory:
      "List folder"
    case .readMetadata:
      "Read metadata"
    case .measureSize:
      "Measure size"
    }
  }
}
