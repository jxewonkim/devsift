import SwiftUI

@main
struct DevSiftApp: App {
  var body: some Scene {
    WindowGroup("DevSift") {
      ScanDashboardView()
    }
    .defaultSize(width: 1_200, height: 760)
  }
}
