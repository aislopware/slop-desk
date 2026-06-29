// PaneDropOverlayModelGenerationTests — the post-reset async-race guard on the drop overlay model.
//
// `PaneDropReceiver.dropEntered` kicks off an ASYNC pasteboard classification (`.url`/`.text` providers can
// be slow) and writes the result into `PaneDropOverlayModel.content`. On a fast enter→exit — or any slow
// provider load — the classify Task could resolve AFTER `dropExited`/`performDrop` already called `reset()`,
// re-setting `content`, flipping `isActive` back to true, and STRANDING the full-pane overlay faded-in with
// no drag present until the next drag interaction. The fix stamps each entry with a monotonically-increasing
// `generation` (bumped on every `reset()`); a classify may only write `content` if its captured generation
// is still current (`applyClassified(_:generation:)`).
//
// These drive the PURE `@MainActor` model directly — NO real `WKWebView` / `DropInfo` / GUI (hang-safety).
// Revert-to-confirm-fail: drop the `guard generation == self.generation` line from `applyClassified` and
// `testStaleClassifyAfterResetDoesNotReactivateOverlay` fails (the stale write reactivates the overlay).

#if canImport(SwiftUI)
import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

@MainActor
final class PaneDropOverlayModelGenerationTests: XCTestCase {
    /// A classify that resolves AFTER a reset (drag committed / cursor left) must NOT re-activate the overlay.
    func testStaleClassifyAfterResetDoesNotReactivateOverlay() {
        let model = PaneDropOverlayModel()

        // Drag enters → stamp a generation the classify Task would capture.
        let stale = model.beginClassification()
        // Drag leaves before the classify resolves → reset bumps the generation, invalidating `stale`.
        model.reset()
        XCTAssertFalse(model.isActive, "precondition: overlay cleared by reset")

        // The slow classify finally resolves with its (now stale) captured generation.
        model.applyClassified(.url("https://example.com"), generation: stale)

        XCTAssertNil(model.content, "a stale classify must be dropped, not re-set")
        XCTAssertFalse(model.isActive, "the full-pane overlay must NOT reactivate after the drag has left")
    }

    /// The guard must not be over-zealous: a classify whose generation is still current DOES apply.
    func testCurrentClassifyAppliesAndActivatesOverlay() {
        let model = PaneDropOverlayModel()

        let current = model.beginClassification()
        model.applyClassified(.file("/Users/me/notes.md"), generation: current)

        XCTAssertEqual(model.content, .file("/Users/me/notes.md"), "an in-generation classify applies")
        XCTAssertTrue(model.isActive, "the overlay shows while a supported drag is hovering")
    }

    /// A second entry (re-stamp) invalidates the first entry's in-flight classify — last drag wins.
    func testReentryInvalidatesPriorClassify() {
        let model = PaneDropOverlayModel()

        let first = model.beginClassification()
        let second = model.beginClassification()

        // The first (older) classify resolves last — it must be dropped, the second classify wins.
        model.applyClassified(.text("first"), generation: first)
        XCTAssertNil(model.content, "the older entry's classify is stale once a newer entry re-stamped")

        model.applyClassified(.text("second"), generation: second)
        XCTAssertEqual(model.content, .text("second"), "the current entry's classify applies")
    }
}
#endif
