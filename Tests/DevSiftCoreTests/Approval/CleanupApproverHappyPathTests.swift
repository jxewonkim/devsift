import Testing

@testable import DevSiftCore

@Suite("Cleanup approval review sessions")
struct CleanupApproverHappyPathTests {
  @Test("A review session issues exact canonical references for its planned manifest")
  func exactReviewSession() async throws {
    let source = try await approvalTestSource(
      rawNames: [Array("z-cache".utf8), Array("a-cache".utf8)]
    )
    let expectedManifest = try CleanupPlanner().makeManifest(source.manifestRequest)
    let approver = CleanupApprover()

    let session = try approver.beginReview(source.manifestRequest)

    #expect(session.sourceRoot == source.classificationRequest.root)
    #expect(session.reviewedManifest == expectedManifest)
    #expect(session.entryReferences.map(\.ordinal) == [0, 1])
    #expect(
      session.entryReferences.map(\.path)
        == session.reviewedManifest.entries.map(\.path)
    )
    #expect(
      session.entryReferences.map(\.ruleRevision)
        == session.reviewedManifest.entries.map(\.ruleRevision)
    )

    let confirmations = try approvalConfirmations(from: session)
    #expect(confirmations.map(\.ordinal) == [0, 1])
    #expect(confirmations.map(\.path) == session.entryReferences.map(\.path))
    #expect(
      confirmations.map(\.ruleRevision)
        == session.entryReferences.map(\.ruleRevision)
    )
  }

  @Test("All session-issued confirmations approve the exact root and manifest")
  func exactWholeManifestApproval() async throws {
    let source = try await approvalTestSource()
    let approver = CleanupApprover()
    let session = try approver.beginReview(source.manifestRequest)
    let confirmations = try approvalConfirmations(from: session)
    let request = CleanupApprovalRequest(
      session: session,
      confirmations: confirmations
    )

    let first = try approver.approve(request)
    let second = try approver.approve(request)

    #expect(first.contractVersion == CleanupApproval.currentContractVersion)
    #expect(first.contractVersion == 2)
    #expect(first.sourceRoot == source.classificationRequest.root)
    #expect(first.sourceRoot == session.sourceRoot)
    #expect(first.reviewedManifest == session.reviewedManifest)
    #expect(first.reviewedManifest.entries == session.reviewedManifest.entries)
    #expect(first.reviewedManifest.totals == session.reviewedManifest.totals)
    #expect(second.sourceRoot == first.sourceRoot)
    #expect(second.reviewedManifest == first.reviewedManifest)
    #expect(first.preconditionReviewAcknowledgements.isEmpty)
    #expect(second.preconditionReviewAcknowledgements.isEmpty)
    #expect(first.reviewedManifest.requiresExplicitApproval)
    #expect(first.requiresExecutionRevalidation)
    #expect(first.reviewedManifest.requiresExecutionRevalidation)
    #expect(!first.isSingleUse)
    #expect(!first.isAuthenticityProof)
    #expect(!first.grantsFilesystemMutationAuthority)
  }

  @Test("Pending execution preconditions receive exact canonical review acknowledgements")
  func canonicalPreconditionReviewAcknowledgements() async throws {
    let source = try await approvalPendingPreconditionTestSource(
      rawNames: [Array("z-cache".utf8), Array("a-cache".utf8)]
    )
    let approver = CleanupApprover()
    let session = try approver.beginReview(source.manifestRequest)

    #expect(session.preconditionReferences.map(\.ordinal) == [0, 1])
    #expect(
      session.preconditionReferences.map(\.path)
        == session.reviewedManifest.entries.map(\.path)
    )
    #expect(
      session.preconditionReferences.map(\.ruleRevision)
        == session.reviewedManifest.entries.map(\.ruleRevision)
    )
    #expect(
      session.preconditionReferences.map(\.precondition)
        == [
          .requiresUserAttestationThatResponsibleToolIsStopped,
          .requiresUserAttestationThatResponsibleToolIsStopped,
        ]
    )
    #expect(
      session.reviewedManifest.entries.allSatisfy {
        $0.deferredExecutionPreconditions == [.requiresUserAttestationThatResponsibleToolIsStopped]
      }
    )

    let acknowledgements = try approvalPreconditionReviewAcknowledgements(from: session)
    #expect(acknowledgements.map(\.ordinal) == [0, 1])
    #expect(acknowledgements.map(\.path) == session.preconditionReferences.map(\.path))
    #expect(
      acknowledgements.map(\.ruleRevision)
        == session.preconditionReferences.map(\.ruleRevision)
    )
    #expect(
      acknowledgements.map(\.precondition)
        == session.preconditionReferences.map(\.precondition)
    )

    let approval = try approver.approve(
      CleanupApprovalRequest(
        session: session,
        confirmations: try approvalConfirmations(from: session),
        preconditionReviewAcknowledgements: acknowledgements
      )
    )

    #expect(approval.preconditionReviewAcknowledgements == acknowledgements)
    #expect(
      approval.reviewedManifest.entries.flatMap(\.deferredExecutionPreconditions)
        == acknowledgements.map(\.precondition)
    )
  }

  @Test("A precondition review acknowledgement is replayable intent, not activity freshness")
  func preconditionReviewAcknowledgementIsNotFreshness() async throws {
    let source = try await approvalPendingPreconditionTestSource(
      rawNames: [Array("candidate".utf8)]
    )
    let approver = CleanupApprover()
    let session = try approver.beginReview(source.manifestRequest)
    let request = CleanupApprovalRequest(
      session: session,
      confirmations: try approvalConfirmations(from: session),
      preconditionReviewAcknowledgements: try approvalPreconditionReviewAcknowledgements(
        from: session)
    )

    let first = try approver.approve(request)
    let second = try approver.approve(request)
    let firstEntry = try #require(first.reviewedManifest.entries.first)
    let activityFinding = try #require(
      firstEntry.findings.first { $0.identifier == AutomaticCheckIdentifier.activity }
    )

    #expect(first.preconditionReviewAcknowledgements == second.preconditionReviewAcknowledgements)
    #expect(
      firstEntry.deferredExecutionPreconditions == [
        .requiresUserAttestationThatResponsibleToolIsStopped
      ]
    )
    #expect(activityFinding.state == .unknown(.notCollected))
    #expect(first.requiresExecutionRevalidation)
    #expect(!first.isSingleUse)
    #expect(!first.isAuthenticityProof)
    #expect(!first.grantsFilesystemMutationAuthority)
  }

  @Test("Exact raw bytes remain distinct when escaped display paths collide")
  func exactRawPathConfirmations() async throws {
    let escapedBytes = Array("\\xFF".utf8)
    let nonUTF8Bytes: [UInt8] = [0xFF]
    let source = try await approvalTestSource(
      rawNames: [nonUTF8Bytes, escapedBytes]
    )
    let approver = CleanupApprover()
    let session = try approver.beginReview(source.manifestRequest)

    #expect(session.entryReferences.count == 2)
    #expect(
      session.entryReferences[0].path.description
        == session.entryReferences[1].path.description
    )
    #expect(
      session.entryReferences[0].path.rawComponents
        != session.entryReferences[1].path.rawComponents
    )
    #expect(session.entryReferences[0] != session.entryReferences[1])

    let confirmations = try approvalConfirmations(from: session)
    let approval = try approver.approve(
      CleanupApprovalRequest(session: session, confirmations: confirmations)
    )

    #expect(
      approval.reviewedManifest.entries.map(\.path.rawComponents)
        == [[escapedBytes], [nonUTF8Bytes]]
    )
  }

  @Test("Opaque review values are non-serializable and grant no execution authority")
  func opaqueValueBoundary() async throws {
    let source = try await approvalPendingPreconditionTestSource(
      rawNames: [Array("candidate".utf8)]
    )
    let approver = CleanupApprover()
    let session = try approver.beginReview(source.manifestRequest)
    let reference = try #require(session.entryReferences.first)
    let confirmation = try session.confirm(reference)
    let preconditionReference = try #require(session.preconditionReferences.first)
    let preconditionAcknowledgement = try session.acknowledgePreconditionForReview(
      preconditionReference
    )
    let request = CleanupApprovalRequest(
      session: session,
      confirmations: [confirmation],
      preconditionReviewAcknowledgements: [preconditionAcknowledgement]
    )
    let approval = try approver.approve(request)

    #expect(
      Mirror(reflecting: request).children.compactMap(\.label)
        == ["session", "confirmations", "preconditionReviewAcknowledgements"]
    )
    #expect(
      Mirror(reflecting: preconditionReference).children.compactMap(\.label)
        == ["ordinal", "path", "ruleRevision", "precondition", "reviewIdentity"]
    )
    #expect(
      Mirror(reflecting: preconditionAcknowledgement).children.compactMap(\.label)
        == ["reference"]
    )
    #expect(
      Mirror(reflecting: approval).children.compactMap(\.label)
        == [
          "contractVersion", "sourceRoot", "reviewedManifest", "preconditionReviewAcknowledgements",
        ]
    )
    #expect(!isEncodableApprovalValue(session))
    #expect(!isEncodableApprovalValue(reference))
    #expect(!isEncodableApprovalValue(confirmation))
    #expect(!isEncodableApprovalValue(preconditionReference))
    #expect(!isEncodableApprovalValue(preconditionAcknowledgement))
    #expect(!isEncodableApprovalValue(request))
    #expect(!isEncodableApprovalValue(approval))
    #expect(approval.requiresExecutionRevalidation)
    #expect(!approval.isSingleUse)
    #expect(!approval.isAuthenticityProof)
    #expect(!approval.grantsFilesystemMutationAuthority)
  }
}
