// PaneMoveEscapeMonitorControllerTests — the BALANCE invariant behind escape-to-cancel, exercised headlessly
// through the controller's injected install/remove seams. No `NSEvent` is created and no real local monitor
// is installed: a test that installed one would attach to the TEST RUNNER's own keyDown stream and, worse,
// could not COUNT anything — and counting is the entire subject here.
//
// WHAT IS ACTUALLY AT RISK. A local `.keyDown` monitor left installed after the drag ends swallows Escape for
// the WHOLE APP — every terminal, every overlay, every sheet — with no crash, no log and nothing on screen
// that says so. The user reports "Escape stopped working" and there is not a symbol to grep for. The inverse
// (a monitor removed twice, or a token removed that was never installed) is AppKit's own undefined behaviour.
// So the contract is one remove per install, never two, never zero, across as many drags as the user makes.
//
// These are non-tautological: `isArmed` is asserted against the SEAM COUNTS, not on its own. A controller
// that installed a second monitor on the second drag frame, that forgot to remove on `disarm`, that removed a
// stale token from the previous drag, or that swallowed a key it did not cancel on, fails one of them.

#if os(macOS)
import XCTest
@testable import SlopDeskClientCore

@MainActor
final class PaneMoveEscapeMonitorControllerTests: XCTestCase {
    /// The hardware key codes the decision is made on. Escape's number is the crate's
    /// (`slopdesk_key_capture_is_escape`) and is reached through the real FFI here — a wrong number would
    /// make the cancel key unreachable while every Rust test still passed. `keyA` is any non-cancel key.
    private let keyEscape: UInt16 = 53
    private let keyA: UInt16 = 0

    /// A counting stand-in for `NSEvent.addLocalMonitorForEvents` / `removeMonitor`. It hands back a fresh
    /// class instance per install so the test can assert the token REMOVED is the token installed — the
    /// difference between a controller that balances and one that merely calls remove the right number of
    /// times. The controller retains the closures (→ the probe), so the probe outlives the local binding.
    @MainActor
    private final class Probe {
        /// One installed monitor's identity. A class, so `===` is the whole assertion.
        final class Token {}

        private(set) var installed: [Token] = []
        private(set) var removed: [Token] = []
        /// The reader the LAST install was handed — the controller's per-event decision, called directly.
        private(set) var reader: PaneMoveEscapeMonitorController.KeyReader?
        /// Makes the next install fail the way AppKit can (a `nil` monitor), so the refusal path is reachable.
        var refuseInstall = false

        var installs: Int { installed.count }
        var removes: Int { removed.count }

        func make() -> PaneMoveEscapeMonitorController {
            PaneMoveEscapeMonitorController(
                install: { reader in
                    self.reader = reader
                    guard !self.refuseInstall else { return nil }
                    let token = Token()
                    self.installed.append(token)
                    return token
                },
                remove: { token in
                    guard let token = token as? Token else {
                        XCTFail("the controller removed a token no install of ours produced")
                        return
                    }
                    self.removed.append(token)
                },
            )
        }
    }

    /// A fresh controller holds no monitor. The floor every other assertion stands on: at rest there is
    /// nothing installed to shadow Escape for the terminal.
    func testStartsDisarmed() {
        let probe = Probe()
        let controller = probe.make()
        XCTAssertFalse(controller.isArmed)
        XCTAssertEqual(probe.installs, 0)
        XCTAssertEqual(probe.removes, 0)
    }

    /// One drag = one install and one remove. The whole contract in a sentence.
    func testOneDragInstallsOnceAndRemovesOnce() {
        let probe = Probe()
        let controller = probe.make()
        controller.arm {}
        XCTAssertTrue(controller.isArmed)
        XCTAssertEqual(probe.installs, 1)
        XCTAssertEqual(probe.removes, 0)
        controller.disarm()
        XCTAssertFalse(controller.isArmed)
        XCTAssertEqual(probe.installs, 1)
        XCTAssertEqual(probe.removes, 1)
    }

    /// The SwiftUI mount calls `arm` on every drag FRAME (`updateNSView` runs per frame, and the AppKit
    /// column will re-arm on every pointer move for the same reason). Twenty frames must still be ONE
    /// monitor. FAILS on a controller that installs unconditionally — which is nineteen monitors racing for
    /// one `NSEvent` stream, and nineteen tokens with no owner left to remove them.
    func testRearmingEveryDragFrameInstallsExactlyOneMonitor() {
        let probe = Probe()
        let controller = probe.make()
        for _ in 0..<20 { controller.arm {} }
        XCTAssertEqual(probe.installs, 1)
        controller.disarm()
        XCTAssertEqual(probe.removes, 1)
        XCTAssertFalse(controller.isArmed)
    }

    /// `arm` REBINDS the cancel on every frame even though it does not reinstall. A controller that kept the
    /// first frame's closure would cancel through a drag that has already been replaced — the "Escape ended
    /// the wrong drag" defect, which is silent because both closures exist and both run.
    func testRearmingRebindsTheCancelWithoutReinstalling() {
        let probe = Probe()
        let controller = probe.make()
        var first = 0
        var second = 0
        controller.arm { first += 1 }
        controller.arm { second += 1 }
        XCTAssertEqual(probe.installs, 1)
        XCTAssertEqual(probe.reader?(keyEscape), true)
        XCTAssertEqual(first, 0)
        XCTAssertEqual(second, 1)
    }

    /// `disarm` is idempotent. The drag's own end and the mount's `dismantleNSView` both call it on a normal
    /// release, and a pane closing mid-drag makes them race. A second remove of an already-removed token is
    /// AppKit's undefined behaviour, so the count must not move.
    func testDisarmIsIdempotent() {
        let probe = Probe()
        let controller = probe.make()
        controller.arm {}
        controller.disarm()
        controller.disarm()
        controller.disarm()
        XCTAssertEqual(probe.removes, 1)
        XCTAssertFalse(controller.isArmed)
    }

    /// `disarm` on a controller that was never armed removes NOTHING. FAILS on the shape that keeps a
    /// nullable token and calls remove without checking it — the mount disarms on every non-dragging frame,
    /// so this path runs far more often than the armed one.
    func testDisarmWithoutArmRemovesNothing() {
        let probe = Probe()
        let controller = probe.make()
        controller.disarm()
        controller.disarm()
        XCTAssertEqual(probe.removes, 0)
        XCTAssertFalse(controller.isArmed)
    }

    /// Three drags in a row: three installs, three removes, and each remove takes back the token its own
    /// install produced. Identity is the assertion — a controller that removed a STALE token would leave the
    /// live monitor installed and the count would still read 3/3.
    func testThreeDragsBalanceAndEachRemoveTakesItsOwnToken() {
        let probe = Probe()
        let controller = probe.make()
        for _ in 0..<3 {
            controller.arm {}
            controller.disarm()
        }
        XCTAssertEqual(probe.installs, 3)
        XCTAssertEqual(probe.removes, 3)
        XCTAssertEqual(probe.installed.count, probe.removed.count)
        for (installed, removed) in zip(probe.installed, probe.removed) {
            XCTAssertIdentical(installed, removed)
        }
    }

    /// A refused install (AppKit hands back `nil`) leaves the controller DISARMED rather than half-armed, and
    /// the next frame retries. A controller that recorded the refusal as armed would spend the whole drag
    /// with no cancel key and would then "remove" a monitor that never existed.
    func testRefusedInstallLeavesItDisarmedAndTheNextFrameRetries() {
        let probe = Probe()
        let controller = probe.make()
        probe.refuseInstall = true
        controller.arm {}
        XCTAssertFalse(controller.isArmed)
        XCTAssertEqual(probe.installs, 0)
        controller.disarm()
        XCTAssertEqual(probe.removes, 0)

        probe.refuseInstall = false
        controller.arm {}
        XCTAssertTrue(controller.isArmed)
        XCTAssertEqual(probe.installs, 1)
        controller.disarm()
        XCTAssertEqual(probe.removes, 1)
    }

    /// Escape cancels AND is swallowed (`true` = return `nil` from the monitor), so the key that ends the
    /// drag is never also typed into the focused pane.
    func testEscapeCancelsAndIsSwallowed() {
        let probe = Probe()
        let controller = probe.make()
        var cancels = 0
        controller.arm { cancels += 1 }
        XCTAssertEqual(probe.reader?(keyEscape), true)
        XCTAssertEqual(cancels, 1)
    }

    /// Every other key passes through untouched and cancels nothing — typing during a drag still reaches the
    /// terminal, which is the Mac's stated advantage over the phone's first-responder grab. FAILS on a
    /// monitor that swallows the whole keyboard for the length of a gesture.
    func testANonCancelKeyPassesThroughAndCancelsNothing() {
        let probe = Probe()
        let controller = probe.make()
        var cancels = 0
        controller.arm { cancels += 1 }
        XCTAssertEqual(probe.reader?(keyA), false)
        XCTAssertEqual(cancels, 0)
    }

    /// A disarmed controller cancels nothing even if its reader is still called — the monitor is gone in
    /// production, but the closure is cleared too, so a late delivery cannot end a drag that has committed.
    func testADisarmedControllerCancelsNothing() {
        let probe = Probe()
        let controller = probe.make()
        var cancels = 0
        controller.arm { cancels += 1 }
        controller.disarm()
        XCTAssertEqual(probe.reader?(keyEscape), false)
        XCTAssertEqual(cancels, 0)
    }

    /// The reader holds the controller WEAKLY: a monitor that outlived its controller must decide nothing
    /// rather than resurrect a finished drag. FAILS on a strong capture, which is also the retain cycle that
    /// would keep every cancelled drag's closure alive.
    func testTheReaderDoesNotKeepTheControllerAlive() {
        let probe = Probe()
        var controller: PaneMoveEscapeMonitorController? = probe.make()
        var cancels = 0
        controller?.arm { cancels += 1 }
        controller = nil
        XCTAssertEqual(probe.reader?(keyEscape), false)
        XCTAssertEqual(cancels, 0)
    }
}
#endif
