import CryptoKit
import Foundation

/// Immutable evidence authorizing one user-confirmed attempt to restore a
/// previously quarantined npm cache directory.
struct QuarantineRestoreJournalIntentV1: Equatable, Sendable {
  static let schemaIdentifier = "devsift.quarantine-restore-intent"
  static let formatVersion: UInt32 = 1
  static let currentRestorePolicyRevision: UInt32 = 1

  let restoreTransactionID: String
  let quarantineTransactionID: String
  let quarantineIntentDigest: [UInt8]
  let quarantineReceiptDigest: [UInt8]
  let npmRootBinding: QuarantineJournalFileBindingV1
  let quarantineRootBinding: QuarantineJournalFileBindingV1
  let candidateBinding: QuarantineJournalFileBindingV1
  let sourceComponents: [[UInt8]]
  let quarantineItemComponent: [UInt8]
  let restorePolicyRevision: UInt32

  init(
    restoreTransactionID: String,
    quarantineTransactionID: String,
    quarantineIntentDigest: [UInt8],
    quarantineReceiptDigest: [UInt8],
    npmRootBinding: QuarantineJournalFileBindingV1,
    quarantineRootBinding: QuarantineJournalFileBindingV1,
    candidateBinding: QuarantineJournalFileBindingV1,
    sourceComponents: [[UInt8]],
    quarantineItemComponent: [UInt8],
    restorePolicyRevision: UInt32 = Self.currentRestorePolicyRevision
  ) {
    self.restoreTransactionID = restoreTransactionID
    self.quarantineTransactionID = quarantineTransactionID
    self.quarantineIntentDigest = quarantineIntentDigest
    self.quarantineReceiptDigest = quarantineReceiptDigest
    self.npmRootBinding = npmRootBinding
    self.quarantineRootBinding = quarantineRootBinding
    self.candidateBinding = candidateBinding
    self.sourceComponents = sourceComponents
    self.quarantineItemComponent = quarantineItemComponent
    self.restorePolicyRevision = restorePolicyRevision
  }
}

enum QuarantineRestoreJournalReceiptOutcomeV1: String, Equatable, Sendable {
  case restored
  case notRestored = "not-restored"
}

/// Immutable terminal evidence for one restore intent.
struct QuarantineRestoreJournalReceiptV1: Equatable, Sendable {
  static let schemaIdentifier = "devsift.quarantine-restore-receipt"
  static let formatVersion: UInt32 = 1

  let restoreTransactionID: String
  let restoreIntentDigest: [UInt8]
  let outcome: QuarantineRestoreJournalReceiptOutcomeV1
  let sourceNameWasOccupied: Bool
  let quarantineNameWasRecreated: Bool
  let producedByRecovery: Bool
}

enum QuarantineRestoreJournalCodecError: Error, Equatable, Sendable {
  case emptyDocument
  case documentTooLarge
  case malformedDocument
  case nonCanonicalDocument
  case unsupportedSchema
  case unsupportedVersion
  case invalidRestoreTransactionID
  case invalidQuarantineTransactionID
  case invalidDigest
  case invalidBinding
  case invalidSourcePath
  case invalidQuarantineItem
  case policyDrift
  case invalidQuarantineRecordPair
  case quarantineReceiptNotRestorable
  case invalidReceiptRelationships
  case receiptDoesNotMatchIntent
}

/// Strict canonical codec for the private restore journal namespace.
enum QuarantineRestoreJournalV1Codec {
  static let maximumEncodedByteCount = 32 * 1_024

  static func makeIntent(
    restoreTransactionID: String,
    canonicalQuarantineIntentBytes intentBytes: Data,
    canonicalQuarantineReceiptBytes receiptBytes: Data
  ) throws -> QuarantineRestoreJournalIntentV1 {
    let pair = try quarantinePair(
      canonicalIntentBytes: intentBytes,
      canonicalReceiptBytes: receiptBytes
    )
    let intent = QuarantineRestoreJournalIntentV1(
      restoreTransactionID: restoreTransactionID,
      quarantineTransactionID: pair.intent.transactionID,
      quarantineIntentDigest: digest(intentBytes),
      quarantineReceiptDigest: digest(receiptBytes),
      npmRootBinding: pair.intent.npmRootBinding,
      quarantineRootBinding: pair.intent.quarantineRootBinding,
      candidateBinding: pair.intent.candidateBinding,
      sourceComponents: pair.intent.sourceComponents,
      quarantineItemComponent: pair.quarantineItemComponent
    )
    try validateIntentStructure(intent)
    guard
      intent.restorePolicyRevision
        == QuarantineRestoreJournalIntentV1
        .currentRestorePolicyRevision
    else {
      throw QuarantineRestoreJournalCodecError.policyDrift
    }
    return intent
  }

  static func encode(_ intent: QuarantineRestoreJournalIntentV1) throws -> Data {
    try validateIntentStructure(intent)
    guard
      intent.restorePolicyRevision
        == QuarantineRestoreJournalIntentV1
        .currentRestorePolicyRevision
    else {
      throw QuarantineRestoreJournalCodecError.policyDrift
    }
    return try encodeCanonicalIntent(intent)
  }

  static func encode(
    _ intent: QuarantineRestoreJournalIntentV1,
    matchingQuarantineIntentBytes quarantineIntentBytes: Data,
    matchingQuarantineReceiptBytes quarantineReceiptBytes: Data
  ) throws -> Data {
    try validate(
      intent,
      canonicalQuarantineIntentBytes: quarantineIntentBytes,
      canonicalQuarantineReceiptBytes: quarantineReceiptBytes
    )
    return try encode(intent)
  }

  static func decodeIntent(_ bytes: Data) throws -> QuarantineRestoreJournalIntentV1 {
    try validateInputSize(bytes)
    let wire: RestoreIntentWire = try decode(bytes)
    let intent = try wire.domainValue()
    try validateIntentStructure(intent)
    guard try encodeCanonicalIntent(intent) == bytes else {
      throw QuarantineRestoreJournalCodecError.nonCanonicalDocument
    }
    return intent
  }

  static func decodeIntent(
    _ bytes: Data,
    matchingQuarantineIntentBytes quarantineIntentBytes: Data,
    matchingQuarantineReceiptBytes quarantineReceiptBytes: Data
  ) throws -> QuarantineRestoreJournalIntentV1 {
    let intent = try decodeIntent(bytes)
    try validate(
      intent,
      canonicalQuarantineIntentBytes: quarantineIntentBytes,
      canonicalQuarantineReceiptBytes: quarantineReceiptBytes
    )
    return intent
  }

  static func validate(
    _ intent: QuarantineRestoreJournalIntentV1,
    canonicalQuarantineIntentBytes intentBytes: Data,
    canonicalQuarantineReceiptBytes receiptBytes: Data
  ) throws {
    try validateIntentStructure(intent)
    let pair = try quarantinePair(
      canonicalIntentBytes: intentBytes,
      canonicalReceiptBytes: receiptBytes
    )
    guard
      intent.quarantineTransactionID == pair.intent.transactionID,
      intent.quarantineIntentDigest == digest(intentBytes),
      intent.quarantineReceiptDigest == digest(receiptBytes),
      intent.npmRootBinding == pair.intent.npmRootBinding,
      intent.quarantineRootBinding == pair.intent.quarantineRootBinding,
      intent.candidateBinding == pair.intent.candidateBinding,
      intent.sourceComponents == pair.intent.sourceComponents,
      intent.quarantineItemComponent == pair.quarantineItemComponent
    else {
      throw QuarantineRestoreJournalCodecError.invalidQuarantineRecordPair
    }
  }

  static func makeReceipt(
    outcome: QuarantineRestoreJournalReceiptOutcomeV1,
    sourceNameWasOccupied: Bool = false,
    quarantineNameWasRecreated: Bool = false,
    producedByRecovery: Bool,
    canonicalRestoreIntentBytes intentBytes: Data
  ) throws -> QuarantineRestoreJournalReceiptV1 {
    let intent = try decodeIntent(intentBytes)
    let receipt = QuarantineRestoreJournalReceiptV1(
      restoreTransactionID: intent.restoreTransactionID,
      restoreIntentDigest: digest(intentBytes),
      outcome: outcome,
      sourceNameWasOccupied: sourceNameWasOccupied,
      quarantineNameWasRecreated: quarantineNameWasRecreated,
      producedByRecovery: producedByRecovery
    )
    try validate(receipt, matching: intent, canonicalIntentBytes: intentBytes)
    return receipt
  }

  static func encode(_ receipt: QuarantineRestoreJournalReceiptV1) throws -> Data {
    try validateReceiptStructure(receipt)
    return try encodeBounded(RestoreReceiptWire(receipt))
  }

  static func encode(
    _ receipt: QuarantineRestoreJournalReceiptV1,
    matchingIntentBytes intentBytes: Data
  ) throws -> Data {
    let intent = try decodeIntent(intentBytes)
    try validate(receipt, matching: intent, canonicalIntentBytes: intentBytes)
    return try encode(receipt)
  }

  static func decodeReceipt(_ bytes: Data) throws -> QuarantineRestoreJournalReceiptV1 {
    try validateInputSize(bytes)
    let wire: RestoreReceiptWire = try decode(bytes)
    let receipt = try wire.domainValue()
    try validateReceiptStructure(receipt)
    guard try encode(receipt) == bytes else {
      throw QuarantineRestoreJournalCodecError.nonCanonicalDocument
    }
    return receipt
  }

  static func decodeReceipt(
    _ bytes: Data,
    matchingIntentBytes intentBytes: Data
  ) throws -> QuarantineRestoreJournalReceiptV1 {
    let intent = try decodeIntent(intentBytes)
    let receipt = try decodeReceipt(bytes)
    try validate(receipt, matching: intent, canonicalIntentBytes: intentBytes)
    return receipt
  }

  static func restoreIntentDigest(forCanonicalIntentBytes bytes: Data) throws -> [UInt8] {
    _ = try decodeIntent(bytes)
    return digest(bytes)
  }

  static func validate(
    _ receipt: QuarantineRestoreJournalReceiptV1,
    matching intent: QuarantineRestoreJournalIntentV1,
    canonicalIntentBytes intentBytes: Data
  ) throws {
    let decodedIntent = try decodeIntent(intentBytes)
    guard decodedIntent == intent else {
      throw QuarantineRestoreJournalCodecError.receiptDoesNotMatchIntent
    }
    try validateReceiptStructure(receipt)
    guard
      receipt.restoreTransactionID == intent.restoreTransactionID,
      receipt.restoreIntentDigest == digest(intentBytes)
    else {
      throw QuarantineRestoreJournalCodecError.receiptDoesNotMatchIntent
    }
  }

  private static func quarantinePair(
    canonicalIntentBytes intentBytes: Data,
    canonicalReceiptBytes receiptBytes: Data
  ) throws -> (
    intent: QuarantineJournalIntentV1,
    receipt: QuarantineJournalReceiptV1,
    quarantineItemComponent: [UInt8]
  ) {
    let intent: QuarantineJournalIntentV1
    let receipt: QuarantineJournalReceiptV1
    do {
      intent = try QuarantineJournalV1Codec.decodeIntent(intentBytes)
      receipt = try QuarantineJournalV1Codec.decodeReceipt(
        receiptBytes,
        matchingIntentBytes: intentBytes
      )
    } catch {
      throw QuarantineRestoreJournalCodecError.invalidQuarantineRecordPair
    }
    guard receipt.outcome == .quarantined,
      let ordinal = receipt.selectedDestinationOrdinal,
      intent.destinationComponents.indices.contains(ordinal),
      receipt.destinationBinding == intent.candidateBinding
    else {
      throw QuarantineRestoreJournalCodecError.quarantineReceiptNotRestorable
    }
    let item = intent.destinationComponents[ordinal]
    guard isQuarantineItemComponent(item) else {
      throw QuarantineRestoreJournalCodecError.invalidQuarantineRecordPair
    }
    return (intent, receipt, item)
  }

  private static func validateIntentStructure(
    _ intent: QuarantineRestoreJournalIntentV1
  ) throws {
    guard isLowercaseHexIdentifier(intent.restoreTransactionID) else {
      throw QuarantineRestoreJournalCodecError.invalidRestoreTransactionID
    }
    guard isLowercaseHexIdentifier(intent.quarantineTransactionID),
      intent.quarantineTransactionID != intent.restoreTransactionID
    else {
      throw QuarantineRestoreJournalCodecError.invalidQuarantineTransactionID
    }
    guard intent.quarantineIntentDigest.count == SHA256.byteCount,
      intent.quarantineReceiptDigest.count == SHA256.byteCount
    else {
      throw QuarantineRestoreJournalCodecError.invalidDigest
    }
    guard
      isValidBinding(intent.npmRootBinding),
      isValidBinding(intent.quarantineRootBinding),
      isValidBinding(intent.candidateBinding),
      intent.npmRootBinding.kind == .directory,
      intent.quarantineRootBinding.kind == .directory,
      intent.candidateBinding.kind == .directory,
      intent.npmRootBinding.device == intent.quarantineRootBinding.device,
      intent.npmRootBinding.device == intent.candidateBinding.device,
      intent.npmRootBinding.ownerUID != 0,
      intent.npmRootBinding.ownerUID == intent.quarantineRootBinding.ownerUID,
      intent.npmRootBinding.ownerUID == intent.candidateBinding.ownerUID
    else {
      throw QuarantineRestoreJournalCodecError.invalidBinding
    }
    let identities = [
      intent.npmRootBinding.inode,
      intent.quarantineRootBinding.inode,
      intent.candidateBinding.inode,
    ]
    guard Set(identities).count == identities.count else {
      throw QuarantineRestoreJournalCodecError.invalidBinding
    }
    guard intent.sourceComponents == [Array("_cacache".utf8)] else {
      throw QuarantineRestoreJournalCodecError.invalidSourcePath
    }
    guard isQuarantineItemComponent(intent.quarantineItemComponent) else {
      throw QuarantineRestoreJournalCodecError.invalidQuarantineItem
    }
    guard intent.restorePolicyRevision > 0,
      intent.restorePolicyRevision
        <= QuarantineRestoreJournalIntentV1.currentRestorePolicyRevision
    else {
      throw QuarantineRestoreJournalCodecError.policyDrift
    }
  }

  private static func validateReceiptStructure(
    _ receipt: QuarantineRestoreJournalReceiptV1
  ) throws {
    guard isLowercaseHexIdentifier(receipt.restoreTransactionID) else {
      throw QuarantineRestoreJournalCodecError.invalidRestoreTransactionID
    }
    guard receipt.restoreIntentDigest.count == SHA256.byteCount else {
      throw QuarantineRestoreJournalCodecError.invalidDigest
    }
    switch receipt.outcome {
    case .restored:
      guard !receipt.sourceNameWasOccupied else {
        throw QuarantineRestoreJournalCodecError.invalidReceiptRelationships
      }
    case .notRestored:
      guard !receipt.quarantineNameWasRecreated else {
        throw QuarantineRestoreJournalCodecError.invalidReceiptRelationships
      }
    }
  }

  private static func isValidBinding(_ binding: QuarantineJournalFileBindingV1) -> Bool {
    binding.birthNanoseconds < 1_000_000_000
      && binding.permissionMode <= 0o7777
      && binding.linkCount > 0
  }

  private static func isQuarantineItemComponent(_ bytes: [UInt8]) -> Bool {
    let prefix = Array("item-v1-".utf8)
    return bytes.count == prefix.count + 32
      && bytes.starts(with: prefix)
      && bytes.dropFirst(prefix.count).allSatisfy(isLowercaseHexDigit)
  }

  private static func isLowercaseHexIdentifier(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return bytes.count == 32 && bytes.allSatisfy(isLowercaseHexDigit)
  }

  private static func isLowercaseHexDigit(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
  }

  private static func validateInputSize(_ bytes: Data) throws {
    guard !bytes.isEmpty else {
      throw QuarantineRestoreJournalCodecError.emptyDocument
    }
    guard bytes.count <= maximumEncodedByteCount else {
      throw QuarantineRestoreJournalCodecError.documentTooLarge
    }
  }

  private static func encodeCanonicalIntent(
    _ intent: QuarantineRestoreJournalIntentV1
  ) throws -> Data {
    try encodeBounded(RestoreIntentWire(intent))
  }

  private static func encodeBounded<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes: Data
    do {
      bytes = try encoder.encode(value)
    } catch {
      throw QuarantineRestoreJournalCodecError.malformedDocument
    }
    guard bytes.count <= maximumEncodedByteCount else {
      throw QuarantineRestoreJournalCodecError.documentTooLarge
    }
    return bytes
  }

  private static func decode<Value: Decodable>(_ bytes: Data) throws -> Value {
    do {
      return try JSONDecoder().decode(Value.self, from: bytes)
    } catch {
      throw QuarantineRestoreJournalCodecError.malformedDocument
    }
  }

  private static func digest(_ bytes: Data) -> [UInt8] {
    Array(SHA256.hash(data: bytes))
  }
}

private struct RestoreIntentWire: Codable {
  let schema: String
  let version: String
  let restoreTransactionID: String
  let quarantineTransactionID: String
  let quarantineIntentDigest: String
  let quarantineReceiptDigest: String
  let npmRootBinding: RestoreBindingWire
  let quarantineRootBinding: RestoreBindingWire
  let candidateBinding: RestoreBindingWire
  let sourceComponents: [String]
  let quarantineItemComponent: String
  let restorePolicyRevision: String

  init(_ intent: QuarantineRestoreJournalIntentV1) {
    schema = QuarantineRestoreJournalIntentV1.schemaIdentifier
    version = String(QuarantineRestoreJournalIntentV1.formatVersion)
    restoreTransactionID = intent.restoreTransactionID
    quarantineTransactionID = intent.quarantineTransactionID
    quarantineIntentDigest = restoreBase64(intent.quarantineIntentDigest)
    quarantineReceiptDigest = restoreBase64(intent.quarantineReceiptDigest)
    npmRootBinding = RestoreBindingWire(intent.npmRootBinding)
    quarantineRootBinding = RestoreBindingWire(intent.quarantineRootBinding)
    candidateBinding = RestoreBindingWire(intent.candidateBinding)
    sourceComponents = intent.sourceComponents.map(restoreBase64)
    quarantineItemComponent = restoreBase64(intent.quarantineItemComponent)
    restorePolicyRevision = String(intent.restorePolicyRevision)
  }

  func domainValue() throws -> QuarantineRestoreJournalIntentV1 {
    guard schema == QuarantineRestoreJournalIntentV1.schemaIdentifier else {
      throw QuarantineRestoreJournalCodecError.unsupportedSchema
    }
    guard
      try restoreParseUInt32(version) == QuarantineRestoreJournalIntentV1.formatVersion
    else {
      throw QuarantineRestoreJournalCodecError.unsupportedVersion
    }
    return try QuarantineRestoreJournalIntentV1(
      restoreTransactionID: restoreTransactionID,
      quarantineTransactionID: quarantineTransactionID,
      quarantineIntentDigest: restoreDecodeBase64(quarantineIntentDigest),
      quarantineReceiptDigest: restoreDecodeBase64(quarantineReceiptDigest),
      npmRootBinding: npmRootBinding.domainValue(),
      quarantineRootBinding: quarantineRootBinding.domainValue(),
      candidateBinding: candidateBinding.domainValue(),
      sourceComponents: sourceComponents.map(restoreDecodeBase64),
      quarantineItemComponent: restoreDecodeBase64(quarantineItemComponent),
      restorePolicyRevision: restoreParseUInt32(restorePolicyRevision)
    )
  }
}

private struct RestoreReceiptWire: Codable {
  let schema: String
  let version: String
  let restoreTransactionID: String
  let restoreIntentDigest: String
  let outcome: String
  let sourceNameWasOccupied: Bool
  let quarantineNameWasRecreated: Bool
  let producedByRecovery: Bool

  init(_ receipt: QuarantineRestoreJournalReceiptV1) {
    schema = QuarantineRestoreJournalReceiptV1.schemaIdentifier
    version = String(QuarantineRestoreJournalReceiptV1.formatVersion)
    restoreTransactionID = receipt.restoreTransactionID
    restoreIntentDigest = restoreBase64(receipt.restoreIntentDigest)
    outcome = receipt.outcome.rawValue
    sourceNameWasOccupied = receipt.sourceNameWasOccupied
    quarantineNameWasRecreated = receipt.quarantineNameWasRecreated
    producedByRecovery = receipt.producedByRecovery
  }

  func domainValue() throws -> QuarantineRestoreJournalReceiptV1 {
    guard schema == QuarantineRestoreJournalReceiptV1.schemaIdentifier else {
      throw QuarantineRestoreJournalCodecError.unsupportedSchema
    }
    guard
      try restoreParseUInt32(version) == QuarantineRestoreJournalReceiptV1.formatVersion
    else {
      throw QuarantineRestoreJournalCodecError.unsupportedVersion
    }
    guard let outcome = QuarantineRestoreJournalReceiptOutcomeV1(rawValue: outcome) else {
      throw QuarantineRestoreJournalCodecError.invalidReceiptRelationships
    }
    return try QuarantineRestoreJournalReceiptV1(
      restoreTransactionID: restoreTransactionID,
      restoreIntentDigest: restoreDecodeBase64(restoreIntentDigest),
      outcome: outcome,
      sourceNameWasOccupied: sourceNameWasOccupied,
      quarantineNameWasRecreated: quarantineNameWasRecreated,
      producedByRecovery: producedByRecovery
    )
  }
}

private struct RestoreBindingWire: Codable {
  let device: String
  let inode: String
  let generation: String
  let birthSeconds: String
  let birthNanoseconds: String
  let kind: String
  let uid: String
  let mode: String
  let flags: String
  let linkCount: String

  init(_ binding: QuarantineJournalFileBindingV1) {
    device = String(binding.device)
    inode = String(binding.inode)
    generation = String(binding.generation)
    birthSeconds = String(binding.birthSeconds)
    birthNanoseconds = String(binding.birthNanoseconds)
    kind = binding.kind.rawValue
    uid = String(binding.ownerUID)
    mode = String(binding.permissionMode)
    flags = String(binding.flags)
    linkCount = String(binding.linkCount)
  }

  func domainValue() throws -> QuarantineJournalFileBindingV1 {
    guard
      let kind = FileSystemEntryKind(rawValue: kind),
      let generation = UInt32(exactly: try restoreParseUInt64(generation)),
      let birthNanoseconds = UInt32(exactly: try restoreParseUInt64(birthNanoseconds)),
      let ownerUID = UInt32(exactly: try restoreParseUInt64(uid)),
      let permissionMode = UInt32(exactly: try restoreParseUInt64(mode)),
      let flags = UInt32(exactly: try restoreParseUInt64(flags))
    else {
      throw QuarantineRestoreJournalCodecError.invalidBinding
    }
    return try QuarantineJournalFileBindingV1(
      device: restoreParseUInt64(device),
      inode: restoreParseUInt64(inode),
      generation: generation,
      birthSeconds: restoreParseInt64(birthSeconds),
      birthNanoseconds: birthNanoseconds,
      kind: kind,
      ownerUID: ownerUID,
      permissionMode: permissionMode,
      flags: flags,
      linkCount: restoreParseUInt64(linkCount)
    )
  }
}

private func restoreBase64(_ bytes: [UInt8]) -> String {
  Data(bytes).base64EncodedString()
}

private func restoreDecodeBase64(_ value: String) throws -> [UInt8] {
  guard
    let decoded = Data(base64Encoded: value),
    decoded.base64EncodedString() == value
  else {
    throw QuarantineRestoreJournalCodecError.malformedDocument
  }
  return Array(decoded)
}

private func restoreParseUInt32(_ value: String) throws -> UInt32 {
  let parsed = try restoreParseUInt64(value)
  guard let result = UInt32(exactly: parsed) else {
    throw QuarantineRestoreJournalCodecError.malformedDocument
  }
  return result
}

private func restoreParseUInt64(_ value: String) throws -> UInt64 {
  guard let result = UInt64(value), String(result) == value else {
    throw QuarantineRestoreJournalCodecError.malformedDocument
  }
  return result
}

private func restoreParseInt64(_ value: String) throws -> Int64 {
  guard let result = Int64(value), String(result) == value else {
    throw QuarantineRestoreJournalCodecError.malformedDocument
  }
  return result
}
