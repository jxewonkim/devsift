import SwiftUI

struct CleanupQuarantineProgressView: View {
  let root: URL
  let review: CleanupManifestReviewPresentation

  var body: some View {
    VStack(spacing: 18) {
      ProgressView()
        .controlSize(.large)
        .accessibilityLabel("Quarantine attempt in progress")

      Text("Moving the reviewed npm cache to quarantine")
        .font(.title2.weight(.semibold))
        .accessibilityAddTraits(.isHeader)

      Text(SafeDisplayText.filePath(root))
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)

      Text(
        "DevSift is repeating its filesystem safety checks and recording the transaction. Closing the window requests cancellation, but reconciliation may continue if the protected rename has already started."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: 560)

      Label(
        "\(review.entryCount.formatted()) reviewed item · permanent deletion disabled",
        systemImage: "shippingbox.and.arrow.backward"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(40)
  }
}

struct CleanupQuarantineResultView: View {
  let root: URL
  let result: CleanupQuarantineResultPresentation
  let rescan: () -> Void
  let openRecovery: (() -> Void)?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack(alignment: .top, spacing: 14) {
          Image(systemName: result.tone.systemImage)
            .font(.system(size: 34))
            .foregroundStyle(result.tone.color)
            .accessibilityHidden(true)

          VStack(alignment: .leading, spacing: 6) {
            Text(result.title)
              .font(.title2.weight(.semibold))
              .accessibilityAddTraits(.isHeader)
            Text(SafeDisplayText.filePath(root))
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }

        statusCard(
          title: "Attempt result",
          message: result.message,
          systemImage: "arrow.right.square"
        )
        statusCard(
          title: "Durability",
          message: result.durabilityMessage,
          systemImage: "checkmark.shield"
        )

        if let namespaceMessage = result.namespaceMessage {
          statusCard(
            title: "Quarantine namespace",
            message: namespaceMessage,
            systemImage: "folder.badge.gearshape"
          )
        }
        if let cancellationMessage = result.cancellationMessage {
          statusCard(
            title: "Cancellation",
            message: cancellationMessage,
            systemImage: "clock.arrow.circlepath"
          )
        }

        HStack(alignment: .top, spacing: 12) {
          Image(systemName: "externaldrive.badge.exclamationmark")
            .font(.title2)
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 4) {
            Text("No disk space was reclaimed")
              .font(.headline)
            Text(
              "Quarantine is a same-volume move. No file was permanently deleted and guaranteed freed capacity is \(StorageByteFormatter.string(from: result.guaranteedFreedBytes))."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
          }
        }
        .padding(14)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

        HStack {
          if let openRecovery {
            Button("Open Recovery…", action: openRecovery)
              .buttonStyle(.borderedProminent)
          }
          Button("Rescan", action: rescan)
        }
      }
      .frame(maxWidth: 720, alignment: .leading)
      .padding(28)
      .frame(maxWidth: .infinity, alignment: .center)
    }
  }

  private func statusCard(
    title: String,
    message: String,
    systemImage: String
  ) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
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
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
    }
  }
}

struct CleanupQuarantineFailureView: View {
  let root: URL
  let failure: CleanupQuarantineFailurePresentation
  let rescan: () -> Void

  var body: some View {
    ScanMessageView(
      systemImage: "exclamationmark.shield",
      title: failure.title,
      message: failure.message,
      root: root,
      primaryTitle: "Rescan and Review",
      primaryAction: rescan
    )
  }
}

extension CleanupQuarantinePresentationTone {
  fileprivate var systemImage: String {
    switch self {
    case .success:
      "checkmark.shield.fill"
    case .warning:
      "exclamationmark.triangle.fill"
    case .failure:
      "xmark.shield.fill"
    }
  }

  fileprivate var color: Color {
    switch self {
    case .success:
      .green
    case .warning:
      .orange
    case .failure:
      .red
    }
  }
}
