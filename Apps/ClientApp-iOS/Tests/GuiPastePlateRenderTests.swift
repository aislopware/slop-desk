// GuiPastePlateRenderTests
//
// ONE claim, and it is about SHAPE rather than about a number of call sites: RENDERING the remote-GUI
// pane's paste plate must not read the clipboard's CONTENT.
//
// Since iOS 16, reading `UIPasteboard.string` for content this app did not write — with no paste gesture
// behind it — raises the modal "Allow Paste?" alert. `GuiPastePlateMenu.canPasteCurrent` is read from
// `body` (it is what `.disabled(_:)` on "Paste as Keystrokes" hangs off), and it used to call
// `WorkspaceStore.currentLocalClipboard()`: every render of a desktop pane's footer put that alert on
// screen, unprompted (increment 78). The Mac's twin never could — `MacGuiPaneControls` builds its menu in
// `pasteMenu.onClick`, at menu OPEN — and SwiftUI has no equivalent moment, because a `Menu`'s content is a
// `@ViewBuilder` evaluated WITH the body.
//
// So the test injects BOTH clipboard seams and counts: the content provider must be called ZERO times by a
// render, and the probe (`clipboardHasTextProbe`) must be called at least once — otherwise "zero content
// reads" would be satisfied by a render that never evaluated the menu at all. The probe's own agreement
// with what a paste would actually find (the ring fallback included) is pinned headlessly next to the
// store, in `Tests/SlopDeskWorkspaceCoreTests/Workspace/ClipboardRingTests.swift`; here the subject is the
// VIEW, which is why this suite lives on the iOS triple (docs/56 F4c — `SlopDeskPhoneUI` is `#if os(iOS)`
// end to end, so a macOS `swift test` sees an empty module and would assert nothing).
//
// `SlopDeskPhoneUI` is `@testable`-imported for `GuiPastePlateMenu`, which is internal — this bundle is an
// Xcode target OUTSIDE the SwiftPM package, so a plain `import` cannot see it.

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
import SwiftUI
import XCTest
@testable import SlopDeskPhoneUI

@MainActor
final class GuiPastePlateRenderTests: XCTestCase {
    /// A store with `FakePaneSession` behind the `makeSession` seam (compiled into this bundle from
    /// `SlopDeskWorkspaceCoreTests` rather than copied — see `SharedFocusSettingTests`).
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(makeSession: { seed in FakePaneSession(seed.spec) })
    }

    /// A remote-GUI model that CAN type: streaming (`open()`) plus a live key sink. Without both,
    /// `canPasteKeystrokes` is false and the plate would be disabled for a reason that has nothing to do
    /// with the clipboard.
    private func makeTypingModel() -> RemoteWindowModel {
        let model = RemoteWindowModel(windowID: "42", title: "Remote window")
        model.open()
        model.keyInjector = { _, _, _ in }
        XCTAssertTrue(model.canPasteKeystrokes, "the fixture must be able to type, else the pin is vacuous")
        return model
    }

    /// Drives `plate` through the view-graph evaluation a render performs, and it takes TWO levels: the
    /// plate's own `body` yields a `SlatePlateMenu` holding an unevaluated `@ViewBuilder` closure, and it
    /// is `SlatePlateMenu`'s body — `Menu { content() }` — that finally builds the menu items and the
    /// `.disabled(!canPasteCurrent)` on the paste one. Stopping at the first level would assert nothing.
    ///
    /// Deliberately NOT an `ImageRenderer` pass (the phone's pixel rigs in `SlateSnapshotRender` use one):
    /// the subject here is which seams a body evaluation touches, and rasterizing a `Menu` would add a
    /// dependency on how the renderer treats a control it draws as a label.
    private func render(_ plate: GuiPastePlateMenu) {
        _ = plate.body.body
    }

    // MARK: - A render reads the probe, never the content

    func testRenderingThePastePlateNeverReadsTheClipboardContent() {
        let store = makeStore()
        var contentReads = 0
        var probes = 0
        store.clipboardTextProvider = {
            contentReads += 1
            return "live-clipboard"
        }
        store.clipboardHasTextProbe = {
            probes += 1
            return true
        }
        let plate = GuiPastePlateMenu(model: makeTypingModel(), store: store)

        render(plate)

        XCTAssertGreaterThan(probes, 0, "the render must have evaluated the menu — else the pin is vacuous")
        XCTAssertEqual(
            contentReads, 0,
            "a render must NEVER read the clipboard's content: on iOS that read is the modal "
                + "\"Allow Paste?\" alert, and body runs on every frame of the pane footer",
        )
        XCTAssertTrue(store.clipboardRing.isEmpty, "and so a render records nothing into the history either")
    }

    // MARK: - The probe is what decides the enablement

    /// Both directions, so the `false` is not an accident of the fixture: the plate is lit when the probe
    /// says there is text and dark when it does not, with the content provider untouched either way.
    func testEnablementFollowsTheProbeInBothDirections() {
        let store = makeStore()
        var contentReads = 0
        store.clipboardTextProvider = {
            contentReads += 1
            return "live-clipboard"
        }
        let model = makeTypingModel()

        store.clipboardHasTextProbe = { true }
        XCTAssertTrue(GuiPastePlateMenu(model: model, store: store).canPasteCurrent)

        store.clipboardHasTextProbe = { false }
        XCTAssertFalse(
            GuiPastePlateMenu(model: model, store: store).canPasteCurrent,
            "nothing on the board and nothing in the ring ⇒ nothing to type",
        )
        XCTAssertEqual(contentReads, 0, "neither answer came from a content read")
    }

    /// A pane that cannot type is disabled whatever the clipboard holds — the other half of
    /// `ClipboardPasteMenu.canPaste`, mounted.
    func testAReadOnlyPaneIsDisabledEvenWithTextOnTheBoard() {
        let store = makeStore()
        store.clipboardHasTextProbe = { true }
        // No `open()`, no key sink: the read-only / not-streaming seam, which withholds the injector.
        let model = RemoteWindowModel(windowID: "42", title: "Remote window")
        XCTAssertFalse(model.canPasteKeystrokes)
        XCTAssertFalse(GuiPastePlateMenu(model: model, store: store).canPasteCurrent)
    }

    // MARK: - The ring submenu reads the RING, not the board

    /// The other thing the plate's body does is list recent clips, and that is a read of the app's OWN
    /// recorded history (`WorkspaceStore.clipboardRing`) rather than of the pasteboard — so it cannot
    /// prompt, and it stays in the body where it is. Asserted rather than assumed.
    func testTheClipboardRingSubmenuComesFromTheRingWithoutTouchingTheBoard() {
        let store = makeStore()
        var contentReads = 0
        store.clipboardTextProvider = {
            contentReads += 1
            return "live-clipboard"
        }
        store.clipboardHasTextProbe = { true }
        store.recordClip("older")
        store.recordClip("newest")

        render(GuiPastePlateMenu(model: makeTypingModel(), store: store))

        XCTAssertEqual(store.clipboardRing, ["newest", "older"], "the rows' source is the ring, untouched")
        XCTAssertEqual(contentReads, 0)
    }
}
#endif
