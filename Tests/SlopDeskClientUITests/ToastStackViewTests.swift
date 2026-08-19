// ToastStackViewTests — pins what the PHONE's toast column owns, which is now exactly two things: the
// rung → `Color` map (its view of the one ink ladder) and that the card stack renders headlessly.
//
// The headline, the spine budget, the mark's rung and glyph, and the dwell length left this file with
// the surface split (docs/56 stage D): they are the same on the Mac's `NSPanel`, so they are pinned
// below both in `ToastPresentationTests`. The model-level de-dupe / cap / dismiss stays in
// `OverlayCoordinatorMountTests`.
//
// Headless-only (per the hang-safety rule): no SCStream/VT/Metal — `ImageRenderer` of a pure SwiftUI view is
// CPU rasterisation (the same `SlateSnapshotRender` pattern the repo already uses in this target).

#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import SlopDeskSlate
import SwiftUI
import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskClientUI

@MainActor
final class ToastStackViewTests: XCTestCase {
    // MARK: - Rung → ink (this half's view of the one ladder)

    /// The four rungs must resolve to four DISTINCT `Color`s. Which rung a flavour takes is pinned once,
    /// below both platforms (`ToastPresentationTests`); what this pins is that the SwiftUI half does not
    /// collapse two of them back together on the way to the screen — the exact failure the old
    /// `.attention → accent` mapping had, where every seed's `info == accent` drew needs-input and a
    /// routine notice in the same cyan.
    func testEveryRungResolvesToItsOwnInk() {
        let rungs: [ToastMarkRung] = [.neutral, .ok, .warn, .err]
        for (index, a) in rungs.enumerated() {
            for b in rungs.dropFirst(index + 1) {
                XCTAssertNotEqual(
                    ToastStackView.ink(for: a), ToastStackView.ink(for: b),
                    "\(a) and \(b) must read as different inks",
                )
            }
        }
        XCTAssertEqual(ToastStackView.ink(for: .ok), Slate.Status.ok)
        XCTAssertEqual(ToastStackView.ink(for: .err), Slate.Status.err)
        XCTAssertEqual(
            ToastStackView.ink(for: .warn), Slate.Status.warn,
            "amber, matching the rail's 'a question waiting'; NOT the theme accent",
        )
        XCTAssertEqual(
            ToastStackView.ink(for: .neutral), SlateOverlayInk.secondary,
            "a routine notice wears the reading ink, never a hue",
        )
    }

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
        let image = try XCTUnwrap(renderer.nsImage, "ToastStackView renders all flavours without crashing")

        guard let out = ProcessInfo.processInfo.environment["SLOPDESK_TOAST_SNAPSHOT_OUT"] else { return }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            XCTFail("ImageRenderer produced no PNG")
            return
        }
        try png.write(to: URL(fileURLWithPath: out))
        print("SLOPDESK_TOAST_SNAPSHOT_WRITTEN \(out)")
    }
}
#endif
