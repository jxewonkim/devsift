import CryptoKit
import Foundation
import Testing

@testable import DevSiftCore

@Suite("Quarantine restore journal v1 canonical codec")
struct QuarantineRestoreJournalV1Tests {
  @Test("Restore intent is derived from one exact quarantined record pair")
  func intentDerivationAndRoundTrip() throws {
    let pair = try validQuarantinePair(selectedDestinationOrdinal: 7)
    let intent = try QuarantineRestoreJournalV1Codec.makeIntent(
      restoreTransactionID: restoreTransactionID,
      canonicalQuarantineIntentBytes: pair.intentBytes,
      canonicalQuarantineReceiptBytes: pair.receiptBytes
    )

    let first = try QuarantineRestoreJournalV1Codec.encode(
      intent,
      matchingQuarantineIntentBytes: pair.intentBytes,
      matchingQuarantineReceiptBytes: pair.receiptBytes
    )
    let second = try QuarantineRestoreJournalV1Codec.encode(intent)

    #expect(first == second)
    #expect(try QuarantineRestoreJournalV1Codec.decodeIntent(first) == intent)
    #expect(
      try QuarantineRestoreJournalV1Codec.decodeIntent(
        first,
        matchingQuarantineIntentBytes: pair.intentBytes,
        matchingQuarantineReceiptBytes: pair.receiptBytes
      ) == intent
    )
    #expect(intent.restoreTransactionID == restoreTransactionID)
    #expect(intent.quarantineTransactionID == pair.intent.transactionID)
    #expect(intent.quarantineIntentDigest == restoreTestDigest(pair.intentBytes))
    #expect(intent.quarantineReceiptDigest == restoreTestDigest(pair.receiptBytes))
    #expect(intent.npmRootBinding == pair.intent.npmRootBinding)
    #expect(intent.quarantineRootBinding == pair.intent.quarantineRootBinding)
    #expect(intent.candidateBinding == pair.intent.candidateBinding)
    #expect(intent.sourceComponents == pair.intent.sourceComponents)
    #expect(intent.quarantineItemComponent == pair.intent.destinationComponents[7])
    #expect(
      intent.restorePolicyRevision
        == QuarantineRestoreJournalIntentV1.currentRestorePolicyRevision
    )
    #expect(first.count < QuarantineRestoreJournalV1Codec.maximumEncodedByteCount)
    #expect(!(intent as Any is any Encodable))

    let text = try #require(String(data: first, encoding: .utf8))
    #expect(!text.contains("\n"))
    #expect(text.hasPrefix("{\"candidateBinding\":"))
    #expect(text.contains("\"sourceComponents\":[\"X2NhY2FjaGU=\"]"))
    #expect(text.hasSuffix("\"version\":\"1\"}"))
  }

  @Test("Restore intent requires a canonical matching quarantined receipt")
  func intentRejectsInvalidOriginalPair() throws {
    let pair = try validQuarantinePair(selectedDestinationOrdinal: 3)
    let notMovedReceipt = try QuarantineJournalV1Codec.makeReceipt(
      outcome: .notMoved,
      producedByRecovery: false,
      canonicalIntentBytes: pair.intentBytes
    )
    let notMovedBytes = try QuarantineJournalV1Codec.encode(
      notMovedReceipt,
      matchingIntentBytes: pair.intentBytes
    )
    let otherPair = try validQuarantinePair(
      quarantineTransactionID: String(repeating: "c", count: 32),
      selectedDestinationOrdinal: 3
    )

    expectRestoreCodecError(.quarantineReceiptNotRestorable) {
      try QuarantineRestoreJournalV1Codec.makeIntent(
        restoreTransactionID: restoreTransactionID,
        canonicalQuarantineIntentBytes: pair.intentBytes,
        canonicalQuarantineReceiptBytes: notMovedBytes
      )
    }
    expectRestoreCodecError(.invalidQuarantineRecordPair) {
      try QuarantineRestoreJournalV1Codec.makeIntent(
        restoreTransactionID: restoreTransactionID,
        canonicalQuarantineIntentBytes: pair.intentBytes,
        canonicalQuarantineReceiptBytes: otherPair.receiptBytes
      )
    }
    expectRestoreCodecError(.invalidQuarantineRecordPair) {
      try QuarantineRestoreJournalV1Codec.makeIntent(
        restoreTransactionID: restoreTransactionID,
        canonicalQuarantineIntentBytes: Data(),
        canonicalQuarantineReceiptBytes: pair.receiptBytes
      )
    }
  }

  @Test("Restore intent exact-pair validation detects record drift")
  func intentRejectsExactOriginalRecordDrift() throws {
    let pair = try validQuarantinePair(selectedDestinationOrdinal: 5)
    let intent = try restoreIntent(from: pair)
    let alteredReceipt = try QuarantineJournalV1Codec.makeReceipt(
      outcome: .quarantined,
      selectedDestinationOrdinal: 6,
      producedByRecovery: true,
      canonicalIntentBytes: pair.intentBytes
    )
    let alteredReceiptBytes = try QuarantineJournalV1Codec.encode(
      alteredReceipt,
      matchingIntentBytes: pair.intentBytes
    )
    let driftedDigest = copyRestoreIntent(
      intent,
      quarantineReceiptDigest: Array(repeating: 0xFF, count: SHA256.byteCount)
    )

    expectRestoreCodecError(.invalidQuarantineRecordPair) {
      try QuarantineRestoreJournalV1Codec.validate(
        intent,
        canonicalQuarantineIntentBytes: pair.intentBytes,
        canonicalQuarantineReceiptBytes: alteredReceiptBytes
      )
    }
    expectRestoreCodecError(.invalidQuarantineRecordPair) {
      try QuarantineRestoreJournalV1Codec.encode(
        driftedDigest,
        matchingQuarantineIntentBytes: pair.intentBytes,
        matchingQuarantineReceiptBytes: pair.receiptBytes
      )
    }
  }

  @Test("Intent decoder rejects empty, oversized, and malformed documents")
  func intentRejectsInvalidDocumentEnvelope() {
    expectRestoreCodecError(.emptyDocument) {
      try QuarantineRestoreJournalV1Codec.decodeIntent(Data())
    }
    expectRestoreCodecError(.documentTooLarge) {
      try QuarantineRestoreJournalV1Codec.decodeIntent(
        Data(
          repeating: 0x20,
          count: QuarantineRestoreJournalV1Codec.maximumEncodedByteCount + 1
        )
      )
    }
    expectRestoreCodecError(.malformedDocument) {
      try QuarantineRestoreJournalV1Codec.decodeIntent(Data("{".utf8))
    }
  }

  @Test("Intent decoder rejects unknown formats and noncanonical JSON")
  func intentRejectsFormatAndCanonicalityDrift() throws {
    let pair = try validQuarantinePair()
    let bytes = try QuarantineRestoreJournalV1Codec.encode(restoreIntent(from: pair))
    let futureSchema = try restoreReplacingFirst(
      in: bytes,
      "devsift.quarantine-restore-intent",
      with: "devsift.quarantine-restore-future"
    )
    let futureVersion = try restoreReplacingFirst(
      in: bytes,
      "\"version\":\"1\"}",
      with: "\"version\":\"2\"}"
    )
    let unknown = try restoreInsertingBeforeFinalBrace(
      in: bytes,
      fragment: ",\"unknown\":\"value\""
    )
    let duplicate = try restoreInsertingAfterOpeningBrace(
      in: bytes,
      fragment: "\"schema\":\"devsift.quarantine-restore-intent\","
    )
    var whitespace = Data([0x20])
    whitespace.append(bytes)

    expectRestoreCodecError(.unsupportedSchema) {
      try QuarantineRestoreJournalV1Codec.decodeIntent(futureSchema)
    }
    expectRestoreCodecError(.unsupportedVersion) {
      try QuarantineRestoreJournalV1Codec.decodeIntent(futureVersion)
    }
    for candidate in [unknown, duplicate, whitespace] {
      expectRestoreCodecError(.nonCanonicalDocument) {
        try QuarantineRestoreJournalV1Codec.decodeIntent(candidate)
      }
    }
  }

  @Test("Intent decoder rejects invalid Base64 and decimal strings")
  func intentRejectsInvalidScalarEncoding() throws {
    let pair = try validQuarantinePair()
    let bytes = try QuarantineRestoreJournalV1Codec.encode(restoreIntent(from: pair))
    let invalidBase64 = try restoreReplacingFirst(
      in: bytes,
      "\"sourceComponents\":[\"X2NhY2FjaGU=\"]",
      with: "\"sourceComponents\":[\"***\"]"
    )
    let leadingZero = try restoreReplacingFirst(
      in: bytes,
      "\"restorePolicyRevision\":\"1\"",
      with: "\"restorePolicyRevision\":\"01\""
    )

    expectRestoreCodecError(.malformedDocument) {
      try QuarantineRestoreJournalV1Codec.decodeIntent(invalidBase64)
    }
    expectRestoreCodecError(.malformedDocument) {
      try QuarantineRestoreJournalV1Codec.decodeIntent(leadingZero)
    }
  }

  @Test("Intent rejects identifiers, binding, source, item, digest, and policy drift")
  func intentRejectsInvalidDomainRelationships() throws {
    let pair = try validQuarantinePair()
    let baseline = try restoreIntent(from: pair)

    expectRestoreCodecError(.invalidRestoreTransactionID) {
      try QuarantineRestoreJournalV1Codec.encode(
        copyRestoreIntent(
          baseline,
          restoreTransactionID: "ffeeddccbbaa998877665544332211GG"
        )
      )
    }
    expectRestoreCodecError(.invalidQuarantineTransactionID) {
      try QuarantineRestoreJournalV1Codec.encode(
        copyRestoreIntent(
          baseline,
          quarantineTransactionID: baseline.restoreTransactionID
        )
      )
    }
    expectRestoreCodecError(.invalidDigest) {
      try QuarantineRestoreJournalV1Codec.encode(
        copyRestoreIntent(baseline, quarantineIntentDigest: [0])
      )
    }
    expectRestoreCodecError(.invalidBinding) {
      try QuarantineRestoreJournalV1Codec.encode(
        copyRestoreIntent(
          baseline,
          quarantineRootBinding: restoreBinding(device: 12, inode: 101)
        )
      )
    }
    expectRestoreCodecError(.invalidSourcePath) {
      try QuarantineRestoreJournalV1Codec.encode(
        copyRestoreIntent(baseline, sourceComponents: [Array("cache".utf8)])
      )
    }
    expectRestoreCodecError(.invalidQuarantineItem) {
      try QuarantineRestoreJournalV1Codec.encode(
        copyRestoreIntent(
          baseline,
          quarantineItemComponent: Array(
            "item-v1-00112233445566778899AABBCCDDEEFF".utf8
          )
        )
      )
    }
    expectRestoreCodecError(.policyDrift) {
      try QuarantineRestoreJournalV1Codec.encode(
        copyRestoreIntent(baseline, restorePolicyRevision: 0)
      )
    }
    expectRestoreCodecError(.policyDrift) {
      try QuarantineRestoreJournalV1Codec.encode(
        copyRestoreIntent(baseline, restorePolicyRevision: 2)
      )
    }
  }

  @Test("Intent decode rejects zero and future restore policy revisions")
  func intentDecodeRejectsUnsupportedPolicy() throws {
    let pair = try validQuarantinePair()
    let bytes = try QuarantineRestoreJournalV1Codec.encode(restoreIntent(from: pair))
    let zero = try restoreReplacingFirst(
      in: bytes,
      "\"restorePolicyRevision\":\"1\"",
      with: "\"restorePolicyRevision\":\"0\""
    )
    let future = try restoreReplacingFirst(
      in: bytes,
      "\"restorePolicyRevision\":\"1\"",
      with: "\"restorePolicyRevision\":\"2\""
    )

    expectRestoreCodecError(.policyDrift) {
      try QuarantineRestoreJournalV1Codec.decodeIntent(zero)
    }
    expectRestoreCodecError(.policyDrift) {
      try QuarantineRestoreJournalV1Codec.decodeIntent(future)
    }
  }

  @Test("Restore intent SHA-256 covers the exact canonical bytes")
  func exactRestoreIntentDigest() throws {
    let pair = try validQuarantinePair()
    let bytes = try QuarantineRestoreJournalV1Codec.encode(restoreIntent(from: pair))
    let digest = try QuarantineRestoreJournalV1Codec.restoreIntentDigest(
      forCanonicalIntentBytes: bytes
    )

    #expect(digest == restoreTestDigest(bytes))
    #expect(digest.count == SHA256.byteCount)

    var noncanonical = bytes
    noncanonical.append(0x20)
    expectRestoreCodecError(.nonCanonicalDocument) {
      try QuarantineRestoreJournalV1Codec.restoreIntentDigest(
        forCanonicalIntentBytes: noncanonical
      )
    }
  }

  @Test("Restored receipt bytes round trip and match their exact intent")
  func restoredReceiptRoundTrip() throws {
    let pair = try validQuarantinePair()
    let intentBytes = try QuarantineRestoreJournalV1Codec.encode(restoreIntent(from: pair))
    let receipt = try QuarantineRestoreJournalV1Codec.makeReceipt(
      outcome: .restored,
      quarantineNameWasRecreated: true,
      producedByRecovery: true,
      canonicalRestoreIntentBytes: intentBytes
    )

    let first = try QuarantineRestoreJournalV1Codec.encode(
      receipt,
      matchingIntentBytes: intentBytes
    )
    let second = try QuarantineRestoreJournalV1Codec.encode(receipt)

    #expect(first == second)
    #expect(
      try QuarantineRestoreJournalV1Codec.decodeReceipt(
        first,
        matchingIntentBytes: intentBytes
      ) == receipt
    )
    #expect(receipt.restoreIntentDigest == restoreTestDigest(intentBytes))
    #expect(!receipt.sourceNameWasOccupied)
    #expect(receipt.quarantineNameWasRecreated)
    #expect(receipt.producedByRecovery)
    #expect(!(receipt as Any is any Encodable))
    let text = try #require(String(data: first, encoding: .utf8))
    #expect(text.hasPrefix("{\"outcome\":\"restored\","))
    #expect(text.hasSuffix("\"version\":\"1\"}"))
  }

  @Test("Not-restored receipts preserve whether the source name was occupied")
  func notRestoredReceiptRelationships() throws {
    let pair = try validQuarantinePair()
    let intentBytes = try QuarantineRestoreJournalV1Codec.encode(restoreIntent(from: pair))
    let receipt = try QuarantineRestoreJournalV1Codec.makeReceipt(
      outcome: .notRestored,
      sourceNameWasOccupied: true,
      producedByRecovery: false,
      canonicalRestoreIntentBytes: intentBytes
    )
    let bytes = try QuarantineRestoreJournalV1Codec.encode(
      receipt,
      matchingIntentBytes: intentBytes
    )

    #expect(
      try QuarantineRestoreJournalV1Codec.decodeReceipt(
        bytes,
        matchingIntentBytes: intentBytes
      ) == receipt
    )
    #expect(receipt.sourceNameWasOccupied)
    #expect(!receipt.quarantineNameWasRecreated)

    let restoredWithOccupiedSource = copyRestoreReceipt(
      receipt,
      outcome: .restored,
      sourceNameWasOccupied: true
    )
    let notRestoredWithRecreatedQuarantineName = copyRestoreReceipt(
      receipt,
      quarantineNameWasRecreated: true
    )
    expectRestoreCodecError(.invalidReceiptRelationships) {
      try QuarantineRestoreJournalV1Codec.encode(restoredWithOccupiedSource)
    }
    expectRestoreCodecError(.invalidReceiptRelationships) {
      try QuarantineRestoreJournalV1Codec.encode(notRestoredWithRecreatedQuarantineName)
    }
  }

  @Test("Receipt rejects malformed digest and restore-intent mismatches")
  func receiptRejectsDigestAndIntentMismatch() throws {
    let pair = try validQuarantinePair()
    let intent = try restoreIntent(from: pair)
    let intentBytes = try QuarantineRestoreJournalV1Codec.encode(intent)
    let valid = try QuarantineRestoreJournalV1Codec.makeReceipt(
      outcome: .restored,
      producedByRecovery: false,
      canonicalRestoreIntentBytes: intentBytes
    )

    expectRestoreCodecError(.invalidDigest) {
      try QuarantineRestoreJournalV1Codec.encode(
        copyRestoreReceipt(valid, restoreIntentDigest: [0])
      )
    }
    expectRestoreCodecError(.receiptDoesNotMatchIntent) {
      try QuarantineRestoreJournalV1Codec.validate(
        copyRestoreReceipt(
          valid,
          restoreTransactionID: String(repeating: "d", count: 32)
        ),
        matching: intent,
        canonicalIntentBytes: intentBytes
      )
    }
    expectRestoreCodecError(.receiptDoesNotMatchIntent) {
      try QuarantineRestoreJournalV1Codec.validate(
        copyRestoreReceipt(
          valid,
          restoreIntentDigest: Array(repeating: 0xFF, count: SHA256.byteCount)
        ),
        matching: intent,
        canonicalIntentBytes: intentBytes
      )
    }
  }

  @Test("Receipt decoder rejects invalid envelopes and formats")
  func receiptRejectsInvalidEnvelopeAndFormat() throws {
    let pair = try validQuarantinePair()
    let intentBytes = try QuarantineRestoreJournalV1Codec.encode(restoreIntent(from: pair))
    let receipt = try QuarantineRestoreJournalV1Codec.makeReceipt(
      outcome: .restored,
      producedByRecovery: false,
      canonicalRestoreIntentBytes: intentBytes
    )
    let bytes = try QuarantineRestoreJournalV1Codec.encode(receipt)
    let futureSchema = try restoreReplacingFirst(
      in: bytes,
      "devsift.quarantine-restore-receipt",
      with: "devsift.quarantine-restore-future"
    )
    let futureVersion = try restoreReplacingFirst(
      in: bytes,
      "\"version\":\"1\"}",
      with: "\"version\":\"2\"}"
    )
    let invalidOutcome = try restoreReplacingFirst(
      in: bytes,
      "\"outcome\":\"restored\"",
      with: "\"outcome\":\"future\""
    )

    expectRestoreCodecError(.emptyDocument) {
      try QuarantineRestoreJournalV1Codec.decodeReceipt(Data())
    }
    expectRestoreCodecError(.documentTooLarge) {
      try QuarantineRestoreJournalV1Codec.decodeReceipt(
        Data(
          repeating: 0x20,
          count: QuarantineRestoreJournalV1Codec.maximumEncodedByteCount + 1
        )
      )
    }
    expectRestoreCodecError(.malformedDocument) {
      try QuarantineRestoreJournalV1Codec.decodeReceipt(Data("{".utf8))
    }
    expectRestoreCodecError(.unsupportedSchema) {
      try QuarantineRestoreJournalV1Codec.decodeReceipt(futureSchema)
    }
    expectRestoreCodecError(.unsupportedVersion) {
      try QuarantineRestoreJournalV1Codec.decodeReceipt(futureVersion)
    }
    expectRestoreCodecError(.invalidReceiptRelationships) {
      try QuarantineRestoreJournalV1Codec.decodeReceipt(invalidOutcome)
    }
  }

  @Test("Receipt decoder rejects unknown, duplicate, scalar, and whitespace drift")
  func receiptRejectsNonCanonicalRecords() throws {
    let pair = try validQuarantinePair()
    let intentBytes = try QuarantineRestoreJournalV1Codec.encode(restoreIntent(from: pair))
    let receipt = try QuarantineRestoreJournalV1Codec.makeReceipt(
      outcome: .notRestored,
      producedByRecovery: true,
      canonicalRestoreIntentBytes: intentBytes
    )
    let bytes = try QuarantineRestoreJournalV1Codec.encode(receipt)
    let unknown = try restoreInsertingBeforeFinalBrace(in: bytes, fragment: ",\"x\":false")
    let duplicate = try restoreInsertingAfterOpeningBrace(
      in: bytes,
      fragment: "\"schema\":\"devsift.quarantine-restore-receipt\","
    )
    let invalidBase64 = try restoreReplacingFirst(
      in: bytes,
      "\"restoreIntentDigest\":\"",
      with: "\"restoreIntentDigest\":\"***"
    )
    var whitespace = bytes
    whitespace.append(0x0A)

    for candidate in [unknown, duplicate, whitespace] {
      expectRestoreCodecError(.nonCanonicalDocument) {
        try QuarantineRestoreJournalV1Codec.decodeReceipt(candidate)
      }
    }
    expectRestoreCodecError(.malformedDocument) {
      try QuarantineRestoreJournalV1Codec.decodeReceipt(invalidBase64)
    }
  }
}

private let restoreTransactionID = "ffeeddccbbaa99887766554433221100"

private struct RestoreQuarantinePair {
  let intent: QuarantineJournalIntentV1
  let intentBytes: Data
  let receiptBytes: Data
}

private func validQuarantinePair(
  quarantineTransactionID: String = "00112233445566778899aabbccddeeff",
  selectedDestinationOrdinal: Int = 7
) throws -> RestoreQuarantinePair {
  let intent = QuarantineJournalIntentV1(
    transactionID: quarantineTransactionID,
    npmRootBinding: restoreBinding(device: 11, inode: 100),
    quarantineRootBinding: restoreBinding(device: 11, inode: 101),
    candidateBinding: restoreBinding(device: 11, inode: 102, linkCount: 5),
    sourceComponents: [Array("_cacache".utf8)],
    destinationComponents: (0..<16).map(restoreDestinationComponent)
  )
  let intentBytes = try QuarantineJournalV1Codec.encode(intent)
  let receipt = try QuarantineJournalV1Codec.makeReceipt(
    outcome: .quarantined,
    selectedDestinationOrdinal: selectedDestinationOrdinal,
    producedByRecovery: false,
    canonicalIntentBytes: intentBytes
  )
  let receiptBytes = try QuarantineJournalV1Codec.encode(
    receipt,
    matchingIntentBytes: intentBytes
  )
  return RestoreQuarantinePair(
    intent: intent,
    intentBytes: intentBytes,
    receiptBytes: receiptBytes
  )
}

private func restoreIntent(
  from pair: RestoreQuarantinePair
) throws -> QuarantineRestoreJournalIntentV1 {
  try QuarantineRestoreJournalV1Codec.makeIntent(
    restoreTransactionID: restoreTransactionID,
    canonicalQuarantineIntentBytes: pair.intentBytes,
    canonicalQuarantineReceiptBytes: pair.receiptBytes
  )
}

private func restoreBinding(
  device: UInt64,
  inode: UInt64,
  linkCount: UInt64 = 3
) -> QuarantineJournalFileBindingV1 {
  QuarantineJournalFileBindingV1(
    device: device,
    inode: inode,
    generation: 7,
    birthSeconds: 1_725_000_000,
    birthNanoseconds: 123_456_789,
    kind: .directory,
    ownerUID: 501,
    permissionMode: 0o700,
    flags: 0,
    linkCount: linkCount
  )
}

private func restoreDestinationComponent(_ ordinal: Int) -> [UInt8] {
  let suffix = String(ordinal, radix: 16)
  let padded = String(repeating: "0", count: 32 - suffix.count) + suffix
  return Array("item-v1-\(padded)".utf8)
}

private func copyRestoreIntent(
  _ baseline: QuarantineRestoreJournalIntentV1,
  restoreTransactionID: String? = nil,
  quarantineTransactionID: String? = nil,
  quarantineIntentDigest: [UInt8]? = nil,
  quarantineReceiptDigest: [UInt8]? = nil,
  npmRootBinding: QuarantineJournalFileBindingV1? = nil,
  quarantineRootBinding: QuarantineJournalFileBindingV1? = nil,
  candidateBinding: QuarantineJournalFileBindingV1? = nil,
  sourceComponents: [[UInt8]]? = nil,
  quarantineItemComponent: [UInt8]? = nil,
  restorePolicyRevision: UInt32? = nil
) -> QuarantineRestoreJournalIntentV1 {
  QuarantineRestoreJournalIntentV1(
    restoreTransactionID: restoreTransactionID ?? baseline.restoreTransactionID,
    quarantineTransactionID: quarantineTransactionID ?? baseline.quarantineTransactionID,
    quarantineIntentDigest: quarantineIntentDigest ?? baseline.quarantineIntentDigest,
    quarantineReceiptDigest: quarantineReceiptDigest ?? baseline.quarantineReceiptDigest,
    npmRootBinding: npmRootBinding ?? baseline.npmRootBinding,
    quarantineRootBinding: quarantineRootBinding ?? baseline.quarantineRootBinding,
    candidateBinding: candidateBinding ?? baseline.candidateBinding,
    sourceComponents: sourceComponents ?? baseline.sourceComponents,
    quarantineItemComponent: quarantineItemComponent ?? baseline.quarantineItemComponent,
    restorePolicyRevision: restorePolicyRevision ?? baseline.restorePolicyRevision
  )
}

private func copyRestoreReceipt(
  _ baseline: QuarantineRestoreJournalReceiptV1,
  restoreTransactionID: String? = nil,
  restoreIntentDigest: [UInt8]? = nil,
  outcome: QuarantineRestoreJournalReceiptOutcomeV1? = nil,
  sourceNameWasOccupied: Bool? = nil,
  quarantineNameWasRecreated: Bool? = nil,
  producedByRecovery: Bool? = nil
) -> QuarantineRestoreJournalReceiptV1 {
  QuarantineRestoreJournalReceiptV1(
    restoreTransactionID: restoreTransactionID ?? baseline.restoreTransactionID,
    restoreIntentDigest: restoreIntentDigest ?? baseline.restoreIntentDigest,
    outcome: outcome ?? baseline.outcome,
    sourceNameWasOccupied: sourceNameWasOccupied ?? baseline.sourceNameWasOccupied,
    quarantineNameWasRecreated: quarantineNameWasRecreated
      ?? baseline.quarantineNameWasRecreated,
    producedByRecovery: producedByRecovery ?? baseline.producedByRecovery
  )
}

private func restoreTestDigest(_ bytes: Data) -> [UInt8] {
  Array(SHA256.hash(data: bytes))
}

private func restoreReplacingFirst(
  in bytes: Data,
  _ target: String,
  with replacement: String
) throws -> Data {
  let text = try #require(String(data: bytes, encoding: .utf8))
  let range = try #require(text.range(of: target))
  let prefix = String(text[..<range.lowerBound])
  let suffix = String(text[range.upperBound...])
  return Data((prefix + replacement + suffix).utf8)
}

private func restoreInsertingBeforeFinalBrace(
  in bytes: Data,
  fragment: String
) throws -> Data {
  let text = try #require(String(data: bytes, encoding: .utf8))
  #expect(text.last == "}")
  return Data((String(text.dropLast()) + fragment + "}").utf8)
}

private func restoreInsertingAfterOpeningBrace(
  in bytes: Data,
  fragment: String
) throws -> Data {
  let text = try #require(String(data: bytes, encoding: .utf8))
  #expect(text.first == "{")
  return Data(("{" + fragment + text.dropFirst()).utf8)
}

private func expectRestoreCodecError<Value>(
  _ expected: QuarantineRestoreJournalCodecError,
  performing operation: () throws -> Value
) {
  do {
    _ = try operation()
    Issue.record("Expected quarantine restore journal codec error \(expected)")
  } catch let error as QuarantineRestoreJournalCodecError {
    #expect(error == expected)
  } catch {
    Issue.record("Unexpected error: \(error)")
  }
}
