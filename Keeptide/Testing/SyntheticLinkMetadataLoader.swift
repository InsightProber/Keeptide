#if DEBUG
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A stand-in for the network that a UI test session's link previews use, and only when `--fake-link-previews` asks for
/// it: each page is titled after its link's host and path, with a picture drawn here. It loads nothing.
struct SyntheticLinkMetadataLoader: LinkMetadataLoading {
    func metadata(for url: URL) async throws -> LinkPageMetadata {
        LinkPageMetadata(title: "Synthetic page at \(url.host() ?? "")\(url.path())", image: Self.picture)
    }

    /// A picture 1,200 by 630 pixels, the shape pages often give, in two bands of colour.
    private static let picture: Data? = {
        guard let context = CGContext(data: nil, width: 1_200, height: 630, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.16, green: 0.42, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 630))
        context.setFillColor(CGColor(srgbRed: 0.95, green: 0.72, blue: 0.25, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 210))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }()
}
#endif
