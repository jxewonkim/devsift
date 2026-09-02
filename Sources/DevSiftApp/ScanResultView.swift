import AppKit
import DevSiftCore
import SwiftUI

struct ScanResultView: View {
  let root: URL
  let presentation: ScanPresentation

  @State private var selectedItem: ScanRelativePath?
  @State private var notesAreExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      resultHeading
      SummaryBand(presentation: presentation)

      if shouldShowObservationNotice {
        ObservationNotice(presentation: presentation)
      }

      topLevelContent

      AccountingFootnote(presentation: presentation)
    }
    .padding(.horizontal, 28)
    .padding(.top, 16)
    .padding(.bottom, 10)
  }

  private var resultHeading: some View {
    HStack(alignment: .firstTextBaseline, spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text(SafeDisplayText.fileName(of: root))
          .font(.system(size: 28, weight: .semibold))
          .lineLimit(1)
          .accessibilityAddTraits(.isHeader)
        Text(SafeDisplayText.filePath(root))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(SafeDisplayText.filePath(root))
      }

      Spacer()

      Label(
        presentation.observationIsComplete ? "Complete observation" : "Partial observation",
        systemImage: presentation.observationIsComplete
          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
      )
      .font(.callout.weight(.medium))
      .foregroundStyle(presentation.observationIsComplete ? .green : .orange)
      .accessibilityLabel(
        presentation.observationIsComplete
          ? "Scan complete within configured limits"
          : "Partial scan. Some entries or accounting details were not observed"
      )
    }
  }

  @ViewBuilder
  private var topLevelContent: some View {
    if presentation.report.traversalDetailsWereDiscarded {
      UnavailableResultsView(
        title: "Largest observed items unavailable",
        message:
          "The entry limit was reached. Descendant totals, top-level details, and earlier scan notes were discarded; only the selected folder inode remains in the diagnostic report."
      )
    } else if presentation.report.topLevelItemsWereSuppressed {
      UnavailableResultsView(
        title: "Top-level details suppressed",
        message:
          "\(presentation.report.topLevelItemCount.formatted()) top-level items were observed. Their details exceeded the configured reporting limit, so no partial subset is shown."
      )
    } else if presentation.items.isEmpty {
      UnavailableResultsView(
        title: "No top-level items observed",
        message: "The selected folder contained no entries within the configured scan scope."
      )
    } else {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Largest observed items")
            .font(.headline)
          Text("Apparent allocation, largest first")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Text("\(presentation.items.count.formatted()) shown")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Table(presentation.items, selection: $selectedItem) {
          TableColumn("Item") { row in
            HStack(spacing: 8) {
              Image(systemName: row.summary.kind.systemImage)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
              Text(row.displayPath)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .help(row.displayPath)
          }
          .width(min: 180, ideal: 240, max: 520)

          TableColumn("Kind") { row in
            Text(row.summary.kind.displayName)
              .foregroundStyle(.secondary)
          }
          .width(min: 60, ideal: 72, max: 90)

          TableColumn("Allocation") { row in
            SizeCell(
              bytes: row.summary.recursiveSize.allocatedBytes,
              isAvailable: !row.summary.sizeOverflowed,
              isPartial: !row.summary.isComplete
                || row.summary.unknownAllocatedItemCount > 0
            )
          }
          .width(min: 110, ideal: 120, max: 140)

          TableColumn("Link-adjusted") { row in
            SizeCell(
              bytes: row.summary.hardLinkExclusiveAllocatedBytes,
              isAvailable: !row.summary.sizeOverflowed,
              isPartial: !presentation.report.hardLinkAccountingIsComplete
                || !row.summary.isComplete
                || row.summary.unknownAllocatedItemCount > 0
                || row.summary.unobservedHardLinkFileCount > 0
            )
          }
          .width(min: 110, ideal: 120, max: 140)

          TableColumn("Entries") { row in
            Text(row.summary.counts.total.formatted())
              .monospacedDigit()
          }
          .width(min: 55, ideal: 64, max: 80)

          TableColumn("Status") { row in
            Label(
              row.observationIsComplete ? "Complete" : "Partial",
              systemImage: row.observationIsComplete
                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .labelStyle(.titleAndIcon)
            .foregroundStyle(row.observationIsComplete ? .green : .orange)
          }
          .width(min: 80, ideal: 88, max: 104)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .frame(minHeight: 180)
        .accessibilityLabel("Largest observed top-level items")
      }
    }
  }

  private var shouldShowObservationNotice: Bool {
    !presentation.observationIsComplete
      || !presentation.report.issues.isEmpty
      || presentation.report.suppressedIssueCount > 0
  }
}

private struct SummaryBand: View {
  let presentation: ScanPresentation

  var body: some View {
    VStack(spacing: 14) {
      HStack(spacing: 0) {
        MetricView(
          title: "Observed apparent allocation",
          value: sizeValue(presentation.report.root.recursiveSize.allocatedBytes),
          detail: apparentSizeDetail
        )
        Divider().padding(.vertical, 2)
        MetricView(
          title: "Hard-link-adjusted allocation",
          value: sizeValue(presentation.report.root.hardLinkExclusiveAllocatedBytes),
          detail: hardLinkDetail
        )
        Divider().padding(.vertical, 2)
        MetricView(
          title: "Observed logical size",
          value: sizeValue(presentation.report.root.recursiveSize.logicalBytes),
          detail: logicalSizeDetail
        )
        Divider().padding(.vertical, 2)
        MetricView(
          title: "Observed entries",
          value: entryValue,
          detail: presentation.metricsAreAvailable
            ? "Includes selected folder" : "Entry limit reached"
        )
      }

      if presentation.sizeMetricsAreAvailable,
        !presentation.report.topLevelItemsWereSuppressed,
        !presentation.items.isEmpty
      {
        AllocationDistributionBar(presentation: presentation)
      }
    }
    .padding(16)
    .background {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
    }
  }

  private var apparentSizeDetail: String {
    if !presentation.metricsAreAvailable {
      return "Entry limit reached"
    }
    if presentation.report.root.sizeOverflowed {
      return "Exact total unavailable"
    }
    if !presentation.report.root.isComplete
      || presentation.report.root.unknownAllocatedItemCount > 0
    {
      return "Partial metadata"
    }
    return "Observed metadata"
  }

  private var logicalSizeDetail: String {
    if !presentation.metricsAreAvailable {
      return "Entry limit reached"
    }
    if presentation.report.root.sizeOverflowed {
      return "Exact total unavailable"
    }
    return presentation.report.root.isComplete ? "Observed metadata" : "Partial metadata"
  }

  private var hardLinkDetail: String {
    if !presentation.metricsAreAvailable {
      return "Entry limit reached"
    }
    if presentation.report.root.sizeOverflowed {
      return "Exact total unavailable"
    }
    let isPartial =
      !presentation.report.hardLinkAccountingIsComplete
      || !presentation.report.root.isComplete
      || presentation.report.root.unknownAllocatedItemCount > 0
    return isPartial ? "Partial accounting" : "Regular-file links adjusted"
  }

  private var entryValue: String {
    presentation.metricsAreAvailable
      ? presentation.report.root.counts.total.formatted() : "Unavailable"
  }

  private func sizeValue(_ bytes: UInt64) -> String {
    guard presentation.metricsAreAvailable else {
      return "Unavailable"
    }
    guard !presentation.report.root.sizeOverflowed else {
      return "Overflow"
    }
    return StorageByteFormatter.string(from: bytes)
  }
}

private struct MetricView: View {
  let title: String
  let value: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Text(value)
        .font(.title3.weight(.semibold))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
      Text(detail)
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .accessibilityElement(children: .combine)
  }
}

private struct AllocationDistributionBar: View {
  let presentation: ScanPresentation

  private var segments: [(id: ScanRelativePath, bytes: UInt64, color: Color)] {
    let colors: [Color] = [
      .accentColor,
      .accentColor.opacity(0.76),
      .accentColor.opacity(0.58),
      .accentColor.opacity(0.42),
      .secondary.opacity(0.28),
    ]

    return zip(presentation.items.prefix(colors.count), colors).compactMap { row, color in
      guard row.summary.recursiveSize.allocatedBytes > 0 else {
        return nil
      }
      return (row.id, row.summary.recursiveSize.allocatedBytes, color)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Top-level apparent allocation distribution")
        .font(.caption2)
        .foregroundStyle(.secondary)

      GeometryReader { geometry in
        HStack(spacing: 2) {
          ForEach(segments, id: \.id) { segment in
            segment.color
              .frame(width: segmentWidth(segment.bytes, available: geometry.size.width))
          }
          Color.secondary.opacity(0.12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
      }
      .frame(height: 7)
    }
    .padding(.horizontal, 12)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "Distribution of apparent allocation across the largest observed top-level items")
  }

  private func segmentWidth(_ bytes: UInt64, available: CGFloat) -> CGFloat {
    let total = max(presentation.report.root.recursiveSize.allocatedBytes, 1)
    let ratio = min(Double(bytes) / Double(total), 1)
    return max(CGFloat(ratio) * available, 2)
  }
}

private struct SizeCell: View {
  let bytes: UInt64
  let isAvailable: Bool
  let isPartial: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(isAvailable ? StorageByteFormatter.string(from: bytes) : "Unavailable")
        .monospacedDigit()
      if isPartial {
        Text("Partial")
          .font(.caption2)
          .foregroundStyle(.orange)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

private struct ObservationNotice: View {
  let presentation: ScanPresentation

  @State private var isExpanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      ForEach(presentation.partialDetailMessages, id: \.self) { message in
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.top, 6)

      ForEach(Array(presentation.report.issues.enumerated()), id: \.offset) { _, issue in
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "exclamationmark.circle")
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(SafeDisplayText.path(issue.path))
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
              Text(issue.reason.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(issueDetail(issue))
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
          Spacer()
        }
      }
    } label: {
      Label(noticeTitle, systemImage: "exclamationmark.triangle.fill")
        .font(.callout.weight(.medium))
        .foregroundStyle(.orange)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityHint("Expands partial scan details and retained issues")
  }

  private var noticeTitle: String {
    let retained = presentation.report.issues.count
    let suppressed = presentation.report.suppressedIssueCount
    let retainedNoun = retained == 1 ? "issue" : "issues"
    var parts = [
      "Partial scan — some entries or accounting details were not observed.",
      "\(retained.formatted()) scan \(retainedNoun) shown",
    ]
    if suppressed > 0 {
      let suppressedNoun = suppressed == 1 ? "issue" : "issues"
      parts.append("\(suppressed.formatted()) additional \(suppressedNoun) not retained")
    }
    return parts.joined(separator: " · ")
  }

  private func issueDetail(_ issue: ScanIssue) -> String {
    var parts = [issue.operation.displayName, issue.impact.displayName]
    if let systemCode = issue.systemCode {
      parts.append("POSIX \(systemCode)")
    }
    return parts.joined(separator: " · ")
  }
}

private struct UnavailableResultsView: View {
  let title: String
  let message: String

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: "list.bullet.rectangle")
        .font(.system(size: 32, weight: .light))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(title)
        .font(.headline)
      Text(message)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 620)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
    }
  }
}

private struct AccountingFootnote: View {
  let presentation: ScanPresentation

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(
        "Observed allocation is not guaranteed reclaimable. Hard links, clones, snapshots, compression, unreadable paths, and concurrent changes can affect actual free space."
      )
      if !accountingDetails.isEmpty {
        Text(accountingDetails.joined(separator: " · "))
      }
      Text(
        "The selected folder inode is included, so top-level rows may not sum to the root total.")
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var accountingDetails: [String] {
    let root = presentation.report.root
    var details: [String] = []
    if root.unknownAllocatedItemCount > 0 {
      let count = root.unknownAllocatedItemCount
      let noun = count == 1 ? "entry" : "entries"
      let verb = count == 1 ? "is" : "are"
      details.append(
        "\(count.formatted()) \(noun) with unknown allocation \(verb) excluded"
      )
    }
    if root.possibleSharedContentFileCount > 0 {
      details.append(
        "\(root.possibleSharedContentFileCount.formatted()) files may share APFS content"
      )
    }
    if root.sharedContentMetadataUnavailableCount > 0 {
      details.append(
        "shared-content metadata unavailable for \(root.sharedContentMetadataUnavailableCount.formatted()) files"
      )
    }
    if !presentation.report.hardLinkAccountingIsComplete {
      details.append("hard-link-adjusted allocation is partial")
    }
    if root.unobservedHardLinkFileCount > 0 {
      details.append(
        "\(root.unobservedHardLinkFileCount.formatted()) hard-link groups have links outside the observed scope"
      )
    }
    if root.nonExclusiveHardLinkFileCount > 0 {
      details.append(
        "\(root.nonExclusiveHardLinkFileCount.formatted()) hard-link paths receive no exclusive allocation credit"
      )
    }
    return details
  }
}
