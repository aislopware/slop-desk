import SlopDeskAgentDetect
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost

/// W10 — the PURE ``ForegroundProcessDetector`` core (no real PTY / syscall / socket; the
/// `PTYForegroundProbe` OS shim is compiled + code-reviewed only). Drives the detector with an
/// INJECTED foreground-process-name source and asserts the type-26 / type-27 emit decisions,
/// the embedded state-machine transitions, and the edge/dedupe behaviour.
final class ForegroundProcessWatcherTests: XCTestCase {
    // MARK: type-26 (foregroundProcess) edge-trigger + dedupe

    func testFirstSampleEmitsForegroundProcess() {
        var d = ForegroundProcessDetector()
        let e = d.sample(name: "zsh", at: 0)
        XCTAssertEqual(e.foreground, .foregroundProcess(name: "zsh"))
    }

    func testRepeatedSameNameDoesNotReEmitType26() {
        var d = ForegroundProcessDetector()
        _ = d.sample(name: "zsh", at: 0)
        let e1 = d.sample(name: "zsh", at: 1)
        let e2 = d.sample(name: "zsh", at: 2)
        XCTAssertNil(e1.foreground, "an unchanged basename must not re-emit type 26 (dedupe)")
        XCTAssertNil(e2.foreground)
    }

    func testBasenameEdgeReEmits() {
        var d = ForegroundProcessDetector()
        _ = d.sample(name: "zsh", at: 0)
        let e = d.sample(name: "claude", at: 1)
        XCTAssertEqual(e.foreground, .foregroundProcess(name: "claude"), "a changed basename re-emits type 26")
    }

    func testPathIsReducedToBasenameOnTheWire() {
        var d = ForegroundProcessDetector()
        let e = d.sample(name: "/usr/local/bin/claude", at: 0)
        XCTAssertEqual(e.foreground, .foregroundProcess(name: "claude"), "the wire carries the basename, not the path")
    }

    /// A path and its bare basename are the SAME process → no spurious type-26 edge between them.
    func testPathThenBasenameIsNotAnEdge() {
        var d = ForegroundProcessDetector()
        _ = d.sample(name: "/usr/local/bin/claude", at: 0)
        let e = d.sample(name: "claude", at: 1)
        XCTAssertNil(e.foreground, "path → basename of the same process is not a change")
    }

    // MARK: type-27 (claudeStatus) — presence floor + transitions

    func testNonClaudeProcessIsStatusNone() {
        var d = ForegroundProcessDetector()
        let e = d.sample(name: "zsh", at: 0)
        XCTAssertEqual(d.status, .none, "a plain shell is not claude → status none")
        // First-ever status verdict (none, urgency 0) IS emitted (the anchor was nil).
        XCTAssertEqual(e.status, .claudeStatus(state: 0, kind: 0, label: ""))
    }

    func testClaudeProcessLiftsToIdleFloor() {
        var d = ForegroundProcessDetector()
        _ = d.sample(name: "zsh", at: 0) // emits none
        let e = d.sample(name: "claude", at: 1)
        XCTAssertEqual(d.status, .idle, "claude foreground lifts the presence floor to idle")
        XCTAssertEqual(e.status, .claudeStatus(state: 1, kind: 0, label: ""), "type 27 carries idle (urgency 1)")
    }

    func testClaudeGoneReturnsToNone() {
        var d = ForegroundProcessDetector()
        _ = d.sample(name: "claude", at: 0) // → idle
        let e = d.sample(name: "zsh", at: 1) // claude gone
        XCTAssertEqual(d.status, .none)
        XCTAssertEqual(e.status, .claudeStatus(state: 0, kind: 0, label: ""), "claude gone → none")
    }

    // MARK: type-27 dedupe — identical status is not re-sent

    func testIdleStatusIsNotReSentOnRepeatedClaudeSamples() {
        var d = ForegroundProcessDetector()
        _ = d.sample(name: "claude", at: 0) // → idle, emits type 27
        let e1 = d.sample(name: "claude", at: 1)
        let e2 = d.sample(name: "claude", at: 2)
        XCTAssertNil(e1.status, "an unchanged idle status must not re-emit type 27 (dedupe)")
        XCTAssertNil(e2.status)
        // And type 26 is also deduped (same basename).
        XCTAssertNil(e1.foreground)
    }

    // MARK: emission flattening / ordering

    func testEmissionMessagesAreForegroundThenStatus() {
        var d = ForegroundProcessDetector()
        let e = d.sample(name: "claude", at: 0)
        XCTAssertEqual(e.messages, [
            .foregroundProcess(name: "claude"),
            .claudeStatus(state: 1, kind: 0, label: ""),
        ], "presence floor (type 26) precedes the status (type 27)")
    }

    func testEmptyNameClearsPresence() {
        var d = ForegroundProcessDetector()
        _ = d.sample(name: "claude", at: 0) // → idle
        let e = d.sample(name: "", at: 1)
        XCTAssertEqual(d.status, .none, "an empty foreground name clears presence")
        XCTAssertEqual(e.status, .claudeStatus(state: 0, kind: 0, label: ""))
    }

    // MARK: basename helper

    func testBasenameHelper() {
        XCTAssertEqual(ForegroundProcessDetector.basename(of: "/usr/local/bin/claude"), "claude")
        XCTAssertEqual(ForegroundProcessDetector.basename(of: "zsh"), "zsh")
        XCTAssertEqual(ForegroundProcessDetector.basename(of: ""), "")
        XCTAssertEqual(ForegroundProcessDetector.basename(of: "claudefoo"), "claudefoo")
    }

    /// `claudefoo` is NOT claude (exact basename match) — guards a substring false positive.
    func testClaudefooIsNotClaude() {
        var d = ForegroundProcessDetector()
        _ = d.sample(name: "claudefoo", at: 0)
        XCTAssertEqual(d.status, .none, "claudefoo must not match claude")
    }
}
