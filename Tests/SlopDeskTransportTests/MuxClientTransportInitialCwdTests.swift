import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskTransport

final class MuxClientTransportInitialCwdTests: XCTestCase {
    /// The cwd hint rides EVERY (re)connect, not only the first. The host ignores it on a reattach (the
    /// live shell's cwd is preserved) and honors it only on a fresh respawn — where the pane's project dir
    /// is exactly what we want. Nil-ing it on reconnect (the prior behavior, pinned by the old assertion
    /// `["/Users/me/project", nil]`) made every respawned shell land in `$HOME`, losing the working
    /// directory and collapsing the cwd-derived pane/tab title to "Terminal".
    func testInitialCwdSentOnEveryConnectSoRespawnKeepsProjectDir() async throws {
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String?] = []

            func append(_ value: String?) {
                lock.lock()
                values.append(value)
                lock.unlock()
            }

            var snapshot: [String?] {
                lock.lock()
                defer { lock.unlock() }
                return values
            }
        }

        let recorder = Recorder()
        let transport = MuxClientTransport(
            acquire: { _, _, _, _, initialCwd in
                recorder.append(initialCwd)
                let dataCh = await MuxSubChannel.makeNull(channel: .data)
                let controlCh = await MuxSubChannel.makeNull(channel: .control)
                return MuxAcquisition(channelID: 1, data: dataCh, control: controlCh)
            },
            release: { _, _, _ in },
        )

        await transport.setInitialCwd("/Users/me/project")
        // First connect: a brand-new session (zero sessionID).
        try await transport.connect(
            host: "host",
            port: 1,
            resume: WireMessage.newSessionID,
            lastReceivedSeq: 0,
            handshakeTimeout: .seconds(1),
        )
        // Reconnect: a returning session (a learned, non-zero sessionID) — the hint must STILL be sent.
        try await transport.connect(
            host: "host",
            port: 1,
            resume: UUID(),
            lastReceivedSeq: 10,
            handshakeTimeout: .seconds(1),
        )

        XCTAssertEqual(recorder.snapshot, ["/Users/me/project", "/Users/me/project"])
    }
}
