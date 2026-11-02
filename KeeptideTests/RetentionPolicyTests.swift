import Foundation
import XCTest
@testable import Keeptide

final class RetentionPolicyTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60
    private let origin = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testDayPoliciesExpireFromLastCopyAtTheExactBoundary() throws {
        for days in [1, 7, 30, 90, 365, 42] {
            let policy = RetentionPolicy.days(days)
            let expiration = origin.addingTimeInterval(Double(days) * day)

            XCTAssertEqual(try policy.expirationDate(lastCopiedAt: origin), expiration)
            XCTAssertFalse(try policy.isExpired(lastCopiedAt: origin, at: expiration.addingTimeInterval(-0.001)))
            XCTAssertTrue(try policy.isExpired(lastCopiedAt: origin, at: expiration))
        }
    }

    func testPermanentNeverExpiresAndHasNoCapacityInput() throws {
        let policy = RetentionPolicy.permanent
        let farFuture = origin.addingTimeInterval(200 * 365 * day)

        XCTAssertNil(try policy.expirationDate(lastCopiedAt: origin))
        XCTAssertFalse(try policy.isExpired(lastCopiedAt: origin, at: farFuture))
    }

    func testInvalidDayCountsDatesAndOverflowAreRejected() throws {
        for days in [0, -1, Int.max] {
            XCTAssertThrowsError(try RetentionPolicy.days(days).expirationDate(lastCopiedAt: origin))
        }
        XCTAssertThrowsError(try RetentionPolicy.days(1).expirationDate(
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: .nan)
        ))
        XCTAssertThrowsError(try RetentionPolicy.days(1).isExpired(
            lastCopiedAt: origin,
            at: Date(timeIntervalSinceReferenceDate: .infinity)
        ))
        XCTAssertThrowsError(try RetentionPolicy.days(1).expirationDate(lastCopiedAt: .distantFuture))
    }

    func testPolicyCodableRoundTripAndInvalidDecodedDays() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for policy in [RetentionPolicy.days(30), .permanent] {
            XCTAssertEqual(try decoder.decode(RetentionPolicy.self, from: encoder.encode(policy)), policy)
        }

        for json in [
            #"{"kind":"days","days":0}"#,
            #"{"kind":"days","days":-7}"#,
            #"{"kind":"days"}"#,
            #"{"kind":"unknown"}"#,
        ] {
            XCTAssertThrowsError(try decoder.decode(RetentionPolicy.self, from: Data(json.utf8)), json)
        }
    }

    func testManualDeletionWindowUsesSevenDaysAndHasStrictBoundary() throws {
        let window = try DeletionWindow.manual(deletedAt: origin)
        let deadline = origin.addingTimeInterval(7 * day)

        XCTAssertEqual(window.purgeAfter, deadline)
        XCTAssertTrue(try window.canRestore(at: deadline.addingTimeInterval(-0.001)))
        XCTAssertFalse(try window.isPurgeEligible(at: deadline.addingTimeInterval(-0.001)))
        XCTAssertFalse(try window.canRestore(at: deadline))
        XCTAssertTrue(try window.isPurgeEligible(at: deadline))
    }

    func testPersistedDeletionWindowRequiresACompleteExactFinitePair() throws {
        let deadline = origin.addingTimeInterval(7 * day)
        XCTAssertNil(try DeletionWindow.validated(deletedAt: nil, purgeAfter: nil))
        XCTAssertEqual(
            try DeletionWindow.validated(deletedAt: origin, purgeAfter: deadline),
            DeletionWindow(deletedAt: origin, purgeAfter: deadline)
        )

        let invalidPairs: [(Date?, Date?)] = [
            (origin, nil),
            (nil, deadline),
            (origin, origin.addingTimeInterval(-1)),
            (origin, origin.addingTimeInterval(6 * day)),
            (Date(timeIntervalSinceReferenceDate: .nan), deadline),
            (origin, Date(timeIntervalSinceReferenceDate: .infinity)),
        ]
        for pair in invalidPairs {
            XCTAssertThrowsError(try DeletionWindow.validated(deletedAt: pair.0, purgeAfter: pair.1))
        }
    }

    func testDeletionWindowCodableRejectsCorruptedPersistedValues() throws {
        let window = try DeletionWindow.manual(deletedAt: origin)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        XCTAssertEqual(try decoder.decode(DeletionWindow.self, from: encoder.encode(window)), window)
        XCTAssertThrowsError(try decoder.decode(
            DeletionWindow.self,
            from: Data(#"{"deletedAt":1000000}"#.utf8)
        ))
        XCTAssertThrowsError(try decoder.decode(
            DeletionWindow.self,
            from: Data(#"{"deletedAt":1000000,"purgeAfter":1000001}"#.utf8)
        ))
    }

    func testHistoryRecoveryRequiresBothGraceAndNaturalRetention() throws {
        let policy = RetentionPolicy.days(1)
        let deletedAt = origin.addingTimeInterval(day / 2)
        let window = try DeletionWindow.manual(deletedAt: deletedAt)

        XCTAssertTrue(try policy.canRestoreHistory(
            lastCopiedAt: origin,
            deletedAt: window.deletedAt,
            purgeAfter: window.purgeAfter,
            at: origin.addingTimeInterval(day - 1)
        ))
        let naturallyExpired = origin.addingTimeInterval(2 * day)
        XCTAssertFalse(try policy.canRestoreHistory(
            lastCopiedAt: origin,
            deletedAt: window.deletedAt,
            purgeAfter: window.purgeAfter,
            at: naturallyExpired
        ))
        XCTAssertFalse(try window.isPurgeEligible(at: naturallyExpired), "natural expiry must not advance physical purge")
    }

    func testMemoDeletionWindowDoesNotDependOnHistoryPolicy() throws {
        let historyPolicy = RetentionPolicy.days(1)
        let memoDeletedAt = origin.addingTimeInterval(2 * day)
        let memoWindow = try DeletionWindow.manual(deletedAt: memoDeletedAt)
        let now = origin.addingTimeInterval(3 * day)

        XCTAssertTrue(try historyPolicy.isExpired(lastCopiedAt: origin, at: now))
        XCTAssertTrue(try memoWindow.canRestore(at: now))
    }

    func testHistoryRecoveryRejectsMissingDeletionStateAndThePurgeBoundary() throws {
        let policy = RetentionPolicy.permanent
        XCTAssertFalse(try policy.canRestoreHistory(
            lastCopiedAt: origin, deletedAt: nil, purgeAfter: nil, at: origin
        ))
        XCTAssertThrowsError(try policy.canRestoreHistory(
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: .nan),
            deletedAt: nil,
            purgeAfter: nil,
            at: origin
        ))

        let window = try DeletionWindow.manual(deletedAt: origin)
        XCTAssertFalse(try policy.canRestoreHistory(
            lastCopiedAt: origin,
            deletedAt: window.deletedAt,
            purgeAfter: window.purgeAfter,
            at: window.purgeAfter
        ))
        XCTAssertFalse(try window.canRestore(at: origin.addingTimeInterval(-1)))
    }
}
