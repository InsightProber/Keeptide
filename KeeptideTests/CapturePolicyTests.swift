import AppKit
import XCTest
@testable import Keeptide

final class CapturePolicyTests: XCTestCase {
    func testRecordingMustBeEnabled() {
        XCTAssertEqual(
            CapturePolicy.decision(
                typeIdentifiers: [NSPasteboard.PasteboardType.string.rawValue],
                sourceApp: "com.example.Editor",
                isCaptureEnabled: false,
                isPaused: false,
                excludedSourceApps: []
            ),
            .skip(.recordingDisabled)
        )
    }

    func testPausedCaptureIsRejectedBeforeSourceAndTypeChecks() {
        XCTAssertEqual(
            CapturePolicy.decision(
                typeIdentifiers: [CapturePolicy.concealedType],
                sourceApp: "com.example.Secret",
                isCaptureEnabled: true,
                isPaused: true,
                excludedSourceApps: ["com.example.Secret"]
            ),
            .skip(.paused)
        )
    }

    func testExcludedSourceIsRejectedWithoutTreatingTheObservationAsAuthenticated() {
        let observedSource = "com.example.Editor"

        XCTAssertEqual(
            CapturePolicy.decision(
                typeIdentifiers: [NSPasteboard.PasteboardType.string.rawValue],
                sourceApp: observedSource,
                isCaptureEnabled: true,
                isPaused: false,
                excludedSourceApps: [observedSource]
            ),
            .skip(.excludedSource)
        )
        XCTAssertEqual(
            CapturePolicy.decision(
                typeIdentifiers: [NSPasteboard.PasteboardType.string.rawValue],
                sourceApp: "com.example.ImpersonatingObservation",
                isCaptureEnabled: true,
                isPaused: false,
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
                    isCaptureEnabled: true,
                    isPaused: false,
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
                isCaptureEnabled: true,
                isPaused: false,
                excludedSourceApps: []
            ),
            .skip(.sensitivePasteboard)
        )
    }
}
