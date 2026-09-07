import SwiftUI

@MainActor
struct QuarantineRecoveryView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var viewModel: QuarantineRecoveryViewModel

  init(
    viewModel: QuarantineRecoveryViewModel = QuarantineRecoveryViewModel()
  ) {
    _viewModel = State(initialValue: viewModel)
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          sameVolumeNotice
          restoreStatus
          purgeStatus
          inventoryContent
          safetyFooter
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .center)
      }
    }
    .frame(minWidth: 680, minHeight: 560)
    .background(Color(nsColor: .windowBackgroundColor))
    .onDisappear(perform: viewModel.stopForDismissal)
  }

  private var header: some View {
    HStack(spacing: 12) {
      Label(
        "npm Recovery & Cleanup",
        systemImage: "externaldrive.badge.minus"
      )
      .font(.title2.weight(.semibold))

      Spacer()

      if case .loaded = viewModel.inventoryState {
        Button(action: { viewModel.loadInventory() }) {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(viewModel.isWorking)
        .accessibilityHint(
          viewModel.refreshDiscardsPendingConfirmation
            ? "Cancels the pending confirmation, then reconciles and loads a new bounded inventory"
            : "Reconciles the journal and loads a new bounded inventory"
        )
      }

      Button("Done") {
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
      .disabled(viewModel.isWorking)
    }
    .padding(.horizontal, 24)
    .frame(height: 58)
  }

  private var sameVolumeNotice: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "externaldrive.badge.exclamationmark")
        .font(.title2)
        .foregroundStyle(.orange)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text("Quarantine is not permanent deletion")
          .font(.headline)
        Text(
          "Quarantine is a same-volume move and frees 0 B. Restore and receipt-bound permanent deletion are separate. Capacity change may be zero; DevSift provides neither secure erase nor guaranteed reclaimed space."
        )
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
  }

  @ViewBuilder
  private var purgeStatus: some View {
    switch viewModel.purgeState {
    case .idle:
      EmptyView()

    case .preparing(let target):
      recoveryProgress(
        title: purgeProgressTitle(
          target,
          initial: "Preparing permanent deletion",
          retry: "Preparing deletion retry"
        ),
        message:
          "Core is freshly validating the exact receipt-bound journal evidence, trusted descriptors, current account, and same-volume capacity observation."
      )

    case .awaitingConfirmation(let confirmation):
      QuarantinePurgeConfirmationView(
        confirmation: confirmation,
        confirm: {
          exactStatementWasConfirmed,
          restoreCutoffWasAccepted,
          activityRisksWereAccepted,
          capacityLimitsWereAccepted in
          viewModel.confirmAndPurge(
            confirmationID: confirmation.id,
            exactPermanentDeletionStatementWasConfirmed: exactStatementWasConfirmed,
            restoreCutoffAndPartialDeletionWereAccepted: restoreCutoffWasAccepted,
            workWasStoppedAndActivityRisksWereAccepted: activityRisksWereAccepted,
            capacityAndSecureEraseLimitsWereAccepted: capacityLimitsWereAccepted
          )
        },
        cancel: { viewModel.cancelPurgeConfirmation(confirmation.id) }
      )
      .id(confirmation.id)

    case .cancellingConfirmation:
      recoveryProgress(
        title: "Cancelling permanent deletion confirmation",
        message: "Discarding the prepared one-time authority before another action is enabled."
      )

    case .purging(let target):
      recoveryProgress(
        title: purgeProgressTitle(
          target,
          initial: "Permanently deleting quarantined contents",
          retry: "Continuing permanent deletion"
        ),
        message:
          "Core is executing one bounded, receipt-bound pass. If it stops after staging, the refreshed inventory will require a new explicit retry."
      )

    case .finished(let result):
      QuarantinePurgeResultBanner(
        result: result,
        dismiss: viewModel.dismissPurgeStatus
      )

    case .failed(let issue):
      QuarantineRecoveryIssueBanner(
        issue: issue,
        actionTitle: "Dismiss",
        dismiss: viewModel.dismissPurgeStatus
      )
    }
  }

  @ViewBuilder
  private var restoreStatus: some View {
    switch viewModel.restoreState {
    case .idle:
      EmptyView()

    case .preparing:
      recoveryProgress(
        title: "Preparing restore",
        message:
          "Core is freshly validating the journal, source name, quarantined contents, and trusted parent bindings."
      )

    case .awaitingConfirmation(let confirmation):
      QuarantineRecoveryConfirmationView(
        confirmation: confirmation,
        confirm: { exactStatementWasConfirmed, npmWasStopped, changesWereAccepted in
          viewModel.confirmAndRestore(
            confirmationID: confirmation.id,
            exactStatementWasConfirmed: exactStatementWasConfirmed,
            npmWasStopped: npmWasStopped,
            postQuarantineChangesWereAccepted: changesWereAccepted
          )
        },
        cancel: { viewModel.cancelRestoreConfirmation(confirmation.id) }
      )
      .id(confirmation.id)

    case .cancellingConfirmation:
      recoveryProgress(
        title: "Cancelling restore confirmation",
        message: "Discarding the prepared one-time authority before another action is enabled."
      )

    case .restoring:
      recoveryProgress(
        title: "Restoring current contents",
        message:
          "Core is performing a protected no-overwrite rename and recording the bounded result."
      )

    case .finished(let result):
      QuarantineRecoveryResultBanner(
        result: result,
        dismiss: viewModel.dismissRestoreStatus
      )

    case .failed(let issue):
      QuarantineRecoveryIssueBanner(
        issue: issue,
        actionTitle: "Dismiss",
        dismiss: viewModel.dismissRestoreStatus
      )
    }
  }

  @ViewBuilder
  private var inventoryContent: some View {
    switch viewModel.inventoryState {
    case .notLoaded:
      VStack(alignment: .leading, spacing: 10) {
        Text("Load the recovery and cleanup inventory")
          .font(.headline)
        Text(
          "Loading is explicit: DevSift will acquire the journal lock, reconcile incomplete receipts, and inspect only its fixed current-account npm quarantine. Nothing is deleted while loading."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        Button("Load and Reconcile") {
          viewModel.loadInventory()
        }
        .buttonStyle(.borderedProminent)
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        Color(nsColor: .controlBackgroundColor),
        in: RoundedRectangle(cornerRadius: 10)
      )

    case .loading:
      recoveryProgress(
        title: "Loading recovery and cleanup inventory",
        message: "Reconciling durable journal state before any restore or deletion option is shown."
      )

    case .failed(let failure):
      QuarantineRecoveryIssueBanner(issue: failure, actionTitle: "Try Again") {
        viewModel.loadInventory()
      }

    case .loaded(let inventory):
      if inventory.isEmpty {
        VStack(alignment: .leading, spacing: 5) {
          Label("No quarantined npm cache", systemImage: "checkmark.circle")
            .font(.headline)
          Text(
            "The reconciled journal contains no current item that can be restored, permanently deleted, or retried."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          Color(nsColor: .controlBackgroundColor),
          in: RoundedRectangle(cornerRadius: 10)
        )
      } else {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Text("Reconciled inventory")
              .font(.headline)
            Spacer()
            Text(
              "\((inventory.rows.count + inventory.purgeRetryRows.count).formatted()) \((inventory.rows.count + inventory.purgeRetryRows.count) == 1 ? "item" : "items")"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }

          ForEach(inventory.rows) { row in
            QuarantineRecoveryInventoryRowView(
              row: row,
              restoreSelectionIsEnabled: viewModel.canStartRestore,
              purgeSelectionIsEnabled: viewModel.canStartInitialPurge,
              restore: { viewModel.requestRestore(for: row.id) },
              purge: { viewModel.requestInitialPurge(for: row.id) }
            )
          }

          if !inventory.purgeRetryRows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              Label(
                "Incomplete permanent deletions",
                systemImage: "exclamationmark.arrow.triangle.2.circlepath"
              )
              .font(.callout.weight(.semibold))
              .foregroundStyle(.orange)

              Text(
                "These exact staged remainders cannot be restored. Each continuation requires a new, separate confirmation."
              )
              .font(.caption)
              .foregroundStyle(.secondary)

              ForEach(inventory.purgeRetryRows) { row in
                QuarantinePurgeRetryInventoryRowView(
                  row: row,
                  retrySelectionIsEnabled: viewModel.canStartPurgeRetry,
                  retry: { viewModel.requestPurgeRetry(for: row.id) }
                )
              }
            }
            .padding(.top, 6)
          }
        }
      }
    }
  }

  private var safetyFooter: some View {
    VStack(alignment: .leading, spacing: 5) {
      Label(
        "Receipt-bound operations only · no arbitrary paths · no overwrite",
        systemImage: "lock.shield"
      )
      Text(
        "No filesystem paths, journal transaction IDs, or raw journal bytes are displayed. Permanent deletion never targets the active npm cache and does not claim secure erasure, attribution, or guaranteed reclaimed capacity."
      )
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }

  private func purgeProgressTitle(
    _ target: QuarantineRecoveryPurgeTarget,
    initial: String,
    retry: String
  ) -> String {
    switch target {
    case .initial:
      initial
    case .explicitRetry:
      retry
    }
  }

  private func recoveryProgress(
    title: String,
    message: String
  ) -> some View {
    HStack(alignment: .top, spacing: 12) {
      ProgressView()
        .controlSize(.small)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.callout.weight(.semibold))
        Text(message)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
  }
}

private struct QuarantineRecoveryInventoryRowView: View {
  let row: QuarantineRecoveryInventoryRowPresentation
  let restoreSelectionIsEnabled: Bool
  let purgeSelectionIsEnabled: Bool
  let restore: () -> Void
  let purge: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(row.originalName)
            .font(.headline.monospaced())
          Text(row.responsibleTool)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        HStack(spacing: 8) {
          Button("Restore…", action: restore)
            .buttonStyle(.borderedProminent)
            .disabled(!row.canRestore || !restoreSelectionIsEnabled)
            .accessibilityIdentifier("quarantineRestoreButton")
            .accessibilityHint(row.restoreAvailabilityMessage)

          Button("Permanently Delete…", role: .destructive, action: purge)
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(!row.canPurge || !purgeSelectionIsEnabled)
            .accessibilityIdentifier("quarantineInitialPurgeButton")
            .accessibilityHint(row.purgeAvailabilityMessage)
        }
      }

      Divider()

      recoveryStateLabel(row.source)
      recoveryStateLabel(row.quarantinedItem)

      if row.receiptWasProducedByRecovery {
        Label(
          "The terminal quarantine receipt was completed by journal recovery.",
          systemImage: "clock.arrow.circlepath"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Text(row.restoreAvailabilityMessage)
        .font(.caption)
        .foregroundStyle(row.canRestore ? Color.secondary : Color.orange)
        .fixedSize(horizontal: false, vertical: true)

      Text(row.purgeAvailabilityMessage)
        .font(.caption)
        .foregroundStyle(row.canPurge ? Color.secondary : Color.orange)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
    }
  }

  private func recoveryStateLabel(
    _ state: QuarantineRecoverySourcePresentation
  ) -> some View {
    Label(state.title, systemImage: state.tone.systemImage)
      .font(.caption)
      .foregroundStyle(state.tone.color)
  }

  private func recoveryStateLabel(
    _ state: QuarantineRecoveryItemStatePresentation
  ) -> some View {
    Label(state.title, systemImage: state.tone.systemImage)
      .font(.caption)
      .foregroundStyle(state.tone.color)
  }
}

private struct QuarantinePurgeRetryInventoryRowView: View {
  let row: QuarantineRecoveryPurgeRetryRowPresentation
  let retrySelectionIsEnabled: Bool
  let retry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(row.originalName)
            .font(.headline.monospaced())
          Text(row.responsibleTool)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        Button("Continue Deletion…", role: .destructive, action: retry)
          .buttonStyle(.borderedProminent)
          .tint(.red)
          .disabled(!row.canRetry || !retrySelectionIsEnabled)
          .accessibilityIdentifier("quarantinePurgeRetryButton")
          .accessibilityHint(row.retryAvailabilityMessage)
      }

      Label("Exact staged deletion remainder", systemImage: "shippingbox.and.arrow.backward")
        .font(.caption)
        .foregroundStyle(.orange)

      Text(row.retryAvailabilityMessage)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color.orange.opacity(0.35), lineWidth: 0.5)
    }
  }
}

private struct QuarantineRecoveryConfirmationView: View {
  let confirmation: QuarantineRecoveryConfirmationPresentation
  let confirm: (Bool, Bool, Bool) -> Void
  let cancel: () -> Void

  @State private var exactStatementWasConfirmed = false
  @State private var npmWasStopped = false
  @State private var postQuarantineChangesWereAccepted = false

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 6) {
        Text(
          "Core prepared one attempt to restore the current quarantined \(confirmation.originalName) for \(confirmation.responsibleTool). It will fail rather than overwrite the original name."
        )
        .font(.callout)
        .foregroundStyle(.secondary)

        VStack(alignment: .leading, spacing: 4) {
          Text("Exact Core-required statement")
            .font(.caption.weight(.semibold))
          Text(verbatim: confirmation.requiredStatementIdentifier)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))

        Toggle(
          "I confirm the exact Core-required statement shown above.",
          isOn: $exactStatementWasConfirmed
        )
        .toggleStyle(.checkbox)

        Toggle(isOn: $npmWasStopped) {
          Text(
            "I stopped npm work using this cache. I understand DevSift did not observe inactivity."
          )
        }
        .toggleStyle(.checkbox)

        Toggle(isOn: $postQuarantineChangesWereAccepted) {
          Text(
            "I accept that these are the current quarantined contents and may include changes made after quarantine."
          )
        }
        .toggleStyle(.checkbox)

        HStack {
          Spacer()
          Button("Cancel", action: cancel)
          Button("Restore Current Contents") {
            confirm(
              exactStatementWasConfirmed,
              npmWasStopped,
              postQuarantineChangesWereAccepted
            )
          }
          .buttonStyle(.borderedProminent)
          .disabled(
            !exactStatementWasConfirmed || !npmWasStopped
              || !postQuarantineChangesWereAccepted
          )
        }
      }
      .padding(.top, 4)
    } label: {
      Label("Confirm no-overwrite restore", systemImage: "checkmark.shield")
        .font(.headline)
    }
  }
}

private struct QuarantinePurgeConfirmationView: View {
  let confirmation: QuarantineRecoveryPurgeConfirmationPresentation
  let confirm: (Bool, Bool, Bool, Bool) -> Void
  let cancel: () -> Void

  @State private var exactStatementWasConfirmed = false
  @State private var restoreCutoffAndPartialDeletionWereAccepted = false
  @State private var workAndActivityRisksWereAccepted = false
  @State private var capacityAndSecureEraseLimitsWereAccepted = false

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 12) {
        Text(introduction)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Label {
          Text(confirmation.dataRemanenceDisclosure)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.red)
        .accessibilityIdentifier("quarantinePurgeDataRemanenceDisclosure")

        VStack(alignment: .leading, spacing: 5) {
          Text("Exact Core-required statement")
            .font(.caption.weight(.semibold))
          Text(verbatim: confirmation.requiredStatementIdentifier)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
          RoundedRectangle(cornerRadius: 7)
            .stroke(Color.red.opacity(0.3), lineWidth: 0.5)
        }

        Toggle(
          "I confirm the exact statement above and understand this is permanent deletion, not secure erase.",
          isOn: $exactStatementWasConfirmed
        )
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("quarantinePurgeExactStatementAcknowledgement")

        Toggle(
          "I accept that restore becomes unavailable after staging and that deletion may be partial.",
          isOn: $restoreCutoffAndPartialDeletionWereAccepted
        )
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("quarantinePurgeRestoreCutoffAcknowledgement")

        Toggle(
          "I stopped npm and other work using this cache. I accept unobserved activity, post-quarantine changes, and same-account races.",
          isOn: $workAndActivityRisksWereAccepted
        )
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("quarantinePurgeActivityRiskAcknowledgement")

        Toggle(
          "I accept that the capacity reading is only observational, may show zero change or be unavailable, and cannot be attributed to DevSift.",
          isOn: $capacityAndSecureEraseLimitsWereAccepted
        )
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("quarantinePurgeCapacityAcknowledgement")

        HStack {
          Spacer()
          Button("Cancel", action: cancel)
          Button(confirmButtonTitle, role: .destructive) {
            confirm(
              exactStatementWasConfirmed,
              restoreCutoffAndPartialDeletionWereAccepted,
              workAndActivityRisksWereAccepted,
              capacityAndSecureEraseLimitsWereAccepted
            )
          }
          .buttonStyle(.borderedProminent)
          .tint(.red)
          .disabled(!allRisksWereAcknowledged)
          .accessibilityIdentifier("quarantinePurgeConfirmButton")
          .accessibilityHint(
            "Runs one receipt-bound permanent deletion pass after all four acknowledgements are selected"
          )
        }
      }
      .padding(.top, 4)
    } label: {
      Label(confirmationTitle, systemImage: "trash.fill")
        .font(.headline)
        .foregroundStyle(.red)
    }
    .accessibilityIdentifier("quarantinePurgeConfirmation")
  }

  private var introduction: String {
    if confirmation.isExplicitRetry {
      return
        "Core prepared one attempt to continue deleting the exact staged remainder of \(confirmation.originalName) for \(confirmation.responsibleTool). Restore is already unavailable for this remainder."
    }
    return
      "Core prepared one attempt to permanently delete the exact current quarantined \(confirmation.originalName) for \(confirmation.responsibleTool). It never targets the active cache name."
  }

  private var confirmationTitle: String {
    confirmation.isExplicitRetry
      ? "Confirm permanent deletion retry"
      : "Confirm permanent deletion"
  }

  private var confirmButtonTitle: String {
    confirmation.isExplicitRetry
      ? "Continue Permanent Deletion"
      : "Permanently Delete"
  }

  private var allRisksWereAcknowledged: Bool {
    exactStatementWasConfirmed
      && restoreCutoffAndPartialDeletionWereAccepted
      && workAndActivityRisksWereAccepted
      && capacityAndSecureEraseLimitsWereAccepted
  }
}

private struct QuarantineRecoveryResultBanner: View {
  let result: QuarantineRecoveryResultPresentation
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top) {
        Label(result.title, systemImage: result.tone.systemImage)
          .font(.headline)
          .foregroundStyle(result.tone.color)
        Spacer()
        Button("Dismiss", action: dismiss)
          .controlSize(.small)
      }
      Text(result.message)
      Text(result.durabilityMessage)
        .foregroundStyle(.secondary)
      if let cancellationMessage = result.cancellationMessage {
        Text(cancellationMessage)
          .foregroundStyle(.secondary)
      }
      Text("Restore result · no overwrite · no deletion authority used")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }
    .font(.callout)
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(result.tone.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
  }
}

private struct QuarantinePurgeResultBanner: View {
  let result: QuarantineRecoveryPurgeResultPresentation
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top) {
        Label(result.title, systemImage: result.tone.systemImage)
          .font(.headline)
          .foregroundStyle(result.tone.color)
        Spacer()
        Button("Dismiss", action: dismiss)
          .controlSize(.small)
      }

      Text(result.message)
      Text(result.durabilityMessage)
        .foregroundStyle(.secondary)
      Text(result.observedUnlinkMessage)
        .foregroundStyle(.secondary)
      Text(result.capacityMessage)
        .foregroundStyle(.secondary)

      if let cancellationMessage = result.cancellationMessage {
        Text(cancellationMessage)
          .foregroundStyle(.orange)
      }

      Label(resultSummary, systemImage: resultSummaryImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(result.requiresExplicitRetry ? Color.orange : result.tone.color)

      Text(result.limitationsMessage)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .font(.callout)
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(result.tone.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityIdentifier("quarantinePurgeResult")
  }

  private var resultSummary: String {
    if result.requiresExplicitRetry {
      return "A separate confirmation is required to continue deletion."
    }
    if result.performedPermanentDeletion {
      return "Permanent deletion activity was observed during this pass."
    }
    return "No permanent deletion activity was observed during this pass."
  }

  private var resultSummaryImage: String {
    if result.requiresExplicitRetry {
      return "exclamationmark.arrow.triangle.2.circlepath"
    }
    return result.performedPermanentDeletion ? "trash.fill" : "nosign"
  }
}

private struct QuarantineRecoveryIssueBanner: View {
  let issue: QuarantineRecoveryIssuePresentation
  let actionTitle: String
  let dismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: issue.tone.systemImage)
        .foregroundStyle(issue.tone.color)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(issue.title)
          .font(.callout.weight(.semibold))
        Text(issue.message)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      Button(actionTitle, action: dismiss)
        .controlSize(.small)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(issue.tone.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
  }
}

extension QuarantineRecoveryPresentationTone {
  fileprivate var systemImage: String {
    switch self {
    case .neutral:
      "info.circle"
    case .success:
      "checkmark.circle.fill"
    case .warning:
      "exclamationmark.triangle.fill"
    case .failure:
      "xmark.circle.fill"
    }
  }

  fileprivate var color: Color {
    switch self {
    case .neutral:
      .secondary
    case .success:
      .green
    case .warning:
      .orange
    case .failure:
      .red
    }
  }
}
