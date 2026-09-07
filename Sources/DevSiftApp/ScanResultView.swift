import AppKit
import DevSiftCore
import SwiftUI

struct ScanResultView: View {
  @Environment(\.appLanguage) private var language

  let root: URL
  let presentation: ScanPresentation
  let cleanupReviewPhase: CleanupReviewPhase
  let cleanupCandidateCount: Int
  let selectedCleanupCandidates: Set<CleanupCandidateSelection>
  let setCleanupCandidate: (CleanupCandidateSelection, Bool) -> Void
  let clearCleanupCandidates: () -> Void
  let prepareCleanupReview: () -> Void
  let cancelCleanupReviewPreparation: () -> Void

  @State private var selectedItem: ScanRelativePath?
  @State private var policyDetailsAreExpanded: Bool

  init(
    root: URL,
    presentation: ScanPresentation,
    cleanupReviewPhase: CleanupReviewPhase,
    cleanupCandidateCount: Int,
    selectedCleanupCandidates: Set<CleanupCandidateSelection>,
    setCleanupCandidate: @escaping (CleanupCandidateSelection, Bool) -> Void,
    clearCleanupCandidates: @escaping () -> Void,
    prepareCleanupReview: @escaping () -> Void,
    cancelCleanupReviewPreparation: @escaping () -> Void,
    policyDetailsInitiallyExpanded: Bool = false
  ) {
    self.root = root
    self.presentation = presentation
    self.cleanupReviewPhase = cleanupReviewPhase
    self.cleanupCandidateCount = cleanupCandidateCount
    self.selectedCleanupCandidates = selectedCleanupCandidates
    self.setCleanupCandidate = setCleanupCandidate
    self.clearCleanupCandidates = clearCleanupCandidates
    self.prepareCleanupReview = prepareCleanupReview
    self.cancelCleanupReviewPreparation = cancelCleanupReviewPreparation
    _selectedItem = State(
      initialValue: policyDetailsInitiallyExpanded ? presentation.items.first?.id : nil
    )
    _policyDetailsAreExpanded = State(initialValue: policyDetailsInitiallyExpanded)
  }

  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 12) {
        resultHeading
        SummaryBand(presentation: presentation)

        if shouldShowObservationNotice {
          ObservationNotice(presentation: presentation)
        }

        topLevelContent

        CleanupDraftSelectionBar(
          candidateCount: cleanupCandidateCount,
          selectedCount: selectedCleanupCandidates.count,
          phase: cleanupReviewPhase,
          clearSelection: clearCleanupCandidates,
          prepareReview: prepareCleanupReview,
          cancelPreparation: cancelCleanupReviewPreparation
        )

        if let selectedRow {
          PolicyExplanationDisclosure(
            row: selectedRow,
            isExpanded: $policyDetailsAreExpanded
          )
        } else if !presentation.items.isEmpty {
          PolicySelectionPrompt()
        }

        AccountingFootnote(presentation: presentation)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 28)
      .padding(.top, 16)
      .padding(.bottom, 10)
    }
    .defaultScrollAnchor(.top)
    .onChange(of: selectedItem) { _, _ in
      policyDetailsAreExpanded = false
    }
    .onChange(of: presentation) { _, newPresentation in
      guard let selectedItem else {
        return
      }
      if !newPresentation.items.contains(where: { $0.id == selectedItem }) {
        self.selectedItem = nil
        policyDetailsAreExpanded = false
      }
    }
  }

  private var selectedRow: ScanItemRow? {
    guard let selectedItem else {
      return nil
    }
    return presentation.items.first { $0.id == selectedItem }
  }

  private var resultHeading: some View {
    HStack(alignment: .firstTextBaseline, spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: SafeDisplayText.fileName(of: root))
          .font(.system(size: 28, weight: .semibold))
          .lineLimit(1)
          .accessibilityAddTraits(.isHeader)
        Text(verbatim: SafeDisplayText.filePath(root))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(SafeDisplayText.filePath(root))
      }

      Spacer()

      Label(
        language.localized(
          presentation.observationIsComplete ? "Complete observation" : "Partial observation"
        ),
        systemImage: presentation.observationIsComplete
          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
      )
      .font(.callout.weight(.medium))
      .foregroundStyle(presentation.observationIsComplete ? .green : .orange)
      .accessibilityLabel(
        language.localized(
          presentation.observationIsComplete
            ? "Scan complete within configured limits"
            : "Partial scan. Some entries or accounting details were not observed"
        )
      )
    }
  }

  @ViewBuilder
  private var topLevelContent: some View {
    if presentation.report.traversalDetailsWereDiscarded {
      UnavailableResultsView(
        title: language.localized("Largest observed items unavailable"),
        message: language.localized(
          "The entry limit was reached. Descendant totals, top-level details, and earlier scan notes were discarded; only the selected folder inode remains in the diagnostic report."
        )
      )
    } else if presentation.report.topLevelItemsWereSuppressed {
      UnavailableResultsView(
        title: language.localized("Top-level details suppressed"),
        message: topLevelItemsSuppressedMessage
      )
    } else if presentation.items.isEmpty {
      UnavailableResultsView(
        title: language.localized("No top-level items observed"),
        message: language.localized(
          "The selected folder contained no entries within the configured scan scope."
        )
      )
    } else {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(language.localized("Largest observed items"))
            .font(.headline)
          Text(language.localized("Scanner observation · independent policy assessment"))
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Text(shownItemCount)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Table(presentation.items, selection: $selectedItem) {
          TableColumn(language.localized("Dry run")) { row in
            if let selection = row.cleanupSelection {
              Toggle(
                language.format("Include %@ in the dry run", row.displayPath),
                isOn: cleanupSelectionBinding(for: selection)
              )
              .labelsHidden()
              .toggleStyle(.checkbox)
              .disabled(cleanupReviewPhase.isPreparing)
              .accessibilityValue(
                language.localized(
                  selectedCleanupCandidates.contains(selection) ? "Included" : "Not included"
                )
              )
              .accessibilityHint(
                language.localized(
                  "Adds this exact path and rule revision to an unapproved in-memory draft"
                )
              )
            } else {
              Image(systemName: "lock.fill")
                .foregroundStyle(.tertiary)
                .accessibilityLabel(language.localized("Not eligible for the dry run"))
                .help(
                  language.localized("This item does not meet every Core planning requirement."))
            }
          }
          .width(58)

          TableColumn(language.localized("Item")) { row in
            HStack(spacing: 8) {
              Image(systemName: row.summary.kind.systemImage)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
              Text(verbatim: row.displayPath)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .help(row.displayPath)
          }
          .width(min: 130, ideal: 170, max: 360)

          TableColumn(language.localized("Kind")) { row in
            Text(language.localized(row.summary.kind.displayName))
              .foregroundStyle(.secondary)
          }
          .width(54)

          TableColumn(language.localized("Allocation")) { row in
            SizeCell(
              bytes: row.summary.recursiveSize.allocatedBytes,
              isAvailable: !row.summary.sizeOverflowed,
              isPartial: !row.summary.isComplete
                || row.summary.unknownAllocatedItemCount > 0
            )
          }
          .width(92)

          TableColumn(language.localized("Link-adjusted")) { row in
            SizeCell(
              bytes: row.summary.hardLinkExclusiveAllocatedBytes,
              isAvailable: !row.summary.sizeOverflowed,
              isPartial: !presentation.report.hardLinkAccountingIsComplete
                || !row.summary.isComplete
                || row.summary.unknownAllocatedItemCount > 0
                || row.summary.unobservedHardLinkFileCount > 0
            )
          }
          .width(98)

          TableColumn(language.localized("Entries")) { row in
            Text(language.format("%lld", Int64(clamping: row.summary.counts.total)))
              .monospacedDigit()
          }
          .width(54)

          TableColumn(language.localized("Observation")) { row in
            Label(
              language.localized(row.observationIsComplete ? "Complete" : "Partial"),
              systemImage: row.observationIsComplete
                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .labelStyle(.titleAndIcon)
            .foregroundStyle(row.observationIsComplete ? .green : .orange)
          }
          .width(86)

          TableColumn(language.localized("Policy")) { row in
            PolicyBadge(policy: row.policy)
          }
          .width(94)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .frame(height: tableHeight)
        .accessibilityLabel(
          language.localized(
            "Largest observed top-level items with observation and policy status"
          )
        )
      }
    }
  }

  private var shouldShowObservationNotice: Bool {
    !presentation.observationIsComplete
      || !presentation.report.issues.isEmpty
      || presentation.report.suppressedIssueCount > 0
  }

  private var tableHeight: CGFloat {
    policyDetailsAreExpanded || shouldShowObservationNotice ? 120 : 180
  }

  private var topLevelItemsSuppressedMessage: String {
    let count = presentation.report.topLevelItemCount
    return language.format(
      count == 1
        ? "%lld top-level item was observed. Its details exceeded the configured reporting limit, so no partial subset is shown."
        : "%lld top-level items were observed. Their details exceeded the configured reporting limit, so no partial subset is shown.",
      Int64(clamping: count)
    )
  }

  private var shownItemCount: String {
    let count = presentation.items.count
    return language.format(
      count == 1 ? "%lld item shown" : "%lld items shown",
      Int64(clamping: count)
    )
  }

  private func cleanupSelectionBinding(
    for selection: CleanupCandidateSelection
  ) -> Binding<Bool> {
    Binding(
      get: { selectedCleanupCandidates.contains(selection) },
      set: { setCleanupCandidate(selection, $0) }
    )
  }
}

private struct CleanupDraftSelectionBar: View {
  @Environment(\.appLanguage) private var language

  let candidateCount: Int
  let selectedCount: Int
  let phase: CleanupReviewPhase
  let clearSelection: () -> Void
  let prepareReview: () -> Void
  let cancelPreparation: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Label(statusTitle, systemImage: statusImage)
        .font(.callout.weight(.medium))

      Text(statusDetail)
        .font(.caption)
        .foregroundStyle(.secondary)

      Spacer()

      if phase.isPreparing {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel(language.localized("Preparing the in-memory draft"))
        Button(language.localized("Cancel"), role: .cancel, action: cancelPreparation)
      } else {
        if selectedCount > 0 {
          Button(language.localized("Clear"), action: clearSelection)
        }
        Button(language.localized("Review Draft…"), action: prepareReview)
          .buttonStyle(.borderedProminent)
          .disabled(selectedCount == 0)
          .accessibilityHint(
            language.localized(
              "Creates an unapproved, read-only draft without changing files"
            )
          )
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
    }
    .accessibilityElement(children: .contain)
  }

  private var statusTitle: String {
    if phase.isPreparing {
      return language.localized("Preparing draft")
    }
    if case .failed(let failure) = phase {
      return language.localized(failure.title)
    }
    if candidateCount == 0 {
      return language.localized("No eligible draft candidates")
    }
    return language.format(
      "%lld of %lld included",
      Int64(clamping: selectedCount),
      Int64(clamping: candidateCount)
    )
  }

  private var statusDetail: String {
    if case .failed(let failure) = phase {
      return language.localized(failure.message)
    }
    if phase.isPreparing {
      return language.localized("Core is validating a frozen selection snapshot.")
    }
    if candidateCount == 0 {
      return language.localized("Nothing currently meets every planning requirement.")
    }
    return language.localized("Selection is not approval. No files will be changed.")
  }

  private var statusImage: String {
    if phase.isPreparing {
      return "hourglass"
    }
    if case .failed = phase {
      return "exclamationmark.triangle"
    }
    return candidateCount == 0 ? "lock.shield" : "checklist"
  }
}

private struct PolicySelectionPrompt: View {
  @Environment(\.appLanguage) private var language

  var body: some View {
    Label(
      language.localized("Select an observed item to inspect its policy explanation."),
      systemImage: "list.bullet.rectangle"
    )
    .font(.callout)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityHint(
      language.localized("The Policy column remains visible for every item")
    )
  }
}

private struct PolicyBadge: View {
  @Environment(\.appLanguage) private var language

  let policy: PolicyDecisionPresentation

  var body: some View {
    Label(language.localized(policy.badgeTitle), systemImage: policy.systemImage)
      .font(.caption.weight(.medium))
      .lineLimit(1)
      .foregroundStyle(foregroundColor)
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(foregroundColor.opacity(0.1), in: Capsule())
      .accessibilityLabel(localizedAccessibilityLabel)
  }

  private var localizedAccessibilityLabel: String {
    language.format(
      "Policy disposition: %@. Match state: %@. %@",
      language.localized(policy.badgeTitle),
      language.localized(policy.matchStateDisplayName),
      language.localized(policy.explanation)
    )
  }

  private var foregroundColor: Color {
    switch policy.disposition {
    case .reclaimable:
      .green
    case .reviewRequired:
      .orange
    case .protected:
      .blue
    }
  }
}

private struct PolicyExplanationDisclosure: View {
  @Environment(\.appLanguage) private var language

  let row: ScanItemRow
  @Binding var isExpanded: Bool

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(language.localized(row.policy.displayName))
            .font(.callout.weight(.semibold))
          Text(verbatim: row.policy.responsibleTool)
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
        }

        if !row.policy.ruleRevisionLabels.isEmpty {
          Text(verbatim: row.policy.ruleRevisionLabels.joined(separator: " · "))
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }

        Text(
          language.format(
            "Match state: %@",
            language.localized(row.policy.matchStateDisplayName)
          )
        )
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)

        Text(language.localized(row.policy.explanation))
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        if row.policy.findings.isEmpty {
          Label(
            language.localized("No structured rule evidence is available for this item."),
            systemImage: "questionmark.circle"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        } else {
          LazyVStack(alignment: .leading, spacing: 7) {
            ForEach(Array(row.policy.findings.enumerated()), id: \.offset) { _, finding in
              PolicyFindingRow(finding: finding)
            }
          }
          .accessibilityLabel(language.localized("Structured policy evidence"))
        }

        Label(
          language.localized(
            "Advisory only — this release cannot clean, approve, quarantine, or delete files."
          ),
          systemImage: "lock.shield"
        )
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
      }
      .padding(.top, 8)
    } label: {
      HStack(spacing: 8) {
        Text(language.localized("Policy explanation"))
          .font(.callout.weight(.medium))
        Text(verbatim: row.displayPath)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
        PolicyBadge(policy: row.policy)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
    }
    .accessibilityValue(language.localized(isExpanded ? "Expanded" : "Collapsed"))
    .accessibilityHint(
      language.localized(PolicyDisclosureAccessibility.hint(isExpanded: isExpanded))
    )
  }
}

enum PolicyDisclosureAccessibility {
  static func hint(isExpanded: Bool) -> String {
    isExpanded
      ? "Collapses the rule identifier, explanation, and structured evidence"
      : "Expands the rule identifier, explanation, and structured evidence"
  }
}

private struct PolicyFindingRow: View {
  @Environment(\.appLanguage) private var language

  let finding: RuleFinding

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: finding.state.systemImage)
        .foregroundStyle(stateColor)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(language.localized(finding.kind.displayName))
            .font(.caption.weight(.medium))
          Text(verbatim: finding.identifier.rawValue)
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
          Spacer()
          Text(localizedState)
            .font(.caption2.weight(.medium))
            .foregroundStyle(stateColor)
        }
        Text(language.localized(finding.explanation))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var stateColor: Color {
    switch finding.state {
    case .satisfied:
      .green
    case .failed:
      .red
    case .unknown:
      .orange
    }
  }

  private var localizedState: String {
    switch finding.state {
    case .satisfied, .failed:
      return language.localized(finding.state.displayName)
    case .unknown(let reason):
      return language.format(
        "Unknown · %@",
        language.localized(reason.displayName)
      )
    }
  }
}

private struct SummaryBand: View {
  @Environment(\.appLanguage) private var language

  let presentation: ScanPresentation

  var body: some View {
    VStack(spacing: 14) {
      HStack(spacing: 0) {
        MetricView(
          title: language.localized("Observed apparent allocation"),
          value: sizeValue(presentation.report.root.recursiveSize.allocatedBytes),
          detail: apparentSizeDetail
        )
        Divider().padding(.vertical, 2)
        MetricView(
          title: language.localized("Hard-link-adjusted allocation"),
          value: sizeValue(presentation.report.root.hardLinkExclusiveAllocatedBytes),
          detail: hardLinkDetail
        )
        Divider().padding(.vertical, 2)
        MetricView(
          title: language.localized("Observed logical size"),
          value: sizeValue(presentation.report.root.recursiveSize.logicalBytes),
          detail: logicalSizeDetail
        )
        Divider().padding(.vertical, 2)
        MetricView(
          title: language.localized("Observed entries"),
          value: entryValue,
          detail: presentation.metricsAreAvailable
            ? language.localized("Includes selected folder")
            : language.localized("Entry limit reached")
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
      return language.localized("Entry limit reached")
    }
    if presentation.report.root.sizeOverflowed {
      return language.localized("Exact total unavailable")
    }
    if !presentation.report.root.isComplete
      || presentation.report.root.unknownAllocatedItemCount > 0
    {
      return language.localized("Partial metadata")
    }
    return language.localized("Observed metadata")
  }

  private var logicalSizeDetail: String {
    if !presentation.metricsAreAvailable {
      return language.localized("Entry limit reached")
    }
    if presentation.report.root.sizeOverflowed {
      return language.localized("Exact total unavailable")
    }
    return language.localized(
      presentation.report.root.isComplete ? "Observed metadata" : "Partial metadata"
    )
  }

  private var hardLinkDetail: String {
    if !presentation.metricsAreAvailable {
      return language.localized("Entry limit reached")
    }
    if presentation.report.root.sizeOverflowed {
      return language.localized("Exact total unavailable")
    }
    let isPartial =
      !presentation.report.hardLinkAccountingIsComplete
      || !presentation.report.root.isComplete
      || presentation.report.root.unknownAllocatedItemCount > 0
    return language.localized(
      isPartial ? "Partial accounting" : "Regular-file links adjusted"
    )
  }

  private var entryValue: String {
    presentation.metricsAreAvailable
      ? language.format("%lld", Int64(clamping: presentation.report.root.counts.total))
      : language.localized("Unavailable")
  }

  private func sizeValue(_ bytes: UInt64) -> String {
    guard presentation.metricsAreAvailable else {
      return language.localized("Unavailable")
    }
    guard !presentation.report.root.sizeOverflowed else {
      return language.localized("Overflow")
    }
    return localizedByteCount(bytes)
  }

  private func localizedByteCount(_ bytes: UInt64) -> String {
    let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]
    guard bytes >= 1_024 else {
      return language.format("%llu B", bytes)
    }

    var value = Double(bytes)
    var unitIndex = 0
    while value >= 1_024, unitIndex < units.count - 1 {
      value /= 1_024
      unitIndex += 1
    }
    return language.format("%.1f %@", value, units[unitIndex])
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
  @Environment(\.appLanguage) private var language

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
      Text(language.localized("Top-level apparent allocation distribution"))
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
      language.localized(
        "Distribution of apparent allocation across the largest observed top-level items"
      )
    )
  }

  private func segmentWidth(_ bytes: UInt64, available: CGFloat) -> CGFloat {
    let total = max(presentation.report.root.recursiveSize.allocatedBytes, 1)
    let ratio = min(Double(bytes) / Double(total), 1)
    return max(CGFloat(ratio) * available, 2)
  }
}

private struct SizeCell: View {
  @Environment(\.appLanguage) private var language

  let bytes: UInt64
  let isAvailable: Bool
  let isPartial: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(isAvailable ? localizedByteCount : language.localized("Unavailable"))
        .monospacedDigit()
      if isPartial {
        Text(language.localized("Partial"))
          .font(.caption2)
          .foregroundStyle(.orange)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var localizedByteCount: String {
    let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]
    guard bytes >= 1_024 else {
      return language.format("%llu B", bytes)
    }

    var value = Double(bytes)
    var unitIndex = 0
    while value >= 1_024, unitIndex < units.count - 1 {
      value /= 1_024
      unitIndex += 1
    }
    return language.format("%.1f %@", value, units[unitIndex])
  }
}

private struct ObservationNotice: View {
  @Environment(\.appLanguage) private var language

  let presentation: ScanPresentation

  @State private var isExpanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      ForEach(localizedPartialDetailMessages, id: \.self) { message in
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
              Text(verbatim: SafeDisplayText.path(issue.path))
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
              Text(language.localized(issue.reason.displayName))
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
    .accessibilityValue(language.localized(isExpanded ? "Expanded" : "Collapsed"))
    .accessibilityHint(
      language.localized(ObservationDisclosureAccessibility.hint(isExpanded: isExpanded))
    )
  }

  private var noticeTitle: String {
    let retained = presentation.report.issues.count
    let suppressed = presentation.report.suppressedIssueCount
    var parts = [
      language.localized("Partial scan — some entries or accounting details were not observed."),
      language.format(
        retained == 1 ? "%lld scan issue shown" : "%lld scan issues shown",
        Int64(clamping: retained)
      ),
    ]
    if suppressed > 0 {
      parts.append(
        language.format(
          suppressed == 1
            ? "%lld additional issue not retained"
            : "%lld additional issues not retained",
          Int64(clamping: suppressed)
        )
      )
    }
    return parts.joined(separator: " · ")
  }

  private var localizedPartialDetailMessages: [String] {
    let report = presentation.report
    var messages: [String] = []
    if report.traversalDetailsWereDiscarded {
      messages.append(
        language.localized(
          "Earlier descendant totals and scan issues were discarded; their total is unknown."
        )
      )
    }
    if report.topLevelItemsWereSuppressed && !report.traversalDetailsWereDiscarded {
      messages.append(
        language.localized("Top-level details exceeded the configured reporting limit.")
      )
    }
    if !report.hardLinkAccountingIsComplete {
      messages.append(language.localized("Hard-link-adjusted allocation is partial."))
    }
    if report.root.unknownAllocatedItemCount > 0 {
      let count = report.root.unknownAllocatedItemCount
      messages.append(
        language.format(
          count == 1
            ? "%lld entry has unknown allocation."
            : "%lld entries have unknown allocation.",
          Int64(clamping: count)
        )
      )
    }
    if report.root.sizeOverflowed {
      messages.append(
        language.localized("One or more root size totals overflowed; exact values are unavailable.")
      )
    }
    if report.suppressedIssueCount > 0 {
      let count = report.suppressedIssueCount
      messages.append(
        language.format(
          count == 1
            ? "%lld additional scan issue was not retained."
            : "%lld additional scan issues were not retained.",
          Int64(clamping: count)
        )
      )
    }
    return messages
  }

  private func issueDetail(_ issue: ScanIssue) -> String {
    var parts = [
      language.localized(issue.operation.displayName),
      language.localized(issue.impact.displayName),
    ]
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

enum ObservationDisclosureAccessibility {
  static func hint(isExpanded: Bool) -> String {
    isExpanded
      ? "Collapses partial scan details and retained issues"
      : "Expands partial scan details and retained issues"
  }
}

private struct AccountingFootnote: View {
  @Environment(\.appLanguage) private var language

  let presentation: ScanPresentation

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(
        language.localized(
          "Observed allocation is not guaranteed reclaimable. Hard links, clones, snapshots, compression, unreadable paths, and concurrent changes can affect actual free space."
        )
      )
      if !accountingDetails.isEmpty {
        Text(accountingDetails.joined(separator: " · "))
      }
      Text(
        language.localized(
          "The selected folder inode is included, so top-level rows may not sum to the root total."
        )
      )
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
      details.append(
        language.format(
          count == 1
            ? "%lld entry with unknown allocation is excluded"
            : "%lld entries with unknown allocation are excluded",
          Int64(clamping: count)
        )
      )
    }
    if root.possibleSharedContentFileCount > 0 {
      let count = root.possibleSharedContentFileCount
      details.append(
        language.format(
          count == 1 ? "%lld file may share APFS content" : "%lld files may share APFS content",
          Int64(clamping: count)
        )
      )
    }
    if root.sharedContentMetadataUnavailableCount > 0 {
      let count = root.sharedContentMetadataUnavailableCount
      details.append(
        language.format(
          count == 1
            ? "shared-content metadata unavailable for %lld file"
            : "shared-content metadata unavailable for %lld files",
          Int64(clamping: count)
        )
      )
    }
    if !presentation.report.hardLinkAccountingIsComplete {
      details.append(language.localized("hard-link-adjusted allocation is partial"))
    }
    if root.unobservedHardLinkFileCount > 0 {
      let count = root.unobservedHardLinkFileCount
      details.append(
        language.format(
          count == 1
            ? "%lld hard-link group has links outside the observed scope"
            : "%lld hard-link groups have links outside the observed scope",
          Int64(clamping: count)
        )
      )
    }
    if root.nonExclusiveHardLinkFileCount > 0 {
      let count = root.nonExclusiveHardLinkFileCount
      details.append(
        language.format(
          count == 1
            ? "%lld hard-link path receives no exclusive allocation credit"
            : "%lld hard-link paths receive no exclusive allocation credit",
          Int64(clamping: count)
        )
      )
    }
    return details
  }
}
