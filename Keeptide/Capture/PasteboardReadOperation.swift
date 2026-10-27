import Darwin
import Foundation

/// One short-lived child owns all materialization. Process separation is needed:
/// NSPasteboard(name:) can return the same cached object elsewhere in the app.
final class PasteboardReadOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let timeout: TimeInterval
    private let environment: [String: String]?

    init(timeout: TimeInterval = 30, environment: [String: String]? = nil) {
        self.timeout = timeout
        self.environment = environment
    }
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    private var finished = false

    func cancel(timedOut: Bool = false) {
        let running = lock.withLock { () -> Process? in
            guard !finished else { return nil }
            self.timedOut = self.timedOut || (!cancelled && timedOut)
            cancelled = true
            return process
        }
        if let running { Self.stop(running) }
    }

    func read(executable: URL, pasteboardName: String, expectedChangeCount: Int) throws -> CaptureSnapshotValue {
        let child = Process()
        let output = Pipe()
        child.executableURL = executable
        if let environment { child.environment = environment }
        child.arguments = ["--pasteboard", pasteboardName, "--change-count", String(expectedChangeCount)]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        defer {
            Self.stop(child)
            if child.processIdentifier > 0 { child.waitUntilExit() }
            lock.withLock { finished = true; process = nil }
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            process = child
            do { try child.run() } catch { throw SnapshotReaderError.readerUnavailable }
        }
        do { try output.fileHandleForWriting.close() }
        catch { throw SnapshotReaderError.readerUnavailable }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.cancel(timedOut: true)
        }
        let headerSize = CaptureWire.magic.count + MemoryLayout<UInt64>.size
        var data = Data()
        do {
            while let chunk = try output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                guard chunk.count <= CaptureWire.maximumResponseBytes + headerSize - data.count else {
                    Self.stop(child)
                    throw SnapshotReaderError.readerUnavailable
                }
                data.append(chunk)
            }
        } catch {
            let cancellation = lock.withLock { (cancelled, timedOut) }
            if cancellation.1 { throw SnapshotReaderError.readTimedOut }
            if cancellation.0 { throw CancellationError() }
            throw SnapshotReaderError.readerUnavailable
        }
        child.waitUntilExit() // Dedicated utility task, never the UI executor.
        let cancellation = lock.withLock { (cancelled, timedOut) }
        if cancellation.1 { throw SnapshotReaderError.readTimedOut }
        if cancellation.0 { throw CancellationError() }
        guard child.terminationStatus == 0 else { throw SnapshotReaderError.readerUnavailable }
        return try Self.decodeReply(data, processID: child.processIdentifier, expectedChangeCount: expectedChangeCount)
    }

    private static func stop(_ child: Process) {
        guard child.isRunning else { return }
        // This child only reads immutable data. Force termination cannot interrupt
        // a store write, and a blocked provider must not hold shutdown open.
        kill(child.processIdentifier, SIGKILL)
    }

    static func decodeReply(_ data: Data, processID: Int32, expectedChangeCount: Int) throws -> CaptureSnapshotValue {
        let headerSize = CaptureWire.magic.count + MemoryLayout<UInt64>.size
        guard data.count >= headerSize,
              data.prefix(CaptureWire.magic.count) == CaptureWire.magic else { throw SnapshotReaderError.readerUnavailable }
        let length = data[CaptureWire.magic.count..<headerSize].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard length <= CaptureWire.maximumResponseBytes, length == data.count - headerSize else {
            throw SnapshotReaderError.readerUnavailable
        }
        let reply: CaptureReaderReply
        do { reply = try PropertyListDecoder().decode(CaptureReaderReply.self, from: data.dropFirst(headerSize)) }
        catch { throw SnapshotReaderError.readerUnavailable }
        guard reply.protocolVersion == 1, reply.processID == processID,
              (reply.snapshot == nil) != (reply.failure == nil) else { throw SnapshotReaderError.readerUnavailable }
        if let failure = reply.failure { throw failure }
        guard let snapshot = reply.snapshot, snapshot.changeCount == expectedChangeCount else {
            throw SnapshotReaderError.readerUnavailable
        }
        return snapshot
    }
}
