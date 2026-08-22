// PanelTabsTests — the RIGHT panel's tab row as values: the four tabs, and the width ladder that
// decides how many of them get to say their name.
//
// The ladder is the part worth pinning. It used to be a SwiftUI `ViewThatFits` — three candidate rows
// built and measured — which no test could ask a question of without mounting a view; said as
// arithmetic it answers to a width and a measuring closure, so the rungs and, more importantly, the
// BOUNDARIES between them are pinned here rather than photographed.

import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientCore

final class PanelTabsTests: XCTestCase {
    // The strip's real numbers, so the arithmetic is exercised at the scale it ships at.
    private let cell: CGFloat = 24
    private let gap: CGFloat = 4
    /// A bare row: four square cells and three gaps.
    private var bare: CGFloat { cell * 4 + gap * 3 }

    /// What each label costs beyond its bare cell — the four words are different lengths, which is the
    /// whole reason `selectedOnly` is a rung rather than a coin flip.
    private static let cost: [PanelSurface: CGFloat] = [
        .code: 30, .simulators: 68, .android: 62, .desktop: 48,
    ]
    private func named(_ tab: PanelTabReading) -> CGFloat { Self.cost[tab.surface] ?? 0 }

    private func rung(_ available: CGFloat, selected: PanelSurface = .code) -> PanelTabLabelling {
        PanelTabs.labelling(
            available: available, cell: cell, gap: gap, named: named, selected: selected,
        )
    }

    // MARK: The four tabs

    func testFourTabsInShippingOrder() {
        XCTAssertEqual(PanelTabs.all.map(\.surface), [.code, .simulators, .android, .desktop])
        XCTAssertEqual(PanelTabs.all.map(\.label), ["Files", "Simulators", "Emulators", "Desktop"])
    }

    func testEverySurfaceHasExactlyOneTab() {
        // The tabs are the switch over `PanelSurface`, so a surface added without a tab is a surface
        // nothing can reach and a second tab for one surface is two plates claiming one selection.
        XCTAssertEqual(Set(PanelTabs.all.map(\.surface)), Set(PanelSurface.allCases))
        XCTAssertEqual(PanelTabs.all.count, PanelSurface.allCases.count)
    }

    func testEveryTabHelpLeadsWithItsOwnLabel() {
        // The tooltip is the label plus what it means — "Files — the project's embedded editor".
        for tab in PanelTabs.all {
            XCTAssertTrue(
                tab.help.hasPrefix("\(tab.label) — "), "\(tab.label)'s help drifted: \(tab.help)",
            )
        }
    }

    func testTheAndroidTabIsTheOneDrawnMark() {
        // Everything else rides Apple's optical grid; the head is the one path with no grid behind it.
        let drawn = PanelTabs.all.filter { $0.mark == .android }
        XCTAssertEqual(drawn.map(\.surface), [.android])
    }

    // MARK: The ladder

    func testWideStripNamesEveryTab() {
        XCTAssertEqual(rung(bare + Self.cost.values.reduce(0, +)), .all)
        XCTAssertEqual(rung(2000), .all)
    }

    func testEveryNameFitsExactlyIsStillEveryName() {
        // The rung is the WIDEST that still fits, and "fits" is inclusive: a row measured to the point
        // must not drop a word for the one pixel it does not need.
        XCTAssertEqual(rung(bare + Self.cost.values.reduce(0, +)), .all)
        XCTAssertEqual(rung(bare + Self.cost.values.reduce(0, +) - 0.5), .selectedOnly)
    }

    func testOneNameShortOfEveryNameKeepsTheSelectedOne() {
        XCTAssertEqual(rung(bare + Self.cost[.code]!), .selectedOnly)
        XCTAssertEqual(rung(bare + Self.cost[.code]! - 0.5), .none)
    }

    func testTheSELECTEDTabIsTheOneMeasuredOnTheMiddleRung() {
        // A width that affords "Emulators" (62) does not afford "Simulators" (68), so which tab is
        // selected decides whether the middle rung is reachable at all. Measuring the widest label
        // instead — or the first — would drop a word the strip could have kept.
        let width = bare + 64
        XCTAssertEqual(rung(width, selected: .android), .selectedOnly)
        XCTAssertEqual(rung(width, selected: .simulators), .none)
    }

    func testNarrowStripNamesNothing() {
        XCTAssertEqual(rung(bare), .none)
        XCTAssertEqual(rung(0), .none)
        // Negative is reachable: the trailing plates are subtracted before the ladder is asked, and a
        // panel dragged below their cost hands it a width in the red.
        XCTAssertEqual(rung(-200), .none)
    }

    // MARK: Which tab says its name

    func testNamesAtEachRung() {
        let files = PanelTabs.all[0]
        let simulators = PanelTabs.all[1]
        XCTAssertTrue(PanelTabs.names(files, at: .all, selected: .code))
        XCTAssertTrue(PanelTabs.names(simulators, at: .all, selected: .code))
        XCTAssertTrue(PanelTabs.names(files, at: .selectedOnly, selected: .code))
        XCTAssertFalse(PanelTabs.names(simulators, at: .selectedOnly, selected: .code))
        XCTAssertFalse(PanelTabs.names(files, at: .none, selected: .code))
        XCTAssertFalse(PanelTabs.names(simulators, at: .none, selected: .code))
    }

    // MARK: What a screen reader hears

    /// The label is the WORD. A tab is focused far more often than it is explained, and a label is
    /// what gets read on every focus change — so the sentence is a hint, not an identity. (The phone
    /// read `help` as its label until this reading existed; the Mac read `label`. One answer now.)
    func testAccessibilityLabelIsTheWord() {
        XCTAssertEqual(
            PanelTabs.all.map(\.accessibilityLabel), ["Files", "Simulators", "Emulators", "Desktop"],
        )
    }

    /// The hint drops the name the help text opens with — the reader has just heard it as the label.
    func testAccessibilityHintDropsTheLeadingName() {
        XCTAssertEqual(
            PanelTabs.all.map(\.accessibilityHint),
            [
                "the project's embedded editor",
                "the host's iOS Simulator devices",
                "the host's Android emulators and attached devices",
                "the host's window surface",
            ],
        )
    }

    /// A help string with no `Name — ` opening is already a bare sentence and is offered whole,
    /// rather than being truncated by a split that did not find its separator.
    func testAccessibilityHintToleratesAHelpWithNoDash() {
        let tab = PanelTabReading(
            surface: .desktop, mark: .symbol("display"), label: "Desktop", help: "No dash here",
        )
        XCTAssertEqual(tab.accessibilityHint, "No dash here")
    }
}
