import XCTest
import RworkProtocol
@testable import RworkTransport

/// Socket-free tests for ``HostSessionTransport`` lifecycle additions from the WF-3
/// review: `close()` (orphaned-session teardown) and recorded-exit replay on resume.
final class HostSessionTransportTests: XCTestCase {

    /// `close()` must finish the inbound relay streams so their consumers (the WF-3 relay
    /// tasks) terminate instead of hanging. Without the `finish()` calls a dropped
    /// orphaned session would leave the input/resize/ack/drain consumers parked forever.
    func testCloseFinishesInboundStreams() async throws {
        let session = HostSessionTransport(sessionID: UUID())

        // Park a consumer on each inbound stream; each loop must END when close() finishes.
        let input = Task { for await _ in session.inboundInput {}; return true }
        let resize = Task { for await _ in session.inboundResize {}; return true }
        let ack = Task { for await _ in session.inboundAck {}; return true }
        let drain = Task { for await _ in session.drainPauses {}; return true }

        await session.close()

        // All four must complete (bounded by the test timeout, not hang).
        _ = await input.value
        _ = await resize.value
        _ = await ack.value
        _ = await drain.value
    }

    /// `sendExit` records the code; a subsequent `resume(after:)` re-sends it after the
    /// replayed output tail. With no channel ever bound here, we assert the recording
    /// survives and is observable through the resume path indirectly: re-binding via a
    /// loopback channel is covered end-to-end in `HandshakeReconnectTests`; here we just
    /// confirm `sendExit` does not throw when no channel is bound (it must record, not
    /// require a live channel) so a child exiting while offline is captured.
    func testSendExitWithoutChannelRecordsInsteadOfThrowing() async throws {
        let session = HostSessionTransport(sessionID: UUID())
        await session.setClientOnline(false)
        _ = try await session.sendOutput(Data("tail".utf8))
        // No data channel is bound (client offline). sendExit must record the code, not
        // throw — otherwise the exit would be lost on the common offline-exit path.
        do {
            try await session.sendExit(code: 137)
        } catch {
            XCTFail("sendExit with no bound channel must record (not throw): \(error)")
        }
    }
}
