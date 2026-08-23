//! The video path lends what it holds, and each of its rules has one author.
//!
//! Ported from `scripts/check-supervisor.sh`. None of the defects below is visible to any test,
//! which is the entire reason they are pinned: an exported door with no caller reads as covered, a
//! re-encode of bytes just parsed is correct and slow, and two languages spelling one table
//! differently is a defect at zero calls per second where only one of the two answers is right.
//!
//! Every rule was BREAK-TESTED against the real tree: the file was copied to `/tmp`, the port was
//! reverted by hand in the working copy, the rule was run, and the file was restored from the copy.
//! Each rule's comment records the verdict.

use crate::claim::{Claim, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The encoder, whose quantiser knobs go through one door.
const VIDEO_ENCODER: &str = "Sources/SlopDeskVideoHost/VideoEncoder.swift";
/// The client session, which receives control datagrams.
const CLIENT_SESSION: &str = "Sources/SlopDeskVideoClient/SlopDeskVideoClientSession.swift";
/// The state machine's Swift face.
const SESSION_LOGIC: &str = "Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift";

/// The video path lends what it holds — no re-encode, no re-ask, no second array
///
/// ## A control datagram the client already holds is not re-encoded to be re-parsed
/// `handleControl(datagram:)` existed, documented itself as being "so a caller that already holds
/// the bytes does not re-encode what it just decoded", and had no caller: the receive path routed
/// the datagram into a `VideoControlMessage` and then handed the state machine
/// `[UInt8](message.encode())` — re-encoding, into a fresh array, bytes it had just parsed.
/// Measured against the shipped xcframework, two agreeing runs: 147.8/155.2 ns to re-encode against
/// 0.7 ns to lend the `Data`. `docs/55` §8 is why this is a gate and not a nicety: an exported door
/// with no caller is worse than an unported rule, because it reads as covered.
///
/// ## The cursor-shape tracker answers "already cached" without lending three buffers
/// Its general step lends three arrays and adopts three prefixes — 6 allocations — and the host
/// samples the cursor at ~120 Hz, so in steady state that is 6 allocations per packet to be told
/// the shape is already cached. The crate answers that case without touching its state, so the face
/// asks through `slopdesk_cursor_shape_is_known`, which allocates nothing. Measured, two agreeing
/// runs: 488.0/509.1 ns per call with 4 cached shapes and 1249.3/1122.3 ns with 12, against
/// 68.5/68.6 ns and 252.2/258.6 ns through the guard. Matched on the LINE's shape rather than on
/// `isKnown` alone, because `isKnown` is also the test/diagnostics seam and would pass this gate
/// while the hot path went back through the step.
///
/// ## The FEC send path promotes its fragments LAZILY
/// `FECBlobList.encode` takes `Collection<Data?>`; the send side holds `[Data]`. Promoting eagerly
/// builds a whole second array of refcounted `Data`s, once per frame, to say nothing at all.
/// Measured at `-O`, two agreeing runs, per call: 423.7/430.0 ns eager at 24 fragments, 960.6/947.9
/// ns at 60, 3559.2/3561.8 ns at 240 — against 31.4/30.5, 69.7/70.0 and 247.3/245.1 ns through the
/// lazy view.
///
/// The trap this pins is that the eager form was written as `.map(\.self)`, and DELETING it does
/// not fix anything: the implicit `[Data]` → `[Data?]` bridge that then runs is a runtime cast, and
/// it is more than TWICE as dear as the `map` (902.8/905.0 ns at 24 fragments). So the ban is on
/// the eager `map`, and the positive rule is that the lazy overload is still there to bind to.
#[must_use]
pub fn the_video_path_lends_what_it_holds(tree: &Tree) -> Report {
    /// The FEC scheme, which holds the lazy overload.
    const VIDEO_FEC: &str = "Sources/SlopDeskVideoProtocol/FECScheme.swift";
    /// Its sibling on the send path, which may not promote eagerly either.
    const VIDEO_NAL: &str = "Sources/SlopDeskVideoProtocol/NALUnit.swift";

    check_all(tree, &[
        Claim::Matches {
            path: CLIENT_SESSION,
            pattern: r"handleControl\(datagram:",
            view: View::Code,
            message: "the client session no longer lends the control DATAGRAM — it is re-encoding a message \
                      it parsed",
        },
        Claim::Lacks {
            path: CLIENT_SESSION,
            pattern: r"handleControl\(message\)|\[UInt8\]\(message\.encode\(\)\)|handleControl\(routed",
            view: View::Code,
            message: "the client session re-encodes a routed control message — hand the state machine the \
                      bytes it arrived in",
        },
        Claim::Matches {
            path: SESSION_LOGIC,
            pattern: r"if +isKnown\(shapeID\) *\{ *return false *\}",
            view: View::Code,
            message: "the session logic lost the cached-shape guard — 6 allocations per cursor packet to \
                      answer no",
        },
        Claim::NoneOf {
            paths: &[VIDEO_FEC, VIDEO_NAL],
            pattern: r"FECBlobList\.encode\([A-Za-z]+\.map\(",
            view: View::Code,
            message: "the send path eagerly promotes its fragments — hand the encoder the array and let the \
                      lazy overload take it",
        },
        Claim::Matches {
            path: VIDEO_FEC,
            pattern: r"blobs\.lazy\.map",
            view: View::Code,
            message: "FECScheme lost the lazy [Data] overload — every send-path caller pays a second array \
                      per frame",
        },
    ])
}

/// The two `CoreGraphics` phase encodings are ONE table
///
/// `CoreGraphics` puts two phase fields on a scroll event and encodes the same three edges
/// differently: the scroll field is a bit set, so its END is 4 and there is room for a cancel at 8
/// and a finger-at-rest at 128; the momentum field is an ordinal, so ITS end is 3. Those ten
/// numbers were spelled in FOUR places across two languages — a private block in `client_gestures`,
/// the reprojector, the touch translation, and the Mac client's view — and two of the four read
/// different sets of them. Nothing measures: a door here is ~1 ns against ~5 branches, which is the
/// point. A rule two languages spell differently is a defect at zero calls per second, and only one
/// of the two answers is right.
///
/// VERIFIED, not asserted: the port was differentially checked from Swift against the deleted Swift
/// verbatim, over all 256 masks × both fields = 512 comparisons, through the linked release
/// archive. Zero mismatches, twice. The `AppKit` bit values the mapping assumes were read out of
/// the LIVE framework at runtime rather than from the header (began 1<<0 … mayBegin 1<<5) — all six
/// agree.
///
/// The ban is on the LADDER, not the bit test: `event.phase.contains(.began)` is a legitimate
/// gesture-start check and appears here for the pinch planner. What may not come back is a
/// contains-test whose body RETURNS A BARE NUMBER, which is the transcription and nothing else.
///
/// On the Rust side the reprojector must keep READING the table rather than matching bare codes.
/// Its `of_platform` is the one place a 3 and a 4 sit next to each other, so a literal there is the
/// likeliest way for the two encodings to get crossed. And the table itself stays single: the
/// private per-file copy that lived in `client_gestures` is what made this a FOUR-way spelling
/// rather than a three-way one.
#[must_use]
pub fn the_scroll_phases_are_one_table(tree: &Tree) -> Report {
    /// The Mac half's backing view, since the video carve (`docs/56` §3). This was one file whose
    /// middle 2,514 lines were an `#if os(macOS)` / `#elseif os(iOS)` two-armed conditional, and
    /// the two phase encodings are `NSEvent.Phase`, so they went to the `AppKit` arm and
    /// nowhere else.
    const WINDOW_VIEW: &str = "Sources/SlopDeskVideoClientMac/MacMetalLayerBackedView.swift";
    /// Where the one table lives.
    const CLIENT_GESTURES: &str = "rust/slopdesk-video/src/client_gestures.rs";
    /// The reprojector, which must read it rather than restate it.
    const SCROLL_REPROJECT: &str = "rust/slopdesk-video/src/scroll_reproject.rs";

    check_all(tree, &[
        Claim::Doors {
            path: WINDOW_VIEW,
            entries: &["slopdesk_cg_scroll_phase_code", "slopdesk_cg_momentum_phase_code"],
            message: "the Mac view no longer calls {entry} — the two phase encodings live in \
                      client_gestures.rs",
        },
        Claim::Lacks {
            path: WINDOW_VIEW,
            pattern: r"contains\(\.(began|changed|ended|cancelled|mayBegin)\) *\{ *return [0-9]",
            view: View::Code,
            message: "the Mac view decodes an NSEvent.Phase mask into a code itself again — hand the raw \
                      bits to the door",
        },
        Claim::Matches {
            path: SCROLL_REPROJECT,
            pattern: r"use crate::client_gestures::\{",
            view: View::Code,
            message: "the reprojector stopped reading the phase table — a bare 3 and a bare 4 mean \
                      different fields",
        },
        Claim::Lacks {
            path: SCROLL_REPROJECT,
            pattern: r"^ *[0-9]+( \| [0-9]+)? *=> *Self::(Ended|Momentum)",
            view: View::Code,
            message: "the reprojector matches a bare phase code again — name it from client_gestures.rs",
        },
        Claim::Lacks {
            path: CLIENT_GESTURES,
            pattern: "const (PHASE_|MOMENTUM_ENDED)",
            view: View::Code,
            message: "client_gestures grew a second private phase table — the exported SCROLL_*/MOMENTUM_* \
                      constants are it",
        },
    ])
}

/// The encoder's quantiser knobs CLAMP; they do not reject
///
/// `SLOPDESK_MAX_QP`, `_CONST_QP` and `_CRISP_QP` each hand-rolled a parse that REJECTED an
/// out-of-range value to the knob's default, while `slopdesk_qp_clamped_int` — which every other
/// quantiser knob in the tree already goes through — CLAMPS it. One rule, two answers.
///
/// Resolved toward CLAMPING, and the reason is that rejecting silently INVERTS the request:
/// `SLOPDESK_MAX_QP=0` asks for the sharpest ceiling the encoder has and used to get 51, the
/// coarsest, with nothing said. Clamping answers 1. Measured through the linked archive, old → new,
/// for every shape a knob can take: absent, empty, in-range, and unparseable are all UNCHANGED;
/// only out-of-range moves. Presence still decides whether const-QP engages at all, so an absent
/// knob is still OFF, and text that is not a number at all still leaves it OFF rather than
/// inventing an operating point.
///
/// ALL FIVE [1, 51] knobs in this target are named: MAX, CONST, CRISP and COMPACT in the encoder,
/// and `AQP_MAX` in the capturer. The fourth is here because this very gate found it — it was not
/// in the brief, it sat ten lines from the other three, and it had the same hand-rolled reject. The
/// FIFTH was found the same way, one file over, and is the reason `envQP` is not `private`: there
/// is no version of "one rule" where the fifth caller gets its own copy for living in another file.
///
/// ## And the message-shaped control face stays a WRAPPER
/// After the datagram fix its only callers are the state-machine tests, which is the shape the
/// one-implementation rule bans — unless it decides nothing, which it does not: it encodes and
/// hands over. The claim pins exactly that, so it can neither be deleted as dead nor quietly grown
/// into a second transition that only the tests would exercise.
#[must_use]
pub fn a_quantiser_knob_clamps_rather_than_rejects(tree: &Tree) -> Report {
    /// The capturer, which holds the fifth knob of the same shape.
    const WINDOW_CAPTURER: &str = "Sources/SlopDeskVideoHost/WindowCapturer.swift";

    check_all(tree, &[
        // The door the face asks changed with the encoder port — `slopdesk_video_encoder_qp_knob`
        // is the encoder's own knob entry, and it routes to the same `clamped_int_from_env` the
        // general door does, one crate closer to the rules that read the answer.
        Claim::Matches {
            path: VIDEO_ENCODER,
            pattern: r"slopdesk_video_encoder_qp_knob\(",
            view: View::Code,
            message: "the encoder parses its quantiser knobs itself again — the parse and the clamp are the \
                      door's",
        },
        // Matched on the `environment[…]` read followed by a bare `Int(` parse, which is the
        // shape all five had and none of them has now.
        Claim::NoneOf {
            paths: &[VIDEO_ENCODER, WINDOW_CAPTURER],
            pattern: r#"environment\["SLOPDESK_((MAX|CONST|CRISP|COMPACT)_QP|AQP_MAX)"\], *let v = Int\("#,
            view: View::Code,
            message: "a [1,51] quantiser knob is parsed by hand again — clamping through the door is the \
                      answer the caller can act on",
        },
        Claim::Matches {
            path: WINDOW_CAPTURER,
            pattern: r"VideoEncoder\.envQP\(",
            view: View::Code,
            message: "the capturer stopped asking VideoEncoder.envQP for SLOPDESK_AQP_MAX — the fifth knob \
                      of the same shape",
        },
        Claim::Matches {
            path: SESSION_LOGIC,
            pattern: r"handleControl\(datagram: message\.encode\(\)\)",
            view: View::Code,
            message: "the message-shaped handleControl stopped delegating — a test-only face that decides",
        },
    ])
}

/// The four defaults the settings sheet shows are the ones the encoder runs
///
/// `VideoPreferences` names what each surfaced field resolves to while it is `nil`, under a doc
/// comment that forbids literals there in as many words — and four of them were literals anyway:
/// `26`, `40`, `1`, `5`, against `qp_control.rs`'s sharp/coarse and `adaptive_fec.rs`'s default m
/// and k. Every one of those already had a door.
///
/// The failure mode is quiet and ASYMMETRIC, which is why it is worth a gate rather than a comment.
/// A retune moves the encoder's operating point; Settings goes on showing the old number, which is
/// merely wrong. But "reset to default" WRITES the shown number into the env overlay as an explicit
/// override — so the gesture whose entire purpose is to get out of the daemon's way is the one that
/// pins the daemon to a value nobody ever chose, and it stays pinned across restarts.
///
/// Index 11 is the multi-loss default m and is deliberately not index 7, which is `M_MIN`. They are
/// both 1 today and that coincidence is exactly how this one regrew: a reader who sees the floor
/// answer the same number stops looking for the door that answers the question actually being
/// asked.
///
/// The four fields are named INDIVIDUALLY rather than matched as "any `= <digit>` in this file",
/// because the file legitimately holds other numeric defaults that are its own; only these four
/// mirror a door.
#[must_use]
pub fn the_settings_sheet_shows_the_encoders_defaults(tree: &Tree) -> Report {
    /// The surfaced fields and what they fall back to.
    const PREFERENCES: &str = "Sources/SlopDeskVideoProtocol/Settings/VideoPreferences.swift";

    check_all(tree, &[
        // Read comment-stripped, unlike the Mac view's pair above: this file's header
        // discusses both doors by name, so a raw read would be answered by the prose that
        // explains why they are here.
        Claim::Matches {
            path: PREFERENCES,
            pattern: r"slopdesk_qp_config_default\(",
            view: View::Code,
            message: "the settings sheet no longer asks slopdesk_qp_config_default — its defaults are the \
                      encoder's",
        },
        Claim::Matches {
            path: PREFERENCES,
            pattern: r"slopdesk_adaptive_fec_constant\(",
            view: View::Code,
            message: "the settings sheet no longer asks slopdesk_adaptive_fec_constant — its defaults are \
                      the encoder's",
        },
        Claim::Lacks {
            path: PREFERENCES,
            pattern: r"(qpSharpDefault|qpCoarseDefault|fecMDefault|fecKDefault)[^=]*= *[0-9]",
            view: View::Code,
            message: "a QP or FEC default is a literal again — those four numbers are the encoder's, and \
                      \"reset to default\" writes whatever this file shows",
        },
    ])
}

/// The REJECT reading of an env knob: one rule, and it is Rust's
///
/// The clamp reading above settled the quantiser ordinals. This is the OTHER reading, for the rates
/// and fractions, and it had three implementations: a generic pair in `EnvConfig` with no callers
/// at all, and a private copy inside each of two files.
///
/// The two readings do NOT converge, deliberately. A quantiser ordinal has a meaningful nearest
/// legal value, which is the whole argument for the clamp; a malformed rate or fraction does not.
/// `SLOPDESK_ABR_LOSS=900` clamped is a controller that treats every frame as catastrophic loss
/// forever; rejected, it is the default and a knob that did nothing. So the tree carries both, each
/// with exactly one implementation — `slopdesk_qp_clamped_int` for `[1, 51]`, and
/// `slopdesk_abr_validated_int`/`_double` for rates and fractions. The `_double` form also rejects
/// the non-finite, which no clamp can express: `NaN` compares false against both bounds, so a clamp
/// would pass it straight through into the controller's arithmetic.
///
/// `FPSGovernor`'s copy carried a second bug on top of the duplication, and it is the one that
/// would have been reported as "the setting does nothing": it read
/// `ProcessInfo.processInfo.environment` DIRECTLY, bypassing `EnvConfig`'s overlay, so every
/// governor tunable set through the settings sheet was written, persisted, shown as active — and
/// never read. `EnvConfig.string` is the only legal reader here: real env FIRST, then the settings
/// overlay, then the compile-time default.
///
/// The ban is on the PARSE-THEN-COMPARE shape all three copies had, `Int(s), v >= lo`, rather than
/// on a door's absence — a file can keep calling the door and grow a second private parse beside
/// it, which is how the third copy appeared in the first place. And the generic pair stays deleted
/// tree-wide, spelled as a CALL rather than as a declaration so that re-adding it anywhere — a
/// helper, an extension, a test fake — is caught by its first user rather than by its author.
#[must_use]
pub fn the_reject_reading_of_an_env_knob_is_rusts(tree: &Tree) -> Report {
    /// The congestion controller, whose copy went through `EnvConfig` and was only duplicated.
    const ABR_CONTROLLER: &str = "Sources/SlopDeskVideoHost/LiveCongestionController.swift";
    /// The governor, whose copy was duplicated AND deaf.
    const FPS_GOVERNOR: &str = "Sources/SlopDeskVideoHost/FPSGovernor.swift";
    /// The overlay reader, which held the generic pair.
    const ENV_CONFIG: &str = "Sources/SlopDeskVideoProtocol/Settings/EnvConfig.swift";

    let mut claims = vec![
        Claim::Lacks {
            path: FPS_GOVERNOR,
            pattern: r"ProcessInfo\.processInfo\.environment",
            view: View::Code,
            message: "the governor reads the process environment directly again — that bypasses the \
                      settings overlay, which is how a governor tunable set in Settings came to do nothing",
        },
        Claim::NoneOf {
            paths: &[ABR_CONTROLLER, FPS_GOVERNOR, ENV_CONFIG],
            pattern: r"(Int|Double)\([a-zA-Z_]+\), *[a-zA-Z_]+ *(>=|<=|>|<) ",
            view: View::Code,
            message: "a numeric env knob is parsed by hand again — the reject rule is \
                      slopdesk_abr_validated_int/_double and the clamp rule is slopdesk_qp_clamped_int",
        },
        // The corpus is the whole Swift tree; if it ever reads as fewer than 200 files the walk has
        // gone stale and the ban below is passing on nothing.
        Claim::Populated {
            roots: &["Sources", "Tests"],
            extensions: SWIFT,
            minimum: 200,
            message: "the tree-wide Swift corpus read as {found} files — the EnvConfig ban is passing \
                      vacuously",
        },
        Claim::NoneUnder {
            roots: &["Sources", "Tests"],
            extensions: SWIFT,
            pattern: r"EnvConfig\.(int|double)\(",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} calls EnvConfig.int/.double again — that generic reject pair had zero callers \
                      and is deleted; ask a door",
        },
    ];
    for caller in [ABR_CONTROLLER, FPS_GOVERNOR] {
        claims.push(Claim::Matches {
            path: caller,
            pattern: r"slopdesk_abr_validated_int\(",
            view: View::Code,
            message: "a congestion reader no longer asks slopdesk_abr_validated_int — the reject rule is \
                      congestion.rs's",
        });
        claims.push(Claim::Matches {
            path: caller,
            pattern: r"slopdesk_abr_validated_double\(",
            view: View::Code,
            message: "a congestion reader no longer asks slopdesk_abr_validated_double — the reject rule is \
                      congestion.rs's",
        });
    }
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// The three lending rules in their post-port shape.
    fn lending(fixture: &Fixture) {
        fixture
            .write(
                super::CLIENT_SESSION,
                "stateMachine.handleControl(datagram: datagram)\n",
            )
            .write(
                super::SESSION_LOGIC,
                "if isKnown(shapeID) { return false }\nfunc handleControl(_ message: VideoControlMessage) { \
                 handleControl(datagram: message.encode()) }\n",
            )
            .write(
                "Sources/SlopDeskVideoProtocol/FECScheme.swift",
                "FECBlobList.encode(blobs.lazy.map { Optional($0) })\n",
            )
            .write(
                "Sources/SlopDeskVideoProtocol/NALUnit.swift",
                "FECBlobList.encode(fragments)\n",
            );
    }

    #[test]
    fn a_re_encode_of_parsed_bytes_is_red() {
        let fixture = Fixture::new("video-lending");
        lending(&fixture);
        assert!(super::the_video_path_lends_what_it_holds(&fixture.tree()).is_clean());

        // 147.8 ns to re-encode bytes it had just parsed, against 0.7 ns to lend the `Data`.
        fixture.write(
            super::CLIENT_SESSION,
            "stateMachine.handleControl(datagram: \
             datagram)\nstateMachine.handle([UInt8](message.encode()))\n",
        );
        assert!(!super::the_video_path_lends_what_it_holds(&fixture.tree()).is_clean());

        // And the cached-shape guard gone: 6 allocations per cursor packet to answer no.
        lending(&fixture);
        fixture.write(
            super::SESSION_LOGIC,
            "let known = isKnown(shapeID)\nfunc handleControl(_ message: VideoControlMessage) { \
             handleControl(datagram: message.encode()) }\n",
        );
        assert!(!super::the_video_path_lends_what_it_holds(&fixture.tree()).is_clean());
    }

    /// The four spellings of the phase table, all reading the one that is exported.
    fn phases(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskVideoClientMac/MacMetalLayerBackedView.swift",
                "let code = slopdesk_cg_scroll_phase_code(bits)\nlet m = \
                 slopdesk_cg_momentum_phase_code(bits)\n",
            )
            .write(
                "rust/slopdesk-video/src/client_gestures.rs",
                "pub const SCROLL_ENDED: u8 = 4;\npub const MOMENTUM_END: u8 = 3;\n",
            )
            .write(
                "rust/slopdesk-video/src/scroll_reproject.rs",
                "use crate::client_gestures::{SCROLL_ENDED, MOMENTUM_END};\nSCROLL_ENDED => Self::Ended,\n",
            );
    }

    #[test]
    fn a_transcribed_phase_ladder_is_red() {
        let fixture = Fixture::new("video-phases");
        phases(&fixture);
        assert!(super::the_scroll_phases_are_one_table(&fixture.tree()).is_clean());

        // The ladder, not the bit test: a contains-test whose body returns a bare number.
        fixture.write(
            "Sources/SlopDeskVideoClientMac/MacMetalLayerBackedView.swift",
            "let code = slopdesk_cg_scroll_phase_code(bits)\nlet m = \
             slopdesk_cg_momentum_phase_code(bits)\nif phase.contains(.began) { return 1 }\n",
        );
        assert!(!super::the_scroll_phases_are_one_table(&fixture.tree()).is_clean());

        // A bare 3 and a bare 4 sitting next to each other, which is how the two get crossed.
        phases(&fixture);
        fixture.write(
            "rust/slopdesk-video/src/scroll_reproject.rs",
            "use crate::client_gestures::{SCROLL_ENDED};\n    4 | 8 => Self::Ended,\n",
        );
        assert!(!super::the_scroll_phases_are_one_table(&fixture.tree()).is_clean());

        // And a second private table, which is what made this a four-way spelling.
        phases(&fixture);
        fixture.write(
            "rust/slopdesk-video/src/client_gestures.rs",
            "const PHASE_BEGAN: u8 = 1;\n",
        );
        assert!(!super::the_scroll_phases_are_one_table(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_hand_rolled_quantiser_parse_is_red() {
        let fixture = Fixture::new("video-knobs");
        fixture
            .write(
                super::VIDEO_ENCODER,
                "let ceiling = slopdesk_video_encoder_qp_knob(\"SLOPDESK_MAX_QP\")\n",
            )
            .write(
                "Sources/SlopDeskVideoHost/WindowCapturer.swift",
                "let aqp = VideoEncoder.envQP(\"SLOPDESK_AQP_MAX\")\n",
            )
            .write(
                super::SESSION_LOGIC,
                "func handleControl(_ message: VideoControlMessage) { handleControl(datagram: \
                 message.encode()) }\n",
            );
        assert!(super::a_quantiser_knob_clamps_rather_than_rejects(&fixture.tree()).is_clean());

        // The reject that INVERTS the request: `SLOPDESK_MAX_QP=0` asking for the sharpest ceiling
        // and getting the coarsest, with nothing said.
        fixture.write(
            super::VIDEO_ENCODER,
            "let ceiling = slopdesk_video_encoder_qp_knob(\"SLOPDESK_MAX_QP\")\nif let s = \
             environment[\"SLOPDESK_MAX_QP\"], let v = Int(s), v >= 1 { return v }\n",
        );
        assert!(!super::a_quantiser_knob_clamps_rather_than_rejects(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_settings_default_spelled_as_a_literal_is_red() {
        let fixture = Fixture::new("video-prefs");
        fixture.write(
            "Sources/SlopDeskVideoProtocol/Settings/VideoPreferences.swift",
            "static var qpSharpDefault: Int { slopdesk_qp_config_default(0) }\nstatic var fecMDefault: Int \
             { slopdesk_adaptive_fec_constant(11) }\n",
        );
        assert!(super::the_settings_sheet_shows_the_encoders_defaults(&fixture.tree()).is_clean());

        // "Reset to default" writes whatever this file shows, so a stale literal pins the daemon.
        fixture.write(
            "Sources/SlopDeskVideoProtocol/Settings/VideoPreferences.swift",
            "static var qpSharpDefault: Int { slopdesk_qp_config_default(0) }\nstatic let fecMDefault = \
             1\nstatic var k: Int { slopdesk_adaptive_fec_constant(12) }\n",
        );
        assert!(!super::the_settings_sheet_shows_the_encoders_defaults(&fixture.tree()).is_clean());
    }

    /// The corpus floor, plus the three files that have held a copy of the reject parse.
    fn reject(fixture: &Fixture) {
        for index in 0..200 {
            fixture.write(&format!("Sources/Filler/Filler{index}.swift"), "let filler = 0\n");
        }
        fixture
            .write(
                "Sources/SlopDeskVideoHost/LiveCongestionController.swift",
                "slopdesk_abr_validated_int(key, lo, hi)\nslopdesk_abr_validated_double(key, lo, hi)\n",
            )
            .write(
                "Sources/SlopDeskVideoHost/FPSGovernor.swift",
                "slopdesk_abr_validated_int(key, lo, hi)\nslopdesk_abr_validated_double(key, lo, hi)\n",
            )
            .write(
                "Sources/SlopDeskVideoProtocol/Settings/EnvConfig.swift",
                "static func string(_ key: String) -> String? { overlay[key] }\n",
            );
    }

    #[test]
    fn a_private_reject_parse_is_red() {
        let fixture = Fixture::new("video-reject");
        reject(&fixture);
        assert!(super::the_reject_reading_of_an_env_knob_is_rusts(&fixture.tree()).is_clean());

        // The read that bypasses the overlay — set, persisted, shown as active, never read.
        fixture.write(
            "Sources/SlopDeskVideoHost/FPSGovernor.swift",
            "slopdesk_abr_validated_int(key, lo, hi)\nslopdesk_abr_validated_double(key, lo, hi)\nlet raw = \
             ProcessInfo.processInfo.environment[key]\n",
        );
        assert!(!super::the_reject_reading_of_an_env_knob_is_rusts(&fixture.tree()).is_clean());

        // And the generic pair back, caught by its first USER rather than by its author.
        reject(&fixture);
        fixture.write(
            "Sources/SlopDeskVideoHost/Governor.swift",
            "let n = EnvConfig.int(\"SLOPDESK_ABR_LOSS\", 1, 100)\n",
        );
        assert!(!super::the_reject_reading_of_an_env_knob_is_rusts(&fixture.tree()).is_clean());
    }
}
