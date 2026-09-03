import Foundation

/// A whole-manifest record of explicit in-memory approval intent.
///
/// Only `CleanupApprover` can issue this value. It remains copyable and does
/// not authenticate its caller, provide single-use semantics, prove human
/// review, or grant filesystem authority. Fresh execution-time revalidation is
/// always required. Stored precondition review acknowledgements are replayable
/// review intent, not proof that a pending condition is currently satisfied.
public struct CleanupApproval: Sendable {
  public static let currentContractVersion: UInt32 = 2

  public let contractVersion: UInt32
  public let sourceRoot: URL
  public let reviewedManifest: CleanupManifest
  public let preconditionReviewAcknowledgements: [CleanupApprovalPreconditionReviewAcknowledgement]

  public var requiresExecutionRevalidation: Bool { true }
  public var isSingleUse: Bool { false }
  public var isAuthenticityProof: Bool { false }
  public var grantsFilesystemMutationAuthority: Bool { false }

  fileprivate init(
    contractVersion: UInt32 = CleanupApproval.currentContractVersion,
    sourceRoot: URL,
    reviewedManifest: CleanupManifest,
    preconditionReviewAcknowledgements: [CleanupApprovalPreconditionReviewAcknowledgement]
  ) {
    self.contractVersion = contractVersion
    self.sourceRoot = sourceRoot
    self.reviewedManifest = reviewedManifest
    self.preconditionReviewAcknowledgements = preconditionReviewAcknowledgements
  }
}

public protocol CleanupApproving: Sendable {
  func beginReview(_ source: CleanupManifestRequest) throws -> CleanupApprovalReviewSession
  func approve(_ request: CleanupApprovalRequest) throws -> CleanupApproval
}

/// Creates and approves process-local whole-manifest review sessions without
/// filesystem access.
///
/// Both phases use the concrete, pure Core planner. Approval regenerates the
/// exact manifest from the retained source request; this detects substitution
/// between the reviewed value and the approval request but does not establish
/// live filesystem freshness.
public struct CleanupApprover: CleanupApproving, Sendable {
  public init() {}

  public func beginReview(
    _ source: CleanupManifestRequest
  ) throws -> CleanupApprovalReviewSession {
    try Task.checkCancellation()
    guard LocalFileSystemRootValidator.isValid(source.classificationRequest.root) else {
      throw CleanupApprovalError.invalidSourceRoot
    }

    let manifest = try CleanupPlanner().makeManifest(source)
    guard !manifest.entries.isEmpty else {
      throw CleanupApprovalError.emptyManifest
    }
    try Task.checkCancellation()

    let session = CleanupApprovalReviewSession(
      sourceRequest: source,
      reviewedManifest: manifest
    )
    try Task.checkCancellation()
    return session
  }

  public func approve(_ request: CleanupApprovalRequest) throws -> CleanupApproval {
    try Task.checkCancellation()

    let session = request.session
    let sourceRoot = session.sourceRequest.classificationRequest.root
    guard
      session.sourceRoot == sourceRoot,
      LocalFileSystemRootValidator.isValid(sourceRoot)
    else {
      throw CleanupApprovalError.invalidSourceRoot
    }

    guard !session.reviewedManifest.entries.isEmpty else {
      throw CleanupApprovalError.emptyManifest
    }
    try validateConfirmations(request.confirmations, in: session)
    try validatePreconditionReviewAcknowledgements(
      request.preconditionReviewAcknowledgements,
      in: session
    )
    try Task.checkCancellation()

    let regeneratedManifest = try CleanupPlanner().makeManifest(session.sourceRequest)
    guard regeneratedManifest == session.reviewedManifest else {
      throw CleanupApprovalError.reviewedManifestRegenerationMismatch
    }
    try Task.checkCancellation()

    let approval = CleanupApproval(
      sourceRoot: sourceRoot,
      reviewedManifest: regeneratedManifest,
      preconditionReviewAcknowledgements: request.preconditionReviewAcknowledgements
    )
    try Task.checkCancellation()
    return approval
  }

  private func validateConfirmations(
    _ confirmations: [CleanupApprovalEntryConfirmation],
    in session: CleanupApprovalReviewSession
  ) throws {
    guard confirmations.count == session.entryReferences.count else {
      throw CleanupApprovalError.confirmationCountMismatch(
        expected: session.entryReferences.count,
        actual: confirmations.count
      )
    }

    for index in session.entryReferences.indices {
      try Task.checkCancellation()
      guard session.matches(confirmations[index], at: index) else {
        throw CleanupApprovalError.confirmationMismatch(index: index)
      }
    }
  }

  private func validatePreconditionReviewAcknowledgements(
    _ acknowledgements: [CleanupApprovalPreconditionReviewAcknowledgement],
    in session: CleanupApprovalReviewSession
  ) throws {
    guard acknowledgements.count == session.preconditionReferences.count else {
      throw CleanupApprovalError.preconditionReviewAcknowledgementCountMismatch(
        expected: session.preconditionReferences.count,
        actual: acknowledgements.count
      )
    }

    for index in session.preconditionReferences.indices {
      try Task.checkCancellation()
      guard session.matches(acknowledgements[index], at: index) else {
        throw CleanupApprovalError.preconditionReviewAcknowledgementMismatch(index: index)
      }
    }
  }
}
