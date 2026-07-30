// ToastStackViewTests — pins the toast host's view-level behaviour (the model-level de-dupe /
// cap / dismiss is pinned by `OverlayCoordinatorMountTests`). Two things this view owns that the coordinator
// does not: the flavour → tint mapping (the leading glyph colour) and that the card stack renders headlessly.
//
// Headless-only (per the hang-safety rule): no SCStream/VT/Metal — `ImageRenderer` of a pure SwiftUI view is
// CPU rasterisation (the same `SlateSnapshotRender` pattern the repo already uses in this target).

#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class ToastStackViewTests: XCTestCase {
    // MARK: - Flavour tint mapping (the leading-glyph colour role)

    /// The eyebrow ink per flavour: success → OK, error → error, default → info, attention → WARN.
    /// `.attention` is AMBER for rail parity — ``StatusDot`` already fixed "amber = a question waiting" — and
    /// the view + this test read the SAME `tint(for:)`, so the rendered colour cannot drift from the pin.
    func testToastFlavorTintMapping() {
        XCTAssertEqual(ToastStackView.tint(for: .success), Slate.Status.ok, "success → OK status tint")
        XCTAssertEqual(ToastStackView.tint(for: .error), Slate.Status.err, "error → error status tint")
        XCTAssertEqual(ToastStackView.tint(for: .default), Slate.Status.info, "default → info status tint")
        XCTAssertEqual(
            ToastStackView.tint(for: .attention), Slate.Status.warn,
            "attention → WARN (amber), matching the rail's 'a question waiting'; NOT the theme accent",
        )
    }

    /// All FOUR flavours must be pairwise distinct inks. This is the real invariant behind a flavour — a
    /// flavour that cannot be told apart from another conveys nothing — and it is the assertion the previous
    /// pin deliberately WITHHELD: `.attention` used to resolve to `Slate.State.accent`, and every Monokai
    /// seed sets `info == accent`, so needs-input and a routine notice rendered in the same cyan. Routing
    /// `.attention` to the status quartet's unused amber rung is what makes this hold.
    func testEveryFlavorInkIsDistinct() {
        let flavors: [Toast.Flavor] = [.default, .success, .error, .attention]
        for (i, a) in flavors.enumerated() {
            for b in flavors.dropFirst(i + 1) {
                XCTAssertNotEqual(
                    ToastStackView.tint(for: a), ToastStackView.tint(for: b),
                    "\(a.rawValue) and \(b.rawValue) must read as different inks",
                )
            }
        }
    }

    // MARK: - Eyebrow (WHO is speaking, said in words)

    /// The eyebrow is resolved from ``Toast/source`` and ``Toast/flavor`` TOGETHER, and this pins why: a
    /// `.success` toast says `DONE` when an agent finished its turn but `FINISHED` when a command exited 0.
    /// Flavour alone cannot tell those apart, so a resolver that keyed on it would announce a finished
    /// `make` as an agent turn — the same fusion bug `TabBadgeResolver` had (docs/DECISIONS.md round 21).
    func testEyebrowSplitsAgentFromCommand() {
        func eyebrow(_ source: Toast.Source, _ flavor: Toast.Flavor) -> String {
            ToastStackView.eyebrow(for: Toast(id: "x", flavor: flavor, source: source, title: "t"))
        }
        // Same flavour, two speakers, two DIFFERENT words — the whole point of carrying `source`.
        XCTAssertEqual(eyebrow(.agent, .success), "DONE")
        XCTAssertEqual(eyebrow(.command, .success), "FINISHED")
        XCTAssertNotEqual(
            eyebrow(.agent, .success), eyebrow(.command, .success),
            "an agent's finished turn and a command's clean exit must not read as the same event",
        )
        XCTAssertEqual(eyebrow(.agent, .attention), "NEEDS INPUT")
        XCTAssertEqual(eyebrow(.command, .default), "NOTICE")
        // An advisory is the one attention-flavour where nothing went WRONG (a host-resolved cwd).
        XCTAssertEqual(eyebrow(.command, .attention), "ADVISORY")
        // Every eyebrow is caps — the engraving register the DS reserves for micro-labels.
        for source in [Toast.Source.agent, .command] {
            for flavor in [Toast.Flavor.default, .success, .error, .attention] {
                let label = eyebrow(source, flavor)
                XCTAssertFalse(label.isEmpty, "every (source, flavour) pair must name an event")
                XCTAssertEqual(label, label.uppercased(), "\(label) must be caps")
            }
        }
    }

    /// A toast may carry its OWN eyebrow when it knows a truer word than the derivation can reach — the
    /// reconnect verdict is `REATTACHED` vs `RECONNECTED`, a distinction no flavour encodes. An explicit
    /// eyebrow must WIN over the derived one, and an empty one must fall back rather than render a blank.
    func testExplicitEyebrowOverridesTheDerivedOne() {
        let explicit = Toast(id: "x", flavor: .success, source: .command, title: "t", eyebrow: "REATTACHED")
        XCTAssertEqual(ToastStackView.eyebrow(for: explicit), "REATTACHED")
        let blank = Toast(id: "x", flavor: .success, source: .command, title: "t", eyebrow: "")
        XCTAssertEqual(ToastStackView.eyebrow(for: blank), "FINISHED", "an empty eyebrow falls back")
    }

    // MARK: - Stack spine (which cards speak in full)

    /// Only the NEWEST `expandedCount` cards carry a body + dwell track; older ones collapse to the
    /// one-line spine. Newest is LAST, so the expanded ones are at the END of the array.
    func testOnlyTheNewestCardsExpand() {
        XCTAssertTrue(ToastStackLayout.isExpanded(index: 3, count: 4), "the newest card speaks in full")
        XCTAssertTrue(ToastStackLayout.isExpanded(index: 2, count: 4), "so does the one before it")
        XCTAssertFalse(ToastStackLayout.isExpanded(index: 1, count: 4), "older cards collapse to the spine")
        XCTAssertFalse(ToastStackLayout.isExpanded(index: 0, count: 4), "the oldest most of all")
        // A stack shallower than the budget expands everything — no lone card is ever collapsed.
        XCTAssertTrue(ToastStackLayout.isExpanded(index: 0, count: 1))
        XCTAssertTrue(ToastStackLayout.isExpanded(index: 0, count: 2))
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
    /// Covers BOTH speakers (so the ring and the dot are both drawn) and BOTH stack tiers (4 cards ⇒ two
    /// collapsed spine rows above two full cards).
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
