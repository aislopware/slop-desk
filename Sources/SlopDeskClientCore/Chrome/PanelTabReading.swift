// PanelTabReading — the near-side FACE of `slopdesk_workspace::panel_tabs`.
//
// The four tabs were written TWICE — once across the panel's own strip and once down the rail the
// collapsed panel leaves behind — and the two lists had to agree on the mark, the word AND the help
// text of every surface. They are the same four tabs seen on two axes, exactly the way the tab list is
// the sidebar's rows seen on two axes, so they are cut once on the far side and drawn by whoever is
// mounted.
//
// THE WIDTH LADDER IS ARITHMETIC, not a `ViewThatFits`. Four tabs carrying a mark and a word want more
// room than a panel dragged to its minimum has, so the strip gives the words up a rung at a time —
// every tab named, then only the selected one, then none — rather than truncating, because a tab
// reading "Simulat…" has stopped saying what it switches to while a mark alone still says it. SwiftUI
// could ask that question by building all three candidates and measuring them; that cost a NAMESPACE
// PER RUNG. Said as arithmetic it is one answer: the renderer MEASURES, the shared rule DECIDES.
//
// A MARK IS A KIND, NOT A GLYPH. `apple.logo` is a brand and takes the same em as `folder`, because
// Apple's optical grid already makes them agree; the ONE mark no icon set ships is a drawn path with
// no grid behind it, so it crosses as its own code with no name beside it rather than as a name the
// near side would have to recognise as a sentinel.

import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

/// What a panel tab draws before its label.
package enum PanelTabMark: Equatable, Sendable {
    /// An SF Symbol, by NAME — the two frameworks want different types out of it, and what the
    /// decision is about is WHICH glyph, not how it is loaded.
    case symbol(String)
    case android
}

/// One tab of the right panel: the surface it selects, the mark that identifies it, the word that
/// names it, and the sentence the pointer gets.
package struct PanelTabReading: Equatable, Sendable {
    package let surface: PanelSurface
    package let mark: PanelTabMark
    package let label: String
    package let help: String

    /// The elaboration, offered AFTER the label. `help` minus the name it opens with, because the
    /// reader has just heard that name as the label and hearing it twice reads as a stutter. Cut on
    /// the far side, so the rule about the dash lives with the strings it is about.
    package let accessibilityHint: String

    package init(
        surface: PanelSurface,
        mark: PanelTabMark,
        label: String,
        help: String,
        accessibilityHint: String? = nil,
    ) {
        self.surface = surface
        self.mark = mark
        self.label = label
        self.help = help
        self.accessibilityHint = accessibilityHint ?? help
    }

    /// What a screen reader CALLS this tab. The word, never the sentence: a label is an identity and
    /// gets read on every focus change, so a tab whose label is the whole help text makes the reader
    /// listen to an explanation four times to find out where they are.
    ///
    /// The two shells had drifted to opposite answers — the Mac read `label`, the phone read `help` —
    /// which is the drift a shared reading exists to prevent.
    package var accessibilityLabel: String { label }
}

/// How many tabs get to say their name at the width the strip actually has.
package enum PanelTabLabelling: Equatable, Sendable {
    case all
    case selectedOnly
    case none

    /// The rung `code` names; anything past the end is the one that always fits.
    init(code: UInt8) {
        switch code {
        case 0: self = .all
        case 1: self = .selectedOnly
        default: self = .none
        }
    }

    /// The byte the per-tab question reads this rung as.
    var code: UInt8 {
        switch self {
        case .all: 0
        case .selectedOnly: 1
        case .none: 2
        }
    }
}

private extension PanelSurface {
    /// The surface's own index, which is what every panel-tab door speaks in.
    var index: UInt8 {
        switch self {
        case .code: 0
        case .simulators: 1
        case .android: 2
        case .desktop: 3
        }
    }
}

package enum PanelTabs {
    /// The four tabs, in their shipping order.
    ///
    /// Files and Simulators lead because they are the REAL host resources; Desktop trails because it
    /// is announced-but-empty. Four crossings, once per process — the strip re-renders on every drag
    /// of the panel's divider.
    package static let all: [PanelTabReading] = PanelSurface.allCases.compactMap(tab(for:))

    /// One tab's delivery: `[u8 mark]` then four runs — symbol name, label, help, accessibility hint.
    ///
    /// `nil` for §4's `0`, which cannot happen from ``PanelSurface/allCases``: every case has a tab.
    private static func tab(for surface: PanelSurface) -> PanelTabReading? {
        let blob = wsAnswerBytes { out, cap in Int(slopdesk_ws_panel_tab(surface.index, out, cap)) }
        guard let mark = blob.first else { return nil }
        let text = wsRuns(Array(blob.dropFirst()), count: 4)
        return PanelTabReading(
            surface: surface,
            // The drawn mark carries no symbol name, which is what makes it a KIND rather than a
            // sentinel string this side would have to recognise.
            mark: mark == 1 ? .android : .symbol(text[0]),
            label: text[1],
            help: text[2],
            accessibilityHint: text[3],
        )
    }

    /// Which rung of the width ladder a strip of `available` points can afford.
    ///
    /// `named` is what ONE named tab costs beyond its bare cell — the label's measured width plus the
    /// gap and the collar around it — asked of the caller because only the renderer can measure its
    /// own type. Everything else is the shared rule's: a bare cell is square, the tabs sit `gap`
    /// apart, and the rung is the widest one that still fits.
    package static func labelling(
        available: CGFloat, cell: CGFloat, gap: CGFloat, named: (PanelTabReading) -> CGFloat,
        selected: PanelSurface,
    ) -> PanelTabLabelling {
        let widths = all.map { Double(named($0)) }
        let code = widths.withUnsafeBufferPointer { measured in
            slopdesk_ws_panel_tab_labelling(
                Double(available), Double(cell), Double(gap), measured.baseAddress, measured.count,
                selected.index,
            )
        }
        return PanelTabLabelling(code: code)
    }

    /// Whether `tab` says its name at this rung.
    ///
    /// Asked once per tab against a rung asked once per strip: the expensive question happens on
    /// layout, the cheap one where the answer is used.
    package static func names(_ tab: PanelTabReading, at rung: PanelTabLabelling, selected: PanelSurface) -> Bool {
        slopdesk_ws_panel_tab_names(rung.code, tab.surface.index, selected.index)
    }
}
