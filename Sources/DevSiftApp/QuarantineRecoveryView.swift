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
      Label("npm Recovery", systemImage: "arrow.uturn.backward.circle.fill")
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
        Text("Quarantine does not free disk space")
          .font(.headline)
        Text(
          "DevSift quarantine is a same-volume move. Recovery can restore the current quarantined contents, but neither quarantine nor restore permanently deletes files or reclaims capacity."
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
        Text("Load the recovery inventory")
          .font(.headline)
        Text(
          "Loading is explicit: DevSift will acquire the recovery journal lock, reconcile incomplete receipts, and inspect only its fixed current-account npm quarantine."
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
        title: "Loading recovery inventory",
        message: "Reconciling durable journal state before any restore option is shown."
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
            "The reconciled journal contains no current item that can be presented for recovery."
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
              "\(inventory.rows.count.formatted()) \(inventory.rows.count == 1 ? "item" : "items")"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }

          ForEach(inventory.rows) { row in
            QuarantineRecoveryInventoryRowView(
              row: row,
              restoreSelectionIsEnabled: viewModel.canStartRestore,
              restore: { viewModel.requestRestore(for: row.id) }
            )
          }
        }
      }
    }
  }

  private var safetyFooter: some View {
    VStack(alignment: .leading, spacing: 5) {
      Label(
        "Restore only · no permanent deletion · no overwrite",
        systemImage: "lock.shield"
      )
      Text(
        "Journal v1 does not provide trustworthy item dates or sizes, so this screen does not invent or estimate them. No filesystem paths or journal transaction IDs are displayed."
      )
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
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
  let restore: () -> Void

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

        Button("Restore…", action: restore)
          .buttonStyle(.borderedProminent)
          .disabled(!row.canRestore || !restoreSelectionIsEnabled)
          .accessibilityHint(row.restoreAvailabilityMessage)
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

private struct QuarantineRecoveryConfirmationView: View {
  let confirmation: QuarantineRecoveryConfirmationPresentation
  let confirm: (Bool, Bool, Bool) -> Void
  let cancel: () -> Void

  @State private var exactStatementWasConfirmed = false
  @State private var npmWasStopped = false
  @State private var postQuarantineChangesWereAccepted = false

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 12) {
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
      Text("Permanent deletion: no · overwrite: no")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }
    .font(.callout)
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(result.tone.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
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
