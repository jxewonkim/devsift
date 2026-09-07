import Foundation
import Testing

@testable import DevSiftApp
@testable import DevSiftCore

@Suite("Native app localization")
struct AppLocalizationTests {
  @Test("Explicit and system language choices resolve deterministically")
  func languageResolution() {
    #expect(
      AppLanguageSelection.system.resolvedLanguage(preferredLanguages: ["ko-KR"])
        == .korean
    )
    #expect(
      AppLanguageSelection.system.resolvedLanguage(preferredLanguages: ["en-US"])
        == .english
    )
    #expect(
      AppLanguageSelection.system.resolvedLanguage(preferredLanguages: ["ja-JP"])
        == .english
    )
    #expect(
      AppLanguageSelection.english.resolvedLanguage(preferredLanguages: ["ko-KR"])
        == .english
    )
    #expect(
      AppLanguageSelection.korean.resolvedLanguage(preferredLanguages: ["en-US"])
        == .korean
    )
  }

  @Test("English passes through and unknown values remain verbatim")
  func fallbackAndVerbatimValues() {
    let path = "/private/tmp/DevSift/%@/원본/_cacache"
    let revision = "devsift.cache.npm@3"
    let posixCode = "POSIX 13"

    #expect(AppLanguage.english.localized("Permanently Delete") == "Permanently Delete")
    #expect(AppLanguage.korean.localized(path) == path)
    #expect(AppLanguage.korean.localized(revision) == revision)
    #expect(AppLanguage.korean.localized(posixCode) == posixCode)
  }

  @Test("Critical permanent-deletion disclosures have Korean copy")
  func koreanSafetyCopy() {
    let keys = [
      "I confirm the exact statement above and understand this is permanent deletion, not secure erase.",
      "I accept that restore becomes unavailable after staging and that deletion may be partial.",
      "I stopped npm and other work using this cache. I accept unobserved activity, post-quarantine changes, and same-account races.",
      "I accept that the capacity reading is only observational, may show zero change or be unavailable, and cannot be attributed to DevSift.",
    ]

    #expect(AppLanguage.korean.localized("Permanently Delete") == "영구 삭제")
    #expect(
      AppLanguage.korean.localized(
        "This is not secure erase: APFS snapshots or clones, backups, open file descriptors, and storage-device behavior may retain data or blocks."
      ).contains("보안 삭제가 아닙니다")
    )
    for key in keys {
      #expect(AppLanguage.korean.localized(key) != key)
    }
  }

  @Test("Korean format strings preserve injected raw values")
  func koreanFormatting() {
    let rawName = "이름%@\\n"

    #expect(
      AppLanguage.korean.format("Scanning %@…", rawName)
        == "\(rawName) 스캔 중…"
    )
    #expect(
      AppLanguage.korean.format("%lld of %lld included", Int64(2), Int64(5))
        == "5개 중 2개 포함"
    )
    #expect(
      AppLanguage.korean.format(
        "Core prepared one attempt to permanently delete the exact current quarantined %@ for %@. It never targets the active cache name.",
        "_cacache",
        "npm"
      ).hasPrefix("Core가 npm용 현재 격리 항목 _cacache의 영구 삭제 작업")
    )
  }

  @Test("Every localized format keeps compatible argument positions and types")
  func formatCatalogCompatibility() {
    #expect(AppLanguage.koreanCatalogFormatCompatibilityIssues.isEmpty)
  }

  @Test("Preformatted workflow results localize through bounded templates")
  func preformattedWorkflowResults() {
    let capacity =
      "Observed same-volume available capacity increased by 4.3 GB; this change is not attributed to DevSift."
    let stageFailure =
      "The attempt was cancelled during review confirmation. No execution result was issued; rescan before trying again."
    let manualRecovery =
      "A possible quarantine location was observed. The rename result is indeterminate. Recovery must inspect the current namespaces."
    let retry =
      "Core observed bounded unlink progress, but an exact staged remainder still exists. The pass stopped after cancellation was observed. Restore is unavailable for the staged remainder; continuing requires a separate explicit confirmation from the refreshed inventory."

    let localizedCapacity = AppLanguage.korean.localized(capacity)
    #expect(localizedCapacity.contains("4.3 GB"))
    #expect(localizedCapacity.contains("증가했습니다"))
    #expect(AppLanguage.korean.localized(stageFailure).contains("검토 확인 중"))
    #expect(AppLanguage.korean.localized(manualRecovery).contains("가능한 격리 위치"))
    #expect(AppLanguage.korean.localized(manualRecovery).contains("이름 변경 결과"))
    #expect(AppLanguage.korean.localized(retry).contains("별도로 다시 확인해야 합니다"))
    #expect(!AppLanguage.korean.localized(retry).contains("Restore is unavailable"))
  }

  @Test("Known Core scan and policy copy has Korean presentation")
  func knownCoreCopy() throws {
    let scanErrors: [ScanError] = [
      .rootMustBeAbsoluteFileURL,
      .rootNotFound,
      .rootIsSymbolicLink,
      .rootIsNotDirectory,
      .rootChangedDuringValidation,
      .rootUnavailable(operation: .readMetadata, systemCode: 13),
    ]
    for error in scanErrors {
      let english = try #require(error.errorDescription)
      #expect(AppLanguage.korean.localized(english) != english)
    }

    let policyCopy = [
      "uv cache",
      "npm content cache",
      "Homebrew cache",
      "SwiftPM build output",
      "iOS DeviceSupport version",
      "The candidate raw name must be exactly `_cacache`.",
      "All required evidence was satisfied; the item is classified as reclaimable.",
      "Activity was not observed. Review can continue only with a pending user-attestation requirement; this is not inactivity evidence.",
    ]
    for english in policyCopy {
      #expect(AppLanguage.korean.localized(english) != english)
    }
    #expect(
      AppLanguage.korean.localized(
        "The candidate raw name must be exactly `_cacache`."
      ).contains("`_cacache`")
    )
  }

  @Test("Core-required confirmation statements are never translated")
  func coreStatementsRemainVerbatim() {
    let statements = [
      QuarantineRestoreConfirmationStatement
        .restoreCurrentQuarantinedContentsWithoutOverwriteWithNPMStoppedAndChangesAccepted
        .rawValue,
      QuarantinePurgeConfirmationStatement.initialPermanentDeletionRisksAccepted.rawValue,
      QuarantinePurgeConfirmationStatement.explicitRetryPermanentDeletionRisksAccepted.rawValue,
      CleanupQuarantineAttestationStatement
        .responsibleToolStoppedAndUnobservedActivityRiskAccepted.rawValue,
    ]

    for statement in statements {
      #expect(AppLanguage.korean.localized(statement) == statement)
    }
  }
}
