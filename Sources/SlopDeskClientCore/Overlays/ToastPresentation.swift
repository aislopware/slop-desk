// ToastPresentation — WHAT a notification card says and which of them speak in full. Not a view:
// two of them draw this, one per platform.
//
// The Mac's stack is an AppKit panel (``SlopDeskMacUI/MacToastStack``) and the phone's is a SwiftUI
// column, and neither knows the other exists. What they may not do is each decide what a card SAYS —
// so the three rules that are not layout live here, below both (docs/56: layout diverges, capability
// does not).
//
//   * The HEADLINE is `slopdesk_ws_notify_toast_headline`, resolved from source + flavour TOGETHER.
//     `.success` is "the agent finished its turn" for an agent and "the command exited 0" for a
//     command — two speakers saying two different words — and a command's notice or waiting prompt
//     is returned VERBATIM, because it arrived already phrased and a verb hung onto someone else's
//     sentence garbles it. A toast may carry its own ``Toast/headline`` override when a factory knows
//     a truer phrase than the derivation can reach (a reconnect verdict is "Session reattached").
//   * The SPINE — only the newest ``expandedCount`` cards carry a detail line, so four simultaneous
//     notifications cost a third of the corner instead of blanketing the prompt.
//   * The MARK — one bare glyph per flavour and the status rung it is drawn in. The rung is named
//     rather than coloured here: `SlopDeskClientCore` has no design tokens, and each half resolves
//     the same rung through its own view of the ONE ladder (`Slate.Status` / `Slate.Native.Status`).
//
// The dwell, the hover pause and the hue are the drawing halves' own; nothing about a timer or a
// `Color` belongs to a value type.

import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceCore // WorkspaceStore — the jump a card is a door to
import SlopDeskWorkspaceModel // wsAnswerBytes — the (out, cap) answer protocol, spelled once; PaneID

/// Which status rung a card's mark is drawn in. Named, not coloured: the ink ladder is the drawing
/// half's, and this layer must not own a `Color`.
public enum ToastMarkRung: Sendable, Equatable {
    /// It ended well — green.
    case ok
    /// It is waiting on a human — AMBER, not the accent. The rail already fixed this mapping
    /// (``StatusDot``: green finish, amber question, red failure), so an agent waiting on a human is
    /// the same colour here as on its own sidebar row; and every FOUNDRY seed sets `info == accent`,
    /// so the accent would have rendered "needs input" in the same cyan as a routine notice.
    case warn
    /// It ended badly — red.
    case err
    /// A routine notice, drawn in the reading ink's secondary rung. NEUTRAL on purpose: cyan on
    /// every OSC notice was chrome pretending to be signal.
    case neutral
}

/// One card's mark: the bare glyph, and the rung it is drawn in. The glyph is UNENCLOSED — the disc
/// under it is the drawing half's, so the two families never disagree about the enclosure.
public struct ToastMark: Sendable, Equatable {
    /// An SF Symbol name.
    public let symbolName: String
    public let rung: ToastMarkRung

    public init(symbolName: String, rung: ToastMarkRung) {
        self.symbolName = symbolName
        self.rung = rung
    }
}

/// What a notification card says, and which of a stack's cards say all of it.
public enum ToastPresentation {
    // MARK: - The spine

    /// The newest N cards render with their detail line. TWO, not one: the common burst is a pair
    /// (a command finishes in one pane while an agent asks a question in another) and both deserve
    /// to be readable at a glance; beyond that the corner is worth more than the third body.
    public static let expandedCount = 2

    /// Whether the card at `index` of a `count`-deep stack speaks in full. The stack is newest-LAST,
    /// so the expanded ones are at the END — the cards flush to the corner the eye already goes to.
    public static func isExpanded(index: Int, count: Int) -> Bool {
        index >= count - expandedCount
    }

    // MARK: - The headline

    /// The sentence-case event phrase that leads a card, asked of `slopdesk_ws_notify_toast_headline`
    /// — or the toast's own override when it carries one.
    public static func headline(for toast: Toast) -> String {
        if let explicit = toast.headline, !explicit.isEmpty { return explicit }
        var subject = toast.title
        let answer = wsAnswerBytes { out, cap in
            subject.withUTF8 { text in
                slopdesk_ws_notify_toast_headline(
                    speakerCase(toast.source), flavourCase(toast.flavor),
                    text.baseAddress, text.count, out, cap,
                )
            }
        }
        return String(bytes: answer, encoding: .utf8) ?? ""
    }

    /// `0` agent · `1` command — the header's map, read from this side.
    private static func speakerCase(_ source: Toast.Source) -> UInt8 {
        switch source {
        case .agent: 0
        case .command: 1
        }
    }

    /// `0` notice · `1` success · `2` failure · `3` attention.
    private static func flavourCase(_ flavor: Toast.Flavor) -> UInt8 {
        switch flavor {
        case .default: 0
        case .success: 1
        case .error: 2
        case .attention: 3
        }
    }

    // MARK: - The mark

    /// The card's one point of colour: one glyph family, one weight — never the mixed-family outline
    /// quartet an earlier round cut.
    public static func mark(for flavor: Toast.Flavor) -> ToastMark {
        switch flavor {
        case .success: ToastMark(symbolName: "checkmark", rung: .ok)
        case .error: ToastMark(symbolName: "xmark", rung: .err)
        case .attention: ToastMark(symbolName: "exclamationmark", rung: .warn)
        case .default: ToastMark(symbolName: "info", rung: .neutral)
        }
    }

    /// The disc layer's share of the mark's hue — matched to what HIERARCHICAL rendering gives the
    /// enclosure layer of the system's own `*.circle.fill` status symbols (0.30, measured off a
    /// rendered `info.circle.fill`), so a composed mark is indistinguishable from the native idiom.
    /// Not a taste knob: drift it and the mark stops matching the system's status marks.
    public static let discLayerOpacity = 0.30

    // MARK: - The dwell

    /// A card's whole dwell in seconds; `0` for a sticky card, which has no timer at all. Manual
    /// (no `TimeInterval` bridge) because `Duration` exposes only the component pair.
    public static func dwellSeconds(_ toast: Toast) -> Double {
        guard let dwell = toast.autoDismiss else { return 0 }
        return Double(dwell.components.seconds) + Double(dwell.components.attoseconds) / 1e18
    }

    /// The dwell SAMPLE interval — the granularity at which a hover can freeze the countdown. 10 Hz
    /// is imperceptible as a rounding error on a 4s dwell and costs nothing; it only runs while a
    /// card is actually on screen.
    public static let dwellTick = 0.1
}

// MARK: - The door

public extension WorkspaceStore {
    /// Lands on the pane a notification came from. THE CARD IS A DOOR: every push site is gated on
    /// the source pane NOT being focused, so a card always names a place the user is not looking at,
    /// and a notification about somewhere else that cannot take you there is a dead end.
    ///
    /// Routed through `jumpToPaneTree` rather than `focusPaneTree` for the reason
    /// ``ConnectionAlertChip`` is — an undirected landing that CROSSES a tab swaps the whole viewport,
    /// and that seam is what fires the "JUMPED · session ▸ tab" orientation breadcrumb.
    ///
    /// It lives here, below both shells, because the Mac's corner is an `NSPanel` and the phone's is a
    /// SwiftUI column: two views, one destination. An unparseable key — a toast whose pane is long
    /// gone — is a silent no-op, never a crash on host-shaped text.
    func jumpToPaneNamedByNotification(_ paneKey: String) {
        guard let raw = UUID(uuidString: paneKey) else { return }
        jumpToPaneTree(PaneID(raw: raw))
    }
}
