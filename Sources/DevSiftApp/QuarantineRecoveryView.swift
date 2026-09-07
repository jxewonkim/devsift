import SwiftUI

@MainActor
struct QuarantineRecoveryView: View {
  @Environment(\.appLanguage) private var language
  @Environment(\.dismiss) private var dismiss
  @State private var viewModel: QuarantineRecoveryViewModel
  @Binding private var languageSelection: AppLanguageSelection

  init(
    viewModel: QuarantineRecoveryViewModel = QuarantineRecoveryViewModel(),
    languageSelection: Binding<AppLanguageSelection> = .constant(.english)
  ) {
    _viewModel = State(initialValue: viewModel)
    _languageSelection = languageSelection
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
        language.localized("npm Recovery & Cleanup"),
        systemImage: "externaldrive.badge.minus"
      )
      .font(.title2.weight(.semibold))

      Spacer()

      Menu {
        Picker(language.localized("Language"), selection: $languageSelection) {
          ForEach(AppLanguageSelection.allCases) { selection in
            Text(language.localized(languageOptionTitle(selection)))
              .tag(selection)
          }
        }
      } label: {
        Label(languageMenuValue, systemImage: "globe")
      }
      .accessibilityIdentifier("recovery-language-menu")
      .accessibilityLabel(language.localized("Language"))
      .accessibilityValue(language.localized(languageOptionTitle(languageSelection)))
      .accessibilityHint(language.localized("Choose the language used by DevSift"))
      .help(language.localized("Choose the language used by DevSift"))

      if case .loaded = viewModel.inventoryState {
        Button(action: { viewModel.loadInventory() }) {
          Label(language.localized("Refresh"), systemImage: "arrow.clockwise")
        }
        .disabled(viewModel.isWorking)
        .accessibilityHint(
          viewModel.refreshDiscardsPendingConfirmation
            ? language.localized(
              "Cancels the pending confirmation, then reconciles and loads a new bounded inventory"
            )
            : language.localized("Reconciles the journal and loads a new bounded inventory")
        )
      }

      Button(language.localized("Done")) {
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
        Text(language.localized("Quarantine is not permanent deletion"))
          .font(.headline)
        Text(
          language.localized(
            "Quarantine is a same-volume move and frees 0 B. Restore and receipt-bound permanent deletion are separate. Capacity change may be zero; DevSift provides neither secure erase nor guaranteed reclaimed space."
          )
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

  private var languageMenuValue: String {
    switch languageSelection {
    case .system:
      language.localized("Auto")
    case .english:
      "EN"
    case .korean:
      "한국어"
    }
  }

  private func languageOptionTitle(_ selection: AppLanguageSelection) -> String {
    switch selection {
    case .system:
      "System"
    case .english:
      "English"
    case .korean:
      "Korean"
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
        Text(language.localized("Load the recovery and cleanup inventory"))
          .font(.headline)
        Text(
          language.localized(
            "Loading is explicit: DevSift will acquire the journal lock, reconcile incomplete receipts, and inspect only its fixed current-account npm quarantine. Nothing is deleted while loading."
          )
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        Button(language.localized("Load and Reconcile")) {
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
          Label(
            language.localized("No quarantined npm cache"),
            systemImage: "checkmark.circle"
          )
          .font(.headline)
          Text(
            language.localized(
              "The reconciled journal contains no current item that can be restored, permanently deleted, or retried."
            )
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
            Text(language.localized("Reconciled inventory"))
              .font(.headline)
            Spacer()
            Text(inventoryCountText(inventory))
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
                language.localized("Incomplete permanent deletions"),
                systemImage: "exclamationmark.arrow.triangle.2.circlepath"
              )
              .font(.callout.weight(.semibold))
              .foregroundStyle(.orange)

              Text(
                language.localized(
                  "These exact staged remainders cannot be restored. Each continuation requires a new, separate confirmation."
                )
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
        language.localized("Receipt-bound operations only · no arbitrary paths · no overwrite"),
        systemImage: "lock.shield"
      )
      Text(
        language.localized(
          "No filesystem paths, journal transaction IDs, or raw journal bytes are displayed. Permanent deletion never targets the active npm cache and does not claim secure erasure, attribution, or guaranteed reclaimed capacity."
        )
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
        .accessibilityLabel(language.localized(title))
      VStack(alignment: .leading, spacing: 3) {
        Text(language.localized(title))
          .font(.callout.weight(.semibold))
        Text(language.localized(message))
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
  }

  private func inventoryCountText(
    _ inventory: QuarantineRecoveryInventoryPresentation
  ) -> String {
    let count = inventory.rows.count + inventory.purgeRetryRows.count
    return language.format(count == 1 ? "%lld item" : "%lld items", Int64(count))
  }
}

private struct QuarantineRecoveryInventoryRowView: View {
  @Environment(\.appLanguage) private var language

  let row: QuarantineRecoveryInventoryRowPresentation
  let restoreSelectionIsEnabled: Bool
  let purgeSelectionIsEnabled: Bool
  let restore: () -> Void
  let purge: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: row.originalName)
            .font(.headline.monospaced())
          Text(verbatim: row.responsibleTool)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        HStack(spacing: 8) {
          Button(language.localized("Restore…"), action: restore)
            .buttonStyle(.borderedProminent)
            .disabled(!row.canRestore || !restoreSelectionIsEnabled)
            .accessibilityIdentifier("quarantineRestoreButton")
            .accessibilityHint(language.localized(row.restoreAvailabilityMessage))

          Button(
            language.localized("Permanently Delete…"),
            role: .destructive,
            action: purge
          )
          .buttonStyle(.bordered)
          .tint(.red)
          .disabled(!row.canPurge || !purgeSelectionIsEnabled)
          .accessibilityIdentifier("quarantineInitialPurgeButton")
          .accessibilityHint(language.localized(row.purgeAvailabilityMessage))
        }
      }

      Divider()

      recoveryStateLabel(row.source)
      recoveryStateLabel(row.quarantinedItem)

      if row.receiptWasProducedByRecovery {
        Label(
          language.localized(
            "The terminal quarantine receipt was completed by journal recovery."
          ),
          systemImage: "clock.arrow.circlepath"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Text(language.localized(row.restoreAvailabilityMessage))
        .font(.caption)
        .foregroundStyle(row.canRestore ? Color.secondary : Color.orange)
        .fixedSize(horizontal: false, vertical: true)

      Text(language.localized(row.purgeAvailabilityMessage))
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
    Label(language.localized(state.title), systemImage: state.tone.systemImage)
      .font(.caption)
      .foregroundStyle(state.tone.color)
  }

  private func recoveryStateLabel(
    _ state: QuarantineRecoveryItemStatePresentation
  ) -> some View {
    Label(language.localized(state.title), systemImage: state.tone.systemImage)
      .font(.caption)
      .foregroundStyle(state.tone.color)
  }
}

private struct QuarantinePurgeRetryInventoryRowView: View {
  @Environment(\.appLanguage) private var language

  let row: QuarantineRecoveryPurgeRetryRowPresentation
  let retrySelectionIsEnabled: Bool
  let retry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: row.originalName)
            .font(.headline.monospaced())
          Text(verbatim: row.responsibleTool)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        Button(language.localized("Continue Deletion…"), role: .destructive, action: retry)
          .buttonStyle(.borderedProminent)
          .tint(.red)
          .disabled(!row.canRetry || !retrySelectionIsEnabled)
          .accessibilityIdentifier("quarantinePurgeRetryButton")
          .accessibilityHint(language.localized(row.retryAvailabilityMessage))
      }

      Label(
        language.localized("Exact staged deletion remainder"),
        systemImage: "shippingbox.and.arrow.backward"
      )
      .font(.caption)
      .foregroundStyle(.orange)

      Text(language.localized(row.retryAvailabilityMessage))
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
  @Environment(\.appLanguage) private var language

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
          language.format(
            "Core prepared one attempt to restore the current quarantined %@ for %@. It will fail rather than overwrite the original name.",
            confirmation.originalName,
            confirmation.responsibleTool
          )
        )
        .font(.callout)
        .foregroundStyle(.secondary)

        VStack(alignment: .leading, spacing: 4) {
          Text(language.localized("Exact Core-required statement"))
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
          language.localized("I confirm the exact Core-required statement shown above."),
          isOn: $exactStatementWasConfirmed
        )
        .toggleStyle(.checkbox)

        Toggle(isOn: $npmWasStopped) {
          Text(
            language.localized(
              "I stopped npm work using this cache. I understand DevSift did not observe inactivity."
            )
          )
        }
        .toggleStyle(.checkbox)

        Toggle(isOn: $postQuarantineChangesWereAccepted) {
          Text(
            language.localized(
              "I accept that these are the current quarantined contents and may include changes made after quarantine."
            )
          )
        }
        .toggleStyle(.checkbox)

        HStack {
          Spacer()
          Button(language.localized("Cancel"), action: cancel)
          Button(language.localized("Restore Current Contents")) {
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
      Label(
        language.localized("Confirm no-overwrite restore"),
        systemImage: "checkmark.shield"
      )
      .font(.headline)
    }
  }
}

private struct QuarantinePurgeConfirmationView: View {
  @Environment(\.appLanguage) private var language

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
          Text(language.localized(confirmation.dataRemanenceDisclosure))
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.red)
        .accessibilityIdentifier("quarantinePurgeDataRemanenceDisclosure")

        VStack(alignment: .leading, spacing: 5) {
          Text(language.localized("Exact Core-required statement"))
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
          language.localized(
            "I confirm the exact statement above and understand this is permanent deletion, not secure erase."
          ),
          isOn: $exactStatementWasConfirmed
        )
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("quarantinePurgeExactStatementAcknowledgement")

        Toggle(
          language.localized(
            "I accept that restore becomes unavailable after staging and that deletion may be partial."
          ),
          isOn: $restoreCutoffAndPartialDeletionWereAccepted
        )
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("quarantinePurgeRestoreCutoffAcknowledgement")

        Toggle(
          language.localized(
            "I stopped npm and other work using this cache. I accept unobserved activity, post-quarantine changes, and same-account races."
          ),
          isOn: $workAndActivityRisksWereAccepted
        )
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("quarantinePurgeActivityRiskAcknowledgement")

        Toggle(
          language.localized(
            "I accept that the capacity reading is only observational, may show zero change or be unavailable, and cannot be attributed to DevSift."
          ),
          isOn: $capacityAndSecureEraseLimitsWereAccepted
        )
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("quarantinePurgeCapacityAcknowledgement")

        HStack {
          Spacer()
          Button(language.localized("Cancel"), action: cancel)
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
            language.localized(
              "Runs one receipt-bound permanent deletion pass after all four acknowledgements are selected"
            )
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
      return language.format(
        "Core prepared one attempt to continue deleting the exact staged remainder of %@ for %@. Restore is already unavailable for this remainder.",
        confirmation.originalName,
        confirmation.responsibleTool
      )
    }
    return language.format(
      "Core prepared one attempt to permanently delete the exact current quarantined %@ for %@. It never targets the active cache name.",
      confirmation.originalName,
      confirmation.responsibleTool
    )
  }

  private var confirmationTitle: String {
    language.localized(
      confirmation.isExplicitRetry
        ? "Confirm permanent deletion retry"
        : "Confirm permanent deletion"
    )
  }

  private var confirmButtonTitle: String {
    language.localized(
      confirmation.isExplicitRetry
        ? "Continue Permanent Deletion"
        : "Permanently Delete"
    )
  }

  private var allRisksWereAcknowledged: Bool {
    exactStatementWasConfirmed
      && restoreCutoffAndPartialDeletionWereAccepted
      && workAndActivityRisksWereAccepted
      && capacityAndSecureEraseLimitsWereAccepted
  }
}

private struct QuarantineRecoveryResultBanner: View {
  @Environment(\.appLanguage) private var language

  let result: QuarantineRecoveryResultPresentation
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top) {
        Label(language.localized(result.title), systemImage: result.tone.systemImage)
          .font(.headline)
          .foregroundStyle(result.tone.color)
        Spacer()
        Button(language.localized("Dismiss"), action: dismiss)
          .controlSize(.small)
      }
      Text(language.localized(result.message))
      Text(language.localized(result.durabilityMessage))
        .foregroundStyle(.secondary)
      if let cancellationMessage = result.cancellationMessage {
        Text(language.localized(cancellationMessage))
          .foregroundStyle(.secondary)
      }
      Text(language.localized("Restore result · no overwrite · no deletion authority used"))
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
  @Environment(\.appLanguage) private var language

  let result: QuarantineRecoveryPurgeResultPresentation
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top) {
        Label(language.localized(result.title), systemImage: result.tone.systemImage)
          .font(.headline)
          .foregroundStyle(result.tone.color)
        Spacer()
        Button(language.localized("Dismiss"), action: dismiss)
          .controlSize(.small)
      }

      Text(language.localized(result.message))
      Text(language.localized(result.durabilityMessage))
        .foregroundStyle(.secondary)
      Text(language.localized(result.observedUnlinkMessage))
        .foregroundStyle(.secondary)
      Text(language.localized(result.capacityMessage))
        .foregroundStyle(.secondary)

      if let cancellationMessage = result.cancellationMessage {
        Text(language.localized(cancellationMessage))
          .foregroundStyle(.orange)
      }

      Label(resultSummary, systemImage: resultSummaryImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(result.requiresExplicitRetry ? Color.orange : result.tone.color)

      Text(language.localized(result.limitationsMessage))
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
      return language.localized("A separate confirmation is required to continue deletion.")
    }
    if result.performedPermanentDeletion {
      return language.localized("Permanent deletion activity was observed during this pass.")
    }
    return language.localized("No permanent deletion activity was observed during this pass.")
  }

  private var resultSummaryImage: String {
    if result.requiresExplicitRetry {
      return "exclamationmark.arrow.triangle.2.circlepath"
    }
    return result.performedPermanentDeletion ? "trash.fill" : "nosign"
  }
}

private struct QuarantineRecoveryIssueBanner: View {
  @Environment(\.appLanguage) private var language

  let issue: QuarantineRecoveryIssuePresentation
  let actionTitle: String
  let dismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: issue.tone.systemImage)
        .foregroundStyle(issue.tone.color)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(language.localized(issue.title))
          .font(.callout.weight(.semibold))
        Text(language.localized(issue.message))
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      Button(language.localized(actionTitle), action: dismiss)
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
