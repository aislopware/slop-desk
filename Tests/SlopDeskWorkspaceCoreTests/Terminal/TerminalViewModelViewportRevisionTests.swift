import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

// MARK: - TerminalViewModelViewportRevisionTests (the local-scroll re-detect signal)

/// The `LinkHighlightOverlay` re-runs link detection while ⌘ is held on TWO observable signals:
/// `bytesReceived` (new streaming output) and `viewportRevision` (a LOCAL scrollback scroll, which moves
/// the viewport with NO new wire bytes). These pin the `viewportRevision` half — that
/// ``TerminalViewModel/noteViewportScrolled()`` bumps it AND that it is observation-tracked, so a SwiftUI
/// body reading it re-evaluates on a local scroll (the overlay's reactive dependency). Headless — no
/// renderer, no window server (the hang-safety rule).
@MainActor
final class TerminalViewModelViewportRevisionTests: XCTestCase {
    /// `noteViewportScrolled()` advances `viewportRevision` (the per-scroll change signal).
    func testNoteViewportScrolledAdvancesRevision() {
        let model = TerminalViewModel()
        let start = model.viewportRevision
        model.noteViewportScrolled()
        model.noteViewportScrolled()
        XCTAssertEqual(model.viewportRevision, start &+ 2, "each local scroll bumps the viewport tick")
    }

    /// `viewportRevision` is OBSERVATION-TRACKED: a `withObservationTracking` read (what a SwiftUI body
    /// does) fires its `onChange` when `noteViewportScrolled()` mutates it. This is the property that makes
    /// the ⌘-hold overlay re-detect on a local scroll; if the counter were `@ObservationIgnored` (or the
    /// overlay read only `bytesReceived`), the underlines would stay stranded over pre-scroll rows.
    func testViewportRevisionIsObservationTracked() {
        let model = TerminalViewModel()
        let changed = expectation(description: "observation onChange fired")
        withObservationTracking {
            _ = model.viewportRevision
        } onChange: {
            changed.fulfill()
        }
        model.noteViewportScrolled()
        wait(for: [changed], timeout: 1.0)
    }
}
