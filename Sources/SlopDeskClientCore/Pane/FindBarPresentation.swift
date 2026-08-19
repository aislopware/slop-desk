// FindBarPresentation — what the in-pane ⌘F find bar SAYS and how big it is, for both of the halves
// that will draw it.
//
// The bar's behaviour was already below the view (``TerminalFindBarModel`` beside this file); what was
// still spelled at the call site was everything the user actually reads — the field's placeholder, the
// four tooltips, the `N of M` counter's three-way rule — plus its measurements, which were chosen by a
// `#if os(iOS)` INSIDE the view. docs/56 §3 names that gate a smell: a platform branch in a view file
// says the numbers belong to the platform, when what they belong to is the POINTER. A finger wants a
// 34pt plate and a 200pt field whether it is on a phone or on an iPad; a mouse wants the chrome
// ladder's 24 and 130 whether the Mac is drawing AppKit or the simulator is drawing SwiftUI. So the
// rungs are asked for BY NAME here, and each renderer picks the one its input device earns.
//
// ⚠️ ONE NUMBER IS RESTATED AND IT IS DELIBERATE. ``FindBarMetrics/pointer``'s `plate` and `iconSize`
// are `Slate.Metric.plate` (24) and `Slate.Metric.iconSize` (13) written out. They cannot be READ from
// there: `SlopDeskSlate` depends on THIS target, so the token floor sits above it and an import would
// invert the layer graph. The alternative — leaving the two rungs nil and letting each renderer fall
// back to its own ladder — is the `#if` again with extra steps, because then the phone's numbers are
// values and the Mac's are not, and only one of the two is reviewable here.

import Foundation

// MARK: - The bar's words

/// Every string the find bar prints that is not the user's own query.
package enum FindBarPresentation {
    /// The query field's placeholder — the one word the bar shows before anything is typed.
    package static let placeholder = "Find"

    /// The `∧` chevron's tooltip.
    package static let previousMatchHelp = "Previous match (⇧⌘G)"
    /// The `∨` chevron's tooltip.
    package static let nextMatchHelp = "Next match (⌘G)"
    /// The `rectangle.stack` escalation's tooltip — the in-pane find handing over to cross-tab search.
    package static let searchAllTabsHelp = "Search all tabs (⇧⌘F)"
    /// The `×` plate's tooltip.
    package static let closeHelp = "Close (Esc)"

    /// The three mode chips the IN-PANE bar offers, in their drawn order.
    ///
    /// The counter: `N of M` when a match is selected, a muted verdict when the query matched nothing,
    /// and NOTHING at all under an empty field.
    ///
    /// The third branch is the one worth having as a rule rather than as an `if` in a body: "No results"
    /// under an empty field would report a failure nobody asked for — the same distinction
    /// ``GlobalSearchPresentation/emptyStateLine(query:)`` draws for the cross-tab surface.
    ///
    /// `position` is ``TerminalSearchController/positionLabel`` passed straight through, so the counter
    /// can never disagree with the engine about which match is current.
    package static func counterText(position: (current: Int, total: Int)?, query: String) -> String? {
        if let position { return "\(position.current) of \(position.total)" }
        return query.isEmpty ? nil : "No results"
    }
}

// MARK: - The bar's measurements

/// One rung of the find bar's sizing ladder: the square plate every control stands on, the glyph inside
/// it, and the query field's fixed width.
///
/// The field is FIXED rather than flexible on purpose — the bar floats over live terminal output, and a
/// field that grew with the pane would move the counter and the chevrons under the pointer every time
/// the split moved.
package struct FindBarRung: Equatable, Sendable {
    /// The square hit plate each control (chevron, escalation, close) occupies.
    package let plate: Double
    /// The glyph drawn inside that plate.
    package let iconSize: Double
    /// The query field's width.
    package let fieldWidth: Double

    package init(plate: Double, iconSize: Double, fieldWidth: Double) {
        self.plate = plate
        self.iconSize = iconSize
        self.fieldWidth = fieldWidth
    }
}

/// The two rungs, named by the INPUT DEVICE rather than by the platform (see the file header).
package enum FindBarMetrics {
    /// A MOUSE drives the bar: the chrome ladder's control plate and icon, and a field sized to the
    /// compact card `find.png` shows.
    ///
    /// The two numbers restate `Slate.Metric.plate` and `Slate.Metric.iconSize`, which this target sits
    /// below and cannot import — see the file header for why that is deliberate rather than a leak.
    package static let pointer = FindBarRung(plate: 24, iconSize: 13, fieldWidth: 130)

    /// A FINGER drives the bar: a plate big enough to hit and a field wide enough to read a query in
    /// over a software keyboard. A touch surface is a TARGET before it is a plate.
    package static let touch = FindBarRung(plate: 34, iconSize: 16, fieldWidth: 200)
}

// MARK: - The mode chip's appearance

/// What an `Aa` / `ab` / `.*` chip LOOKS like, as one verdict over its two inputs.
///
/// ⚠️ It exists because the table was spelled TWICE — once in the SwiftUI ``FindTogglePill`` and once in
/// `SlopDeskMacUI`'s `MacFindTogglePillView`, each deriving a plate, a ring and an ink from `isOn` and
/// `hovering` independently. That is one appearance rule in two languages, and the locked invariant it
/// has to keep ("the find bar and the global-search query bar render the pills IDENTICALLY") could not
/// survive it: a hover plate changed on one side reads as correct on both until someone puts the two
/// surfaces side by side.
///
/// The verdict is SEMANTIC, never a colour: each renderer maps the three cases to its own three tokens,
/// which is the same "one value, two ink ladders" split ``ToastPresentation`` already uses.
package enum FindTogglePillAppearance: Equatable, Sendable {
    /// Off, and the pointer is elsewhere: the chip's own resting plate and a hairline. Never a bare
    /// glyph — every idle chip is DELINEATED (the locked rendering).
    case idle
    /// Off, pointer over it: the hover plate, hairline held.
    case hovering
    /// On: accent ink on the accent wash, with the accent ring in place of the hairline.
    case on

    /// ON outranks HOVER, because a chip that lost its accent while the pointer sat on it would read as
    /// having been switched off by the hover itself.
    package static func resolve(isOn: Bool, hovering: Bool) -> Self {
        if isOn { return .on }
        return hovering ? .hovering : .idle
    }
}
