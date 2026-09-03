@testable import DevSiftCore

let diffRuleRevisionA = RuleRevision(
  identifier: testRuleIdentifier("devsift.test.diff-a"),
  version: testRuleVersion()
)

let diffRuleRevisionB = RuleRevision(
  identifier: testRuleIdentifier("devsift.test.diff-b"),
  version: testRuleVersion()
)

func diffPolicyProvenance(
  catalogVersion: UInt32 = 1,
  classificationVersion: UInt32 = 1,
  ruleRevisions: [RuleRevision] = [diffRuleRevisionA, diffRuleRevisionB]
) throws -> RulePolicyProvenance {
  try RulePolicyProvenance(
    classificationContractRevision: RuleRevision(
      identifier: testRuleIdentifier("devsift.test.diff-contract"),
      version: testRuleVersion(classificationVersion)
    ),
    catalogRevision: RuleRevision(
      identifier: testRuleIdentifier("devsift.test.diff-catalog"),
      version: testRuleVersion(catalogVersion)
    ),
    ruleRevisions: ruleRevisions
  )
}

func diffEntry(
  rawName: [UInt8],
  expectedKind: FileSystemEntryKind = .directory,
  expectedIdentity: FileIdentity = FileIdentity(device: 42, inode: 2),
  ruleRevision: RuleRevision = diffRuleRevisionA,
  disposition: RuleDisposition = .reclaimable,
  reproducibility: RuleReproducibility = .reproducible,
  displayName: String = "Diff candidate",
  responsibleTool: String = "Diff tool",
  classificationExplanation: String = "The diff candidate is eligible.",
  findings: [RuleFinding] = [
    RuleFinding(
      identifier: testCheckIdentifier("diff-evidence"),
      kind: .positiveEvidence,
      state: .satisfied,
      explanation: "Diff evidence is satisfied."
    )
  ],
  deferredExecutionPreconditions: [RuleDeferredExecutionPrecondition] = [],
  observedLogicalBytes: UInt64 = 10,
  observedAllocatedBytes: UInt64 = 8,
  observedHardLinkExclusiveAllocatedBytes: UInt64 = 6,
  possibleSharedContentFileCount: UInt64 = 1,
  sharedContentMetadataUnavailableCount: UInt64 = 2,
  unobservedHardLinkFileCount: UInt64 = 3,
  nonExclusiveHardLinkFileCount: UInt64 = 4
) -> CleanupManifestEntry {
  let candidate = PlanningTestCandidate(
    rawName: rawName,
    identity: expectedIdentity,
    kind: expectedKind,
    recursiveSize: StorageSize(
      logicalBytes: observedLogicalBytes,
      allocatedBytes: observedAllocatedBytes
    ),
    hardLinkExclusiveAllocatedBytes: observedHardLinkExclusiveAllocatedBytes,
    possibleSharedContentFileCount: possibleSharedContentFileCount,
    sharedContentMetadataUnavailableCount: sharedContentMetadataUnavailableCount,
    unobservedHardLinkFileCount: unobservedHardLinkFileCount,
    nonExclusiveHardLinkFileCount: nonExclusiveHardLinkFileCount
  )
  return CleanupManifestEntry(
    path: candidate.path,
    expectedKind: expectedKind,
    expectedIdentity: expectedIdentity,
    ruleRevision: ruleRevision,
    disposition: disposition,
    reproducibility: reproducibility,
    displayName: displayName,
    responsibleTool: responsibleTool,
    classificationExplanation: classificationExplanation,
    findings: findings,
    deferredExecutionPreconditions: deferredExecutionPreconditions,
    size: CleanupManifestSizeObservation(summary: candidate.summary)
  )
}

func diffManifest(
  entries: [CleanupManifestEntry],
  contractVersion: UInt32 = CleanupManifest.currentContractVersion,
  policyProvenance: RulePolicyProvenance? = nil,
  rootIdentity: FileIdentity = FileIdentity(device: 42, inode: 1),
  referenceUnixSeconds: Int64 = 100
) throws -> CleanupManifest {
  let resolvedProvenance: RulePolicyProvenance
  if let policyProvenance {
    resolvedProvenance = policyProvenance
  } else {
    resolvedProvenance = try diffPolicyProvenance()
  }
  return try CleanupManifest(
    contractVersion: contractVersion,
    policyProvenance: resolvedProvenance,
    classificationReferenceUnixSeconds: referenceUnixSeconds,
    expectedRootIdentity: rootIdentity,
    entries: entries
  )
}
