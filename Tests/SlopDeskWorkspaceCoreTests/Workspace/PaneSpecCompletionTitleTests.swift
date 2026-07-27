import Foundation
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// ``PaneLabel/completionNotificationTitle(title:cwd:liveTitle:)`` is what
/// `WorkspaceStore`'s `onCommandCompleted` wiring feeds into the completion banner/toast (see
/// `WorkspaceStore.swift`'s `wireMaterializedLeaf` / canvas-path twin). It must prefer the live OSC
/// 0/2 shell title over the static, rarely-changed ``PaneSpec/title``
/// (default `"Terminal"`) so multiple same-named panes produce distinguishable completion banners.
///
final class PaneSpecCompletionTitleTests: XCTestCase {
    func testPrefersLiveTitleOverStaticTitle() {
        XCTAssertEqual(
            PaneLabel.completionNotificationTitle(
                title: "Terminal", cwd: nil, liveTitle: "~/project — sleep 12; false",
            ),
            "~/project — sleep 12; false",
            "the live shell title identifies WHICH command finished, not the generic pane name",
        )
    }

    func testFallsBackToStaticTitleWhenNoLiveTitleAndNoCwd() {
        XCTAssertEqual(
            PaneLabel.completionNotificationTitle(title: "Terminal", cwd: nil, liveTitle: nil),
            "Terminal",
            "with no live title AND no known cwd, the static spec title is the only thing to show",
        )
    }

    /// B1 (host-authoritative-metadata audit): a shell that emits NO OSC-0/2 title (Starship / hookless)
    /// but whose host cwd IS known must NOT surface the generic "Terminal" in the completion banner — the
    /// cwd's folder name is the same identity the sidebar/tab/window title already show, so the banner
    /// stays consistent with them.
    func testFallsBackToCwdFolderNameWhenNoLiveTitle() {
        XCTAssertEqual(
            PaneLabel.completionNotificationTitle(
                title: "Terminal", cwd: "/Users/me/slop-desk", liveTitle: nil,
            ),
            "slop-desk",
            "with no live title but a known cwd, the folder name identifies the pane (not \"Terminal\")",
        )
    }

    func testLiveTitleStillWinsOverCwdFolderName() {
        XCTAssertEqual(
            PaneLabel.completionNotificationTitle(
                title: "Terminal", cwd: "/Users/me/slop-desk", liveTitle: "~/slop-desk — make check",
            ),
            "~/slop-desk — make check",
            "a live shell title is more specific than the folder name and still wins",
        )
    }

    func testTheLiveSignalWinsEvenOverAUserRename() {
        // The banner always prefers the live signal when present, matching the documented
        // "often the running command line" semantics the notifier relies on.
        XCTAssertEqual(
            PaneLabel.completionNotificationTitle(title: "My Custom Title", cwd: nil, liveTitle: "zsh"),
            "zsh",
        )
    }
}
