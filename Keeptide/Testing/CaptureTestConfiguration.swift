import Foundation

/// Shared by the debug app and the synthetic host. Malformed explicit IDs never
/// silently select a different pasteboard or a production library.
struct CaptureTestConfiguration: Sendable {
    /// The system test host, the one app a test session pastes into: it reads the session's pasteboard, where any
    /// other app would paste from the general one.
    static let systemTestHostBundleIdentifier = "io.github.insightprober.Keeptide.SystemTestHost"

    let id: UUID
    var pasteboardName: String { "io.github.insightprober.Keeptide.capture-test.\(id.uuidString)" }
    var preferencesSuite: String { "KeeptideCaptureTest.\(id.uuidString)" }
    var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("KeeptideCaptureTests", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }
    static func parse(_ arguments: [String]) throws -> Self? {
        let indices = arguments.indices.filter { arguments[$0] == "--capture-test-session" }
        guard !indices.isEmpty else { return nil }
        guard indices.count == 1, let index = indices.first,
              arguments.indices.contains(index + 1), let id = UUID(uuidString: arguments[index + 1]) else {
            throw CocoaError(.coderInvalidValue)
        }
        return Self(id: id)
    }
}
