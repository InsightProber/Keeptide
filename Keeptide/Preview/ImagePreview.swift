import CoreGraphics
import SwiftUI

enum ImagePreviewScaleMode: String, CaseIterable, Identifiable {
    case fit
    case actualSize

    var id: Self { self }
}

enum ImagePreviewMetrics {
    static func actualPointSize(decodedPixelSize: CGSize, displayScale: CGFloat) -> CGSize {
        let scale = displayScale.isFinite && displayScale > 0 ? displayScale : 1
        return CGSize(
            width: validDimension(decodedPixelSize.width) / scale,
            height: validDimension(decodedPixelSize.height) / scale
        )
    }

    static func isDownsampled(decodedPixelSize: CGSize, sourcePixelSize: CGSize) -> Bool {
        decodedPixelSize.width.rounded() < sourcePixelSize.width.rounded()
            || decodedPixelSize.height.rounded() < sourcePixelSize.height.rounded()
    }

    static func resolutionDescription(decodedPixelSize: CGSize, sourcePixelSize: CGSize) -> String {
        let decoded = dimensions(decodedPixelSize)
        guard isDownsampled(decodedPixelSize: decodedPixelSize, sourcePixelSize: sourcePixelSize) else {
            return "Preview resolution: \(decoded) pixels"
        }
        return "Scaled preview: \(decoded) pixels; source reports \(dimensions(sourcePixelSize)) pixels"
    }

    private static func dimensions(_ size: CGSize) -> String {
        "\(integerDimension(size.width)) × \(integerDimension(size.height))"
    }

    private static func validDimension(_ value: CGFloat) -> CGFloat {
        value.isFinite && value > 0 ? value : 0
    }

    private static func integerDimension(_ value: CGFloat) -> Int {
        let bounded = min(validDimension(value).rounded(), CGFloat(Int32.max))
        return Int(bounded)
    }
}

struct ImagePreview: View {
    let image: CGImage
    let pixelSize: CGSize
    var accessibilityLabel = "Image preview"
    var isLoadingOriginal = false
    var onRequestOriginal: (() -> Void)? = nil

    @Environment(\.displayScale) private var displayScale
    @State private var scaleMode: ImagePreviewScaleMode = .fit

    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $scaleMode) {
                Text(verbatim: "Fit").tag(ImagePreviewScaleMode.fit)
                Text(verbatim: "Actual Size").tag(ImagePreviewScaleMode.actualSize)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityLabel(Text(verbatim: "Image scale"))

            Group {
                switch scaleMode {
                case .fit:
                    Image(image, scale: 1, label: Text(verbatim: resolvedAccessibilityLabel))
                        .resizable()
                        .aspectRatio(validAspectRatio, contentMode: .fit)
                        .padding()
                case .actualSize:
                    ScrollView([.horizontal, .vertical]) {
                        Image(image, scale: effectiveDisplayScale, label: Text(verbatim: resolvedAccessibilityLabel))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(verbatim: resolutionDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if isDownsampled, let onRequestOriginal {
                Button {
                    onRequestOriginal()
                } label: {
                    if isLoadingOriginal {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(verbatim: "Load Original")
                    }
                }
                .disabled(isLoadingOriginal)
                .accessibilityLabel(Text(verbatim: isLoadingOriginal ? "Loading original image" : "Load original image"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var decodedPixelSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }

    private var isDownsampled: Bool {
        ImagePreviewMetrics.isDownsampled(
            decodedPixelSize: decodedPixelSize,
            sourcePixelSize: pixelSize
        )
    }

    private var resolutionDescription: String {
        ImagePreviewMetrics.resolutionDescription(
            decodedPixelSize: decodedPixelSize,
            sourcePixelSize: pixelSize
        )
    }

    private var resolvedAccessibilityLabel: String {
        "\(accessibilityLabel). \(resolutionDescription)"
    }

    private var effectiveDisplayScale: CGFloat {
        displayScale.isFinite && displayScale > 0 ? displayScale : 1
    }

    private var validAspectRatio: CGFloat? {
        guard pixelSize.width.isFinite,
              pixelSize.height.isFinite,
              pixelSize.width > 0,
              pixelSize.height > 0 else { return nil }
        return pixelSize.width / pixelSize.height
    }
}
