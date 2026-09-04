import CryptoKit
import Foundation

/// The complete stable filesystem binding persisted by quarantine journal v1.
///
/// This is a Core domain value rather than a wire DTO. In particular, it is
/// deliberately not `Codable`; the private DTOs below own the disk format.
struct QuarantineJournalFileBindingV1: Equatable, Sendable {
  let device: UInt64
  let inode: UInt64
  let generation: UInt32
  let birthSeconds: Int64
  let birthNanoseconds: UInt32
  let kind: FileSystemEntryKind
  let ownerUID: UInt32
  let permissionMode: UInt32
  let flags: UInt32
  let linkCount: UInt64

  init(
    device: UInt64,
    inode: UInt64,
    generation: UInt32,
    birthSeconds: Int64,
    birthNanoseconds: UInt32,
    kind: FileSystemEntryKind,
    ownerUID: UInt32,
    permissionMode: UInt32,
    flags: UInt32,
    linkCount: UInt64
  ) {
    self.device = device
    self.inode = inode
    self.generation = generation
    self.birthSeconds = birthSeconds
    self.birthNanoseconds = birthNanoseconds
    self.kind = kind
    self.ownerUID = ownerUID
    self.permissionMode = permissionMode
    self.flags = flags
    self.linkCount = linkCount
  }

  init?(snapshot: DescriptorStatSnapshot) {
    guard
      let birthSeconds = Int64(exactly: snapshot.birthSeconds),
      let birthNanoseconds = UInt32(exactly: snapshot.birthNanoseconds),
      let ownerUID = UInt32(exactly: snapshot.ownerUID),
      let permissionMode = UInt32(exactly: snapshot.permissionMode)
    else {
      return nil
    }
    self.init(
      device: snapshot.identity.device,
      inode: snapshot.identity.inode,
      generation: snapshot.generation,
      birthSeconds: birthSeconds,
      birthNanoseconds: birthNanoseconds,
      kind: snapshot.kind,
      ownerUID: ownerUID,
      permissionMode: permissionMode,
      flags: snapshot.flags,
      linkCount: snapshot.linkCount
    )
  }
}

struct QuarantineJournalPolicyRevisionV1: Equatable, Sendable {
  let identifier: String
  let version: UInt32
}

struct QuarantineJournalPolicyV1: Equatable, Sendable {
  let classification: QuarantineJournalPolicyRevisionV1
  let catalog: QuarantineJournalPolicyRevisionV1
  let npmRule: QuarantineJournalPolicyRevisionV1

  static let current = QuarantineJournalPolicyV1(
    classification: QuarantineJournalPolicyRevisionV1(
      identifier: "devsift.classification.explainable",
      version: 3
    ),
    catalog: QuarantineJournalPolicyRevisionV1(
      identifier: "devsift.builtin-rules",
      version: 6
    ),
    npmRule: QuarantineJournalPolicyRevisionV1(
      identifier: "devsift.cache.npm",
      version: 5
    )
  )
}

/// Immutable domain value represented by one final `.intent-v1-*` record.
struct QuarantineJournalIntentV1: Equatable, Sendable {
  static let schemaIdentifier = "devsift.quarantine-intent"
  static let formatVersion: UInt32 = 1
  static let destinationCount = 16

  let transactionID: String
  let npmRootBinding: QuarantineJournalFileBindingV1
  let quarantineRootBinding: QuarantineJournalFileBindingV1
  let candidateBinding: QuarantineJournalFileBindingV1
  let sourceComponents: [[UInt8]]
  let destinationComponents: [[UInt8]]
  let policy: QuarantineJournalPolicyV1

  init(
    transactionID: String,
    npmRootBinding: QuarantineJournalFileBindingV1,
    quarantineRootBinding: QuarantineJournalFileBindingV1,
    candidateBinding: QuarantineJournalFileBindingV1,
    sourceComponents: [[UInt8]],
    destinationComponents: [[UInt8]],
    policy: QuarantineJournalPolicyV1 = .current
  ) {
    self.transactionID = transactionID
    self.npmRootBinding = npmRootBinding
    self.quarantineRootBinding = quarantineRootBinding
    self.candidateBinding = candidateBinding
    self.sourceComponents = sourceComponents
    self.destinationComponents = destinationComponents
    self.policy = policy
  }
}

enum QuarantineJournalReceiptOutcomeV1: String, Equatable, Sendable {
  case quarantined
  case notMoved = "not-moved"
  case rolledBack = "rolled-back"
}

/// Immutable domain value represented by one final `.receipt-v1-*` record.
struct QuarantineJournalReceiptV1: Equatable, Sendable {
  static let schemaIdentifier = "devsift.quarantine-receipt"
  static let formatVersion: UInt32 = 1

  let transactionID: String
  let intentDigest: [UInt8]
  let outcome: QuarantineJournalReceiptOutcomeV1
  let selectedDestinationOrdinal: Int?
  let destinationBinding: QuarantineJournalFileBindingV1?
  let sourceNameWasRecreated: Bool
  let producedByRecovery: Bool
}

enum QuarantineJournalCodecError: Error, Equatable, Sendable {
  case emptyDocument
  case documentTooLarge
  case malformedDocument
  case nonCanonicalDocument
  case unsupportedSchema
  case unsupportedVersion
  case invalidTransactionID
  case invalidBinding
  case invalidSourcePath
  case invalidDestinationPlan
  case policyDrift
  case invalidIntentDigest
  case invalidReceiptRelationships
  case receiptDoesNotMatchIntent
}

/// Strict, bounded codec for DevSift's two private quarantine journal records.
///
/// Decode succeeds only when the input is already the one canonical encoding
/// of the validated domain value. Consequently JSON features that
/// `JSONDecoder` otherwise tolerates, including unknown or duplicate keys and
/// insignificant whitespace, are rejected by byte-for-byte re-encoding.
enum QuarantineJournalV1Codec {
  static let maximumEncodedByteCount = 32 * 1_024

  static func encode(_ intent: QuarantineJournalIntentV1) throws -> Data {
    try validateIntentStructure(intent)
    guard intent.policy == .current else {
      throw QuarantineJournalCodecError.policyDrift
    }
    return try encodeCanonicalIntent(intent)
  }

  static func decodeIntent(_ bytes: Data) throws -> QuarantineJournalIntentV1 {
    try validateInputSize(bytes)
    let wire: IntentWire = try decode(bytes)
    let intent = try wire.domainValue()
    try validateIntentStructure(intent)
    guard try encodeCanonicalIntent(intent) == bytes else {
      throw QuarantineJournalCodecError.nonCanonicalDocument
    }
    return intent
  }

  static func encode(_ receipt: QuarantineJournalReceiptV1) throws -> Data {
    try validate(receipt)
    return try encodeBounded(ReceiptWire(receipt))
  }

  static func encode(
    _ receipt: QuarantineJournalReceiptV1,
    matchingIntentBytes intentBytes: Data
  ) throws -> Data {
    let intent = try decodeIntent(intentBytes)
    try validate(receipt, matching: intent, canonicalIntentBytes: intentBytes)
    return try encode(receipt)
  }

  static func decodeReceipt(_ bytes: Data) throws -> QuarantineJournalReceiptV1 {
    try validateInputSize(bytes)
    let wire: ReceiptWire = try decode(bytes)
    let receipt = try wire.domainValue()
    try validate(receipt)
    guard try encode(receipt) == bytes else {
      throw QuarantineJournalCodecError.nonCanonicalDocument
    }
    return receipt
  }

  static func decodeReceipt(
    _ bytes: Data,
    matchingIntentBytes intentBytes: Data
  ) throws -> QuarantineJournalReceiptV1 {
    let intent = try decodeIntent(intentBytes)
    let receipt = try decodeReceipt(bytes)
    try validate(receipt, matching: intent, canonicalIntentBytes: intentBytes)
    return receipt
  }

  static func makeReceipt(
    outcome: QuarantineJournalReceiptOutcomeV1,
    selectedDestinationOrdinal: Int? = nil,
    sourceNameWasRecreated: Bool = false,
    producedByRecovery: Bool,
    canonicalIntentBytes intentBytes: Data
  ) throws -> QuarantineJournalReceiptV1 {
    let intent = try decodeIntent(intentBytes)
    let receipt = QuarantineJournalReceiptV1(
      transactionID: intent.transactionID,
      intentDigest: digest(intentBytes),
      outcome: outcome,
      selectedDestinationOrdinal: selectedDestinationOrdinal,
      destinationBinding: outcome == .quarantined ? intent.candidateBinding : nil,
      sourceNameWasRecreated: sourceNameWasRecreated,
      producedByRecovery: producedByRecovery
    )
    try validate(receipt, matching: intent, canonicalIntentBytes: intentBytes)
    return receipt
  }

  static func intentDigest(forCanonicalIntentBytes bytes: Data) throws -> [UInt8] {
    _ = try decodeIntent(bytes)
    return digest(bytes)
  }

  static func validate(
    _ receipt: QuarantineJournalReceiptV1,
    matching intent: QuarantineJournalIntentV1,
    canonicalIntentBytes intentBytes: Data
  ) throws {
    let decodedIntent = try decodeIntent(intentBytes)
    guard decodedIntent == intent else {
      throw QuarantineJournalCodecError.receiptDoesNotMatchIntent
    }
    try validate(receipt)
    guard
      receipt.transactionID == intent.transactionID,
      receipt.intentDigest == digest(intentBytes)
    else {
      throw QuarantineJournalCodecError.receiptDoesNotMatchIntent
    }
    if receipt.outcome == .quarantined {
      guard receipt.destinationBinding == intent.candidateBinding else {
        throw QuarantineJournalCodecError.receiptDoesNotMatchIntent
      }
    }
  }

  private static func validateIntentStructure(_ intent: QuarantineJournalIntentV1) throws {
    guard isLowercaseHexIdentifier(intent.transactionID) else {
      throw QuarantineJournalCodecError.invalidTransactionID
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
      throw QuarantineJournalCodecError.invalidBinding
    }

    let identities = [
      intent.npmRootBinding.inode,
      intent.quarantineRootBinding.inode,
      intent.candidateBinding.inode,
    ]
    guard Set(identities).count == identities.count else {
      throw QuarantineJournalCodecError.invalidBinding
    }
    guard intent.sourceComponents == [Array("_cacache".utf8)] else {
      throw QuarantineJournalCodecError.invalidSourcePath
    }
    guard
      intent.destinationComponents.count == QuarantineJournalIntentV1.destinationCount,
      Set(intent.destinationComponents).count == intent.destinationComponents.count,
      intent.destinationComponents.allSatisfy(isDestinationComponent)
    else {
      throw QuarantineJournalCodecError.invalidDestinationPlan
    }
    guard
      isSupportedHistoricalRevision(
        intent.policy.classification,
        current: QuarantineJournalPolicyV1.current.classification
      ),
      isSupportedHistoricalRevision(
        intent.policy.catalog,
        current: QuarantineJournalPolicyV1.current.catalog
      ),
      isSupportedHistoricalRevision(
        intent.policy.npmRule,
        current: QuarantineJournalPolicyV1.current.npmRule
      )
    else {
      throw QuarantineJournalCodecError.policyDrift
    }
  }

  private static func isSupportedHistoricalRevision(
    _ revision: QuarantineJournalPolicyRevisionV1,
    current: QuarantineJournalPolicyRevisionV1
  ) -> Bool {
    revision.identifier == current.identifier
      && revision.version > 0
      && revision.version <= current.version
  }

  private static func validate(_ receipt: QuarantineJournalReceiptV1) throws {
    guard isLowercaseHexIdentifier(receipt.transactionID) else {
      throw QuarantineJournalCodecError.invalidTransactionID
    }
    guard receipt.intentDigest.count == SHA256.byteCount else {
      throw QuarantineJournalCodecError.invalidIntentDigest
    }

    switch receipt.outcome {
    case .quarantined:
      guard
        let ordinal = receipt.selectedDestinationOrdinal,
        (0..<QuarantineJournalIntentV1.destinationCount).contains(ordinal),
        let binding = receipt.destinationBinding,
        binding.kind == .directory,
        isValidBinding(binding)
      else {
        throw QuarantineJournalCodecError.invalidReceiptRelationships
      }
    case .notMoved:
      guard
        receipt.selectedDestinationOrdinal == nil,
        receipt.destinationBinding == nil,
        !receipt.sourceNameWasRecreated
      else {
        throw QuarantineJournalCodecError.invalidReceiptRelationships
      }
    case .rolledBack:
      guard
        receipt.selectedDestinationOrdinal == nil,
        receipt.destinationBinding == nil,
        !receipt.sourceNameWasRecreated,
        !receipt.producedByRecovery
      else {
        throw QuarantineJournalCodecError.invalidReceiptRelationships
      }
    }
  }

  private static func isValidBinding(_ binding: QuarantineJournalFileBindingV1) -> Bool {
    binding.birthNanoseconds < 1_000_000_000
      && binding.permissionMode <= 0o7777
      && binding.linkCount > 0
  }

  private static func isLowercaseHexIdentifier(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return bytes.count == 32 && bytes.allSatisfy(isLowercaseHexDigit)
  }

  private static func isDestinationComponent(_ bytes: [UInt8]) -> Bool {
    let prefix = Array("item-v1-".utf8)
    return bytes.count == prefix.count + 32
      && bytes.starts(with: prefix)
      && bytes.dropFirst(prefix.count).allSatisfy(isLowercaseHexDigit)
  }

  private static func isLowercaseHexDigit(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
  }

  private static func validateInputSize(_ bytes: Data) throws {
    guard !bytes.isEmpty else {
      throw QuarantineJournalCodecError.emptyDocument
    }
    guard bytes.count <= maximumEncodedByteCount else {
      throw QuarantineJournalCodecError.documentTooLarge
    }
  }

  private static func encodeBounded<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes: Data
    do {
      bytes = try encoder.encode(value)
    } catch {
      throw QuarantineJournalCodecError.malformedDocument
    }
    guard bytes.count <= maximumEncodedByteCount else {
      throw QuarantineJournalCodecError.documentTooLarge
    }
    return bytes
  }

  private static func encodeCanonicalIntent(
    _ intent: QuarantineJournalIntentV1
  ) throws -> Data {
    try encodeBounded(IntentWire(intent))
  }

  private static func decode<Value: Decodable>(_ bytes: Data) throws -> Value {
    do {
      return try JSONDecoder().decode(Value.self, from: bytes)
    } catch {
      throw QuarantineJournalCodecError.malformedDocument
    }
  }

  private static func digest(_ bytes: Data) -> [UInt8] {
    Array(SHA256.hash(data: bytes))
  }
}

private struct IntentWire: Codable {
  let schema: String
  let version: String
  let transactionID: String
  let npmRootBinding: BindingWire
  let quarantineRootBinding: BindingWire
  let candidateBinding: BindingWire
  let sourceComponents: [String]
  let destinationComponents: [String]
  let classificationRevision: PolicyRevisionWire
  let catalogRevision: PolicyRevisionWire
  let npmRuleRevision: PolicyRevisionWire

  init(_ intent: QuarantineJournalIntentV1) {
    schema = QuarantineJournalIntentV1.schemaIdentifier
    version = String(QuarantineJournalIntentV1.formatVersion)
    transactionID = intent.transactionID
    npmRootBinding = BindingWire(intent.npmRootBinding)
    quarantineRootBinding = BindingWire(intent.quarantineRootBinding)
    candidateBinding = BindingWire(intent.candidateBinding)
    sourceComponents = intent.sourceComponents.map(base64)
    destinationComponents = intent.destinationComponents.map(base64)
    classificationRevision = PolicyRevisionWire(intent.policy.classification)
    catalogRevision = PolicyRevisionWire(intent.policy.catalog)
    npmRuleRevision = PolicyRevisionWire(intent.policy.npmRule)
  }

  func domainValue() throws -> QuarantineJournalIntentV1 {
    guard schema == QuarantineJournalIntentV1.schemaIdentifier else {
      throw QuarantineJournalCodecError.unsupportedSchema
    }
    guard
      try parseUInt32(version) == QuarantineJournalIntentV1.formatVersion
    else {
      throw QuarantineJournalCodecError.unsupportedVersion
    }
    return try QuarantineJournalIntentV1(
      transactionID: transactionID,
      npmRootBinding: npmRootBinding.domainValue(),
      quarantineRootBinding: quarantineRootBinding.domainValue(),
      candidateBinding: candidateBinding.domainValue(),
      sourceComponents: sourceComponents.map(decodeBase64),
      destinationComponents: destinationComponents.map(decodeBase64),
      policy: QuarantineJournalPolicyV1(
        classification: classificationRevision.domainValue(),
        catalog: catalogRevision.domainValue(),
        npmRule: npmRuleRevision.domainValue()
      )
    )
  }
}

private struct ReceiptWire: Codable {
  let schema: String
  let version: String
  let transactionID: String
  let intentDigest: String
  let outcome: String
  let selectedDestinationOrdinal: String?
  let destinationBinding: BindingWire?
  let sourceNameWasRecreated: Bool
  let producedByRecovery: Bool

  init(_ receipt: QuarantineJournalReceiptV1) {
    schema = QuarantineJournalReceiptV1.schemaIdentifier
    version = String(QuarantineJournalReceiptV1.formatVersion)
    transactionID = receipt.transactionID
    intentDigest = base64(receipt.intentDigest)
    outcome = receipt.outcome.rawValue
    selectedDestinationOrdinal = receipt.selectedDestinationOrdinal.map(String.init)
    destinationBinding = receipt.destinationBinding.map(BindingWire.init)
    sourceNameWasRecreated = receipt.sourceNameWasRecreated
    producedByRecovery = receipt.producedByRecovery
  }

  func domainValue() throws -> QuarantineJournalReceiptV1 {
    guard schema == QuarantineJournalReceiptV1.schemaIdentifier else {
      throw QuarantineJournalCodecError.unsupportedSchema
    }
    guard
      try parseUInt32(version) == QuarantineJournalReceiptV1.formatVersion
    else {
      throw QuarantineJournalCodecError.unsupportedVersion
    }
    guard let outcome = QuarantineJournalReceiptOutcomeV1(rawValue: outcome) else {
      throw QuarantineJournalCodecError.invalidReceiptRelationships
    }
    let ordinal: Int?
    if let selectedDestinationOrdinal {
      let decoded = try parseUInt64(selectedDestinationOrdinal)
      guard let value = Int(exactly: decoded) else {
        throw QuarantineJournalCodecError.invalidReceiptRelationships
      }
      ordinal = value
    } else {
      ordinal = nil
    }
    return try QuarantineJournalReceiptV1(
      transactionID: transactionID,
      intentDigest: decodeBase64(intentDigest),
      outcome: outcome,
      selectedDestinationOrdinal: ordinal,
      destinationBinding: destinationBinding?.domainValue(),
      sourceNameWasRecreated: sourceNameWasRecreated,
      producedByRecovery: producedByRecovery
    )
  }
}

private struct BindingWire: Codable {
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
      let generation = UInt32(exactly: try parseUInt64(generation)),
      let birthNanoseconds = UInt32(exactly: try parseUInt64(birthNanoseconds)),
      let ownerUID = UInt32(exactly: try parseUInt64(uid)),
      let permissionMode = UInt32(exactly: try parseUInt64(mode)),
      let flags = UInt32(exactly: try parseUInt64(flags))
    else {
      throw QuarantineJournalCodecError.invalidBinding
    }
    return try QuarantineJournalFileBindingV1(
      device: parseUInt64(device),
      inode: parseUInt64(inode),
      generation: generation,
      birthSeconds: parseInt64(birthSeconds),
      birthNanoseconds: birthNanoseconds,
      kind: kind,
      ownerUID: ownerUID,
      permissionMode: permissionMode,
      flags: flags,
      linkCount: parseUInt64(linkCount)
    )
  }
}

private struct PolicyRevisionWire: Codable {
  let identifier: String
  let version: String

  init(_ revision: QuarantineJournalPolicyRevisionV1) {
    identifier = revision.identifier
    version = String(revision.version)
  }

  func domainValue() throws -> QuarantineJournalPolicyRevisionV1 {
    QuarantineJournalPolicyRevisionV1(
      identifier: identifier,
      version: try parseUInt32(version)
    )
  }
}

private func base64(_ bytes: [UInt8]) -> String {
  Data(bytes).base64EncodedString()
}

private func decodeBase64(_ value: String) throws -> [UInt8] {
  guard
    let decoded = Data(base64Encoded: value),
    decoded.base64EncodedString() == value
  else {
    throw QuarantineJournalCodecError.malformedDocument
  }
  return Array(decoded)
}

private func parseUInt32(_ value: String) throws -> UInt32 {
  let parsed = try parseUInt64(value)
  guard let result = UInt32(exactly: parsed) else {
    throw QuarantineJournalCodecError.malformedDocument
  }
  return result
}

private func parseUInt64(_ value: String) throws -> UInt64 {
  guard let result = UInt64(value), String(result) == value else {
    throw QuarantineJournalCodecError.malformedDocument
  }
  return result
}

private func parseInt64(_ value: String) throws -> Int64 {
  guard let result = Int64(value), String(result) == value else {
    throw QuarantineJournalCodecError.malformedDocument
  }
  return result
}
