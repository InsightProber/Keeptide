import os
import XCTest
@testable import Keeptide

/// What every provider's source shares, where only the core itself can be held still. A stand-in answers in place of
/// the network; nothing is sent anywhere.
@MainActor
final class ProviderStreamTests: XCTestCase {
    override func setUp() async throws {
        StubService.reset()
    }

    override func tearDown() async throws {
        StubService.reset()
    }

    func testARequestStoppedWhileItIsWrittenIsNeverSent() async throws {
        let writing = OSAllocatedUnfairLock(initialState: false)
        let written = DispatchSemaphore(value: 0)
        let events = ProviderStream.events(
            from: .openAI, by: ModelClient(protocolClasses: [StubService.self]),
            sending: {
                writing.withLock { $0 = true }
                // As a large image takes a while to encode.
                _ = written.wait(timeout: .now() + 5)
                return CloudRequest(method: .post, url: URL(string: "https://api.openai.com/v1/responses")!,
                                    headers: [:], body: Data("{}".utf8))
            },
            answer: Silent(), failure: { _, _, _ in .error(.interrupted) }
        )
        let reading = Task {
            for try await _ in events {}
        }
        await waitUntil("the request is being written") { writing.withLock { $0 } }

        // As a person stops the job, which stops reading the source.
        reading.cancel()
        _ = await reading.result
        written.signal()

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(StubService.requests.isEmpty, "Nothing goes out once the generation is stopped")
    }
}

/// An answer that makes nothing of what it reads.
private struct Silent: ProviderAnswer {
    var isOver: Bool { true }
    var usage: GenerationUsage? { nil }

    mutating func read(_ event: ServerSentEvent) throws -> [GenerationEvent] { [] }
}
