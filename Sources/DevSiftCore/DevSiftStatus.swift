public enum SafetyMode: String, Codable, Sendable {
  case scanOnly = "scan-only"

  public var allowsFilesystemMutation: Bool {
    false
  }
}

public struct DevSiftStatus: Equatable, Sendable {
  public static let current = DevSiftStatus(
    version: "0.0.0-dev",
    safetyMode: .scanOnly
  )

  public let version: String
  public let safetyMode: SafetyMode

  public init(version: String, safetyMode: SafetyMode) {
    self.version = version
    self.safetyMode = safetyMode
  }

  public var summary: String {
    "DevSift \(version) (\(safetyMode.rawValue))"
  }
}
