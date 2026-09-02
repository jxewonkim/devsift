import AppKit
import DevSiftCore
import SwiftUI
import UniformTypeIdentifiers

struct ScanDashboardView: View {
  @State private var viewModel: ScanViewModel
  @State private var folderImporterIsPresented = false
  @State private var folderImportFailureIsPresented = false

  init(viewModel: ScanViewModel = ScanViewModel()) {
    _viewModel = State(initialValue: viewModel)
  }

  var body: some View {
    VStack(spacing: 0) {
      dashboardHeader
      Divider()

      Group {
        switch viewModel.phase {
        case .empty:
          EmptyScanView(selectFolder: selectFolder)
        case .scanning(let root):
          ScanningView(root: root)
        case .result(let root, let presentation):
          ScanResultView(root: root, presentation: presentation)
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
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      Divider()
      safetyFooter
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
    .onChange(of: footerStatus) { _, _ in
      guard let announcement = DashboardAccessibility.announcement(for: viewModel.phase) else {
        return
      }
      NSAccessibility.post(
        element: NSApp as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: announcement,
          .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ]
      )
    }
    .onDisappear(perform: viewModel.stopForWindowClosure)
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

      if viewModel.isScanning {
        Button(role: .cancel, action: viewModel.cancelScan) {
          Label("Cancel", systemImage: "xmark")
        }
        .keyboardShortcut(.escape, modifiers: [])
        .accessibilityHint("Stops the scan at the next cancellation checkpoint")
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
    .frame(height: 64)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var safetyFooter: some View {
    HStack(spacing: 8) {
      Label("Read-only analysis · No files were changed", systemImage: "lock.shield")
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
    .frame(height: 36)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var footerStatus: String {
    switch viewModel.phase {
    case .empty:
      "Ready"
    case .scanning:
      "Scan in progress"
    case .result(_, let presentation):
      presentation.observationIsComplete ? "Complete observation" : "Partial observation"
    case .cancelled:
      "Scan cancelled"
    case .failed:
      "Scan unavailable"
    }
  }

  private var showsHeaderFolderButton: Bool {
    switch viewModel.phase {
    case .empty, .scanning:
      false
    default:
      true
    }
  }

  private var showsHeaderRescanButton: Bool {
    if case .result = viewModel.phase {
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

private struct ScanMessageView: View {
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
