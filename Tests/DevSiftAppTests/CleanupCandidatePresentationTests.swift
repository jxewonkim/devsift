import DevSiftCore
import Foundation
import Testing

@testable import DevSiftApp
@testable import DevSiftCore

@Suite("Cleanup candidate presentation")
struct CleanupCandidatePresentationTests {
  private let referenceUnixSeconds: Int64 = 1_700_000_000
  private let device: UInt64 = 42

  @Test("Eligible rows retain exact byte-distinct non-UTF-8 selections")
  func exactByteDistinctSelections() async throws {
    let rule = try revision("devsift.test.cache")
    let first = item(rawComponents: [[0x63, 0x61, 0x80]], inode: 10)
    let second = item(rawComponents: [[0x63, 0x61, 0x81]], inode: 11)
    let report = completeReport(items: [first, second])
    let classification = try classification(
      evaluations: [
        evaluation(
          path: second.path,
          rule: rule,
          matchingRules: [rule],
          matchState: .matched,
          disposition: .reviewRequired,
          reproducibility: .conditional,
          findings: satisfiedEvidence()
        ),
        evaluation(
          path: first.path,
          rule: rule,
          matchingRules: [rule],
          matchState: .matched,
          disposition: .reclaimable,
          reproducibility: .reproducible,
          findings: satisfiedEvidence()
        ),
      ],
      declaredRules: [rule]
    )

    let presentation = try await ScanPresentation.prepare(
      report: report,
      classification: classification
    )

    let selections = presentation.items.compactMap(\.cleanupSelection)
    #expect(
      Set(selections)
        == Set([
          CleanupCandidateSelection(path: first.path, ruleRevision: rule),
          CleanupCandidateSelection(path: second.path, ruleRevision: rule),
        ])
    )
    #expect(selections.count == 2)
    #expect(
      Set(selections.map(\.path.rawComponents))
        == Set([first.path, second.path].map(\.rawComponents)))
  }

  @Test("Protected, possible-match and conflicting decisions never become candidates")
  func protectedPolicyDecisions() async throws {
    let firstRule = try revision("devsift.test.first")
    let secondRule = try revision("devsift.test.second")
    let protectedItem = item(rawComponents: [Array("protected".utf8)], inode: 20)
    let possibleItem = item(rawComponents: [Array("possible".utf8)], inode: 21)
    let conflictItem = item(rawComponents: [Array("conflict".utf8)], inode: 22)
    let report = completeReport(items: [protectedItem, possibleItem, conflictItem])
    let classification = try classification(
      evaluations: [
        evaluation(
          path: protectedItem.path,
          rule: nil,
          matchingRules: [],
          matchState: .unrecognized,
          disposition: .protected,
          reproducibility: .unknown,
          findings: [blockingFinding()]
        ),
        evaluation(
          path: possibleItem.path,
          rule: firstRule,
          matchingRules: [firstRule],
          matchState: .possibleMatch,
          disposition: .protected,
          reproducibility: .reproducible,
          findings: [blockingFinding()]
        ),
        evaluation(
          path: conflictItem.path,
          rule: nil,
          matchingRules: [firstRule, secondRule],
          matchState: .conflict,
          disposition: .protected,
          reproducibility: .unknown,
          findings: [blockingFinding()]
        ),
      ],
      declaredRules: [firstRule, secondRule]
    )

    let presentation = try await ScanPresentation.prepare(
      report: report,
      classification: classification
    )

    #expect(presentation.items.allSatisfy { $0.cleanupSelection == nil })
    #expect(presentation.items.allSatisfy { !$0.policy.isMalformed })
    #expect(
      Set(presentation.items.map(\.policy.matchState)) == [
        .unrecognized, .possibleMatch, .conflict,
      ])
  }

  @Test("Malformed matched policy decisions remain ineligible")
  func malformedMatchedDecisions() async throws {
    let selectedRule = try revision("devsift.test.selected")
    let otherRule = try revision("devsift.test.other")
    let duplicate = item(rawComponents: [Array("duplicate".utf8)], inode: 30)
    let mismatched = item(rawComponents: [Array("mismatch".utf8)], inode: 31)
    let failed = item(rawComponents: [Array("failed".utf8)], inode: 32)
    let unknown = item(rawComponents: [Array("unknown".utf8)], inode: 33)
    let conditional = item(rawComponents: [Array("conditional".utf8)], inode: 34)
    let report = completeReport(
      items: [duplicate, mismatched, failed, unknown, conditional]
    )
    let duplicateEvaluation = evaluation(
      path: duplicate.path,
      rule: selectedRule,
      matchingRules: [selectedRule],
      matchState: .matched,
      disposition: .reclaimable,
      reproducibility: .reproducible,
      findings: satisfiedEvidence()
    )
    let classification = try classification(
      evaluations: [
        duplicateEvaluation,
        duplicateEvaluation,
        evaluation(
          path: mismatched.path,
          rule: selectedRule,
          matchingRules: [otherRule],
          matchState: .matched,
          disposition: .reclaimable,
          reproducibility: .reproducible,
          findings: satisfiedEvidence()
        ),
        evaluation(
          path: failed.path,
          rule: selectedRule,
          matchingRules: [selectedRule],
          matchState: .matched,
          disposition: .reclaimable,
          reproducibility: .reproducible,
          findings: [blockingFinding()] + satisfiedEvidence()
        ),
        evaluation(
          path: unknown.path,
          rule: selectedRule,
          matchingRules: [selectedRule],
          matchState: .matched,
          disposition: .reviewRequired,
          reproducibility: .unknown,
          findings: satisfiedEvidence()
        ),
        evaluation(
          path: conditional.path,
          rule: selectedRule,
          matchingRules: [selectedRule],
          matchState: .matched,
          disposition: .reclaimable,
          reproducibility: .conditional,
          findings: satisfiedEvidence()
        ),
      ],
      declaredRules: [selectedRule, otherRule]
    )

    let presentation = try await ScanPresentation.prepare(
      report: report,
      classification: classification
    )

    #expect(presentation.items.allSatisfy { $0.cleanupSelection == nil })
    #expect(presentation.items.allSatisfy { $0.policy.isMalformed })
  }

  @Test("Incomplete reports, roots and missing provenance disable every candidate")
  func incompleteReportGates() async throws {
    let rule = try revision("devsift.test.cache")
    let candidate = item(rawComponents: [Array("cache".utf8)], inode: 40)
    let evaluation = evaluation(
      path: candidate.path,
      rule: rule,
      matchingRules: [rule],
      matchState: .matched,
      disposition: .reclaimable,
      reproducibility: .reproducible,
      findings: satisfiedEvidence()
    )
    let invalidReports = [
      completeReport(
        root: root(hasIdentity: false),
        items: [candidate]
      ),
      completeReport(
        root: root(unknownAllocatedItemCount: 1),
        items: [candidate]
      ),
      completeReport(
        root: root(sizeOverflowed: true),
        items: [candidate]
      ),
      completeReport(
        root: root(isComplete: false),
        items: [candidate]
      ),
      completeReport(items: [candidate], hardLinkAccountingIsComplete: false),
    ]

    for report in invalidReports {
      let result = try await ScanPresentation.prepare(
        report: report,
        classification: try classification(
          evaluations: [evaluation],
          declaredRules: [rule]
        )
      )
      #expect(result.items.first?.cleanupSelection == nil)
    }

    let missingProvenance = try await ScanPresentation.prepare(
      report: completeReport(items: [candidate]),
      classification: RuleClassificationReport(
        referenceUnixSeconds: referenceUnixSeconds,
        evaluations: [evaluation]
      )
    )
    #expect(missingProvenance.items.first?.cleanupSelection == nil)

    let undeclaredRule = try await ScanPresentation.prepare(
      report: completeReport(items: [candidate]),
      classification: try classification(
        evaluations: [evaluation],
        declaredRules: [try revision("devsift.test.different")]
      )
    )
    #expect(undeclaredRule.items.first?.cleanupSelection == nil)
  }

  @Test("Planner-specific identity evidence is required for a candidate")
  func identityEvidenceGate() async throws {
    let rule = try revision("devsift.test.cache")
    let candidate = item(rawComponents: [Array("cache".utf8)], inode: 45)
    let classification = try classification(
      evaluations: [
        evaluation(
          path: candidate.path,
          rule: rule,
          matchingRules: [rule],
          matchState: .matched,
          disposition: .reviewRequired,
          reproducibility: .conditional,
          findings: [
            finding("test.positive", kind: .positiveEvidence, state: .satisfied),
            finding("test.exclusion", kind: .exclusion, state: .satisfied),
          ]
        )
      ],
      declaredRules: [rule]
    )

    let presentation = try await ScanPresentation.prepare(
      report: completeReport(items: [candidate]),
      classification: classification
    )

    #expect(presentation.items.first?.policy.isMalformed == false)
    #expect(presentation.items.first?.cleanupSelection == nil)
  }

  @Test("Incomplete, ambiguous or invalid item observations remain ineligible")
  func incompleteItemGates() async throws {
    let rule = try revision("devsift.test.cache")
    let invalidItems = [
      item(rawComponents: [Array("nested".utf8), Array("cache".utf8)], inode: 50),
      item(rawComponents: [Array("file".utf8)], kind: .regularFile, inode: 51),
      item(rawComponents: [Array("incomplete".utf8)], inode: 52, isComplete: false),
      item(rawComponents: [Array("missing-id".utf8)], hasIdentity: false),
      item(rawComponents: [Array("other-device".utf8)], device: device + 1, inode: 54),
      item(rawComponents: [Array("overflow".utf8)], inode: 55, sizeOverflowed: true),
      item(rawComponents: [Array("unknown".utf8)], inode: 56, unknownAllocatedItemCount: 1),
      item(
        rawComponents: [Array("bad-size".utf8)],
        inode: 57,
        allocatedBytes: 4_096,
        hardLinkExclusiveAllocatedBytes: 8_192
      ),
    ]

    for candidate in invalidItems {
      let report = completeReport(items: [candidate])
      let result = try await ScanPresentation.prepare(
        report: report,
        classification: try classification(
          evaluations: [
            evaluation(
              path: candidate.path,
              rule: rule,
              matchingRules: [rule],
              matchState: .matched,
              disposition: .reclaimable,
              reproducibility: .reproducible,
              findings: satisfiedEvidence()
            )
          ],
          declaredRules: [rule]
        )
      )
      #expect(result.items.first?.cleanupSelection == nil)
    }

    let duplicate = item(rawComponents: [Array("duplicate".utf8)], inode: 58)
    let duplicateResult = try await ScanPresentation.prepare(
      report: completeReport(items: [duplicate, duplicate]),
      classification: try classification(
        evaluations: [
          evaluation(
            path: duplicate.path,
            rule: rule,
            matchingRules: [rule],
            matchState: .matched,
            disposition: .reclaimable,
            reproducibility: .reproducible,
            findings: satisfiedEvidence()
          )
        ],
        declaredRules: [rule]
      )
    )
    #expect(duplicateResult.items.allSatisfy { $0.cleanupSelection == nil })
  }

  private func completeReport(
    root: ScanItemSummary? = nil,
    items: [ScanItemSummary],
    hardLinkAccountingIsComplete: Bool = true
  ) -> ScanReport {
    AppTestReportFactory.report(
      root: root ?? self.root(),
      topLevelItems: items,
      hardLinkAccountingIsComplete: hardLinkAccountingIsComplete
    )
  }

  private func root(
    hasIdentity: Bool = true,
    unknownAllocatedItemCount: UInt64 = 0,
    sizeOverflowed: Bool = false,
    isComplete: Bool = true
  ) -> ScanItemSummary {
    AppTestReportFactory.item(
      scanTimeIdentity: hasIdentity ? FileIdentity(device: device, inode: 1) : nil,
      allocatedBytes: 16_384,
      hardLinkExclusiveAllocatedBytes: 16_384,
      unknownAllocatedItemCount: unknownAllocatedItemCount,
      sizeOverflowed: sizeOverflowed,
      isComplete: isComplete
    )
  }

  private func item(
    rawComponents: [[UInt8]],
    kind: FileSystemEntryKind = .directory,
    hasIdentity: Bool = true,
    device: UInt64? = nil,
    inode: UInt64 = 2,
    allocatedBytes: UInt64 = 8_192,
    hardLinkExclusiveAllocatedBytes: UInt64 = 8_192,
    unknownAllocatedItemCount: UInt64 = 0,
    sizeOverflowed: Bool = false,
    isComplete: Bool = true
  ) -> ScanItemSummary {
    AppTestReportFactory.item(
      rawComponents: rawComponents,
      kind: kind,
      scanTimeIdentity: hasIdentity
        ? FileIdentity(device: device ?? self.device, inode: inode)
        : nil,
      allocatedBytes: allocatedBytes,
      hardLinkExclusiveAllocatedBytes: hardLinkExclusiveAllocatedBytes,
      unknownAllocatedItemCount: unknownAllocatedItemCount,
      sizeOverflowed: sizeOverflowed,
      isComplete: isComplete
    )
  }

  private func classification(
    evaluations: [RuleEvaluation],
    declaredRules: [RuleRevision]
  ) throws -> RuleClassificationReport {
    RuleClassificationReport(
      referenceUnixSeconds: referenceUnixSeconds,
      evaluations: evaluations,
      policyProvenance: try RulePolicyProvenance(
        classificationContractRevision: revision("devsift.test.classification-contract"),
        catalogRevision: revision("devsift.test.catalog"),
        ruleRevisions: declaredRules
      ),
      sourceBinding: nil
    )
  }

  private func evaluation(
    path: ScanRelativePath,
    rule: RuleRevision?,
    matchingRules: [RuleRevision],
    matchState: RuleMatchState,
    disposition: RuleDisposition,
    reproducibility: RuleReproducibility,
    findings: [RuleFinding]
  ) -> RuleEvaluation {
    RuleEvaluation(
      path: path,
      rule: rule,
      matchingRules: matchingRules,
      displayName: "Synthetic cache",
      responsibleTool: "Synthetic tool",
      matchState: matchState,
      disposition: disposition,
      reproducibility: reproducibility,
      findings: findings,
      explanation: "Synthetic classification."
    )
  }

  private func satisfiedEvidence() -> [RuleFinding] {
    [
      finding("test.positive", kind: .positiveEvidence, state: .satisfied),
      finding("test.exclusion", kind: .exclusion, state: .satisfied),
      finding("identity-matches-scan", kind: .scanIntegrity, state: .satisfied),
    ]
  }

  private func blockingFinding() -> RuleFinding {
    finding("test.blocking", kind: .exclusion, state: .failed)
  }

  private func finding(
    _ identifier: String,
    kind: RuleFindingKind,
    state: RuleFindingState
  ) -> RuleFinding {
    guard let checkIdentifier = CheckIdentifier(rawValue: identifier) else {
      preconditionFailure("Invalid test check identifier: \(identifier)")
    }
    return RuleFinding(
      identifier: checkIdentifier,
      kind: kind,
      state: state,
      explanation: "Synthetic evidence."
    )
  }

  private func revision(_ identifier: String, version: UInt32 = 1) throws -> RuleRevision {
    RuleRevision(
      identifier: try #require(RuleIdentifier(rawValue: identifier)),
      version: try #require(RuleVersion(rawValue: version))
    )
  }
}
