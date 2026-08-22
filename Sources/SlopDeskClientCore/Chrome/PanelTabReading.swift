// PanelTabReading — the RIGHT panel's tab row as VALUES: which tabs exist, what each is called, what
// it draws, and how many of them get to say their name at a given width.
//
// It exists because the four tabs were written TWICE — once across the panel's own strip and once
// down the rail the collapsed panel leaves behind — and the two lists had to agree on the mark, the
// word AND the help text of every surface. They are the same four tabs seen on two axes, exactly the
// way the tab list is the sidebar's rows seen on two axes, so they are cut once here and drawn by
// whoever is mounted.
//
// THE WIDTH LADDER IS ARITHMETIC HERE, not a `ViewThatFits`. Four tabs carrying a mark and a word want
// more room than a panel dragged to its minimum has, so the strip gives the words up a rung at a time
// — every tab named, then only the selected one, then none — rather than truncating, because a tab
// reading "Simulat…" has stopped saying what it switches to while a mark alone still says it. SwiftUI
// could ask that question by building all three candidates and measuring them; that cost a NAMESPACE
// PER RUNG (every candidate is built, so one namespace would put three copies of the travelling
// plate's geometry on screen at once). Said as arithmetic it is one answer, and both frameworks — and
// a test — can ask it without building anything.

import Foundation

/// What a panel tab draws before its label.
///
/// The split is NOT between a shape and a brand: `apple.logo` is a brand and takes the same em as
/// `folder`, because Apple's optical grid already makes them agree. The split is between a symbol on
/// that grid and the ONE mark no icon set ships — a drawn path with no grid behind it, which is why it
/// carries its own size (`Slate.Metric.androidMark`).
package enum PanelTabMark: Equatable, Sendable {
    /// An SF Symbol, by NAME — the two frameworks want different types out of it, and what the
    /// decision here is about is WHICH glyph, not how it is loaded.
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

    package init(surface: PanelSurface, mark: PanelTabMark, label: String, help: String) {
        self.surface = surface
        self.mark = mark
        self.label = label
        self.help = help
    }

    /// What a screen reader CALLS this tab. The word, never the sentence: a label is an identity and
    /// gets read on every focus change, so a tab whose label is the whole help text makes the reader
    /// listen to an explanation four times to find out where they are.
    ///
    /// The two shells had drifted to opposite answers — the Mac read `label`, the phone read `help` —
    /// which is the drift a shared reading exists to prevent. Cut here rather than in either renderer
    /// so there is one answer, and so the next surface added is described once.
    package var accessibilityLabel: String { label }

    /// The elaboration, offered AFTER the label. `help` minus the name it opens with, because the
    /// reader has just heard that name as the label and hearing it twice reads as a stutter. Every
    /// help string is written `Name — sentence`; one without the dash is already a bare sentence and
    /// is offered whole.
    package var accessibilityHint: String {
        guard let dash = help.range(of: " — ") else { return help }
        return String(help[dash.upperBound...])
    }
}

/// How many tabs get to say their name at the width the strip actually has.
package enum PanelTabLabelling: Equatable, Sendable {
    case all
    case selectedOnly
    case none
}

package enum PanelTabs {
    /// The four tabs, in their shipping order.
    ///
    /// Files and Simulators lead because they are the REAL host resources; Desktop trails because it
    /// is announced-but-empty. "Emulators" names the Android tab and the help text carries the rest —
    /// the surface also lists attached hardware, which no emulator is. Desktop's glyph is `display`,
    /// the app's existing GUI-surface vocabulary (`macwindow` read as a blob at strip size).
    package static let all: [PanelTabReading] = [
        PanelTabReading(
            // The FOLDER register, not a lone document — the tab opens the whole project tree.
            surface: .code, mark: .symbol("folder"), label: "Files",
            help: "Files — the project's embedded editor",
        ),
        PanelTabReading(
            surface: .simulators, mark: .symbol("apple.logo"), label: "Simulators",
            help: "Simulators — the host's iOS Simulator devices",
        ),
        PanelTabReading(
            surface: .android, mark: .android, label: "Emulators",
            help: "Emulators — the host's Android emulators and attached devices",
        ),
        PanelTabReading(
            surface: .desktop, mark: .symbol("display"), label: "Desktop",
            help: "Desktop — the host's window surface",
        ),
    ]

    /// Which rung of the width ladder a strip of `available` points can afford.
    ///
    /// `named` is what ONE named tab costs beyond its bare cell — the label's measured width plus the
    /// gap and the collar around it — asked of the caller because only the renderer can measure its
    /// own type. Everything else is this decision's: a bare cell is square, the tabs sit `gap` apart,
    /// and the rung is the widest one that still fits.
    package static func labelling(
        available: CGFloat, cell: CGFloat, gap: CGFloat, named: (PanelTabReading) -> CGFloat,
        selected: PanelSurface,
    ) -> PanelTabLabelling {
        let bare = cell * CGFloat(all.count) + gap * CGFloat(all.count - 1)
        let everyName = all.reduce(CGFloat.zero) { $0 + named($1) }
        if bare + everyName <= available { return .all }
        let oneName = all.first { $0.surface == selected }.map(named) ?? 0
        if bare + oneName <= available { return .selectedOnly }
        return .none
    }

    /// Whether `tab` says its name at this rung.
    package static func names(_ tab: PanelTabReading, at rung: PanelTabLabelling, selected: PanelSurface) -> Bool {
        switch rung {
        case .all: true
        case .selectedOnly: tab.surface == selected
        case .none: false
        }
    }
}
