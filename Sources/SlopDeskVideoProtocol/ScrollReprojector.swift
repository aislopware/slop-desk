import CSlopDeskFFI

/// The Swift face of `rust/slopdesk-video`'s `scroll_reproject`, reached through the door of the
/// same name.
///
/// PUBLIC so the client's `FramePacer` / `MetalVideoRenderer` wiring (in `SlopDeskVideoClient`) can
/// own one per video pane. v1 is CLIENT-ONLY: the client already originates the scroll delta
/// locally, so there is no wire / protocol change.
///
/// The law: integrate the local scroll velocity into a small normalized UV offset on the pacer's
/// *between-content* display ticks (so a remote window scrolls at the display rate), clamp it to a
/// band, decay it once the scroll stops, and RESET it to exactly zero the instant a real decoded
/// frame is presented (that frame already contains the scrolled content — resetting is what
/// prevents the double-count).
///
/// A class, because a pane holds ONE of these by reference and every tick folds it; the STATE is
/// seven scalars and crosses by value, which is why the arithmetic — the separate multiply and add
/// that must never fuse, the ordered clamps, the ease-out and its rest epsilon — is spelled once,
/// on the far side. One owner per pane; not thread-safe (the caller's main actor / pacer lock
/// serializes it).
public final class ScrollReprojector: @unchecked Sendable {
    /// Default maximum reprojection band per axis (normalized units), roughly an eighth of the
    /// frame. A hint never translates the frame by more than this fraction — past it the
    /// disocclusion gutter would dominate and the guess is worse than a static re-show.
    public static let defaultMaxBand = defaults.max_band
    /// Default decay time-constant (seconds) once a scroll has *stopped* (phase ended / momentum
    /// end). The offset bleeds to zero over ~this long so the picture eases to rest instead of
    /// snapping back when the velocity source goes quiet but no fresh frame has reset it yet.
    public static let defaultDecaySeconds = defaults.decay_seconds

    private static let defaults = slopdesk_scroll_reprojector_defaults()

    /// The phase of a scroll velocity sample, mapped from the platform scroll phases.
    ///
    /// The Swift shell collapses the finer `CGScrollPhase` / `CGMomentumScrollPhase` codes into
    /// these three: a finger-on-glass *changed/began* is ``active``; a finger lift or a momentum
    /// *continue* keeps coasting under ``momentum``; a finger-lift *ended* or momentum *end* is
    /// ``ended`` and arms the decay.
    public enum Phase: UInt8 {
        /// Finger on glass: track velocity, no decay.
        case active = 0
        /// Inertial coast: track velocity, no decay.
        case momentum = 1
        /// Gesture finished: arm the decay.
        case ended = 2

        /// The phase the platform's two scroll codes name together, as the far side collapses them.
        ///
        /// `CGScrollPhase` is `1` began, `2` changed, `4` ended, `8` cancelled;
        /// `CGMomentumScrollPhase` is `1` begin, `2` continue, `3` end. The momentum code wins,
        /// because it is the later half of one gesture.
        public init(scrollPhase: UInt8, momentumPhase: UInt8) {
            let code = slopdesk_scroll_phase_of_platform(scrollPhase, momentumPhase)
            self =
                switch code {
                case SLOPDESK_SCROLL_PHASE_MOMENTUM: .momentum
                case SLOPDESK_SCROLL_PHASE_ENDED: .ended
                default: .active
                }
        }
    }

    /// One host-MEASURED per-frame scroll shift, in the fixed-point units it crosses the wire in:
    /// a signed shift in ten-thousandths of the frame extent, plus the moving-content band in the
    /// same units.
    ///
    /// The host measures the TRUE pixel shift between two captured frames; the client must never
    /// guess one from local trackpad deltas, because the host applies momentum, acceleration and
    /// clamping the client cannot know and a guess snaps and shakes. Both halves of the encoding —
    /// the host's and the client's — live on the far side, together, because they are one encoding:
    /// a scale spelled on only one side is a scale the two ends can drift apart on.
    public struct Hint: Equatable, Sendable {
        /// The signed horizontal shift over one frame, in ten-thousandths of the frame width.
        public var dx: Int16 { record.dx }
        /// The signed vertical shift over one frame, in ten-thousandths of the frame height.
        public var dy: Int16 { record.dy }
        /// The band's top edge, in ten-thousandths of the frame height.
        public var bandTop: UInt16 { record.band_top }
        /// The band's bottom edge, exclusive, in the same units.
        public var bandBottom: UInt16 { record.band_bottom }

        private var record: SlopDeskScrollHint

        /// The hint a measured estimate encodes, over the frame height it was measured on.
        ///
        /// `shift` is in rows, positive meaning the content moved DOWN; `bandTopRow` /
        /// `bandBottomRow` are the INCLUSIVE current-frame row span of the moving content, negative
        /// when there is none. An unconfident or zero shift, or a degenerate height, answers the
        /// hint that says nothing moved — a defined "nothing to reproject", never a fault.
        public init(
            shift: Int32,
            confidenceMilli: UInt32,
            bandTopRow: Int32,
            bandBottomRow: Int32,
            height: Int,
        ) {
            record = slopdesk_scroll_hint_measured(
                shift, confidenceMilli, bandTopRow, bandBottomRow, height,
            )
        }

        /// The hint these four wire integers describe, as the client receives them.
        public init(dx: Int16, dy: Int16, bandTop: UInt16, bandBottom: UInt16) {
            record = SlopDeskScrollHint(dx: dx, dy: dy, band_top: bandTop, band_bottom: bandBottom)
        }

        /// The velocity sample this hint is (normalized units per second), given the rate the
        /// content frames arrive at. A zero shift is the host saying the scroll STOPPED, which is
        /// ``Phase/ended`` and arms the decay — the client never sees the finger, so that is the
        /// only phase it can honestly report.
        public func velocity(contentFps: Double) -> (vx: Double, vy: Double, phase: Phase) {
            let sample = slopdesk_scroll_hint_velocity(record, contentFps)
            let phase: Phase =
                switch sample.phase {
                case SLOPDESK_SCROLL_PHASE_MOMENTUM: .momentum
                case SLOPDESK_SCROLL_PHASE_ENDED: .ended
                default: .active
                }
            return (sample.vx, sample.vy, phase)
        }

        /// The moving-content band as normalized edges, or `nil` when this hint carries none.
        ///
        /// `nil` is not "an empty band": a caller holding one from an earlier frame should KEEP it,
        /// so a decay tick eases out still masked.
        public func band() -> (top: Float, bottom: Float)? {
            let band = slopdesk_scroll_hint_band(record)
            guard band.present else { return nil }
            return (band.top, band.bottom)
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.dx == rhs.dx && lhs.dy == rhs.dy
                && lhs.bandTop == rhs.bandTop && lhs.bandBottom == rhs.bandBottom
        }
    }

    /// The door's code for one phase.
    private static func code(of phase: Phase) -> UInt32 {
        switch phase {
        case .active: SLOPDESK_SCROLL_PHASE_ACTIVE
        case .momentum: SLOPDESK_SCROLL_PHASE_MOMENTUM
        case .ended: SLOPDESK_SCROLL_PHASE_ENDED
        }
    }

    /// The integrator: both knobs and the live offset, velocity and decay flag.
    private var record: SlopDeskScrollReprojector

    /// Builds a reprojector with the band (normalized units) + decay time-constant (seconds). Both
    /// are sanitized on the far side — clamped to a sane band, a non-finite knob falling back to
    /// its default — so a hostile value can never produce a runaway / negative offset. Offset and
    /// velocity start zero.
    public init(maxBand: Double, decaySeconds: Double) {
        record = slopdesk_scroll_reprojector_new(maxBand, decaySeconds)
    }

    /// Folds one scroll-velocity sample (`vx`/`vy` in normalized units per second) with its phase.
    /// A non-finite sample is dropped (treated as zero) so a bad event can never poison the
    /// integrator.
    ///
    /// An ``Phase/active`` / ``Phase/momentum`` sample sets the live velocity and disarms decay; an
    /// ``Phase/ended`` sample keeps the last velocity (the supplied one if non-zero) but arms the
    /// decay so the next ``advance(elapsedSeconds:)`` eases the offset to rest.
    public func noteVelocity(vx: Double, vy: Double, phase: Phase) {
        record = slopdesk_scroll_reprojector_note_velocity(record, vx, vy, Self.code(of: phase))
    }

    /// Integrates the velocity over `elapsedSeconds` (or decays a stopped scroll), clamps each axis
    /// to the band, and returns the resulting normalized offset `(x, y)`.
    ///
    /// Called once per spare (between-content) display tick with the time since the last tick. A
    /// non-finite / negative `elapsedSeconds` is treated as zero (the offset comes back unchanged)
    /// so a clock glitch can never jump the picture.
    public func advance(elapsedSeconds: Double) -> (x: Double, y: Double) {
        let step = slopdesk_scroll_reprojector_advance(record, elapsedSeconds)
        record = step.reprojector
        return (step.offset.x, step.offset.y)
    }

    /// Resets the offset (and the integration baseline) to exactly zero — the no-double-count
    /// reset.
    ///
    /// Call the instant a real decoded frame is presented: that frame already contains the scrolled
    /// content, so any accumulated hint offset MUST be discarded or it would be added on top of the
    /// real scroll. The live velocity is preserved (the gesture may still be in flight — the next
    /// spare tick re-integrates from zero), but the decay flag is cleared since the fresh frame is
    /// the authoritative rest position.
    public func noteRealFrame() {
        record = slopdesk_scroll_reprojector_note_real_frame(record)
    }

    /// Fully resets the reprojector (offset AND velocity to zero, decay cleared) — call when a pane
    /// goes idle / loses focus so a stale velocity can never resume on the next event.
    public func reset() {
        record = slopdesk_scroll_reprojector_reset(record)
    }
}
