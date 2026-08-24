// FindBarPresentation — the near-side FACE of `slopdesk_workspace::find_bar`.
//
// The bar's behaviour was already below the view (``TerminalFindBarModel`` beside this file); what was
// still spelled at the call site was everything the user actually reads — the field's placeholder, the
// four tooltips, the `N of M` counter's three-way rule — plus its measurements, which were chosen by a
// `#if os(iOS)` INSIDE the view. docs/56 §3 names that gate a smell: a platform branch in a view file
// says the numbers belong to the platform, when what they belong to is the POINTER. A finger wants a
// 34pt plate and a 200pt field whether it is on a phone or on an iPad; a mouse wants the chrome
// ladder's 24 and 130 whether the Mac is drawing AppKit or the simulator is drawing SwiftUI. So the
// rungs are asked for BY INPUT CLASS, and each renderer picks the one its input device earns.
//
// The rung crosses BY VALUE — three doubles with no interior, in one `struct` — rather than as three
// doors, because a caller that asked for them one at a time could pair a touch plate with a pointer
// field. That is `docs/55` §6's by-value shape, on `CDwellGate`'s argument.
//
// The appearance verdict is SEMANTIC, never a colour: each renderer maps the three cases to its own
// three tokens, which is the same "one value, two ink ladders" split ``ToastPresentation`` uses.

import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

// MARK: - The bar's words

/// Every string the find bar prints that is not the user's own query.
package enum FindBarPresentation {
    /// The query field's placeholder — the one word the bar shows before anything is typed.
    package static var placeholder: String { words[0] }

    /// The `∧` chevron's tooltip.
    package static var previousMatchHelp: String { words[1] }
    /// The `∨` chevron's tooltip.
    package static var nextMatchHelp: String { words[2] }
    /// The `rectangle.stack` escalation's tooltip — the in-pane find handing over to cross-tab search.
    package static var searchAllTabsHelp: String { words[3] }
    /// The `×` plate's tooltip.
    package static var closeHelp: String { words[4] }

    /// The five fixed words, in ONE crossing, once per process. A bar that is mounted wants all five.
    private static let words: [String] = wsRuns(
        wsAnswerBytes { out, cap in Int(slopdesk_ws_find_bar_words(out, cap)) },
        count: 5,
    )

    /// The counter beside the field.
    ///
    /// `N of M` when a match is selected, a muted verdict when the query matched nothing, and NOTHING
    /// at all under an empty field. The third branch is the one worth having as a rule rather than as
    /// an `if` in a body: "No results" under an empty field would report a failure nobody asked for —
    /// the same distinction ``GlobalSearchPresentation/emptyStateLine(query:)`` draws for the
    /// cross-tab surface.
    ///
    /// `position` is ``TerminalSearchController/positionLabel`` passed straight through, so the counter
    /// can never disagree with the engine about which match is current.
    package static func counterText(position: (current: Int, total: Int)?, query: String) -> String? {
        let bytes = Array(query.utf8)
        let blob = bytes.withUnsafeBufferPointer { borrowed in
            wsAnswerBytes { out, cap in
                Int(slopdesk_ws_find_bar_counter(
                    position != nil,
                    UInt32(position?.current ?? 0),
                    UInt32(position?.total ?? 0),
                    borrowed.baseAddress,
                    borrowed.count,
                    out,
                    cap,
                ))
            }
        }
        // `docs/55` §4's `0` is the silence itself here: a counter that prints nothing is not a
        // counter that prints an empty string.
        return blob.isEmpty ? nil : wsRuns(blob, count: 1)[0]
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

    /// The rung as it crosses — three doubles in the order the door declares them.
    init(_ rung: SlopDeskWsFindBarRung) {
        self.init(plate: rung.plate, iconSize: rung.icon_size, fieldWidth: rung.field_width)
    }
}

/// The two rungs, named by the INPUT DEVICE rather than by the platform (see the file header).
package enum FindBarMetrics {
    /// A MOUSE drives the bar: the chrome ladder's control plate and icon, and a field sized to the
    /// compact card `find.png` shows.
    package static let pointer = FindBarRung(slopdesk_ws_find_bar_rung(false))

    /// A FINGER drives the bar: a plate big enough to hit and a field wide enough to read a query in
    /// over a software keyboard. A touch surface is a TARGET before it is a plate.
    package static let touch = FindBarRung(slopdesk_ws_find_bar_rung(true))
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
        switch slopdesk_ws_find_toggle_appearance(isOn, hovering) {
        case 1: .hovering
        case 2: .on
        default: .idle
        }
    }
}
