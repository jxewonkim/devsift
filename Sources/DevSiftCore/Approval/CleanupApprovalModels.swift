import Foundation

/// Process-local identity shared only by one Core-issued review session and
/// its entry references. Reference identity is deliberately not serialized or
/// treated as an authenticity secret.
private final class CleanupApprovalReviewIdentity: Sendable {}

/// One entry reference issued by a specific approval review session.
///
/// The visible fields identify what the user can confirm. Equality also
/// includes the issuing session's process-local identity, so a reference from
/// another review cannot be substituted even when those fields are equal.
public struct CleanupApprovalEntryReference: Hashable, Sendable {
  public let ordinal: Int
  public let path: ScanRelativePath
  public let ruleRevision: RuleRevision

  fileprivate let reviewIdentity: CleanupApprovalReviewIdentity

  public static func == (
    left: CleanupApprovalEntryReference,
    right: CleanupApprovalEntryReference
  ) -> Bool {
    left.reviewIdentity === right.reviewIdentity
      && left.ordinal == right.ordinal
      && left.path == right.path
      && left.ruleRevision == right.ruleRevision
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(reviewIdentity))
    hasher.combine(ordinal)
    hasher.combine(path)
    hasher.combine(ruleRevision)
  }
}

/// An explicit confirmation created from one session-owned entry reference.
///
/// There is no public initializer. Call `CleanupApprovalReviewSession.confirm`
/// so the issuing session is checked before this value is created.
public struct CleanupApprovalEntryConfirmation: Hashable, Sendable {
  fileprivate let reference: CleanupApprovalEntryReference

  public var ordinal: Int { reference.ordinal }
  public var path: ScanRelativePath { reference.path }
  public var ruleRevision: RuleRevision { reference.ruleRevision }

  fileprivate init(reference: CleanupApprovalEntryReference) {
    self.reference = reference
  }
}

/// One pending execution precondition exposed by an exact review session.
///
/// Acknowledging this reference records only that the condition and its risk
/// were included in review. It does not attest that the responsible tool is
/// currently stopped and does not resolve the condition for a later operation.
public struct CleanupApprovalPreconditionReference: Hashable, Sendable {
  public let ordinal: Int
  public let path: ScanRelativePath
  public let ruleRevision: RuleRevision
  public let precondition: RuleDeferredExecutionPrecondition

  fileprivate let reviewIdentity: CleanupApprovalReviewIdentity

  public static func == (
    left: CleanupApprovalPreconditionReference,
    right: CleanupApprovalPreconditionReference
  ) -> Bool {
    left.reviewIdentity === right.reviewIdentity
      && left.ordinal == right.ordinal
      && left.path == right.path
      && left.ruleRevision == right.ruleRevision
      && left.precondition == right.precondition
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(reviewIdentity))
    hasher.combine(ordinal)
    hasher.combine(path)
    hasher.combine(ruleRevision)
    hasher.combine(precondition)
  }
}

/// A process-local review acknowledgement for one pending requirement.
///
/// This remains pending execution work. It proves neither current inactivity
/// nor fresh consent for a future quarantine attempt.
public struct CleanupApprovalPreconditionReviewAcknowledgement: Hashable, Sendable {
  fileprivate let reference: CleanupApprovalPreconditionReference

  public var ordinal: Int { reference.ordinal }
  public var path: ScanRelativePath { reference.path }
  public var ruleRevision: RuleRevision { reference.ruleRevision }
  public var precondition: RuleDeferredExecutionPrecondition { reference.precondition }

  fileprivate init(reference: CleanupApprovalPreconditionReference) {
    self.reference = reference
  }
}

/// A Core-issued, process-local binding between one exact planning request and
/// the exact manifest produced for review from that request.
///
/// This value retains sensitive in-memory scan and classification source state
/// until it is discarded. It is neither persistent nor an execution
/// capability.
public struct CleanupApprovalReviewSession: Sendable {
  public let sourceRoot: URL
  public let reviewedManifest: CleanupManifest
  public let entryReferences: [CleanupApprovalEntryReference]
  public let preconditionReferences: [CleanupApprovalPreconditionReference]

  let sourceRequest: CleanupManifestRequest
  private let reviewIdentity: CleanupApprovalReviewIdentity

  init(
    sourceRequest: CleanupManifestRequest,
    reviewedManifest: CleanupManifest
  ) {
    let reviewIdentity = CleanupApprovalReviewIdentity()
    self.sourceRoot = sourceRequest.classificationRequest.root
    self.reviewedManifest = reviewedManifest
    self.sourceRequest = sourceRequest
    self.reviewIdentity = reviewIdentity
    self.entryReferences = reviewedManifest.entries.enumerated().map { ordinal, entry in
      CleanupApprovalEntryReference(
        ordinal: ordinal,
        path: entry.path,
        ruleRevision: entry.ruleRevision,
        reviewIdentity: reviewIdentity
      )
    }
    var nextPreconditionOrdinal = 0
    var preconditionReferences: [CleanupApprovalPreconditionReference] = []
    preconditionReferences.reserveCapacity(
      reviewedManifest.entries.reduce(into: 0) { count, entry in
        count += entry.deferredExecutionPreconditions.count
      }
    )
    for entry in reviewedManifest.entries {
      for precondition in entry.deferredExecutionPreconditions {
        preconditionReferences.append(
          CleanupApprovalPreconditionReference(
            ordinal: nextPreconditionOrdinal,
            path: entry.path,
            ruleRevision: entry.ruleRevision,
            precondition: precondition,
            reviewIdentity: reviewIdentity
          )
        )
        nextPreconditionOrdinal += 1
      }
    }
    self.preconditionReferences = preconditionReferences
  }

  /// Confirms one entry issued by this exact review session.
  ///
  /// A same-looking reference from another session fails rather than being
  /// rebound by its visible path and rule revision.
  public func confirm(
    _ reference: CleanupApprovalEntryReference
  ) throws -> CleanupApprovalEntryConfirmation {
    guard owns(reference) else {
      throw CleanupApprovalError.entryReferenceDoesNotBelongToReview
    }
    return CleanupApprovalEntryConfirmation(reference: reference)
  }

  /// Acknowledges that one exact pending execution requirement was included
  /// in this review. It does not satisfy that requirement.
  public func acknowledgePreconditionForReview(
    _ reference: CleanupApprovalPreconditionReference
  ) throws -> CleanupApprovalPreconditionReviewAcknowledgement {
    guard owns(reference) else {
      throw CleanupApprovalError.preconditionReferenceDoesNotBelongToReview
    }
    return CleanupApprovalPreconditionReviewAcknowledgement(reference: reference)
  }

  func matches(
    _ confirmation: CleanupApprovalEntryConfirmation,
    at index: Int
  ) -> Bool {
    guard entryReferences.indices.contains(index) else {
      return false
    }
    return confirmation.reference.reviewIdentity === reviewIdentity
      && confirmation.reference.ordinal == index
      && confirmation.reference == entryReferences[index]
  }

  func matches(
    _ acknowledgement: CleanupApprovalPreconditionReviewAcknowledgement,
    at index: Int
  ) -> Bool {
    guard preconditionReferences.indices.contains(index) else {
      return false
    }
    return acknowledgement.reference.reviewIdentity === reviewIdentity
      && acknowledgement.reference.ordinal == index
      && acknowledgement.reference == preconditionReferences[index]
  }

  private func owns(_ reference: CleanupApprovalEntryReference) -> Bool {
    guard entryReferences.indices.contains(reference.ordinal) else {
      return false
    }
    return reference.reviewIdentity === reviewIdentity
      && reference == entryReferences[reference.ordinal]
  }

  private func owns(_ reference: CleanupApprovalPreconditionReference) -> Bool {
    guard preconditionReferences.indices.contains(reference.ordinal) else {
      return false
    }
    return reference.reviewIdentity === reviewIdentity
      && reference == preconditionReferences[reference.ordinal]
  }
}

/// An explicit request to approve one complete review session.
///
/// Confirmations must repeat every session entry exactly once in its existing
/// canonical order. Partial approval requires a new planning request and review
/// session. Pending-precondition acknowledgements likewise repeat only what was
/// reviewed; they are not execution-time attestations.
public struct CleanupApprovalRequest: Sendable {
  public let session: CleanupApprovalReviewSession
  public let confirmations: [CleanupApprovalEntryConfirmation]
  public let preconditionReviewAcknowledgements: [CleanupApprovalPreconditionReviewAcknowledgement]

  public init(
    session: CleanupApprovalReviewSession,
    confirmations: [CleanupApprovalEntryConfirmation],
    preconditionReviewAcknowledgements: [CleanupApprovalPreconditionReviewAcknowledgement] = []
  ) {
    self.session = session
    self.confirmations = confirmations
    self.preconditionReviewAcknowledgements = preconditionReviewAcknowledgements
  }
}

public enum CleanupApprovalError: Error, Equatable, Sendable {
  case invalidSourceRoot
  case emptyManifest
  case entryReferenceDoesNotBelongToReview
  case preconditionReferenceDoesNotBelongToReview
  case confirmationCountMismatch(expected: Int, actual: Int)
  case confirmationMismatch(index: Int)
  case preconditionReviewAcknowledgementCountMismatch(expected: Int, actual: Int)
  case preconditionReviewAcknowledgementMismatch(index: Int)
  case reviewedManifestRegenerationMismatch
}
