// NotificationsOnIOSTests
//
// The phone shipped the whole Notification settings group over nothing: `CommandCompletionNotifier` and
// `PaneNotificationRouter` were `#if os(macOS)`, so the phone's shell installed none of the
// composition's three OS sinks and a long build finishing, a non-zero exit and an agent awaiting input
// all died at a nil closure. `UserNotifications` is one framework with one API on both triples, so the
// guard is gone and the phone installs the same poster the Mac does.
//
// These run on the iOS triple (`slopdesk-gate ios-tests`) and are the only place that widening is
// OBSERVABLE: a macOS `swift test` compiled those types before the change too and would assert nothing
// about it. They follow the discipline of the notifier's own suite — `UNUserNotificationCenter` is never
// instantiated (it needs a bundle + entitlements + an auth prompt, and this is a host-less logic bundle),
// so what is pinned is the PURE policy layer plus the two facts the compile itself is the proof of: the
// poster and the router exist here at all.

import SlopDeskWorkspaceCore
import XCTest

@MainActor
final class NotificationsOnIOSTests: XCTestCase {
    // MARK: the poster and the router reach the phone

    /// The compile is most of this test: naming ``CommandCompletionNotifier`` on the iOS triple is what
    /// the old `#if os(macOS)` made impossible. Construction is safe — `init` touches no `UN` type; only
    /// a delivered event does — so instantiating it proves the type is real rather than a name that
    /// happens to typecheck.
    ///
    /// `bounceDock` is the ONE genuinely macOS-shaped piece of the poster, and it survived the widening
    /// as an INJECTED closure rather than as a gate: a phone has no Dock tile, so it leaves the seam at
    /// its `{}` default. That the seam is injectable at all is what makes the asymmetry a binding
    /// decision instead of a `#if`.
    func testThePosterExistsOnTheIOSTripleWithAnInjectableBounceSeam() {
        let notifier = CommandCompletionNotifier()
        var bounces = 0
        notifier.bounceDock = { bounces += 1 }
        notifier.bounceDock()
        XCTAssertEqual(bounces, 1, "the bounce is a closure the Mac binds and the phone deliberately does not")
    }

    /// The click-to-reveal contract: the router's key is what the pure `userInfo` builder embeds, so a
    /// tapped banner carries a pane id the router can read back. Pinned against the REAL key rather than
    /// a placeholder — the builder takes the key as a parameter precisely so it stays testable, and on
    /// this triple the router that owns the key is finally in scope to check it against.
    func testATappedBannerCarriesThePaneIDTheRouterReadsBack() {
        let info = LongCommandNotificationUserInfo.make(
            paneIDUserInfoKey: PaneNotificationRouter.paneIDUserInfoKey, paneIDKey: "PANE-1",
        )
        XCTAssertEqual(info[PaneNotificationRouter.paneIDUserInfoKey], "PANE-1")
        XCTAssertEqual(PaneNotificationRouter.paneIDUserInfoKey, "slopdesk.paneID")
        // No reveal target ⇒ no key, so a banner for an unresolved pane routes nowhere rather than wrongly.
        XCTAssertTrue(LongCommandNotificationUserInfo.make(
            paneIDUserInfoKey: PaneNotificationRouter.paneIDUserInfoKey, paneIDKey: nil,
        ).isEmpty)
    }

    /// The router the phone installs as the `UNUserNotificationCenter` delegate is the SAME type the Mac
    /// installs — one router, two entry points. Its reveal seam is a plain closure, so it is checkable
    /// without a `UNNotification` (which cannot be constructed outside the framework).
    func testTheRouterCarriesTheRevealSeamOnIOS() {
        let router = PaneNotificationRouter()
        var revealed: String?
        router.onReveal = { revealed = $0 }
        router.onReveal?("PANE-7")
        XCTAssertEqual(revealed, "PANE-7", "the phone wires this to store.revealPane(byIDString:)")
    }

    // MARK: the sound verdict the phone spends on the banner

    /// ONE decision, TWO presenters. ``AgentSoundPolicy`` is the whole cue policy on both platforms; the
    /// Mac spends the verdict on `NSSound`, the phone attaches a `UNNotificationSound` to the request.
    /// What must hold on this triple is that the verdict is the same one — including its deliberate
    /// REFUSAL to gate on focus, which is what lets a cue ring for a pane focused in another window.
    func testTheAgentCueVerdictIsUnchangedOnIOS() {
        XCTAssertEqual(
            AgentSoundPolicy.sound(
                needsInput: true, sourcePaneFocused: true, soundTaskComplete: true, soundAwaitInput: true,
            ),
            .awaitInput,
            "focus does not silence the cue — only the toggle does",
        )
        XCTAssertEqual(
            AgentSoundPolicy.sound(
                needsInput: false, sourcePaneFocused: false, soundTaskComplete: true, soundAwaitInput: true,
            ),
            .taskComplete,
        )
        // Both toggles off ⇒ nil ⇒ the phone posts a SILENT banner. This is the whole of what keeps the
        // two Code Agent sound switches honest on a platform whose cue rides the notification request.
        XCTAssertNil(AgentSoundPolicy.sound(
            needsInput: true, sourcePaneFocused: false, soundTaskComplete: false, soundAwaitInput: false,
        ))
        XCTAssertNil(AgentSoundPolicy.sound(
            needsInput: false, sourcePaneFocused: false, soundTaskComplete: false, soundAwaitInput: false,
        ))
    }

    // MARK: the three events the phone now delivers

    /// The delivery gate the phone's sinks re-apply. With the SHIPPED defaults and a backgrounded app,
    /// all three of the events the phone used to drop are delivered: a non-zero exit, an agent awaiting
    /// input, and an explicit OSC 9/777 notice. A clean exit stays off, because "Notify on Command
    /// Finish" ships OFF — the phone inherits the Mac's defaults rather than inventing quieter ones.
    func testTheShippedDefaultsDeliverTheThreeEventsThePhoneUsedToDrop() {
        let settings = NotificationSettings()
        func delivers(_ event: NotificationEvent) -> Bool {
            NotificationPolicy.shouldDeliver(
                event: event, appActive: false, sourcePaneVisible: false, settings: settings,
            )
        }
        XCTAssertTrue(delivers(.commandFinish(exit: 1)), "a failed build must reach the phone")
        XCTAssertTrue(delivers(.agentAwaitInput), "a blocked agent must reach the phone")
        XCTAssertTrue(delivers(.explicitOSC))
        XCTAssertFalse(delivers(.commandFinish(exit: 0)), "Notify on Command Finish ships OFF on both")
    }
}
