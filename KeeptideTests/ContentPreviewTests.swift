import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Keeptide

final class ContentPreviewTests: XCTestCase {
    func testExplicitMarkdownTypeRendersWithoutGuessingPlainText() async throws {
        let ref = makeRef()
        let markdown = "# Heading\n\n- [ ] Keep source"
        let service = PreviewService(read: { _ in
            return resolved(ref, type: "net.daringfireball.markdown", bytes: Data(markdown.utf8))
        })

        let rendered = try await service.preview(for: ref, kind: .other, maximumImagePixels: 200)
        guard case .markdown(let document, isTruncated: false) = rendered else {
            return XCTFail("Explicit Markdown did not produce a Markdown preview")
        }
        XCTAssertEqual(document.source, markdown)

        let plain = PreviewService(read: { _ in
            resolved(ref, type: "public.utf8-plain-text", bytes: Data(markdown.utf8))
        })
        let plainPreview = try await plain.preview(for: ref, kind: .text, maximumImagePixels: 200)
        XCTAssertEqual(plainPreview, .text(markdown, isTruncated: false))
    }

    func testMarkdownPreviewBoundsLargeSourceAndPreservesPrefix() async throws {
        let ref = makeRef()
        let source = "# Start\n" + String(repeating: "中", count: 7_000_000)
        XCTAssertGreaterThan(source.utf8.count, 20 * 1_024 * 1_024)
        let service = PreviewService(read: { _ in
            resolved(ref, type: "text/markdown", bytes: Data(source.utf8))
        })

        let rendered = try await service.preview(for: ref, kind: .text, maximumImagePixels: 200)
        guard case .markdown(let document, isTruncated: true) = rendered else {
            return XCTFail("Large Markdown did not produce a bounded preview")
        }
        XCTAssertTrue(document.source.hasPrefix("# Start\n"))
        XCTAssertLessThanOrEqual(document.source.utf8.count, QuickAccessState.previewByteLimit)
    }

    func testURLUsesStoredAddressAndTitleWithoutAResolver() async throws {
        let ref = makeRef()
        let address = "https://example.com/a/complete/path?query=值"
        let representations = [
            representation(ref, type: "public.url", bytes: Data(address.utf8), index: 0),
            representation(ref, type: "public.url-name", bytes: Data("Local title".utf8), index: 1),
        ]
        let service = PreviewService(read: { _ in
            ResolvedContent(ref: ref, integrity: .complete, representations: representations)
        })

        let preview = try await service.preview(for: ref, kind: .url, maximumImagePixels: 200)
        XCTAssertEqual(preview, .url(title: "Local title", address: address))
    }

    func testFilePreviewUsesLocalReferenceReaderWithoutPortableRead() async throws {
        let ref = makeRef()
        let reads = ReadCount()
        let reference = FilePreviewReference(
            ref: ref,
            representationID: UUID(),
            snapshotID: ref.version.rawValue,
            itemIndex: 0,
            representationIndex: 0,
            typeIdentifier: "public.file-url",
            descriptorByteCount: 0,
            descriptorDigest: Data(repeating: 7, count: 32),
            bindingSupport: .supportedFileURL,
            displayName: "fixture.txt",
            localAccess: nil
        )
        let service = PreviewService(
            read: { _ in
                await reads.increment()
                throw StoreError.notFound
            },
            fileReferences: { _ in
                return [reference]
            }
        )

        let preview = try await service.preview(for: ref, kind: .file, maximumImagePixels: 200)
        XCTAssertEqual(preview, .files([reference]))
        let readCount = await reads.value
        XCTAssertEqual(readCount, 0)
    }

    func testNonActionableContentNeverProducesTypedPreview() async throws {
        let ref = makeRef()
        let service = PreviewService(read: { _ in
            ResolvedContent(ref: ref, integrity: .recovering, representations: [])
        })

        do {
            _ = try await service.preview(for: ref, kind: .url, maximumImagePixels: 200)
            XCTFail("Recovering content produced a preview")
        } catch {
            XCTAssertEqual(error as? PasteRefusal, .contentUnavailable)
        }
    }

    func testFullPreviewIsFreshWhileCardDetailRemainsCacheable() async throws {
        let ref = makeRef()
        let reads = ReadCount()
        let service = PreviewService(read: { _ in
            let number = await reads.increment()
            return resolved(ref, type: "public.utf8-plain-text", bytes: Data("version \(number)".utf8))
        })

        let first = try await service.preview(for: ref, kind: .text, maximumImagePixels: 200)
        let second = try await service.preview(for: ref, kind: .text, maximumImagePixels: 200)
        XCTAssertEqual(first, .text("version 1", isTruncated: false))
        XCTAssertEqual(second, .text("version 2", isTruncated: false))
    }

    func testOriginalImageBudgetRejectsOverflowAndAllowsBoundary() throws {
        XCTAssertNoThrow(try OriginalImagePolicy.validate(pixelSize: CGSize(width: 8_000, height: 8_000), limit: 64_000_000))
        XCTAssertThrowsError(try OriginalImagePolicy.validate(
            pixelSize: CGSize(width: 8_001, height: 8_000),
            limit: 64_000_000
        )) { error in
            XCTAssertEqual(error as? PreviewLoadError, .originalImageTooLarge)
        }
        XCTAssertThrowsError(try OriginalImagePolicy.validate(
            pixelSize: CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            ),
            limit: 64_000_000
        ))
        XCTAssertThrowsError(try OriginalImagePolicy.validate(
            pixelSize: CGSize(width: CGFloat(Int.max), height: 1),
            limit: 64_000_000
        )) { error in
            XCTAssertEqual(error as? PreviewLoadError, .invalidImageDimensions)
        }
    }

    func testFittedImageLimitDoesNotConvertAnUnrepresentableHeaderDimension() {
        XCTAssertEqual(
            FittedImagePolicy.maximumPixels(
                sourceSize: CGSize(width: CGFloat(Int.max), height: 1),
                requested: 512
            ),
            512
        )
        XCTAssertEqual(
            FittedImagePolicy.maximumPixels(
                sourceSize: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 1),
                requested: 512
            ),
            512
        )
        XCTAssertEqual(
            FittedImagePolicy.maximumPixels(sourceSize: CGSize(width: 48, height: 32), requested: 512),
            48
        )
    }

    func testOriginalImageDecodesOnlyAfterExplicitCall() async throws {
        let ref = makeRef()
        let bytes = try png(width: 48, height: 32)
        let reads = ReadCount()
        let service = PreviewService(read: { _ in
            _ = await reads.increment()
            return resolved(ref, type: "public.png", bytes: bytes)
        })

        let fitted = try await service.preview(for: ref, kind: .image, maximumImagePixels: 12)
        guard case .image(let thumbnail, let size) = fitted else { return XCTFail("Missing fitted image") }
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 12)
        XCTAssertEqual(size, CGSize(width: 48, height: 32))
        let fittedReads = await reads.value
        XCTAssertEqual(fittedReads, 1)

        let loadedOriginal = try await service.originalImage(for: ref)
        let original = try XCTUnwrap(loadedOriginal)
        XCTAssertEqual(original.image.width, 48)
        XCTAssertEqual(original.image.height, 32)
        let originalReads = await reads.value
        XCTAssertEqual(originalReads, 2)
    }

    func testFittedPreviewBoundsAnImageWhoseStoredPayloadExceedsTwentyMiB() async throws {
        let ref = makeRef()
        let bytes = try uncompressedTIFF(width: 3_000, height: 2_400)
        XCTAssertGreaterThan(bytes.count, 20 * 1_024 * 1_024)
        let service = PreviewService(read: { _ in
            resolved(ref, type: UTType.tiff.identifier, bytes: bytes)
        })

        let preview = try await service.preview(for: ref, kind: .image, maximumImagePixels: 512)
        guard case .image(let image, let sourceSize) = preview else {
            return XCTFail("Large stored image did not produce a fitted preview")
        }
        XCTAssertEqual(sourceSize, CGSize(width: 3_000, height: 2_400))
        XCTAssertLessThanOrEqual(max(image.width, image.height), 512)
    }
}

private actor ReadCount {
    private var count = 0

    @discardableResult
    func increment() -> Int {
        count += 1
        return count
    }

    var value: Int { count }
}

private func makeRef() -> ContentRef {
    ContentRef(itemID: ItemID(), facet: .history, version: ContentVersion(), digest: Data(repeating: 1, count: 32))
}

private func resolved(_ ref: ContentRef, type: String, bytes: Data) -> ResolvedContent {
    ResolvedContent(
        ref: ref,
        integrity: .complete,
        representations: [representation(ref, type: type, bytes: bytes, index: 0)]
    )
}

private func representation(
    _ ref: ContentRef,
    type: String,
    bytes: Data,
    index: Int
) -> RepresentationValue {
    RepresentationValue(
        snapshotID: ref.version.rawValue,
        itemIndex: 0,
        representationIndex: index,
        typeIdentifier: type,
        storage: .portable,
        byteCount: Int64(bytes.count),
        digest: ContentDigest.sha256(bytes),
        bytes: bytes
    )
}

private func png(width: Int, height: Int) throws -> Data {
    let context = try XCTUnwrap(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let image = try XCTUnwrap(context.makeImage())
    let output = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
        output,
        UTType.png.identifier as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
}

private func uncompressedTIFF(width: Int, height: Int) throws -> Data {
    let context = try XCTUnwrap(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let image = try XCTUnwrap(context.makeImage())
    let output = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
        output,
        UTType.tiff.identifier as CFString,
        1,
        nil
    ))
    let properties: [CFString: Any] = [
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1],
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
}
