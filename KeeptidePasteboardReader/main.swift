import AppKit
import Foundation

#if DEBUG
// Synthetic process-lifecycle fixtures are absent from Release builds. They do
// not access any pasteboard; the PID marker is inside the test's temporary store.
if let mode = ProcessInfo.processInfo.environment["KEEPTIDE_READER_FIXTURE"],
   let marker = ProcessInfo.processInfo.environment["KEEPTIDE_READER_FIXTURE_PID"],
   ["stall", "oversized"].contains(mode) {
    do {
        try Data(String(getpid()).utf8).write(to: URL(fileURLWithPath: marker), options: .atomic)
        if mode == "stall" { Thread.sleep(forTimeInterval: 30) }
        else {
            let chunk = Data(repeating: 0, count: 65_536)
            for _ in 0...CaptureWire.maximumResponseBytes / chunk.count {
                try FileHandle.standardOutput.write(contentsOf: chunk)
            }
        }
        exit(0)
    } catch { exit(74) }
}
#endif

// No shell, network, persistent state or UI. A crash or blocked provider in this
// process cannot mutate the parent app's AppKit pasteboard caches.
guard CommandLine.arguments.count == 5,
      CommandLine.arguments[1] == "--pasteboard",
      CommandLine.arguments[3] == "--change-count",
      let expected = Int(CommandLine.arguments[4]) else { exit(64) }

let reply: CaptureReaderReply = autoreleasepool {
    do {
        let snapshot = try SnapshotMaterializer.read(
            pasteboard: NSPasteboard(name: .init(CommandLine.arguments[2])),
            sourceApp: nil, expectedChangeCount: expected)
        return CaptureReaderReply(protocolVersion: 1, processID: ProcessInfo.processInfo.processIdentifier,
                                  snapshot: snapshot, failure: nil)
    } catch {
        return CaptureReaderReply(protocolVersion: 1, processID: ProcessInfo.processInfo.processIdentifier,
                                  snapshot: nil, failure: error as? SnapshotReaderError ?? .readerUnavailable)
    }
}
do {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let payload = try encoder.encode(reply)
    guard payload.count <= CaptureWire.maximumResponseBytes else { exit(65) }
    var length = UInt64(payload.count).bigEndian
    var frame = CaptureWire.magic
    withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    try FileHandle.standardOutput.write(contentsOf: frame)
    try FileHandle.standardOutput.write(contentsOf: payload)
} catch { exit(74) }
