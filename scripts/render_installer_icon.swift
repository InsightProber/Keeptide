#!/usr/bin/env swift

import AppKit
import Foundation

enum ExportError: Error, CustomStringConvertible {
    case usage, invalidInput, invalidOutput, render(Int)

    var description: String {
        switch self {
        case .usage: return "usage: render_installer_icon.swift <1024.png> <output.icns>"
        case .invalidInput: return "input must be a readable 1024 x 1024 PNG"
        case .invalidOutput: return "output must be a new .icns file"
        case .render(let size): return "could not render a valid \(size)-pixel icon"
        }
    }
}

let renditions: [(type: String, pixels: Int)] = [
    ("icp4", 16), ("ic11", 32), ("icp5", 32), ("ic12", 64),
    ("ic07", 128), ("ic13", 256), ("ic08", 256), ("ic14", 512),
    ("ic09", 512), ("ic10", 1024),
]

func render(_ image: NSImage, pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap), let bytes = bitmap.bitmapData else {
        throw ExportError.render(pixels)
    }
    bytes.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    context.imageInterpolation = .high
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    var visible = 0
    var low = UInt8.max
    var high = UInt8.min
    for y in 0..<pixels {
        let row = bytes.advanced(by: y * bitmap.bytesPerRow)
        for x in 0..<pixels {
            let pixel = row.advanced(by: x * 4)
            if pixel[3] > 0 {
                visible += 1
                for channel in 0..<3 {
                    low = min(low, pixel[channel])
                    high = max(high, pixel[channel])
                }
            }
        }
    }
    guard visible > pixels * pixels / 10, Int(high) - Int(low) > 16,
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw ExportError.render(pixels)
    }
    return png
}

func appendUInt32(_ value: Int, to data: inout Data) {
    var bigEndian = UInt32(value).bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

func run() throws {
    guard CommandLine.arguments.count == 3 else { throw ExportError.usage }
    let input = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let output = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
    guard output.pathExtension == "icns", !FileManager.default.fileExists(atPath: output.path)
    else { throw ExportError.invalidOutput }
    guard let sourceData = try? Data(contentsOf: input),
          let source = NSBitmapImageRep(data: sourceData),
          source.pixelsWide == 1024, source.pixelsHigh == 1024,
          let appearance = NSAppearance(named: .aqua)
    else { throw ExportError.invalidInput }
    let image = NSImage(size: NSSize(width: 1024, height: 1024))
    image.addRepresentation(source)

    var rendered: Result<[(String, Data)], Error>?
    appearance.performAsCurrentDrawingAppearance {
        rendered = Result {
            try renditions.map { rendition in
                (rendition.type, try render(image, pixels: rendition.pixels))
            }
        }
    }
    guard let rendered else { throw ExportError.invalidInput }
    let chunks = try rendered.get()
    var outputData = Data("icns".utf8)
    appendUInt32(8 + chunks.reduce(0) { $0 + 8 + $1.1.count }, to: &outputData)
    for (type, png) in chunks {
        outputData.append(Data(type.utf8))
        appendUInt32(8 + png.count, to: &outputData)
        outputData.append(png)
    }
    try outputData.write(to: output, options: .withoutOverwriting)
}

do { try run() }
catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
