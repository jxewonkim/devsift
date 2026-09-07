enum CleanupReviewAccessibility {
  static func announcement(
    from previousPhase: CleanupReviewPhase,
    to phase: CleanupReviewPhase,
    language: AppLanguage = .english
  ) -> String? {
    switch phase {
    case .preparing(let selectedCount):
      return language.format(
        selectedCount == 1
          ? "Preparing an in-memory draft for %lld selected item. No files are being changed."
          : "Preparing an in-memory draft for %lld selected items. No files are being changed.",
        Int64(selectedCount)
      )
    case .review(let review):
      return language.format(
        review.entryCount == 1
          ? "Unapproved draft ready with %lld item. No files were changed."
          : "Unapproved draft ready with %lld items. No files were changed.",
        Int64(review.entryCount)
      )
    case .executing:
      return language.localized(
        "Recoverable quarantine started. Permanent deletion is disabled. Reconciliation may continue after cancellation."
      )
    case .executionResult(let result):
      return language.format(
        "Quarantine attempt finished. %@. %@",
        language.localized(result.title),
        language.localized(result.durabilityMessage)
      )
    case .executionFailed:
      return language.localized(
        "Quarantine did not start. Rescan and review before trying again."
      )
    case .failed:
      return language.localized("Draft review unavailable. No files were changed.")
    case .selecting where previousPhase.isPreparing:
      return language.localized("Draft preparation cancelled. No files were changed.")
    case .unavailable, .selecting:
      return nil
    }
  }
}
