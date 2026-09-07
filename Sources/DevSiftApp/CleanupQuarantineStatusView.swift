import SwiftUI

struct CleanupQuarantineProgressView: View {
  let root: URL
  let review: CleanupManifestReviewPresentation
  @Environment(\.appLanguage) private var language

  var body: some View {
    VStack(spacing: 18) {
      ProgressView()
        .controlSize(.large)
        .accessibilityLabel(language.localized("Quarantine attempt in progress"))

      Text(language.localized("Moving the reviewed npm cache to quarantine"))
        .font(.title2.weight(.semibold))
        .accessibilityAddTraits(.isHeader)

      Text(verbatim: SafeDisplayText.filePath(root))
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)

      Text(
        language.localized(
          "DevSift is repeating its filesystem safety checks and recording the transaction. Closing the window requests cancellation, but reconciliation may continue if the protected rename has already started."
        )
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: 560)

      Label(
        language.format(
          review.entryCount == 1
            ? "%lld reviewed item · permanent deletion disabled"
            : "%lld reviewed items · permanent deletion disabled",
          Int64(review.entryCount)
        ),
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
  @Environment(\.appLanguage) private var language

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack(alignment: .top, spacing: 14) {
          Image(systemName: result.tone.systemImage)
            .font(.system(size: 34))
            .foregroundStyle(result.tone.color)
            .accessibilityHidden(true)

          VStack(alignment: .leading, spacing: 6) {
            Text(language.localized(result.title))
              .font(.title2.weight(.semibold))
              .accessibilityAddTraits(.isHeader)
            Text(verbatim: SafeDisplayText.filePath(root))
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }

        statusCard(
          title: "Attempt result",
          message: language.localized(result.message),
          systemImage: "arrow.right.square"
        )
        statusCard(
          title: "Durability",
          message: language.localized(result.durabilityMessage),
          systemImage: "checkmark.shield"
        )

        if let namespaceMessage = result.namespaceMessage {
          statusCard(
            title: "Quarantine namespace",
            message: language.localized(namespaceMessage),
            systemImage: "folder.badge.gearshape"
          )
        }
        if let cancellationMessage = result.cancellationMessage {
          statusCard(
            title: "Cancellation",
            message: language.localized(cancellationMessage),
            systemImage: "clock.arrow.circlepath"
          )
        }

        HStack(alignment: .top, spacing: 12) {
          Image(systemName: "externaldrive.badge.exclamationmark")
            .font(.title2)
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 4) {
            Text(language.localized("No disk space was reclaimed"))
              .font(.headline)
            Text(
              language.format(
                "Quarantine is a same-volume move. No file was permanently deleted and guaranteed freed capacity is %@.",
                StorageByteFormatter.string(from: result.guaranteedFreedBytes)
              )
            )
            .font(.callout)
            .foregroundStyle(.secondary)
          }
        }
        .padding(14)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

        HStack {
          if let openRecovery {
            Button(language.localized("Open Recovery…"), action: openRecovery)
              .buttonStyle(.borderedProminent)
          }
          Button(language.localized("Rescan"), action: rescan)
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
        Text(language.localized(title))
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
