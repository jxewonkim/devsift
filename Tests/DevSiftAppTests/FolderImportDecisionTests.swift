import Foundation
import Testing

@testable import DevSiftApp

@Suite("Folder import decisions")
struct FolderImportDecisionTests {
  @Test("A successful picker result preserves the exact first URL")
  func successfulSelection() {
    let selected = URL(
      fileURLWithPath: "/private/tmp/DevSift picker/../selected",
      isDirectory: true
    )

    #expect(FolderImportDecision.resolve(.success([selected])) == .scan(selected))
  }

  @Test("An empty successful result is treated as a failure")
  func emptySelection() {
    #expect(FolderImportDecision.resolve(.success([])) == .failure)
  }

  @Test("Only the Cocoa user-cancelled error is ignored")
  func cancellationIdentity() {
    let cancellation = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
    let sameCodeFromAnotherDomain = NSError(
      domain: NSPOSIXErrorDomain,
      code: NSUserCancelledError
    )

    #expect(FolderImportDecision.resolve(.failure(cancellation)) == .cancelled)
    #expect(FolderImportDecision.resolve(.failure(sameCodeFromAnotherDomain)) == .failure)
  }

  @Test("Ordinary picker errors are surfaced")
  func pickerFailure() {
    let failure = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)

    #expect(FolderImportDecision.resolve(.failure(failure)) == .failure)
  }
}
