import CryptoKit
import Darwin
import Foundation

enum StagedArchiveWriterError: Error, Equatable {
    case unsafeDestination, destinationExists, exclusivePublishUnsupported, ioFailure(Int32)
}

/// A single logical writer. The recursive lock serializes final publication/cleanup when the
/// lease gate invokes publication on the persistence writer queue while cancellation races it.
final class StagedArchiveWriter: @unchecked Sendable {
    static let chunkSize = 1_024 * 1_024

    let stagingURL: URL
    let destinationURL: URL
    private let parentURL: URL
    private let stagingName: String
    private let destinationName: String
    private let parentFD: Int32
    private var stageFD: Int32 = -1
    private var entriesHandle: FileHandle?
    private var entriesHasher = SHA256()
    private var entriesBytes: Int64 = 0
    private var createdFiles = ["entries.ndjson"]
    private var createdDirectories = Set<String>()
    private var directoryFDs: [String: Int32] = [:]
    private let lock = NSRecursiveLock()

    init(destinationParent: URL, destinationName: String, stagingID: UUID) throws {
        guard destinationParent.isFileURL, !destinationName.isEmpty,
              !destinationName.contains("/"), destinationName != ".", destinationName != ".." else {
            throw StagedArchiveWriterError.unsafeDestination
        }
        parentURL = destinationParent.standardizedFileURL
        self.destinationName = destinationName
        stagingName = ".keeptide-export-\(stagingID.uuidString.lowercased()).tmp"
        stagingURL = parentURL.appendingPathComponent(stagingName, isDirectory: true)
        destinationURL = parentURL.appendingPathComponent(destinationName, isDirectory: true)
        parentFD = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw StagedArchiveWriterError.unsafeDestination }
        do {
            try validatePinnedParent()
            guard mkdirat(parentFD, stagingName, 0o700) == 0 else {
                if errno == EEXIST { throw StagedArchiveWriterError.destinationExists }
                throw StagedArchiveWriterError.ioFailure(errno)
            }
            stageFD = openat(parentFD, stagingName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard stageFD >= 0 else { throw StagedArchiveWriterError.ioFailure(errno) }
            let entriesFD = openat(stageFD, "entries.ndjson",
                                   O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard entriesFD >= 0 else { throw StagedArchiveWriterError.ioFailure(errno) }
            entriesHandle = FileHandle(fileDescriptor: entriesFD, closeOnDealloc: true)
        } catch {
            if stageFD >= 0 {
                close(stageFD)
                _ = unlinkat(parentFD, stagingName, AT_REMOVEDIR)
            }
            close(parentFD)
            throw error
        }
    }

    deinit {
        try? entriesHandle?.close()
        for descriptor in directoryFDs.values { close(descriptor) }
        if stageFD >= 0 { close(stageFD) }
        close(parentFD)
    }

    func appendEntry(_ entry: ArchiveEntry) throws {
        lock.lock(); defer { lock.unlock() }
        try Task.checkCancellation()
        let encoder = Self.encoder()
        var line = try encoder.encode(entry)
        line.append(0x0A)
        try entriesHandle?.write(contentsOf: line)
        entriesHasher.update(data: line)
        entriesBytes += Int64(line.count)
    }

    func write(_ data: Data, relativePath: String) throws -> ArchiveFileDigest {
        lock.lock(); defer { lock.unlock() }
        guard Self.isSafe(relativePath) else { throw StagedArchiveWriterError.unsafeDestination }
        let components = relativePath.split(separator: "/").map(String.init)
        let directoryFD: Int32
        let filename: String
        if components.count == 2 {
            let directory = components[0]
            if mkdirat(stageFD, directory, 0o700) != 0, errno != EEXIST {
                throw StagedArchiveWriterError.ioFailure(errno)
            }
            if let existing = directoryFDs[directory] {
                directoryFD = existing
            } else {
                directoryFD = openat(stageFD, directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard directoryFD >= 0 else { throw StagedArchiveWriterError.unsafeDestination }
                directoryFDs[directory] = directoryFD
            }
            createdDirectories.insert(directory)
            filename = components[1]
        } else {
            directoryFD = stageFD
            filename = components[0]
        }
        let fileFD = openat(directoryFD, filename,
                            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fileFD >= 0 else {
            throw errno == EEXIST ? StagedArchiveWriterError.destinationExists
                                  : StagedArchiveWriterError.ioFailure(errno)
        }
        let handle = FileHandle(fileDescriptor: fileFD, closeOnDealloc: true)
        createdFiles.append(relativePath)
        var hasher = SHA256()
        do {
            var offset = 0
            while offset < data.count {
                try Task.checkCancellation()
                let end = min(offset + Self.chunkSize, data.count)
                let chunk = data.subdata(in: offset..<end)
                try handle.write(contentsOf: chunk)
                hasher.update(data: chunk)
                offset = end
            }
            try handle.synchronize()
            try handle.close()
        } catch { try? handle.close(); throw error }
        return ArchiveFileDigest(path: relativePath, byteCount: Int64(data.count), sha256: Self.hex(hasher.finalize()))
    }

    func finishEntries() throws -> ArchiveFileDigest {
        lock.lock(); defer { lock.unlock() }
        try entriesHandle?.synchronize()
        try entriesHandle?.close()
        entriesHandle = nil
        return ArchiveFileDigest(path: "entries.ndjson", byteCount: entriesBytes,
                                 sha256: Self.hex(entriesHasher.finalize()))
    }

    func writeManifest(_ manifest: ArchiveManifest) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try Self.encoder().encode(manifest)
        _ = try write(data, relativePath: "manifest.json")
    }

    func publish() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        try Task.checkCancellation()
        try validatePinnedParent()
        try validateStagePath()
        guard renameatx_np(parentFD, stagingName, parentFD, destinationName, UInt32(RENAME_EXCL)) == 0 else {
            switch errno {
            case EEXIST: throw StagedArchiveWriterError.destinationExists
            case ENOTSUP, EINVAL: throw StagedArchiveWriterError.exclusivePublishUnsupported
            default: throw StagedArchiveWriterError.ioFailure(errno)
            }
        }
        _ = fsync(parentFD)
        return destinationURL
    }

    func preparePublication() throws {
        lock.lock(); defer { lock.unlock() }
        for descriptor in directoryFDs.values {
            guard fsync(descriptor) == 0 else { throw StagedArchiveWriterError.ioFailure(errno) }
        }
        guard fsync(stageFD) == 0 else { throw StagedArchiveWriterError.ioFailure(errno) }
    }

    func cleanup() {
        lock.lock(); defer { lock.unlock() }
        try? entriesHandle?.close(); entriesHandle = nil
        for path in createdFiles.reversed() {
            let components = path.split(separator: "/").map(String.init)
            if components.count == 2 {
                if let directoryFD = directoryFDs[components[0]] {
                    _ = unlinkat(directoryFD, components[1], 0)
                }
            } else if components.count == 1 {
                _ = unlinkat(stageFD, components[0], 0)
            }
        }
        for directory in createdDirectories {
            guard let descriptor = directoryFDs[directory], path(directory, matches: descriptor, under: stageFD) else {
                continue
            }
            _ = unlinkat(stageFD, directory, AT_REMOVEDIR)
        }
        if (try? validatePinnedParent()) != nil, (try? validateStagePath()) != nil {
            _ = unlinkat(parentFD, stagingName, AT_REMOVEDIR)
        }
    }

    private func validatePinnedParent() throws {
        var descriptor = stat(), current = stat()
        guard fstat(parentFD, &descriptor) == 0, lstat(parentURL.path, &current) == 0,
              (current.st_mode & S_IFMT) == S_IFDIR,
              descriptor.st_dev == current.st_dev, descriptor.st_ino == current.st_ino else {
            throw StagedArchiveWriterError.unsafeDestination
        }
    }

    private func validateStagePath() throws {
        var descriptor = stat(), current = stat()
        guard fstat(stageFD, &descriptor) == 0,
              fstatat(parentFD, stagingName, &current, AT_SYMLINK_NOFOLLOW) == 0,
              (current.st_mode & S_IFMT) == S_IFDIR,
              descriptor.st_dev == current.st_dev, descriptor.st_ino == current.st_ino else {
            throw StagedArchiveWriterError.unsafeDestination
        }
    }

    private func path(_ name: String, matches descriptor: Int32, under parent: Int32) -> Bool {
        var owned = stat(), current = stat()
        return fstat(descriptor, &owned) == 0
            && fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0
            && (current.st_mode & S_IFMT) == S_IFDIR
            && owned.st_dev == current.st_dev
            && owned.st_ino == current.st_ino
    }

    private static func isSafe(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.hasPrefix("/") && !path.contains("\\") && (1...2).contains(components.count) &&
            components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
