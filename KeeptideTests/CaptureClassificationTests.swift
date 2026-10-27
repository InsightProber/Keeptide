import Foundation
import XCTest
@testable import Keeptide

final class CaptureClassificationTests: XCTestCase {
    func testUTF16FileURLsRemainLocalReferences() throws {
        let value = "file:///Synthetic/报告.txt"
        let littleEndian = try XCTUnwrap(value.data(using: .utf16LittleEndian))
        let bigEndian = try XCTUnwrap(value.data(using: .utf16BigEndian))
        let littleEndianWithBOM = Data([0xFF, 0xFE]) + littleEndian
        let bigEndianWithBOM = Data([0xFE, 0xFF]) + bigEndian

        for bytes in [littleEndian, bigEndian, littleEndianWithBOM, bigEndianWithBOM] {
            XCTAssertTrue(
                SystemFileReferenceClassifier.isLocalFileReference(
                    typeIdentifier: "public.url",
                    bytes: bytes
                )
            )
        }
    }

    func testOpaqueOrUndecodableURLPayloadsFailClosedToLocal() {
        let cases = [
            Data([0xFF, 0x00, 0xD8]),
            Data("not a URL".utf8),
            Data(),
        ]

        for bytes in cases {
            XCTAssertTrue(
                SystemFileReferenceClassifier.isLocalFileReference(
                    typeIdentifier: "public.url",
                    bytes: bytes
                ),
                "Accepted opaque URL payload \(bytes as NSData) as portable"
            )
        }
        XCTAssertTrue(
            SystemFileReferenceClassifier.isLocalFileReference(
                typeIdentifier: "public.url",
                bytes: nil
            )
        )
    }

    func testAliasAndBookmarkRepresentationsAreAlwaysLocal() {
        for typeIdentifier in [
            "com.apple.alias-record",
            "com.apple.alias-file",
            "com.apple.bookmark",
            "com.apple.security.bookmark",
            "public.bookmark",
        ] {
            XCTAssertTrue(
                SystemFileReferenceClassifier.isLocalFileReference(
                    typeIdentifier: typeIdentifier,
                    bytes: Data([1, 2, 3])
                ),
                "Accepted \(typeIdentifier) as portable"
            )
        }
    }

    func testNestedPropertyListFileURLIsLocal() throws {
        let bytes = try PropertyListSerialization.data(
            fromPropertyList: ["metadata": ["target": "file:///Synthetic/report.txt"]],
            format: .binary,
            options: 0
        )

        XCTAssertTrue(
            SystemFileReferenceClassifier.isLocalFileReference(
                typeIdentifier: "public.url",
                bytes: bytes
            )
        )
    }

    func testNormalWebURLsRemainPortableAcrossSupportedStringEncodings() throws {
        let value = "https://example.invalid/路径?q=1"
        let utf8 = Data(value.utf8)
        let utf16 = try XCTUnwrap(value.data(using: .utf16))

        XCTAssertFalse(SystemFileReferenceClassifier.isLocalFileReference(
            typeIdentifier: "public.url",
            bytes: utf8
        ))
        XCTAssertFalse(SystemFileReferenceClassifier.isLocalFileReference(
            typeIdentifier: "public.url",
            bytes: utf16
        ))
    }

    func testPlainTextCommandsAndPathsAreNeverReclassifiedOrRewritten() {
        let bytes = Data(#"open file:///Users/example/报告.txt && echo /tmp/result"#.utf8)
        let original = bytes

        XCTAssertFalse(SystemFileReferenceClassifier.isLocalFileReference(
            typeIdentifier: "public.utf8-plain-text",
            bytes: bytes
        ))
        XCTAssertEqual(bytes, original)
    }

    func testSafeTypeIdentifierAcceptsOnlyBoundedASCIIUTILikeCharacters() {
        XCTAssertTrue(CapturePolicy.isSafeTypeIdentifier("public.utf8-plain-text"))
        XCTAssertTrue(CapturePolicy.isSafeTypeIdentifier("dyn.a_B-9"))
        XCTAssertTrue(CapturePolicy.isSafeTypeIdentifier(String(repeating: "a", count: 255)))

        for unsafe in [
            "",
            "Apple URL pasteboard type",
            "../../private/path",
            "public.url\nsecond",
            "public.图像",
            String(repeating: "a", count: 256),
        ] {
            XCTAssertFalse(CapturePolicy.isSafeTypeIdentifier(unsafe), "Accepted unsafe type: \(unsafe)")
        }
    }
}
