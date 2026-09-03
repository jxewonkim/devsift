import Foundation

/// Lexically validates a URL intended to name an absolute local filesystem
/// root. This does not establish that the path exists or remains bound to the
/// same filesystem object; descriptor-relative validation remains required for
/// any filesystem operation.
enum LocalFileSystemRootValidator {
  static func isValid(_ url: URL) -> Bool {
    let hostIsLocal: Bool
    if let host = url.host, !host.isEmpty {
      hostIsLocal = host.caseInsensitiveCompare("localhost") == .orderedSame
    } else {
      hostIsLocal = true
    }

    return url.isFileURL
      && url.baseURL == nil
      && hostIsLocal
      && !url.path.utf8.contains(0)
      && !url.absoluteString.lowercased().contains("%00")
      && url.user == nil
      && url.password == nil
      && url.port == nil
      && url.query == nil
      && url.fragment == nil
      && url.pathComponents.first == "/"
  }
}
