import AppKit
import Foundation
import SwiftUI
import XCTest
import os
@testable import Keeptide

/// This suite instruments Foundation's registered URL-loading system. It does
/// not claim to observe unrelated providers such as WebKit or Quick Look.
@MainActor
final class PreviewNetworkTests: XCTestCase {
    func testRenderingNativeMarkdownAndURLPreviewsStartsNoInstrumentedRequest() async throws {
        let instrumentedHost = "keeptide-preview-\(UUID().uuidString.lowercased()).invalid"
        InstrumentedPreviewURLProtocol.configure(host: instrumentedHost)
        guard URLProtocol.registerClass(InstrumentedPreviewURLProtocol.self) else {
            return XCTFail("Could not register the in-process URL loading interceptor")
        }
        defer {
            URLProtocol.unregisterClass(InstrumentedPreviewURLProtocol.self)
            InstrumentedPreviewURLProtocol.configure(host: nil)
        }

        // Positive control: prove this process's registered Foundation URL-loading
        // system reaches the counter, while still completing wholly in-process.
        let controlURL = try XCTUnwrap(URL(string: "https://\(instrumentedHost)/control"))
        let (_, response) = try await URLSession.shared.data(from: controlURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
        XCTAssertEqual(InstrumentedPreviewURLProtocol.requestCount, 1)
        InstrumentedPreviewURLProtocol.resetCount()

        let markdown = MarkdownRenderer.parse("""
        # Native preview

        [A stored link](https://\(instrumentedHost)/markdown-link)

        ![An external image](https://\(instrumentedHost)/markdown-image.png)

        <img src="https://\(instrumentedHost)/html-image.png">
        """)
        let displayedURL = try XCTUnwrap(URL(string: "https://\(instrumentedHost)/stored-address"))
        let opens = PreviewOpenCounter()
        let root = VStack {
            MarkdownPreviewView(document: markdown)
            URLPreview(title: "Stored title", url: displayedURL) { url in
                opens.record(url)
            }
        }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 720)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        addTeardownBlock { window.close() }
        // The off-screen window is deliberately never ordered front.
        host.layoutSubtreeIfNeeded()

        // Force an actual AppKit/SwiftUI drawing pass without ordering a window
        // front or activating the application.
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 640,
            pixelsHigh: 720,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        await settle(host)

        XCTAssertEqual(InstrumentedPreviewURLProtocol.requestCount, 0)
        XCTAssertEqual(opens.urls, [])
    }

    /// Give SwiftUI a bounded number of main-run-loop turns. Each iteration
    /// queues its continuation on the main queue, allowing pending view work to
    /// run without blocking the actor or waiting on a network timeout.
    private func settle(_ view: NSView) async {
        for _ in 0..<8 {
            view.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

@MainActor
private final class PreviewOpenCounter {
    private(set) var urls: [URL] = []

    func record(_ url: URL) {
        urls.append(url)
    }
}

private final class InstrumentedPreviewURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State: Sendable {
        var host: String?
        var requestCount = 0
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static var requestCount: Int {
        state.withLock { $0.requestCount }
    }

    static func configure(host: String?) {
        state.withLock {
            $0.host = host
            $0.requestCount = 0
        }
    }

    static func resetCount() {
        state.withLock { $0.requestCount = 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        state.withLock { configured in
            request.url?.host == configured.host
        }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.state.withLock { $0.requestCount += 1 }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 204,
                httpVersion: "HTTP/1.1",
                headerFields: nil
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
