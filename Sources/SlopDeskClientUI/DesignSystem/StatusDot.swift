// StatusDot — the sidebar row's trailing status dot: ONE flat circle on the state's ink, sitting
// at the trailing slot's right edge so status reads down a single column and every row carries
// visual weight on both ends. Ported from T3 Code's thread-status pill (`ThreadStatusLabel` +
// `resolveThreadStatusPill`): the ink names WHICH state, a duty-cycled stepped opacity pulse means
// ALIVE RIGHT NOW (only the running tiers pulse — the waiting states hold still), and an idle row
// mounts nothing at all (T3 Code renders null — the resting rail stays bare).
//
// The pulse is T3 Code's `status-pulse` cadence (2s: hold full → dip to half → hold → rise)
// quantized the WorkingShimmer way: hard cuts through one intermediate step, never a glide.
// Every phase decision is pure math off the WALL CLOCK against a fixed epoch, so all pulsing
// dots in the rail tick in unison and a store-driven re-render can never reset a pulse mid-cycle.

#if canImport(SwiftUI)
import SwiftUI

/// The status dot's timing + geometry — pure, clock-in/value-out, unit-testable.
enum StatusDot {
    /// The dot's footprint — T3 Code's in-row size (6px), small enough to read as punctuation.
    static let diameter: CGFloat = 6
    /// One full pulse: high hold → step down → low hold → step up (T3 Code's 2s `status-pulse`).
    static let cycle: TimeInterval = 2.0
    /// Each transition's length — ONE discrete slot between the holds (the mechanical cut).
    static let step: TimeInterval = 0.1
    /// The low hold's opacity — T3 Code dims to half, deep enough to read as a beat, not a flicker.
    static let lowOpacity = 0.5
    /// The single intermediate opacity the transitions pass through.
    static let midOpacity = 0.75

    /// The `TimelineView` cadence — one tick per step slot while a dot is pulsing.
    static var tick: TimeInterval { step }
    /// The shared phase anchor: a FIXED epoch (never `.now`, which re-renders would recreate and
    /// de-phase) — every pulsing dot derives the same phase from the same clock.
    static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    /// The dot's opacity at `date` while pulsing: `1 → ¾ → ½ → ¾ → 1` across the cycle, holds
    /// symmetric, hard cuts only. Pre-epoch dates fold into the same cycle (no negative phase).
    static func pulseOpacity(at date: Date) -> Double {
        let raw = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
        let phase = raw < 0 ? raw + cycle : raw
        let half = cycle / 2
        if phase < half - step { return 1 }
        if phase < half { return midOpacity }
        if phase < cycle - step { return lowOpacity }
        return midOpacity
    }
}

/// One resolved dot: the state's ink and whether it pulses. A pure value (no view), so the
/// resolver (``StatusPresentation/statusDot(working:badge:)``) unit-tests without rendering.
struct StatusDotStyle: Equatable {
    let ink: Color
    let pulses: Bool
}

/// The dot itself. The `TimelineView` mounts ONLY on a pulsing dot, so the waiting/finished dots
/// — and the whole resting rail — schedule nothing. AX-hidden: the row title's accessibility
/// value already speaks the same state, so the dot never double-announces.
struct StatusDotView: View {
    let style: StatusDotStyle

    var body: some View {
        Group {
            if style.pulses {
                TimelineView(.periodic(from: StatusDot.epoch, by: StatusDot.tick)) { context in
                    dot.opacity(StatusDot.pulseOpacity(at: context.date))
                }
            } else {
                dot
            }
        }
        .accessibilityHidden(true)
    }

    private var dot: some View {
        Circle()
            .fill(style.ink)
            .frame(width: StatusDot.diameter, height: StatusDot.diameter)
    }
}
#endif
