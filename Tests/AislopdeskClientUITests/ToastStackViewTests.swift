// ToastStackViewTests — pins the E2 / WI-4 toast host's view-level behaviour (the model-level de-dupe /
// cap / dismiss is pinned by `OverlayCoordinatorMountTests`). Two things this view owns that the coordinator
// does not: the flavour → tint mapping (the leading glyph colour) and that the card stack renders headlessly.
//
// Headless-only (per the hang-safety rule): no SCStream/VT/Metal — `ImageRenderer` of a pure SwiftUI view is
// CPU rasterisation (the same `SlateSnapshotRender` pattern the repo already uses in this target).

#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
@testable import AislopdeskClientUI

@MainActor
final class ToastStackViewTests: XCTestCase {
    // MARK: - Flavour tint mapping (the leading-glyph colour role)

    /// The toast glyph is tinted by flavour: success → OK, error → error, default → info, attention → accent
    /// (E2 plan WI-4). Pin the SPEC mapping — a regression that swapped success/error (or pointed a flavour at
    /// the wrong status role) would fail here, and the view + this test read the SAME `tint(for:)` so the
    /// rendered colour can't drift from the asserted contract. (Distinctness is asserted only for OK vs error,
    /// which are distinct hues in every theme; default/attention coincide under the Monokai Classic palette
    /// where `info == accent`, so they are NOT asserted distinct.)
    func testToastFlavorTintMapping() {
        XCTAssertEqual(ToastStackView.tint(for: .success), Slate.Status.ok, "success → OK status tint")
        XCTAssertEqual(ToastStackView.tint(for: .error), Slate.Status.err, "error → error status tint")
        XCTAssertEqual(ToastStackView.tint(for: .default), Slate.Status.info, "default → info status tint")
        XCTAssertEqual(ToastStackView.tint(for: .attention), Slate.State.accent, "attention → active accent")
        XCTAssertNotEqual(
            ToastStackView.tint(for: .success),
            ToastStackView.tint(for: .error),
            "success and error must read as visually distinct status tints",
        )
    }

    // MARK: - Render smoke (eyeball-able via AISLOPDESK_TOAST_SNAPSHOT_OUT env var)

    /// Renders the stack with one card of every flavour and asserts `ImageRenderer` produces a bitmap — a
    /// crash-free proof the card layout + every `tint(for:)` branch resolves under the live token layer. Opt-in
    /// file write (mirrors `SlateSnapshotRender`): set `AISLOPDESK_TOAST_SNAPSHOT_OUT=<path.png>` to dump the PNG.
    func testToastStackRenderSmoke() throws {
        let coordinator = OverlayCoordinator()
        coordinator.pushToast(Toast(id: "a", flavor: .default, title: "Build started", body: "swift build"))
        coordinator.pushToast(Toast(id: "b", flavor: .success, title: "Build finished", body: "0 errors"))
        coordinator.pushToast(Toast(id: "c", flavor: .error, title: "Tests failed", body: "3 failures"))
        coordinator.pushToast(Toast(id: "d", flavor: .attention, title: "Agent needs input"))

        let renderer = ImageRenderer(
            content: ToastStackView(coordinator: coordinator).frame(width: 420, height: 360),
        )
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "ToastStackView renders all flavours without crashing")

        guard let out = ProcessInfo.processInfo.environment["AISLOPDESK_TOAST_SNAPSHOT_OUT"] else { return }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            XCTFail("ImageRenderer produced no PNG")
            return
        }
        try png.write(to: URL(fileURLWithPath: out))
        print("AISLOPDESK_TOAST_SNAPSHOT_WRITTEN \(out)")
    }
}
#endif
