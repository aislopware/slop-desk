#if os(macOS)
import XCTest
@testable import SlopDeskVideoHost

/// Pins the pure frontmost rule ``HostFrontmostApp/frontmostOwnerPID(in:)`` — the z-order scan
/// behind the daemon-safe frontmost read (the WindowServer list is front-to-back; the first
/// normal-level visible window's owner is the frontmost app). No WindowServer here: the CG
/// query itself is a thin adapter, headless `swift test` must never need an Aqua session.
final class HostFrontmostAppTests: XCTestCase {
    private func window(layer: Int? = 0, pid: pid_t? = 100, alpha: Double? = 1) -> HostFrontmostApp.WindowRecord {
        HostFrontmostApp.WindowRecord(layer: layer, ownerPID: pid, alpha: alpha)
    }

    func testFirstNormalLevelVisibleWindowWins() {
        // Front-to-back: a menubar-level overlay (layer 25), then Chrome, then Finder — the
        // overlay never counts, Chrome is frontmost.
        let pid = HostFrontmostApp.frontmostOwnerPID(in: [
            window(layer: 25, pid: 50),
            window(pid: 200),
            window(pid: 300),
        ])
        XCTAssertEqual(pid, 200)
    }

    func testTransparentAndMalformedRecordsNeverElect() {
        // A fully transparent layer-0 window (alpha 0) and records missing any field are
        // skipped — validate-then-drop, a malformed record must not become "the frontmost app".
        let pid = HostFrontmostApp.frontmostOwnerPID(in: [
            window(alpha: 0),
            window(layer: nil),
            window(pid: nil),
            window(alpha: nil),
            window(pid: 0),
            window(pid: 400, alpha: 0.4),
        ])
        XCTAssertEqual(pid, 400)
    }

    func testNoQualifyingWindowIsNil() {
        XCTAssertNil(HostFrontmostApp.frontmostOwnerPID(in: []))
        XCTAssertNil(HostFrontmostApp.frontmostOwnerPID(in: [window(layer: 8), window(alpha: 0)]))
    }
}
#endif
