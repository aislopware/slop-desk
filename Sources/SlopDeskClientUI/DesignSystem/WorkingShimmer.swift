// WorkingShimmer — the sidebar's "agent thinking" reading: a DARK band sweeping across the row
// title's own ink, quantized into discrete steps so the sweep ticks mechanically instead of
// gliding, with a rest beat between sweeps. The title text IS the indicator — a working row spends
// no trailing glyph on motion, so its slot keeps the shell label. Reserved for the AGENT tier: a
// plain running command's title stands still (the command text is signal enough).
//
// The recipe follows the production convention of coder/mux's sidebar (`.shimmer-text`: a darkened
// band on the muted foreground, `steps(42)` sweep) and T3 Code's duty-cycled stepped pulses: the
// band DARKENS the ink (never a bright highlight), the sweep is stepped (hard cuts, no glide), and
// each sweep is followed by a rest so the motion has a visual pause.
//
// Every phase decision is pure math off the WALL CLOCK against a fixed epoch, so all working rows
// tick in unison and a store-driven re-render can never reset a sweep mid-cycle.

#if canImport(SwiftUI)
import SwiftUI

/// The stepped title shimmer's timing + geometry — pure, clock-in/value-out, unit-testable.
enum WorkingShimmer {
    /// One band sweep across the title, leading → trailing.
    static let sweepDuration: TimeInterval = 1.4
    /// The rest beat between sweeps — the title sits on plain ink (motion needs a pause to read as
    /// deliberate rather than looping gloss).
    static let restDuration: TimeInterval = 1.0
    /// Discrete positions per sweep — the band JUMPS between these (the mechanical tick), it never
    /// glides. Also the repaint cap: one update per step, not per vsync.
    static let sweepSteps = 24
    /// Half the band's width in unit text-widths — a wide, soft band reads calmer than a streak.
    static let bandHalfWidth = 0.18
    /// The band's ink multiplier — the band DARKENS the title toward the background; the resting
    /// ink is the bright state, so the sweep reads as a shadow passing, not a shine. Deep enough
    /// to register at a glance (a fainter band read as "barely there" in the field).
    static let dimOpacity = 0.35

    /// The `TimelineView` cadence — one tick per band step while a row is working.
    static var tick: TimeInterval { sweepDuration / Double(sweepSteps) }
    /// The shared phase anchor: a FIXED epoch (never `.now`, which re-renders would recreate and
    /// de-phase) — every working row derives the same phase from the same clock.
    static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    /// The band's center in unit text-widths at `date`, or `nil` during the rest beat. Travels
    /// `-bandHalfWidth → 1 + bandHalfWidth` so the band fully enters and fully exits, quantized to
    /// ``sweepSteps`` discrete positions.
    static func bandCenter(at date: Date) -> Double? {
        let cycle = sweepDuration + restDuration
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
        guard t < sweepDuration else { return nil }
        let step = (t / sweepDuration * Double(sweepSteps)).rounded(.down)
        let progress = step / Double(sweepSteps)
        let travel = 1 + 2 * bandHalfWidth
        return progress * travel - bandHalfWidth
    }

    /// The gradient profile for a band at `center`: unit locations with a `dim` flag, clamped to
    /// `[0, 1]` and non-decreasing (a partially off-edge band clips instead of folding). The view
    /// maps `dim` to the darkened ink; everything else is the resting ink.
    static func bandProfile(center: Double) -> [(location: Double, dim: Bool)] {
        let lead = unitClamp(center - bandHalfWidth)
        let mid = unitClamp(center)
        let trail = unitClamp(center + bandHalfWidth)
        return [(0, false), (lead, false), (mid, true), (trail, false), (1, false)]
    }

    /// Clamp to the unit interval — `Double.minimum`/`.maximum` per the repo float idiom.
    private static func unitClamp(_ value: Double) -> Double {
        Double.minimum(Double.maximum(value, 0), 1)
    }

    /// The title's foreground style at `date`: the resting `ink` during the rest beat, or the
    /// leading→trailing gradient carrying the darkened band mid-sweep.
    static func style(at date: Date, ink: Color) -> AnyShapeStyle {
        guard let center = bandCenter(at: date) else { return AnyShapeStyle(ink) }
        let dim = ink.opacity(dimOpacity)
        let stops = bandProfile(center: center).map { profile in
            Gradient.Stop(color: profile.dim ? dim : ink, location: profile.location)
        }
        return AnyShapeStyle(LinearGradient(
            stops: stops, startPoint: .leading, endPoint: .trailing,
        ))
    }
}

extension View {
    /// Paint this text in `ink` — shimmering (the stepped dark-band sweep) while `working`, plain
    /// ink otherwise. The `TimelineView` mounts ONLY on working rows, so a resting sidebar schedules
    /// nothing.
    @ViewBuilder
    func workingShimmer(_ working: Bool, ink: Color) -> some View {
        if working {
            TimelineView(.periodic(from: WorkingShimmer.epoch, by: WorkingShimmer.tick)) { context in
                foregroundStyle(WorkingShimmer.style(at: context.date, ink: ink))
            }
        } else {
            foregroundStyle(ink)
        }
    }
}
#endif
