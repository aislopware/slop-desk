import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import XCTest
@testable import SlopDeskClient

/// WB2 — the client-side decode of the Warp-style "Blocks" wire messages: a host→client `commandBlock`
/// (type 28) becomes a `.commandBlock` Event and a `blockOutput` (type 29) becomes a `.blockOutput`
/// Event, and the outbound `requestBlockOutput` (type 15) reaches the transport.
final class SlopDeskClientBlocksTests: XCTestCase {
    private func makeClient(_ transport: RecordingBlockTransport) -> SlopDeskClient {
        SlopDeskClient(makeTransport: { transport })
    }

    func testType28DecodesToCommandBlockEvent() async {
        let client = makeClient(RecordingBlockTransport())
        let events = client.events
        await client.handleInboundForTesting(.commandBlock(
            index: 7, exitCode: 0, durationMS: 1250, complete: true, outputLen: 42, commandText: "ls -la",
            promptOrdinal: 9,
        ))
        let event: SlopDeskClient.Event? = await withTaskGroup(of: SlopDeskClient.Event?.self) { group in
            group.addTask {
                for await e in events { if case .commandBlock = e { return e } }
                return nil
            }
            group.addTask { try? await Task.sleep(for: .seconds(2))
                return nil
            }
            // swiftlint:disable:next redundant_nil_coalescing
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard case let .commandBlock(index, exitCode, durationMS, complete, outputLen, commandText, ordinal) = event
        else {
            XCTFail("type 28 should surface a .commandBlock event")
            await client.close()
            return
        }
        XCTAssertEqual(index, 7)
        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(durationMS, 1250)
        XCTAssertTrue(complete)
        XCTAssertEqual(outputLen, 42)
        XCTAssertEqual(commandText, "ls -la")
        XCTAssertEqual(ordinal, 9, "the prompt ordinal must survive the wire → Event surface verbatim")
        await client.close()
    }

    func testType29DecodesToBlockOutputEvent() async {
        let client = makeClient(RecordingBlockTransport())
        let events = client.events
        let payload = Data("total 0\n".utf8)
        await client.handleInboundForTesting(.blockOutput(index: 3, output: payload))
        let event: SlopDeskClient.Event? = await withTaskGroup(of: SlopDeskClient.Event?.self) { group in
            group.addTask {
                for await e in events { if case .blockOutput = e { return e } }
                return nil
            }
            group.addTask { try? await Task.sleep(for: .seconds(2))
                return nil
            }
            // swiftlint:disable:next redundant_nil_coalescing
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard case let .blockOutput(index, output) = event else {
            XCTFail("type 29 should surface a .blockOutput event")
            await client.close()
            return
        }
        XCTAssertEqual(index, 3)
        XCTAssertEqual(output, payload)
        await client.close()
    }

    func testEmptyType29SurfacesEmptyBlockOutput() async {
        // An evicted/unknown block → empty output. The client must surface it (so the UI resolves the
        // pending request as "unavailable"); it must NOT drop or hang.
        let client = makeClient(RecordingBlockTransport())
        let events = client.events
        await client.handleInboundForTesting(.blockOutput(index: 99, output: Data()))
        let isEmpty: Bool? = await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                for await e in events { if case let .blockOutput(_, output) = e { return output.isEmpty } }
                return nil
            }
            group.addTask { try? await Task.sleep(for: .seconds(2))
                return nil
            }
            // swiftlint:disable:next redundant_nil_coalescing
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        XCTAssertEqual(isEmpty, true, "an empty type-29 surfaces an empty .blockOutput (the UI handles eviction)")
        await client.close()
    }

    func testRequestBlockOutputReachesTransport() async throws {
        let transport = RecordingBlockTransport()
        let client = makeClient(transport)
        try await client.connect(host: "h", port: 1)
        try await client.requestBlockOutput(index: 5)
        // Give the (synchronous-conformer) transport a beat — the call awaits the actor directly here.
        let requested = await transport.requestedIndices
        XCTAssertEqual(requested, [5], "requestBlockOutput(5) sends a single type-15 request to the transport")
        await client.close()
    }

    func testRequestBlockOutputBeforeConnectThrows() async {
        let client = makeClient(RecordingBlockTransport())
        do {
            try await client.requestBlockOutput(index: 1)
            XCTFail("requestBlockOutput before connect must throw, never silently no-op")
        } catch {
            // expected — invalidState
        }
        await client.close()
    }

    // MARK: - Recording transport (captures requestBlockOutput, drives inbound)

    private actor RecordingBlockTransport: ClientTransporting {
        private var _sessionID: UUID?
        var sessionID: UUID? { _sessionID }
        var resumeFromSeq: Int64 { 0 }
        var returningClient: Bool { false }
        private(set) var requestedIndices: [UInt32] = []

        private let continuation: AsyncThrowingStream<WireMessage, Error>.Continuation
        nonisolated let inbound: AsyncThrowingStream<WireMessage, Error>

        init() {
            var c: AsyncThrowingStream<WireMessage, Error>.Continuation!
            inbound = AsyncThrowingStream { c = $0 }
            continuation = c
        }

        func connect(
            host _: String,
            port _: UInt16,
            resume _: UUID,
            lastReceivedSeq _: Int64,
            handshakeTimeout _: Duration,
        ) {
            _sessionID = UUID()
        }

        func sendInput(_: Data) {}
        func sendResize(cols _: UInt16, rows _: UInt16, pxWidth _: UInt16, pxHeight _: UInt16) {}
        func sendAck(seq _: Int64) {}
        func sendBye() {}
        func sendRequestBlockOutput(index: UInt32) { requestedIndices.append(index) }
        func close() { continuation.finish() }
    }
}
