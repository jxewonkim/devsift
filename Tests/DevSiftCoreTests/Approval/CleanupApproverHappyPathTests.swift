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
    #expect(first.contractVersion == 1)
    #expect(first.sourceRoot == source.classificationRequest.root)
    #expect(first.sourceRoot == session.sourceRoot)
    #expect(first.reviewedManifest == session.reviewedManifest)
    #expect(first.reviewedManifest.entries == session.reviewedManifest.entries)
    #expect(first.reviewedManifest.totals == session.reviewedManifest.totals)
    #expect(second.sourceRoot == first.sourceRoot)
    #expect(second.reviewedManifest == first.reviewedManifest)
    #expect(first.reviewedManifest.requiresExplicitApproval)
    #expect(first.requiresExecutionRevalidation)
    #expect(first.reviewedManifest.requiresExecutionRevalidation)
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
    let source = try await approvalTestSource(rawNames: [Array("candidate".utf8)])
    let approver = CleanupApprover()
    let session = try approver.beginReview(source.manifestRequest)
    let reference = try #require(session.entryReferences.first)
    let confirmation = try session.confirm(reference)
    let request = CleanupApprovalRequest(
      session: session,
      confirmations: [confirmation]
    )
    let approval = try approver.approve(request)

    #expect(
      Mirror(reflecting: request).children.compactMap(\.label)
        == ["session", "confirmations"]
    )
    #expect(
      Mirror(reflecting: approval).children.compactMap(\.label)
        == ["contractVersion", "sourceRoot", "reviewedManifest"]
    )
    #expect(!isEncodableApprovalValue(session))
    #expect(!isEncodableApprovalValue(reference))
    #expect(!isEncodableApprovalValue(confirmation))
    #expect(!isEncodableApprovalValue(request))
    #expect(!isEncodableApprovalValue(approval))
    #expect(approval.requiresExecutionRevalidation)
    #expect(!approval.isSingleUse)
    #expect(!approval.isAuthenticityProof)
    #expect(!approval.grantsFilesystemMutationAuthority)
  }
}
