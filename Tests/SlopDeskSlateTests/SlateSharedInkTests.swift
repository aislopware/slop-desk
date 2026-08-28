// SlateSharedInkTests — three name → ink/weight tables that moved down here in docs/56 batch 3, off a
// SwiftUI target whose test suite was about to stop running in `just check`.
//
// Each was a PURE answer sitting on a `View`'s own `static func` — reached only by hanging a `static`
// member off a view type, never by building the view — which is exactly the shape that suite could no
// longer carry once `SlopDeskClientUI` became iOS-only and its tests moved to a booted-simulator-only
// target. None of the three had anywhere BELOW `SlopDeskSlate` to land: each resolves to a COLOUR (or
// a font weight riding beside one), and colour is this floor's, one level above `SlopDeskClientCore` —
// the name each switches on (``ConnectionAlarm``, ``PaneStatusPillInk``, ``ToastMarkRung``) stays
// there, colour-free.
//
// Each also had an EXACT AppKit twin — ``MacConnectionIsland``'s `ink`/`weight`, ``MacPaneStatusPillView``'s
// `fillColor`, `MacToastMarkView`'s `ink` — the same switch, spelled a second time by hand.
// That is the duplicate `CLAUDE.md` bans, not a coincidence of two renderers agreeing: two independently
// maintained tables can drift (a third case added to one and not the other, or the same case resolved to
// different rungs), and nothing but eyeballing both files ever caught it. Collapsed into one switch here —
// ``Slate/Native/connectionAlarmInk(_:)`` and the rest, the same idiom ``Slate/Native/agentInk(_:)``
// already used — the drift is now a type the compiler forbids rather than a review someone has to
// remember to do. One switch, one `SlateNativeColor`, resolving to the renderer's own colour class.

import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskSlate

@MainActor
final class SlateSharedInkTests: XCTestCase {
    // MARK: - The connection alarm (``MacConnectionIsland``; the phone's `ConnectionPill` has no UIKit
    // successor yet)

    /// The island spends BRIGHTNESS and WEIGHT, never hue: `quiet` is the metadata grey every healthy
    /// reading rests in, `raised` steps up to the body-secondary ink at semibold, `loud` to the primary
    /// ink at bold. Three distinct rungs on BOTH channels — a rung that only moved one of them would be
    /// invisible on a theme whose greys sit close, or on a line already full of medium-weight type.
    func testConnectionAlarmClimbsBrightnessAndWeightTogether() {
        XCTAssertEqual(Slate.Native.connectionAlarmInk(.quiet), Slate.Native.Text.tertiary)
        XCTAssertEqual(Slate.Native.connectionAlarmInk(.raised), Slate.Native.Text.secondary)
        XCTAssertEqual(Slate.Native.connectionAlarmInk(.loud), Slate.Native.Text.primary)
        XCTAssertEqual(Slate.Native.connectionAlarmWeight(.quiet), .regular)
        XCTAssertEqual(Slate.Native.connectionAlarmWeight(.raised), .semibold)
        XCTAssertEqual(Slate.Native.connectionAlarmWeight(.loud), .bold)
        let inks = [ConnectionAlarm.quiet, .raised, .loud].map(Slate.Native.connectionAlarmInk)
        XCTAssertEqual(Set(inks).count, 3, "every rung is its own ink — no two states paint the same")
        for alarm in [ConnectionAlarm.quiet, .raised, .loud] {
            XCTAssertNotEqual(
                Slate.Native.connectionAlarmInk(alarm), Slate.Native.StatusInk.warn,
                "the island has no hue register — \(alarm) must not reach for a status colour",
            )
            XCTAssertNotEqual(Slate.Native.connectionAlarmInk(alarm), Slate.Native.StatusInk.err)
        }
    }

    // MARK: - The pane status pill's fill (``PaneStatusPillView`` / ``MacPaneStatusPillView``)

    /// The secure-input chip names the SECURITY ink, and it resolves to the fixed royal-blue token
    /// (#2D6FE8) — not the palette-derived info colour, and NOT the app accent. That collapse is the
    /// exact failure the fixed token exists for: `secure-input.png` is the green-accent Paper theme and
    /// the chip is still the same blue.
    func testSecureInputPillIsFixedBlueNotAccent() {
        XCTAssertEqual(
            PaneStatusPill.secureInput.fill, .fixed(.security),
            "the secure-input chip is filled by NAME, so an AppKit half reads the same decision",
        )
        XCTAssertEqual(
            Slate.Native.paneStatusPillFill(.security), Slate.Native.Status.secureInput,
            "the secure-input chip fills with the fixed security token, not a re-derived colour",
        )
        XCTAssertEqual(
            Slate.Native.Status.secureInput, SlateNativeColor(slateHex: 0x2D6FE8),
            "the fixed security token is pinned to the spec royal-blue #2D6FE8",
        )
        XCTAssertNotEqual(
            Slate.Native.paneStatusPillFill(.security), Slate.Native.State.accent,
            "the security chip must NOT read as the app accent (the purple that info collapses to)",
        )
        XCTAssertNotEqual(
            Slate.Native.paneStatusPillFill(.security), Slate.Native.Status.info,
            "the security chip is INDEPENDENT of the palette — distinct from the derived info colour",
        )
    }

    /// The sync-input chip is the same contract on the other fixed tone.
    func testSyncInputPillIsFixedAmberNotAccent() {
        XCTAssertEqual(PaneStatusPill.syncInput.fill, .fixed(.sync))
        XCTAssertEqual(Slate.Native.paneStatusPillFill(.sync), Slate.Native.Status.syncInput)
        XCTAssertNotEqual(Slate.Native.paneStatusPillFill(.sync), Slate.Native.State.accent)
        XCTAssertNotEqual(Slate.Native.paneStatusPillFill(.sync), Slate.Native.Status.info)
    }

    /// The two vivid tones are DISTINCT from each other. They are the app's two "this mode is
    /// dangerous" signals and they mean opposite things — one says your keystrokes are protected, the
    /// other says they are going somewhere else.
    func testTheTwoFixedPillTonesAreNotTheSameColour() {
        XCTAssertNotEqual(Slate.Native.paneStatusPillFill(.security), Slate.Native.paneStatusPillFill(.sync))
    }

    // MARK: - The toast mark's ink (``MacToastStack`` / ``PhoneToastStackView``)

    /// The four rungs must resolve to four DISTINCT inks — the exact failure the old
    /// `.attention → accent` mapping had, where every seed's `info == accent` drew needs-input and a
    /// routine notice in the same cyan. Which rung a flavour TAKES is pinned once, below both
    /// platforms (`ToastPresentationTests`); this pins that the rung → colour lookup itself does not
    /// collapse two of them back together.
    func testEveryToastRungResolvesToItsOwnInk() {
        let rungs: [ToastMarkRung] = [.neutral, .ok, .warn, .err]
        for (index, a) in rungs.enumerated() {
            for b in rungs.dropFirst(index + 1) {
                XCTAssertNotEqual(
                    Slate.Native.toastMarkInk(for: a), Slate.Native.toastMarkInk(for: b),
                    "\(a) and \(b) must read as different inks",
                )
            }
        }
        XCTAssertEqual(Slate.Native.toastMarkInk(for: .ok), Slate.Native.Status.ok)
        XCTAssertEqual(Slate.Native.toastMarkInk(for: .err), Slate.Native.Status.err)
        XCTAssertEqual(
            Slate.Native.toastMarkInk(for: .warn), Slate.Native.Status.warn,
            "amber, matching the rail's 'a question waiting'; NOT the theme accent",
        )
        XCTAssertEqual(
            Slate.Native.toastMarkInk(for: .neutral), Slate.Native.Overlay.secondary,
            "a routine notice wears the reading ink, never a hue",
        )
    }
}
