// SidebarRowPresenceCutTests — pins that the phone's presence line is a CUT of the Mac's tooltip and
// not a second reading of the same fan-out.
//
// The multiclient pair ("Also open on <device>" / "Held by <device>") is the one thing in
// `SidebarRowTooltip.text` that appears nowhere else on a row, and the phone — the device most likely
// to BE that second client — had no pointer to hover it out of. Increment 85 gave it
// `SidebarRowReading.presence`, a second SPENDING of `presenceLines(viewers:holders:)`, which the
// tooltip splices verbatim.
//
// So the property under test is not "the strings are right" (`SidebarRowTooltipTests` already pins
// those inside the tooltip) — it is that there is ONE writer. A future edit that teaches the phone to
// say "shared with" while the Mac still says "Held by" is a disagreement about the workspace rather
// than about a layout, and it fails here rather than on somebody's second device.

import XCTest
@testable import SlopDeskClientCore

final class SidebarRowPresenceCutTests: XCTestCase {
    // MARK: - The lines themselves

    /// VIEWING and HOLDING are different facts and both surfaces say both, viewing first — it is the
    /// softer claim (a client can be looking at a pane it does not hold).
    func testViewingIsWrittenBeforeHolding() {
        XCTAssertEqual(
            SidebarRowTooltip.presenceLines(viewers: ["iPad"], holders: ["mac-studio"]),
            ["Also open on iPad", "Held by mac-studio"],
        )
    }

    /// Several devices read as a list — two Macs and a phone on one nvim is the whole point of the
    /// fan-out, so neither surface may name only the first.
    func testSeveralDevicesJoinWithCommas() {
        XCTAssertEqual(
            SidebarRowTooltip.presenceLines(viewers: [], holders: ["mac-studio", "macbook-pro"]),
            ["Held by mac-studio, macbook-pro"],
        )
    }

    /// The common case — this client alone — writes NO line, so a row grows nothing rather than an
    /// empty one.
    func testAloneWritesNothing() {
        XCTAssertTrue(SidebarRowTooltip.presenceLines(viewers: [], holders: []).isEmpty)
        XCTAssertNil(SidebarRowTooltip.presence(viewers: [], holders: []))
    }

    // MARK: - The one line the phone spends

    /// The phone lands this UNDER a row title, where the tooltip has a popover's worth of rows: one
    /// line, the lines joined by the separator that reads as "and also".
    func testPresenceJoinsBothLinesOntoOne() {
        XCTAssertEqual(
            SidebarRowTooltip.presence(viewers: ["iPad"], holders: ["mac-studio"]),
            "Also open on iPad · Held by mac-studio",
        )
    }

    /// One fact alone takes no separator — a trailing ` · ` would read as a run that failed to render.
    func testOneFactCarriesNoSeparator() {
        XCTAssertEqual(SidebarRowTooltip.presence(viewers: ["iPad"], holders: []), "Also open on iPad")
    }

    // MARK: - The cut

    /// THE INVARIANT: every line the phone prints appears VERBATIM in the tooltip the Mac hovers.
    /// Both spellings come off `presenceLines`, so this can only fail if someone re-derives one of
    /// them — which is exactly the failure worth a test.
    func testEveryPresenceLineAppearsVerbatimInTheTooltip() {
        let viewers = ["iPad", "macbook-pro"]
        let holders = ["mac-studio"]
        let tooltip = SidebarRowTooltip.text(
            cwd: "/Users/me/project", detail: nil, lastCommand: nil,
            viewers: viewers, holders: holders,
        )
        let tooltipLines = (tooltip ?? "").split(separator: "\n").map(String.init)
        for line in SidebarRowTooltip.presenceLines(viewers: viewers, holders: holders) {
            XCTAssertTrue(tooltipLines.contains(line), "the tooltip lost the presence line '\(line)'")
        }
    }

    /// And the tooltip keeps them LAST, after the cwd / readout / last-command parts it already had —
    /// the pair is the newest fact on the row, not a re-heading of it.
    func testPresenceLinesLandAfterTheTooltipsOwnParts() {
        let tooltip = SidebarRowTooltip.text(
            cwd: "/Users/me/project",
            detail: "Allow edit to Config.swift?",
            lastCommand: "make check · 1.3s · exit 0",
            viewers: ["iPad"],
            holders: ["mac-studio"],
        )
        XCTAssertEqual(tooltip, """
        /Users/me/project
        Allow edit to Config.swift?
        make check · 1.3s · exit 0
        Also open on iPad
        Held by mac-studio
        """)
    }

    /// An EMPTY leading part still drops out with the presence lines appended — the two assemblies
    /// compose rather than one of them re-introducing the `Optional(...)`/blank-line class the
    /// tooltip's unwrap exists to prevent.
    func testEmptyLeadingPartsStillDropWithPresenceAppended() {
        let tooltip = SidebarRowTooltip.text(
            cwd: "", detail: nil, lastCommand: "", viewers: [], holders: ["mac-studio"],
        )
        XCTAssertEqual(tooltip, "Held by mac-studio")
    }
}
