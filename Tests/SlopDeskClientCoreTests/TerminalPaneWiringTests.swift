// TerminalPaneWiringTests — the terminal leaf's wiring, pinned as behaviour rather than as prose.
//
// Every claim below was a COMMENT on `TerminalLeafView` until the wiring descended (docs/56 §3,
// increment 56c). That mattered because the canvas is getting a second renderer: a rule that lives in
// a comment gets hand-translated into AppKit, and a rule that lives in a test does not.
//
// THE ONE WITH TEETH IS THE SECURE-INPUT BALANCE. macOS `EnableSecureEventInput()` is
// PROCESS-GLOBAL and REFERENCE-COUNTED: a missed decrement leaves the keyboard "secured" for every
// other app on the machine until the process dies — a notorious footgun, and one with nothing on
// screen to explain it. Three of these tests are about the DECREMENT alone, and the sharpest is
// `testClearReleasesTheLockEvenWhenTheModelHasAlreadyGone`: `clear` tears the controller down ABOVE
// its `guard let model`, so a pane whose model went first still gives the keyboard back. Moving that
// one line below the guard passes a compiler, passes a build, and locks the user out.
//
// The controller's process-global seams are INJECTED here (as they are designed to be) so the suite
// counts calls without ever securing the TEST RUNNER's keyboard, and its notification centre is a
// private one so no real `NSApplication` edge can land mid-assertion. The counters therefore work on
// every platform, unlike the model's own `secureInputActive` mirror — which is gated `false` off
// macOS and is deliberately not asserted on here.
//
// The rig mints a REAL `LivePaneSession` because that handle is what carries the retain-cycle rule
// the wiring exists to state once. Its client factory traps: nothing here dials, and a leak that made
// it dial would say so loudly instead of opening a socket in a unit test.

import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientCore

/// Counts the process-global secure-input seams without calling them.
@MainActor
private final class SecureInputLedger {
    var enables = 0
    var disables = 0
}

@MainActor
final class TerminalPaneWiringTests: XCTestCase {
    // MARK: - Rig

    private struct Rig {
        let store: WorkspaceStore
        let live: LivePaneSession
        let model: TerminalViewModel
        let tabID: TabID
        let wiring: TerminalPaneWiring
        let ledger: SecureInputLedger
    }

    /// One pane in one tab, a real session over it, and a wiring whose lock seams are counted.
    ///
    /// The pane id is SHARED between the store's tree and the session, because two of the verbs under
    /// test (`dismiss(.syncInput:)`, the code-panel reveal) look the pane up in the store by that id.
    private func makeRig() -> Rig {
        let paneID = PaneID()
        let spec = PaneSpec(kind: .terminal, title: "Terminal")
        let tab = Tab(id: TabID(), title: "one", root: .leaf(paneID), activePane: paneID)
        let session = Session(id: SessionID(), name: "wiring", tabs: [tab], specs: [paneID: spec])
        let store = WorkspaceStore(
            restoringTree: TreeWorkspace(sessions: [session], activeSessionID: session.id),
            makeSession: { seed in RecordingPaneSession(seed.spec) },
        )
        store.attachLoopbackWorkspaceDocument()

        let live = LivePaneSession.make(
            paneID: paneID,
            spec: spec,
            makeClient: { _ in
                fatalError("the pane wiring never dials — this rig has no transport to dial over")
            },
            makeInspector: { _ in nil },
        )
        let ledger = SecureInputLedger()
        let wiring = TerminalPaneWiring(
            secureInput: SecureKeyboardEntryController(
                // Pinned rather than read off the machine's stored setting: `wire` pushes the value
                // each test passes, so nothing here depends on how this Mac happens to be configured.
                autoSecureInput: false,
                enable: { ledger.enables += 1 },
                disable: { ledger.disables += 1 },
                // A private centre: no real app-frontmost edge may land inside an assertion.
                notificationCenter: NotificationCenter(),
            ),
        )
        return Rig(
            store: store,
            live: live,
            model: live.terminalModel!,
            tabID: tab.id,
            wiring: wiring,
            ledger: ledger,
        )
    }

    private func wire(_ rig: Rig, autoSecureInput: Bool = false) {
        rig.wiring.wire(
            live: rig.live, store: rig.store, overlay: nil, chrome: nil,
            autoSecureInput: autoSecureInput,
        )
    }

    // MARK: - Every callback the leaf owns is installed, and every one is taken back

    /// `wire` installs all TEN model callbacks. They were ten separate assignments spread over five
    /// `private func`s on a `View`; the count is the contract, because a leg silently dropped in a port
    /// is a chord that stops working with nothing red.
    func testWireInstallsEveryCallbackTheLeafOwns() {
        let rig = makeRig()
        wire(rig)

        XCTAssertNotNil(rig.model.onRequestFind, "⌘F")
        XCTAssertNotNil(rig.model.onRequestFindBackward, "copy-mode `?`")
        XCTAssertNotNil(rig.model.onRequestFindNext, "⌘G")
        XCTAssertNotNil(rig.model.onRequestFindPrev, "⇧⌘G")
        XCTAssertNotNil(rig.model.onHostEchoChanged, "the host no-echo edge (wire type 31)")
        XCTAssertNotNil(rig.model.onManualSecureInputChanged, "the manual secure-input toggle")
        XCTAssertNotNil(rig.model.onHintConfirmed, "Hint Mode's resolved label")
        XCTAssertNotNil(rig.model.onRequestBlockNavigator, "⌃⌘O")
        XCTAssertNotNil(rig.model.onRequestOpenHostPath, "⌘click open-on-host")
        XCTAssertNotNil(rig.model.onRequestRevealHostPath, "⌘⇧click reveal-on-host")
    }

    /// `clear` takes every one back. The model is owned by the LIVE SESSION and outlives a
    /// `.id(PaneID)` remount, so a callback left behind is a dead leaf's state being driven by a
    /// surviving model.
    func testClearNilsEveryCallbackSoASurvivingModelCannotDriveADeadLeaf() {
        let rig = makeRig()
        wire(rig)
        rig.wiring.clear(live: rig.live)

        XCTAssertNil(rig.model.onRequestFind)
        XCTAssertNil(rig.model.onRequestFindBackward)
        XCTAssertNil(rig.model.onRequestFindNext)
        XCTAssertNil(rig.model.onRequestFindPrev)
        XCTAssertNil(rig.model.onHostEchoChanged)
        XCTAssertNil(rig.model.onManualSecureInputChanged)
        XCTAssertNil(rig.model.onHintConfirmed)
        XCTAssertNil(rig.model.onRequestBlockNavigator)
        XCTAssertNil(rig.model.onRequestOpenHostPath)
        XCTAssertNil(rig.model.onRequestRevealHostPath)
        XCTAssertNil(rig.wiring.findBar.onSearchAllTabs, "the bar's escalation hook is the leaf's too")
    }

    /// A renderer's trigger over-fires (SwiftUI re-runs `.onChange` on any live-session swap; an
    /// observation-tracked AppKit canvas re-arms on every render). Every leg ASSIGNS, so re-wiring
    /// replaces rather than stacks — and the lock is still taken exactly once.
    func testWiringTwiceReplacesRatherThanStacks() {
        let rig = makeRig()
        rig.model.hostNoEcho = true
        wire(rig, autoSecureInput: true)
        wire(rig, autoSecureInput: true)

        XCTAssertEqual(rig.ledger.enables, 1, "two wires, one EnableSecureEventInput")
        XCTAssertEqual(rig.ledger.disables, 0)

        rig.wiring.clear(live: rig.live)
        XCTAssertEqual(rig.ledger.disables, 1, "and one balancing DisableSecureEventInput")
    }

    /// A pane with no terminal model yet (or a non-terminal kind) wires nothing and — critically —
    /// takes no lock.
    func testWiringAPaneWithNoSessionIsAWholeNoOp() {
        let rig = makeRig()
        rig.wiring.wire(live: nil, store: rig.store, overlay: nil, chrome: nil, autoSecureInput: true)

        XCTAssertEqual(rig.ledger.enables, 0)
        XCTAssertFalse(rig.wiring.findBar.visible)
        XCTAssertNil(rig.model.onRequestFind, "nothing was wired at all — not onto some other pane's model")
    }

    // MARK: - The reference-counted process-global lock

    /// The host floods the no-echo edge (every prompt redraw can re-assert it), and the closure the
    /// wiring installed is what receives it. One `EnableSecureEventInput()`, however many edges.
    func testAFloodOfNoEchoEdgesTakesTheLockOnce() {
        let rig = makeRig()
        wire(rig, autoSecureInput: true)

        for _ in 0..<5 { rig.model.onHostEchoChanged?(true) }
        XCTAssertEqual(rig.ledger.enables, 1)
        XCTAssertEqual(rig.ledger.disables, 0)

        for _ in 0..<5 { rig.model.onHostEchoChanged?(false) }
        XCTAssertEqual(rig.ledger.enables, 1)
        XCTAssertEqual(rig.ledger.disables, 1, "echo restored gives the keyboard back exactly once")
    }

    /// `wire` adopts the model's CURRENT inputs rather than waiting for the next edge. A pane
    /// remounted while the remote shell is already sitting at a password prompt has no edge coming.
    func testWireAdoptsTheModelsCurrentNoEchoStateRatherThanWaitingForAnEdge() {
        let rig = makeRig()
        rig.model.hostNoEcho = true // no callback is installed yet — this edge is LOST on purpose
        XCTAssertEqual(rig.ledger.enables, 0)

        wire(rig, autoSecureInput: true)
        XCTAssertEqual(rig.ledger.enables, 1, "the wire reads hostNoEcho, it does not wait for it")
    }

    /// The AUTO path is gated by the setting; the MANUAL toggle is not. Off macOS both are inert
    /// through the default seams, which is why the seams and not the platform are what these count.
    func testAutoSecureInputOffLeavesTheAutoPathAloneButNotTheManualOne() {
        let rig = makeRig()
        rig.model.hostNoEcho = true
        wire(rig, autoSecureInput: false)
        XCTAssertEqual(rig.ledger.enables, 0, "auto off ⇒ a host password prompt takes no lock")

        rig.model.toggleSecureKeyboardEntry()
        XCTAssertEqual(rig.ledger.enables, 1, "the manual toggle engages regardless of the setting")

        rig.wiring.clear(live: rig.live)
        XCTAssertEqual(rig.ledger.disables, 1)
    }

    /// Teardown releases the reference exactly once, and a second teardown does not double-disable
    /// (the leak hazard in reverse).
    func testClearReleasesTheLockExactlyOnceAndIsIdempotent() {
        let rig = makeRig()
        rig.model.hostNoEcho = true
        wire(rig, autoSecureInput: true)
        XCTAssertEqual(rig.ledger.enables, 1)

        rig.wiring.clear(live: rig.live)
        rig.wiring.clear(live: rig.live)
        rig.wiring.clear(live: nil)

        XCTAssertEqual(rig.ledger.disables, 1, "one enable, one disable, however many teardowns")
    }

    /// THE ORDERING TEST. `clear` calls `teardown()` ABOVE its `guard let model`, so a pane torn down
    /// after its session/model has gone still gives the process-global keyboard back. Move that line
    /// below the guard and this is the only thing that notices — until a user cannot type in any other
    /// app.
    func testClearReleasesTheLockEvenWhenTheModelHasAlreadyGone() {
        let rig = makeRig()
        rig.model.hostNoEcho = true
        wire(rig, autoSecureInput: true)
        XCTAssertEqual(rig.ledger.enables, 1)

        rig.wiring.clear(live: nil) // the session went first — the lock is still ours to release

        XCTAssertEqual(rig.ledger.disables, 1, "the lock is process-global; the model is not")
    }

    /// The same ordering, for the find bar: `attach(nil)` and the escalation hook are cleared above the
    /// guard, so a bar can never be left attached to a model the leaf no longer owns.
    func testClearDetachesTheFindBarEvenWhenTheModelHasAlreadyGone() {
        let rig = makeRig()
        wire(rig)
        XCTAssertNotNil(rig.wiring.findBar.onSearchAllTabs)

        rig.wiring.clear(live: nil)

        XCTAssertNil(rig.wiring.findBar.onSearchAllTabs)
    }

    /// The LIVE Settings toggle. Without this reconcile an engaged lock lingers until the next pane
    /// swap or echo edge — the carryover footgun the Settings footer's "live" claim would be lying
    /// about.
    func testTurningAutoSecureInputOffReleasesTheLockWithoutAPaneSwap() {
        let rig = makeRig()
        rig.model.hostNoEcho = true
        wire(rig, autoSecureInput: true)
        XCTAssertEqual(rig.ledger.enables, 1)

        rig.wiring.reconcileSecureInput(live: rig.live, autoSecureInput: false)
        XCTAssertEqual(rig.ledger.disables, 1, "the OFF edge releases the lock at once")

        rig.wiring.reconcileSecureInput(live: rig.live, autoSecureInput: true)
        XCTAssertEqual(rig.ledger.enables, 2, "and the ON edge re-takes it, the prompt still being up")
    }

    /// A reconcile for a pane that has no model yet must not touch the actuator at all — the setting
    /// change belongs to panes that exist.
    func testReconcileIsANoOpForAPaneWithNoSession() {
        let rig = makeRig()
        rig.wiring.reconcileSecureInput(live: nil, autoSecureInput: true)
        XCTAssertEqual(rig.ledger.enables, 0)
        XCTAssertEqual(rig.ledger.disables, 0)
    }

    // MARK: - Find, navigator, hint

    /// ⌘F opens the bar forward; copy-mode `?` opens the SAME bar biased BACKWARD, which is the whole
    /// reason `onRequestFindBackward` is a separate hook (vim parity: `n`/`N` step against the sense).
    func testTheFindHooksOpenTheOneBarWithTheRightBias() {
        let rig = makeRig()
        wire(rig)

        rig.model.onRequestFind?()
        XCTAssertTrue(rig.wiring.findBar.visible)
        XCTAssertFalse(rig.wiring.findBar.searchBackward, "⌘F searches forward")

        rig.model.onRequestFindBackward?()
        XCTAssertTrue(rig.wiring.findBar.visible)
        XCTAssertTrue(rig.wiring.findBar.searchBackward, "copy-mode `?` biases the same bar backward")
    }

    /// ⌃⌘O TOGGLES the per-pane chrome — the store fires it only on the ACTIVE pane, so the card only
    /// ever mounts over the pane that asked. The chrome is the wiring's own state, so it is captured
    /// strongly on purpose; `clear` nils the model's side of it.
    func testTheNavigatorHookTogglesThePerPaneChrome() {
        let rig = makeRig()
        wire(rig)
        XCTAssertFalse(rig.wiring.navigatorChrome.isVisible)

        rig.model.onRequestBlockNavigator?()
        XCTAssertTrue(rig.wiring.navigatorChrome.isVisible)

        rig.model.onRequestBlockNavigator?()
        XCTAssertFalse(rig.wiring.navigatorChrome.isVisible, "⌃⌘O is a toggle, not an open")
    }

    /// The hint hook survives its own model being released — it captures `[weak model]`, so a fire
    /// after teardown is a no-op rather than a resurrection or a cycle. (What it DOES with a live
    /// model is `TerminalHintActuatorTests`'.)
    func testTheHintHookHoldsItsModelWeakly() {
        let rig = makeRig()
        wire(rig)
        let hook = rig.model.onHintConfirmed
        rig.wiring.clear(live: rig.live)

        XCTAssertNil(rig.model.onHintConfirmed, "teardown nils the model's side")
        XCTAssertNotNil(hook, "the closure the renderer captured is still callable and inert")
    }

    // MARK: - The chip `×`

    /// Read-only releases through the MODEL, whose `onReadOnlyChanged` hook converges the store's set —
    /// never by writing the store directly, which would leave the pane's own flag armed.
    func testDismissingTheReadOnlyChipReleasesThroughTheModel() {
        let rig = makeRig()
        rig.model.enterReadOnly()
        XCTAssertTrue(rig.model.readOnlyBadgeActive)

        TerminalPaneWiring.dismiss(.readOnly, live: rig.live, store: rig.store)

        XCTAssertFalse(rig.model.readOnlyBadgeActive)
    }

    /// Sync input disarms the WHOLE TAB, because the mode is the tab's: clearing it on one pane would
    /// leave the siblings still fanning input into a pane that no longer shows the chip.
    func testDismissingTheSyncInputChipDisarmsTheWholeTab() {
        let rig = makeRig()
        rig.store.toggleSyncInput(tabID: rig.tabID)
        XCTAssertTrue(rig.store.syncInputArmed(for: rig.live.id))

        TerminalPaneWiring.dismiss(.syncInput, live: rig.live, store: rig.store)

        XCTAssertFalse(rig.store.syncInputArmed(for: rig.live.id))
    }

    /// The secure-input chip carries no `×` (`PaneStatusPill.dismissHelp`), so this can only be reached
    /// by a renderer that grew one. It must not release the lock behind the actuator's back.
    func testDismissingTheSecureInputChipTouchesNothing() {
        let rig = makeRig()
        rig.model.hostNoEcho = true
        wire(rig, autoSecureInput: true)

        TerminalPaneWiring.dismiss(.secureInput, live: rig.live, store: rig.store)

        XCTAssertEqual(rig.ledger.enables, 1)
        XCTAssertEqual(rig.ledger.disables, 0, "the chip has no `×`; the actuator owns the balance")
    }

    // MARK: - The two async verbs, for a pane that has nothing to do

    /// No session ⇒ no dial. The rig's client factory traps, so a leak here is loud rather than a
    /// socket opened in a unit test.
    func testConnectIfNeededIsANoOpForAPaneWithNoSession() async {
        let rig = makeRig()
        await TerminalPaneWiring.connectIfNeeded(live: nil, store: rig.store)
    }

    /// No session ⇒ nothing typed. (`AutotypeSeamTests` owns the once-per-launch latch itself.)
    func testRunAutotypeIsANoOpForAPaneWithNoSession() async {
        await TerminalPaneWiring.runAutotypeIfRequested(live: nil)
    }
}
