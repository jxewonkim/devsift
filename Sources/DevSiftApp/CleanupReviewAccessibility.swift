enum CleanupReviewAccessibility {
  static func announcement(
    from previousPhase: CleanupReviewPhase,
    to phase: CleanupReviewPhase
  ) -> String? {
    switch phase {
    case .preparing(let selectedCount):
      let noun = selectedCount == 1 ? "item" : "items"
      return
        "Preparing an in-memory draft for \(selectedCount) selected \(noun). No files are being changed."
    case .review(let review):
      let noun = review.entryCount == 1 ? "item" : "items"
      return "Unapproved draft ready with \(review.entryCount) \(noun). No files were changed."
    case .failed:
      return "Draft review unavailable. No files were changed."
    case .selecting where previousPhase.isPreparing:
      return "Draft preparation cancelled. No files were changed."
    case .unavailable, .selecting:
      return nil
    }
  }
}
