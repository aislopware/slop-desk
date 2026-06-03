import XCTest
@testable import RworkVideoHost
import RworkVideoProtocol

/// PURE button-balance bookkeeping. Verifies the safety auto-release decision (emit a
/// synthetic up before a down on an already-held button) WITHOUT an `InputInjector` /
/// CGEvents. This is the cross-interaction recovery for a lost/never-sent `mouseUp` that
/// would otherwise leave the target app stuck mid-selection.
final class InputButtonBalanceTests: XCTestCase {
    private let n = VideoPoint(x: 0.5, y: 0.5)
    private func down(_ b: MouseButton) -> InputEvent { .mouseDown(button: b, normalized: n, clickCount: 1, modifiers: [], tag: 0) }
    private func up(_ b: MouseButton) -> InputEvent { .mouseUp(button: b, normalized: n, clickCount: 1, modifiers: [], tag: 0) }
    private func drag(_ b: MouseButton) -> InputEvent { .mouseDrag(button: b, normalized: n, clickCount: 1, modifiers: [], tag: 0) }

    func testCleanClickNeverPreReleases() {
        var bal = InputButtonBalance()
        XCTAssertNil(bal.plan(for: down(.left)).preRelease, "first down has nothing held")
        XCTAssertTrue(bal.held.contains(.left))
        XCTAssertNil(bal.plan(for: up(.left)).preRelease)
        XCTAssertFalse(bal.held.contains(.left), "up clears the button")
    }

    func testDragSelectNeverPreReleases() {
        var bal = InputButtonBalance()
        XCTAssertNil(bal.plan(for: down(.left)).preRelease)
        for _ in 0..<5 { XCTAssertNil(bal.plan(for: drag(.left)).preRelease, "a drag never pre-releases") }
        XCTAssertNil(bal.plan(for: up(.left)).preRelease)
        XCTAssertTrue(bal.held.isEmpty)
    }

    /// The core recovery: a down → drag with the up LOST, then a fresh down. The fresh down
    /// must pre-release the still-held button so the click does not start inside a selection.
    func testLostUpThenClickPreReleases() {
        var bal = InputButtonBalance()
        _ = bal.plan(for: down(.left))
        _ = bal.plan(for: drag(.left))
        // (up never arrives — dropped on the wire / never sent by a flaky three-finger drag)
        let plan = bal.plan(for: down(.left))
        XCTAssertEqual(plan.preRelease, .left, "a down on a still-held button releases it first")
        XCTAssertTrue(bal.held.contains(.left), "the fresh down then owns the button")
    }

    func testDoubleClickDoesNotPreRelease() {
        var bal = InputButtonBalance()
        XCTAssertNil(bal.plan(for: down(.left)).preRelease)
        XCTAssertNil(bal.plan(for: up(.left)).preRelease)
        XCTAssertNil(bal.plan(for: down(.left)).preRelease, "second click is clean — the first up cleared the button")
        XCTAssertNil(bal.plan(for: up(.left)).preRelease)
    }

    func testRedundantUpIsSuppressedAfterFirst() {
        var bal = InputButtonBalance()
        _ = bal.plan(for: down(.left))
        // The client sends the up 3× for loss-resilience. The FIRST releases + posts; the
        // 2nd/3rd find nothing held → SUPPRESSED so the host posts no spurious extra *MouseUp.
        let first = bal.plan(for: up(.left))
        XCTAssertFalse(first.suppress, "first up releases the held button and is posted")
        XCTAssertNil(first.preRelease)
        XCTAssertTrue(bal.plan(for: up(.left)).suppress, "2nd duplicate up is suppressed")
        XCTAssertTrue(bal.plan(for: up(.left)).suppress, "3rd duplicate up is suppressed")
        XCTAssertTrue(bal.held.isEmpty)
    }

    func testOrphanUpWithNoDownIsSuppressed() {
        var bal = InputButtonBalance()
        // An up that arrives with no matching down (reorder / lost down) must not post a
        // stray release into the target app.
        XCTAssertTrue(bal.plan(for: up(.left)).suppress)
        XCTAssertTrue(bal.held.isEmpty)
    }

    func testDownPostFirstUpThenRedundantSuppressedDoesNotStickButton() {
        var bal = InputButtonBalance()
        _ = bal.plan(for: down(.left))
        XCTAssertFalse(bal.plan(for: up(.left)).suppress)   // released
        XCTAssertTrue(bal.plan(for: up(.left)).suppress)    // duplicate dropped
        // A fresh click after the redundant ups is clean — the button was released by the first up.
        XCTAssertNil(bal.plan(for: down(.left)).preRelease, "fresh click does not pre-release — duplicates did not leave it held")
    }

    func testMovesScrollKeysTextDoNotChangeHeld() {
        var bal = InputButtonBalance()
        _ = bal.plan(for: down(.left))
        let noop: [InputEvent] = [
            .mouseMove(normalized: n, tag: 0),
            .scroll(dx: 1, dy: 2, normalized: n, tag: 0),
            .key(keyCode: 1, down: true, modifiers: [], tag: 0),
            .text("x", tag: 0),
        ]
        for e in noop {
            XCTAssertNil(bal.plan(for: e).preRelease, "\(e) never pre-releases")
            XCTAssertEqual(bal.held, [.left], "\(e) leaves held state untouched")
        }
    }

    func testButtonsTrackedIndependently() {
        var bal = InputButtonBalance()
        _ = bal.plan(for: down(.left))
        XCTAssertNil(bal.plan(for: down(.right)).preRelease, "right is independent of a held left")
        XCTAssertEqual(bal.held, [.left, .right])
        // A right down again (right still held, e.g. lost right-up) pre-releases right only.
        XCTAssertEqual(bal.plan(for: down(.right)).preRelease, .right)
        XCTAssertNil(bal.plan(for: up(.left)).preRelease)
        XCTAssertEqual(bal.held, [.right])
    }
}
