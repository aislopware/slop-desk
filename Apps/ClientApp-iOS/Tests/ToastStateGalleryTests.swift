// ToastStateGalleryTests — a VISUAL harness: renders the notification card in every state it can be in and
// dumps them as PNGs, so a design change can be judged on the artefact instead of on the code.
//
// Why a harness and not eyeballing the app: the hovered states are unreachable in a normal render —
// `ImageRenderer` never delivers a hover, so the at-rest card is the ONLY thing a naive snapshot can show.
// That is why ``ToastCardView`` seeds `hovering` through its init. The cards below are the SHIPPING view,
// not a mock of it. One state has NO appearance and so is absent by nature: the dwell freezing under the
// pointer is pure behaviour (nothing draws the time remaining).
//
// Headless (the hang-safety rule): no SCStream / VideoToolbox / Metal — `ImageRenderer` over pure SwiftUI is
// CPU rasterisation. The asserts are crash-free-render smoke; the VALUE is the opt-in PNG dump. docs/56 F4c
// put the rig in the iOS-triple bundle, where the view it photographs is compiled at all (`ToastCardView` is
// `SlopDeskPhoneUI`, `#if os(iOS)` end to end), so the dump runs through the simulator harness:
//
//     SIMCTL_CHILD_SLOPDESK_TOAST_GALLERY_DIR=/tmp/toast slopdesk-gate ios-tests
//
// The `SIMCTL_CHILD_` prefix is `simctl`'s: it forwards such a variable into the process it spawns inside
// the simulator with the prefix stripped, so the test reads the bare `SLOPDESK_TOAST_GALLERY_DIR` name it
// always read. The PNGs land on the HOST filesystem — the `xctest` agent is not app-sandboxed. `Slate` is
// `@testable`-imported below for its `package` design floor: this bundle is an Xcode target OUTSIDE the
// SwiftPM package, so a plain `import` cannot see `Slate.Surface` / `Slate.Text` at all.
//
// Every card is rendered over `Slate.Surface.face` — the PANE tone, which is where a notification actually
// appears. On a bare backdrop the card's separation from the terminal cannot be judged at all.
//
// ⚠️ The card's GLASS surface is a GPU backdrop effect that `ImageRenderer` cannot rasterise — these dumps
// judge layout, type and the status marks, NOT the surface. To judge the real card, run the app with
// `SLOPDESK_TOAST_DEMO=1` (a sticky demo stack) and photograph the window.

import SwiftUI
import UIKit
import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskPhoneUI
@testable import SlopDeskSlate

@MainActor
final class ToastStateGalleryTests: XCTestCase {
    // MARK: - The gallery groups

    /// Every (source, flavour) pair — the full headline vocabulary. This is the group that shows the
    /// round-21 split doing its job: the two `Claude` cards differ ONLY in flavour, and that turns the
    /// headline from "Claude needs input" to "Claude is done", while the two `make check` cards say
    /// "finished" / "failed".
    func testGalleryHeadlines() throws {
        try dump("1-headlines", captioned: [
            ("agent · attention → needs input, warn (amber)", card(.agent, .attention, "Claude", "slop-desk ▸ api")),
            ("agent · success → is done, ok", card(.agent, .success, "Claude", "refactor the reducer")),
            ("agent · error → failed, err", card(.agent, .error, "Claude", "turn failed")),
            ("agent · default → is working, neutral mark", card(.agent, .default, "Claude", "slop-desk ▸ api")),
            ("command · success → finished, ok", card(.command, .success, "make check", "exit 0 · 42s")),
            ("command · error → failed, err", card(.command, .error, "make check", "exit 1 · 42s")),
            (
                "command · default → title passthrough, neutral mark",
                card(.command, .default, "npm run dev", "listening on :3000"),
            ),
            (
                "command · attention → title passthrough, warn (amber)",
                card(.command, .attention, "cd'd on host", "may not exist there"),
            ),
            ("explicit headline (reconnect verdict)", reconnectCard()),
        ])
    }

    /// The one factory that overrides the derived headline — no flavour+title suffix encodes the verdict.
    private func reconnectCard() -> ToastCardView {
        ToastCardView(
            toast: Toast(
                id: "gallery.reconnect", flavor: .attention, source: .command,
                title: "Reconnected to a fresh shell", body: "The previous session ended",
                paneKey: UUID().uuidString, headline: "Reconnected to a fresh shell",
            ),
            expanded: true, onDismiss: {}, onJump: {},
        )
    }

    /// Rest vs hover, and the two stack tiers. Hovering does three things at once: reveals the ✕, expands a
    /// collapsed spine row to show the body it was holding back, and freezes the dwell — the third is
    /// behaviour with no appearance, so it is the one thing here a snapshot cannot show.
    func testGalleryInteraction() throws {
        try dump("2-interaction", captioned: [
            ("EXPANDED, at rest — no ✕", card(.agent, .attention, "Claude", "slop-desk ▸ api")),
            (
                "EXPANDED, HOVERED — ✕ revealed, dwell frozen",
                card(.agent, .attention, "Claude", "slop-desk ▸ api", hovering: true),
            ),
            (
                "COLLAPSED spine row, at rest — title only",
                card(.agent, .attention, "Claude", "slop-desk ▸ api", expanded: false),
            ),
            (
                "COLLAPSED, HOVERED — body revealed + ✕",
                card(.agent, .attention, "Claude", "slop-desk ▸ api", expanded: false, hovering: true),
            ),
            ("STICKY (autoDismiss nil) — ✕ unconditional", stickyCard()),
            (
                "no jump target (paneKey nil) — inert notice",
                card(.command, .error, "open on host", "/Users/x/nope", jumpable: false),
            ),
        ])
    }

    /// Content edges: the card is a fixed 320 column, so what happens to text that does not fit is a design
    /// decision, not an accident. A title loses its MIDDLE (a command line's program and last argument are
    /// the informative ends); a body wraps to two lines and then truncates.
    func testGalleryContent() throws {
        let longTitle = "docker compose -f ./deploy/compose.prod.yaml up --build --force-recreate api"
        let longBody = "listening on :3000 · watching 1284 files · press r to restart, u to open the inspector, q to quit"
        try dump("3-content", captioned: [
            ("no body at all", card(.command, .success, "make check", nil)),
            ("long title → MIDDLE truncated", card(.command, .default, longTitle, "exit 0 · 3s")),
            ("long body → wraps to 2 lines, then clips", card(.command, .default, "npm run dev", longBody)),
            ("both long", card(.command, .error, longTitle, longBody)),
            ("shortest possible", card(.agent, .success, "Claude", nil)),
        ])
    }

    /// The real stack, through the real host view: four deep ⇒ two collapsed spine rows above two full
    /// cards. This is the footprint claim — a burst costs about a third of the corner, not a blanket over
    /// the prompt line.
    func testGalleryStack() throws {
        let coordinator = OverlayCoordinator()
        coordinator.pushToast(Toast(
            id: "a",
            flavor: .default,
            source: .command,
            title: "npm run dev",
            body: "listening on :3000",
        ))
        coordinator.pushToast(Toast(
            id: "b",
            flavor: .success,
            source: .agent,
            title: "Claude",
            body: "refactor the reducer",
        ))
        coordinator.pushToast(Toast(
            id: "c",
            flavor: .error,
            source: .command,
            title: "make check",
            body: "exit 1 · 42s",
        ))
        coordinator.pushToast(Toast(
            id: "d",
            flavor: .attention,
            source: .agent,
            title: "Claude",
            body: "slop-desk ▸ api",
        ))

        try write(
            "4-stack",
            view: ToastStackView(coordinator: coordinator)
                .frame(width: 400, height: 300)
                .background(Slate.Surface.face),
        )
    }

    // MARK: - Card builders

    private func card(
        _ source: Toast.Source,
        _ flavor: Toast.Flavor,
        _ title: String,
        _ body: String?,
        expanded: Bool = true,
        hovering: Bool = false,
        jumpable: Bool = true,
    ) -> ToastCardView {
        ToastCardView(
            toast: Toast(
                id: "gallery.\(title).\(flavor.rawValue)",
                flavor: flavor,
                source: source,
                title: title,
                body: body,
                paneKey: jumpable ? UUID().uuidString : nil,
            ),
            expanded: expanded,
            onDismiss: {},
            onJump: jumpable ? {} : nil,
            hovering: hovering,
        )
    }

    /// A card with no auto-dismiss — the one case whose ✕ is unconditional, because it has no other exit
    /// (and iOS has no hover to reveal one with).
    private func stickyCard() -> ToastCardView {
        ToastCardView(
            toast: Toast(
                id: "gallery.sticky",
                flavor: .attention,
                source: .agent,
                title: "Claude",
                body: "slop-desk ▸ api",
                autoDismiss: nil,
                paneKey: UUID().uuidString,
            ),
            expanded: true,
            onDismiss: {},
            onJump: {},
        )
    }

    // MARK: - Rendering

    /// Lays the cards out in one captioned column and rasterises. The caption is harness chrome (system
    /// face, tertiary ink) so it never reads as part of a card.
    private func dump(_ name: String, captioned rows: [(String, ToastCardView)]) throws {
        let gallery = VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.0)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Slate.Text.tertiary)
                    row.1
                }
            }
        }
        .padding(24)
        .background(Slate.Surface.face)
        try write(name, view: gallery)
    }

    private func write(_ name: String, view: some View) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage, "\(name) renders without crashing")

        guard let dir = ProcessInfo.processInfo.environment["SLOPDESK_TOAST_GALLERY_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let png = image.pngData() else {
            XCTFail("\(name): ImageRenderer produced no PNG")
            return
        }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try png.write(to: url)
        print("SLOPDESK_TOAST_GALLERY_WROTE \(url.path)")
    }
}
