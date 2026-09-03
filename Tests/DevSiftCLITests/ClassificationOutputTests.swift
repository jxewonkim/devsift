import DevSiftCore
import Foundation
import Testing

@testable import DevSiftCLI
@testable import DevSiftCore

@Suite("Classification output")
struct ClassificationOutputTests {
  @Test("Text output is deterministic, terminal-safe, and explains every decision")
  func textOutput() {
    let firstPath = [[UInt8](arrayLiteral: 0xFF, 0x1B)]
    let secondPath = [Array("z\ncache".utf8)]
    let firstItem = CLITestReportFactory.item(
      rawComponents: firstPath,
      allocatedBytes: 8_192,
      hardLinkExclusiveAllocatedBytes: 4_096,
      unknownAllocatedItemCount: 1,
      isComplete: false
    )
    let secondItem = CLITestReportFactory.item(
      rawComponents: secondPath,
      allocatedBytes: 2_048,
      sizeOverflowed: true
    )
    let revision = CLITestClassificationFactory.revision(
      identifier: "devsift.test.cache",
      version: 7
    )
    let report = CLITestClassificationFactory.report(
      referenceUnixSeconds: -42,
      evaluations: [
        CLITestClassificationFactory.evaluation(
          rawComponents: secondPath,
          rule: revision,
          displayName: "Generated\ncache",
          responsibleTool: "Tool\u{001B}",
          matchState: .possibleMatch,
          disposition: .protected,
          findings: [
            CLITestClassificationFactory.finding(
              state: .unknown(.notCollected),
              explanation: "Evidence\rnot collected"
            )
          ],
          explanation: "Evidence is\nmissing."
        ),
        CLITestClassificationFactory.evaluation(
          rawComponents: firstPath,
          rule: nil,
          matchingRules: [],
          displayName: "Unrecognized data",
          responsibleTool: "Unknown",
          matchState: .unrecognized,
          disposition: .protected,
          reproducibility: .unknown,
          findings: [],
          explanation: "No rule recognized this item."
        ),
      ]
    )
    let scanReport = CLITestReportFactory.report(
      root: CLITestReportFactory.item(isComplete: false),
      topLevelItems: [secondItem, firstItem],
      hardLinkAccountingIsComplete: false
    )

    let first = ClassificationTextRenderer.render(report: report, scanReport: scanReport)
    let second = ClassificationTextRenderer.render(report: report, scanReport: scanReport)

    #expect(first == second)
    #expect(first.hasSuffix("\n"))
    #expect(first.contains("Catalog: devsift.builtin-rules v5"))
    #expect(first.contains("Catalog rules: 6"))
    #expect(first.contains("Scan completeness: partial"))
    #expect(first.contains("Reference time (Unix seconds): -42"))
    #expect(first.contains("Decisions: 2"))
    #expect(first.contains("possible-match 1"))
    #expect(first.contains("unrecognized 1"))
    #expect(first.contains("protected 2"))
    #expect(first.contains("Path: \"\\xFF\\x1B\""))
    #expect(first.contains("Path: \"z\\ncache\""))
    #expect(first.range(of: "z\\ncache")!.lowerBound < first.range(of: "\\xFF\\x1B")!.lowerBound)
    #expect(first.contains("Rule revision: devsift.test.cache@7"))
    #expect(first.contains("Matching rule revisions: none"))
    #expect(first.contains("unknown(not-collected)"))
    #expect(first.contains("Generated\\ncache"))
    #expect(first.contains("Evidence\\rnot collected"))
    #expect(first.contains("8.0 KiB (8192 B)"))
    #expect(first.contains("4.0 KiB (4096 B) (partial)"))
    #expect(first.contains("unavailable (size overflow)"))
    #expect(first.contains("z\ncache") == false)
    #expect(first.contains("Generated\ncache") == false)
  }

  @Test("Empty text output has a stable explicit decision section")
  func emptyTextOutput() {
    let output = ClassificationTextRenderer.render(
      report: CLITestClassificationFactory.report(evaluations: []),
      scanReport: CLITestReportFactory.report()
    )

    #expect(output.contains("Decisions: 0"))
    #expect(output.hasSuffix("Decisions: none\n"))
  }

  @Test("Partial scan integrity remains explainable with zero retained decisions")
  func partialIntegrityWithoutDecisions() throws {
    let issue = ScanIssue(
      path: .root,
      operation: .listDirectory,
      reason: .resourceLimit,
      impact: .descendantsSkipped
    )
    let scanReport = CLITestReportFactory.report(
      root: CLITestReportFactory.item(
        unknownAllocatedItemCount: 3,
        sizeOverflowed: true,
        isComplete: false
      ),
      topLevelItems: [],
      topLevelItemCount: 8,
      topLevelItemsWereSuppressed: true,
      hardLinkAccountingIsComplete: false,
      traversalDetailsWereDiscarded: true,
      issues: [issue],
      suppressedIssueCount: 2
    )
    let report = CLITestClassificationFactory.report(evaluations: [])

    let text = ClassificationTextRenderer.render(report: report, scanReport: scanReport)
    let json = try ClassificationJSONRenderer.render(report: report, scanReport: scanReport)
    let data = try #require(json.data(using: String.Encoding.utf8))
    let decoded = try JSONDecoder().decode(ClassificationJSONDocumentV1.self, from: data)

    #expect(text.contains("Report: partial"))
    #expect(text.contains("Root summary: partial"))
    #expect(text.contains("Top-level items observed: 8"))
    #expect(text.contains("Retained top-level items: 0"))
    #expect(text.contains("Top-level items suppressed: yes"))
    #expect(text.contains("Traversal details discarded: yes"))
    #expect(text.contains("Hard-link accounting complete: no"))
    #expect(text.contains("Issues: 1 retained, 2 suppressed"))
    #expect(text.contains("Size overflow: root yes, any retained item no"))
    #expect(text.contains("Unknown allocation: any yes, root 3"))
    #expect(text.hasSuffix("Decisions: none\n"))
    #expect(decoded.scanIntegrity.isComplete == false)
    #expect(decoded.scanIntegrity.rootIsComplete == false)
    #expect(decoded.scanIntegrity.topLevelItemCount == "8")
    #expect(decoded.scanIntegrity.retainedTopLevelItemCount == "0")
    #expect(decoded.scanIntegrity.retainedIssueCount == "1")
    #expect(decoded.scanIntegrity.suppressedIssueCount == "2")
    #expect(decoded.scanIntegrity.rootSizeOverflowed)
    #expect(decoded.scanIntegrity.anyRetainedItemSizeOverflowed == false)
    #expect(decoded.scanIntegrity.anyUnknownAllocatedSize)
  }

  @Test("JSON v1 has exact key sets, string integers, and lossless raw paths")
  func jsonOutputContract() throws {
    let rawPath = [[UInt8](arrayLiteral: 0xFF, 0x00, 0x5C)]
    let rootIdentity = FileIdentity(device: 0xD35, inode: 0x200)
    let itemIdentity = FileIdentity(device: rootIdentity.device, inode: 0x201)
    let revisions = [
      CLITestClassificationFactory.revision(identifier: "devsift.test.alpha", version: 2),
      CLITestClassificationFactory.revision(identifier: "devsift.test.beta", version: .max),
    ]
    let item = CLITestReportFactory.item(
      rawComponents: rawPath,
      kind: .directory,
      scanTimeIdentity: itemIdentity,
      allocatedBytes: .max,
      hardLinkExclusiveAllocatedBytes: .max,
      unknownAllocatedItemCount: .max,
      sizeOverflowed: true,
      isComplete: false
    )
    let evaluation = CLITestClassificationFactory.evaluation(
      rawComponents: rawPath,
      rule: nil,
      matchingRules: Array(revisions.reversed()),
      displayName: "Conflicting rules",
      responsibleTool: "Multiple tools",
      matchState: .conflict,
      disposition: .protected,
      reproducibility: .unknown,
      findings: [
        CLITestClassificationFactory.finding(
          identifier: "rule-conflict",
          kind: .conflict,
          state: .unknown(.resourceLimit)
        )
      ],
      explanation: "Multiple rules recognized this item."
    )
    let report = CLITestClassificationFactory.report(
      referenceUnixSeconds: .min,
      evaluations: [evaluation]
    )
    let scanReport = CLITestReportFactory.report(
      root: CLITestReportFactory.item(
        scanTimeIdentity: rootIdentity,
        unknownAllocatedItemCount: .max,
        sizeOverflowed: true,
        isComplete: false
      ),
      topLevelItems: [item],
      topLevelItemsWereSuppressed: true,
      hardLinkAccountingIsComplete: false,
      traversalDetailsWereDiscarded: true,
      issues: [
        ScanIssue(
          path: .root,
          operation: .listDirectory,
          reason: .ioFailure,
          impact: .descendantsSkipped
        )
      ],
      suppressedIssueCount: .max
    )

    let first = try ClassificationJSONRenderer.render(
      report: report,
      scanReport: scanReport
    )
    let second = try ClassificationJSONRenderer.render(
      report: report,
      scanReport: scanReport
    )
    let data = try #require(first.data(using: String.Encoding.utf8))
    let decoded = try JSONDecoder().decode(ClassificationJSONDocumentV1.self, from: data)

    #expect(first == second)
    #expect(first.hasSuffix("\n"))
    #expect(first.hasSuffix("\n\n") == false)
    #expect(decoded == ClassificationJSONDocumentV1(report: report, scanReport: scanReport))
    #expect(decoded.schema == "devsift.classification")
    #expect(decoded.schemaVersion == 1)
    #expect(decoded.pathStyle == "root-relative")
    #expect(decoded.catalog.identifier == BuiltInRuleCatalog.revision.identifier.rawValue)
    #expect(decoded.catalog.version == String(BuiltInRuleCatalog.revision.version.rawValue))
    #expect(decoded.catalog.version == "5")
    #expect(decoded.catalog.ruleCount == String(BuiltInRuleCatalog.rules.count))
    #expect(decoded.referenceUnixSeconds == String(Int64.min))
    #expect(decoded.scanIntegrity.retainedTopLevelItemCount == "1")
    #expect(decoded.scanIntegrity.retainedIssueCount == "1")
    #expect(decoded.scanIntegrity.suppressedIssueCount == String(UInt64.max))
    #expect(decoded.scanIntegrity.rootUnknownAllocatedItemCount == String(UInt64.max))
    #expect(decoded.summary.decisionCount == "1")
    #expect(decoded.summary.observedRuleRevisionCount == "2")
    #expect(decoded.decisions.first?.ruleRevision == nil)
    #expect(
      decoded.decisions.first?.matchingRuleRevisions.map { $0.version }
        == ["2", String(UInt32.max)]
    )
    #expect(decoded.decisions.first?.path.rawComponentsBase64 == ["/wBc"])
    #expect(decoded.decisions.first?.observation?.apparentAllocatedBytes == String(UInt64.max))
    #expect(decoded.decisions.first?.observation?.unknownAllocatedItemCount == String(UInt64.max))
    #expect(decoded.decisions.first?.findings.first?.state.status == "unknown")
    #expect(decoded.decisions.first?.findings.first?.state.reason == "resource-limit")
    #expect(first.contains("\"ruleRevision\" : null"))
    try assertJSONV1KeySets(data)
  }

  @Test("Ambiguous duplicate scan summaries do not get attached to a decision")
  func duplicateObservationIsWithheld() throws {
    let path = [Array("duplicate".utf8)]
    let item = CLITestReportFactory.item(rawComponents: path, allocatedBytes: 1)
    let scanReport = CLITestReportFactory.report(topLevelItems: [item, item])
    let report = CLITestClassificationFactory.report(
      evaluations: [CLITestClassificationFactory.evaluation(rawComponents: path)]
    )

    let text = ClassificationTextRenderer.render(report: report, scanReport: scanReport)
    let json = try ClassificationJSONRenderer.render(report: report, scanReport: scanReport)

    #expect(text.contains("unavailable (scan summary missing)"))
    #expect(json.contains("\"observation\" : null"))
  }

  private func assertJSONV1KeySets(_ data: Data) throws {
    let object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(
      Set(object.keys) == [
        "schema", "schemaVersion", "devsiftVersion", "safetyMode", "pathStyle", "catalog",
        "referenceUnixSeconds", "scanIsComplete", "scanIntegrity", "summary", "decisions",
      ]
    )

    let catalog = try #require(object["catalog"] as? [String: Any])
    #expect(Set(catalog.keys) == ["identifier", "version", "ruleCount"])
    #expect(catalog["ruleCount"] is String)

    let scanIntegrity = try #require(object["scanIntegrity"] as? [String: Any])
    #expect(
      Set(scanIntegrity.keys) == [
        "isComplete", "rootIsComplete", "topLevelItemCount", "retainedTopLevelItemCount",
        "topLevelItemsWereSuppressed", "traversalDetailsWereDiscarded",
        "hardLinkAccountingIsComplete", "retainedIssueCount", "suppressedIssueCount",
        "rootSizeOverflowed", "anyRetainedItemSizeOverflowed",
        "rootUnknownAllocatedItemCount", "retainedItemsWithUnknownAllocatedSizeCount",
        "anyUnknownAllocatedSize",
      ]
    )
    for key in [
      "topLevelItemCount", "retainedTopLevelItemCount", "retainedIssueCount",
      "suppressedIssueCount",
      "rootUnknownAllocatedItemCount", "retainedItemsWithUnknownAllocatedSizeCount",
    ] {
      #expect(scanIntegrity[key] is String)
    }

    let summary = try #require(object["summary"] as? [String: Any])
    #expect(
      Set(summary.keys) == [
        "decisionCount", "observedRuleRevisionCount", "matchedCount", "possibleMatchCount",
        "unrecognizedCount", "conflictCount", "invalidRuleCount", "reclaimableCount",
        "reviewRequiredCount", "protectedCount",
      ]
    )
    for value in summary.values {
      #expect(value is String)
    }

    let decisions = try #require(object["decisions"] as? [[String: Any]])
    let decision = try #require(decisions.first)
    #expect(
      Set(decision.keys) == [
        "path", "ruleRevision", "matchingRuleRevisions", "displayName", "responsibleTool",
        "matchState", "disposition", "reproducibility", "observation", "findings",
        "explanation",
      ]
    )

    let path = try #require(decision["path"] as? [String: Any])
    #expect(Set(path.keys) == ["display", "rawComponentsBase64"])

    let revisions = try #require(
      decision["matchingRuleRevisions"] as? [[String: Any]]
    )
    for revision in revisions {
      #expect(Set(revision.keys) == ["identifier", "version"])
      #expect(revision["version"] is String)
    }

    let observation = try #require(decision["observation"] as? [String: Any])
    #expect(
      Set(observation.keys) == [
        "kind", "apparentAllocatedBytes", "hardLinkExclusiveAllocatedBytes",
        "unknownAllocatedItemCount", "itemIsComplete", "sizeOverflowed",
        "hardLinkAccountingIsComplete",
      ]
    )
    #expect(observation["apparentAllocatedBytes"] is String)
    #expect(observation["hardLinkExclusiveAllocatedBytes"] is String)
    #expect(observation["unknownAllocatedItemCount"] is String)

    let findings = try #require(decision["findings"] as? [[String: Any]])
    let finding = try #require(findings.first)
    #expect(Set(finding.keys) == ["identifier", "kind", "state", "explanation"])
    let state = try #require(finding["state"] as? [String: Any])
    #expect(Set(state.keys) == ["status", "reason"])
  }
}
