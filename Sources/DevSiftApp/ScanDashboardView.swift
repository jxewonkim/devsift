import AppKit
import DevSiftCore
import SwiftUI
import UniformTypeIdentifiers

struct ScanDashboardView: View {
  @State private var viewModel: ScanViewModel
  @State private var folderImporterIsPresented = false
  @State private var folderImportFailureIsPresented = false
  private let policyDetailsInitiallyExpanded: Bool

  init(
    viewModel: ScanViewModel = ScanViewModel(),
    policyDetailsInitiallyExpanded: Bool = false
  ) {
    _viewModel = State(initialValue: viewModel)
    self.policyDetailsInitiallyExpanded = policyDetailsInitiallyExpanded
  }

  var body: some View {
    GeometryReader { window in
      VStack(spacing: 0) {
        dashboardHeader
          .layoutPriority(1)
        Divider()
        dashboardContent
          .frame(
            width: window.size.width,
            height: max(0, window.size.height - DashboardLayout.chromeHeight)
          )
          .clipped()

        Divider()
        safetyFooter
          .layoutPriority(1)
      }
      .frame(
        width: window.size.width,
        height: window.size.height,
        alignment: .top
      )
    }
    .frame(minWidth: 900, minHeight: 620)
    .background(Color(nsColor: .windowBackgroundColor))
    .fileImporter(
      isPresented: $folderImporterIsPresented,
      allowedContentTypes: [.directory],
      allowsMultipleSelection: false,
      onCompletion: handleFolderImport
    )
    .fileDialogImportsUnresolvedAliases(true)
    .alert("Folder selection failed", isPresented: $folderImportFailureIsPresented) {
      Button("OK") {}
    } message: {
      Text("DevSift could not open the folder picker result. Select the folder again.")
    }
    .onChange(of: viewModel.phase) { _, phase in
      guard let announcement = DashboardAccessibility.announcement(for: phase) else {
        return
      }
      postAccessibilityAnnouncement(announcement)
    }
    .onChange(of: viewModel.cleanupReviewPhase) { previousPhase, phase in
      guard
        let announcement = CleanupReviewAccessibility.announcement(
          from: previousPhase,
          to: phase
        )
      else {
        return
      }
      postAccessibilityAnnouncement(announcement)
    }
    .onDisappear(perform: viewModel.stopForWindowClosure)
  }

  @ViewBuilder
  private var dashboardContent: some View {
    switch viewModel.phase {
    case .empty:
      EmptyScanView(selectFolder: selectFolder)
    case .scanning(let root):
      ScanningView(root: root)
    case .classifying(let root):
      ClassifyingView(root: root)
    case .result(let root, let presentation):
      switch viewModel.cleanupReviewPhase {
      case .review(let review):
        CleanupManifestReviewView(
          root: root,
          review: review,
          quarantineAvailability: viewModel.cleanupQuarantineAvailability,
          backToSelection: viewModel.dismissCleanupReview,
          executeQuarantine: { reviewWasConfirmed, npmStoppedRiskWasAccepted in
            viewModel.executeReviewedCleanup(
              reviewWasConfirmed: reviewWasConfirmed,
              npmStoppedRiskWasAccepted: npmStoppedRiskWasAccepted
            )
          }
        )
      case .executing(let review):
        CleanupQuarantineProgressView(root: root, review: review)
      case .executionResult(let result):
        CleanupQuarantineResultView(
          root: root,
          result: result,
          rescan: { viewModel.rescan() },
          openRecovery: nil
        )
      case .executionFailed(let failure):
        CleanupQuarantineFailureView(
          root: root,
          failure: CleanupQuarantineFailurePresentation(failure: failure),
          rescan: { viewModel.rescan() }
        )
      case .unavailable, .selecting, .preparing, .failed:
        ScanResultView(
          root: root,
          presentation: presentation,
          cleanupReviewPhase: viewModel.cleanupReviewPhase,
          cleanupCandidateCount: viewModel.cleanupCandidateCount,
          selectedCleanupCandidates: viewModel.selectedCleanupCandidates,
          setCleanupCandidate: viewModel.setCleanupCandidate,
          clearCleanupCandidates: viewModel.clearCleanupCandidates,
          prepareCleanupReview: { viewModel.prepareCleanupReview() },
          cancelCleanupReviewPreparation: viewModel.cancelCleanupReviewPreparation,
          policyDetailsInitiallyExpanded: policyDetailsInitiallyExpanded
        )
      }
    case .cancelled(let root):
      ScanMessageView(
        systemImage: "stop.circle",
        title: "Scan cancelled",
        message: "The scan stopped without changing files.",
        root: root,
        primaryTitle: "Scan Again",
        primaryAction: { viewModel.rescan() }
      )
    case .failed(let root, let failure):
      ScanMessageView(
        systemImage: "exclamationmark.triangle",
        title: failure.title,
        message: failure.message,
        root: root,
        primaryTitle: "Try Again",
        primaryAction: { viewModel.rescan() }
      )
    }
  }

  private var dashboardHeader: some View {
    HStack(spacing: 14) {
      Label {
        Text("DevSift")
          .font(.title2.weight(.semibold))
      } icon: {
        Image(systemName: "line.3.horizontal.decrease.circle.fill")
          .font(.title2)
          .foregroundStyle(.tint)
      }
      .accessibilityElement(children: .combine)

      Spacer()

      if showsHeaderRescanButton {
        Button(action: { viewModel.rescan() }) {
          Label("Rescan", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("r", modifiers: .command)
        .accessibilityHint("Scans the same selected folder again")
      }

      if viewModel.isWorking {
        Button(role: .cancel, action: viewModel.cancelScan) {
          Label("Cancel", systemImage: "xmark")
        }
        .keyboardShortcut(.escape, modifiers: [])
        .accessibilityHint(DashboardAccessibility.cancelHint)
      }

      if showsHeaderFolderButton {
        Button(action: selectFolder) {
          Label("Select Folder…", systemImage: "folder.badge.plus")
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut("o", modifiers: .command)
        .accessibilityHint("Choose the only folder DevSift will scan")
      }
    }
    .controlSize(.regular)
    .padding(.horizontal, 28)
    .frame(height: DashboardLayout.headerHeight)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var safetyFooter: some View {
    HStack(spacing: 8) {
      Label(footerSafetyStatus, systemImage: "lock.shield")
        .foregroundStyle(.secondary)

      Spacer()

      Text(footerStatus)
        .foregroundStyle(.secondary)
      Text("·")
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
      Text("No telemetry")
        .foregroundStyle(.secondary)
    }
    .font(.caption)
    .padding(.horizontal, 28)
    .frame(height: DashboardLayout.footerHeight)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var footerSafetyStatus: String {
    switch viewModel.cleanupReviewPhase {
    case .executing:
      "Recoverable move only · Permanent deletion disabled"
    case .executionResult:
      "Quarantine is not deletion · 0 B guaranteed freed"
    case .executionFailed:
      "Attempt rejected · Permanent deletion disabled"
    case .unavailable, .selecting, .preparing, .review, .failed:
      "Analysis and review · No files changed in this state"
    }
  }

  private var footerStatus: String {
    switch viewModel.phase {
    case .empty:
      "Ready"
    case .scanning:
      "Scan in progress"
    case .classifying:
      "Policy analysis in progress"
    case .result(_, let presentation):
      switch viewModel.cleanupReviewPhase {
      case .preparing:
        "Draft preparation in progress"
      case .review:
        "Unapproved draft review"
      case .executing:
        "Recoverable quarantine in progress"
      case .executionResult:
        "Quarantine attempt finished"
      case .executionFailed:
        "Quarantine attempt did not start"
      case .failed:
        "Draft unavailable"
      case .unavailable, .selecting:
        presentation.observationIsComplete ? "Complete observation" : "Partial observation"
      }
    case .cancelled:
      "Scan cancelled"
    case .failed:
      "Scan unavailable"
    }
  }

  private var showsHeaderFolderButton: Bool {
    guard !viewModel.cleanupReviewPhase.isExecuting else {
      return false
    }
    return switch viewModel.phase {
    case .empty, .scanning, .classifying:
      false
    default:
      true
    }
  }

  private var showsHeaderRescanButton: Bool {
    if case .result = viewModel.phase, viewModel.canRescan {
      return true
    }
    return false
  }

  private func selectFolder() {
    folderImporterIsPresented = true
  }

  private func handleFolderImport(_ result: Result<[URL], any Error>) {
    switch FolderImportDecision.resolve(result) {
    case .scan(let url):
      viewModel.startScan(at: url)
    case .cancelled:
      break
    case .failure:
      folderImportFailureIsPresented = true
    }
  }

  private func postAccessibilityAnnouncement(_ announcement: String) {
    NSAccessibility.post(
      element: NSApp as Any,
      notification: .announcementRequested,
      userInfo: [
        .announcement: announcement,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ]
    )
  }
}

private enum DashboardLayout {
  static let headerHeight: CGFloat = 64
  static let footerHeight: CGFloat = 36
  static let dividerHeight: CGFloat = 1
  static let chromeHeight = headerHeight + footerHeight + (dividerHeight * 2)
}

enum FolderImportDecision: Equatable {
  case scan(URL)
  case cancelled
  case failure

  static func resolve(_ result: Result<[URL], any Error>) -> FolderImportDecision {
    switch result {
    case .success(let urls):
      guard let url = urls.first else {
        return .failure
      }
      return .scan(url)
    case .failure(let error):
      let cocoaError = error as NSError
      if cocoaError.domain == NSCocoaErrorDomain && cocoaError.code == NSUserCancelledError {
        return .cancelled
      }
      return .failure
    }
  }
}

private struct EmptyScanView: View {
  let selectFolder: () -> Void

  var body: some View {
    VStack(spacing: 22) {
      ZStack {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .fill(Color.accentColor.opacity(0.08))
          .frame(width: 112, height: 112)
        Image(systemName: "internaldrive")
          .font(.system(size: 48, weight: .light))
          .foregroundStyle(.tint)
      }
      .accessibilityHidden(true)

      VStack(spacing: 8) {
        Text("Understand what's taking space.")
          .font(.system(size: 30, weight: .semibold))
          .accessibilityAddTraits(.isHeader)
        Text("Choose one folder to observe its filesystem metadata and largest top-level items.")
          .font(.title3)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 560)
      }

      Button("Select Folder…", action: selectFolder)
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut("o", modifiers: .command)

      Label("Analysis only — no files will be changed.", systemImage: "lock.shield")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .padding(40)
  }
}

private struct ScanningView: View {
  let root: URL

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Scanning \(SafeDisplayText.fileName(of: root))…")
            .font(.system(size: 28, weight: .semibold))
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
          Text("Reading filesystem metadata. File contents are never opened.")
            .foregroundStyle(.secondary)
        }

        ProgressView()
          .progressViewStyle(.linear)
          .accessibilityLabel("Scanning filesystem metadata")

        Text("You can cancel safely at any time. Scanning stops at the next checkpoint.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(28)

      Divider()
        .padding(.horizontal, 28)

      VStack(spacing: 0) {
        ForEach(0..<6, id: \.self) { index in
          HStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 3)
              .fill(.quaternary)
              .frame(width: index.isMultiple(of: 2) ? 220 : 280, height: 12)
            Spacer()
            RoundedRectangle(cornerRadius: 3)
              .fill(.quaternary)
              .frame(width: 90, height: 12)
            RoundedRectangle(cornerRadius: 3)
              .fill(.quaternary)
              .frame(width: 110, height: 12)
          }
          .padding(.horizontal, 18)
          .frame(height: 48)

          if index < 5 {
            Divider()
          }
        }
      }
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color(nsColor: .controlBackgroundColor))
      )
      .overlay {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
      }
      .padding(28)
      .accessibilityHidden(true)

      Spacer(minLength: 0)
    }
  }
}

private struct ClassifyingView: View {
  let root: URL

  var body: some View {
    VStack(spacing: 22) {
      ZStack {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .fill(Color.accentColor.opacity(0.08))
          .frame(width: 104, height: 104)
        Image(systemName: "checklist")
          .font(.system(size: 44, weight: .light))
          .foregroundStyle(.tint)
      }
      .accessibilityHidden(true)

      VStack(spacing: 8) {
        Text("Analyzing policies for \(SafeDisplayText.fileName(of: root))…")
          .font(.system(size: 28, weight: .semibold))
          .lineLimit(1)
          .accessibilityAddTraits(.isHeader)
        Text(
          "The storage scan has finished. DevSift is comparing exact filesystem names with versioned, read-only rules."
        )
        .font(.title3)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 620)
      }

      ProgressView()
        .controlSize(.small)
        .accessibilityLabel("Analyzing read-only storage policies")

      Label(
        "Missing evidence stays protected. A versioned rule may expose deliberately unobserved activity only as a pending execution requirement.",
        systemImage: "lock.shield"
      )
      .font(.callout)
      .foregroundStyle(.secondary)
    }
    .padding(40)
  }
}

struct ScanMessageView: View {
  let systemImage: String
  let title: String
  let message: String
  let root: URL?
  let primaryTitle: String
  let primaryAction: () -> Void

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: systemImage)
        .font(.system(size: 46, weight: .light))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      VStack(spacing: 7) {
        Text(title)
          .font(.title.weight(.semibold))
          .accessibilityAddTraits(.isHeader)
        Text(message)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 520)
        if let root {
          Text(SafeDisplayText.filePath(root))
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)
            .lineLimit(2)
            .truncationMode(.middle)
        }
      }

      Button(primaryTitle, action: primaryAction)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(root == nil ? "o" : "r", modifiers: .command)
    }
    .padding(40)
  }
}
