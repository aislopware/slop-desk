#if canImport(SwiftUI)
import SwiftUI

// MARK: - PaneConnectionStatus (the shared presentation derivation)

/// The ONE source of truth for how a pane's ``ConnectionViewModel/Status`` is presented as a status
/// dot (research B1 — per-pane status). Both the per-pane header (``PaneChromeView``) and the sidebar
/// tab rail (``TabSidebarView``) derive their dot from this type so the two surfaces can never drift.
///
/// It is a pure, `Equatable` value computed from a `ConnectionViewModel.Status?` — no view, no actor —
/// so the mapping (status → colour / label / pulse) and the tab-level salience fold are both unit-tested
/// directly without a SwiftUI render. The `nextRetry` instant is carried through so the header can run a
/// `TimelineView` countdown ("retrying in Ns") WITHOUT mutating the store every second.
///
/// ### The deliberate colour split (surfacing WF3)
/// `.connecting` (initial dial) is **yellow**; `.reconnecting` (a drop being retried by the WF3 backoff)
/// is **orange**; `.unreachable`/`.failed` (terminal — the dead-host timeout or a campaign give-up) is
/// **red**. This is exactly what turns the old "connecting forever" wart into a visible
/// "Reconnecting (n) — retrying in Ns" → "Unreachable" progression.
///
/// ### Connection state vs shell activity (the deliberate split)
/// `PaneConnectionStatus` stays the PURE connection projection (idle/connecting/connected/…).
/// The OSC 133 idle-vs-RUNNING shell activity (B6 shell-integration) is carried SEPARATELY as
/// the `running` flag on ``PaneStatusDot`` — not folded into a connection `Phase` — because the
/// two are orthogonal (a pane is `.connected` AND running) and a single dot must be able to show
/// both the green connection colour and the amber running pulse at once.
struct PaneConnectionStatus: Equatable {
    /// The presented phase — a flattened projection of `ConnectionViewModel.Status` plus a `.none`
    /// sentinel for a pane that has no PATH-1 connection (a `.remoteGUI` / faked handle ⇒ no dot).
    enum Phase: Equatable {
        case idle           // .disconnected — known, deliberately not connected
        case connecting     // .connecting — initial dial
        case connected      // .connected
        case reconnecting   // .reconnecting — a drop is being retried (WF3 backoff)
        case unreachable    // .unreachable — gave up after the dead-host timeout
        case failed         // .failed — initial connect refused / timed out
        case none           // no connection at all (video pane / faked handle): render no dot
    }

    let phase: Phase
    /// The 1-based reconnect attempt count when `phase == .reconnecting` (0 when not yet reported), so
    /// the label can read "Reconnecting (2)…".
    let attempt: Int
    /// When `phase == .reconnecting`, the instant the next attempt fires — drives the header countdown.
    let nextRetry: Date?
    /// The `.failed` message, surfaced only in the hover tooltip (kept off the compact label).
    let failureDetail: String?

    private init(phase: Phase, attempt: Int = 0, nextRetry: Date? = nil, failureDetail: String? = nil) {
        self.phase = phase
        self.attempt = attempt
        self.nextRetry = nextRetry
        self.failureDetail = failureDetail
    }

    /// Derives the presentation from a connection status (`nil` ⇒ `.none`, no dot). The single mapping
    /// site — both surfaces call this so the colour/label/pulse rules live in one place.
    static func from(_ status: ConnectionViewModel.Status?) -> PaneConnectionStatus {
        switch status {
        case .none:                            return PaneConnectionStatus(phase: .none)
        case .disconnected:                    return PaneConnectionStatus(phase: .idle)
        case .connecting:                      return PaneConnectionStatus(phase: .connecting)
        case .connected:                       return PaneConnectionStatus(phase: .connected)
        case let .reconnecting(attempt, next): return PaneConnectionStatus(phase: .reconnecting, attempt: attempt, nextRetry: next)
        case .unreachable:                     return PaneConnectionStatus(phase: .unreachable)
        case let .failed(message):             return PaneConnectionStatus(phase: .failed, failureDetail: message)
        }
    }

    /// Whether a dot should be drawn at all (a `.remoteGUI` / faked handle has no connection ⇒ none).
    var showsDot: Bool { phase != .none }

    /// The dot colour for the phase (the at-a-glance signal). `.none` returns clear (never drawn).
    var color: Color {
        switch phase {
        case .connecting:   return .yellow
        case .connected:    return .green
        case .reconnecting: return .orange
        case .unreachable, .failed: return .red
        case .idle:         return .secondary
        case .none:         return .clear
        }
    }

    /// Whether the dot pulses (the "something is in flight" cue): connecting + reconnecting only.
    var pulses: Bool {
        switch phase {
        case .connecting, .reconnecting: return true
        default: return false
        }
    }

    /// The static label (no countdown — the live "retrying in Ns" is composed by the view from
    /// `nextRetry` via a `TimelineView`, so this stays pure/clock-free and testable).
    var label: String {
        switch phase {
        case .idle:         return "Disconnected"
        case .connecting:   return "Connecting…"
        case .connected:    return "Connected"
        case .reconnecting: return attempt > 0 ? "Reconnecting (\(attempt))…" : "Reconnecting…"
        case .unreachable:  return "Unreachable"
        case .failed:       return "Failed"
        case .none:         return ""
        }
    }

    /// The tooltip / accessibility detail: the label plus the `.failed` message when present.
    var detailedLabel: String {
        if phase == .failed, let failureDetail, !failureDetail.isEmpty {
            return "Failed: \(failureDetail)"
        }
        return label
    }

    // MARK: - Tab-level salience fold

    /// Folds a tab's per-leaf statuses into ONE tab-level presentation for the sidebar rail. A single
    /// bad pane must surface at the tab level even if its siblings are green — that is the whole point of
    /// an at-a-glance rail — so the fold picks the MOST salient phase across the leaves by this order:
    ///
    ///   unreachable > failed > reconnecting > connecting > connected > idle > none
    ///
    /// Pure + `nonisolated` so it is unit-tested without a view. When the worst phase is `.reconnecting`
    /// the fold carries through the lowest-attempt / soonest-`nextRetry` reconnecting leaf so the rail's
    /// dot still pulses with a representative countdown.
    nonisolated static func fold(_ statuses: [ConnectionViewModel.Status?]) -> PaneConnectionStatus {
        let derived = statuses.map(from)
        func salience(_ p: Phase) -> Int {
            switch p {
            case .unreachable:  return 6
            case .failed:       return 5
            case .reconnecting: return 4
            case .connecting:   return 3
            case .connected:    return 2
            case .idle:         return 1
            case .none:         return 0
            }
        }
        // The leaf with the highest salience wins; ties keep the first (stable, pre-order).
        guard let worst = derived.max(by: { salience($0.phase) < salience($1.phase) }) else {
            return PaneConnectionStatus(phase: .none)
        }
        return worst
    }
}

// MARK: - PaneStatusDot (the shared dot view)

/// A small colour-coded connection-status dot, optionally pulsing, rendered identically in the pane
/// header and the sidebar rail. Cross-platform (no AppKit): the pulse is a `TimelineView`-driven opacity
/// ramp, which avoids a stored animation `@State` and is cheap. Renders nothing when there is no
/// connection (`phase == .none`).
struct PaneStatusDot: View {
    let status: PaneConnectionStatus
    /// OSC 133 shell activity (orthogonal to ``status``): when `true` AND the pane is connected,
    /// an amber pulse ring overlays the connection dot to signal a RUNNING command. Defaults to
    /// `false` so every existing call site (which passes only `status`) is unchanged.
    var running: Bool = false
    /// The dot diameter (the header uses 7; the rail uses the same for consistency).
    var size: CGFloat = 7

    /// The running ring is shown only when a command is actually executing on a LIVE connection —
    /// a disconnected/reconnecting pane shows its connection state, not a stale running cue.
    private var showsRunningRing: Bool { running && status.phase == .connected }

    /// Whether to overlay a NON-COLOUR error glyph. The rail/header dot signals an error by RED alone
    /// (WCAG 1.4.1 — colour must not be the only cue), so a small "!" makes `.failed`/`.unreachable`
    /// distinguishable without relying on hue. Error phases only; the running ring is `.connected`-gated
    /// and never co-occurs, so this overlay does not touch the `size + 4` ring math. `internal` so the
    /// condition is unit-testable.
    var showsErrorGlyph: Bool { status.phase == .unreachable || status.phase == .failed }

    /// The running-ring colour (amber) — distinct from every connection colour so the running cue
    /// reads as "activity", not a connection state change.
    private static let runningColor = Color.orange

    var body: some View {
        if status.showsDot {
            Group {
                if status.pulses {
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        circle.opacity(pulseOpacity(at: context.date))
                    }
                } else {
                    circle
                }
            }
            // The RUNNING cue: an amber ring around the (steady green) connection dot, pulsing via
            // the SAME wall-clock ramp the connecting/reconnecting pulse uses — no new animation
            // system. Layered on top so the connection colour (the at-a-glance signal) is never lost.
            .overlay {
                if showsRunningRing {
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        Circle()
                            .stroke(Self.runningColor, lineWidth: 1.5)
                            .frame(width: size + 4, height: size + 4)
                            .opacity(pulseOpacity(at: context.date))
                    }
                }
            }
            // NON-COLOUR error cue: a white "!" over the red error dot so a colour-blind user can tell a
            // failed/unreachable pane from a healthy one without relying on hue. Additive overlay (the
            // base dot + ring math are untouched); shown for error phases only.
            .overlay {
                if showsErrorGlyph {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: size + 1, weight: .black))
                        .foregroundStyle(.white)
                }
            }
            .help(detailedLabel)
            .accessibilityLabel(Text(detailedLabel))
        }
    }

    /// The connection label, suffixed with " — running" while a command executes, so hover /
    /// accessibility surfaces the activity too.
    private var detailedLabel: String {
        showsRunningRing ? "\(status.detailedLabel) — running" : status.detailedLabel
    }

    private var circle: some View {
        Circle()
            .fill(status.color)
            .frame(width: size, height: size)
    }

    /// A smooth 1s breathing ramp between 0.4 and 1.0, derived from wall-clock time so no per-frame
    /// state is stored. `0.5`-second ticks keep it light; the cosine interpolation reads as a pulse.
    private func pulseOpacity(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.0)
        let eased = (cos(phase * 2 * .pi) + 1) / 2     // 0…1, smooth
        return 0.4 + 0.6 * eased
    }
}
#endif
