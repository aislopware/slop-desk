import Foundation
import SlopDeskTransport
import XCTest
@testable import SlopDeskHost

/// Periodic disk-scrollback sweep (audit `scrollback-journal-sweep-once-at-startup`, high):
/// `ScrollbackJournalStore.sweep()` — the maxAge/keepNewest bound on orphaned `<uuid>.scrollback`
/// files — used to run exactly ONCE, in a `Task.detached` at `HostServer.init`. hostd is a
/// week/month-long daemon: orphans from link-drop detaches and TTL evictions accumulated
/// unbounded past that single pass. The fix keeps re-running `sweep()` on a fixed cadence for the
/// life of the daemon and cancels the loop in `stop()` (mirrors `HostTransport`'s `reaperTask`
/// shape) so a repeated Start→Stop cycle never leaks a background loop.
///
/// All headless: no NWListener, no spawned shell — these servers never call `start()`
/// (hang-safety); the periodic task is wired at `init` regardless. The tiny injected
/// `scrollbackSweepInterval` drives the schedule pin without any wall-clock day.
final class HostServerJournalSweepTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-journal-sweep-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        defer { super.tearDown() }
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    /// Polls `condition` (up to ~2 s) so the async periodic loop gets scheduled ticks.
    private func waitUntil(_ condition: @Sendable () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// The schedule pin: over a short window with a tiny injected interval, `sweep()` must run
    /// more than once — a single init-time sweep would freeze the count at 1 forever.
    func testPeriodicSweepRunsRepeatedlyThenStopsAfterStop() async {
        let store = ScrollbackJournalStore(directory: tempDir)
        let server = HostServer(
            port: 0,
            detachEnabled: true,
            resumeOnRecovery: true,
            scrollbackJournals: store,
            scrollbackSweepInterval: .milliseconds(50),
        )

        waitUntil { store.sweepCallCountForTesting() >= 2 }
        XCTAssertGreaterThanOrEqual(
            store.sweepCallCountForTesting(), 2,
            "sweep() must keep re-running on a fixed cadence for the life of the daemon — a "
                + "single sweep at init leaves later orphans (link-drop detach, TTL eviction) "
                + "unbounded until a daemon restart",
        )

        await server.stop()
        let countAtStop = store.sweepCallCountForTesting()
        try? await Task.sleep(for: .milliseconds(200)) // several intervals' worth, were the loop still alive
        XCTAssertEqual(
            store.sweepCallCountForTesting(), countAtStop,
            "stop() must cancel the periodic sweep task — a repeated Start→Stop cycle must not "
                + "leak a background loop",
        )
    }
}
