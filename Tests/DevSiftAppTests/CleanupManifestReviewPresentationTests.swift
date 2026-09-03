import DevSiftCore
import Foundation
import Testing

@testable import DevSiftApp
@testable import DevSiftCore

@Suite("Cleanup manifest review presentation")
struct CleanupManifestReviewPresentationTests {
  @Test("Rows preserve exact manifest ordering and project every total")
  func orderingCountsAndTotals() throws {
    let reviewEntry = try ManifestReviewFixture.entry(
      rawName: Array("z-review".utf8),
      ruleIdentifier: "devsift.test.z-review",
      disposition: .reviewRequired,
      logicalBytes: 1,
      allocatedBytes: 2,
      hardLinkExclusiveAllocatedBytes: 1,
      possibleSharedContentFileCount: 4,
      sharedContentMetadataUnavailableCount: 5,
      unobservedHardLinkFileCount: 6,
      nonExclusiveHardLinkFileCount: 7
    )
    let reclaimableEntry = try ManifestReviewFixture.entry(
      rawName: Array("a-reclaimable".utf8),
      ruleIdentifier: "devsift.test.a-reclaimable",
      ruleVersion: 9,
      disposition: .reclaimable,
      logicalBytes: 10,
      allocatedBytes: 20,
      hardLinkExclusiveAllocatedBytes: 15,
      possibleSharedContentFileCount: 40,
      sharedContentMetadataUnavailableCount: 50,
      unobservedHardLinkFileCount: 60,
      nonExclusiveHardLinkFileCount: 70
    )
    let manifest = try ManifestReviewFixture.manifest(
      entries: [reviewEntry, reclaimableEntry]
    )

    let presentation = try CleanupManifestReviewPresentation.prepare(manifest: manifest)

    #expect(presentation.entryCount == 2)
    #expect(presentation.reclaimableCount == 1)
    #expect(presentation.reviewRequiredCount == 1)
    #expect(presentation.deferredExecutionPreconditionCount == 0)
    #expect(!presentation.hasDeferredExecutionPreconditions)
    #expect(presentation.entries.map(\.id) == [reclaimableEntry.path, reviewEntry.path])
    #expect(presentation.entries.map(\.displayPath) == ["a-reclaimable", "z-review"])

    let first = try #require(presentation.entries.first)
    #expect(first.ruleRevisionLabel == "devsift.test.a-reclaimable@9")
    #expect(first.disposition == .reclaimable)
    #expect(first.reproducibility == .reproducible)
    #expect(first.size.observedLogicalBytes == 10)
    #expect(first.size.observedAllocatedBytes == 20)
    #expect(first.size.observedHardLinkExclusiveAllocatedBytes == 15)
    #expect(first.size.possibleSharedContentFileCount == 40)
    #expect(first.size.sharedContentMetadataUnavailableCount == 50)
    #expect(first.size.unobservedHardLinkFileCount == 60)
    #expect(first.size.nonExclusiveHardLinkFileCount == 70)

    #expect(presentation.totals.observedLogicalBytes == 11)
    #expect(presentation.totals.observedAllocatedBytes == 22)
    #expect(presentation.totals.observedHardLinkExclusiveAllocatedBytes == 16)
    #expect(presentation.totals.possibleSharedContentFileCount == 44)
    #expect(presentation.totals.sharedContentMetadataUnavailableCount == 55)
    #expect(presentation.totals.unobservedHardLinkFileCount == 66)
    #expect(presentation.totals.nonExclusiveHardLinkFileCount == 77)
  }

  @Test("Paths and all free-form review text are display escaped")
  func escaping() throws {
    let rawPath = Array("line\nleft​\\name".utf8)
    let invalidUTF8Path: [UInt8] = [0x66, 0xFF, 0x80]
    let finding = try ManifestReviewFixture.finding(
      identifier: "test.exclusion",
      kind: .exclusion,
      explanation: "Finding line\t"
    )
    let entry = try ManifestReviewFixture.entry(
      rawName: rawPath,
      displayName: "Display\n​",
      responsibleTool: "Tool\\name\t",
      classificationExplanation: "Class\r‮",
      findings: [finding]
    )
    let invalidUTF8Entry = try ManifestReviewFixture.entry(
      rawName: invalidUTF8Path,
      ruleIdentifier: "devsift.test.invalid-utf8"
    )
    let manifest = try ManifestReviewFixture.manifest(entries: [entry, invalidUTF8Entry])

    let presentation = try CleanupManifestReviewPresentation.prepare(manifest: manifest)
    let row = try #require(presentation.entries.first(where: { $0.id == entry.path }))
    let invalidUTF8Row = try #require(
      presentation.entries.first(where: { $0.id == invalidUTF8Entry.path })
    )
    let renderedFinding = try #require(row.findings.first)

    #expect(row.id.rawComponents == [rawPath])
    #expect(row.displayPath == "line\\nleft\\u{200B}\\\\name")
    #expect(row.displayName == "Display\\n\\u{200B}")
    #expect(row.responsibleTool == "Tool\\\\name\\t")
    #expect(row.classificationExplanation == "Class\\r\\u{202E}")
    #expect(renderedFinding.identifier == "test.exclusion")
    #expect(renderedFinding.kind == .exclusion)
    #expect(renderedFinding.state == .satisfied)
    #expect(renderedFinding.explanation == "Finding\\u{2028}line\\t")
    #expect(invalidUTF8Row.id.rawComponents == [invalidUTF8Path])
    #expect(invalidUTF8Row.displayPath == "\\x66\\xFF\\x80")
  }

  @Test("Deferred activity is presented as unobserved and not as authorization")
  func deferredActivityDisclosure() throws {
    let activityFinding = try ManifestReviewFixture.finding(
      identifier: "activity-requirement",
      kind: .activity,
      state: .unknown(.notCollected),
      explanation: "Reliable tool activity information was not collected."
    )
    let entry = try ManifestReviewFixture.entry(
      responsibleTool: "npm",
      findings: [try ManifestReviewFixture.finding(), activityFinding],
      deferredExecutionPreconditions: [.requiresUserAttestationThatResponsibleToolIsStopped]
    )
    let manifest = try ManifestReviewFixture.manifest(entries: [entry])

    let presentation = try CleanupManifestReviewPresentation.prepare(manifest: manifest)
    let row = try #require(presentation.entries.first)
    let precondition = try #require(row.deferredExecutionPreconditions.first)

    #expect(presentation.hasDeferredExecutionPreconditions)
    #expect(presentation.deferredExecutionPreconditionCount == 1)
    #expect(presentation.deferredExecutionNoticeTitle == "Activity remains unobserved")
    #expect(
      presentation.deferredExecutionNoticeMessage.contains("not evidence that a tool is inactive")
    )
    #expect(presentation.deferredExecutionNoticeMessage.contains("fresh revalidation"))
    #expect(presentation.deferredExecutionNoticeMessage.contains("attempt-scoped authorization"))
    #expect(
      presentation.deferredExecutionNoticeMessage.contains("does not provide that authorization")
    )
    #expect(row.deferredExecutionPreconditions.count == 1)
    #expect(precondition.identifier == "requires-user-attestation-that-responsible-tool-is-stopped")
    #expect(precondition.policyRevision == 1)
    #expect(
      precondition.identifierAndRevisionLabel
        == "requires-user-attestation-that-responsible-tool-is-stopped@1")
    #expect(precondition.title == "Activity remains unobserved")
    #expect(precondition.explanation.contains("did not observe whether npm is active"))
    #expect(precondition.explanation.contains("attempt-scoped authorization"))
    #expect(precondition.explanation.contains("This draft is not that authorization"))
    #expect(precondition.explanation.contains("cannot be executed"))
    #expect(!precondition.explanation.localizedCaseInsensitiveContains("known to be inactive"))
    #expect(!precondition.explanation.localizedCaseInsensitiveContains("safe to clean"))
    let displayedActivityFinding = row.findings.first { finding in
      finding.identifier == "activity-requirement"
    }
    #expect(displayedActivityFinding?.kind == .activity)
    #expect(displayedActivityFinding?.state == .unknown(.notCollected))
  }

  @Test("Projection omits filesystem identity, roots, time, Base64, and authority")
  func privacyAndNonAuthorityBoundary() throws {
    let rawName = Array("private-client-project".utf8)
    let rawNameBase64 = Data(rawName).base64EncodedString()
    let device: UInt64 = 7_777_771_234_567
    let entryInode: UInt64 = 8_888_881_234_567
    let rootInode: UInt64 = 9_999_991_234_567
    let referenceUnixSeconds: Int64 = -6_543_219_876_543
    let entry = try ManifestReviewFixture.entry(
      rawName: rawName,
      identity: FileIdentity(device: device, inode: entryInode),
      displayName: "Private cache",
      responsibleTool: "Private tool",
      classificationExplanation: "Locally generated data."
    )
    let manifest = try ManifestReviewFixture.manifest(
      entries: [entry],
      referenceUnixSeconds: referenceUnixSeconds,
      rootIdentity: FileIdentity(device: device, inode: rootInode)
    )

    let presentation = try CleanupManifestReviewPresentation.prepare(manifest: manifest)
    let row = try #require(presentation.entries.first)
    let finding = try #require(row.findings.first)
    let userFacingStrings = [
      row.displayPath,
      row.displayName,
      row.responsibleTool,
      row.classificationExplanation,
      row.ruleRevisionLabel,
      finding.identifier,
      finding.explanation,
    ]

    #expect(manifest.requiresExplicitApproval)
    #expect(manifest.requiresExecutionRevalidation)
    #expect(row.id == entry.path)
    #expect(
      storedPropertyLabels(of: presentation) == [
        "deferredExecutionPreconditionCount", "entries", "entryCount", "reclaimableCount",
        "reviewRequiredCount", "totals",
      ])
    #expect(
      storedPropertyLabels(of: row) == [
        "classificationExplanation",
        "deferredExecutionPreconditions",
        "displayName",
        "displayPath",
        "disposition",
        "findings",
        "id",
        "reproducibility",
        "responsibleTool",
        "ruleRevisionLabel",
        "size",
      ])
    #expect(
      storedPropertyLabels(of: finding) == ["explanation", "identifier", "kind", "state"]
    )
    #expect(
      storedPropertyLabels(of: presentation.totals) == [
        "nonExclusiveHardLinkFileCount",
        "observedAllocatedBytes",
        "observedHardLinkExclusiveAllocatedBytes",
        "observedLogicalBytes",
        "possibleSharedContentFileCount",
        "sharedContentMetadataUnavailableCount",
        "unobservedHardLinkFileCount",
      ])

    let forbiddenValues = [
      String(device),
      String(entryInode),
      String(rootInode),
      String(referenceUnixSeconds),
      rawNameBase64,
    ]
    for forbiddenValue in forbiddenValues {
      #expect(userFacingStrings.allSatisfy { !$0.contains(forbiddenValue) })
    }

    let forbiddenFieldFragments = [
      "identity", "inode", "device", "root", "time", "base64", "authority", "approval",
      "manifest",
    ]
    let allFieldLabels =
      storedPropertyLabels(of: presentation)
      + storedPropertyLabels(of: row)
      + storedPropertyLabels(of: finding)
      + storedPropertyLabels(of: presentation.totals)
    for fragment in forbiddenFieldFragments {
      #expect(allFieldLabels.allSatisfy { !$0.lowercased().contains(fragment) })
    }
    #expect((presentation as Any) is any Encodable == false)
  }

  @Test("Pre-cancellation returns no review presentation")
  func cancellation() async throws {
    let manifest = try ManifestReviewFixture.manifest(
      entries: [ManifestReviewFixture.entry()]
    )
    let wasCancelled = await Task {
      withUnsafeCurrentTask { task in
        task?.cancel()
      }
      do {
        _ = try CleanupManifestReviewPresentation.prepare(manifest: manifest)
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }.value

    #expect(wasCancelled)
  }

  @Test("Boundary-scale traversal observes cancellation inside both nested loops")
  func boundaryScaleCancellationChecks() throws {
    let findings = try (0..<20).map { index in
      try ManifestReviewFixture.finding(
        identifier: "test.finding-\(index)",
        explanation: "Boundary finding \(index)."
      )
    }
    let entry = try ManifestReviewFixture.entry(findings: findings)
    let manifest = try ManifestReviewFixture.manifest(
      entries: Array(
        repeating: entry,
        count: CleanupPlanningLimits.maximumSelections
      )
    )
    let totalFindingCount = manifest.entries.reduce(into: 0) { count, entry in
      count += entry.findings.count
    }
    #expect(totalFindingCount == RuleCatalogLimits.maximumTotalEvaluationFindings)

    // This threshold is greater than either the entry checks or finding checks
    // could reach alone, so both nested-loop check sites are covered.
    let cancellationThreshold = 1_025_000
    var checkCount = 0
    let wasCancelled: Bool
    do {
      _ = try CleanupManifestReviewPresentation.prepare(
        manifest: manifest,
        cancellationCheck: {
          checkCount += 1
          if checkCount == cancellationThreshold {
            throw CancellationError()
          }
        }
      )
      wasCancelled = false
    } catch is CancellationError {
      wasCancelled = true
    } catch {
      wasCancelled = false
    }

    #expect(wasCancelled)
    #expect(checkCount == cancellationThreshold)
  }

  private func storedPropertyLabels(of value: some Any) -> [String] {
    Mirror(reflecting: value).children.compactMap(\.label).sorted()
  }
}

private enum ManifestReviewFixture {
  static func revision(
    identifier: String = "devsift.test.review",
    version: UInt32 = 1
  ) throws -> RuleRevision {
    RuleRevision(
      identifier: try #require(RuleIdentifier(rawValue: identifier)),
      version: try #require(RuleVersion(rawValue: version))
    )
  }

  static func finding(
    identifier: String = "test.positive-evidence",
    kind: RuleFindingKind = .positiveEvidence,
    state: RuleFindingState = .satisfied,
    explanation: String = "Synthetic review evidence."
  ) throws -> RuleFinding {
    RuleFinding(
      identifier: try #require(CheckIdentifier(rawValue: identifier)),
      kind: kind,
      state: state,
      explanation: explanation
    )
  }

  static func entry(
    rawName: [UInt8] = Array("cache".utf8),
    identity: FileIdentity = FileIdentity(device: 42, inode: 2),
    ruleIdentifier: String = "devsift.test.review",
    ruleVersion: UInt32 = 1,
    disposition: RuleDisposition = .reviewRequired,
    reproducibility: RuleReproducibility = .reproducible,
    displayName: String = "Review cache",
    responsibleTool: String = "Review tool",
    classificationExplanation: String = "Synthetic review classification.",
    findings: [RuleFinding]? = nil,
    deferredExecutionPreconditions: [RuleDeferredExecutionPrecondition] = [],
    logicalBytes: UInt64 = 1_024,
    allocatedBytes: UInt64 = 768,
    hardLinkExclusiveAllocatedBytes: UInt64 = 512,
    possibleSharedContentFileCount: UInt64 = 1,
    sharedContentMetadataUnavailableCount: UInt64 = 2,
    unobservedHardLinkFileCount: UInt64 = 3,
    nonExclusiveHardLinkFileCount: UInt64 = 4
  ) throws -> CleanupManifestEntry {
    let summary = AppTestReportFactory.item(
      rawComponents: [rawName],
      scanTimeIdentity: identity,
      logicalBytes: logicalBytes,
      allocatedBytes: allocatedBytes,
      hardLinkExclusiveAllocatedBytes: hardLinkExclusiveAllocatedBytes,
      possibleSharedContentFileCount: possibleSharedContentFileCount,
      sharedContentMetadataUnavailableCount: sharedContentMetadataUnavailableCount,
      unobservedHardLinkFileCount: unobservedHardLinkFileCount,
      nonExclusiveHardLinkFileCount: nonExclusiveHardLinkFileCount
    )
    return CleanupManifestEntry(
      path: summary.path,
      expectedKind: .directory,
      expectedIdentity: identity,
      ruleRevision: try revision(identifier: ruleIdentifier, version: ruleVersion),
      disposition: disposition,
      reproducibility: reproducibility,
      displayName: displayName,
      responsibleTool: responsibleTool,
      classificationExplanation: classificationExplanation,
      findings: try findings ?? [self.finding()],
      deferredExecutionPreconditions: deferredExecutionPreconditions,
      size: CleanupManifestSizeObservation(summary: summary)
    )
  }

  static func manifest(
    entries: [CleanupManifestEntry],
    referenceUnixSeconds: Int64 = 1_700_000_000,
    rootIdentity: FileIdentity = FileIdentity(device: 42, inode: 1)
  ) throws -> CleanupManifest {
    let selectedRevisions = Array(Set(entries.map(\.ruleRevision))).sorted()
    return try CleanupManifest(
      policyProvenance: RulePolicyProvenance(
        classificationContractRevision: revision(
          identifier: "devsift.test.classification-contract"
        ),
        catalogRevision: revision(identifier: "devsift.test.catalog"),
        ruleRevisions: selectedRevisions
      ),
      classificationReferenceUnixSeconds: referenceUnixSeconds,
      expectedRootIdentity: rootIdentity,
      entries: entries
    )
  }
}
