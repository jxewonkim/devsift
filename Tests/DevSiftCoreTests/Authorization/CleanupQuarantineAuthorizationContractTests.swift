import Foundation
import Testing

@testable import DevSiftCore

@Suite("Cleanup quarantine authorization contract")
struct CleanupQuarantineAuthorizationContractTests {
  @Test("The public default authorizer accepts a built-in npm pending approval")
  func defaultAuthorizerBuiltInNPMHappyPath() async throws {
    let value = try await authorizationBuiltInNPMApproval()
    let session = try CleanupQuarantineAuthorizer().beginAttempt(for: value.approval)

    #expect(session.attestationRequest.subjects.count == 1)
    #expect(session.attestationRequest.subjects[0].responsibleTool == "npm")
    #expect(
      session.attestationRequest.subjects[0].ruleRevision
        == RuleRevision(
          identifier: testRuleIdentifier("devsift.cache.npm"),
          version: testRuleVersion(5)
        )
    )
    #expect(
      session.attestationRequest.subjects[0].precondition
        == .requiresUserAttestationThatResponsibleToolIsStopped
    )

    let attestation = authorizationAttestation(for: session)
    let authorization = try await session.authorize(using: attestation)
    let claim = try await authorization.consumeForExecution()

    #expect(claim.approval.reviewedManifest == value.approval.reviewedManifest)
    #expect(claim.attestation == attestation)
  }

  @Test("Canonical pending subjects retain exact raw paths and issue one exact internal claim")
  func canonicalSubjectsAndRetainedClaim() async throws {
    let escapedBytes: [UInt8] = [0x1B, 0x5B, 0x33, 0x31, 0x6D]
    let nonUTF8Bytes: [UInt8] = [0xFF, 0xFE]
    let rawNames = [nonUTF8Bytes, Array("z-cache".utf8), escapedBytes]
    let value = try await authorizationPendingApproval(rawNames: rawNames)
    let session = try syntheticAuthorizationSession(for: value.approval)
    let request = session.attestationRequest
    let expectedEntries = value.approval.reviewedManifest.entries

    #expect(request.requiredStatement == .responsibleToolStoppedAndUnobservedActivityRiskAccepted)
    #expect(request.requiredStatement.policyRevision == 1)
    #expect(request.subjects.map(\.ordinal) == [0, 1, 2])
    #expect(request.subjects.map(\.path) == expectedEntries.map(\.path))
    #expect(request.subjects.map(\.ruleRevision) == expectedEntries.map(\.ruleRevision))
    #expect(request.subjects.map(\.responsibleTool) == expectedEntries.map(\.responsibleTool))
    #expect(
      request.subjects.map(\.precondition)
        == Array(
          repeating: .requiresUserAttestationThatResponsibleToolIsStopped,
          count: expectedEntries.count
        )
    )
    #expect(
      request.subjects.map(\.path.rawComponents)
        == [[escapedBytes], [Array("z-cache".utf8)], [nonUTF8Bytes]]
    )
    #expect(request.subjects.allSatisfy { $0.precondition.policyRevision == 1 })

    let attestation = authorizationAttestation(for: session)
    let authorization = try await session.authorize(using: attestation)
    let claim = try await authorization.consumeForExecution()

    #expect(claim.approval.contractVersion == value.approval.contractVersion)
    #expect(claim.approval.sourceRoot == value.approval.sourceRoot)
    #expect(claim.approval.reviewedManifest == value.approval.reviewedManifest)
    #expect(
      claim.approval.preconditionReviewAcknowledgements
        == value.approval.preconditionReviewAcknowledgements
    )
    #expect(claim.attestation == attestation)
    #expect(claim.attestation.request == request)
  }

  @Test("Attempt values are non-Codable and authorization exposes version-one safety flags")
  func opaqueSafetyContract() async throws {
    let value = try await authorizationPendingApproval()
    let session = try syntheticAuthorizationSession(for: value.approval)
    let request = session.attestationRequest
    let attestation = authorizationAttestation(for: session)
    let authorization = try await session.authorize(using: attestation)

    #expect(!isEncodableAuthorizationValue(request))
    #expect(!isEncodableAuthorizationValue(attestation))
    #expect(!isEncodableAuthorizationValue(authorization))
    #expect(authorization.contractVersion == CleanupQuarantineAuthorization.currentContractVersion)
    #expect(authorization.contractVersion == 1)
    #expect(authorization.isSingleUse)
    #expect(authorization.authorizesRecoverableQuarantineOnly)
    #expect(!authorization.authorizesPermanentDeletion)
    #expect(authorization.requiresInlineFilesystemRevalidation)
    #expect(!authorization.grantsStandaloneFilesystemMutationAuthority)
    #expect(!authorization.usesWallClockFreshness)
  }

  @Test("An approval without pending execution preconditions cannot begin an attempt")
  func noPendingPreconditions() async throws {
    let value = try await authorizationNonPendingApproval()

    expectAuthorizationError(.noPendingExecutionPreconditions) {
      _ = try syntheticAuthorizationAuthorizer(for: value.approval)
        .beginAttempt(for: value.approval)
    }
  }

  @Test("The default authorizer rejects a synthetic approval policy before issuing a request")
  func defaultAuthorizerRejectsSyntheticPolicy() async throws {
    let value = try await authorizationPendingApproval()

    expectAuthorizationError(.unsupportedApprovalPolicy) {
      _ = try CleanupQuarantineAuthorizer().beginAttempt(for: value.approval)
    }
  }

  @Test("Authorization policy markers do not silently follow classifier or catalog drift")
  func exactAuthorizationPolicyMarkers() async throws {
    let value = try await authorizationPendingApproval()
    let provenance = value.approval.reviewedManifest.policyProvenance
    let entry = try #require(value.approval.reviewedManifest.entries.first)
    let nextClassificationVersion = try #require(
      RuleVersion(rawValue: provenance.classificationContractRevision.version.rawValue + 1)
    )
    let nextCatalogVersion = try #require(
      RuleVersion(rawValue: provenance.catalogRevision.version.rawValue + 1)
    )
    let classificationDriftAuthorizer = CleanupQuarantineAuthorizer(
      supportedPolicyProvenance: provenance,
      supportedClassificationContractRevision: RuleRevision(
        identifier: provenance.classificationContractRevision.identifier,
        version: nextClassificationVersion
      ),
      supportedCatalogRevision: provenance.catalogRevision,
      supportedRuleRevision: entry.ruleRevision,
      responsibleTool: entry.responsibleTool
    )
    let catalogDriftAuthorizer = CleanupQuarantineAuthorizer(
      supportedPolicyProvenance: provenance,
      supportedClassificationContractRevision: provenance.classificationContractRevision,
      supportedCatalogRevision: RuleRevision(
        identifier: provenance.catalogRevision.identifier,
        version: nextCatalogVersion
      ),
      supportedRuleRevision: entry.ruleRevision,
      responsibleTool: entry.responsibleTool
    )

    expectAuthorizationError(.unsupportedApprovalPolicy) {
      _ = try classificationDriftAuthorizer.beginAttempt(for: value.approval)
    }
    expectAuthorizationError(.unsupportedApprovalPolicy) {
      _ = try catalogDriftAuthorizer.beginAttempt(for: value.approval)
    }
  }

  @Test("Pending subjects must match the configured rule revision and canonical tool")
  func exactAttestationRequirement() async throws {
    let value = try await authorizationPendingApproval()
    let entry = try #require(value.approval.reviewedManifest.entries.first)
    let wrongRule = RuleRevision(
      identifier: testRuleIdentifier("devsift.test.authorization-other"),
      version: testRuleVersion()
    )
    let wrongRuleAuthorizer = CleanupQuarantineAuthorizer(
      supportedPolicyProvenance: value.approval.reviewedManifest.policyProvenance,
      supportedClassificationContractRevision: value.approval.reviewedManifest.policyProvenance
        .classificationContractRevision,
      supportedCatalogRevision: value.approval.reviewedManifest.policyProvenance.catalogRevision,
      supportedRuleRevision: wrongRule,
      responsibleTool: entry.responsibleTool
    )
    let wrongRuleVersionAuthorizer = CleanupQuarantineAuthorizer(
      supportedPolicyProvenance: value.approval.reviewedManifest.policyProvenance,
      supportedClassificationContractRevision: value.approval.reviewedManifest.policyProvenance
        .classificationContractRevision,
      supportedCatalogRevision: value.approval.reviewedManifest.policyProvenance.catalogRevision,
      supportedRuleRevision: RuleRevision(
        identifier: entry.ruleRevision.identifier,
        version: try #require(
          RuleVersion(rawValue: entry.ruleRevision.version.rawValue + 1)
        )
      ),
      responsibleTool: entry.responsibleTool
    )
    let wrongToolAuthorizer = CleanupQuarantineAuthorizer(
      supportedPolicyProvenance: value.approval.reviewedManifest.policyProvenance,
      supportedClassificationContractRevision: value.approval.reviewedManifest.policyProvenance
        .classificationContractRevision,
      supportedCatalogRevision: value.approval.reviewedManifest.policyProvenance.catalogRevision,
      supportedRuleRevision: entry.ruleRevision,
      responsibleTool: "Another tool"
    )

    expectAuthorizationError(.unsupportedAttestationRequirements) {
      _ = try wrongRuleAuthorizer.beginAttempt(for: value.approval)
    }
    expectAuthorizationError(.unsupportedAttestationRequirements) {
      _ = try wrongRuleVersionAuthorizer.beginAttempt(for: value.approval)
    }
    expectAuthorizationError(.unsupportedAttestationRequirements) {
      _ = try wrongToolAuthorizer.beginAttempt(for: value.approval)
    }
  }

  @Test("An approval with pending subjects from multiple tools fails closed")
  func mixedResponsibleToolsAreUnsupported() async throws {
    let value = try await authorizationMixedToolPendingApproval()

    #expect(
      Set(value.approval.reviewedManifest.entries.map(\.responsibleTool))
        == ["Alpha tool", "Beta tool"]
    )
    expectAuthorizationError(.unsupportedAttestationRequirements) {
      _ = try syntheticAuthorizationAuthorizer(for: value.approval)
        .beginAttempt(for: value.approval)
    }
  }

  @Test("A same-looking attestation from another attempt cannot be substituted")
  func crossAttemptAttestation() async throws {
    let value = try await authorizationPendingApproval()
    let first = try syntheticAuthorizationSession(for: value.approval)
    let second = try syntheticAuthorizationSession(for: value.approval)

    #expect(first.attestationRequest.subjects == second.attestationRequest.subjects)
    #expect(
      first.attestationRequest.requiredStatement == second.attestationRequest.requiredStatement)
    #expect(first.attestationRequest != second.attestationRequest)

    await expectAuthorizationError(.attestationDoesNotBelongToAttempt) {
      _ = try await first.authorize(using: authorizationAttestation(for: second))
    }

    _ = try await first.authorize(using: authorizationAttestation(for: first))
  }

  @Test("An attestation cannot cross attempts created from different approvals")
  func crossApprovalAttestation() async throws {
    let firstValue = try await authorizationPendingApproval(
      root: URL(fileURLWithPath: "/synthetic/FirstAuthorizationRoot", isDirectory: true)
    )
    let secondValue = try await authorizationPendingApproval(
      root: URL(fileURLWithPath: "/synthetic/SecondAuthorizationRoot", isDirectory: true)
    )
    let first = try syntheticAuthorizationSession(for: firstValue.approval)
    let second = try syntheticAuthorizationSession(for: secondValue.approval)

    #expect(firstValue.approval.sourceRoot != secondValue.approval.sourceRoot)
    #expect(first.attestationRequest.subjects == second.attestationRequest.subjects)
    #expect(first.attestationRequest != second.attestationRequest)
    await expectAuthorizationError(.attestationDoesNotBelongToAttempt) {
      _ = try await first.authorize(using: authorizationAttestation(for: second))
    }
    _ = try await first.authorize(using: authorizationAttestation(for: first))
  }
}
