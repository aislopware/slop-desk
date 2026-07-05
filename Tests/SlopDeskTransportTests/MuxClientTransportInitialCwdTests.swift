import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskTransport

final class MuxClientTransportInitialCwdTests: XCTestCase {
    func testInitialCwdSentOnlyForFreshSession() async throws {
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
        try await transport.connect(
            host: "host",
            port: 1,
            resume: WireMessage.newSessionID,
            lastReceivedSeq: 0,
            handshakeTimeout: .seconds(1),
        )
        try await transport.connect(
            host: "host",
            port: 1,
            resume: UUID(),
            lastReceivedSeq: 10,
            handshakeTimeout: .seconds(1),
        )

        XCTAssertEqual(recorder.snapshot, ["/Users/me/project", nil])
    }
}
