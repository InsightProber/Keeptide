import Foundation

struct ManifestEntry: Codable, Equatable, Sendable {
    var itemIndex: Int
    var representationIndex: Int
    var typeIdentifier: String
    var storage: RepresentationStorage
    var byteCount: Int64
    var digest: Data

    init(
        itemIndex: Int,
        representationIndex: Int,
        typeIdentifier: String,
        storage: RepresentationStorage,
        byteCount: Int64,
        digest: Data
    ) {
        self.itemIndex = itemIndex
        self.representationIndex = representationIndex
        self.typeIdentifier = typeIdentifier
        self.storage = storage
        self.byteCount = byteCount
        self.digest = digest
    }

    init(_ representation: RepresentationValue) {
        self.init(
            itemIndex: representation.itemIndex,
            representationIndex: representation.representationIndex,
            typeIdentifier: representation.typeIdentifier,
            storage: representation.storage,
            byteCount: representation.byteCount,
            digest: representation.digest
        )
    }
}

struct CaptureManifest: Codable, Equatable, Sendable {
    var version: Int
    var itemCount: Int
    var entries: [ManifestEntry]

    init(version: Int = 1, itemCount: Int, entries: [ManifestEntry]) {
        self.version = version
        self.itemCount = itemCount
        self.entries = entries
    }

    func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    func validate(_ representations: [RepresentationValue], snapshotID: UUID) -> ContentIntegrity {
        guard hasValidCoordinates else {
            return .corrupt
        }
        guard representations.count <= entries.count else {
            return .corrupt
        }

        let entriesByCoordinate = Dictionary(uniqueKeysWithValues: entries.map {
            (ManifestCoordinate(itemIndex: $0.itemIndex, representationIndex: $0.representationIndex), $0)
        })
        var representationIDs = Set<UUID>()
        var isRecovering = representations.count < entries.count
        var previousCoordinate: ManifestCoordinate?

        for representation in representations {
            let coordinate = ManifestCoordinate(
                itemIndex: representation.itemIndex,
                representationIndex: representation.representationIndex
            )
            guard previousCoordinate.map({ $0 < coordinate }) ?? true,
                  let entry = entriesByCoordinate[coordinate] else {
                return .corrupt
            }
            previousCoordinate = coordinate
            guard representationIDs.insert(representation.id).inserted,
                  representation.snapshotID == snapshotID,
                  entry.matchesExactly(representation) else {
                return .corrupt
            }

            switch representation.storage {
            case .portable:
                guard let bytes = representation.bytes else {
                    isRecovering = true
                    continue
                }
                guard Int64(bytes.count) == entry.byteCount,
                      ContentDigest.sha256(bytes) == entry.digest else {
                    return .corrupt
                }
            case .localReference:
                guard representation.bytes == nil else {
                    return .corrupt
                }
            }
        }

        return isRecovering ? .recovering : .complete
    }

    private var hasValidCoordinates: Bool {
        guard LocalReferencePrivacy.supports(manifestVersion: version), itemCount >= 0 else {
            return false
        }
        guard !entries.isEmpty else {
            return itemCount == 0
        }
        guard entries[0].itemIndex == 0,
              entries[0].representationIndex == 0 else {
            return false
        }

        var currentItem = 0
        var nextRepresentation = 0
        for entry in entries {
            guard entry.itemIndex >= 0,
                  entry.representationIndex >= 0,
                  entry.byteCount >= 0,
                  entry.digest.count == ContentDigest.byteCount else {
                return false
            }
            if LocalReferencePrivacy.usesOpaqueLocalDescriptor(manifestVersion: version),
               entry.storage == .localReference,
               entry.byteCount != 0 {
                return false
            }

            if entry.itemIndex == currentItem {
                guard entry.representationIndex == nextRepresentation else {
                    return false
                }
                nextRepresentation += 1
            } else if entry.itemIndex == currentItem + 1 {
                guard entry.representationIndex == 0 else {
                    return false
                }
                currentItem += 1
                nextRepresentation = 1
            } else {
                return false
            }
        }
        return currentItem + 1 == itemCount
    }
}

private extension ManifestEntry {
    func matchesExactly(_ representation: RepresentationValue) -> Bool {
        itemIndex == representation.itemIndex
            && representationIndex == representation.representationIndex
            && typeIdentifier.utf8.elementsEqual(representation.typeIdentifier.utf8)
            && storage == representation.storage
            && byteCount == representation.byteCount
            && digest == representation.digest
    }
}

private struct ManifestCoordinate: Hashable, Comparable {
    let itemIndex: Int
    let representationIndex: Int

    static func < (lhs: ManifestCoordinate, rhs: ManifestCoordinate) -> Bool {
        (lhs.itemIndex, lhs.representationIndex) < (rhs.itemIndex, rhs.representationIndex)
    }
}
