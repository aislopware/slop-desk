import XCTest
import Foundation
import AislopdeskProtocol
import AislopdeskTransport
@testable import AislopdeskClient

/// The client's RTT fold: a `.pong` (our monotonic timestamp echoed back) becomes an
/// EWMA-smoothed `smoothedRTTMS` and a broadcast `.rtt` event (the latency-badge datum).
final class AislopdeskClientRTTTests: XCTestCase {

    private func makeClient() -> AislopdeskClient {
        AislopdeskClient(makeTransport: {
            MuxClientTransport(
                acquire: { _, _, _, _ in throw AislopdeskTransportError.notConnected("inert") },
                release: { _, _, _ in }
            )
        })
    }

    func testPongFoldsIntoSmoothedRTT() async throws {
        let client = makeClient()
        let initial = await client.smoothedRTTMS
        XCTAssertNil(initial, "no RTT before the first pong")

        let nowMS = DispatchTime.now().uptimeNanoseconds / 1_000_000
        await client._handleInboundForTesting(.pong(timestampMS: nowMS - 40))
        let first = await client.smoothedRTTMS
        XCTAssertNotNil(first)
        XCTAssertGreaterThanOrEqual(first!, 40, "first sample seeds the EWMA directly")
        XCTAssertLessThan(first!, 500, "sample is sane (now - sentAt, same monotonic clock)")

        // Second sample pulls the EWMA by α=0.25.
        let secondNow = DispatchTime.now().uptimeNanoseconds / 1_000_000
        await client._handleInboundForTesting(.pong(timestampMS: secondNow - 200))
        let second = await client.smoothedRTTMS
        XCTAssertNotNil(second)
        XCTAssertGreaterThan(second!, first!, "a slower sample raises the smoothed value")
        XCTAssertLessThan(second!, 200, "EWMA absorbs the outlier rather than jumping to it")

        await client.close()
    }

    func testPongBroadcastsRTTEvent() async throws {
        let client = makeClient()
        // Subscribe BEFORE the fold (a broadcaster child sees events from its subscription
        // point on), then race the collector against a bounded timeout.
        let events = client.events
        let nowMS = DispatchTime.now().uptimeNanoseconds / 1_000_000
        await client._handleInboundForTesting(.pong(timestampMS: nowMS - 10))

        let sample: Double? = await withTaskGroup(of: Double?.self) { group in
            group.addTask {
                for await event in events {
                    if case let .rtt(ms) = event { return ms }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        XCTAssertNotNil(sample, "a fresh smoothed-RTT sample is broadcast as .rtt")
        XCTAssertGreaterThanOrEqual(sample ?? -1, 10)

        await client.close()
    }

    func testFutureTimestampIsIgnored() async throws {
        let client = makeClient()
        let futureMS = DispatchTime.now().uptimeNanoseconds / 1_000_000 + 60_000
        await client._handleInboundForTesting(.pong(timestampMS: futureMS))
        let rtt = await client.smoothedRTTMS
        XCTAssertNil(rtt, "a nonsensical (future) echo is dropped, never a negative sample")
        await client.close()
    }
}
