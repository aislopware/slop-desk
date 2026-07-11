import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskVideoHost

#if os(macOS)
/// Reconnect must NOT reset the button/modifier balance (the stuck-drag/stuck-⌘ fix).
///
/// A transparent auto-reconnect (SCStream death, wifi flap → bye → fresh hello) rebuilds the
/// `InputInjector` in `startLiveComponents` while the user may still be PHYSICALLY holding a
/// drag or a modifier. A rebuilt injector with a FRESH empty ``InputButtonBalance`` classifies
/// the user's eventual mouseUp/keyUp as an orphan → `Plan(suppress: true)` → the terminating
/// CGEvent is never posted → the host OS stays stuck in drag/modifier state. The fix carries the
/// old injector's balance into the new one (`balanceSnapshot` → seeding `init(balance:)`), which
/// this suite drives through the REAL `InputInjector` seam the session actor uses.
///
/// HANG-SAFETY: only `InputInjector.init` + the balance seam are exercised — `inject(_:)` /
/// `raiseTargetWindow()` are NEVER called, so no CGEvent is posted, no AX chain runs, and no
/// SCStream/VT/Metal is touched (init just allocates a CGEventSource, harmless headless).
final class InputBalanceReconnectCarryTests: XCTestCase {
    private let n = VideoPoint(x: 0.5, y: 0.5)
    private let bounds = VideoRect(x: 0, y: 0, width: 800, height: 600)

    private func down(_ b: MouseButton) -> InputEvent {
        .mouseDown(button: b, normalized: n, clickCount: 1, modifiers: [], tag: 0)
    }

    private func up(_ b: MouseButton) -> InputEvent {
        .mouseUp(button: b, normalized: n, clickCount: 1, modifiers: [], tag: 0)
    }

    private func key(_ code: UInt16, down: Bool) -> InputEvent {
        .key(keyCode: code, down: down, modifiers: [], tag: 0)
    }

    private func makeInjector(balance: InputButtonBalance) -> InputInjector {
        InputInjector(pid: 0, windowID: 0, windowBoundsCG: bounds, balance: balance)
    }

    /// The CRITICAL repro: down in the OLD injector → transparent-reconnect rebuild → the up
    /// folded through the NEW injector's balance must POST (not suppress). The rebuild is the
    /// exact session-actor seam: snapshot the stale injector's balance, seed the replacement.
    func testRebuildCarriesHeldButtonSoPostReconnectUpPosts() {
        // The user's mouseDown reached the OLD injector (this is the balance it holds).
        var heldAtDisconnect = InputButtonBalance()
        XCTAssertNil(heldAtDisconnect.plan(for: down(.left)).preRelease)
        let old = makeInjector(balance: heldAtDisconnect)

        // Wifi flap: teardown snapshots the stale injector; the re-hello seeds the new one.
        let rebuilt = makeInjector(balance: old.balanceSnapshot)

        // The user (still physically dragging) finally releases: the up must match + post.
        var carried = rebuilt.balanceSnapshot
        let plan = carried.plan(for: up(.left))
        XCTAssertFalse(
            plan.suppress,
            "the post-reconnect mouseUp must POST — suppressing it wedges the host OS in drag state",
        )
        XCTAssertTrue(carried.held.isEmpty, "the carried up releases the held button")
    }

    /// Same carry for a physically-held MODIFIER (a stuck ⌘ corrupts all subsequent input).
    func testRebuildCarriesHeldModifierSoPostReconnectKeyUpPosts() {
        var heldAtDisconnect = InputButtonBalance()
        XCTAssertFalse(heldAtDisconnect.plan(for: key(55, down: true)).suppress) // ⌘ down posted
        let old = makeInjector(balance: heldAtDisconnect)

        let rebuilt = makeInjector(balance: old.balanceSnapshot)

        var carried = rebuilt.balanceSnapshot
        XCTAssertFalse(
            carried.plan(for: key(55, down: false)).suppress,
            "the post-reconnect ⌘ up must POST — suppressing it latches the modifier host-side",
        )
    }

    /// Deliberate session END keeps today's behaviour: a NEW session with no predecessor seeds
    /// an EMPTY balance (the default), so nothing changes for a genuinely fresh client.
    func testDefaultInitStartsWithEmptyBalance() {
        let fresh = InputInjector(pid: 0, windowID: 0, windowBoundsCG: bounds)
        XCTAssertEqual(fresh.balanceSnapshot, InputButtonBalance())
    }

    /// The carried state must keep the OTHER half of the safety contract intact: a fresh down on
    /// a still-carried (stuck) button pre-releases it first, exactly as an uninterrupted session would.
    func testCarriedBalanceStillPreReleasesOnFreshDown() {
        var heldAtDisconnect = InputButtonBalance()
        _ = heldAtDisconnect.plan(for: down(.left))
        let rebuilt = makeInjector(balance: makeInjector(balance: heldAtDisconnect).balanceSnapshot)

        var carried = rebuilt.balanceSnapshot
        XCTAssertEqual(
            carried.plan(for: down(.left)).preRelease, .left,
            "a fresh down on a carried held button still emits the synthetic release first",
        )
    }
}
#endif
