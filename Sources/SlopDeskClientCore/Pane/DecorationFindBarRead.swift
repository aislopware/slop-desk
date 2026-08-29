// DecorationFindBarRead — the find bar's one tracked read, and its three mode flags
//
// The in-pane find bar is drawn twice, and the two halves differ in exactly three lines: how a
// `String` is written into the field (`stringValue` against `text`), how the well is built, and how a
// layer is reached. Everything ABOVE that — which properties are observed, what the counter says,
// which pill is lit, and which model method a pill's tap calls — is one implementation asked twice.
//
// ⚠️ THE TRACKED READ IS THE DEPENDENCY SET, so it lives here and not at the call site. `Observation`
// registers a dependency on every property read while the tracking block runs and does not care
// whether the read happened inside the closure's braces or inside a function the closure called. A
// shared `reading(_:)` is therefore a shared dependency set: the half that grows a fourth signal
// cannot grow it in one shell only. That is the same argument `DecorationSurfaceReads.swift` makes.
//
// ⚠️ `lit` IS PART OF THE READ, NOT PART OF THE WORK. It reaches three observable flags, so building
// the dictionary inside `apply` would leave the bar unsubscribed from its own mode pills.

// The field's own pin rides along at the foot of the file for the same reason: a fixed-width field
// centred in a well is Auto Layout, which is ONE api on both shells.

import SlopDeskSlate
import SlopDeskWorkspaceCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Everything the find bar draws, taken in one tracked pass.
package struct DecorationFindBarReading {
    /// The controller's query — written back to the field only when it actually differs.
    package let query: String
    /// The `N of M` line, or `nil` when the three-way rule says draw nothing.
    package let label: String?
    package let lit: [FindModePill: Bool]
    /// The re-open bump. A change means "take focus", never "the query moved".
    package let token: Int
}

@MainActor
package enum DecorationFindBarRead {
    /// One tracked read of everything the bar draws. The model is `@Observable`, and every mutation
    /// it makes — a keystroke's recount, a toggle, a ⌘G step, the re-open bump — lands in one of
    /// these.
    package static func reading(_ model: TerminalFindBarModel) -> DecorationFindBarReading {
        let controller = model.controller
        return DecorationFindBarReading(
            query: controller.query,
            label: FindBarPresentation.counterText(
                position: controller.positionLabel, query: controller.query,
            ),
            lit: lit(in: model),
            token: model.focusToken,
        )
    }

    /// Whether `mode`'s chip is lit — the controller's own flag, never a mirror.
    package static func isOn(_ mode: FindModePill, in model: TerminalFindBarModel) -> Bool {
        switch mode {
        case .caseSensitive: model.controller.caseSensitive
        case .wholeWord: model.controller.wholeWord
        case .regex: model.controller.isRegex
        }
    }

    /// Flip `mode` through the model, which refreshes the mirror and re-arms the highlight.
    ///
    /// The pill's own lit state is redrawn by the tracked read, off the controller — a chip that
    /// painted itself here would be a second source for a flag the model already owns.
    package static func toggle(_ mode: FindModePill, in model: TerminalFindBarModel) {
        switch mode {
        case .caseSensitive: model.toggleCaseSensitive()
        case .wholeWord: model.toggleWholeWord()
        case .regex: model.toggleRegex()
        }
    }

    /// Every pill the in-pane bar offers, against its flag.
    package static func lit(in model: TerminalFindBarModel) -> [FindModePill: Bool] {
        Dictionary(
            uniqueKeysWithValues: FindModePill.inPaneFindBar.map { ($0, isOn($0, in: model)) },
        )
    }
}

// MARK: - The query field in its well

@MainActor
package enum DecorationFindWell {
    /// The field, centred in the well at a FIXED width.
    ///
    /// ⚠️ The width is a constant rather than a fill, per ``FindBarRung/fieldWidth``: a query longer
    /// than the field has to scroll rather than clip, or the tail of what was typed is simply not
    /// there. The two spacings are the well's own padding.
    package static func constraints(
        in well: SlateHostView,
        field: SlateHostView,
        width: CGFloat,
    ) -> [NSLayoutConstraint] {
        field.translatesAutoresizingMaskIntoConstraints = false
        return [
            field.widthAnchor.constraint(equalToConstant: width),
            field.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: Slate.Metric.space2),
            field.trailingAnchor.constraint(
                equalTo: well.trailingAnchor, constant: -Slate.Metric.space2,
            ),
            field.topAnchor.constraint(equalTo: well.topAnchor, constant: Slate.Metric.space1),
            field.bottomAnchor.constraint(
                equalTo: well.bottomAnchor, constant: -Slate.Metric.space1,
            ),
        ]
    }
}
