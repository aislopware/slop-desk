//! Every video path that used to be Swift, and the shapes that would bring it back.
//!
//! Ported from the deleted `check-supervisor.sh`, the long stretch after §9. What all of these have
//! in common is the failure mode: a Swift re-implementation of any of them would not fail a test.
//! It would be a second implementation of the WIRE, and the byte-identity pins would keep passing
//! right up until the two drifted — on one machine, mid-session, on the link that was already
//! lossy.
//!
//! So none of these assert BEHAVIOUR. They assert SHAPE: the Swift file still calls each door, and
//! the names a re-implementation would need are absent.

use crate::claim::{Claim, RUST, SWIFT, SWIFT_ROOTS, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The Rust host, which is where every claim that used to name the Swift one now points.
const DAEMON: &str = "rust/slopdesk-videohostd";

const PACKETIZER: &str = "Sources/SlopDeskVideoProtocol/FramePacketizer.swift";
const REASSEMBLER: &str = "Sources/SlopDeskVideoProtocol/FrameReassembler.swift";
const ADAPTIVE_FEC: &str = "Sources/SlopDeskVideoProtocol/AdaptiveFECPolicy.swift";
const RECOVERY: &str = "Sources/SlopDeskVideoProtocol/RecoverySignaling.swift";
const MUX: &str = "Sources/SlopDeskVideoProtocol/Mux/VideoMuxHeaderCodec.swift";
const INPUT: &str = "Sources/SlopDeskVideoProtocol/InputEventCodec.swift";
const FRAME_MEASURE: &str = "Sources/SlopDeskVideoProtocol/FrameMeasurement.swift";
const CLIENT_SESSION: &str = "Sources/SlopDeskVideoClient/SlopDeskVideoClientSession.swift";

/// The FEC field and the send path.
///
/// `GF256.swift` carried the field and `NeonGf`, the hand-written kernel that reached into
/// `Sources/CSlopDeskSIMD` with `UnsafeBufferPointer` and a `swiftlint:disable force_unwrapping` —
/// the least safe code here, on the path that parses hostile UDP. All of it is
/// `rust/slopdesk-video` now, with the one vector loop isolated in `rust/slopdesk-gfsimd`.
///
/// The SEND path went the same way one layer up. `VideoPacketizer` is a handle onto that crate's
/// packetizer: the MTU split, the tier ladder's per-frame FEC shape, the parity, the interleave and
/// the 19-byte stamp are all over there. The transmit reorder went with it — it had ONE caller left
/// outside the packetizer, `slopdesk-loopback-validate`, reordering by hand after asking for an
/// un-interleaved frame, which is the shape a mirror takes: a tool that reproduces the host's
/// composition instead of driving it.
///
/// The SENDER at the top of that path is no longer Swift at all. `VideoSessionLogic` used to be
/// asked here not to grow a second `scheduleFrame`, and `docs/61` deleted it as a face; the same
/// question is now asked of `rust/slopdesk-videohostd`, which is the only sender left. It has to be
/// asked, because the daemon started life with a `packetize.rs` that had re-declared the crate's
/// own `Outgoing` and `schedule_frame_raw` — the drift is not hypothetical, it is what `docs/61 §3`
/// deleted. The verdict must be single for the reason the golden vectors exist: what leaves this
/// host is pinned byte-for-byte against `rust/slopdesk-video`'s composition, so a daemon-local
/// second composition is unpinned by construction and de-syncs a client mid-session rather than
/// failing a test. The "no Swift brings this back" half is stated tree-wide in
/// [`crate::rules::deleted_video_swift`].
///
/// The ban covers the crate's own name, `schedule_frame_raw`, and not only the shorter one, because
/// the ask above is satisfied by an IMPORT LINE. A daemon that declared its own `fn
/// schedule_frame_raw` would still be spelling the name the ask looks for, so the ask alone would
/// read green on precisely the file that re-derived the law. The ban is what makes the pair decide
/// anything: one half says the daemon must reach for the crate, the other says the reach must not
/// be to itself.
#[must_use]
pub fn send_path(tree: &Tree) -> Report {
    let claims = [
        Claim::Absent {
            path: "Sources/SlopDeskVideoProtocol/GF256.swift",
            message: "the FEC field lives in rust/slopdesk-video, its kernel in rust/slopdesk-gfsimd",
        },
        Claim::Absent {
            path: "Sources/SlopDeskVideoProtocol/ReedSolomonMatrix.swift",
            message: "the FEC field lives in rust/slopdesk-video, its kernel in rust/slopdesk-gfsimd",
        },
        Claim::Absent {
            path: "Sources/CSlopDeskSIMD",
            message: "the FEC field lives in rust/slopdesk-video, its kernel in rust/slopdesk-gfsimd",
        },
        Claim::Absent {
            path: "Tests/SlopDeskVideoProtocolTests/GF256NeonDifferentialTests.swift",
            message: "the FEC field lives in rust/slopdesk-video, its kernel in rust/slopdesk-gfsimd",
        },
        Claim::NoneUnder {
            roots: SWIFT_ROOTS,
            extensions: SWIFT,
            pattern: r"(enum|struct|final class) (GF256|NeonGf|ReedSolomonMatrix)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift GF(2^8) backend is back in {files} — one implementation, and it is the Rust \
                      one",
        },
        Claim::Doors {
            path: PACKETIZER,
            entries: &[
                "slopdesk_video_packetizer_raw",
                "slopdesk_video_packetizer_answer",
                "slopdesk_video_packetizer_free",
                // The datagram CODEC — the 19-byte header both paths meet at — is the same crate's,
                // reached from the one Swift file that still names the layout. It is the easiest of
                // the three to rewrite by accident: nineteen bytes of big-endian appends look like
                // something a reader "fixes" inline.
                "slopdesk_video_fragment_encode",
                "slopdesk_video_fragment_decode",
            ],
            message: "Sources/SlopDeskVideoProtocol/FramePacketizer.swift no longer calls {entry} — the \
                      send path and the wire layout are rust/slopdesk-video's (docs/55 §4b)",
        },
        Claim::Lacks {
            path: PACKETIZER,
            pattern: r"func (packetizeFragments|makeFragment)",
            view: View::Code,
            message: "Sources/SlopDeskVideoProtocol/FramePacketizer.swift grew a fragment builder back — \
                      the fragments are built in rust/slopdesk-video",
        },
        Claim::Lacks {
            path: PACKETIZER,
            pattern: r"appendBE\(header\.",
            view: View::Code,
            message: "Sources/SlopDeskVideoProtocol/FramePacketizer.swift builds a header byte by byte \
                      again — encode it through the Rust codec",
        },
        Claim::Absent {
            path: "Sources/SlopDeskVideoProtocol/FragmentInterleaver.swift",
            message: "the reorder law is rust/slopdesk-video's, reached through packetize(interleave:)",
        },
        Claim::Absent {
            path: "Tests/SlopDeskVideoProtocolTests/FragmentInterleaverTests.swift",
            message: "the reorder law is rust/slopdesk-video's, reached through packetize(interleave:)",
        },
        // The host end of the same path, now that the host is Rust. `docs/61 §3` deleted
        // `packetize.rs` from the daemon because it had re-declared the rules crate's own
        // `Outgoing` and `schedule_frame_raw`; the daemon ASKS for both instead.
        Claim::MentionsUnder {
            root: DAEMON,
            names: &[
                "packetizer",
                "recovery_routing",
                "schedule_frame_raw",
                "send_pacing",
            ],
            message: "rust/slopdesk-videohostd stopped naming {entry} — the send path's fragments, its \
                      routing verdict, its raw-frame schedule and its pacing are rust/slopdesk-video's, and \
                      a daemon that no longer asks for one of them is either deriving it or has dropped it \
                      (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"fn schedule_frame(_raw)? *\(|\b(struct|enum) Outgoing\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "rust/slopdesk-videohostd re-declares the send path's own shape in {files} — \
                      `Outgoing` and the frame schedule are slopdesk_video::recovery_routing's, and a \
                      daemon-local copy is a second answer to what goes on the wire, byte-for-byte \
                      invisible to the golden vectors that pin the crate's (docs/61 §3)",
        },
    ];
    check_all(tree, &claims)
}

/// The receive path, which is the half that parses hostile UDP.
///
/// Every fragment-count, frag-index and frontier-jump guard is `rust/slopdesk-video`'s
/// `reassembler` now. A Swift rebuild here would be the worst of the three to have twice, because
/// the guards are what stop a crafted datagram allocating per frame, and two copies of a guard
/// drift silently.
#[must_use]
pub fn receive_path(tree: &Tree) -> Report {
    let claims = [
        Claim::Doors {
            path: REASSEMBLER,
            entries: &[
                "slopdesk_video_reassembler_ingest",
                "slopdesk_video_reassembler_frame_avcc",
                "slopdesk_video_reassembler_free",
            ],
            message: "Sources/SlopDeskVideoProtocol/FrameReassembler.swift no longer calls {entry} — the \
                      receive path is Rust's (docs/55 §4b)",
        },
        // The guards' own names, which only a re-implementation would need back.
        Claim::Lacks {
            path: REASSEMBLER,
            pattern: "maxFrontierJump|resyncStreak|resyncClusterWindow|frontierJumpCandidates",
            view: View::Code,
            message: "Sources/SlopDeskVideoProtocol/FrameReassembler.swift grew a hostile-input guard back \
                      — those guards are Rust's",
        },
    ];
    check_all(tree, &claims)
}

/// The FEC ladder and the recovery channel — both read off the wire by both ends.
///
/// A drifted threshold does not fail a test: it de-syncs a host from a client mid-session, on the
/// exact link that was already losing packets. The recovery decoder is the other place hostile
/// input is parsed, and its trailing-bytes rejection is load-bearing: the host's deduper keys on
/// RAW datagram bytes, so a decoder that tolerated suffixes would re-admit one logical request as
/// two host actions.
#[must_use]
pub fn ladder_and_recovery(tree: &Tree) -> Report {
    let claims = [
        Claim::Doors {
            path: ADAPTIVE_FEC,
            entries: &[
                "slopdesk_adaptive_fec_group_size",
                "slopdesk_adaptive_fec_tier",
                "slopdesk_adaptive_fec_next_tier_state",
                "slopdesk_adaptive_fec_next_parity_tier_state",
                "slopdesk_adaptive_fec_constant",
            ],
            message: "Sources/SlopDeskVideoProtocol/AdaptiveFECPolicy.swift no longer calls {entry} — the \
                      ladder is rust/slopdesk-video's",
        },
        // The level ladder's own names: a re-implementation needs every one of them back.
        Claim::Lacks {
            path: ADAPTIVE_FEC,
            pattern: r"func (levelForTier|tierForLevel|targetLevel|mLevelForTier|tierForMLevel|mTargetLevel)",
            view: View::Code,
            message: "Sources/SlopDeskVideoProtocol/AdaptiveFECPolicy.swift grew a level-ladder function \
                      back — the hysteresis and the dwell are Rust's",
        },
        // A differential fixture goes with the second implementation. A test carrying a verbatim
        // copy of the deleted logic as its oracle IS the mirror the rule forbids.
        Claim::Absent {
            path: "Tests/SlopDeskVideoProtocolTests/RustAdaptiveFECParityTests.swift",
            message: "there is one ladder now, so there is nothing to diff",
        },
        Claim::Doors {
            path: RECOVERY,
            entries: &[
                "slopdesk_recovery_encode",
                "slopdesk_recovery_decode",
                "slopdesk_recovery_should_escalate_to_idr",
                "slopdesk_recovery_loss_window_note",
                "slopdesk_recovery_loss_window_observing",
                "slopdesk_recovery_constant",
            ],
            message: "Sources/SlopDeskVideoProtocol/RecoverySignaling.swift no longer calls {entry} — the \
                      recovery channel is rust/slopdesk-video's",
        },
        Claim::Lacks {
            path: RECOVERY,
            pattern: "VideoByteReader|encodeRequestFragments|decodeRequestFragments",
            view: View::Code,
            message: "Sources/SlopDeskVideoProtocol/RecoverySignaling.swift grew a reader back — the \
                      recovery wire is parsed once, in Rust",
        },
        Claim::Absent {
            path: "Tests/SlopDeskVideoProtocolTests/RustRecoveryPolicyParityTests.swift",
            message: "one policy means there is nothing to diff",
        },
        Claim::Absent {
            path: "Tests/SlopDeskVideoProtocolTests/RustCoordinateMappingParityTests.swift",
            message: "one mapping means there is nothing to diff",
        },
    ];
    check_all(tree, &claims)
}

/// The mux prefix, the input events, and the loss-resilient burst.
///
/// The UDP MUX PREFIX fronts every datagram on the video flow and splits every one that arrives, on
/// both ends. Four bytes is exactly the size of thing that gets written twice and drifts once.
///
/// CLIENT INPUT EVENTS are the shortest path from a hostile datagram to a window-server call: the
/// host decodes one off an unauthenticated socket and posts it. The finite-coordinate guard is a
/// decode guard for that reason, and it exists once.
///
/// The loss-resilient input burst encodes ONCE. `sendMouseUp` and a held-modifier key-up put the
/// same datagram on the wire three times, so a lost release cannot stick a button or latch a
/// modifier; both call sites have always SAID the bytes are built once, and for a while the code
/// looped over the single-event `sendInput(_:)` instead, which re-ran the input codec and allocated
/// a fresh `Data` per repeat (measured 2026-08-22: 227 ns a call, 3 per gesture). Nothing was WRONG
/// — the encode is pure, so the repeats were always identical bytes — and that is exactly why
/// nothing could catch it. So the SHAPE is banned rather than the behaviour asserted.
#[must_use]
pub fn mux_and_input(tree: &Tree) -> Report {
    let claims = [
        Claim::Doors {
            path: MUX,
            entries: &[
                "slopdesk_mux_encode",
                "slopdesk_mux_decode",
                "slopdesk_mux_fragment_encode",
                "slopdesk_mux_fragment_decode",
                "slopdesk_mux_constant",
            ],
            message: "Sources/SlopDeskVideoProtocol/Mux/VideoMuxHeaderCodec.swift no longer calls {entry} — \
                      the mux prefix is rust/slopdesk-video's",
        },
        // The writer and reader a hand-rolled prefix would need back, and the two widths it would
        // respell.
        Claim::Lacks {
            path: MUX,
            pattern: "appendBE|VideoByteReader",
            view: View::Code,
            message: "Sources/SlopDeskVideoProtocol/Mux/VideoMuxHeaderCodec.swift grew a byte writer back — \
                      the mux bytes are laid out once, in Rust",
        },
        Claim::Lacks {
            path: MUX,
            pattern: r"(static let|=) *(4 \+ 4|19)\b",
            view: View::Code,
            message: "Sources/SlopDeskVideoProtocol/Mux/VideoMuxHeaderCodec.swift spells a header width \
                      again — slopdesk_mux_constant vends both of them",
        },
        Claim::Doors {
            path: INPUT,
            entries: &[
                "slopdesk_input_event_encode",
                "slopdesk_input_event_decode",
                "slopdesk_input_event_constant",
            ],
            message: "Sources/SlopDeskVideoProtocol/InputEventCodec.swift no longer calls {entry} — the \
                      input wire is rust/slopdesk-video's",
        },
        Claim::Lacks {
            path: INPUT,
            pattern: "appendBE|VideoByteReader|readFiniteFloat64",
            view: View::Code,
            message: "Sources/SlopDeskVideoProtocol/InputEventCodec.swift grew a reader back — input \
                      datagrams are parsed once, in Rust",
        },
        // Named rather than assumed: the ban below would otherwise read a file the rule is not about.
        Claim::Names {
            path: CLIENT_SESSION,
            needle: "func sendInput(_ event: InputEvent, times: Int)",
            message: "Sources/SlopDeskVideoClient/SlopDeskVideoClientSession.swift lost sendInput(_:times:) \
                      — the ban below would read a file the rule is not about (docs/55 §4)",
        },
        Claim::Lacks {
            path: CLIENT_SESSION,
            pattern: r"for .* in 0\.\.<Self\.(redundantUpCount|keySendCount)",
            view: View::Code,
            message: "Sources/SlopDeskVideoClient/SlopDeskVideoClientSession.swift loops the single-event \
                      sendInput over a repeat count again — the burst encodes once, see sendInput(_:times:)",
        },
    ];
    check_all(tree, &claims)
}

/// The three low-rate metadata wires and the two span wires.
///
/// Geometry coordinates end up in a `CALayer` frame (a NaN there is an uncaught
/// `CALayerInvalidGeometry`), the swipe status drives an affordance that must not promise a
/// navigation the host would refuse, and an audio datagram declares its own payload length — the
/// classic over-allocate lever.
///
/// The CURSOR side-channel and the AVCC SPLIT both answer a span into the caller's datagram rather
/// than a copy — the cursor's PNG and a frame's NAL units are the two payloads on this path big
/// enough that copying them to describe them would be the whole cost. The cursor's coordinates are
/// finite-checked at decode for the geometry reason; a ragged AVCC tail ends the walk rather than
/// failing it, so a partly-arrived frame still decodes.
#[must_use]
pub fn metadata_wires(tree: &Tree) -> Report {
    let claims = [
        Claim::Doors {
            path: "Sources/SlopDeskVideoProtocol/WindowGeometryCodec.swift",
            entries: &[
                "slopdesk_window_geometry_encode",
                "slopdesk_window_geometry_decode",
            ],
            message: "Sources/SlopDeskVideoProtocol/WindowGeometryCodec.swift no longer calls {entry} — \
                      that wire is rust/slopdesk-video's",
        },
        Claim::Doors {
            path: "Sources/SlopDeskVideoProtocol/SwipeNavStatusCodec.swift",
            entries: &[
                "slopdesk_swipe_nav_status_encode",
                "slopdesk_swipe_nav_status_decode",
            ],
            message: "Sources/SlopDeskVideoProtocol/SwipeNavStatusCodec.swift no longer calls {entry} — \
                      that wire is rust/slopdesk-video's",
        },
        Claim::Doors {
            path: "Sources/SlopDeskVideoProtocol/AudioWireCodec.swift",
            entries: &["slopdesk_audio_encode", "slopdesk_audio_decode"],
            message: "Sources/SlopDeskVideoProtocol/AudioWireCodec.swift no longer calls {entry} — that \
                      wire is rust/slopdesk-video's",
        },
        // The audio cap and the swipe status's flag bits are the two numbers a second speller would
        // drift. Prose may still name them — a doc comment cannot be what the decoder reads.
        Claim::NoneUnder {
            roots: &[
                "Sources/SlopDeskVideoProtocol/AudioWireCodec.swift",
                "Sources/SlopDeskVideoProtocol/SwipeNavStatusCodec.swift",
            ],
            extensions: SWIFT,
            pattern: r"8192|1 << [012]",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "an audio cap or a swipe flag bit is spelled in Swift again ({files}) — the constant \
                      vends are there for it",
        },
        Claim::Doors {
            path: "Sources/SlopDeskVideoProtocol/CursorCodec.swift",
            entries: &["slopdesk_cursor_encode", "slopdesk_cursor_constant"],
            message: "Sources/SlopDeskVideoProtocol/CursorCodec.swift no longer calls {entry} — that wire \
                      is rust/slopdesk-video's",
        },
        Claim::Doors {
            path: "Sources/SlopDeskVideoProtocol/CursorShapeCodec.swift",
            entries: &["slopdesk_cursor_encode", "slopdesk_cursor_decode"],
            message: "Sources/SlopDeskVideoProtocol/CursorShapeCodec.swift no longer calls {entry} — that \
                      wire is rust/slopdesk-video's",
        },
        Claim::Doors {
            path: "Sources/SlopDeskVideoProtocol/NALUnit.swift",
            entries: &["slopdesk_nal_split", "slopdesk_nal_join"],
            message: "Sources/SlopDeskVideoProtocol/NALUnit.swift no longer calls {entry} — that wire is \
                      rust/slopdesk-video's",
        },
        // The four numbers those two wires would drift on: the cursor's two type bytes, its 36-byte
        // update, its 27-byte header and the 4-byte AVCC prefix. Prose may still name them.
        Claim::NoneUnder {
            roots: &[
                "Sources/SlopDeskVideoProtocol/CursorCodec.swift",
                "Sources/SlopDeskVideoProtocol/CursorShapeCodec.swift",
                "Sources/SlopDeskVideoProtocol/NALUnit.swift",
            ],
            extensions: SWIFT,
            pattern: r"(static let|=) *(36|27|4)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a cursor or AVCC width is spelled in Swift again ({files}) — \
                      slopdesk_cursor/nal_constant vend them",
        },
    ];
    check_all(tree, &claims)
}

/// The three per-frame measurements the capture path takes on a locked pixel buffer.
///
/// The frame hash that suppresses a re-delivery, the scroll shift the client reprojects on, and the
/// change fraction that sets the per-frame QP ceiling. All three are `rust/slopdesk-video`, reached
/// through the one door that takes an ADDRESS rather than bytes — there is no `Data` behind an
/// `IOSurface` to lend.
///
/// This is the path where a second implementation would be least visible and most expensive: the
/// fold is xxHash64-SHAPED but not xxHash64, so no published oracle would catch a Swift copy
/// drifting from it, and a hash that agrees with itself while disagreeing with the Rust suppresses
/// real frames — which the viewer sees as a freeze on stale content, not as an error.
#[must_use]
pub fn frame_measurements(tree: &Tree) -> Report {
    let claims = [
        Claim::Doors {
            path: FRAME_MEASURE,
            entries: &[
                "slopdesk_video_frame_hash_nv12",
                "slopdesk_video_frame_hash_sentinel",
                "slopdesk_video_scroll_nv12",
                "slopdesk_video_adaptive_qp_nv12",
            ],
            message: "Sources/SlopDeskVideoProtocol/FrameMeasurement.swift no longer calls {entry} — the \
                      frame measurements are rust/slopdesk-video's",
        },
        Claim::Absent {
            path: "Sources/SlopDeskVideoProtocol/FrameHasher.swift",
            message: "one fold, one estimator, one QP ramp, and they are Rust's",
        },
        Claim::Absent {
            path: "Sources/SlopDeskVideoProtocol/ScrollShiftEstimator.swift",
            message: "one fold, one estimator, one QP ramp, and they are Rust's",
        },
        Claim::Absent {
            path: "Sources/SlopDeskVideoProtocol/AdaptiveFrameQP.swift",
            message: "one fold, one estimator, one QP ramp, and they are Rust's",
        },
        // The fold, the two laws and the plane validation, none of which may grow back ANYWHERE in
        // Sources/: each is small, pure and framework-free, which is exactly the shape a "tiny local
        // helper" takes.
        Claim::NoneUnder {
            roots: SWIFT_ROOTS,
            extensions: SWIFT,
            pattern: r"(struct|enum|final class) StreamHasher\b|func (hashRow|hashNV12Scalar|rowHashes|rowHashesQuantized|borrowPlane|estimateVerticalShift|changedFraction|adaptiveMaxQP)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift frame-measurement law is back in {files} — rust/slopdesk-video owns the fold \
                      and both laws",
        },
        // The sentinel, the lane primes and the plane ceiling: the numbers a second speller would
        // drift.
        Claim::Lacks {
            path: FRAME_MEASURE,
            pattern: r"UInt64\.max|16384|0x9E37_79B1|0x2752_5BA1|4149_534C",
            view: View::Code,
            message: "Sources/SlopDeskVideoProtocol/FrameMeasurement.swift spells a frame-hash constant \
                      again — the door vends the sentinel",
        },
    ];
    check_all(tree, &claims)
}

/// The four pure policies either end reads on every frame or every tick.
///
/// The shader's colour matrix, the click mapping, one step of the playout buffer, the frozen-stream
/// verdict. Each is a handful of arithmetic with no state behind it, which is precisely the shape
/// someone reimplements in place rather than calls.
///
/// Two of them are pinned in `golden/golden_vectors.json` as IEEE bit patterns, and that is the
/// whole argument: a Swift copy of `coordWindowPoint` or `ycbcr` agrees with the Rust until a
/// compiler fuses a multiply and an add or widens an f32 through an f64, and then a click lands a
/// pixel off — or the whole picture shifts a code value — on ONE machine, with every test green.
#[must_use]
pub fn pure_policies(tree: &Tree) -> Report {
    let claims = [
        Claim::Doors {
            path: "Sources/SlopDeskVideoProtocol/YCbCrConversion.swift",
            entries: &["slopdesk_ycbcr_coefficients"],
            message: "Sources/SlopDeskVideoProtocol/YCbCrConversion.swift no longer calls {entry} — the \
                      policy is rust/slopdesk-video's",
        },
        Claim::Doors {
            path: "Sources/SlopDeskVideoProtocol/CoordinateMapping.swift",
            entries: &["slopdesk_coord_window_point"],
            message: "Sources/SlopDeskVideoProtocol/CoordinateMapping.swift no longer calls {entry} — the \
                      policy is rust/slopdesk-video's",
        },
        Claim::Doors {
            path: "Sources/SlopDeskVideoProtocol/AdaptivePlayoutPolicy.swift",
            entries: &["slopdesk_playout_step_ms"],
            message: "Sources/SlopDeskVideoProtocol/AdaptivePlayoutPolicy.swift no longer calls {entry} — \
                      the policy is rust/slopdesk-video's",
        },
        Claim::Doors {
            path: "Sources/SlopDeskVideoProtocol/StreamStallPolicy.swift",
            entries: &["slopdesk_stream_stall_verdict"],
            message: "Sources/SlopDeskVideoProtocol/StreamStallPolicy.swift no longer calls {entry} — the \
                      policy is rust/slopdesk-video's",
        },
        // The arithmetic itself, which may not grow back in any Swift root. `windowPoint(pixel:`
        // and the CG↔Cocoa flip went with this port: they had no caller outside their own tests, and
        // the Rust twin that survives them is the only one left.
        Claim::NoneUnder {
            roots: SWIFT_ROOTS,
            extensions: SWIFT,
            pattern: r"func (targetSeconds|stepSeconds|cgRectToCocoa|backingScaleFactor)\(|(struct|enum|final class) ScreenInfo\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift policy law is back in {files} — rust/slopdesk-video owns the clamp, the flip \
                      and the step",
        },
        // A coefficient spelled on this side is a second source for a golden vector, and
        // `255.0 / 219.0` written in Swift is `Double` unless someone remembers the annotation.
        Claim::Lacks {
            path: "Sources/SlopDeskVideoProtocol/YCbCrConversion.swift",
            pattern: r"1\.5748|0\.1873|0\.4681|1\.8556|255\.0|219\.0",
            view: View::Code,
            message: "YCbCrConversion.swift spells a BT.709 coefficient again — the door vends the table",
        },
    ];
    check_all(tree, &claims)
}

/// The terminal-mode tracker, which had THREE implementations at once.
///
/// Which screen the host presents, and where the command boundaries are: `rust/slopdesk-terminal`'s
/// grammar, reached through the handle door — a parser that must remember, because `ESC` at the end
/// of one read and `[` at the start of the next is the normal case.
///
/// The three were the live Swift, a frozen pre-fast-path Swift copy kept as a differential oracle,
/// and the Rust. The frozen copy is exactly the "test fake" the one-implementation rule names, and
/// it must not come back — the oracle is the corpus now.
#[must_use]
pub fn mode_tracker(tree: &Tree) -> Report {
    let claims = [
        Claim::Doors {
            path: "Sources/SlopDeskClaudeCode/TerminalModeTracker.swift",
            entries: &[
                "slopdesk_mode_tracker_new",
                "slopdesk_mode_tracker_free",
                "slopdesk_mode_tracker_reset",
                "slopdesk_mode_tracker_consume",
                "slopdesk_mode_tracker_event",
                "slopdesk_mode_tracker_mode",
                "slopdesk_mode_tracker_bracketed_paste_active",
                "slopdesk_mode_tracker_cursor_keys_application",
            ],
            message: "Sources/SlopDeskClaudeCode/TerminalModeTracker.swift no longer calls {entry} — the \
                      tracker's grammar is rust/slopdesk-terminal's",
        },
        Claim::Absent {
            path: "Tests/SlopDeskClaudeCodeTests/Support/LegacyTerminalModeTracker.swift",
            message: "the golden corpus is the oracle, not a second machine",
        },
        Claim::NoneUnder {
            roots: SWIFT_ROOTS,
            extensions: SWIFT,
            pattern: r"(struct|enum|final class) LegacyTerminalModeTracker\b|case (oscEscape|stringConsume|stringConsumeEscape)\b|func (handleCSI|handleOSC)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift terminal-mode state machine is back in {files} — one grammar, and it is Rust's",
        },
        // The corpus key that was frozen-but-unread for as long as it existed. It is the port's
        // differential now, so a suite that stops replaying it silently un-pins 16 cases again.
        Claim::Names {
            path: "Tests/SlopDeskClaudeCodeTests/TerminalModeGoldenVectorTests.swift",
            needle: "terminalModeTracker",
            message: "TerminalModeGoldenVectorTests no longer reads the terminalModeTracker corpus key",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    //! These seed the shape each rule forbids, because none of them can be seeded as a BEHAVIOUR —
    //! that is the whole reason the rules are about shape.

    use crate::tests::Fixture;

    /// A door the Swift face stopped calling is an implementation that came back.
    #[test]
    fn a_face_that_stops_calling_its_door_is_caught() {
        let fixture = Fixture::new("video-door");
        fixture.write(
            "Sources/SlopDeskVideoProtocol/FrameReassembler.swift",
            "slopdesk_video_reassembler_ingest(h)\nslopdesk_video_reassembler_frame_avcc(h)\\
             nslopdesk_video_reassembler_free(h)\n",
        );
        assert!(super::receive_path(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskVideoProtocol/FrameReassembler.swift",
            "slopdesk_video_reassembler_ingest(h)\nslopdesk_video_reassembler_free(h)\n",
        );
        let report = super::receive_path(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("slopdesk_video_reassembler_frame_avcc")),
            "{report:?}",
        );
    }

    /// A guard rebuilt in Swift is two copies of a guard, and two copies of a guard drift silently.
    #[test]
    fn a_hostile_input_guard_rebuilt_in_swift_is_caught() {
        let fixture = Fixture::new("video-guard");
        fixture.write(
            "Sources/SlopDeskVideoProtocol/FrameReassembler.swift",
            "slopdesk_video_reassembler_ingest(h)\nslopdesk_video_reassembler_frame_avcc(h)\\
             nslopdesk_video_reassembler_free(h)\nlet maxFrontierJump = 64\n",
        );
        let report = super::receive_path(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("guard back")),
            "{report:?}"
        );
    }

    /// The Swift half of the send path, green: every door called, no builder re-grown.
    const PACKETIZER_OK_PATH: &str = "Sources/SlopDeskVideoProtocol/FramePacketizer.swift";
    // Both fixtures below carry REAL newlines rather than `\n\` continuations: `format_strings`
    // reflows an escaped `\n` across a break into `\\` + `n`, which silently turns the separator
    // into a literal letter and merges the seeded lines. The leading `\` form is immune.
    const PACKETIZER_OK: &str = "\
slopdesk_video_packetizer_raw(x)
slopdesk_video_packetizer_answer(x)
slopdesk_video_packetizer_free(x)
slopdesk_video_fragment_encode(x)
slopdesk_video_fragment_decode(x)
";

    /// A daemon send lane that asks the crate for every part of the send path.
    const DAEMON_SENDER: &str = "\
use slopdesk_video::packetizer::Packetizer;
use slopdesk_video::recovery_routing::{VideoChannel, schedule_frame_raw};
use slopdesk_video::send_pacing::next_release;
";

    /// A deleted file coming back, including the C target that was a whole DIRECTORY.
    #[test]
    fn a_deleted_swift_backend_returning_is_caught() {
        let fixture = Fixture::new("video-gf");
        fixture
            .write(
                "Sources/SlopDeskVideoProtocol/FramePacketizer.swift",
                "slopdesk_video_packetizer_raw(x)\nslopdesk_video_packetizer_answer(x)\\
                 nslopdesk_video_packetizer_free(x)\nslopdesk_video_fragment_encode(x)\\
                 nslopdesk_video_fragment_decode(x)\n",
            )
            .write("rust/slopdesk-videohostd/src/sendlane.rs", DAEMON_SENDER);
        assert!(super::send_path(&fixture.tree()).is_clean());

        fixture.write("Sources/SlopDeskVideoProtocol/GF256.swift", "enum GF256 {}\n");
        let report = super::send_path(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("GF256.swift is back")),
            "{report:?}"
        );
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("GF(2^8) backend is back")),
            "{report:?}"
        );
    }

    /// A send path whose Swift half is green and whose Rust half has grown a second composition.
    ///
    /// This is the drift `docs/61 §3` actually deleted once: the daemon's own `packetize.rs` had
    /// re-declared `Outgoing` and `schedule_frame_raw`. Every Swift claim in the rule still passes,
    /// and the golden vectors still pin the crate — they just no longer pin what the host sends.
    #[test]
    fn a_daemon_that_recomposes_the_send_path_is_caught() {
        for line in [
            "fn schedule_frame(session: &mut Session) -> Vec<u8> { Vec::new() }\n",
            "fn schedule_frame_raw(session: &mut Session) -> Vec<u8> { Vec::new() }\n",
            "struct Outgoing { channel: u8 }\n",
            "enum Outgoing { Frame, Control }\n",
        ] {
            let fixture = Fixture::new("video-daemon-recompose");
            fixture
                .write(PACKETIZER_OK_PATH, PACKETIZER_OK)
                .write("rust/slopdesk-videohostd/src/sendlane.rs", DAEMON_SENDER);
            assert!(super::send_path(&fixture.tree()).is_clean(), "{line}");

            fixture.append("rust/slopdesk-videohostd/src/sendlane.rs", line);
            let report = super::send_path(&fixture.tree());
            assert!(
                report
                    .violations()
                    .iter()
                    .any(|v| v.contains("re-declares the send path's own shape")),
                "{line:?}: {report:?}"
            );
        }
    }

    /// The failure this whole rule exists to make impossible: the ask goes quiet.
    ///
    /// A daemon that stopped naming `send_pacing` is not a daemon that stopped pacing — it is one
    /// that paces somewhere the crate's suite does not reach. `MentionsUnder` fails on a drained
    /// root for exactly that reason, so the rule cannot pass by having nothing left to check.
    #[test]
    fn a_daemon_that_stopped_asking_the_crate_is_caught() {
        let fixture = Fixture::new("video-daemon-drained");
        fixture
            .write(PACKETIZER_OK_PATH, PACKETIZER_OK)
            .write("rust/slopdesk-videohostd/src/sendlane.rs", DAEMON_SENDER);
        assert!(super::send_path(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-videohostd/src/sendlane.rs",
            "\
use slopdesk_video::packetizer::Packetizer;
use slopdesk_video::recovery_routing::{VideoChannel, schedule_frame_raw};
",
        );
        let report = super::send_path(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("stopped naming send_pacing")),
            "{report:?}"
        );
    }

    /// The measured regression the burst rule was written for: looping the single-event send
    /// re-runs the codec and allocates per repeat, for bytes that are identical every time.
    #[test]
    fn looping_the_single_event_send_is_caught() {
        let fixture = Fixture::new("video-burst");
        let good = "func sendInput(_ event: InputEvent, times: Int) {}\nsendInput(e, times: 3)\n";
        fixture
            .write(
                "Sources/SlopDeskVideoProtocol/Mux/VideoMuxHeaderCodec.swift",
                MUX_OK,
            )
            .write("Sources/SlopDeskVideoProtocol/InputEventCodec.swift", INPUT_OK)
            .write(
                "Sources/SlopDeskVideoClient/SlopDeskVideoClientSession.swift",
                good,
            );
        assert!(super::mux_and_input(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskVideoClient/SlopDeskVideoClientSession.swift",
            &format!("{good}for _ in 0..<Self.redundantUpCount {{ sendInput(e) }}\n"),
        );
        let report = super::mux_and_input(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("encodes once")),
            "{report:?}"
        );
    }

    /// A coefficient spelled in Swift is a second source for a golden bit pattern.
    #[test]
    fn respelling_a_pinned_coefficient_is_caught() {
        let fixture = Fixture::new("video-ycbcr");
        fixture
            .write(
                "Sources/SlopDeskVideoProtocol/YCbCrConversion.swift",
                "slopdesk_ycbcr_coefficients()\n",
            )
            .write(
                "Sources/SlopDeskVideoProtocol/CoordinateMapping.swift",
                "slopdesk_coord_window_point()\n",
            )
            .write(
                "Sources/SlopDeskVideoProtocol/AdaptivePlayoutPolicy.swift",
                "slopdesk_playout_step_ms()\n",
            )
            .write(
                "Sources/SlopDeskVideoProtocol/StreamStallPolicy.swift",
                "slopdesk_stream_stall_verdict()\n",
            );
        assert!(super::pure_policies(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskVideoProtocol/YCbCrConversion.swift",
            "slopdesk_ycbcr_coefficients()\nlet kr = 1.5748\n",
        );
        let report = super::pure_policies(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("BT.709")),
            "{report:?}"
        );
    }

    const MUX_OK: &str = "slopdesk_mux_encode(x)\nslopdesk_mux_decode(x)\nslopdesk_mux_fragment_encode(x)\\
                          nslopdesk_mux_fragment_decode(x)\nslopdesk_mux_constant(x)\n";
    const INPUT_OK: &str =
        "slopdesk_input_event_encode(x)\nslopdesk_input_event_decode(x)\nslopdesk_input_event_constant(x)\n";
}
