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
import CSlopDeskFFI
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

/// WHY the pane area is empty — and, since R12, WHAT IT SAYS: the symbol, the title, the caption and
/// the single next action all hang off the cause itself.
///
/// It is a reading of the CONNECTION, so it is not a fact about either drawing: "connected but no
/// tabs" and "the link is down and the supervisor is redialing" are different sentences the user needs
/// to hear, and a canvas rewritten in AppKit must say the same four things the SwiftUI one does.
///
/// ⚠️ THE COPY DESCENDED RATHER THAN BEING PINNED AS A PAIR, and the test for that is in docs/56 §3's
/// P6: a table that returns a `Color` cannot come below `SlopDeskSlate` and must therefore be pinned
/// as a cross-renderer pair, but a FRAMEWORKLESS value can just move to the floor where neither half
/// can drift from it. These four return `String` — a symbol NAME, not an `Image`; a label, not a
/// `Button` — so there is nothing to pin. They lived as `static func`s on `SlateEmptyState` (a
/// `some View`), and the floor they descended to is now `slopdesk_workspace::pane_empty`.
///
/// WHAT STAYS HERE IS THE CASE, NOT THE COPY. The branch and the four strings are the crate's; the
/// associated values are Swift's, because a renderer switches on the case to decide what its one
/// button does and the host / reason it carries are what the caption is drawn from.
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

    /// Resolves the empty pane area's CAUSE from the live connection. The branch is
    /// `slopdesk_workspace::pane_empty`'s; what stays here is the ASSOCIATED VALUE each cause carries,
    /// because a renderer switches on the case to decide what its one button does.
    package static func resolve(status: ConnectionStatus, host: String) -> Self {
        switch slopdesk_ws_pane_empty_cause(status.terms.code) {
        case UInt8(SLOPDESK_WS_PANE_EMPTY_LINK_DOWN): .linkDown(host: host)
        case UInt8(SLOPDESK_WS_PANE_EMPTY_NO_TABS): .noTabs
        case UInt8(SLOPDESK_WS_PANE_EMPTY_CONNECT_FAILED):
            .connectFailed(reason: ConnectionPresenter.friendlyFailure(status.terms.raw))
        default: .neverConnected
        }
    }

    // MARK: The copy (one crossing, four strings)

    /// The symbol, the title, the caption and the action label, from one crossing.
    ///
    /// Each of the four properties below asks again rather than sharing one stored reading, which is
    /// safe here and nowhere else: the answer is a pure function of the cause VALUE, so four calls
    /// with the same cause cannot come back saying four different things. A renderer that wants all
    /// four in one go destructures this directly.
    ///
    /// The action's ABSENCE is a flag on the delivery rather than an empty label, so a redial offers
    /// no button at all instead of an unlabelled one.
    private var copy: (symbol: String, title: String, caption: String, action: String?) {
        var arena = WsStrings()
        let spans = [arena.span(host), arena.span(reason)]
        var bytes = arena.bytes
        let blob = bytes.withUnsafeMutableBufferPointer { lent in
            spans.withUnsafeBufferPointer { slots in
                wsAnswerBytes { out, cap in
                    Int(slopdesk_ws_pane_empty_copy(
                        crossing, lent.baseAddress, lent.count,
                        slots.baseAddress, slots.count, out, cap,
                    ))
                }
            }
        }
        let head = Int(SLOPDESK_WS_PANE_EMPTY_HEAD_BYTES)
        let hasAction = blob.count >= head && (0..<head).reduce(0) { $0 << 8 | Int(blob[$1]) } == 1
        let runs = wsRuns(blob.count >= head ? Array(blob.dropFirst(head)) : [], count: 4)
        return (runs[0], runs[1], runs[2], hasAction ? runs[3] : nil)
    }

    /// The muted SF Symbol above the title. A NAME, so the two renderers resolve it through their own
    /// image type rather than sharing one they cannot both import.
    package var symbolName: String { copy.symbol }

    /// The short headline. It names the ACTUAL reason ("Not Connected" vs "Connection Lost" vs "No Open
    /// Tabs") rather than one generic "No Session" for all three.
    package var title: String { copy.title }

    /// The one-line cause under the title.
    package var caption: String { copy.caption }

    /// The single next action's label, or `nil` when the cause has none — link-down redials itself, and
    /// offering a button there would suggest the user must do something.
    package var actionLabel: String? { copy.action }

    /// This cause in the door's own numbering.
    private var crossing: UInt8 {
        switch self {
        case .neverConnected: UInt8(SLOPDESK_WS_PANE_EMPTY_NEVER_CONNECTED)
        case .linkDown: UInt8(SLOPDESK_WS_PANE_EMPTY_LINK_DOWN)
        case .noTabs: UInt8(SLOPDESK_WS_PANE_EMPTY_NO_TABS)
        case .connectFailed: UInt8(SLOPDESK_WS_PANE_EMPTY_CONNECT_FAILED)
        }
    }

    /// The host being redialled, absent for every other cause — the door reads this slot only for
    /// link-down, and an absent span is what keeps it from being captioned somewhere else.
    private var host: String? {
        guard case let .linkDown(host) = self else { return nil }
        return host
    }

    /// The failure's own sentence, absent for every other cause.
    private var reason: String? {
        guard case let .connectFailed(reason) = self else { return nil }
        return reason
    }

    // MARK: The one action

    /// RUN the single next action ``actionLabel`` names.
    ///
    /// The label descended with the rest of the copy; the DEED did not, and so both shells wrote the
    /// same four-arm switch under their empty state's callback. It is the same shape as the copy and
    /// belongs in the same place: which of the two things a button does — reopen the Connect editor or
    /// mint a tab — is a reading of the CAUSE, and `.linkDown` does nothing at all because it has no
    /// button to press.
    ///
    /// `onConnect` stays a closure because summoning the Connect editor is the app shell's, not the
    /// store's: on macOS it is a sheet on the key window, on iOS a presented controller.
    @MainActor
    package func act(store: WorkspaceStore, onConnect: () -> Void) {
        switch self {
        case .neverConnected,
             .connectFailed: onConnect()
        case .noTabs: store.newTerminalPane(.newTab)
        case .linkDown: break
        }
    }
}
