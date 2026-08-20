// ToastStackViewTests — pins what the PHONE's toast column owns, which is now that the card stack
// renders headlessly.
//
// The rung → `Color` map left with docs/56 batch 3: `ToastStackView.ink(for:)` was a per-renderer
// table that resolved a name to a fixed token both halves already agreed on, and that resolution is
// now `Slate.toastMarkInk(for:)` itself (`SlateSharedInkTests`, `SlopDeskSlateTests`) — a shared
// function has nothing left for a UI half's test to pin.
//
// The headline, the spine budget, the mark's rung and glyph, and the dwell length left this file with
// the surface split (docs/56 stage D): they are the same on the Mac's `NSPanel`, so they are pinned
// below both in `ToastPresentationTests`. The model-level de-dupe / cap / dismiss stays in
// `OverlayCoordinatorMountTests`.
//
// Headless-only (per the hang-safety rule): no SCStream/VT/Metal — `ImageRenderer` of a pure SwiftUI view is
// CPU rasterisation (the same `SlateSnapshotRender` pattern the repo already uses in this bundle).
//
// docs/56 F4c: this rig lives in the iOS-triple bundle (`scripts/check-ios-tests.sh`) because the view it
// renders does — `ToastStackView` is `SlopDeskPhoneUI`, which is `#if os(iOS)` end to end. `Slate` is
// `@testable`-imported for its `package` design floor: this bundle is an Xcode target OUTSIDE the SwiftPM
// package, so a plain `import` cannot see `Slate.Surface` / `Slate.Text` at all.

import SwiftUI
import UIKit
import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskPhoneUI
@testable import SlopDeskSlate

@MainActor
final class ToastStackViewTests: XCTestCase {
    // MARK: - Dwell epoch (a same-id re-push must RESTART the dwell)

    /// A newer toast with the same id REPLACES the old one and takes a FRESH epoch. The card's dwell timer
    /// is keyed on the epoch, not the id — keyed on the id it would not re-fire (the id is unchanged), so
    /// the replacement would inherit the replaced toast's nearly-elapsed dwell and vanish almost at once.
    func testSameIDRepushTakesAFreshEpoch() {
        let coordinator = OverlayCoordinator()
        coordinator.pushToast(Toast(id: "pane.1", title: "first"))
        let firstEpoch = coordinator.toasts.first?.epoch
        coordinator.pushToast(Toast(id: "pane.1", title: "second"))
        XCTAssertEqual(coordinator.toasts.count, 1, "same id de-dupes to one card")
        XCTAssertEqual(coordinator.toasts.first?.title, "second", "the newer toast wins")
        XCTAssertNotEqual(
            coordinator.toasts.first?.epoch, firstEpoch,
            "the replacement must take a fresh epoch so its dwell timer restarts",
        )
    }

    // MARK: - Render smoke (eyeball-able via SLOPDESK_TOAST_SNAPSHOT_OUT env var)

    /// Renders the stack with one card of every flavour and asserts `ImageRenderer` produces a bitmap — a
    /// crash-free proof the card layout + every `tint(for:)` branch resolves under the live token layer. Opt-in
    /// file write (mirrors `SlateSnapshotRender`): set `SLOPDESK_TOAST_SNAPSHOT_OUT=<path.png>` to dump the PNG.
    /// Covers BOTH speakers and BOTH stack tiers (4 cards ⇒ two collapsed spine rows above two full
    /// cards). NOTE the card's glass surface is a GPU backdrop effect `ImageRenderer` cannot rasterise —
    /// this smoke proves layout + tint resolution, while the REAL surface is judged in the running app
    /// (`SLOPDESK_TOAST_DEMO=1` seeds a sticky demo stack for that).
    func testToastStackRenderSmoke() throws {
        let coordinator = OverlayCoordinator()
        coordinator.pushToast(Toast(
            id: "a", flavor: .default, source: .command, title: "npm run dev", body: "listening on :3000",
        ))
        coordinator.pushToast(Toast(
            id: "b", flavor: .success, source: .agent, title: "Claude", body: "finished — refactor the reducer",
        ))
        coordinator.pushToast(Toast(
            id: "c", flavor: .error, source: .command, title: "make check", body: "exit 1 · 42s",
        ))
        coordinator.pushToast(Toast(
            id: "d", flavor: .attention, source: .agent, title: "Claude", body: "needs your input",
        ))

        // Rendered over `Surface.face` — the PANE tone, which is where a notification actually appears. On a
        // bare/white backdrop the card's separation cannot be judged at all: the old `Surface.face` fill was
        // the exact tone of the terminal behind it, and only a face-toned backdrop makes that visible.
        let renderer = ImageRenderer(
            content: ToastStackView(coordinator: coordinator)
                .frame(width: 420, height: 360)
                .background(Slate.Surface.face),
        )
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage, "ToastStackView renders all flavours without crashing")

        guard let out = ProcessInfo.processInfo.environment["SLOPDESK_TOAST_SNAPSHOT_OUT"] else { return }
        guard let png = image.pngData() else {
            XCTFail("ImageRenderer produced no PNG")
            return
        }
        try png.write(to: URL(fileURLWithPath: out))
        print("SLOPDESK_TOAST_SNAPSHOT_WRITTEN \(out)")
    }
}
