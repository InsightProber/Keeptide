import Foundation

enum RetentionPolicy: Codable, Equatable, Sendable {
    case days(Int)
    case permanent

    func expirationDate(lastCopiedAt: Date) throws -> Date? {
        try validateFinite(lastCopiedAt)
        switch self {
        case .permanent:
            return nil
        case .days(let count):
            guard count > 0 else { throw RetentionPolicyError.invalidDayCount }
            let interval = Double(count) * RetentionPolicyConstants.day
            guard interval.isFinite else { throw RetentionPolicyError.dateOverflow }
            return try adding(interval, to: lastCopiedAt)
        }
    }

    func isExpired(lastCopiedAt: Date, at now: Date) throws -> Bool {
        try validateFinite(now)
        guard let expiration = try expirationDate(lastCopiedAt: lastCopiedAt) else { return false }
        return now >= expiration
    }

    func canRestoreHistory(
        lastCopiedAt: Date,
        deletedAt: Date?,
        purgeAfter: Date?,
        at now: Date
    ) throws -> Bool {
        try validateFinite(lastCopiedAt)
        try validateFinite(now)
        guard let window = try DeletionWindow.validated(deletedAt: deletedAt, purgeAfter: purgeAfter) else {
            return false
        }
        guard try window.canRestore(at: now) else { return false }
        return try !isExpired(lastCopiedAt: lastCopiedAt, at: now)
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case days
    }

    private enum Kind: String, Codable {
        case days
        case permanent
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .permanent:
            self = .permanent
        case .days:
            let count = try values.decode(Int.self, forKey: .days)
            guard count > 0 else { throw RetentionPolicyError.invalidDayCount }
            self = .days(count)
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .permanent:
            try values.encode(Kind.permanent, forKey: .kind)
        case .days(let count):
            guard count > 0 else { throw RetentionPolicyError.invalidDayCount }
            try values.encode(Kind.days, forKey: .kind)
            try values.encode(count, forKey: .days)
        }
    }
}

struct DeletionWindow: Codable, Equatable, Sendable {
    static let duration: TimeInterval = 7 * 24 * 60 * 60

    var deletedAt: Date
    var purgeAfter: Date

    init(deletedAt: Date, purgeAfter: Date) {
        self.deletedAt = deletedAt
        self.purgeAfter = purgeAfter
    }

    static func manual(deletedAt: Date) throws -> DeletionWindow {
        try validateFinite(deletedAt)
        return DeletionWindow(
            deletedAt: deletedAt,
            purgeAfter: try adding(duration, to: deletedAt)
        )
    }

    static func validated(deletedAt: Date?, purgeAfter: Date?) throws -> DeletionWindow? {
        switch (deletedAt, purgeAfter) {
        case (nil, nil):
            return nil
        case (.some(let deletedAt), .some(let purgeAfter)):
            let window = DeletionWindow(deletedAt: deletedAt, purgeAfter: purgeAfter)
            try window.validate()
            return window
        default:
            throw RetentionPolicyError.incompleteDeletionWindow
        }
    }

    func canRestore(at now: Date) throws -> Bool {
        try validate()
        try validateFinite(now)
        return now >= deletedAt && now < purgeAfter
    }

    func isPurgeEligible(at now: Date) throws -> Bool {
        try validate()
        try validateFinite(now)
        return now >= purgeAfter
    }

    private func validate() throws {
        try validateFinite(deletedAt)
        try validateFinite(purgeAfter)
        guard purgeAfter.timeIntervalSince(deletedAt) == Self.duration else {
            throw RetentionPolicyError.invalidDeletionWindow
        }
    }

    private enum CodingKeys: String, CodingKey {
        case deletedAt
        case purgeAfter
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let deletedAt = try values.decode(Date.self, forKey: .deletedAt)
        let purgeAfter = try values.decode(Date.self, forKey: .purgeAfter)
        self.init(deletedAt: deletedAt, purgeAfter: purgeAfter)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(deletedAt, forKey: .deletedAt)
        try values.encode(purgeAfter, forKey: .purgeAfter)
    }
}

enum RetentionPolicyError: Error, Equatable {
    case invalidDayCount
    case invalidDate
    case dateOverflow
    case incompleteDeletionWindow
    case invalidDeletionWindow
}

private enum RetentionPolicyConstants {
    static let day: TimeInterval = 24 * 60 * 60
}

private func validateFinite(_ date: Date) throws {
    guard date.timeIntervalSinceReferenceDate.isFinite else {
        throw RetentionPolicyError.invalidDate
    }
}

private func adding(_ interval: TimeInterval, to date: Date) throws -> Date {
    let result = date.addingTimeInterval(interval)
    let timestamp = result.timeIntervalSinceReferenceDate
    guard timestamp.isFinite,
          result >= Date.distantPast,
          result <= Date.distantFuture else {
        throw RetentionPolicyError.dateOverflow
    }
    return result
}
