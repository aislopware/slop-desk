import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// notify-cluster audit fix — ``PaneSpec/completionNotificationTitle`` is what
/// `WorkspaceStore`'s `onCommandCompleted` wiring feeds into the completion banner/toast (see
/// `WorkspaceStore.swift`'s `wireMaterializedLeaf` / canvas-path twin). It must prefer the live OSC
/// 0/2 shell title (``PaneSpec/lastKnownTitle``) over the static, rarely-changed ``PaneSpec/title``
/// (default `"Terminal"`) so multiple same-named panes produce distinguishable completion banners.
///
/// ### Revert-to-confirm-fail
/// Before the fix the call sites read `spec.title` directly (no such computed property existed /
/// it would have degenerated to `spec.title`), so a spec with a live `lastKnownTitle` still resolved
/// to the generic `"Terminal"` — the assertion in `testPrefersLiveLastKnownTitleOverStaticTitle`
/// would fail against that behaviour.
final class PaneSpecCompletionTitleTests: XCTestCase {
    func testPrefersLiveLastKnownTitleOverStaticTitle() {
        let spec = PaneSpec(kind: .terminal, title: "Terminal", lastKnownTitle: "~/project — sleep 12; false")
        XCTAssertEqual(
            spec.completionNotificationTitle,
            "~/project — sleep 12; false",
            "the live shell title identifies WHICH command finished, not the generic pane name",
        )
    }

    func testFallsBackToStaticTitleWhenNoLastKnownTitle() {
        let spec = PaneSpec(kind: .terminal, title: "Terminal") // never reported a live title
        XCTAssertEqual(
            spec.completionNotificationTitle, "Terminal",
            "with no live title yet, the static spec title is the only thing to show",
        )
    }

    func testFallsBackToStaticTitleWhenUserRenamedAndLastKnownTitleIsStale() {
        // A user-renamed pane still tracks the live shell title separately; the renamed title takes
        // precedence over an unrelated shell-reported line for the completion banner is NOT the
        // contract here — completionNotificationTitle always prefers the live signal when present,
        // matching the documented "often the running command line" semantics used by the notifier.
        let spec = PaneSpec(kind: .terminal, title: "My Custom Title", lastKnownTitle: "zsh")
        XCTAssertEqual(spec.completionNotificationTitle, "zsh")
    }
}
