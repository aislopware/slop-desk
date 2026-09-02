import CSlopDeskFFI
import Foundation
import SlopDeskArena

// MARK: - RemoteWindowRules (what a live video pane ADMITS)

/// The admission rules for one PATH-2 video stream, as `slopdesk-workspace::remote_window` answers
/// them.
///
/// They were nine guards inside ``RemoteWindowModel``, each sitting in front of the `@Observable`
/// write it protected. The writes stayed there — that is what `@Observable` is for — and the guards
/// came here, because not one of them names a view, a session or a socket.
///
/// ``GuiPaneReadout`` is the other half of this pane and the two do not overlap: that one RENDERS a
/// reading, this one decides whether the reading is a reading at all.
///
/// ### A zero is not one thing
///
/// Deliberately NOT uniform, and the reason these are written down once rather than re-derived at
/// each call site: a cadence of `0` is nonsense and is dropped, a bitrate of `0` is what an idle
/// stream measures and is kept, and a latency of `0` is the absence of a reading and becomes `nil`.
public enum RemoteWindowRules {
    // MARK: The entry field

    /// The window id an entry field holds, or `nil` when what is in it is not one.
    ///
    /// This is NOT `UInt32(text)` re-implemented loosely: the rule reproduces Swift's own parser
    /// over Swift's own `CharacterSet.whitespaces`, which disagrees with Rust's `trim`/`parse` on
    /// line breaks (Swift refuses `"42\n"`) and on `-0` (Swift accepts it as `0`). Both divergences
    /// are reachable by pasting into the field, and both are pinned by the Rust suite.
    public static func parseWindowID(_ entered: String) -> UInt32? {
        var parsed: UInt32 = 0
        let found = ffiLend(entered) { text in
            slopdesk_ws_stream_window_id(text.baseAddress, text.count, &parsed)
        }
        return found ? parsed : nil
    }

    // MARK: Geometry

    /// What one geometry push from the live pane is allowed to write.
    public struct Geometry: Equatable, Sendable {
        /// The window's current point size, or `nil` when the push carried no usable one.
        public var current: CGSize?
        /// The maximum resizable point size, or `nil` when the push carried no usable one.
        public var max: CGSize?
    }

    /// The two verdicts on one geometry push, taken apart: a host that has reported its window but
    /// not yet its display bounds sends a real current size beside a zero max.
    ///
    /// A `nil` max does NOT mean "no maximum" — it means this push carried none, and the caller
    /// leaves the cap it already knows standing.
    public static func geometry(currentW: Double, currentH: Double, maxW: Double, maxH: Double) -> Geometry {
        let answer = slopdesk_ws_stream_geometry(currentW, currentH, maxW, maxH)
        return Geometry(
            current: answer.has_current
                ? CGSize(width: answer.current_width, height: answer.current_height) : nil,
            max: answer.has_max ? CGSize(width: answer.max_width, height: answer.max_height) : nil,
        )
    }

    // MARK: The two scalar axes

    /// Whether a host-announced cadence is an announcement. Non-positive is not, and the last good
    /// reading stands rather than the row blanking.
    public static func admitsStreamFps(_ fps: Int) -> Bool {
        slopdesk_ws_stream_admits_fps(Int64(fps))
    }

    /// Whether a measured payload bitrate is a measurement. Only a negative is not — a zero is what
    /// an idle stream measures, and it is kept.
    public static func admitsStreamKbps(_ kbps: Int) -> Bool {
        slopdesk_ws_stream_admits_kbps(Int64(kbps))
    }

    // MARK: The ~2 Hz network sample

    /// One ADMITTED network sample. The rate axes are measurements; the latency axes are `Optional`
    /// because a zero there means "nobody has measured yet" and the readout must draw a dash.
    public struct NetworkReading: Equatable, Sendable {
        /// Frames per second received.
        public var fps: Double
        /// Frames per second the error correction recovered.
        public var fecPerSec: Double
        /// Frames per second lost past recovery.
        public var unrecoveredPerSec: Double
        /// Round-trip time in milliseconds, or `nil` when the host reported none.
        public var rttMs: Double?
        /// Encode wall time in milliseconds, or `nil` when the host reported none.
        public var encodeMs: Double?
        /// Decode wall time in milliseconds, or `nil` when nothing has decoded yet.
        public var decodeMs: Double?
        /// How long the newest frame has been held, in milliseconds.
        public var holdMs: Int
        /// How many frames the presentation pacer is holding.
        public var pacerDepth: Int
    }

    /// One ~2 Hz sample as a reading, or `nil` when any axis is negative or `NaN`.
    ///
    /// ALL OR NOTHING: rates and depths are non-negative by construction, so a negative one means
    /// the telemetry window itself is wrong, and mixing a trustworthy frame rate with a garbage loss
    /// count produces a readout that is confidently incorrect on half its rows.
    public static func networkReading(
        fps: Double, fecPerSec: Double, unrecoveredPerSec: Double, holdMs: Int, pacerDepth: Int,
        rttMs: Double, encodeMs: Double, decodeMs: Double,
    ) -> NetworkReading? {
        let sample = SlopDeskWsStreamSample(
            fps: fps,
            fec_per_sec: fecPerSec,
            unrecovered_per_sec: unrecoveredPerSec,
            rtt_ms: rttMs,
            encode_ms: encodeMs,
            decode_ms: decodeMs,
            hold_ms: Int64(clamping: holdMs),
            pacer_depth: Int64(clamping: pacerDepth),
        )
        let answer = slopdesk_ws_stream_network(sample)
        guard answer.admitted else { return nil }
        return NetworkReading(
            fps: answer.fps,
            fecPerSec: answer.fec_per_sec,
            unrecoveredPerSec: answer.unrecovered_per_sec,
            rttMs: answer.has_rtt_ms ? answer.rtt_ms : nil,
            encodeMs: answer.has_encode_ms ? answer.encode_ms : nil,
            decodeMs: answer.has_decode_ms ? answer.decode_ms : nil,
            holdMs: Int(answer.hold_ms),
            pacerDepth: Int(answer.pacer_depth),
        )
    }

    // MARK: The immersive fold

    /// What an immersive toggle commits.
    public struct ImmersiveCommit: Equatable, Sendable {
        /// The latched wish after the fold — always the requested value.
        public var desired: Bool
        /// The fullscreen auto-arm after the fold, which an explicit OFF always clears.
        public var fullscreenOverride: Bool
        /// Whether the wish actually moved, and so whether the pane's spec should be rewritten.
        public var notifies: Bool
    }

    /// The immersive toggle's fold: the wish becomes `on`, and an explicit OFF drops the fullscreen
    /// auto-arm with it — the escape hatch has to win (docs/DECISIONS.md, the Moonlight lesson).
    public static func immersiveCommit(on: Bool, desired: Bool, fullscreenOverride: Bool) -> ImmersiveCommit {
        let answer = slopdesk_ws_stream_immersive(on, desired, fullscreenOverride)
        return ImmersiveCommit(
            desired: answer.desired,
            fullscreenOverride: answer.fullscreen_override,
            notifies: answer.notifies,
        )
    }

    // MARK: The restore seed

    /// A restored mode snapshot's two overrides, floored at `0` — which is Auto, the value a fresh
    /// session already holds. A negative cap in a hand-edited workspace file must not travel to the
    /// host as a request.
    public static func seededCaps(fpsCap: Int, bitrateCeilingBps: Int) -> (fpsCap: Int, bitrateCeilingBps: Int) {
        let answer = slopdesk_ws_stream_seeded_caps(Int64(clamping: fpsCap), Int64(clamping: bitrateCeilingBps))
        return (Int(answer.fps_cap), Int(answer.bitrate_ceiling_bps))
    }

    // MARK: The two sentences

    /// What the opened descriptor is CALLED: the bound title, or `window <id>` when it has none.
    ///
    /// Never empty, so the door's `0` is a refusal that cannot collide with a real answer.
    public static func descriptorTitle(_ title: String, windowID: UInt32) -> String {
        ffiLend(title) { text in
            ffiAnswerText(capacity: 128) { out, cap in
                slopdesk_ws_stream_title(text.baseAddress, text.count, windowID, out, cap)
            }
        }
    }

    /// What the placeholder says when the host REFUSES the session — the target is gone on the host,
    /// or the two halves disagree about the protocol.
    public static func rejectionMessage(title: String) -> String {
        ffiLend(title) { text in
            ffiAnswerText(capacity: 128) { out, cap in
                slopdesk_ws_stream_rejection(text.baseAddress, text.count, out, cap)
            }
        }
    }

    /// What the placeholder says when NOTHING answered the hello inside the hello deadline — no
    /// `slopdesk-videohostd` at the address the pane dialled. Names the address and the daemon.
    public static func unreachableMessage(host: String, mediaPort: UInt16) -> String {
        ffiLend(host) { text in
            ffiAnswerText(capacity: 256) { out, cap in
                slopdesk_ws_stream_unreachable(text.baseAddress, text.count, mediaPort, out, cap)
            }
        }
    }
}

// MARK: - HostWindowFeedRules (the host-windows rail's fold)

/// The host-windows rail's folds, as `slopdesk-workspace::window_feed` answers them.
///
/// `docs/45` §1 names the UX this exists for in one word — STABILITY. The host re-sends its whole
/// window list twice a second, so a rail that followed the snapshot's order would shuffle rows under
/// the pointer on every focus flip and title change. ``foldStructure(_:_:existingID:incomingID:adopting:)``
/// freezes positions instead: a window that survives keeps the place it had, and only a genuinely new
/// one is appended.
public enum HostWindowFeedRules {
    /// The rail's display title: the window's own, or the app's name when the window has none.
    ///
    /// The EMPTY answer is REAL here (an untitled window belonging to an unnamed app), so the door's
    /// `0` is mapped to `""` rather than treated as a refusal — the one place this face does that.
    public static func displayTitle(title: String, appName: String) -> String {
        ffiLend(title) { titleText in
            ffiLend(appName) { appText in
                ffiAnswerText(capacity: 128) { out, cap in
                    slopdesk_ws_feed_display_title(
                        titleText.baseAddress, titleText.count,
                        appText.baseAddress, appText.count,
                        out, cap,
                    )
                }
            }
        }
    }

    /// The structure after one snapshot: survivors in the order they already had, then the newcomers
    /// in the order the host sent them. Nothing is ever reordered.
    ///
    /// ### Identity stays here
    ///
    /// A `CGWindowID` is identity, so it does not cross. This mints one dense TOKEN per distinct
    /// window across BOTH lists — one table spanning the comparison — and the rule answers POSITIONS
    /// into the two arrays this function still holds. `adopt` builds the record for a newcomer, so
    /// the bundle id and the app name never travel at all.
    ///
    /// ### The duplicate case is the Swift's, on purpose
    ///
    /// A snapshot naming the same window twice appends it twice: the rule computes its "already
    /// known" set once, before the append pass, exactly as the Swift `apply` did. The host does not
    /// emit duplicates, and quietly changing what a malformed snapshot produces would be an
    /// unreported behaviour change hiding inside a port.
    public static func foldStructure<Existing, Incoming>(
        _ structure: [Existing],
        _ snapshot: [Incoming],
        existingID: (Existing) -> UInt32,
        incomingID: (Incoming) -> UInt32,
        adopting adopt: (Incoming) -> Existing,
    ) -> [Existing] {
        var minted: [UInt32: UInt32] = [:]
        func token(_ identity: UInt32) -> UInt32 {
            if let known = minted[identity] { return known }
            let next = UInt32(truncatingIfNeeded: minted.count)
            minted[identity] = next
            return next
        }
        let held = structure.map { token(existingID($0)) }
        let arrived = snapshot.map { token(incomingID($0)) }
        // The arithmetic bound — nothing can be kept AND added — so the docs/55 §4 retry is there
        // for correctness and is never travelled.
        var slots = [SlopDeskWsFeedFoldSlot](
            repeating: SlopDeskWsFeedFoldSlot(), count: held.count + arrived.count,
        )
        let count = held.withUnsafeBufferPointer { existing in
            arrived.withUnsafeBufferPointer { incoming in
                slots.withUnsafeMutableBufferPointer { out in
                    slopdesk_ws_feed_structure_plan(
                        existing.baseAddress, existing.count,
                        incoming.baseAddress, incoming.count,
                        out.baseAddress, out.count,
                    )
                }
            }
        }
        guard count <= slots.count else { return structure }
        return slots.prefix(count).compactMap { (slot: SlopDeskWsFeedFoldSlot) -> Existing? in
            let position = Int(slot.index)
            if slot.is_new {
                return snapshot.indices.contains(position) ? adopt(snapshot[position]) : nil
            }
            return structure.indices.contains(position) ? structure[position] : nil
        }
    }

    /// The POSITION of the host's focused window in the snapshot, or `nil` when none is focused. At
    /// most one window per snapshot carries the flag, so the first is the answer.
    public static func frontmost(_ focused: [Bool]) -> Int? {
        let position = focused.withUnsafeBufferPointer { flags in
            slopdesk_ws_feed_frontmost(flags.baseAddress, flags.count)
        }
        guard position >= 0, position < focused.count else { return nil }
        return position
    }

    /// Whether a "you are current" ack may mark the feed LIVE — only when it names the generation
    /// this client actually holds. A stale or duplicated datagram acking an older generation is not
    /// confirmation of what we have, and UDP delivers both.
    public static func ackMarksLive(isLive: Bool, acked: UInt32, known: UInt32) -> Bool {
        slopdesk_ws_feed_ack_marks_live(isLive, acked, known)
    }

    /// Whether the renewal interval that just elapsed makes the feed stale: no answer for two full
    /// renewal gaps plus the first-answer gap.
    ///
    /// UDP weather loses single datagrams, not multi-second stretches, so one missed reply must not
    /// dim a rail that is fine. `elapsed` is `nil` when no answer has ever landed, which is not
    /// staleness — it is the state before any interval has been timed.
    public static func goesStale(
        isLive: Bool,
        answeredSinceOpen: Bool,
        elapsed: Duration?,
        renewalGap: Duration,
        firstAnswerGap: Duration,
    ) -> Bool {
        slopdesk_ws_feed_goes_stale(
            isLive, answeredSinceOpen, elapsed != nil,
            nanoseconds(elapsed ?? .zero), nanoseconds(renewalGap), nanoseconds(firstAnswerGap),
        )
    }

    /// How long to wait before the next renewal: the fast retransmit gap until the FIRST answer
    /// lands on a freshly opened lane, the ordinary gap after that.
    public static func renewalWait(
        answeredSinceOpen: Bool,
        renewalGap: Duration,
        firstAnswerGap: Duration,
    ) -> Duration {
        .nanoseconds(slopdesk_ws_feed_renewal_wait_ns(
            answeredSinceOpen, nanoseconds(renewalGap), nanoseconds(firstAnswerGap),
        ))
    }

    /// A `Duration` as whole NANOSECONDS, saturating rather than trapping.
    ///
    /// The boundary takes an `int64_t` because C has no `Duration`, and the attoseconds below a
    /// nanosecond are dropped: every gap on this path is measured in hundreds of milliseconds, so
    /// the truncation is unobservable, and a trap here would abort a process over a clock.
    private static func nanoseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        let ceiling: Int64 = parts.seconds < 0 ? .min : .max
        let scaled = parts.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !scaled.overflow else { return ceiling }
        let total = scaled.partialValue.addingReportingOverflow(parts.attoseconds / 1_000_000_000)
        return total.overflow ? ceiling : total.partialValue
    }
}
