import Foundation
import Testing

@testable import DevSiftCore

@Suite("Cleanup manifest differ")
struct CleanupManifestDifferTests {
  @Test("Equal retained entries remain unchanged across arbitrary reference times")
  func equalEntries() throws {
    let a = diffEntry(rawName: Array("a".utf8))
    let b = diffEntry(
      rawName: Array("b".utf8),
      expectedIdentity: FileIdentity(device: 42, inode: 3)
    )
    let baseline = try diffManifest(
      entries: [b, a],
      referenceUnixSeconds: Int64.max
    )
    let comparison = try diffManifest(
      entries: [a, b],
      referenceUnixSeconds: Int64.min
    )

    let result = try CleanupManifestDiffer().difference(
      from: baseline,
      to: comparison
    )

    #expect(result.contractVersion == CleanupManifestDiff.currentContractVersion)
    #expect(result.sourceManifestContractVersion == CleanupManifest.currentContractVersion)
    #expect(result.policyProvenance == baseline.policyProvenance)
    #expect(result.expectedRootIdentity == baseline.expectedRootIdentity)
    #expect(result.baselineReferenceUnixSeconds == Int64.max)
    #expect(result.comparisonReferenceUnixSeconds == Int64.min)
    #expect(result.baselineEntryCount == 2)
    #expect(result.comparisonEntryCount == 2)
    #expect(result.unchangedEntryCount == 2)
    #expect(result.entryDifferences.isEmpty)
    #expect(result.isEmpty)
    #expect(result.totals.observedLogicalBytes == .unchanged)
    #expect(result.totals.observedAllocatedBytes == .unchanged)
    #expect(result.totals.observedHardLinkExclusiveAllocatedBytes == .unchanged)
    #expect(result.totals.possibleSharedContentFileCount == .unchanged)
    #expect(result.totals.sharedContentMetadataUnavailableCount == .unchanged)
    #expect(result.totals.unobservedHardLinkFileCount == .unchanged)
    #expect(result.totals.nonExclusiveHardLinkFileCount == .unchanged)
  }

  @Test("Added, removed, and modified entries use one global raw-path order")
  func mixedDifferences() throws {
    let unchanged = diffEntry(rawName: Array("a".utf8))
    let removed = diffEntry(
      rawName: Array("b".utf8),
      expectedIdentity: FileIdentity(device: 42, inode: 3),
      observedLogicalBytes: 20,
      observedAllocatedBytes: 16,
      observedHardLinkExclusiveAllocatedBytes: 12
    )
    let changedBefore = diffEntry(
      rawName: Array("c".utf8),
      expectedIdentity: FileIdentity(device: 42, inode: 4),
      observedLogicalBytes: 30,
      observedAllocatedBytes: 24,
      observedHardLinkExclusiveAllocatedBytes: 18
    )
    let changedAfter = diffEntry(
      rawName: Array("c".utf8),
      expectedIdentity: FileIdentity(device: 42, inode: 40),
      observedLogicalBytes: 35,
      observedAllocatedBytes: 28,
      observedHardLinkExclusiveAllocatedBytes: 21
    )
    let added = diffEntry(
      rawName: Array("d".utf8),
      expectedIdentity: FileIdentity(device: 42, inode: 5),
      observedLogicalBytes: 40,
      observedAllocatedBytes: 32,
      observedHardLinkExclusiveAllocatedBytes: 24
    )
    let baseline = try diffManifest(entries: [changedBefore, unchanged, removed])
    let comparison = try diffManifest(entries: [added, changedAfter, unchanged])

    let result = try CleanupManifestDiffer().difference(
      from: baseline,
      to: comparison
    )

    #expect(result.entryDifferences.map(\.path) == [removed.path, changedBefore.path, added.path])
    #expect(result.unchangedEntryCount == 1)
    #expect(!result.isEmpty)
    #expect(result.totals.observedLogicalBytes == .increased(by: 25))
    #expect(result.totals.observedAllocatedBytes == .increased(by: 20))
    #expect(
      result.totals.observedHardLinkExclusiveAllocatedBytes == .increased(by: 15)
    )
    #expect(result.totals.possibleSharedContentFileCount == .unchanged)

    guard case .removed(let removedResult) = result.entryDifferences[0] else {
      Issue.record("Expected a removed entry")
      return
    }
    #expect(removedResult == removed)

    guard case .modified(let modification) = result.entryDifferences[1] else {
      Issue.record("Expected a modified entry")
      return
    }
    #expect(modification.baseline == changedBefore)
    #expect(modification.comparison == changedAfter)
    #expect(
      modification.changedFields == [
        .expectedIdentity, .observedLogicalBytes,
        .observedAllocatedBytes, .observedHardLinkExclusiveAllocatedBytes,
      ])

    guard case .added(let addedResult) = result.entryDifferences[2] else {
      Issue.record("Expected an added entry")
      return
    }
    #expect(addedResult == added)
  }

  @Test("Empty and populated manifests reverse additions and removals")
  func emptyDirections() throws {
    let entry = diffEntry(rawName: Array("candidate".utf8))
    let empty = try diffManifest(entries: [])
    let populated = try diffManifest(entries: [entry])

    let addition = try CleanupManifestDiffer().difference(from: empty, to: populated)
    let removal = try CleanupManifestDiffer().difference(from: populated, to: empty)

    #expect(addition.unchangedEntryCount == 0)
    #expect(removal.unchangedEntryCount == 0)
    guard case .added(let added) = addition.entryDifferences.first,
      case .removed(let removed) = removal.entryDifferences.first
    else {
      Issue.record("Expected inverse addition and removal")
      return
    }
    #expect(added == entry)
    #expect(removed == entry)
    #expect(addition.totals.observedLogicalBytes == .increased(by: 10))
    #expect(removal.totals.observedLogicalBytes == .decreased(by: 10))
  }

  @Test(
    "Every stored entry field is represented in canonical change order",
    arguments: CleanupManifestEntryField.allCases)
  func individualChangedField(field: CleanupManifestEntryField) throws {
    let rawName = Array("candidate".utf8)
    let baselineEntry = diffEntry(rawName: rawName)
    let comparisonEntry = changedEntry(for: field, rawName: rawName)
    let result = try CleanupManifestDiffer().difference(
      from: diffManifest(entries: [baselineEntry]),
      to: diffManifest(entries: [comparisonEntry])
    )

    guard case .modified(let modification) = result.entryDifferences.first else {
      Issue.record("Expected a modified entry for \(field)")
      return
    }
    #expect(modification.changedFields == [field])
  }

  @Test("Entry storage shape remains synchronized with the diff field projection")
  func entryShapeTripwire() {
    let entry = diffEntry(rawName: Array("candidate".utf8))
    let entryLabels = Mirror(reflecting: entry).children.compactMap(\.label)
    let sizeLabels = Mirror(reflecting: entry.size).children.compactMap(\.label)

    #expect(
      entryLabels
        == [
          "path",
          "expectedKind",
          "expectedIdentity",
          "ruleRevision",
          "disposition",
          "reproducibility",
          "displayName",
          "responsibleTool",
          "classificationExplanation",
          "findings",
          "size",
        ]
    )
    #expect(
      sizeLabels
        == [
          "observedLogicalBytes",
          "observedAllocatedBytes",
          "observedHardLinkExclusiveAllocatedBytes",
          "possibleSharedContentFileCount",
          "sharedContentMetadataUnavailableCount",
          "unobservedHardLinkFileCount",
          "nonExclusiveHardLinkFileCount",
        ]
    )
    #expect(CleanupManifestEntryField.allCases.count == 16)
  }

  @Test("Multiple changed fields retain declaration order")
  func canonicalChangedFieldOrder() throws {
    let rawName = Array("candidate".utf8)
    let baseline = diffEntry(rawName: rawName)
    let comparison = diffEntry(
      rawName: rawName,
      expectedIdentity: FileIdentity(device: 42, inode: 99),
      displayName: "Changed display name",
      findings: changedFindings(),
      observedAllocatedBytes: 99,
      nonExclusiveHardLinkFileCount: 99
    )

    let result = try CleanupManifestDiffer().difference(
      from: diffManifest(entries: [baseline]),
      to: diffManifest(entries: [comparison])
    )

    guard case .modified(let modification) = result.entryDifferences.first else {
      Issue.record("Expected a modified entry")
      return
    }
    #expect(
      modification.changedFields
        == [
          .expectedIdentity,
          .displayName,
          .findings,
          .observedAllocatedBytes,
          .nonExclusiveHardLinkFileCount,
        ]
    )
  }

  @Test("Raw bytes are the path identity and inode equality never implies rename")
  func rawPathAndIdentitySemantics() throws {
    let identity = FileIdentity(device: 42, inode: 88)
    let escaped = diffEntry(
      rawName: Array("\\xFF".utf8),
      expectedIdentity: identity
    )
    let nonUTF8 = diffEntry(rawName: [0xFF], expectedIdentity: identity)
    #expect(escaped.path.description == nonUTF8.path.description)

    let result = try CleanupManifestDiffer().difference(
      from: diffManifest(entries: [escaped]),
      to: diffManifest(entries: [nonUTF8])
    )

    #expect(result.entryDifferences.map(\.path) == [escaped.path, nonUTF8.path])
    guard case .removed = result.entryDifferences[0],
      case .added = result.entryDifferences[1]
    else {
      Issue.record("Expected exact-path removal and addition")
      return
    }
  }

  @Test("Unsigned total differences preserve the full UInt64 range")
  func fullWidthQuantityDifferences() throws {
    let rawName = Array("candidate".utf8)
    let zero = diffEntry(
      rawName: rawName,
      observedLogicalBytes: 0,
      observedAllocatedBytes: 0,
      observedHardLinkExclusiveAllocatedBytes: 0,
      possibleSharedContentFileCount: 0,
      sharedContentMetadataUnavailableCount: 0,
      unobservedHardLinkFileCount: 0,
      nonExclusiveHardLinkFileCount: 0
    )
    let maximum = diffEntry(
      rawName: rawName,
      observedLogicalBytes: .max,
      observedAllocatedBytes: .max,
      observedHardLinkExclusiveAllocatedBytes: .max,
      possibleSharedContentFileCount: .max,
      sharedContentMetadataUnavailableCount: .max,
      unobservedHardLinkFileCount: .max,
      nonExclusiveHardLinkFileCount: .max
    )
    let zeroManifest = try diffManifest(entries: [zero])
    let maximumManifest = try diffManifest(entries: [maximum])

    let forward = try CleanupManifestDiffer().difference(
      from: zeroManifest,
      to: maximumManifest
    )
    let reverse = try CleanupManifestDiffer().difference(
      from: maximumManifest,
      to: zeroManifest
    )

    #expect(forward.totals.observedLogicalBytes == .increased(by: .max))
    #expect(forward.totals.observedAllocatedBytes == .increased(by: .max))
    #expect(
      forward.totals.observedHardLinkExclusiveAllocatedBytes == .increased(by: .max)
    )
    #expect(forward.totals.possibleSharedContentFileCount == .increased(by: .max))
    #expect(
      forward.totals.sharedContentMetadataUnavailableCount == .increased(by: .max)
    )
    #expect(forward.totals.unobservedHardLinkFileCount == .increased(by: .max))
    #expect(forward.totals.nonExclusiveHardLinkFileCount == .increased(by: .max))
    #expect(reverse.totals.observedLogicalBytes == .decreased(by: .max))
  }

  @Test("Incompatible manifest contracts fail before entry comparison")
  func contractCompatibility() throws {
    let entry = diffEntry(rawName: Array("candidate".utf8))
    let current = try diffManifest(entries: [entry])
    let old = try diffManifest(entries: [entry], contractVersion: 1)

    expectDiffError(
      .manifestContractVersionMismatch(
        baseline: CleanupManifest.currentContractVersion,
        comparison: 1
      ),
      baseline: current,
      comparison: old
    )
    expectDiffError(
      .unsupportedManifestContractVersion(1),
      baseline: old,
      comparison: old
    )
  }

  @Test("Policy and root mismatches are incompatible rather than partial diffs")
  func policyAndRootCompatibility() throws {
    let entry = diffEntry(rawName: Array("candidate".utf8))
    let basePolicy = try diffPolicyProvenance()
    let baseline = try diffManifest(entries: [entry], policyProvenance: basePolicy)
    let incompatiblePolicies = [
      try diffPolicyProvenance(classificationVersion: 2),
      try diffPolicyProvenance(catalogVersion: 2),
      try diffPolicyProvenance(ruleRevisions: [diffRuleRevisionA]),
    ]

    for policy in incompatiblePolicies {
      let comparison = try diffManifest(entries: [entry], policyProvenance: policy)
      #expect(baseline != comparison)
      expectDiffError(
        .policyProvenanceMismatch,
        baseline: baseline,
        comparison: comparison
      )
    }

    for root in [
      FileIdentity(device: 43, inode: 1),
      FileIdentity(device: 42, inode: 2),
    ] {
      expectDiffError(
        .rootIdentityMismatch,
        baseline: baseline,
        comparison: try diffManifest(
          entries: [entry],
          policyProvenance: basePolicy,
          rootIdentity: root
        )
      )
    }
  }

  @Test("Malformed entry collections and undeclared rules fail closed")
  func malformedManifestEntries() throws {
    let entry = diffEntry(rawName: Array("duplicate".utf8))
    let valid = try diffManifest(entries: [])
    let duplicated = try diffManifest(entries: [entry, entry])
    expectDiffError(
      .duplicateEntryPath(side: .comparison, path: entry.path),
      baseline: valid,
      comparison: duplicated
    )

    let overLimitEntries = Array(
      repeating: entry,
      count: CleanupPlanningLimits.maximumSelections + 1
    )
    let overLimit = try diffManifest(entries: overLimitEntries)
    expectDiffError(
      .tooManyEntries(
        side: .comparison,
        maximum: CleanupPlanningLimits.maximumSelections,
        actual: CleanupPlanningLimits.maximumSelections + 1
      ),
      baseline: valid,
      comparison: overLimit
    )

    let undeclaredPolicy = try diffPolicyProvenance(ruleRevisions: [diffRuleRevisionB])
    let undeclared = try diffManifest(
      entries: [entry],
      policyProvenance: undeclaredPolicy
    )
    let validForUndeclaredPolicy = try diffManifest(
      entries: [],
      policyProvenance: undeclaredPolicy
    )
    expectDiffError(
      .undeclaredPolicyRuleRevision(
        side: .comparison,
        path: entry.path,
        revision: diffRuleRevisionA
      ),
      baseline: validForUndeclaredPolicy,
      comparison: undeclared
    )
  }

  @Test("The maximum manifest entry count remains linear and accepted")
  func maximumEntryCount() throws {
    let baselineEntries = (0..<CleanupPlanningLimits.maximumSelections).map { index in
      diffEntry(
        rawName: Array(String(format: "a-%05d", index).utf8),
        expectedIdentity: FileIdentity(device: 42, inode: UInt64(index + 2)),
        observedLogicalBytes: 0,
        observedAllocatedBytes: 0,
        observedHardLinkExclusiveAllocatedBytes: 0,
        possibleSharedContentFileCount: 0,
        sharedContentMetadataUnavailableCount: 0,
        unobservedHardLinkFileCount: 0,
        nonExclusiveHardLinkFileCount: 0
      )
    }
    let comparisonEntries = (0..<CleanupPlanningLimits.maximumSelections).map { index in
      diffEntry(
        rawName: Array(String(format: "b-%05d", index).utf8),
        expectedIdentity: FileIdentity(device: 42, inode: UInt64(index + 2)),
        observedLogicalBytes: 0,
        observedAllocatedBytes: 0,
        observedHardLinkExclusiveAllocatedBytes: 0,
        possibleSharedContentFileCount: 0,
        sharedContentMetadataUnavailableCount: 0,
        unobservedHardLinkFileCount: 0,
        nonExclusiveHardLinkFileCount: 0
      )
    }
    let baseline = try diffManifest(entries: baselineEntries)
    let comparison = try diffManifest(entries: comparisonEntries)

    let unchanged = try CleanupManifestDiffer().difference(
      from: baseline,
      to: baseline
    )
    let disjoint = try CleanupManifestDiffer().difference(
      from: baseline,
      to: comparison
    )

    #expect(unchanged.unchangedEntryCount == CleanupPlanningLimits.maximumSelections)
    #expect(unchanged.entryDifferences.isEmpty)
    #expect(disjoint.unchangedEntryCount == 0)
    #expect(disjoint.entryDifferences.count == 2 * CleanupPlanningLimits.maximumSelections)
  }

  @Test("A cancelled task cannot produce a diff")
  func cancellation() async throws {
    let manifest = try diffManifest(entries: [])
    let task = Task {
      try CleanupManifestDiffer().difference(from: manifest, to: manifest)
    }
    task.cancel()

    do {
      _ = try await task.value
      Issue.record("Expected cancellation to prevent a diff")
    } catch is CancellationError {
      // Expected.
    }
  }

  private func changedEntry(
    for field: CleanupManifestEntryField,
    rawName: [UInt8]
  ) -> CleanupManifestEntry {
    switch field {
    case .expectedKind:
      diffEntry(rawName: rawName, expectedKind: .regularFile)
    case .expectedIdentity:
      diffEntry(
        rawName: rawName,
        expectedIdentity: FileIdentity(device: 42, inode: 99)
      )
    case .ruleRevision:
      diffEntry(rawName: rawName, ruleRevision: diffRuleRevisionB)
    case .disposition:
      diffEntry(rawName: rawName, disposition: .reviewRequired)
    case .reproducibility:
      diffEntry(rawName: rawName, reproducibility: .conditional)
    case .displayName:
      diffEntry(rawName: rawName, displayName: "Changed display name")
    case .responsibleTool:
      diffEntry(rawName: rawName, responsibleTool: "Changed tool")
    case .classificationExplanation:
      diffEntry(
        rawName: rawName,
        classificationExplanation: "Changed classification explanation."
      )
    case .findings:
      diffEntry(rawName: rawName, findings: changedFindings())
    case .observedLogicalBytes:
      diffEntry(rawName: rawName, observedLogicalBytes: 11)
    case .observedAllocatedBytes:
      diffEntry(rawName: rawName, observedAllocatedBytes: 9)
    case .observedHardLinkExclusiveAllocatedBytes:
      diffEntry(rawName: rawName, observedHardLinkExclusiveAllocatedBytes: 7)
    case .possibleSharedContentFileCount:
      diffEntry(rawName: rawName, possibleSharedContentFileCount: 5)
    case .sharedContentMetadataUnavailableCount:
      diffEntry(rawName: rawName, sharedContentMetadataUnavailableCount: 6)
    case .unobservedHardLinkFileCount:
      diffEntry(rawName: rawName, unobservedHardLinkFileCount: 7)
    case .nonExclusiveHardLinkFileCount:
      diffEntry(rawName: rawName, nonExclusiveHardLinkFileCount: 8)
    }
  }

  private func changedFindings() -> [RuleFinding] {
    [
      RuleFinding(
        identifier: testCheckIdentifier("diff-evidence"),
        kind: .positiveEvidence,
        state: .satisfied,
        explanation: "Changed diff evidence is satisfied."
      )
    ]
  }
}

private func expectDiffError(
  _ expected: CleanupManifestDiffError,
  baseline: CleanupManifest,
  comparison: CleanupManifest,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  do {
    _ = try CleanupManifestDiffer().difference(from: baseline, to: comparison)
    Issue.record("Expected manifest diff error \(expected)", sourceLocation: sourceLocation)
  } catch let error as CleanupManifestDiffError {
    #expect(error == expected, sourceLocation: sourceLocation)
  } catch {
    Issue.record("Unexpected error \(error)", sourceLocation: sourceLocation)
  }
}
