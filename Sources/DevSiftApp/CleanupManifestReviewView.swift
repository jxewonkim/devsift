import DevSiftCore
import Foundation
import SwiftUI

struct CleanupManifestReviewView: View {
  let root: URL
  let review: CleanupManifestReviewPresentation
  let backToSelection: () -> Void

  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 14) {
        reviewHeading
        safetyNotice
        if review.hasDeferredExecutionPreconditions {
          deferredExecutionNotice
        }
        summary
        uncertaintySummary
        entryList
        reviewFooter
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 28)
      .padding(.vertical, 16)
    }
    .defaultScrollAnchor(.top)
  }

  private var reviewHeading: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Button(action: backToSelection) {
          Label("Back to Selection", systemImage: "chevron.backward")
        }
        .accessibilityHint("Discards this review presentation and returns to your selected items")

        Spacer()

        Label("Unapproved draft", systemImage: "doc.badge.clock")
          .font(.callout.weight(.medium))
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Draft cleanup plan")
          .font(.system(size: 28, weight: .semibold))
          .accessibilityAddTraits(.isHeader)
        Text(SafeDisplayText.filePath(root))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(SafeDisplayText.filePath(root))
      }
    }
  }

  private var safetyNotice: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "lock.shield.fill")
        .font(.title2)
        .foregroundStyle(.blue)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text("Review only — no files were changed")
          .font(.headline)
        Text(
          "This in-memory snapshot is not approval and cannot be executed. It may already be stale; any future cleanup must freshly revalidate the root, every item, and its policy evidence."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color.blue.opacity(0.25), lineWidth: 0.5)
    }
    .accessibilityElement(children: .combine)
  }

  private var deferredExecutionNotice: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.title2)
        .foregroundStyle(.orange)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text(review.deferredExecutionNoticeTitle)
          .font(.headline)
        Text(review.deferredExecutionNoticeMessage)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color.orange.opacity(0.3), lineWidth: 0.5)
    }
    .accessibilityElement(children: .combine)
  }

  private var summary: some View {
    HStack(spacing: 10) {
      ReviewMetric(
        title: "Selected items",
        value: review.entryCount.formatted(),
        detail:
          "\(review.reclaimableCount.formatted()) reclaimable · \(review.reviewRequiredCount.formatted()) review"
      )
      ReviewMetric(
        title: "Observed allocation",
        value: StorageByteFormatter.string(from: review.totals.observedAllocatedBytes),
        detail: "Apparent allocated bytes"
      )
      ReviewMetric(
        title: "Link-adjusted",
        value: StorageByteFormatter.string(
          from: review.totals.observedHardLinkExclusiveAllocatedBytes
        ),
        detail: "Observed file-level estimate"
      )
    }
    .accessibilityElement(children: .contain)
  }

  private var uncertaintySummary: some View {
    GroupBox {
      Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 5) {
        uncertaintyRow(
          "Observed logical bytes",
          StorageByteFormatter.string(from: review.totals.observedLogicalBytes),
          "Possible shared-content files",
          review.totals.possibleSharedContentFileCount.formatted()
        )
        uncertaintyRow(
          "Shared metadata unavailable",
          review.totals.sharedContentMetadataUnavailableCount.formatted(),
          "Unobserved hard-link files",
          review.totals.unobservedHardLinkFileCount.formatted()
        )
        uncertaintyRow(
          "Non-exclusive hard-link files",
          review.totals.nonExclusiveHardLinkFileCount.formatted(),
          "Guaranteed savings",
          "Not available"
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      Label("Observed quantities and uncertainty", systemImage: "chart.bar.doc.horizontal")
        .font(.callout.weight(.medium))
    }
  }

  private func uncertaintyRow(
    _ firstTitle: String,
    _ firstValue: String,
    _ secondTitle: String,
    _ secondValue: String
  ) -> some View {
    GridRow {
      Text(firstTitle)
        .foregroundStyle(.secondary)
      Text(firstValue)
        .monospacedDigit()
      Text(secondTitle)
        .foregroundStyle(.secondary)
      Text(secondValue)
        .monospacedDigit()
    }
    .font(.caption)
  }

  private var entryList: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Draft entries")
          .font(.headline)
        Spacer()
        Text("Canonical raw-path order")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      LazyVStack(spacing: 8) {
        ForEach(review.entries) { entry in
          CleanupManifestReviewEntryView(entry: entry)
        }
      }
    }
  }

  private var reviewFooter: some View {
    Label(
      "Observed values are estimates, not guaranteed reclaimable space. Return to selection or rescan to discard the in-memory draft.",
      systemImage: "info.circle"
    )
    .font(.caption)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }
}

private struct ReviewMetric: View {
  let title: String
  let value: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.title3.weight(.semibold))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.75)
      Text(detail)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct CleanupManifestReviewEntryView: View {
  let entry: CleanupManifestReviewEntryPresentation

  @State private var isExpanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 10) {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
          detailRow("Rule", entry.ruleRevisionLabel)
          detailRow("Tool", entry.responsibleTool)
          detailRow("Reproducibility", entry.reproducibility.reviewDisplayName)
          detailRow(
            "Observed allocation",
            StorageByteFormatter.string(from: entry.size.observedAllocatedBytes)
          )
          detailRow(
            "Link-adjusted",
            StorageByteFormatter.string(
              from: entry.size.observedHardLinkExclusiveAllocatedBytes
            )
          )
          detailRow(
            "Observed logical bytes",
            StorageByteFormatter.string(from: entry.size.observedLogicalBytes)
          )
        }

        Text(entry.classificationExplanation)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Divider()

        if !entry.deferredExecutionPreconditions.isEmpty {
          Text("Pending execution requirements")
            .font(.caption.weight(.semibold))

          ForEach(entry.deferredExecutionPreconditions, id: \.identifier) { precondition in
            HStack(alignment: .top, spacing: 7) {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
              VStack(alignment: .leading, spacing: 2) {
                Text(precondition.title)
                  .font(.caption.weight(.medium))
                Text(precondition.identifierAndRevisionLabel)
                  .font(.caption2.monospaced())
                  .foregroundStyle(.secondary)
                Text(precondition.explanation)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
            .accessibilityElement(children: .combine)
          }

          Divider()
        }

        Text("Policy findings")
          .font(.caption.weight(.semibold))

        ForEach(entry.findings, id: \.identifier) { finding in
          HStack(alignment: .top, spacing: 7) {
            Image(systemName: finding.state.systemImage)
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
              Text("\(finding.kind.displayName) · \(finding.state.displayName)")
                .font(.caption.weight(.medium))
              Text(finding.identifier)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
              Text(finding.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }

        CleanupEntryUncertainty(entry: entry)
      }
      .padding(.top, 8)
    } label: {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(entry.displayPath)
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .help(entry.displayPath)
          Text(entry.displayName)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Spacer()

        Text(entry.disposition.reviewDisplayName)
          .font(.caption.weight(.medium))
          .foregroundStyle(entry.disposition == .reviewRequired ? .orange : .blue)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(
            (entry.disposition == .reviewRequired ? Color.orange : Color.blue).opacity(0.1),
            in: Capsule()
          )

        Text(StorageByteFormatter.string(from: entry.size.observedAllocatedBytes))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
    }
    .accessibilityHint(
      isExpanded ? "Collapses the draft evidence" : "Expands the draft evidence"
    )
  }

  private func detailRow(_ title: String, _ value: String) -> some View {
    GridRow {
      Text(title)
        .foregroundStyle(.secondary)
      Text(value)
        .textSelection(.enabled)
    }
    .font(.caption)
  }
}

private struct CleanupEntryUncertainty: View {
  let entry: CleanupManifestReviewEntryPresentation

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("Accounting uncertainty")
        .font(.caption.weight(.semibold))
      Text(
        "Possible shared content \(entry.size.possibleSharedContentFileCount.formatted()) · shared metadata unavailable \(entry.size.sharedContentMetadataUnavailableCount.formatted()) · unobserved hard links \(entry.size.unobservedHardLinkFileCount.formatted()) · non-exclusive hard links \(entry.size.nonExclusiveHardLinkFileCount.formatted())"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}

extension RuleDisposition {
  fileprivate var reviewDisplayName: String {
    switch self {
    case .reclaimable:
      "Reclaimable classification"
    case .reviewRequired:
      "Review required"
    case .protected:
      "Protected"
    }
  }
}

extension RuleReproducibility {
  fileprivate var reviewDisplayName: String {
    switch self {
    case .reproducible:
      "Reproducible"
    case .conditional:
      "Conditional"
    case .unknown:
      "Unknown"
    }
  }
}
