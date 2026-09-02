import DevSiftCore
import SwiftUI

@main
struct DevSiftApp: App {
  var body: some Scene {
    WindowGroup {
      FoundationView(status: .current)
    }
    .windowResizability(.contentSize)
  }
}

private struct FoundationView: View {
  let status: DevSiftStatus

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Image(systemName: "line.3.horizontal.decrease.circle")
        .font(.system(size: 44, weight: .medium))
        .foregroundStyle(.tint)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 6) {
        Text("DevSift")
          .font(.largeTitle.bold())
        Text("Know what's safe to clear.")
          .font(.title3)
          .foregroundStyle(.secondary)
      }

      Label("Scan-only foundation", systemImage: "lock.shield")
        .font(.headline)

      Text(
        "No files are changed in this build. The read-only scanner is implemented in DevSiftCore; app integration is the next milestone."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      Divider()

      Text(status.summary)
        .font(.caption.monospaced())
        .foregroundStyle(.tertiary)
        .accessibilityLabel("Version \(status.version), safety mode \(status.safetyMode.rawValue)")
    }
    .padding(32)
    .frame(width: 520)
  }
}
