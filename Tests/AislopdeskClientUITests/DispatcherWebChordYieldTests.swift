// DispatcherWebChordYieldTests (E18 M2) — the live `WorkspaceKeyDispatcher` YIELDS the standard web-browser
// chords (⌘[ Back / ⌘] Forward / ⌘⇧R hard-Reload / ⌘F Find-in-page) to a FOCUSED `.web` pane instead of
// resolving their global pane-cycle / Toggle-Details / Find bindings. The monitor PREEMPTS the responder
// chain, so without this yield the web pane's focus-scoped `.keyboardShortcut` (WebLeafView) would never see
// these chords — ⌘[ would cycle panes BEHIND the page, ⌘F would open the terminal find bar, etc.
//
// Driven headlessly with synthetic NSEvents (no window-server resource — the hang-safety rule is about
// SCStream/VT/Metal, not NSEvent), asserting the swallow/passthrough contract: with a `.web` leaf active,
// `handle(_:)` returns the event (passthrough), and — the load-bearing control — with a non-web (terminal)
// leaf active the SAME chord is OWNED (swallowed) by the monitor.
//
// FAILS on the pre-fix dispatcher: there was no `activePaneIsWeb` yield, so `handle(⌘[)` returned `nil`
// (swallow) and routed `.cyclePanePrev` even with a web pane focused — the chord never reached the pane.

#if os(macOS)
import AppKit
import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

@MainActor
final class DispatcherWebChordYieldTests: XCTestCase {
    /// A synthetic `.keyDown` carrying exactly the fields `KeyChordNormalizer` reads.
    private func keyDown(
        _ chars: String, keyCode: UInt16, command: Bool = false, shift: Bool = false,
    ) -> NSEvent {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: keyCode,
        )!
    }

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
    }

    /// The four web-browser chords the dispatcher yields: (charactersIgnoringModifiers, keyCode, shift).
    private let webChords: [(String, UInt16, Bool)] = [
        ("[", 33, false), // ⌘[  Back
        ("]", 30, false), // ⌘]  Forward
        ("r", 15, true), //  ⌘⇧R Hard reload
        ("f", 3, false), //  ⌘F  Find in page
    ]

    /// The subset of ``webChords`` that still carries a GLOBAL default binding (⌘⇧R ships unbound since the
    /// Details panel — its old owner — was removed, so it passes through on ANY pane; the yield entry only
    /// matters if a user binds it).
    private let globallyBoundWebChords: [(String, UInt16, Bool)] = [
        ("[", 33, false), // ⌘[  cycle pane prev
        ("]", 30, false), // ⌘]  cycle pane next
        ("f", 3, false), //  ⌘F  find bar
    ]

    /// With a `.web` leaf active, every web-browser chord is PASSED THROUGH to the focused pane (handle
    /// returns the event, not `nil`) so the WebLeafView `.keyboardShortcut` owns it.
    func testWebPaneYieldsAllBrowserChords() throws {
        let store = makeStore()
        let url = try XCTUnwrap(WebURLNormalizer.normalize("https://example.com/"))
        store.openWebPane(url: url, placement: .newTab) // a new tab whose lone leaf is a focused web pane
        let active = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        XCTAssertEqual(store.tree.spec(for: active)?.kind, .web, "precondition: the active leaf is a web pane")

        let dispatcher = WorkspaceKeyDispatcher(store: store)
        for (chars, keyCode, shift) in webChords {
            let result = dispatcher.handle(keyDown(chars, keyCode: keyCode, command: true, shift: shift))
            XCTAssertNotNil(
                result,
                "⌘\(shift ? "⇧" : "")\(chars) is yielded to the focused web pane (passthrough), not swallowed",
            )
        }
    }

    /// The load-bearing control: with a TERMINAL leaf active (the seeded default) the still-globally-bound
    /// chords are OWNED by
    /// the monitor — swallowed (handle returns `nil`) and routed to their global bindings. Proves the yield is
    /// gated on `.web` focus, not an accidental table miss. (⌘⇧R is exempt: it ships UNBOUND now that the
    /// Details panel is removed, so it passes through everywhere.)
    func testNonWebPaneStillOwnsTheSameChords() {
        let store = makeStore()
        let dispatcher = WorkspaceKeyDispatcher(store: store)
        for (chars, keyCode, shift) in globallyBoundWebChords {
            let result = dispatcher.handle(keyDown(chars, keyCode: keyCode, command: true, shift: shift))
            XCTAssertNil(
                result,
                "⌘\(shift ? "⇧" : "")\(chars) keeps its global binding (swallowed) when a non-web pane is focused",
            )
        }
    }
}
#endif
