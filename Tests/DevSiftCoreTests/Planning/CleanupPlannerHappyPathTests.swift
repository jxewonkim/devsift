import Testing

@testable import DevSiftCore

@Suite("Cleanup planner happy paths")
struct CleanupPlannerHappyPathTests {
  @Test("Manifest is deterministic and retains review and revalidation evidence")
  func deterministicManifest() async throws {
    let uv = PlanningTestCandidate(
      rawName: Array("uv".utf8),
      identity: FileIdentity(device: 42, inode: 2),
      recursiveSize: StorageSize(logicalBytes: 2_000, allocatedBytes: 1_500),
      hardLinkExclusiveAllocatedBytes: 1_250,
      possibleSharedContentFileCount: 1,
      sharedContentMetadataUnavailableCount: 2,
      unobservedHardLinkFileCount: 3,
      nonExclusiveHardLinkFileCount: 4
    )
    let npm = PlanningTestCandidate(
      rawName: Array("_cacache".utf8),
      identity: FileIdentity(device: 42, inode: 3),
      recursiveSize: StorageSize(logicalBytes: 4_000, allocatedBytes: 3_000),
      hardLinkExclusiveAllocatedBytes: 2_500,
      possibleSharedContentFileCount: 5,
      sharedContentMetadataUnavailableCount: 6,
      unobservedHardLinkFileCount: 7,
      nonExclusiveHardLinkFileCount: 8
    )
    let scenario = try await makePlanningTestScenario(candidates: [uv, npm])
    let uvSelection = scenario.selection(for: uv.path)
    let npmSelection = scenario.selection(for: npm.path)
    let reversedFindings = scenario.classificationReport.evaluations.map { evaluation in
      planningEvaluation(evaluation, findings: evaluation.findings.reversed())
    }
    let reorderedReport = planningClassificationReport(
      scenario.classificationReport,
      evaluations: reversedFindings
    )

    let first = try CleanupPlanner().makeManifest(
      scenario.manifestRequest(selections: [uvSelection, npmSelection])
    )
    let second = try CleanupPlanner().makeManifest(
      scenario.manifestRequest(
        selections: [npmSelection, uvSelection],
        classificationReport: reorderedReport
      )
    )

    #expect(first == second)
    #expect(first.contractVersion == CleanupManifest.currentContractVersion)
    #expect(first.contractVersion == 3)
    #expect(first.policyProvenance == scenario.classificationReport.policyProvenance)
    #expect(first.policyProvenance.catalogRevision == BuiltInRuleCatalog.revision)
    #expect(first.classificationReferenceUnixSeconds == 1_000_000)
    #expect(first.expectedRootIdentity == FileIdentity(device: 42, inode: 1))
    #expect(first.entries.map(\.path) == [npm.path, uv.path])
    #expect(first.entries.map(\.disposition) == [.reviewRequired, .reclaimable])
    #expect(first.entries.allSatisfy { $0.expectedKind == .directory })
    #expect(first.entries.map(\.expectedIdentity) == [npm.identity, uv.identity])
    #expect(first.entries.allSatisfy { $0.deferredExecutionPreconditions.isEmpty })
    #expect(
      first.entries.allSatisfy { entry in
        entry.findings == entry.findings.sorted { $0.identifier < $1.identifier }
          && entry.findings.allSatisfy { $0.state == .satisfied }
          && !entry.displayName.isEmpty
          && !entry.responsibleTool.isEmpty
          && !entry.classificationExplanation.isEmpty
      })
    #expect(first.requiresExplicitApproval)
    #expect(first.requiresExecutionRevalidation)
    #expect(first.totals.observedLogicalBytes == 6_000)
    #expect(first.totals.observedAllocatedBytes == 4_500)
    #expect(first.totals.observedHardLinkExclusiveAllocatedBytes == 3_750)
    #expect(first.totals.possibleSharedContentFileCount == 6)
    #expect(first.totals.sharedContentMetadataUnavailableCount == 8)
    #expect(first.totals.unobservedHardLinkFileCount == 10)
    #expect(first.totals.nonExclusiveHardLinkFileCount == 12)

    let rebuilt = try CleanupManifest(
      policyProvenance: first.policyProvenance,
      classificationReferenceUnixSeconds: first.classificationReferenceUnixSeconds,
      expectedRootIdentity: first.expectedRootIdentity,
      entries: first.entries.reversed()
    )
    #expect(rebuilt == first)
  }

  @Test("Manifest retains a valid deferred execution precondition without rewriting its evidence")
  func deferredExecutionPreconditionRetention() async throws {
    let candidate = PlanningTestCandidate(
      rawName: Array("candidate".utf8),
      identity: FileIdentity(device: 42, inode: 2),
      facts: satisfiedRuleFacts(activity: .unknown(.notCollected))
    )
    let definition = syntheticDefinition(
      id: "devsift.test.planning-deferred-activity",
      disposition: .reviewRequired,
      reproducibility: .conditional,
      activity: .mustBeInactiveOrDeferToAttestationWhenUnobserved
    )
    let scenario = try await makePlanningTestScenario(
      candidates: [candidate],
      rules: [SyntheticRule(definition: definition)]
    )
    let evaluation = try #require(scenario.classificationReport.evaluations.first)

    let manifest = try CleanupPlanner().makeManifest(
      scenario.manifestRequest(selections: [scenario.selection(for: candidate.path)])
    )
    let entry = try #require(manifest.entries.first)

    #expect(evaluation.matchState == .matched)
    #expect(evaluation.disposition == .reviewRequired)
    #expect(
      evaluation.deferredExecutionPreconditions
        == [.requiresUserAttestationThatResponsibleToolIsStopped]
    )
    #expect(entry.findings == evaluation.findings.sorted { $0.identifier < $1.identifier })
    #expect(entry.deferredExecutionPreconditions == evaluation.deferredExecutionPreconditions)
    #expect(entry.deferredExecutionPreconditionsAreWellFormed)
    #expect(entry.nonDeferredBlockingFindings.isEmpty)
    #expect(
      entry.findings.first { $0.identifier == AutomaticCheckIdentifier.activity }?.state
        == .unknown(.notCollected)
    )
  }

  @Test("An explicit empty selection produces a bound empty draft")
  func emptySelection() async throws {
    let eligibleButUnselected = PlanningTestCandidate(
      rawName: Array("uv".utf8),
      identity: FileIdentity(device: 42, inode: 2)
    )
    let scenario = try await makePlanningTestScenario(
      candidates: [eligibleButUnselected]
    )

    let manifest = try CleanupPlanner().makeManifest(
      scenario.manifestRequest(selections: [])
    )

    #expect(manifest.entries.isEmpty)
    #expect(manifest.expectedRootIdentity == FileIdentity(device: 42, inode: 1))
    #expect(manifest.totals.observedLogicalBytes == 0)
    #expect(manifest.totals.observedAllocatedBytes == 0)
    #expect(manifest.totals.observedHardLinkExclusiveAllocatedBytes == 0)
    #expect(manifest.requiresExplicitApproval)
    #expect(manifest.requiresExecutionRevalidation)
  }

  @Test("A maximum-length raw candidate name remains selectable")
  func maximumCandidateNameLength() async throws {
    let candidate = PlanningTestCandidate(
      rawName: Array(
        repeating: 0x61,
        count: CleanupPlanningLimits.maximumCandidateComponentBytes
      ),
      identity: FileIdentity(device: 42, inode: 12)
    )
    let definition = syntheticDefinition(id: "devsift.test.maximum-name")
    let scenario = try await makePlanningTestScenario(
      candidates: [candidate],
      rules: [SyntheticRule(definition: definition)]
    )

    let manifest = try CleanupPlanner().makeManifest(
      scenario.manifestRequest(selections: [scenario.selection(for: candidate.path)])
    )

    #expect(manifest.entries.map(\.path) == [candidate.path])
    #expect(manifest.policyProvenance.catalogRevision == planningTestCatalogRevision)
  }

  @Test("Identity values are evidence and are not used as unique entry keys")
  func duplicateCandidateIdentities() async throws {
    let sharedIdentity = FileIdentity(device: 42, inode: 9)
    let uv = PlanningTestCandidate(rawName: Array("uv".utf8), identity: sharedIdentity)
    let npm = PlanningTestCandidate(rawName: Array("_cacache".utf8), identity: sharedIdentity)
    let scenario = try await makePlanningTestScenario(candidates: [uv, npm])

    let manifest = try CleanupPlanner().makeManifest(
      scenario.manifestRequest(
        selections: [scenario.selection(for: uv.path), scenario.selection(for: npm.path)]
      )
    )

    #expect(manifest.entries.count == 2)
    #expect(manifest.entries.allSatisfy { $0.expectedIdentity == sharedIdentity })
  }

  @Test("Exact raw path bytes determine order even when display text collides")
  func exactRawPathOrdering() async throws {
    let escaped = PlanningTestCandidate(
      rawName: Array("\\xFF".utf8),
      identity: FileIdentity(device: 42, inode: 10)
    )
    let nonUTF8 = PlanningTestCandidate(
      rawName: [0xFF],
      identity: FileIdentity(device: 42, inode: 11)
    )
    let definition = syntheticDefinition(id: "devsift.test.raw-order")
    let scenario = try await makePlanningTestScenario(
      candidates: [nonUTF8, escaped],
      rules: [SyntheticRule(definition: definition)]
    )

    let manifest = try CleanupPlanner().makeManifest(
      scenario.manifestRequest(
        selections: [
          scenario.selection(for: nonUTF8.path),
          scenario.selection(for: escaped.path),
        ]
      )
    )

    #expect(escaped.path.description == nonUTF8.path.description)
    #expect(manifest.entries.map(\.path) == [escaped.path, nonUTF8.path])
    #expect(manifest.entries[0].path.rawComponents != manifest.entries[1].path.rawComponents)
  }
}
