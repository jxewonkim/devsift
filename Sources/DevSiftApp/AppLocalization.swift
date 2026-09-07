import Foundation
import SwiftUI

package enum AppLanguageSelection: String, CaseIterable, Identifiable, Sendable {
  case system
  case english
  case korean

  package var id: String {
    rawValue
  }

  package func resolvedLanguage(
    preferredLanguages: [String] = Locale.preferredLanguages
  ) -> AppLanguage {
    switch self {
    case .english:
      return .english
    case .korean:
      return .korean
    case .system:
      for preferredLanguage in preferredLanguages {
        let languageCode =
          preferredLanguage
          .replacingOccurrences(of: "_", with: "-")
          .split(separator: "-", maxSplits: 1)
          .first?
          .lowercased()

        switch languageCode {
        case "ko":
          return .korean
        case "en":
          return .english
        default:
          continue
        }
      }
      return .english
    }
  }

  package var locale: Locale {
    resolvedLanguage().locale
  }
}

package enum AppLanguage: String, Sendable {
  case english
  case korean

  package var locale: Locale {
    switch self {
    case .english:
      return Locale(identifier: "en_US")
    case .korean:
      return Locale(identifier: "ko_KR")
    }
  }

  package func localized(_ english: String) -> String {
    guard self == .korean else {
      return english
    }
    return Self.koreanCatalog[english] ?? localizedDynamic(english) ?? english
  }

  package func format(_ englishFormat: String, _ arguments: CVarArg...) -> String {
    String(
      format: localized(englishFormat),
      locale: locale,
      arguments: arguments
    )
  }

  /// Localizes the bounded set of presentation strings that contain values
  /// assembled before they reach SwiftUI. Unknown strings still pass through.
  private func localizedDynamic(_ english: String) -> String? {
    if let localized = localizedPurgeRetryComposite(english) {
      return localized
    }
    if let localized = localizedManualRecoveryComposite(english) {
      return localized
    }

    for template in Self.dynamicTemplates {
      if let localized = localizedSingleArgument(
        english,
        template: template.english,
        marker: template.marker,
        localizeArgument: template.localizeArgument
      ) {
        return localized
      }
    }
    return nil
  }

  private func localizedPurgeRetryComposite(_ english: String) -> String? {
    let conclusion =
      "Restore is unavailable for the staged remainder; continuing requires a separate explicit confirmation from the refreshed inventory."
    guard english.hasSuffix(" \(conclusion)") else {
      return nil
    }

    let body = String(english.dropLast(conclusion.count + 1))
    for progress in Self.purgeProgressSentences {
      guard body.hasPrefix("\(progress) ") else {
        continue
      }
      let retry = String(body.dropFirst(progress.count + 1))
      guard Self.purgeRetrySentences.contains(retry) else {
        continue
      }
      return "\(localized(progress)) \(localized(retry)) \(localized(conclusion))"
    }
    return nil
  }

  private func localizedManualRecoveryComposite(_ english: String) -> String? {
    for prefix in Self.manualRecoveryPrefixes where english.hasPrefix(prefix) {
      let message = String(english.dropFirst(prefix.count))
      guard Self.manualRecoverySentences.contains(message) else {
        continue
      }
      return localized(prefix) + localized(message)
    }
    return nil
  }

  private func localizedSingleArgument(
    _ english: String,
    template: String,
    marker: String,
    localizeArgument: Bool
  ) -> String? {
    guard
      let sourceMarker = template.range(of: marker),
      template[sourceMarker.upperBound...].range(of: marker) == nil,
      let translatedTemplate = Self.koreanCatalog[template],
      let translatedMarker = translatedTemplate.range(of: marker)
    else {
      return nil
    }

    let prefix = String(template[..<sourceMarker.lowerBound])
    let suffix = String(template[sourceMarker.upperBound...])
    guard
      !prefix.isEmpty || !suffix.isEmpty,
      english.hasPrefix(prefix),
      english.hasSuffix(suffix)
    else {
      return nil
    }

    let argumentStart = english.index(english.startIndex, offsetBy: prefix.count)
    let argumentEnd = english.index(english.endIndex, offsetBy: -suffix.count)
    guard argumentStart <= argumentEnd else {
      return nil
    }

    let rawArgument = String(english[argumentStart..<argumentEnd])
    let argument = localizeArgument ? Self.koreanCatalog[rawArgument] ?? rawArgument : rawArgument
    return translatedTemplate.replacingCharacters(in: translatedMarker, with: argument)
  }

  package static var koreanCatalogFormatCompatibilityIssues: [String] {
    koreanCatalog.keys.compactMap { english in
      let sourceSignature = formatSignature(english)
      guard !sourceSignature.isEmpty else {
        return nil
      }
      return sourceSignature == formatSignature(koreanCatalog[english] ?? "") ? nil : english
    }.sorted()
  }

  private static func formatSignature(_ text: String) -> [FormatArgument] {
    let pattern = #"%(?:(\d+)\$)?(?:\.\d+)?(ll)?([@duf])"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      return []
    }

    let matches = expression.matches(
      in: text,
      range: NSRange(text.startIndex..<text.endIndex, in: text)
    )
    var nextImplicitPosition = 1
    return matches.compactMap { match in
      let explicitPosition = Range(match.range(at: 1), in: text).flatMap {
        Int(text[$0])
      }
      let position = explicitPosition ?? nextImplicitPosition
      if explicitPosition == nil {
        nextImplicitPosition += 1
      }

      guard let conversionRange = Range(match.range(at: 3), in: text) else {
        return nil
      }
      let lengthModifier = Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? ""
      return FormatArgument(
        position: position,
        conversion: lengthModifier + String(text[conversionRange])
      )
    }.sorted { left, right in
      left.position == right.position
        ? left.conversion < right.conversion
        : left.position < right.position
    }
  }

  private struct FormatArgument: Equatable {
    let position: Int
    let conversion: String
  }

  private static let dynamicTemplates: [(english: String, marker: String, localizeArgument: Bool)] =
    [
      (
        "%@ The item remains protected.",
        "%@",
        true
      ),
      ("Unknown · %@", "%@", true),
      (
        "DevSift did not observe whether %@ is active. Any future recoverable operation requires a separate, attempt-scoped authorization based on the user's explicit statement that they stopped the responsible tool. This draft is not that authorization and cannot be executed.",
        "%@",
        false
      ),
      (
        "The item may have moved, but no terminal receipt proves completion. Open recovery inventory before another operation.%@",
        "%@",
        true
      ),
      (
        "The attempt was cancelled during %@. No execution result was issued; rescan before trying again.",
        "%@",
        true
      ),
      (
        "The retained review was rejected during %@. Rescan and review the current cache again.",
        "%@",
        true
      ),
      (
        "DevSift could not complete %@. The underlying error was not retained or displayed.",
        "%@",
        true
      ),
      ("Journal recovery completed a terminal %@ receipt.", "%@", true),
      ("A terminal %@ receipt was durably recorded.", "%@", true),
      (
        "Observed same-volume available capacity increased by %@; this change is not attributed to DevSift.",
        "%@",
        false
      ),
      (
        "Observed same-volume available capacity decreased by %@; concurrent system activity may affect this value.",
        "%@",
        false
      ),
      (
        "Core invoked unlink and then observed %lld filesystem name absent during this pass.",
        "%lld",
        false
      ),
      (
        "Core invoked unlink and then observed %lld filesystem names absent during this pass.",
        "%lld",
        false
      ),
      ("%lld entry has unknown allocation.", "%lld", false),
      ("%lld entries have unknown allocation.", "%lld", false),
      ("%lld additional scan issue was not retained.", "%lld", false),
      ("%lld additional scan issues were not retained.", "%lld", false),
      ("%llu entry has unknown allocation.", "%llu", false),
      ("%llu entries have unknown allocation.", "%llu", false),
      ("%llu additional scan issue was not retained.", "%llu", false),
      ("%llu additional scan issues were not retained.", "%llu", false),
    ]

  private static let purgeProgressSentences = [
    "Core staged the exact item but did not observe an unlink linearization in this pass.",
    "Core observed bounded unlink progress, but an exact staged remainder still exists.",
  ]

  private static let purgeRetrySentences = [
    "The pass stopped after cancellation was observed.",
    "The managed quarantine namespace changed during the pass.",
    "The staged tree changed during the pass.",
    "The staged tree did not pass a safety recheck.",
    "The bounded traversal limit was reached.",
    "The bounded synchronization pass limit was reached.",
    "A required descriptor-relative observation was unavailable.",
    "The filesystem rejected a bounded unlink operation.",
    "The filesystem could not durably synchronize the observed progress.",
  ]

  private static let manualRecoveryPrefixes = [
    "A possible quarantine location was observed. ",
    "No trustworthy quarantine location could be reported. ",
  ]

  private static let manualRecoverySentences = [
    "The journal failed its safety checks. Do not edit its files; inspect recovery details first.",
    "DevSift could not finish the required durable record. Inspect recovery details before another operation.",
    "The rename result is indeterminate. Recovery must inspect the current namespaces.",
    "The quarantine destination could not be verified after the move attempt.",
    "A parent directory changed during the operation.",
    "Another object occupies the original npm cache name. DevSift will not overwrite it.",
    "The original npm cache name could not be verified after the move attempt.",
    "The object moved back to the source name did not match the reviewed object.",
    "A safe rollback could not be completed.",
    "DevSift could not determine the final rollback state.",
  ]

  // Exact English keys intentionally keep paths, identifiers, SF Symbols, and
  // Core-owned confirmation statement identifiers out of the translation layer.
  private static let koreanCatalog: [String: String] = [
    // App, navigation, and shared controls.
    "Accounting uncertainty": "용량 계산 불확실성",
    "Analysis and review · No files changed in this state": "분석 및 검토 · 이 단계에서는 파일이 변경되지 않음",
    "Analysis only — no files will be changed.": "분석만 수행 — 파일은 변경되지 않습니다.",
    "Auto": "자동",
    "Attempt result": "작업 결과",
    "Back to Selection": "선택으로 돌아가기",
    "Cancel": "취소",
    "Cancellation": "취소",
    "Clear": "지우기",
    "Done": "완료",
    "Dismiss": "닫기",
    "Dry run": "모의 실행",
    "English": "영어",
    "Failed": "실패",
    "Final Confirmation…": "최종 확인…",
    "OK": "확인",
    "Korean": "한국어",
    "Language": "언어",
    "Other": "기타",
    "Ready": "준비됨",
    "Refresh": "새로 고침",
    "Rescan": "다시 스캔",
    "Rescan and Review": "다시 스캔하고 검토",
    "Review": "검토",
    "Scan Again": "다시 스캔",
    "System": "시스템",
    "Try Again": "다시 시도",
    "Unavailable": "사용할 수 없음",
    "Unknown": "알 수 없음",
    "Tool": "도구",
    "approval": "승인",
    "authorization preparation": "권한 준비",
    "changed during observation": "관찰 중 변경됨",
    "clock skew": "시계 오차",
    "entries": "항목",
    "entry": "항목",
    "incomplete scan": "불완전한 스캔",
    "invalid metadata": "잘못된 메타데이터",
    "issue": "문제",
    "issues": "문제",
    "more than the UI can format": "UI에서 표시할 수 있는 범위를 초과함",
    "name": "이름",
    "names": "이름",
    "not collected": "수집되지 않음",
    "one-time authorization": "일회성 권한",
    "permission denied": "권한 거부됨",
    "resource limit": "리소스 제한",
    "review confirmation": "검토 확인",
    "unspecified": "지정되지 않음",
    "unsupported": "지원되지 않음",
    "Choose the language used by DevSift": "DevSift에서 사용할 언어를 선택하세요",
    "hard-link-adjusted allocation is partial": "하드 링크 보정 할당 용량이 일부만 계산됨",
    "npm Recovery & Cleanup": "npm 복구 및 정리",

    // Scan and storage observation.
    "Allocation": "할당 용량",
    "Analyzing read-only storage policies": "읽기 전용 저장 공간 정책 분석 중",
    "Apparent allocated bytes": "표시상 할당 바이트",
    "Changed during scan": "스캔 중 변경됨",
    "Choose one folder to observe its filesystem metadata and largest top-level items.":
      "파일 시스템 메타데이터와 가장 큰 최상위 항목을 확인할 폴더 하나를 선택하세요.",
    "Choose the only folder DevSift will scan": "DevSift가 스캔할 단일 폴더 선택",
    "Complete observation": "완전한 관찰",
    "Complete": "완료",
    "Contents skipped": "내용 건너뜀",
    "Depth limit reached": "깊이 제한에 도달함",
    "Distribution of apparent allocation across the largest observed top-level items":
      "관찰된 가장 큰 최상위 항목의 표시상 할당 용량 분포",
    "Earlier descendant totals and scan issues were discarded; their total is unknown.":
      "이전 하위 항목 합계와 스캔 문제는 폐기되어 전체 수를 알 수 없습니다.",
    "Entries": "항목",
    "Entry limit reached": "항목 수 제한에 도달함",
    "Estimate degraded": "추정 정확도 저하",
    "Exact total unavailable": "정확한 합계를 알 수 없음",
    "File": "파일",
    "Folder": "폴더",
    "Folder selection failed": "폴더 선택 실패",
    "Hard-link-adjusted allocation": "하드 링크 보정 할당 용량",
    "Hard-link-adjusted allocation is partial.": "하드 링크 보정 할당 용량이 일부만 계산되었습니다.",
    "Included": "포함됨",
    "Includes selected folder": "선택한 폴더 포함",
    "Item disappeared": "항목이 사라짐",
    "Item skipped": "항목 건너뜀",
    "Item": "항목",
    "Kind": "종류",
    "Largest observed items unavailable": "관찰된 가장 큰 항목을 확인할 수 없음",
    "Largest observed items": "관찰된 가장 큰 항목",
    "Largest observed top-level items with observation and policy status":
      "관찰 및 정책 상태가 포함된 가장 큰 최상위 항목",
    "Link-adjusted": "링크 보정",
    "List folder": "폴더 나열",
    "Measure size": "크기 측정",
    "Metadata unavailable": "메타데이터를 알 수 없음",
    "No telemetry": "원격 측정 없음",
    "No top-level items observed": "관찰된 최상위 항목 없음",
    "Non-exclusive hard-link files": "비독점 하드 링크 파일",
    "Not available": "사용할 수 없음",
    "Observation": "관찰",
    "Observation integrity": "관찰 무결성",
    "Observed allocation": "관찰된 할당 용량",
    "Observed allocation is not guaranteed reclaimable. Hard links, clones, snapshots, compression, unreadable paths, and concurrent changes can affect actual free space.":
      "관찰된 할당 용량만큼 확보된다고 보장할 수 없습니다. 하드 링크, 클론, 스냅샷, 압축, 읽을 수 없는 경로 및 동시 변경이 실제 여유 공간에 영향을 줄 수 있습니다.",
    "Observed apparent allocation": "관찰된 표시상 할당 용량",
    "Observed entries": "관찰된 항목",
    "Observed file-level estimate": "관찰된 파일 단위 추정값",
    "Observed logical bytes": "관찰된 논리 바이트",
    "Observed logical size": "관찰된 논리 크기",
    "Observed metadata": "관찰된 메타데이터",
    "Observed quantities and uncertainty": "관찰된 용량과 불확실성",
    "One or more root size totals overflowed; exact values are unavailable.":
      "하나 이상의 루트 크기 합계가 범위를 초과해 정확한 값을 알 수 없습니다.",
    "Outside selected folder": "선택한 폴더 외부",
    "Overflow": "범위 초과",
    "Partial accounting": "일부만 계산됨",
    "Partial metadata": "일부 메타데이터만 확인됨",
    "Partial observation": "일부만 관찰됨",
    "Partial scan — some entries or accounting details were not observed.":
      "일부 스캔 — 몇몇 항목이나 용량 정보는 관찰되지 않았습니다.",
    "Partial scan and read-only policy analysis complete. Some observation details are unavailable. Results are ready.":
      "일부 스캔과 읽기 전용 정책 분석이 완료되었습니다. 몇몇 관찰 세부 정보는 확인할 수 없습니다. 결과를 확인할 수 있습니다.",
    "Partial scan. Some entries or accounting details were not observed":
      "일부만 스캔됨. 몇몇 항목이나 용량 정보는 관찰되지 않았습니다",
    "Partial": "일부",
    "Permission denied": "권한 거부됨",
    "Possible shared-content files": "공유 가능 콘텐츠 파일",
    "Read metadata": "메타데이터 읽기",
    "Reading filesystem metadata. File contents are never opened.":
      "파일 시스템 메타데이터를 읽는 중입니다. 파일 내용은 열지 않습니다.",
    "Resource limit reached": "리소스 제한에 도달함",
    "Scan and read-only policy analysis complete. Results are ready.":
      "스캔과 읽기 전용 정책 분석이 완료되었습니다. 결과를 확인할 수 있습니다.",
    "Scan cancelled": "스캔 취소됨",
    "Scan cancelled. No files were changed.": "스캔이 취소되었습니다. 변경된 파일은 없습니다.",
    "Scan complete within configured limits": "설정된 제한 내에서 스캔 완료",
    "Scan in progress": "스캔 중",
    "A symbolic link cannot be used as the scan root.":
      "심볼릭 링크는 스캔 루트로 사용할 수 없습니다.",
    "The scan root changed while it was being validated.":
      "스캔 루트를 검증하는 동안 루트가 변경되었습니다.",
    "The scan root could not be read.": "스캔 루트를 읽을 수 없습니다.",
    "The scan root does not exist.": "스캔 루트가 존재하지 않습니다.",
    "The scan root must be a directory.": "스캔 루트는 디렉터리여야 합니다.",
    "The scan root must be an absolute local file URL.":
      "스캔 루트는 절대 경로의 로컬 파일 URL이어야 합니다.",
    "Scan unavailable": "스캔할 수 없음",
    "Scanner observation · independent policy assessment": "스캐너 관찰 · 독립적인 정책 평가",
    "Scanning filesystem metadata": "파일 시스템 메타데이터 스캔 중",
    "Scans the same selected folder again": "선택한 동일 폴더를 다시 스캔",
    "Select Folder…": "폴더 선택…",
    "Shared metadata unavailable": "공유 메타데이터를 알 수 없음",
    "Size overflow": "크기 범위 초과",
    "Stops the active scan or policy analysis at the next cancellation checkpoint":
      "다음 취소 확인 지점에서 진행 중인 스캔 또는 정책 분석 중지",
    "Symbolic link": "심볼릭 링크",
    "The entry limit was reached. Descendant totals, top-level details, and earlier scan notes were discarded; only the selected folder inode remains in the diagnostic report.":
      "항목 수 제한에 도달했습니다. 하위 항목 합계, 최상위 세부 정보와 이전 스캔 메모는 폐기되었으며 진단 보고서에는 선택한 폴더의 inode만 남습니다.",
    "The scan could not be completed": "스캔을 완료할 수 없습니다",
    "The scan stopped without changing files.": "파일을 변경하지 않고 스캔을 중단했습니다.",
    "The selected folder contained no entries within the configured scan scope.":
      "선택한 폴더의 설정된 스캔 범위에 항목이 없습니다.",
    "The selected folder could not be read.": "선택한 폴더를 읽을 수 없습니다.",
    "The selected folder inode is included, so top-level rows may not sum to the root total.":
      "선택한 폴더의 inode가 포함되어 최상위 행의 합계가 루트 합계와 다를 수 있습니다.",
    "The storage observation finished, but its read-only policy report is unavailable. No files were changed.":
      "저장 공간 관찰은 끝났지만 읽기 전용 정책 보고서를 사용할 수 없습니다. 변경된 파일은 없습니다.",
    "The storage scan has finished. DevSift is comparing exact filesystem names with versioned, read-only rules.":
      "저장 공간 스캔이 끝났습니다. DevSift가 정확한 파일 시스템 이름을 버전이 지정된 읽기 전용 규칙과 비교 중입니다.",
    "This folder could not be scanned": "이 폴더를 스캔할 수 없습니다",
    "Top-level apparent allocation distribution": "최상위 항목의 표시상 할당 용량 분포",
    "Top-level details exceeded the configured reporting limit.":
      "최상위 세부 정보가 설정된 보고 제한을 초과했습니다.",
    "Top-level details suppressed": "최상위 세부 정보 생략됨",
    "Understand what's taking space.": "저장 공간을 무엇이 차지하는지 확인하세요.",
    "Unobserved hard-link files": "관찰되지 않은 하드 링크 파일",
    "Validate folder": "폴더 검증",
    "Validation limit reached": "검증 제한에 도달함",
    "Volume boundary": "볼륨 경계",
    "You can cancel safely at any time. Scanning stops at the next checkpoint.":
      "언제든 안전하게 취소할 수 있습니다. 다음 확인 지점에서 스캔이 중단됩니다.",

    // Read-only policy analysis and evidence.
    "A generated-content marker identifies reproducible output.":
      "생성 콘텐츠 마커가 재생성 가능한 출력임을 식별합니다.",
    "A recognized rule result was invalid, so this item remains protected.":
      "인식된 규칙 결과가 잘못되어 이 항목은 보호 상태로 유지됩니다.",
    "Activity information failed or was unavailable in a way this policy does not defer.":
      "작업 상태 정보를 가져오지 못했거나 이 정책에서 보류할 수 없는 방식으로 사용할 수 없습니다.",
    "Activity was not observed. Review can continue only with a pending user-attestation requirement; this is not inactivity evidence.":
      "작업 상태가 관찰되지 않았습니다. 사용자 확인 요구 사항을 보류한 상태에서만 검토를 계속할 수 있으며, 이는 비활성 상태의 근거가 아닙니다.",
    "All non-deferred evidence was satisfied. Activity remains unobserved, so review may continue only with the recorded execution precondition; this does not prove inactivity or grant execution authority.":
      "보류되지 않은 모든 근거가 충족되었습니다. 작업 상태는 여전히 관찰되지 않았으므로 기록된 실행 전제 조건이 있을 때만 검토를 계속할 수 있습니다. 이는 비활성 상태를 입증하거나 실행 권한을 부여하지 않습니다.",
    "All required evidence was satisfied, but this rule requires explicit review.":
      "모든 필수 근거가 충족되었지만 이 규칙은 명시적인 검토를 요구합니다.",
    "All required evidence was satisfied; the item is classified as reclaimable.":
      "모든 필수 근거가 충족되어 이 항목은 회수 가능으로 분류되었습니다.",
    "Allocated size is known for every observed item in this summary.":
      "이 요약에서 관찰된 모든 항목의 할당 크기를 알고 있습니다.",
    "An exact raw `Package.swift` sibling identifies a Swift package root.":
      "정확한 원시 이름의 `Package.swift` 형제 항목이 Swift 패키지 루트임을 식별합니다.",
    "At least one recognized rule returned missing, duplicate, unexpected, mismatched, oversized, or empty findings.":
      "인식된 규칙 중 하나 이상이 누락, 중복, 예상 밖, 불일치, 크기 제한 초과 또는 빈 근거를 반환했습니다.",
    "Conditional reproducibility cannot be automatically reclaimable.":
      "조건부 재생성 가능 항목은 자동으로 회수 가능할 수 없습니다.",
    "Conflicting rules": "충돌하는 규칙",
    "Duplicate observation": "중복 관찰",
    "Duplicate observations conflict, so this raw path remains protected.":
      "중복 관찰이 충돌하므로 이 원시 경로는 보호 상태로 유지됩니다.",
    "Every strict descendant stably matches the pinned cacache raw path-and-kind grammar, stays on the selected root device, and is owned by the current non-root POSIX account; `tmp` is empty and regular files have one link. This does not inspect contents, ACLs, extended attributes, flags, creator, or tool provenance.":
      "모든 엄격한 하위 항목이 고정된 cacache 원시 경로 및 종류 문법과 안정적으로 일치하고, 선택한 루트 장치에 유지되며, 현재 비루트 POSIX 계정이 소유합니다. `tmp`는 비어 있고 일반 파일의 링크 수는 1입니다. 이는 콘텐츠, ACLs, 확장 속성, 플래그, 생성자 또는 도구 출처를 검사하지 않습니다.",
    "Exact raw `content-v2` and `index-v5` directory children form the supported cacache layout signature.":
      "정확한 원시 이름의 `content-v2` 및 `index-v5` 디렉터리 하위 항목이 지원되는 cacache 레이아웃 서명을 구성합니다.",
    "Hard-link accounting is complete.": "하드 링크 용량 계산이 완료되었습니다.",
    "Homebrew cache": "Homebrew 캐시",
    "Invalid rule result": "잘못된 규칙 결과",
    "iOS DeviceSupport version": "iOS DeviceSupport 버전",
    "More than one rule recognized this exact raw path.":
      "둘 이상의 규칙이 이 정확한 원시 경로를 인식했습니다.",
    "Multiple rules recognized this item, so it remains protected.":
      "여러 규칙이 이 항목을 인식했으므로 보호 상태로 유지됩니다.",
    "No built-in rule recognized this exact raw filesystem path.":
      "기본 제공 규칙 중 이 정확한 원시 파일 시스템 경로를 인식한 규칙이 없습니다.",
    "No protected descendant is present in the candidate scope.":
      "후보 범위에 보호된 하위 항목이 없습니다.",
    "No rule recognized this item, so it remains protected.":
      "이 항목을 인식한 규칙이 없어 보호 상태로 유지됩니다.",
    "No scan issues were suppressed.": "생략된 스캔 문제가 없습니다.",
    "npm content cache": "npm 콘텐츠 캐시",
    "Reliable tool activity information is unavailable.":
      "신뢰할 수 있는 도구 작업 상태 정보를 사용할 수 없습니다.",
    "Reproducibility is conditional and therefore requires review.":
      "재생성 가능성이 조건부이므로 검토가 필요합니다.",
    "SwiftPM build output": "SwiftPM 빌드 출력",
    "The candidate identity could not be rebound safely to the scan-time identity.":
      "후보의 현재 식별 정보를 스캔 당시 식별 정보에 안전하게 다시 연결하지 못했습니다.",
    "The candidate identity did not match the scan-time identity.":
      "후보의 현재 식별 정보가 스캔 당시 식별 정보와 일치하지 않았습니다.",
    "The candidate identity matched the scan-time identity.":
      "후보의 현재 식별 정보가 스캔 당시 식별 정보와 일치했습니다.",
    "The candidate itself is an observed directory.": "후보 자체가 관찰된 디렉터리입니다.",
    "The candidate item observation is complete.": "후보 항목 관찰이 완료되었습니다.",
    "The candidate raw name must be exactly `.build`.":
      "후보의 원시 이름은 정확히 `.build`여야 합니다.",
    "The candidate raw name must be exactly `DerivedData`.":
      "후보의 원시 이름은 정확히 `DerivedData`여야 합니다.",
    "The candidate raw name must be exactly `Homebrew`.":
      "후보의 원시 이름은 정확히 `Homebrew`여야 합니다.",
    "The candidate raw name must be exactly `_cacache`.":
      "후보의 원시 이름은 정확히 `_cacache`여야 합니다.",
    "The candidate raw name must be exactly `uv`.":
      "후보의 원시 이름은 정확히 `uv`여야 합니다.",
    "The classifier received the same exact raw path more than once.":
      "분류기에 동일한 정확한 원시 경로가 두 번 이상 전달되었습니다.",
    "The containing scan report is complete.": "이 항목을 포함한 스캔 보고서가 완전합니다.",
    "The content age could not be represented safely.":
      "콘텐츠 경과 시간을 안전하게 표현할 수 없습니다.",
    "The location is a trusted container for this tool.":
      "이 위치는 해당 도구에 대해 신뢰할 수 있는 컨테이너입니다.",
    "The name matched, but required evidence was failed or unknown; the item remains protected.":
      "이름은 일치했지만 필수 근거가 실패했거나 확인되지 않아 항목은 보호 상태로 유지됩니다.",
    "The newest content modification time is in the future.":
      "가장 최근 콘텐츠 수정 시간이 미래 시점입니다.",
    "The newest content modification time is unavailable.":
      "가장 최근 콘텐츠 수정 시간을 확인할 수 없습니다.",
    "The newest observed content is more recent than the rule permits.":
      "관찰된 최신 콘텐츠가 규칙에서 허용하는 것보다 최근에 수정되었습니다.",
    "The newest observed content meets the minimum age requirement.":
      "관찰된 최신 콘텐츠가 최소 경과 시간 요구 사항을 충족합니다.",
    "The observed item is owned by the responsible tool workflow.":
      "관찰된 항목은 담당 도구의 작업 흐름이 소유합니다.",
    "The responsible tool is active and user confirmation cannot override it.":
      "담당 도구가 실행 중이며 사용자 확인으로 이 상태를 무시할 수 없습니다.",
    "The responsible tool is active.": "담당 도구가 실행 중입니다.",
    "The responsible tool is known to be inactive.": "담당 도구가 실행 중이 아닌 것으로 확인되었습니다.",
    "The rule declares this generated data reproducible.":
      "규칙에서 이 생성 데이터가 재생성 가능하다고 선언합니다.",
    "The rule does not establish that this data is reproducible.":
      "규칙에서 이 데이터가 재생성 가능함을 입증하지 않습니다.",
    "The rule result was invalid, so this item remains protected.":
      "규칙 결과가 잘못되어 이 항목은 보호 상태로 유지됩니다.",
    "The rule returned missing, duplicate, unexpected, mismatched, or empty findings.":
      "규칙이 누락, 중복, 예상 밖, 불일치 또는 빈 근거를 반환했습니다.",
    "The selected root and candidate directories are owned by the current non-root POSIX account; this does not establish creator or tool provenance, descendant ownership, or writability.":
      "선택한 루트 및 후보 디렉터리를 현재 비루트 POSIX 계정이 소유합니다. 이는 생성자나 도구 출처, 하위 항목 소유권 또는 쓰기 가능 여부를 입증하지 않습니다.",
    "The selected root raw name must be exactly `iOS DeviceSupport` and the child must have a version-like raw name.":
      "선택한 루트의 원시 이름은 정확히 `iOS DeviceSupport`여야 하며 하위 항목은 버전 형식의 원시 이름을 가져야 합니다.",
    "The summary size did not overflow.": "요약 크기에 범위 초과가 발생하지 않았습니다.",
    "The top-level scan output was not suppressed.":
      "최상위 스캔 출력이 생략되지 않았습니다.",
    "This rule does not require an activity check.":
      "이 규칙은 작업 상태 확인을 요구하지 않습니다.",
    "This rule does not require an age threshold.":
      "이 규칙은 경과 시간 기준을 요구하지 않습니다.",
    "This rule protects the item.": "이 규칙은 항목을 보호합니다.",
    "Traversal details were retained.": "탐색 세부 정보가 유지되었습니다.",
    "uv cache": "uv 캐시",
    "Activity remains unobserved": "작업 중지 여부가 확인되지 않음",
    "Activity requirement": "작업 중지 요구 사항",
    "A conflicting result did not contain a blocking finding.":
      "충돌 결과에 차단 근거가 없습니다.",
    "A conflicting result identified only one matching rule revision.":
      "충돌 결과에서 일치하는 규칙 버전이 하나만 확인되었습니다.",
    "A conflicting result repeated a matching rule revision.":
      "충돌 결과에 일치하는 규칙 버전이 중복되었습니다.",
    "A conflicting result reported a non-protected disposition.":
      "충돌 결과가 보호되지 않는 처리 상태를 보고했습니다.",
    "A conflicting result unexpectedly selected one rule revision.":
      "충돌 결과에서 예기치 않게 규칙 버전 하나가 선택되었습니다.",
    "A matched policy evaluation contains an unsatisfied finding that is not deferred.":
      "일치한 정책 평가에 보류되지 않은 미충족 근거가 있습니다.",
    "A matched policy evaluation contains no positive evidence.":
      "일치한 정책 평가에 긍정 근거가 없습니다.",
    "A matched policy evaluation contains no satisfied exclusion check.":
      "일치한 정책 평가에 충족된 제외 검사가 없습니다.",
    "A matched policy evaluation did not identify its rule revision.":
      "일치한 정책 평가에서 규칙 버전을 확인하지 못했습니다.",
    "A matched policy evaluation did not name exactly the same single rule revision.":
      "일치한 정책 평가가 정확히 동일한 단일 규칙 버전을 지정하지 않았습니다.",
    "A matched policy evaluation has unknown reproducibility.":
      "일치한 정책 평가의 재생성 가능성을 알 수 없습니다.",
    "A matched policy evaluation reported a protected disposition.":
      "일치한 정책 평가가 보호 처리 상태를 보고했습니다.",
    "A possible match did not contain a blocking finding.":
      "일치 가능성이 있는 결과에 차단 근거가 없습니다.",
    "A possible match did not identify its rule revision.":
      "일치 가능성이 있는 결과에서 규칙 버전을 확인하지 못했습니다.",
    "A possible match did not name exactly the same single rule revision.":
      "일치 가능성이 있는 결과가 정확히 동일한 단일 규칙 버전을 지정하지 않았습니다.",
    "A possible match reported a non-protected disposition.":
      "일치 가능성이 있는 결과가 보호되지 않는 처리 상태를 보고했습니다.",
    "A reclaimable policy evaluation did not establish reproducibility.":
      "회수 가능한 정책 평가에서 재생성 가능성을 입증하지 못했습니다.",
    "An invalid-rule result did not contain a blocking finding.":
      "잘못된 규칙 결과에 차단 근거가 없습니다.",
    "An invalid-rule result did not identify an affected rule revision.":
      "잘못된 규칙 결과에서 영향받는 규칙 버전을 확인하지 못했습니다.",
    "An invalid-rule result did not name exactly the same single rule revision.":
      "잘못된 규칙 결과가 정확히 동일한 단일 규칙 버전을 지정하지 않았습니다.",
    "An invalid-rule result repeated an affected rule revision.":
      "잘못된 규칙 결과에 영향받는 규칙 버전이 중복되었습니다.",
    "An invalid-rule result reported a non-protected disposition.":
      "잘못된 규칙 결과가 보호되지 않는 처리 상태를 보고했습니다.",
    "An unrecognized result did not contain a blocking finding.":
      "인식되지 않은 결과에 차단 근거가 없습니다.",
    "An unrecognized result reported a non-protected disposition.":
      "인식되지 않은 결과가 보호되지 않는 처리 상태를 보고했습니다.",
    "An unrecognized result unexpectedly identified a matching rule.":
      "인식되지 않은 결과에서 예기치 않게 일치하는 규칙이 확인되었습니다.",
    "Adds this exact path and rule revision to an unapproved in-memory draft":
      "이 정확한 경로와 규칙 버전을 승인되지 않은 메모리 내 초안에 추가",
    "Advisory only — this release cannot clean, approve, quarantine, or delete files.":
      "안내 전용 — 이 릴리스에서는 파일을 정리, 승인, 격리 또는 삭제할 수 없습니다.",
    "Age requirement": "경과 시간 요구 사항",
    "Canonical raw-path order": "정규 원시 경로 순서",
    "Collapsed": "접힘",
    "Collapses partial scan details and retained issues": "일부 스캔 세부 정보와 보관된 문제 접기",
    "Collapses the draft evidence": "초안 근거 접기",
    "Collapses the rule identifier, explanation, and structured evidence":
      "규칙 식별자, 설명 및 구조화된 근거 접기",
    "Conditional": "조건부",
    "Conflict": "충돌",
    "Creates an unapproved, read-only draft without changing files":
      "파일을 변경하지 않고 승인되지 않은 읽기 전용 초안 생성",
    "Draft cleanup plan": "정리 계획 초안",
    "Draft entries": "초안 항목",
    "Expanded": "펼침",
    "Expands partial scan details and retained issues": "일부 스캔 세부 정보와 보관된 문제 펼치기",
    "Expands the draft evidence": "초안 근거 펼치기",
    "Expands the rule identifier, explanation, and structured evidence":
      "규칙 식별자, 설명 및 구조화된 근거 펼치기",
    "Invalid rule": "잘못된 규칙",
    "Malformed policy result": "잘못 구성된 정책 결과",
    "Malformed result": "잘못 구성된 결과",
    "Matched": "일치",
    "Missing evidence stays protected. A versioned rule may expose deliberately unobserved activity only as a pending execution requirement.":
      "근거가 부족한 항목은 보호됩니다. 버전이 지정된 규칙은 의도적으로 관찰하지 않은 작업을 보류 중인 실행 요구 사항으로만 표시할 수 있습니다.",
    "Name recognition": "이름 인식",
    "No eligible draft candidates": "초안에 포함할 수 있는 후보 없음",
    "No policy evaluation was returned for this exact raw path.":
      "이 정확한 원시 경로에 대한 정책 평가가 반환되지 않았습니다.",
    "Multiple policy evaluations were returned for this exact raw path.":
      "이 정확한 원시 경로에 대해 여러 정책 평가가 반환되었습니다.",
    "No policy result was returned for this exact raw path, so the item remains protected.":
      "이 정확한 원시 경로에 대한 정책 결과가 없어 항목이 보호 상태로 유지됩니다.",
    "No structured rule evidence is available for this item.":
      "이 항목에 사용할 수 있는 구조화된 규칙 근거가 없습니다.",
    "Not eligible for the dry run": "모의 실행 대상이 아님",
    "Not included": "포함되지 않음",
    "Nothing currently meets every planning requirement.":
      "현재 모든 계획 요구 사항을 충족하는 항목이 없습니다.",
    "Pending execution requirements": "보류 중인 실행 요구 사항",
    "The pending activity requirement is policy metadata, not evidence that a tool is inactive. Any future recoverable operation requires fresh revalidation and a separate, attempt-scoped authorization. This draft does not provide that authorization.":
      "보류 중인 작업 중지 요구 사항은 정책 메타데이터일 뿐 도구가 비활성 상태라는 근거가 아닙니다. 향후 복구 가능한 작업에는 새 검증과 별도의 작업 한정 권한이 필요합니다. 이 초안은 해당 권한을 제공하지 않습니다.",
    "The policy evaluation contains invalid deferred execution requirements.":
      "정책 평가에 잘못된 보류 실행 요구 사항이 있습니다.",
    "The policy evaluation contains no structured findings.":
      "정책 평가에 구조화된 근거가 없습니다.",
    "Policy analysis could not be completed": "정책 분석을 완료할 수 없음",
    "Policy analysis in progress": "정책 분석 중",
    "Policy explanation": "정책 설명",
    "Policy findings": "정책 근거",
    "Policy result validation": "정책 결과 검증",
    "Policy": "정책",
    "Possible match": "일치 가능성 있음",
    "Protected-content check": "보호 콘텐츠 확인",
    "Protected": "보호됨",
    "Reclaimable classification": "회수 가능 분류",
    "Reclaimable": "회수 가능",
    "Reproducibility": "재생성 가능성",
    "Reproducible": "재생성 가능",
    "Required evidence": "필수 근거",
    "Review first — no files have changed yet": "먼저 검토하세요 — 아직 변경된 파일은 없습니다",
    "Review required": "검토 필요",
    "Rule conflict": "규칙 충돌",
    "Rule validity": "규칙 유효성",
    "Rule": "규칙",
    "Satisfied": "충족됨",
    "Select an observed item to inspect its policy explanation.":
      "관찰된 항목을 선택해 정책 설명을 확인하세요.",
    "Selected items": "선택한 항목",
    "Selection is not approval. No files will be changed.":
      "선택은 승인이 아닙니다. 파일은 변경되지 않습니다.",
    "Structured policy evidence": "구조화된 정책 근거",
    "The Policy column remains visible for every item": "모든 항목에 정책 열이 계속 표시됨",
    "This item does not meet every Core planning requirement.":
      "이 항목은 Core의 모든 계획 요구 사항을 충족하지 않습니다.",
    "Unapproved draft review": "승인되지 않은 초안 검토",
    "Unapproved draft": "승인되지 않은 초안",
    "Unrecognized data": "인식되지 않은 데이터",
    "Unrecognized": "인식되지 않음",

    // Draft review and recoverable quarantine.
    "A safe quarantine destination could not be reserved without overwriting.":
      "덮어쓰지 않고 사용할 수 있는 안전한 격리 위치를 확보하지 못했습니다.",
    "A safe rollback could not be completed.": "안전한 롤백을 완료하지 못했습니다.",
    "Attempt rejected · Permanent deletion disabled": "작업 거부됨 · 영구 삭제 비활성화됨",
    "Cancelling restore confirmation": "복원 확인 취소 중",
    "DevSift could not create a complete in-memory draft from this scan. Nothing was approved or changed.":
      "이 스캔에서 완전한 메모리 내 초안을 만들지 못했습니다. 승인되거나 변경된 항목은 없습니다.",
    "DevSift could not open the folder picker result. Select the folder again.":
      "DevSift가 폴더 선택 결과를 열지 못했습니다. 폴더를 다시 선택하세요.",
    "DevSift could not create a safe, unique quarantine destination.":
      "안전하고 고유한 격리 위치를 만들지 못했습니다.",
    "DevSift could not determine the final rollback state.": "최종 롤백 상태를 확인하지 못했습니다.",
    "DevSift could not determine whether the private quarantine directory was created.":
      "비공개 격리 디렉터리가 생성되었는지 확인하지 못했습니다.",
    "DevSift could not establish a supported non-root account for this operation.":
      "이 작업에 지원되는 비루트 계정을 확인하지 못했습니다.",
    "DevSift could not finish the required durable record. Inspect recovery details before another operation.":
      "필수 영구 기록을 완료하지 못했습니다. 다른 작업 전에 복구 세부 정보를 확인하세요.",
    "DevSift could not open its trusted npm recovery location.":
      "신뢰된 npm 복구 위치를 열지 못했습니다.",
    "DevSift created its private npm quarantine directory during this attempt.":
      "이번 작업에서 DevSift의 비공개 npm 격리 디렉터리를 생성했습니다.",
    "DevSift is repeating its filesystem safety checks and recording the transaction. Closing the window requests cancellation, but reconciliation may continue if the protected rename has already started.":
      "DevSift가 파일 시스템 안전 검사를 다시 수행하고 트랜잭션을 기록 중입니다. 창을 닫으면 취소를 요청하지만 보호된 이름 변경이 이미 시작되었다면 조정이 계속될 수 있습니다.",
    "Discarding the prepared one-time authority before another action is enabled.":
      "다른 작업을 활성화하기 전에 준비된 일회성 권한을 폐기하는 중입니다.",
    "Discards this review presentation and returns to your selected items":
      "이 검토 화면을 닫고 선택한 항목으로 돌아가기",
    "Draft preparation cancelled. No files were changed.":
      "초안 준비가 취소되었습니다. 변경된 파일은 없습니다.",
    "Draft preparation in progress": "초안 준비 중",
    "Draft review unavailable": "초안 검토를 사용할 수 없음",
    "Draft review unavailable. No files were changed.":
      "초안 검토를 사용할 수 없습니다. 변경된 파일은 없습니다.",
    "Draft unavailable": "초안을 사용할 수 없음",
    "Guaranteed savings": "보장되는 확보 용량",
    "I reviewed every selected entry and pending requirement shown above.":
      "위에 표시된 모든 선택 항목과 보류 중인 요구 사항을 검토했습니다.",
    "I stopped npm work using this cache. I understand DevSift did not observe inactivity.":
      "이 캐시를 사용하는 npm 작업을 중지했습니다. DevSift가 비활성 상태를 직접 확인하지 않았음을 이해합니다.",
    "Move needs recovery": "이동 작업 복구 필요",
    "Move the reviewed npm cache to quarantine?": "검토한 npm 캐시를 격리하시겠습니까?",
    "Move to Quarantine": "격리로 이동",
    "Move was rolled back": "이동이 롤백됨",
    "Moved to quarantine": "격리로 이동됨",
    "Moving the reviewed npm cache to quarantine": "검토한 npm 캐시를 격리로 이동 중",
    "No durable transaction record was established.": "영구 트랜잭션 기록이 생성되지 않았습니다.",
    "Open Recovery…": "복구 열기…",
    "Opens the final confirmation for a recoverable move, not permanent deletion":
      "영구 삭제가 아닌 복구 가능한 이동의 최종 확인 열기",
    "Post-move validation did not match the reviewed object, so DevSift safely moved it back.":
      "이동 후 검증 결과가 검토한 객체와 일치하지 않아 DevSift가 안전하게 되돌렸습니다.",
    "Post-move validation was unavailable, so DevSift safely moved the item back.":
      "이동 후 검증을 수행할 수 없어 DevSift가 항목을 안전하게 되돌렸습니다.",
    "Protected permanent deletion is unavailable on this platform.":
      "이 플랫폼에서는 보호된 영구 삭제를 사용할 수 없습니다.",
    "Preparing draft": "초안 준비 중",
    "Preparing the in-memory draft": "메모리 내 초안 준비 중",
    "Quarantine attempt did not start": "격리 작업이 시작되지 않음",
    "Quarantine attempt finished": "격리 작업 완료",
    "Quarantine attempt in progress": "격리 작업 진행 중",
    "Quarantine did not start": "격리가 시작되지 않음",
    "Quarantine did not start. Rescan and review before trying again.":
      "격리가 시작되지 않았습니다. 다시 시도하기 전에 재스캔하고 검토하세요.",
    "Quarantine is a same-volume move and frees 0 B. Restore and receipt-bound permanent deletion are separate. Capacity change may be zero; DevSift provides neither secure erase nor guaranteed reclaimed space.":
      "격리는 같은 볼륨 내 이동이므로 확보되는 용량은 0 B입니다. 복원과 영수증에 연결된 영구 삭제는 별개입니다. 용량 변화가 0일 수 있으며 DevSift는 보안 삭제나 저장 공간 확보를 보장하지 않습니다.",
    "Quarantine is not deletion · 0 B guaranteed freed": "격리는 삭제가 아님 · 보장 확보 용량 0 B",
    "Quarantine is not permanent deletion": "격리는 영구 삭제가 아님",
    "Recoverable move only · Permanent deletion disabled": "복구 가능한 이동만 가능 · 영구 삭제 비활성화됨",
    "Recoverable npm quarantine": "복구 가능한 npm 격리",
    "Recoverable quarantine in progress": "복구 가능한 격리 진행 중",
    "Recoverable quarantine requires macOS 26 or newer. Scanning and draft review remain available.":
      "복구 가능한 격리는 macOS 26 이상이 필요합니다. 스캔과 초안 검토는 계속 사용할 수 있습니다.",
    "Recoverable quarantine started. Permanent deletion is disabled. Reconciliation may continue after cancellation.":
      "복구 가능한 격리를 시작했습니다. 영구 삭제는 비활성화되어 있습니다. 취소 후에도 조정 작업이 계속될 수 있습니다.",
    "Review Draft…": "초안 검토…",
    "This build can quarantine only one reviewed npm _cacache from the current account's exact ~/.npm folder.":
      "이 빌드에서는 현재 계정의 정확한 ~/.npm 폴더에 있는 검토된 npm _cacache 하나만 격리할 수 있습니다.",
    "This in-memory snapshot is not approval and may already be stale. If you continue, Core will bind this exact review to a one-time attempt and freshly revalidate the root, item, and policy evidence before any move.":
      "이 메모리 내 스냅샷은 승인이 아니며 이미 오래된 정보일 수 있습니다. 계속하면 Core가 이 정확한 검토를 일회성 작업에 연결하고 이동 전에 루트, 항목 및 정책 근거를 새로 검증합니다.",
    "This one-time attempt asserts that npm work using this cache is stopped while DevSift has not observed inactivity. It moves one exact _cacache into private quarantine; it does not permanently delete files or free disk space.":
      "이 일회성 작업은 DevSift가 비활성 상태를 확인하지 못한 상황에서 사용자가 이 캐시를 쓰는 npm 작업을 중지했다고 확인하는 것입니다. 정확한 _cacache 하나를 비공개 격리로 이동하며 파일을 영구 삭제하거나 저장 공간을 확보하지 않습니다.",
    "This recoverable operation requires macOS 26 or newer.":
      "이 복구 가능한 작업은 macOS 26 이상이 필요합니다.",

    // Recovery inventory, restore, and permanent deletion.
    "A durable intent exists, but Core did not observe the staging rename committed. Refresh to reconcile the exact namespace state.":
      "영구 의도 기록이 있지만 Core가 스테이징 이름 변경의 완료를 확인하지 못했습니다. 정확한 네임스페이스 상태를 조정하려면 새로 고치세요.",
    "A durable intent exists, but a terminal receipt is still pending.":
      "영구 의도 기록이 있지만 최종 영수증은 아직 대기 중입니다.",
    "A permanent deletion intent is durable, but no terminal receipt is available yet.":
      "영구 삭제 의도는 기록되었지만 최종 영수증은 아직 없습니다.",
    "A restore intent was recorded, but no terminal receipt is available yet.":
      "복원 의도는 기록되었지만 최종 영수증은 아직 없습니다.",
    "A possible quarantine location was observed. ": "가능한 격리 위치가 관찰되었습니다. ",
    "A separate confirmation is required to continue deletion.":
      "삭제를 계속하려면 별도의 확인이 필요합니다.",
    "A staged deletion remainder is available for a separately confirmed retry. Restore is no longer available for this item.":
      "별도로 확인한 재시도에서 삭제할 수 있는 스테이징 잔여 항목이 있습니다. 이 항목은 더 이상 복원할 수 없습니다.",
    "A staging rename may have been invoked. Refresh to reconcile the exact namespace state before another action.":
      "스테이징 이름 변경이 실행되었을 수 있습니다. 다른 작업 전에 새로 고쳐 정확한 네임스페이스 상태를 조정하세요.",
    "A terminal permanent deletion receipt already exists for this item.":
      "이 항목에는 이미 최종 영구 삭제 영수증이 있습니다.",
    "A terminal receipt records that this attempt did not stage or delete the item. Use the refreshed inventory before choosing another action.":
      "최종 영수증에 이번 작업에서 항목을 스테이징하거나 삭제하지 않았다고 기록되었습니다. 다른 작업을 선택하기 전에 새로 고친 목록을 사용하세요.",
    "A terminal receipt was durably recorded.": "최종 영수증이 영구 기록되었습니다.",
    "A terminal receipt was validated and completed by recovery.":
      "최종 영수증이 검증되었고 복구를 통해 완료되었습니다.",
    "A terminal restore receipt was completed by journal recovery.":
      "최종 복원 영수증이 저널 복구로 완료되었습니다.",
    "A terminal restore receipt was durably recorded.": "최종 복원 영수증이 영구 기록되었습니다.",
    "Another DevSift quarantine or restore operation currently holds the journal lock.":
      "다른 DevSift 격리 또는 복원 작업이 현재 저널 잠금을 사용 중입니다.",
    "Another object now uses the original name. DevSift will not overwrite it.":
      "다른 객체가 원래 이름을 사용 중입니다. DevSift는 덮어쓰지 않습니다.",
    "Another object occupies the original npm cache name. DevSift will not overwrite it.":
      "다른 객체가 원래 npm 캐시 이름을 사용 중입니다. DevSift는 덮어쓰지 않습니다.",
    "Another recovery operation holds the journal lock. Try again after it finishes.":
      "다른 복구 작업이 저널 잠금을 사용 중입니다. 완료된 후 다시 시도하세요.",
    "Another recovery operation holds the journal lock.":
      "다른 복구 작업이 저널 잠금을 사용 중입니다.",
    "Cache already present": "캐시가 이미 있음",
    "Cache restored": "캐시 복원됨",
    "Cache was not restored": "캐시가 복원되지 않음",
    "Cancelling permanent deletion confirmation": "영구 삭제 확인 취소 중",
    "Cancels the pending confirmation, then reconciles and loads a new bounded inventory":
      "대기 중인 확인을 취소한 뒤 조정하고 제한된 새 목록 불러오기",
    "Confirm no-overwrite restore": "덮어쓰기 없는 복원 확인",
    "Confirm permanent deletion retry": "영구 삭제 재시도 확인",
    "Confirm permanent deletion": "영구 삭제 확인",
    "Continue Deletion…": "삭제 계속…",
    "Continue Permanent Deletion": "영구 삭제 계속",
    "Continuing permanent deletion": "영구 삭제 계속 진행 중",
    "Core could not obtain the mandatory pre-intent capacity observation.":
      "Core가 의도 기록 전 필수 용량 관찰값을 가져오지 못했습니다.",
    "Core could not obtain the required same-volume capacity sample, so no new purge intent was authorized.":
      "Core가 같은 볼륨의 필수 용량 표본을 가져오지 못해 새 삭제 의도를 승인하지 않았습니다.",
    "Core did not report an observed unlink linearization during this pass.":
      "Core가 이번 작업에서 unlink 선형화 관찰을 보고하지 않았습니다.",
    "Core is executing one bounded, receipt-bound pass. If it stops after staging, the refreshed inventory will require a new explicit retry.":
      "Core가 제한된 영수증 연결 작업을 한 번 실행 중입니다. 스테이징 후 중단되면 새로 고친 목록에서 명시적인 재시도가 필요합니다.",
    "Core is validating a frozen selection snapshot.":
      "Core가 고정된 선택 스냅샷을 검증 중입니다.",
    "Core is freshly validating the exact receipt-bound journal evidence, trusted descriptors, current account, and same-volume capacity observation.":
      "Core가 정확한 영수증 연결 저널 근거, 신뢰된 디스크립터, 현재 계정 및 같은 볼륨의 용량 관찰값을 새로 검증 중입니다.",
    "Core is freshly validating the journal, source name, quarantined contents, and trusted parent bindings.":
      "Core가 저널, 원본 이름, 격리된 내용 및 신뢰된 상위 바인딩을 새로 검증 중입니다.",
    "Core is performing a protected no-overwrite rename and recording the bounded result.":
      "Core가 덮어쓰기 방지 이름 변경을 수행하고 제한된 결과를 기록 중입니다.",
    "Core observed bounded unlink progress, but an exact staged remainder still exists.":
      "Core가 제한된 unlink 진행을 관찰했지만 정확한 스테이징 잔여 항목이 남아 있습니다.",
    "Core observed the receipt-bound quarantine and staged-work names absent and recorded the bounded outcome.":
      "Core가 영수증에 연결된 격리 및 스테이징 작업 이름이 없음을 확인하고 제한된 결과를 기록했습니다.",
    "Core rejected inconsistent terminal deletion evidence.":
      "Core가 일관되지 않은 최종 삭제 근거를 거부했습니다.",
    "Core rejected the one-time permanent deletion authorization.":
      "Core가 일회성 영구 삭제 권한을 거부했습니다.",
    "Core rejected the one-time restore authorization.": "Core가 일회성 복원 권한을 거부했습니다.",
    "Core reported a restore without complete terminal safety evidence. Review the refreshed inventory before taking another action.":
      "Core가 완전한 최종 안전 근거 없이 복원을 보고했습니다. 다른 작업 전에 새로 고친 목록을 검토하세요.",
    "Core staged the exact item but did not observe an unlink linearization in this pass.":
      "Core가 정확한 항목을 스테이징했지만 이번 작업에서 unlink 선형화를 관찰하지 못했습니다.",
    "Durability": "영구 기록 상태",
    "Exact Core-required statement": "Core가 요구한 정확한 문구",
    "Exact staged deletion remainder": "정확한 스테이징 삭제 잔여 항목",
    "Explicitly load and reconcile the fixed npm quarantine inventory":
      "고정된 npm 격리 목록을 명시적으로 불러오고 조정",
    "Filesystem changes may have occurred, but Core could not establish durable terminal evidence.":
      "파일 시스템 변경이 발생했을 수 있지만 Core가 영구적인 최종 근거를 확립하지 못했습니다.",
    "I accept that restore becomes unavailable after staging and that deletion may be partial.":
      "스테이징 후 복원이 불가능해지고 일부만 삭제될 수 있음을 인정합니다.",
    "I accept that the capacity reading is only observational, may show zero change or be unavailable, and cannot be attributed to DevSift.":
      "용량 수치는 관찰값일 뿐이며 변화가 0이거나 확인할 수 없을 수 있고 DevSift의 결과로 단정할 수 없음을 인정합니다.",
    "I accept that these are the current quarantined contents and may include changes made after quarantine.":
      "이것이 현재 격리된 내용이며 격리 후 변경 사항이 포함될 수 있음을 인정합니다.",
    "I confirm the exact Core-required statement shown above.":
      "위에 표시된 Core 필수 문구를 정확히 확인했습니다.",
    "I confirm the exact statement above and understand this is permanent deletion, not secure erase.":
      "위 문구를 정확히 확인했으며 이것이 보안 삭제가 아닌 영구 삭제임을 이해합니다.",
    "I stopped npm and other work using this cache. I accept unobserved activity, post-quarantine changes, and same-account races.":
      "이 캐시를 사용하는 npm 및 기타 작업을 중지했습니다. 관찰되지 않은 활동, 격리 후 변경 및 동일 계정 내 경합 위험을 인정합니다.",
    "I stopped npm work using this cache. I understand DevSift did not observe inactivity and another process could still access it.":
      "이 캐시를 사용하는 npm 작업을 중지했습니다. DevSift가 비활성 상태를 확인하지 않았으며 다른 프로세스가 계속 접근할 수 있음을 이해합니다.",
    "Incomplete permanent deletions": "완료되지 않은 영구 삭제",
    "Inventory load cancelled": "목록 불러오기 취소됨",
    "Journal reconciliation required": "저널 조정 필요",
    "Load and Reconcile": "불러오고 조정",
    "Load the recovery and cleanup inventory": "복구 및 정리 목록 불러오기",
    "Loading is explicit: DevSift will acquire the journal lock, reconcile incomplete receipts, and inspect only its fixed current-account npm quarantine. Nothing is deleted while loading.":
      "불러오기는 명시적으로 실행됩니다. DevSift가 저널 잠금을 획득하고 완료되지 않은 영수증을 조정한 뒤 현재 계정의 고정된 npm 격리 위치만 검사합니다. 불러오는 동안에는 아무것도 삭제하지 않습니다.",
    "Loading recovery and cleanup inventory": "복구 및 정리 목록 불러오는 중",
    "Manual recovery is required": "수동 복구가 필요함",
    "Manual recovery required": "수동 복구 필요",
    "No disk space was reclaimed": "확보된 디스크 공간 없음",
    "No filesystem paths, journal transaction IDs, or raw journal bytes are displayed. Permanent deletion never targets the active npm cache and does not claim secure erasure, attribution, or guaranteed reclaimed capacity.":
      "파일 시스템 경로, 저널 트랜잭션 ID 또는 원시 저널 바이트는 표시되지 않습니다. 영구 삭제는 활성 npm 캐시를 대상으로 하지 않으며 보안 삭제, 결과 귀속 또는 용량 확보를 보장하지 않습니다.",
    "No permanent deletion activity was observed during this pass.":
      "이번 작업에서 영구 삭제 활동이 관찰되지 않았습니다.",
    "No permanent deletion intent or terminal receipt was recorded.":
      "영구 삭제 의도나 최종 영수증이 기록되지 않았습니다.",
    "No permanent deletion was performed": "영구 삭제가 수행되지 않음",
    "No quarantined npm cache": "격리된 npm 캐시 없음",
    "No restore intent or terminal receipt was recorded.":
      "복원 의도나 최종 영수증이 기록되지 않았습니다.",
    "No trustworthy quarantine location could be reported. ":
      "신뢰할 수 있는 격리 위치를 보고할 수 없습니다. ",
    "Observed absence and capacity change do not prove secure erasure, attribution, or reclaimed storage.":
      "항목이 보이지 않고 용량이 변했다는 사실만으로 보안 삭제, 결과 귀속 또는 저장 공간 확보를 입증할 수 없습니다.",
    "Observed same-volume available capacity was unchanged. A zero-byte increase is a valid outcome.":
      "관찰된 같은 볼륨의 여유 용량이 변하지 않았습니다. 0바이트 증가는 정상적인 결과입니다.",
    "Observed values are estimates. Quarantine moves an item on the same volume and guarantees 0 B of freed capacity; only a later permanent purge can reclaim disk space.":
      "관찰값은 추정치입니다. 격리는 같은 볼륨에서 항목을 이동하므로 확보 용량은 0 B이며, 이후 영구 삭제를 해야 디스크 공간을 확보할 수 있습니다.",
    "Original location is clear": "원래 위치가 비어 있음",
    "Original location occupied": "원래 위치가 사용 중",
    "Permanent deletion activity was observed during this pass.":
      "이번 작업에서 영구 삭제 활동이 관찰되었습니다.",
    "Permanent deletion authorization rejected": "영구 삭제 권한 거부됨",
    "Permanent deletion could not be prepared": "영구 삭제를 준비할 수 없음",
    "Permanent deletion did not execute": "영구 삭제가 실행되지 않음",
    "Permanent deletion is incomplete": "영구 삭제가 완료되지 않음",
    "Permanently Delete": "영구 삭제",
    "Permanently Delete…": "영구 삭제…",
    "Permanently deleting quarantined contents": "격리된 내용 영구 삭제 중",
    "Preparing deletion retry": "삭제 재시도 준비 중",
    "Preparing permanent deletion": "영구 삭제 준비 중",
    "Preparing restore": "복원 준비 중",
    "Quarantine namespace": "격리 네임스페이스",
    "Quarantined contents available": "격리된 내용을 사용할 수 있음",
    "Quarantined contents changed": "격리된 내용이 변경됨",
    "Quarantined contents missing": "격리된 내용이 없음",
    "Quarantined contents unsafe": "격리된 내용이 안전하지 않음",
    "Quarantined contents were not purged": "격리된 내용이 삭제되지 않음",
    "Quarantined item is absent": "격리된 항목이 없음",
    "Quarantined item is durably recorded absent": "격리된 항목이 없다고 영구 기록됨",
    "Ready to prepare permanent deletion of the exact quarantined contents.":
      "정확한 격리 내용을 영구 삭제할 준비가 되었습니다.",
    "Ready to restore without overwriting an existing item.":
      "기존 항목을 덮어쓰지 않고 복원할 준비가 되었습니다.",
    "Receipt-bound operations only · no arbitrary paths · no overwrite":
      "영수증에 연결된 작업만 가능 · 임의 경로 사용 안 함 · 덮어쓰기 안 함",
    "Reconciled inventory": "조정된 목록",
    "Regular-file links adjusted": "일반 파일 링크 보정됨",
    "Reconciles the journal and loads a new bounded inventory":
      "저널을 조정하고 제한된 새 목록 불러오기",
    "Reconciling durable journal state before any restore or deletion option is shown.":
      "복원 또는 삭제 옵션을 표시하기 전에 영구 저널 상태를 조정하는 중입니다.",
    "Recovery is unavailable": "복구를 사용할 수 없음",
    "Recovery journal is busy": "복구 저널 사용 중",
    "Recovery location rejected": "복구 위치 거부됨",
    "Recovery location unavailable": "복구 위치를 사용할 수 없음",
    "Recovery…": "복구…",
    "Restore Current Contents": "현재 내용 복원",
    "Restore authorization rejected": "복원 권한 거부됨",
    "Restore could not be prepared": "복원을 준비할 수 없음",
    "Restore did not execute": "복원이 실행되지 않음",
    "Restore needs verification": "복원 검증 필요",
    "Restore result · no overwrite · no deletion authority used":
      "복원 결과 · 덮어쓰기 없음 · 삭제 권한 사용 안 함",
    "Restore…": "복원…",
    "Restoring current contents": "현재 내용 복원 중",
    "Runs one receipt-bound permanent deletion pass after all four acknowledgements are selected":
      "네 가지 확인을 모두 선택한 뒤 영수증에 연결된 영구 삭제 작업을 한 번 실행",
    "The current quarantined contents passed the bounded inventory checks.":
      "현재 격리된 내용이 제한된 목록 검사를 통과했습니다.",
    "The exact quarantined contents are no longer available.":
      "정확한 격리 내용을 더 이상 사용할 수 없습니다.",
    "The exact quarantined item was no longer available.":
      "정확한 격리 항목을 더 이상 사용할 수 없습니다.",
    "The exact staged deletion remainder is no longer available.":
      "정확한 스테이징 삭제 잔여 항목을 더 이상 사용할 수 없습니다.",
    "The exact staged deletion remainder was no longer available.":
      "정확한 스테이징 삭제 잔여 항목을 더 이상 사용할 수 없었습니다.",
    "The reconciled inventory changed. Refresh it before choosing another action.":
      "조정된 목록이 변경되었습니다. 다른 작업을 선택하기 전에 새로 고치세요.",
    "The reconciled journal contains no current item that can be restored, permanently deleted, or retried.":
      "조정된 저널에 현재 복원, 영구 삭제 또는 재시도할 수 있는 항목이 없습니다.",
    "These exact staged remainders cannot be restored. Each continuation requires a new, separate confirmation.":
      "이 정확한 스테이징 잔여 항목은 복원할 수 없습니다. 계속할 때마다 새롭고 별도의 확인이 필요합니다.",
    "This is not secure erase: APFS snapshots or clones, backups, open file descriptors, and storage-device behavior may retain data or blocks.":
      "보안 삭제가 아닙니다. APFS 스냅샷 또는 클론, 백업, 열린 파일 디스크립터 및 저장 장치 동작으로 인해 데이터나 블록이 남을 수 있습니다.",
    "This item was already restored.": "이 항목은 이미 복원되었습니다.",
    "Wait for the current quarantine reconciliation to finish":
      "현재 격리 조정이 완료될 때까지 기다리기",

    // Safety, validation, journal, and execution failures.
    "A bounded operating-system or journal resource limit was reached.":
      "운영 체제 또는 저널의 제한된 리소스 한도에 도달했습니다.",
    "A filesystem path changed during final validation. Rescan before trying again.":
      "최종 검증 중 파일 시스템 경로가 변경되었습니다. 다시 시도하기 전에 재스캔하세요.",
    "A filesystem safety check rejected the current cache or quarantine directory.":
      "파일 시스템 안전 검사가 현재 캐시 또는 격리 디렉터리를 거부했습니다.",
    "A parent directory changed during the operation.": "작업 중 상위 디렉터리가 변경되었습니다.",
    "A required descriptor-relative observation was unavailable.":
      "필수 디스크립터 상대 관찰값을 사용할 수 없습니다.",
    "A trusted parent binding changed after restore preparation.":
      "복원 준비 후 신뢰된 상위 바인딩이 변경되었습니다.",
    "A trusted parent binding changed during permanent deletion.":
      "영구 삭제 중 신뢰된 상위 바인딩이 변경되었습니다.",
    "A trusted parent binding changed during the restore.":
      "복원 중 신뢰된 상위 바인딩이 변경되었습니다.",
    "A trusted post-attempt capacity comparison was unavailable.":
      "작업 후 신뢰할 수 있는 용량 비교값을 사용할 수 없습니다.",
    "A trusted recovery binding changed after confirmation.":
      "확인 후 신뢰된 복구 바인딩이 변경되었습니다.",
    "An unexpected error occurred. No files were changed.":
      "예기치 않은 오류가 발생했습니다. 변경된 파일은 없습니다.",
    "Another object also occupies the original name.": "다른 객체도 원래 이름을 사용 중입니다.",
    " Another object also occupies the original name.": " 다른 객체도 원래 이름을 사용 중입니다.",
    "Cancellation arrived after a rename; Core completed bounded reconciliation before reporting this result.":
      "이름 변경 후 취소 요청이 도착했습니다. Core는 이 결과를 보고하기 전에 제한된 조정을 완료했습니다.",
    "Cancellation was observed during this pass. Core's bounded result and the refreshed inventory determine the safe next action.":
      "이번 작업 중 취소가 관찰되었습니다. Core의 제한된 결과와 새로 고친 목록을 기준으로 다음 안전한 작업을 결정하세요.",
    "Cancellation was requested after the move boundary. DevSift finished reconciliation before reporting this result.":
      "이동 경계 이후 취소가 요청되었습니다. DevSift는 이 결과를 보고하기 전에 조정을 완료했습니다.",
    "Core could not allocate bounded internal state for this attempt.":
      "Core가 이번 작업에 필요한 제한된 내부 상태를 할당하지 못했습니다.",
    "Core could not allocate bounded internal state for this deletion attempt.":
      "Core가 이번 삭제 작업에 필요한 제한된 내부 상태를 할당하지 못했습니다.",
    "Core could not determine a unique safe quarantine namespace outcome.":
      "Core가 고유하고 안전한 격리 네임스페이스 결과를 확인하지 못했습니다.",
    "Core could not determine the final outcome of the protected rename.":
      "Core가 보호된 이름 변경의 최종 결과를 확인하지 못했습니다.",
    "Input/output failure": "입출력 오류",
    "Item was not moved": "항목이 이동되지 않음",
    "Journal durability state is unresolved.": "저널 영구 기록 상태를 확인할 수 없습니다.",
    "macOS denied access before a safe move could be completed.":
      "안전한 이동을 완료하기 전에 macOS가 접근을 거부했습니다.",
    "Required filesystem metadata was invalid or unavailable.":
      "필수 파일 시스템 메타데이터가 잘못되었거나 사용할 수 없습니다.",
    "The bounded execution boundary rejected the attempt. Rescan and review again.":
      "제한된 실행 경계가 작업을 거부했습니다. 다시 스캔하고 검토하세요.",
    "The bounded final traversal reached its safety limit.":
      "제한된 최종 순회가 안전 한도에 도달했습니다.",
    "The bounded final validation reached its traversal limit.":
      "제한된 최종 검증이 순회 한도에 도달했습니다.",
    "The bounded safety traversal ended before deletion could be approved.":
      "삭제를 승인하기 전에 제한된 안전 순회가 종료되었습니다.",
    "The bounded safety traversal ended before the item could be approved.":
      "항목을 승인하기 전에 제한된 안전 순회가 종료되었습니다.",
    "The bounded synchronization pass limit was reached.":
      "제한된 동기화 작업 횟수 한도에 도달했습니다.",
    "The bounded terminal verification reached its traversal limit.":
      "제한된 최종 검증이 순회 한도에 도달했습니다.",
    "The bounded traversal limit was reached.": "제한된 순회 한도에 도달했습니다.",
    "The bounded validation limit was reached before restore could be approved.":
      "복원을 승인하기 전에 제한된 검증 한도에 도달했습니다.",
    "The attempt was cancelled before a move was admitted.":
      "이동이 허용되기 전에 작업이 취소되었습니다.",
    "The attempt was cancelled before execution authority was consumed.":
      "실행 권한이 사용되기 전에 작업이 취소되었습니다.",
    "The cache exceeded DevSift's bounded validation limits.":
      "캐시가 DevSift의 제한된 검증 한도를 초과했습니다.",
    "The cache no longer satisfies the minimum age requirement.":
      "캐시가 더 이상 최소 경과 시간 요구 사항을 충족하지 않습니다.",
    "The confirmation did not belong to the current permanent deletion attempt.":
      "확인 정보가 현재 영구 삭제 작업에 속하지 않습니다.",
    "The confirmation did not belong to the current restore attempt.":
      "확인 정보가 현재 복원 작업에 속하지 않습니다.",
    "The confirmation did not match the exact statement requested by Core.":
      "확인 정보가 Core가 요청한 정확한 문구와 일치하지 않습니다.",
    "The current account no longer matches the account bound to this recovery operation.":
      "현재 계정이 이 복구 작업에 연결된 계정과 더 이상 일치하지 않습니다.",
    "The current account or a trusted recovery binding changed.":
      "현재 계정 또는 신뢰된 복구 바인딩이 변경되었습니다.",
    "The deletion preparation was cancelled without granting purge authority.":
      "삭제 권한을 부여하지 않고 삭제 준비가 취소되었습니다.",
    "The durable journal evidence changed before execution.":
      "실행 전에 영구 저널 근거가 변경되었습니다.",
    "The durable journal evidence did not pass safety validation.":
      "영구 저널 근거가 안전 검증을 통과하지 못했습니다.",
    "The durable journal is unresolved and blocks another conflicting operation.":
      "영구 저널이 미해결 상태여서 충돌하는 다른 작업이 차단됩니다.",
    "The durable purge journal must be reconciled before another action can be offered.":
      "다른 작업을 제공하기 전에 영구 삭제 저널을 조정해야 합니다.",
    "The durable records changed during terminal verification.":
      "최종 검증 중 영구 기록이 변경되었습니다.",
    "The durable recovery records did not pass safety validation.":
      "영구 복구 기록이 안전 검증을 통과하지 못했습니다.",
    "The execution was cancelled. The refreshed inventory is the authority for any next action.":
      "실행이 취소되었습니다. 다음 작업은 새로 고친 목록을 기준으로 해야 합니다.",
    "The filesystem cannot perform the required protected restore rename.":
      "파일 시스템에서 필수 보호 복원 이름 변경을 수행할 수 없습니다.",
    "The filesystem change may have completed, but a durable terminal receipt could not be recorded.":
      "파일 시스템 변경이 완료되었을 수 있지만 영구 최종 영수증을 기록하지 못했습니다.",
    "The filesystem could not durably synchronize the observed progress.":
      "파일 시스템에서 관찰된 진행 상태를 영구 동기화하지 못했습니다.",
    "The filesystem has insufficient space for the transaction journal.":
      "트랜잭션 저널을 위한 파일 시스템 공간이 부족합니다.",
    "The filesystem is read-only.": "파일 시스템이 읽기 전용입니다.",
    "The filesystem rejected a bounded unlink operation.":
      "파일 시스템이 제한된 unlink 작업을 거부했습니다.",
    "The filesystem rejected the operation without a safe, specific diagnosis.":
      "파일 시스템이 안전하고 구체적인 진단 없이 작업을 거부했습니다.",
    "The filesystem rejected the protected restore rename.":
      "파일 시스템이 보호된 복원 이름 변경을 거부했습니다.",
    "The filesystem rejected the protected staging rename.":
      "파일 시스템이 보호된 스테이징 이름 변경을 거부했습니다.",
    "The filesystem reported an input/output failure.": "파일 시스템이 입출력 오류를 보고했습니다.",
    "The inventory changed. Refresh it before attempting another restore.":
      "목록이 변경되었습니다. 다시 복원하기 전에 새로 고치세요.",
    "The item or one of its trusted parent bindings did not pass validation.":
      "항목 또는 신뢰된 상위 바인딩 중 하나가 검증을 통과하지 못했습니다.",
    "The journal contains an unresolved operation that DevSift cannot safely resolve automatically.":
      "저널에 DevSift가 안전하게 자동 해결할 수 없는 미해결 작업이 있습니다.",
    "The journal durability state is unresolved.":
      "저널 영구 기록 상태를 확인할 수 없습니다.",
    "The journal failed its safety checks. Do not edit its files; inspect recovery details first.":
      "저널이 안전 검사를 통과하지 못했습니다. 파일을 편집하지 말고 먼저 복구 세부 정보를 확인하세요.",
    "The journal inventory changed before the restore executed.":
      "복원을 실행하기 전에 저널 목록이 변경되었습니다.",
    "The journal requires manual recovery before another restore can begin.":
      "다른 복원을 시작하기 전에 저널을 수동으로 복구해야 합니다.",
    "The load stopped before a current inventory was published. Open recovery again to reconcile the latest durable journal state.":
      "현재 목록이 게시되기 전에 불러오기가 중단되었습니다. 복구를 다시 열어 최신 영구 저널 상태를 조정하세요.",
    "The managed quarantine namespace changed during the pass.":
      "작업 중 관리되는 격리 네임스페이스가 변경되었습니다.",
    "The object moved back to the source name did not match the reviewed object.":
      "원본 이름으로 되돌린 객체가 검토한 객체와 일치하지 않습니다.",
    "The one-time authorization did not match the current permanent deletion attempt.":
      "일회성 권한이 현재 영구 삭제 작업과 일치하지 않습니다.",
    "The one-time authorization did not match the current restore attempt.":
      "일회성 권한이 현재 복원 작업과 일치하지 않습니다.",
    "The one-time authorization did not match this execution attempt. Rescan and review again.":
      "일회성 권한이 이번 실행 작업과 일치하지 않습니다. 다시 스캔하고 검토하세요.",
    "The one-time permanent deletion authorization was already used.":
      "일회성 영구 삭제 권한이 이미 사용되었습니다.",
    "The one-time restore authorization was already used.": "일회성 복원 권한이 이미 사용되었습니다.",
    "The operation was cancelled and Core did not report a completed restore.":
      "작업이 취소되었으며 Core가 완료된 복원을 보고하지 않았습니다.",
    "The original _cacache name is currently unoccupied.":
      "현재 원래 _cacache 이름이 비어 있습니다.",
    "The original _cacache name is occupied. DevSift did not overwrite it.":
      "원래 _cacache 이름이 사용 중입니다. DevSift는 덮어쓰지 않았습니다.",
    "The original _cacache name is occupied. DevSift will not overwrite it.":
      "원래 _cacache 이름이 사용 중입니다. DevSift는 덮어쓰지 않습니다.",
    "The original cache location could not be verified after the restore attempt.":
      "복원 작업 후 원래 캐시 위치를 검증하지 못했습니다.",
    "The original location contains the previously expected object. Restore is blocked.":
      "원래 위치에 이전에 예상한 객체가 있어 복원이 차단됩니다.",
    "The original npm cache name could not be verified after the move attempt.":
      "이동 작업 후 원래 npm 캐시 이름을 검증하지 못했습니다.",
    "The original quarantine transaction is no longer eligible for permanent deletion.":
      "원래 격리 트랜잭션은 더 이상 영구 삭제 대상이 아닙니다.",
    "The pass stopped after cancellation was observed.": "취소가 확인된 후 작업이 중단되었습니다.",
    "The pass was cancelled before a new irreversible namespace operation was reported.":
      "되돌릴 수 없는 새 네임스페이스 작업이 보고되기 전에 작업이 취소되었습니다.",
    "The permanent deletion attempt was cancelled.": "영구 삭제 작업이 취소되었습니다.",
    "The permanent deletion journal durability state is unresolved.":
      "영구 삭제 저널의 영구 기록 상태를 확인할 수 없습니다.",
    "The platform cannot perform the required protected permanent deletion operation.":
      "이 플랫폼에서 필수 보호 영구 삭제 작업을 수행할 수 없습니다.",
    "The prepared permanent deletion evidence was no longer valid. Refresh the inventory.":
      "준비된 영구 삭제 근거가 더 이상 유효하지 않습니다. 목록을 새로 고치세요.",
    "The prepared restore evidence was no longer valid. Refresh the inventory.":
      "준비된 복원 근거가 더 이상 유효하지 않습니다. 목록을 새로 고치세요.",
    "The quarantine destination could not be verified after the move attempt.":
      "이동 작업 후 격리 위치를 검증하지 못했습니다.",
    "The quarantine journal no longer has a trusted structure.":
      "격리 저널이 더 이상 신뢰할 수 있는 구조가 아닙니다.",
    "The quarantined contents changed after authorization.": "권한 부여 후 격리된 내용이 변경되었습니다.",
    "The quarantined contents changed after confirmation.": "확인 후 격리된 내용이 변경되었습니다.",
    "The quarantined contents changed after this inventory was loaded.":
      "이 목록을 불러온 후 격리된 내용이 변경되었습니다.",
    "The quarantined contents no longer match the recorded restore evidence.":
      "격리된 내용이 기록된 복원 근거와 더 이상 일치하지 않습니다.",
    "The quarantined item could not be verified after the restore attempt.":
      "복원 작업 후 격리된 항목을 검증하지 못했습니다.",
    "The quarantined item failed final safety validation.":
      "격리된 항목이 최종 안전 검증을 통과하지 못했습니다.",
    "The quarantined item failed the final safety validation.":
      "격리된 항목이 최종 안전 검증을 통과하지 못했습니다.",
    "The quarantined item or a trusted parent binding failed validation.":
      "격리된 항목 또는 신뢰된 상위 바인딩이 검증을 통과하지 못했습니다.",
    "The recorded quarantined contents are missing.": "기록된 격리 내용이 없습니다.",
    "The recorded quarantined contents are no longer available.":
      "기록된 격리 내용을 더 이상 사용할 수 없습니다.",
    "The recorded quarantined item is no longer available.":
      "기록된 격리 항목을 더 이상 사용할 수 없습니다.",
    "The recovery journal no longer has a trusted structure.":
      "복구 저널이 더 이상 신뢰할 수 있는 구조가 아닙니다.",
    "The recovery journal was unavailable.": "복구 저널을 사용할 수 없습니다.",
    "The rename result is indeterminate. Recovery must inspect the current namespaces.":
      "이름 변경 결과를 확정할 수 없습니다. 복구에서 현재 네임스페이스를 검사해야 합니다.",
    "The restore attempt was cancelled.": "복원 작업이 취소되었습니다.",
    "The restore execution was cancelled.": "복원 실행이 취소되었습니다.",
    "The restore preparation was cancelled without changing files.":
      "파일을 변경하지 않고 복원 준비가 취소되었습니다.",
    "The reviewed filesystem object changed. Rescan before trying again.":
      "검토한 파일 시스템 객체가 변경되었습니다. 다시 시도하기 전에 재스캔하세요.",
    "The reviewed npm cache is no longer present.": "검토한 npm 캐시가 더 이상 없습니다.",
    "The reviewed npm cache was durably quarantined, but another object now occupies its original name. Review the recovery inventory before restoring.":
      "검토한 npm 캐시가 영구 기록과 함께 격리되었지만 다른 객체가 원래 이름을 사용 중입니다. 복원 전에 복구 목록을 검토하세요.",
    "The reviewed npm cache was moved out of npm's active namespace and a terminal receipt was recorded. It can be considered for an explicit restore.":
      "검토한 npm 캐시를 npm의 활성 네임스페이스 밖으로 이동하고 최종 영수증을 기록했습니다. 명시적인 복원을 검토할 수 있습니다.",
    "The reviewed plan no longer matches the supported quarantine policy. Rescan and review again.":
      "검토한 계획이 더 이상 지원되는 격리 정책과 일치하지 않습니다. 다시 스캔하고 검토하세요.",
    "The source and quarantine directory are not on the same filesystem.":
      "원본과 격리 디렉터리가 같은 파일 시스템에 있지 않습니다.",
    "The staged deletion remainder changed after confirmation.":
      "확인 후 스테이징 삭제 잔여 항목이 변경되었습니다.",
    "The staged deletion remainder changed after this inventory was loaded.":
      "이 목록을 불러온 후 스테이징 삭제 잔여 항목이 변경되었습니다.",
    "The staged deletion remainder changed during terminal verification.":
      "최종 검증 중 스테이징 삭제 잔여 항목이 변경되었습니다.",
    "The staged deletion remainder failed terminal safety validation.":
      "스테이징 삭제 잔여 항목이 최종 안전 검증을 통과하지 못했습니다.",
    "The staged deletion remainder or its managed name failed validation.":
      "스테이징 삭제 잔여 항목 또는 관리 이름이 검증을 통과하지 못했습니다.",
    "The staged tree changed during the pass.": "작업 중 스테이징 트리가 변경되었습니다.",
    "The staged tree did not pass a safety recheck.":
      "스테이징 트리가 안전 재검사를 통과하지 못했습니다.",
    "The terminal quarantine receipt was completed by journal recovery.":
      "최종 격리 영수증이 저널 복구로 완료되었습니다.",
    "The trusted npm recovery location did not pass safety validation.":
      "신뢰된 npm 복구 위치가 안전 검증을 통과하지 못했습니다.",
    "The trusted npm recovery location was unavailable.":
      "신뢰된 npm 복구 위치를 사용할 수 없습니다.",
    "The current quarantined contents were restored without overwrite.":
      "현재 격리된 내용을 덮어쓰지 않고 복원했습니다.",
    "The current quarantined contents were restored without overwrite, but another object now occupies the former quarantine item name. Review the refreshed inventory before taking another action.":
      "현재 격리된 내용을 덮어쓰지 않고 복원했지만 다른 객체가 이전 격리 항목 이름을 사용 중입니다. 다른 작업 전에 새로 고친 목록을 검토하세요.",
    "This macOS version or filesystem does not provide the required protected rename operation.":
      "이 macOS 버전 또는 파일 시스템은 필수 보호 이름 변경 작업을 제공하지 않습니다.",
    "This macOS version or filesystem does not support the required durable operation.":
      "이 macOS 버전 또는 파일 시스템은 필수 영구 기록 작업을 지원하지 않습니다.",
    "This one-time authorization was already used. Rescan and review again.":
      "이 일회성 권한은 이미 사용되었습니다. 다시 스캔하고 검토하세요.",
    "This one-time authorization was cancelled before execution.":
      "이 일회성 권한은 실행 전에 취소되었습니다.",
    "This one-time permanent deletion attempt was already authorized.":
      "이 일회성 영구 삭제 작업은 이미 승인되었습니다.",
    "This one-time restore attempt was already authorized.":
      "이 일회성 복원 작업은 이미 승인되었습니다.",

    // Format templates used when user-visible values are inserted at runtime.
    "%@ reclaimable · %@ review": "%@개 회수 가능 · %@개 검토",
    "%lld additional issue not retained": "%lld개의 추가 문제가 보관되지 않음",
    "%lld additional issues not retained": "%lld개의 추가 문제가 보관되지 않음",
    "%lld additional scan issue was not retained.":
      "추가 스캔 문제 %lld개가 보관되지 않았습니다.",
    "%lld additional scan issues were not retained.":
      "추가 스캔 문제 %lld개가 보관되지 않았습니다.",
    "%lld entries have unknown allocation.": "%lld개 항목의 할당 용량을 알 수 없습니다.",
    "%lld entries with unknown allocation are excluded": "할당 용량을 알 수 없는 %lld개 항목 제외",
    "%lld entry has unknown allocation.": "항목 %lld개의 할당 용량을 알 수 없습니다.",
    "%lld entry with unknown allocation is excluded": "할당 용량을 알 수 없는 항목 %lld개 제외",
    "%lld file may share APFS content": "%lld개 파일이 APFS 콘텐츠를 공유할 수 있음",
    "%lld files may share APFS content": "%lld개 파일이 APFS 콘텐츠를 공유할 수 있음",
    "%lld hard-link group has links outside the observed scope":
      "%lld개 하드 링크 그룹에 관찰 범위 밖의 링크가 있음",
    "%lld hard-link groups have links outside the observed scope":
      "%lld개 하드 링크 그룹에 관찰 범위 밖의 링크가 있음",
    "%lld hard-link path receives no exclusive allocation credit":
      "%lld개 하드 링크 경로에 독점 할당 용량을 계산하지 않음",
    "%lld hard-link paths receive no exclusive allocation credit":
      "%lld개 하드 링크 경로에 독점 할당 용량을 계산하지 않음",
    "%lld item": "항목 %lld개",
    "%lld item shown": "항목 %lld개 표시",
    "%lld item with unknown allocation is excluded": "할당 용량을 알 수 없는 항목 %lld개 제외",
    "%lld items": "항목 %lld개",
    "%lld items shown": "항목 %lld개 표시",
    "%lld items with unknown allocation are excluded": "할당 용량을 알 수 없는 항목 %lld개 제외",
    "%lld of %lld included": "%2$lld개 중 %1$lld개 포함",
    "%lld reviewed item · permanent deletion disabled": "%lld개 검토 항목 · 영구 삭제 비활성화됨",
    "%lld reviewed items · permanent deletion disabled": "%lld개 검토 항목 · 영구 삭제 비활성화됨",
    "%lld scan issue shown": "스캔 문제 %lld개 표시",
    "%lld scan issues shown": "스캔 문제 %lld개 표시",
    "%lld shown": "%lld개 표시",
    "%lld top-level item was observed. Its details exceeded the configured reporting limit, so no partial subset is shown.":
      "최상위 항목 %lld개가 관찰되었습니다. 세부 정보가 설정된 보고 제한을 초과해 일부만 표시하지는 않습니다.",
    "%lld top-level items were observed. Their details exceeded the configured reporting limit, so no partial subset is shown.":
      "최상위 항목 %lld개가 관찰되었습니다. 세부 정보가 설정된 보고 제한을 초과해 일부만 표시하지는 않습니다.",
    "%llu additional issue not retained": "%llu개의 추가 문제가 보관되지 않음",
    "%llu additional issues not retained": "%llu개의 추가 문제가 보관되지 않음",
    "%llu additional scan issue was not retained.":
      "추가 스캔 문제 %llu개가 보관되지 않았습니다.",
    "%llu additional scan issues were not retained.":
      "추가 스캔 문제 %llu개가 보관되지 않았습니다.",
    "%llu B": "%llu B",
    "%llu entries have unknown allocation.": "%llu개 항목의 할당 용량을 알 수 없습니다.",
    "%llu entries with unknown allocation are excluded": "할당 용량을 알 수 없는 %llu개 항목 제외",
    "%llu entry has unknown allocation.": "항목 %llu개의 할당 용량을 알 수 없습니다.",
    "%llu entry with unknown allocation is excluded": "할당 용량을 알 수 없는 항목 %llu개 제외",
    "%llu file may share APFS content": "%llu개 파일이 APFS 콘텐츠를 공유할 수 있음",
    "%llu files may share APFS content": "%llu개 파일이 APFS 콘텐츠를 공유할 수 있음",
    "%llu hard-link group has links outside the observed scope":
      "%llu개 하드 링크 그룹에 관찰 범위 밖의 링크가 있음",
    "%llu hard-link groups have links outside the observed scope":
      "%llu개 하드 링크 그룹에 관찰 범위 밖의 링크가 있음",
    "%llu hard-link path receives no exclusive allocation credit":
      "%llu개 하드 링크 경로에 독점 할당 용량을 계산하지 않음",
    "%llu hard-link paths receive no exclusive allocation credit":
      "%llu개 하드 링크 경로에 독점 할당 용량을 계산하지 않음",
    "%llu top-level item was observed. Its details exceeded the configured reporting limit, so no partial subset is shown.":
      "최상위 항목 %llu개가 관찰되었습니다. 세부 정보가 설정된 보고 제한을 초과해 일부만 표시하지는 않습니다.",
    "%llu top-level items were observed. Their details exceeded the configured reporting limit, so no partial subset is shown.":
      "최상위 항목 %llu개가 관찰되었습니다. 세부 정보가 설정된 보고 제한을 초과해 일부만 표시하지는 않습니다.",
    "Analyzing policies for %@…": "%@의 정책 분석 중…",
    "Core invoked unlink and then observed %lld filesystem name absent during this pass.":
      "Core가 unlink를 실행한 뒤 이번 작업에서 파일 시스템 이름 %lld개가 없음을 확인했습니다.",
    "Core invoked unlink and then observed %lld filesystem names absent during this pass.":
      "Core가 unlink를 실행한 뒤 이번 작업에서 파일 시스템 이름 %lld개가 없음을 확인했습니다.",
    "Core prepared one attempt to continue deleting the exact staged remainder of %@ for %@. Restore is already unavailable for this remainder.":
      "Core가 %2$@용 정확한 스테이징 잔여 항목 %1$@의 삭제를 계속할 작업을 한 번 준비했습니다. 이 잔여 항목은 이미 복원할 수 없습니다.",
    "Core prepared one attempt to permanently delete the exact current quarantined %@ for %@. It never targets the active cache name.":
      "Core가 %2$@용 현재 격리 항목 %1$@의 영구 삭제 작업을 한 번 준비했습니다. 활성 캐시 이름은 절대 대상으로 삼지 않습니다.",
    "Core prepared one attempt to restore the current quarantined %@ for %@. It will fail rather than overwrite the original name.":
      "Core가 %2$@용 현재 격리 항목 %1$@의 복원 작업을 한 번 준비했습니다. 원래 이름을 덮어쓰지 않고 실패 처리합니다.",
    "DevSift could not complete %@. The underlying error was not retained or displayed.":
      "DevSift가 %@을(를) 완료하지 못했습니다. 근본 오류는 보관되거나 표시되지 않았습니다.",
    "DevSift did not observe whether %@ is active. Any future recoverable operation requires a separate, attempt-scoped authorization based on the user's explicit statement that they stopped the responsible tool. This draft is not that authorization and cannot be executed.":
      "DevSift는 %@의 실행 여부를 확인하지 않았습니다. 향후 복구 가능한 작업에는 사용자가 해당 도구를 중지했다는 명시적 진술에 따른 별도의 작업 한정 권한이 필요합니다. 이 초안은 그 권한이 아니며 실행할 수 없습니다.",
    "Include %@ in the dry run": "%@을(를) 모의 실행에 포함",
    "Journal recovery completed a terminal %@ receipt.":
      "저널 복구에서 최종 %@ 영수증을 완료했습니다.",
    "Match state: %@": "일치 상태: %@",
    "Observed same-volume available capacity decreased by %@; concurrent system activity may affect this value.":
      "관찰된 같은 볼륨의 여유 용량이 %@ 감소했습니다. 동시에 실행 중인 시스템 작업이 이 값에 영향을 줄 수 있습니다.",
    "Observed same-volume available capacity increased by %@; this change is not attributed to DevSift.":
      "관찰된 같은 볼륨의 여유 용량이 %@ 증가했습니다. 이 변화가 DevSift로 인한 것이라고 단정할 수 없습니다.",
    "Possible shared content %@ · shared metadata unavailable %@ · unobserved hard links %@ · non-exclusive hard links %@":
      "공유 가능 콘텐츠 %@ · 공유 메타데이터 확인 불가 %@ · 관찰되지 않은 하드 링크 %@ · 비독점 하드 링크 %@",
    "Policy disposition: %@. Match state: %@. %@": "정책 처리: %@. 일치 상태: %@. %@",
    "Preparing an in-memory draft for %lld selected entry. No files are being changed.":
      "선택한 항목 %lld개의 메모리 내 초안을 준비 중입니다. 파일은 변경되지 않습니다.",
    "Preparing an in-memory draft for %lld selected entries. No files are being changed.":
      "선택한 항목 %lld개의 메모리 내 초안을 준비 중입니다. 파일은 변경되지 않습니다.",
    "Preparing an in-memory draft for %lld selected item. No files are being changed.":
      "선택한 항목 %lld개의 메모리 내 초안을 준비 중입니다. 파일은 변경되지 않습니다.",
    "Preparing an in-memory draft for %lld selected items. No files are being changed.":
      "선택한 항목 %lld개의 메모리 내 초안을 준비 중입니다. 파일은 변경되지 않습니다.",
    "Quarantine attempt finished. %@. %@": "격리 작업이 완료되었습니다. %@. %@",
    "Quarantine is a same-volume move. No file was permanently deleted and guaranteed freed capacity is %@.":
      "격리는 같은 볼륨 내 이동입니다. 영구 삭제된 파일은 없으며 보장되는 확보 용량은 %@입니다.",
    "Scanning %@. File contents are never opened.": "%@ 스캔 중. 파일 내용은 열지 않습니다.",
    "Scanning %@…": "%@ 스캔 중…",
    "Storage scan finished. Analyzing read-only policies for %@.":
      "저장 공간 스캔이 끝났습니다. %@의 읽기 전용 정책을 분석 중입니다.",
    "shared-content metadata unavailable for %lld file":
      "%lld개 파일의 공유 콘텐츠 메타데이터를 확인할 수 없음",
    "shared-content metadata unavailable for %lld files":
      "%lld개 파일의 공유 콘텐츠 메타데이터를 확인할 수 없음",
    "shared-content metadata unavailable for %llu file":
      "%llu개 파일의 공유 콘텐츠 메타데이터를 확인할 수 없음",
    "shared-content metadata unavailable for %llu files":
      "%llu개 파일의 공유 콘텐츠 메타데이터를 확인할 수 없음",
    "The attempt was cancelled during %@. No execution result was issued; rescan before trying again.":
      "%@ 중 작업이 취소되었습니다. 실행 결과가 발행되지 않았으므로 다시 시도하기 전에 재스캔하세요.",
    "The item may have moved, but no terminal receipt proves completion. Open recovery inventory before another operation.%@":
      "항목이 이동되었을 수 있지만 완료를 입증하는 최종 영수증이 없습니다. 다른 작업 전에 복구 목록을 여세요.%@",
    "The retained review was rejected during %@. Rescan and review the current cache again.":
      "%@ 중 보관된 검토가 거부되었습니다. 현재 캐시를 다시 스캔하고 검토하세요.",
    "Unapproved draft ready with %lld entry. No files were changed.":
      "항목 %lld개의 승인되지 않은 초안이 준비되었습니다. 변경된 파일은 없습니다.",
    "Unapproved draft ready with %lld entries. No files were changed.":
      "항목 %lld개의 승인되지 않은 초안이 준비되었습니다. 변경된 파일은 없습니다.",
    "Unapproved draft ready with %lld item. No files were changed.":
      "항목 %lld개의 승인되지 않은 초안이 준비되었습니다. 변경된 파일은 없습니다.",
    "Unapproved draft ready with %lld items. No files were changed.":
      "항목 %lld개의 승인되지 않은 초안이 준비되었습니다. 변경된 파일은 없습니다.",
    "Unknown · %@": "알 수 없음 · %@",
    "%@. No files were changed.": "%@. 변경된 파일은 없습니다.",
    "A terminal %@ receipt was durably recorded.": "최종 %@ 영수증이 영구 기록되었습니다.",
    "%@ The item remains protected.": "%@ 항목은 보호 상태로 유지됩니다.",
    "item-absent": "항목 없음",
    "not-purged": "삭제되지 않음",
    "Restore is unavailable for the staged remainder; continuing requires a separate explicit confirmation from the refreshed inventory.":
      "스테이징 잔여 항목은 복원할 수 없습니다. 계속하려면 새로 고친 목록에서 별도로 다시 확인해야 합니다.",
  ]
}

private struct AppLanguageEnvironmentKey: EnvironmentKey {
  static let defaultValue: AppLanguage = .english
}

extension EnvironmentValues {
  package var appLanguage: AppLanguage {
    get { self[AppLanguageEnvironmentKey.self] }
    set { self[AppLanguageEnvironmentKey.self] = newValue }
  }
}
