import XCTest
@testable import SlopDeskClientUI
#if os(macOS)
import AppKit // NSApplication.didResign/BecomeActiveNotification — the real app-frontmost edge under test
#endif

/// E17 ES-E17-4 / WI-7 — the ``SecureKeyboardEntryController`` BALANCE invariant for macOS Secure Keyboard
/// Entry. The process-global `EnableSecureEventInput()` is reference-counted: a leaked / doubled call secures
/// (or unbalances) the whole machine's keyboard, so the controller MUST call `enable` exactly once on the
/// false→true engage edge and `disable` exactly once on the true→false disengage edge — never twice the same
/// direction, and never a `disable` it did not pair with an `enable`.
///
/// These tests inject COUNTING seams (`enable` / `disable`) so they assert that balance WITHOUT ever calling
/// the real process-global API (which would secure the test runner's keyboard). They are non-tautological:
/// each asserts the enable/disable call counts against the engage formula `(autoSecureInput && hostNoEcho) ||
/// manualOn` while the app is active — a naive controller (engage when auto is off, double-enable on a repeat,
/// or leak on teardown) FAILS them.
@MainActor
final class SecureKeyboardEntryControllerTests: XCTestCase {
    /// A counting probe for the injected process-global seams. The controller retains the closures (→ the
    /// probe) for its lifetime, so the test's local probe stays alive alongside the controller. `@MainActor`
    /// because it builds the `@MainActor` controller and its counters are mutated from the controller's
    /// (main-actor) seams.
    @MainActor
    private final class Probe {
        var enables = 0
        var disables = 0

        func make(autoSecureInput: Bool = true) -> SecureKeyboardEntryController {
            SecureKeyboardEntryController(
                autoSecureInput: autoSecureInput,
                enable: { self.enables += 1 },
                disable: { self.disables += 1 },
            )
        }
    }

    /// Auto on + host enters a no-echo password prompt ⇒ secure input engages, exactly one enable, no disable.
    func testEngagesOnAutoNoEcho() {
        let probe = Probe()
        let c = probe.make()
        c.setHostNoEcho(true)
        XCTAssertTrue(c.engaged)
        XCTAssertEqual(probe.enables, 1)
        XCTAssertEqual(probe.disables, 0)
    }

    /// Auto OFF ⇒ a host no-echo prompt does NOT engage secure input (the auto setting gates the auto path).
    /// FAILS if the controller ignores `autoSecureInput` and engages on `hostNoEcho` alone.
    func testNoEngageWhenAutoOff() {
        let probe = Probe()
        let c = probe.make(autoSecureInput: false)
        c.setHostNoEcho(true)
        XCTAssertFalse(c.engaged)
        XCTAssertEqual(probe.enables, 0)
    }

    /// The MANUAL toggle engages secure input regardless of `autoSecureInput` / `hostNoEcho` (the Edit-menu
    /// override). FAILS if manual is folded behind the auto gate.
    func testManualOverrideEngagesRegardlessOfAuto() {
        let probe = Probe()
        let c = probe.make(autoSecureInput: false)
        c.setManualOn(true)
        XCTAssertTrue(c.engaged)
        XCTAssertEqual(probe.enables, 1)
        c.toggleManual() // off
        XCTAssertFalse(c.engaged)
        XCTAssertEqual(probe.disables, 1)
    }

    /// Echo restored (the password prompt ended) disengages — one enable, one disable, balanced, not engaged.
    func testEchoRestoredDisengagesBalanced() {
        let probe = Probe()
        let c = probe.make()
        c.setHostNoEcho(true)
        c.setHostNoEcho(false)
        XCTAssertFalse(c.engaged)
        XCTAssertEqual(probe.enables, 1)
        XCTAssertEqual(probe.disables, 1)
    }

    /// A FLOOD of identical engage inputs enables ONCE (idempotent reconcile — no double-enable leak). FAILS
    /// if the controller calls `enable` on every `setHostNoEcho(true)` rather than only on the edge.
    func testIdempotentNoDoubleEnable() {
        let probe = Probe()
        let c = probe.make()
        c.setHostNoEcho(true)
        c.setHostNoEcho(true)
        c.setHostNoEcho(true)
        XCTAssertTrue(c.engaged)
        XCTAssertEqual(probe.enables, 1, "engage edge fires enable exactly once under a repeat flood")
        XCTAssertEqual(probe.disables, 0)
    }

    /// Teardown (pane close) RELEASES the held reference exactly once when engaged — the leak guard. A second
    /// teardown is a clean no-op (never a double-disable).
    func testTeardownReleasesEngagedReferenceOnce() {
        let probe = Probe()
        let c = probe.make()
        c.setHostNoEcho(true)
        c.teardown()
        XCTAssertFalse(c.engaged)
        XCTAssertEqual(probe.disables, 1)
        c.teardown() // idempotent
        XCTAssertEqual(probe.disables, 1, "teardown never double-disables")
    }

    /// Teardown while NEVER engaged disables ZERO times — the controller must not call `disable` it never
    /// paired with an `enable` (that would unbalance the process-global counter into the negative).
    func testTeardownNeverDisablesWhenNeverEngaged() {
        let probe = Probe()
        let c = probe.make()
        c.teardown()
        XCTAssertEqual(probe.disables, 0)
        XCTAssertEqual(probe.enables, 0)
    }

    /// App resign (window backgrounded) disengages even while the password prompt is still up; returning to
    /// active re-engages — so the process-global lock never lingers across an app switch, and the counts stay
    /// balanced across the round trip.
    func testAppResignDisengagesAndReEngages() {
        let probe = Probe()
        let c = probe.make()
        c.setHostNoEcho(true)
        XCTAssertTrue(c.engaged)
        c.setAppActive(false)
        XCTAssertFalse(c.engaged)
        XCTAssertEqual(probe.disables, 1)
        c.setAppActive(true)
        XCTAssertTrue(c.engaged)
        XCTAssertEqual(probe.enables, 2, "returning to active re-engages")
    }

    #if os(macOS)
    /// The LEAK guard the review flagged: an engaged secure-input hold MUST be released when the app stops
    /// being frontmost (the user ⌘-Tabs away — e.g. to a password manager — while a remote no-echo prompt is
    /// still up), driven by the REAL `NSApplication` active/resign notifications the controller observes via
    /// ``SecureKeyboardEntryController/observeAppActivity()`` — not just by a hand-called `setAppActive`. Posts
    /// the genuine notifications to an injected (private) center and asserts the held `EnableSecureEventInput`
    /// reference is released on resign and re-acquired on return. FAILS before the observer wiring: with no
    /// observer the controller never reacted to the backgrounding and the process-global lock leaked to every
    /// other app. The private center keeps the test off the process-global `.default` (no cross-talk).
    func testObservesAppResignNotificationToReleaseLeak() {
        let probe = Probe()
        let center = NotificationCenter()
        let c = SecureKeyboardEntryController(
            autoSecureInput: true,
            enable: { probe.enables += 1 },
            disable: { probe.disables += 1 },
            notificationCenter: center,
        )
        c.observeAppActivity()
        c.setHostNoEcho(true)
        XCTAssertTrue(c.engaged)
        XCTAssertEqual(probe.enables, 1)

        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertFalse(c.engaged, "secure input released when slopdesk is backgrounded — no process-wide leak")
        XCTAssertEqual(probe.disables, 1)

        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(c.engaged, "secure input re-acquired on return to front")
        XCTAssertEqual(probe.enables, 2)
    }

    /// ``observeAppActivity()`` is idempotent: a repeat call (the leaf re-wires on every live-session swap)
    /// must NOT install a second observer pair, or one app-resign notification would disable twice and
    /// unbalance the process-global counter. One resign ⇒ exactly one disable.
    func testObserveAppActivityIdempotentNoDoubleObserver() {
        let probe = Probe()
        let center = NotificationCenter()
        let c = SecureKeyboardEntryController(
            autoSecureInput: true,
            enable: { probe.enables += 1 },
            disable: { probe.disables += 1 },
            notificationCenter: center,
        )
        c.observeAppActivity()
        c.observeAppActivity() // re-wire (live swap) — must not double-subscribe
        c.setHostNoEcho(true)
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertEqual(probe.disables, 1, "a single resign disengages exactly once despite the re-wire")
    }

    /// ``teardown()`` removes the app-activity observers, so a notification posted AFTER teardown is inert —
    /// a torn-down pane's controller can never be driven (or double-disabled) by a late app-resign.
    func testTeardownRemovesAppActivityObserver() {
        let probe = Probe()
        let center = NotificationCenter()
        let c = SecureKeyboardEntryController(
            autoSecureInput: true,
            enable: { probe.enables += 1 },
            disable: { probe.disables += 1 },
            notificationCenter: center,
        )
        c.observeAppActivity()
        c.setHostNoEcho(true)
        c.teardown() // releases the held reference (disables == 1) AND removes the observers
        XCTAssertEqual(probe.disables, 1)
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertEqual(probe.disables, 1, "a post-teardown resign is inert — observer was removed")
    }
    #endif

    /// Turning Auto Secure Input OFF live while engaged on the AUTO path disengages immediately. FAILS if the
    /// setting is only read at construction.
    func testAutoSettingOffWhileEngagedDisengages() {
        let probe = Probe()
        let c = probe.make()
        c.setHostNoEcho(true)
        XCTAssertTrue(c.engaged)
        c.setAutoSecureInput(false)
        XCTAssertFalse(c.engaged)
        XCTAssertEqual(probe.disables, 1)
    }

    /// Manual OFF while the AUTO path still holds (host still at a no-echo prompt) STAYS engaged — dropping one
    /// of two reasons to be secure must not disengage. No spurious disable. FAILS if the controller disengages
    /// on any single input dropping rather than on the combined formula going false.
    func testManualOffWhileAutoStillHoldsStaysEngaged() {
        let probe = Probe()
        let c = probe.make()
        c.setHostNoEcho(true) // auto path engages
        c.setManualOn(true) // manual also on (still one engaged reference)
        XCTAssertEqual(probe.enables, 1, "two reasons, still one engage")
        c.setManualOn(false) // drop manual; auto still holds
        XCTAssertTrue(c.engaged)
        XCTAssertEqual(probe.disables, 0, "auto still holds it secure")
        c.setHostNoEcho(false) // now both reasons gone
        XCTAssertFalse(c.engaged)
        XCTAssertEqual(probe.disables, 1)
    }
}
