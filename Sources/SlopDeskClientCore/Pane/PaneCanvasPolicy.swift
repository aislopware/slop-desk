// PaneCanvasPolicy — the pane canvas spine's decisions, below the drawing (docs/56 §3).
//
// Every rule here was ALREADY `static` and already doc-commented "pure so it is unit-pinned", which is
// the tell that it never belonged to a view in the first place: a `static` on a `some View` is a
// function that happens to be spelled inside a type the other half cannot import. The canvas is the
// last bulk of Stage D (the ledger's kind 1), and when it is rewritten in AppKit these are the rules
// the rewrite has to keep — so they are the part that must NOT be rewritten.
//
// Three homes, by what the rule is about:
//   • ``PaneFocusPolicy``  — who is focused, who is marked, who recedes.
//   • ``PaneCanvasMetrics`` — the z-band and the pointer vocabulary the canvas stacks/answers with.
//   • ``PaneEmptyCause``    — WHY the canvas is empty, which is a reading of the connection, not a view.

import CoreGraphics
import Foundation
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

// MARK: - Focus

/// Which pane owns the keyboard, wears the corner mark, and stays lit during a ⌃⇥ walk.
package enum PaneFocusPolicy {
    /// Whether pane `paneID` (in `tab`) should own the renderer's keyboard focus — the guard that makes
    /// keep-all-mounted safe.
    ///
    /// TRUE only when `tab` is the ACTIVE tab AND `paneID` is that tab's `activePane`. Every mounted
    /// background tab still carries its own `activePane`, but it must NOT claim first responder
    /// (`GhosttyLayerBackedView.applyKeyboardFocus` acts only when `isFocusedPane`), or the
    /// last-mounted hidden tab would steal the keyboard from the visible one.
    package static func isPaneFocused(
        _ paneID: PaneID, in tab: SlopDeskWorkspaceModel.Tab, activeTabID: TabID?,
    ) -> Bool {
        tab.id == activeTabID && paneID == tab.activePane
    }

    /// Whether the focus-corner marker shows: the pane is focused AND its tab actually has siblings to
    /// disambiguate from — a single-pane tab needs no "which pane is active" answer, so the marker
    /// there would be pure ornament.
    package static func showsFocusCorner(isFocused: Bool, tabPaneCount: Int) -> Bool {
        isFocused && tabPaneCount > 1
    }

    /// Whether this pane RECEDES for the ⌃⇥ walk: the switcher is open and this is not the pane it is
    /// on.
    ///
    /// `isFocused` is the subject on BOTH settings of the preview: with it on, each step moves this
    /// device's focus onto the highlighted pane, so the lit pane IS the highlight; with it off the
    /// focus stays put and the lit pane is where a cancel would leave you. Either way exactly one pane
    /// of the visible tab stays lit, which is the whole claim.
    package static func showsSwitcherRecede(switcherIsOpen: Bool, isFocused: Bool) -> Bool {
        switcherIsOpen && !isFocused
    }
}

// MARK: - Canvas metrics

/// The canvas compositor's stacking band and the pointer it answers with.
package enum PaneCanvasMetrics {
    /// The z-index band the compositor stacks by: panes at the base (0), then the divider layer, then
    /// the move-handle / drag-overlay layer. Stated as two named rungs because a bare `10`/`20` at the
    /// two `.zIndex(...)` call sites is a rule spelled in two magic numbers.
    package static let dividerZ: Double = 10
    package static let moveZ: Double = 20

    /// The in-canvas zone a full destination carries (`.none` for every external destination — the
    /// local overlay must not preview a drop that will land outside this canvas).
    package static func canvasZone(of destination: PaneDragDestination) -> PaneDropZone {
        if case let .canvas(zone) = destination { return zone }
        return .none
    }

    /// The divider's hover cursor, telling the truth at the clamp (the same rule as the shell's column
    /// dividers): a seam whose neighbour sits at the ``SplitWeight/minWeight`` floor asks for the
    /// ONE-WAY resize arrow for the only direction the drag still has.
    ///
    /// Movability comes from the handle's pair weights
    /// (``SplitTreeRenderModel/DividerHandle/canMoveTowardLeading``), the exact quantities the drag
    /// clamp reads, so the glyph can never disagree with the gesture.
    ///
    /// It answers in ``PanePointer`` rather than in SwiftUI's `PointerStyle` on purpose: the rule above
    /// is a statement about THIS seam's clamp, and the type that draws it does not exist on iOS.
    /// Stated as a value it stays plain Swift on both platforms and only the drawing is gated.
    package static func resizePointer(
        axis: SplitAxis, toLeading: Bool, toTrailing: Bool,
    ) -> PanePointer {
        axis == .horizontal
            ? .columnResize(toLeading: toLeading, toTrailing: toTrailing)
            : .rowResize(toUp: toLeading, toDown: toTrailing)
    }
}

// MARK: - The empty canvas

/// WHY the pane area is empty — each cause pins its own copy, symbol and single next action one floor
/// up, in whichever framework is drawing the empty state.
///
/// It is a reading of the CONNECTION, so it is not a fact about either drawing: "connected but no
/// tabs" and "the link is down and the supervisor is redialing" are different sentences the user needs
/// to hear, and a canvas rewritten in AppKit must say the same four things the SwiftUI one does.
package enum PaneEmptyCause: Equatable, Sendable {
    /// No host connected (fresh launch / disconnected) — the next action is the Connect editor.
    case neverConnected
    /// A host WAS reachable and the link is down — the supervisor is redialing on its own, so there is
    /// no action; the caption names the host being re-dialed.
    case linkDown(host: String)
    /// Connected fine — just no open tabs; the next action mints one.
    case noTabs
    /// The last explicit connect attempt failed — the caption carries the REAL reason (not the generic
    /// not-connected copy) so a wrong host/port reads as its own mistake, and the action reopens the
    /// Connect editor to correct it.
    case connectFailed(reason: String)

    /// Resolves the empty pane area's CAUSE from the live connection: connected ⇒ the only thing
    /// missing is a tab; an active redial ⇒ link-down (named host, no action — the supervisor is
    /// already dialing); anything else (fresh launch, give-up states, a first `connecting`) reads
    /// not-connected, whose action opens the Connect editor.
    package static func resolve(status: ConnectionStatus, host: String) -> Self {
        switch status {
        case .connected: .noTabs
        case .reconnecting: .linkDown(host: host)
        case let .failed(reason): .connectFailed(reason: ConnectionPresenter.friendlyFailure(reason))
        case .disconnected,
             .connecting,
             .unreachable: .neverConnected
        }
    }
}
