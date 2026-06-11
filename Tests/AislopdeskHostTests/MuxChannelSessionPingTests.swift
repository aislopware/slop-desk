import XCTest
import Foundation
import AislopdeskProtocol
@testable import AislopdeskTransport
@testable import AislopdeskHost

/// The host's stateless RTT responder: a `.ping(ts)` arriving on the CONTROL sub-channel
/// is answered with `.pong(ts)` (timestamp echoed VERBATIM) via the control sender — and
/// it must NOT flush the resize micro-debounce (a periodic probe would otherwise defeat
/// the latest-wins window every 3 s).
final class MuxChannelSessionPingTests: XCTestCase {

    func testPingIsAnsweredWithEchoedPong() async throws {
        final class FrameRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var decoder = FrameDecoder()
            private(set) var messages: [WireMessage] = []
            func ingest(_ inner: Data) {
                lock.lock(); defer { lock.unlock() }
                decoder.append(inner)
                while let m = (try? decoder.nextMessage()) ?? nil { messages.append(m) }
            }
            var all: [WireMessage] { lock.lock(); defer { lock.unlock() }; return messages }
        }
        let recorder = FrameRecorder()
        let data = MuxSubChannel(channelID: 9, channel: .data) { _, _ in }
        // Public init arms a (data-sized) send window — irrelevant here: a pong is tiny and
        // the stub muxSend never withholds credit-relevant sends.
        let control = MuxSubChannel(channelID: 9, channel: .control) { _, inner in
            recorder.ingest(inner)
        }
        let session = MuxChannelSession(
            channelID: 9,
            pty: PTYProcess(),   // unspawned: the read loop EOFs immediately; harmless
            data: data,
            control: control
        )
        session.startRelay()

        // Deliver a ping ON the control sub-channel exactly as the demux would.
        let ts: UInt64 = 1_749_700_000_123
        await control.deliver(payload: WireMessage.ping(timestampMS: ts).encode())

        // The control task answers via the control sender (async) — poll briefly.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if recorder.all.contains(.pong(timestampMS: ts)) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(recorder.all.contains(.pong(timestampMS: ts)),
                      "the host answers ping with a pong echoing the client's timestamp verbatim")

        session.shutdownDetached()
    }
}
