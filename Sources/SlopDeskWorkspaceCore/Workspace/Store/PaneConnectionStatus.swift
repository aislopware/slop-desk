import Foundation

// L0: extracted from the deleted SwiftUI `PaneStatusIndicator.swift`. `PaneConnectionStatus` is the
// PURE, `Equatable` projection of a `ConnectionViewModel.Status?` into a presentable phase + label +
// salience fold — the single source of truth both the pane header and the sidebar rail derive their
// status dot from. The SwiftUI `Color` / `semanticColor` accessors (and the `PaneStatusDot` view) were
// deleted with the chrome; the rebuilt UI (L3) maps `phase` → a token colour itself. No UI import.

/// The ONE source of truth for how a pane's ``ConnectionViewModel/Status`` is presented (research B1 —
/// per-pane status). A pure, `Equatable` value computed from a `ConnectionViewModel.Status?` — no view,
/// no actor for the derivation — so the mapping and the tab-level salience fold are unit-tested directly.
struct PaneConnectionStatus: Equatable {
    /// The presented phase — a flattened projection of `ConnectionViewModel.Status` plus a `.none`
    /// sentinel for a pane that has no PATH-1 connection (a `.remoteGUI` / faked handle ⇒ no dot).
    enum Phase: Equatable {
        case idle // .disconnected — known, deliberately not connected
        case connecting // .connecting — initial dial
        case connected // .connected
        case reconnecting // .reconnecting — a drop is being retried (WF3 backoff)
        case unreachable // .unreachable — gave up after the dead-host timeout
        case failed // .failed — initial connect refused / timed out
        case none // no connection at all (video pane / faked handle): render no dot
    }

    let phase: Phase
    /// The 1-based reconnect attempt count when `phase == .reconnecting` (0 when not yet reported).
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
    /// site — both surfaces call this so the rules live in one place.
    static func from(_ status: ConnectionViewModel.Status?) -> Self {
        switch status {
        case .none: Self(phase: .none)
        case .disconnected: Self(phase: .idle)
        case .connecting: Self(phase: .connecting)
        case .connected: Self(phase: .connected)
        case let .reconnecting(attempt, next): Self(
                phase: .reconnecting,
                attempt: attempt,
                nextRetry: next,
            )
        case .unreachable: Self(phase: .unreachable)
        case let .failed(message): Self(phase: .failed, failureDetail: message)
        }
    }

    /// Whether a dot should be drawn at all (a `.remoteGUI` / faked handle has no connection ⇒ none).
    var showsDot: Bool { phase != .none }

    /// Whether the dot pulses (the "something is in flight" cue): connecting + reconnecting only.
    var pulses: Bool {
        switch phase {
        case .connecting,
             .reconnecting: true
        default: false
        }
    }

    /// The static label (no countdown — the live "retrying in Ns" is composed by the view from
    /// `nextRetry`, so this stays pure/clock-free and testable).
    var label: String {
        switch phase {
        case .idle: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .reconnecting: attempt > 0 ? "Reconnecting (\(attempt))…" : "Reconnecting…"
        case .unreachable: "Unreachable"
        case .failed: "Failed"
        case .none: ""
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
    /// bad pane must surface at the tab level even if its siblings are green, so the fold picks the MOST
    /// salient phase across the leaves by this order:
    ///
    ///   unreachable > failed > reconnecting > connecting > connected > idle > none
    ///
    /// Pure + `nonisolated` so it is unit-tested without a view.
    nonisolated static func fold(_ statuses: [ConnectionViewModel.Status?]) -> Self {
        let derived = statuses.map(from)
        func salience(_ p: Phase) -> Int {
            switch p {
            case .unreachable: 6
            case .failed: 5
            case .reconnecting: 4
            case .connecting: 3
            case .connected: 2
            case .idle: 1
            case .none: 0
            }
        }
        // The leaf with the highest salience wins; ties keep the first (stable, pre-order).
        guard let worst = derived.max(by: { salience($0.phase) < salience($1.phase) }) else {
            return Self(phase: .none)
        }
        return worst
    }
}
