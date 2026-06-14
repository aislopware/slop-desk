import XCTest
@testable import AislopdeskClientUI

/// PANE REBIND: pure resolution of a restored (possibly stale) window binding against the host's
/// live window list.
final class WindowRebindTests: XCTestCase {
    private func win(_ id: UInt32, _ app: String, _ title: String) -> RemoteWindowSummary {
        RemoteWindowSummary(windowID: id, appName: app, title: title, width: 1280, height: 800)
    }

    // MARK: keep

    func testLiveIDSameAppKeeps() {
        let list = [win(58, "Code", "main.swift — aislopdesk"), win(215, "Cua Driver", "")]
        XCTAssertEqual(WindowRebind.resolve(
            windowID: 58,
            appName: "Code",
            title: "main.swift — aislopdesk",
            in: list,
        ), .keep)
    }

    func testLiveIDNoSavedAppKeeps() {
        // Legacy/manual binding (no app recorded): presence of the id is the only signal.
        let list = [win(58, "Code", "whatever")]
        XCTAssertEqual(WindowRebind.resolve(windowID: 58, appName: "", title: "x", in: list), .keep)
    }

    /// THE RECYCLED-ID TRAP: the saved id exists on the host but belongs to a DIFFERENT app now —
    /// keeping it would stream the wrong window (the live black-pane incident: id 215 = Cua Driver
    /// overlay). Must rebind to the saved app instead.
    func testRecycledIDRebindsByApp() {
        let list = [win(215, "Cua Driver", ""), win(58, "Code", "main.swift — aislopdesk")]
        XCTAssertEqual(
            WindowRebind.resolve(
                windowID: 215,
                appName: "Code",
                title: "old.swift — aislopdesk",
                in: list,
            ),
            .rebind(list[1]),
        )
    }

    // MARK: rebind tiebreaks

    func testStaleIDExactTitleWins() {
        let list = [win(70, "Code", "a.swift — proj"), win(71, "Code", "b.swift — proj")]
        XCTAssertEqual(WindowRebind.resolve(
            windowID: 999,
            appName: "Code",
            title: "b.swift — proj",
            in: list,
        ), .rebind(list[1]))
    }

    func testStaleIDSoleAppWindowWins() {
        // VS Code titles mutate per file — the sole window of the app wins despite a title mismatch.
        let list = [win(80, "Code", "other.swift — proj"), win(81, "Safari", "Apple")]
        XCTAssertEqual(WindowRebind.resolve(
            windowID: 999,
            appName: "Code",
            title: "main.swift — proj",
            in: list,
        ), .rebind(list[0]))
    }

    func testStaleIDTitleContainmentTiebreak() {
        let list = [win(90, "Terminal", "zsh"), win(91, "Terminal", "vim — notes.md")]
        XCTAssertEqual(WindowRebind.resolve(
            windowID: 999,
            appName: "Terminal",
            title: "notes.md",
            in: list,
        ), .rebind(list[1]))
    }

    func testStaleIDMultipleNoTitleMatchTakesFirst() {
        let list = [win(90, "Terminal", "zsh"), win(91, "Terminal", "htop")]
        XCTAssertEqual(WindowRebind.resolve(
            windowID: 999,
            appName: "Terminal",
            title: "completely different",
            in: list,
        ), .rebind(list[0]))
    }

    // MARK: unresolved

    func testAppGoneIsUnresolved() {
        let list = [win(58, "Code", "x")]
        XCTAssertEqual(
            WindowRebind.resolve(windowID: 999, appName: "Safari", title: "Apple", in: list),
            .unresolved,
        )
    }

    func testStaleIDNoSavedAppIsUnresolved() {
        // Without an app name there is nothing safe to match — re-pick.
        let list = [win(58, "Code", "x")]
        XCTAssertEqual(
            WindowRebind.resolve(windowID: 999, appName: "", title: "x", in: list),
            .unresolved,
        )
    }
}
