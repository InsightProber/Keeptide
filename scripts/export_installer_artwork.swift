#!/usr/bin/env swift
// Run from the repository root after exporting the macOS Default icon at 1024 px
// from Icon Composer: swift scripts/export_installer_artwork.swift <export.png>
import AppKit
import CryptoKit
import Foundation

let resources = URL(fileURLWithPath: "Keeptide/Resources", isDirectory: true)
let sourceFiles = [
    "Keeptide/Resources/AppIcon.icon/icon.json",
    "Keeptide/Resources/AppIcon.icon/Assets/Retained Page.svg",
    "Keeptide/Resources/AppIcon.icon/Assets/Tide.svg",
]
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
guard CommandLine.arguments.count == 2 else { fail("Provide an Icon Composer PNG export.") }
let input = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let output = resources.appendingPathComponent("InstallerIcon.png").standardizedFileURL
guard input.resolvingSymlinksInPath() != output.resolvingSymlinksInPath()
else { fail("Input must be an original Icon Composer export, not the existing installer artwork.") }
guard let image = NSImage(contentsOf: input),
      image.representations.contains(where: { $0.pixelsWide == 1024 && $0.pixelsHigh == 1024 })
else { fail("Provide a 1024 × 1024 macOS Default PNG exported by Icon Composer.") }

guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
else { fail("Could not create the installer artwork bitmap.") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.cgContext.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))
context.imageInterpolation = .high
// Icon Composer exports the mask edge-to-edge; legacy macOS icons need padding.
image.draw(in: NSRect(x: 100, y: 100, width: 824, height: 824))
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:])
else { fail("Could not encode the installer artwork.") }

do {
    // Read every source before replacing any output.
    var hashes: [String: String] = [:]
    for path in sourceFiles {
        hashes[path] = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))
            .map { String(format: "%02x", $0) }.joined()
    }
    hashes["Keeptide/Resources/InstallerIcon.png"] = SHA256.hash(data: png)
        .map { String(format: "%02x", $0) }.joined()
    let manifest: [String: Any] = ["schemaVersion": 1, "files": hashes]
    let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try png.write(to: output, options: .atomic)
    try (json + Data([0x0A])).write(to: resources.appendingPathComponent("InstallerIcon.source.json"), options: .atomic)
    print("Updated installer artwork and source fingerprints.")
} catch { fail("Could not export installer artwork: \(error)") }
