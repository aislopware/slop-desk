import CSlopDeskFFI
import SlopDeskWorkspaceModel

// MARK: - PaneWiringRules (the decisions a terminal leaf's wiring makes)

/// The decisions behind ``TerminalPaneWiring``'s verbs, as `slopdesk-workspace::pane_session`
/// answers them.
///
/// The wiring itself is closures and their teardown order, which is what a renderer cannot be
/// trusted to reproduce and what keeps it in Swift. What is NOT wiring is which actuator a chip's
/// `×` drives — a three-way choice with a fourth chip waiting to be added — and that comes through
/// here, beside the same rules the live session's own gates read.
package enum PaneWiringRules {
    /// What the `×` on a status chip actually does.
    package enum DismissRoute: UInt8, Sendable, Equatable {
        /// Release the pane's read-only lock through its terminal MODEL, whose own hook converges
        /// the store's read-only set.
        case readOnly = 0
        /// Disarm the whole TAB's synchronized input — the mode belongs to the tab, so clearing it
        /// on one pane would leave the siblings still fanning keystrokes out.
        case syncInput = 1
        /// Nothing: this chip carries no `×`.
        case nothing = 2
    }

    /// Which actuator chip `pill`'s `×` drives.
    ///
    /// Secure input is the one that routes nowhere, and that is a DECISION rather than an omission:
    /// it is a safety indicator the user does not click away, which is the same reason
    /// ``PaneStatusPill/isDismissible`` answers `false` for it. The far side pins the two against
    /// each other, so a fourth chip cannot ship with a `×` that does nothing.
    package static func dismissRoute(_ pill: PaneStatusPill) -> DismissRoute {
        DismissRoute(rawValue: slopdesk_ws_session_dismiss_route(pill.index)) ?? .nothing
    }
}
