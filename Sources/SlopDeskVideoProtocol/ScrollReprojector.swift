import Foundation

/// Native-Swift client-side scroll-hint reprojection law (the single source of truth — the former
/// Rust core `scroll_reprojection.rs` is retired).
///
/// PUBLIC so the client's `FramePacer` / `MetalVideoRenderer` wiring (in `SlopDeskVideoClient`) can
/// own one per video pane. v1 is CLIENT-ONLY: the client already originates the scroll delta locally,
/// so there is no wire / protocol change.
///
/// The law: integrate the local scroll velocity into a small normalized UV offset on the pacer's
/// *between-content* display ticks (so a remote window scrolls at the display rate), clamp it to a
/// band, decay it once the scroll stops, and RESET it to exactly zero the instant a real decoded
/// frame is presented (that frame already contains the scrolled content — resetting is what prevents
/// the double-count). One owner per pane; not thread-safe (the caller's main actor / pacer lock
/// serializes it).
///
/// Normalized units: a frame spans `0..1` on each axis, so the law is resolution-independent. Every
/// method takes the elapsed/now it needs as a parameter — no wall clock, no env, no I/O — so it is
/// deterministic to the bit. Non-finite inputs are dropped (treated as zero) so a bad event / clock
/// glitch can never poison the integrator.
public final class ScrollReprojector: @unchecked Sendable {
    /// Default maximum reprojection band per axis (normalized units), roughly an eighth of the frame.
    /// A hint never translates the frame by more than this fraction — past it the disocclusion gutter
    /// would dominate and the guess is worse than a static re-show, so the offset clamps.
    public static let defaultMaxBand: Double = 0.125
    /// Default decay time-constant (seconds) once a scroll has *stopped* (phase ended / momentum end).
    /// The offset bleeds to zero over ~this long so the picture eases to rest instead of snapping back
    /// when the velocity source goes quiet but no fresh frame has reset it yet.
    public static let defaultDecaySeconds: Double = 0.12

    /// The phase of a scroll velocity sample, mapped from the platform scroll phases.
    ///
    /// The Swift shell collapses the finer `CGScrollPhase` / `CGMomentumScrollPhase` codes into these
    /// three: a finger-on-glass *changed/began* is ``active``; a finger lift or a momentum *continue*
    /// keeps coasting under ``momentum``; a finger-lift *ended* or momentum *end* is ``ended`` and
    /// arms the decay. The raw values mirror the former `AISD_SCROLL_PHASE_*` discriminants.
    public enum Phase: UInt8 {
        /// Finger on glass: track velocity, no decay.
        case active = 0
        /// Inertial coast: track velocity, no decay.
        case momentum = 1
        /// Gesture finished: arm the decay.
        case ended = 2
    }

    /// Per-axis clamp on the integrated offset (normalized units), sanitized at construction.
    private let maxBand: Double
    /// Decay time-constant after a scroll ends (seconds), sanitized at construction.
    private let decaySeconds: Double

    /// Current integrated offset (normalized, clamped to `±maxBand`).
    private var offsetX: Double = 0.0
    private var offsetY: Double = 0.0
    /// Current velocity (normalized units per second).
    private var velX: Double = 0.0
    private var velY: Double = 0.0
    /// True once a scroll has ended: ``advance(elapsedSeconds:)`` decays the offset toward zero
    /// instead of integrating fresh velocity.
    private var decaying: Bool = false

    /// Builds a reprojector with the band (normalized units) + decay time-constant (seconds). Both
    /// are sanitized (clamped to a sane band; a non-finite knob falls back to its default) so a
    /// hostile value can never produce a runaway / negative offset. Offset and velocity start zero.
    public init(maxBand: Double, decaySeconds: Double) {
        // `Config::sanitized` parity: clamp each knob, fall back to the default on a non-finite knob.
        self.maxBand = maxBand.isFinite ? Self.clamp(maxBand, 0.0, 0.5) : Self.defaultMaxBand
        self.decaySeconds = decaySeconds.isFinite ? Self.clamp(decaySeconds, 0.0, 2.0) : Self.defaultDecaySeconds
    }

    /// Folds one scroll-velocity sample (`vx`/`vy` in normalized units per second) with its phase. A
    /// non-finite sample is dropped (treated as zero) so a bad event can never poison the integrator.
    ///
    /// An ``Phase/active`` / ``Phase/momentum`` sample sets the live velocity and disarms decay; an
    /// ``Phase/ended`` sample keeps the last velocity (the supplied one if finite/non-zero) but arms
    /// the decay so the next ``advance(elapsedSeconds:)`` eases the offset to rest.
    public func noteVelocity(vx: Double, vy: Double, phase: Phase) {
        let vx = vx.isFinite ? vx : 0.0
        let vy = vy.isFinite ? vy : 0.0
        switch phase {
        case .active,
             .momentum:
            velX = vx
            velY = vy
            decaying = false
        case .ended:
            // Keep coasting on the last known velocity unless this end-event carried its own (some
            // platforms send a final non-zero sample); then arm the decay.
            if vx != 0.0 || vy != 0.0 {
                velX = vx
                velY = vy
            }
            decaying = true
        }
    }

    /// Integrates the velocity over `elapsedSeconds` (or decays a stopped scroll), clamps each axis
    /// to `±maxBand`, and returns the resulting normalized offset `(x, y)`.
    ///
    /// Called once per spare (between-content) display tick with the time since the last tick. A
    /// non-finite / negative `elapsedSeconds` is treated as zero (the offset is returned unchanged)
    /// so a clock glitch can never jump the picture. While decaying, the offset shrinks geometrically
    /// toward zero on a `decaySeconds` time-constant and snaps to exactly zero once it is within a
    /// sub-pixel epsilon, so a stopped scroll settles cleanly.
    public func advance(elapsedSeconds: Double) -> (x: Double, y: Double) {
        let dt = (elapsedSeconds.isFinite && elapsedSeconds > 0.0) ? elapsedSeconds : 0.0
        if decaying {
            applyDecay(dt)
        } else {
            // keep mul+add separate — FMA breaks bit-exact parity
            // swiftlint:disable:next shorthand_operator
            offsetX = offsetX + velX * dt
            // keep mul+add separate — FMA breaks bit-exact parity
            // swiftlint:disable:next shorthand_operator
            offsetY = offsetY + velY * dt
        }
        clampToBand()
        return (offsetX, offsetY)
    }

    /// Resets the offset (and the integration baseline) to exactly zero — the no-double-count reset.
    ///
    /// Call the instant a real decoded frame is presented: that frame already contains the scrolled
    /// content, so any accumulated hint offset MUST be discarded or it would be added on top of the
    /// real scroll. The live velocity is preserved (the gesture may still be in flight — the next
    /// spare tick re-integrates from zero), but the decay flag is cleared since the fresh frame is the
    /// authoritative rest position.
    public func noteRealFrame() {
        offsetX = 0.0
        offsetY = 0.0
        decaying = false
    }

    /// Fully resets the reprojector (offset AND velocity to zero, decay cleared) — call when a pane
    /// goes idle / loses focus so a stale velocity can never resume on the next event.
    public func reset() {
        offsetX = 0.0
        offsetY = 0.0
        velX = 0.0
        velY = 0.0
        decaying = false
    }

    /// Geometric ease-out toward zero on the `decaySeconds` time-constant; snaps to exactly zero
    /// inside a sub-pixel epsilon so the offset settles rather than asymptoting forever.
    private func applyDecay(_ dt: Double) {
        // ~1/8000 of a frame: below one pixel on any realistic panel ⇒ treat as rest.
        let epsilon = 1.25e-4
        // A zero/degenerate time-constant means "stop instantly".
        if decaySeconds <= 0.0 {
            offsetX = 0.0
            offsetY = 0.0
            return
        }
        let factor = (-dt / decaySeconds).exp()
        offsetX *= factor
        offsetY *= factor
        if offsetX.magnitude < epsilon {
            offsetX = 0.0
        }
        if offsetY.magnitude < epsilon {
            offsetY = 0.0
        }
    }

    /// Clamps each axis to `±maxBand` so a fast flick can never translate the frame past the band
    /// (where the disocclusion gutter would dominate).
    private func clampToBand() {
        let band = maxBand
        offsetX = Self.clamp(offsetX, -band, band)
        offsetY = Self.clamp(offsetY, -band, band)
    }

    /// Ordered clamp mirroring Rust's `f64::clamp(min, max)`: assumes `min <= max`, returns `min` for
    /// inputs `< min`, `max` for inputs `> max`. Uses ordered `<` comparisons (a NaN input would fall
    /// through to itself, matching `f64::clamp`'s NaN passthrough) — all call sites here pass
    /// finite-or-sanitized inputs.
    private static func clamp(_ value: Double, _ minValue: Double, _ maxValue: Double) -> Double {
        if value < minValue {
            return minValue
        }
        if value > maxValue {
            return maxValue
        }
        return value
    }
}

private extension Double {
    /// `f64::exp()` parity (`Foundation`'s libm `exp`).
    func exp() -> Double {
        Foundation.exp(self)
    }
}
