import AppKit
import XCTest
@testable import Keeptide

final class CapturePolicyTests: XCTestCase {
    func testExcludedSourceIsRejectedWithoutTreatingTheObservationAsAuthenticated() {
        let observedSource = "com.example.Editor"

        XCTAssertEqual(
            CapturePolicy.decision(
                typeIdentifiers: [NSPasteboard.PasteboardType.string.rawValue],
                sourceApp: observedSource,
                excludedSourceApps: [observedSource]
            ),
            .skip(.excludedSource)
        )
        XCTAssertEqual(
            CapturePolicy.decision(
                typeIdentifiers: [NSPasteboard.PasteboardType.string.rawValue],
                sourceApp: "com.example.ImpersonatingObservation",
                excludedSourceApps: [observedSource]
            ),
            .capture
        )
    }

    func testEveryPrivacyMarkerConventionIsRejectedCaseInsensitively() {
        for marker in CapturePolicy.privacyMarkerTypes {
            XCTAssertEqual(
                CapturePolicy.decision(
                    typeIdentifiers: [marker.uppercased()],
                    sourceApp: nil,
                    excludedSourceApps: []
                ),
                .skip(.sensitivePasteboard),
                "Allowed privacy marker \(marker)"
            )
        }
    }

    func testPrivacyScanChecksAllItemsInsteadOfOnlyTheFirst() {
        XCTAssertEqual(
            CapturePolicy.decision(
                typeIdentifiers: [
                    NSPasteboard.PasteboardType.string.rawValue,
                    CapturePolicy.transientType
                ],
                sourceApp: nil,
                excludedSourceApps: []
            ),
            .skip(.sensitivePasteboard)
        )
    }
}
