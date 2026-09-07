import SwiftUI

@main
struct DevSiftApp: App {
  var body: some Scene {
    WindowGroup("DevSift") {
      DevSiftAppRootView()
    }
    .defaultSize(width: 1_200, height: 760)
  }
}

struct DevSiftAppRootView: View {
  @AppStorage("devsift.language-selection") private var storedLanguage =
    AppLanguageSelection.system.rawValue

  private var languageSelection: AppLanguageSelection {
    AppLanguageSelection(rawValue: storedLanguage) ?? .system
  }

  var body: some View {
    ScanDashboardView(languageSelection: languageSelectionBinding)
      .environment(\.appLanguage, languageSelection.resolvedLanguage())
      .environment(\.locale, languageSelection.locale)
  }

  private var languageSelectionBinding: Binding<AppLanguageSelection> {
    Binding(
      get: { languageSelection },
      set: { storedLanguage = $0.rawValue }
    )
  }
}
