import XCTest
import AislopdeskProtocol
@testable import AislopdeskTransport

/// Framing + per-channel-delivery tests for ``MuxSubChannel`` in isolation (no shared connection).
/// Proves the two-layer nesting: a ``WireMessage`` sent on a sub-channel is `msg.encode()`-framed
/// and handed to `muxSend` as the OPAQUE body of a `.channelData` envelope; and that an inbound
/// payload fed to ``MuxSubChannel/deliver(payload:)`` reassembles whole inner ``WireMessage``s
/// (including a frame split across two payloads).
final class MuxSubChannelTests: XCTestCase {

    func testSendFramesInnerWireMessageAndStampsChannelID() async throws {
        let captured = Captured()
        let channel = MuxSubChannel(channelID: 7, channel: .data) { id, inner in
            captured.record(id: id, inner: inner)
        }
        let original = WireMessage.input(Data("ls -la\n".utf8))
        try await channel.send(original)

        let (id, inner) = captured.value
        XCTAssertEqual(id, 7, "the sub-channel stamps its own channelID on the send")
        // `inner` is the framed WireMessage — decoding it back must yield the original message.
        var decoder = FrameDecoder()
        decoder.append(inner)
        XCTAssertEqual(try decoder.nextMessage(), original, "inner bytes are the opaque framed WireMessage")
    }

    func testDeliverReassemblesSplitInnerFrame() async throws {
        let channel = MuxSubChannel(channelID: 1, channel: .data) { _, _ in }
        let message = WireMessage.output(seq: 5, bytes: Data("vt payload ✅".utf8))
        let frame = message.encode()

        // Feed the inner frame in TWO partial payloads (TCP coalescing/splitting is transparent).
        let mid = frame.count / 2
        let head = frame.prefix(mid)
        let tail = frame.suffix(from: frame.startIndex + mid)

        let collector = Task { () -> WireMessage? in
            for try await m in channel.inbound { return m }
            return nil
        }
        await channel.deliver(payload: Data(head))
        await channel.deliver(payload: Data(tail))

        let received = try await collector.value
        XCTAssertEqual(received, message, "a frame split across two deliveries reassembles to the original")
    }

    func testFinishEndsInboundCleanly() async throws {
        let channel = MuxSubChannel(channelID: 1, channel: .data) { _, _ in }
        let collector = Task { () -> Int in
            var n = 0
            for try await _ in channel.inbound { n += 1 }
            return n
        }
        await channel.finish()
        let count = try await collector.value
        XCTAssertEqual(count, 0, "finish() ends the inbound stream with no further messages")
    }
}

/// Captures the (channelID, inner) the sub-channel's `muxSend` was called with.
private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var id: UInt32 = 0
    private var inner = Data()
    func record(id: UInt32, inner: Data) {
        lock.lock(); self.id = id; self.inner = inner; lock.unlock()
    }
    var value: (UInt32, Data) { lock.lock(); defer { lock.unlock() }; return (id, inner) }
}
