//! The video path lends what it holds, and each of its rules has one author.
//!
//! Ported from the deleted `check-supervisor.sh`. None of the defects below is visible to any test,
//! which is the entire reason they are pinned: an exported door with no caller reads as covered, a
//! re-encode of bytes just parsed is correct and slow, and two languages spelling one table
//! differently is a defect at zero calls per second where only one of the two answers is right.
//!
//! Every rule was BREAK-TESTED against the real tree: the file was copied to `/tmp`, the port was
//! reverted by hand in the working copy, the rule was run, and the file was restored from the copy.
//! Each rule's comment records the verdict.

use crate::claim::{Claim, RUST, SWIFT, SWIFT_ROOTS, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The GUI video host, which is where the encoder's knobs are read now.
///
/// Named as a DIRECTORY rather than as a file for the reason [`crate::rules::video_host`] gives:
/// the daemon's modules are still being split, and a claim pinned to a filename would go wrong the
/// moment one divides — which is drift none of these rules is about.
const DAEMON: &str = "rust/slopdesk-videohostd";
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
/// ALL FIVE [1, 51] knobs are named: MAX, CONST, CRISP and COMPACT alongside the encoder's own
/// configuration, and `AQP_MAX` in the capture operating point. The fourth is here because this
/// very gate found it — it was not in the brief, it sat ten lines from the other three, and it had
/// the same hand-rolled reject. The FIFTH was found the same way, one file over.
///
/// All five now resolve inside `rust/slopdesk-video` through the SAME `qp_knob`, so the claims name
/// the two modules that call it rather than the Swift that used to. `VideoEncoder.envQP` — the
/// public face the capturer once borrowed across the file boundary — went with the port: the fifth
/// caller lives in the same crate as the other four, so nothing is left to borrow it.
///
/// ## Where the hand-rolled parse could come back now
/// The ban used to name `VideoEncoder.swift` and `WindowCapturer.swift`, the two Swift files that
/// held the reject. Both are deleted (`docs/61`), and the language a fifth copy could be written in
/// is the daemon's own: `rust/slopdesk-videohostd` reads the same knobs, so it is the one place
/// that could clamp a `[1, 51]` ordinal for itself instead of asking. The ban is therefore
/// TRANSLATED rather than dropped — a `.clamp(1, 51)`, a private `QP_MIN`/`QP_MAX`/`MIN_QP`, or a
/// literal frame-QP ceiling, spelled in the daemon. It is scoped to the daemon alone on purpose:
/// `rust/slopdesk-video` legitimately spells every one of those, because it is the module that
/// owns them.
///
/// The positive half is re-aimed the same way. It used to say "the Swift face CALLS the door";
/// with the door gone it says the daemon still ASKS `qp_control` and `encoder_config` rather than
/// resolving an operating point of its own. The "no Swift declares a video-host type" half of the
/// old claim is stated once, tree-wide, in [`crate::rules::deleted_video_swift`].
///
/// ## And the message-shaped control face stays a WRAPPER
/// After the datagram fix its only callers are the state-machine tests, which is the shape the
/// one-implementation rule bans — unless it decides nothing, which it does not: it encodes and
/// hands over. The claim pins exactly that, so it can neither be deleted as dead nor quietly grown
/// into a second transition that only the tests would exercise.
#[must_use]
pub fn a_quantiser_knob_clamps_rather_than_rejects(tree: &Tree) -> Report {
    /// Where the encoder's four knobs are resolved.
    const ENCODER_CONFIG: &str = "rust/slopdesk-video/src/encoder_config.rs";
    /// Where the capture operating point resolves the fifth.
    const CAPTURE_GATES: &str = "rust/slopdesk-video/src/capture_gates.rs";

    check_all(tree, &[
        // `qp_knob` is the one entry all five go through, and it routes to the same
        // `clamped_int_from_env` the general door does — one crate closer to the rules that read
        // the answer than the Swift faces that used to ask.
        Claim::Matches {
            path: ENCODER_CONFIG,
            pattern: r"qp_knob\(",
            message: "the encoder resolves its quantiser knobs some other way — the parse and the clamp are \
                      qp_knob's",
        },
        // The ask, re-aimed off the two deleted Swift faces and onto the daemon that reads the
        // knobs now. A host that stopped naming these modules is a host that has started
        // resolving its own operating point.
        Claim::MentionsUnder {
            root: DAEMON,
            names: &["qp_control", "encoder_config"],
            message: "the daemon stopped asking {entry} — the parse, the clamp and the five [1,51] knobs \
                      are rust/slopdesk-video's, and a host that resolves them itself is the sixth spelling \
                      of a rule that has one (docs/61 §3)",
        },
        // The Swift shape was `environment[…]` followed by a bare `Int(` parse. Translated into
        // the language a sixth copy could now be written in: a clamp to the ordinal's own bounds,
        // a private floor/ceiling constant, or a literal frame-QP ceiling. Scoped to the DAEMON —
        // rust/slopdesk-video spells all three legitimately, because it is what owns them.
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"\.clamp\(1, *51\)|\b(QP_MIN|QP_MAX|MIN_QP)\b|max_allowed_frame_qp *[:=] *[0-9]",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a [1,51] quantiser knob is bounded by hand again in {files} — the ordinal's floor, \
                      its ceiling and the clamp between them are qp_control.rs's, and a second copy answers \
                      SLOPDESK_MAX_QP=0 with the coarsest ceiling the encoder has (docs/61 §3)",
        },
        Claim::Matches {
            path: CAPTURE_GATES,
            pattern: r"qp_knob\(",
            message: "the capture operating point stopped resolving SLOPDESK_AQP_MAX through qp_knob — the \
                      fifth knob of the same shape",
        },
        Claim::Matches {
            path: SESSION_LOGIC,
            pattern: r"handleControl\(datagram: message\.encode\(\)\)",
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
            message: "the settings sheet no longer asks slopdesk_qp_config_default — its defaults are the \
                      encoder's",
        },
        Claim::Matches {
            path: PREFERENCES,
            pattern: r"slopdesk_adaptive_fec_constant\(",
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
/// Two of those three implementations were Swift in the deleted `SlopDeskVideoHost` target and went
/// with `docs/61`. What survives them is the RULE, and the reason the rule needed a gate: the
/// reject reading is one function, it is Rust's, and the way it comes back is a reader growing a
/// private parse beside the door rather than instead of it. So the two dead per-file claims are
/// re-aimed at `rust/slopdesk-videohostd`, which is the reader now — it must still ASK `congestion`
/// and `fps_governor`, and it may not spell a validating parse of its own. Both halves are scoped
/// to the daemon; `rust/slopdesk-video` holds the one implementation and has to spell it.
///
/// `FPSGovernor`'s copy carried a second bug on top of the duplication, and it is the one that
/// would have been reported as "the setting does nothing": it read
/// `ProcessInfo.processInfo.environment` DIRECTLY, bypassing `EnvConfig`'s overlay, so every
/// governor tunable set through the settings sheet was written, persisted, shown as active — and
/// never read. `EnvConfig.string` is the only legal reader here: real env FIRST, then the settings
/// overlay, then the compile-time default.
///
/// ## The direct read is banned TREE-WIDE, and the single-file version is why
/// That ban used to name ONE file. It has since let the same bug ship twice more —
/// `LiveBitratePolicy`'s `SLOPDESK_BPP`, and eighteen client knobs across `MetalVideoRenderer`,
/// `SlopDeskVideoClientSession`, `VideoWindowPipeline`, `TerminalPaneWiring` and `AppSupport` — for
/// the reason a one-file ban always does: it says nothing at all about the file the next knob is
/// written in. So the scope is now every `.swift` file under [`crate::claim::SWIFT_ROOTS`], and
/// `FPSGovernor`'s own `Lacks` is folded into it rather than kept beside it, because the tree-wide
/// claim already covers that path and a second spelling of one law is what this whole rule is
/// about.
///
/// The bug is INVISIBLE to every test, which is what makes it a gate's job: with an EMPTY overlay
/// `EnvConfig.string(k)` IS `ProcessInfo.processInfo.environment[k]`, so the two spellings are
/// byte-identical everywhere a test can look. The difference only appears in a shipped app, where
/// `config.toml`'s `[env]` table folds a raw `SLOPDESK_*` name into the overlay — and a direct read
/// is answered by the real environment alone, so the knob is written, persisted, shown as active,
/// and read past.
///
/// `View::Code` is load-bearing here and was CHECKED rather than assumed: `AdaptiveFECPolicy`,
/// `CaptureGateTable` and `EnvConfig` itself all name the banned spelling in DOC COMMENTS —
/// including the paragraph above — and every one of those mentions is a whole-line `///`, which
/// `Source::code` drops. It matters twice over on the daemon side, where `docs/61` left the deleted
/// Swift's names in the doc comments of the Rust that replaced them. A rule whose own explanation
/// matched its corpus has bitten this crate before.
///
/// ### The one `unless`, and why it is a key rather than a file
/// `SLOPDESK_VIDEO_DEBUG` is a developer gate, not a setting: it has no `config.toml` row,
/// `slopdesk-guigate video` drives it through the real environment, and it is read the same way in
/// eight places spanning the client AND the host. Routing half of them through the overlay would
/// make one `[env]` line light the client and leave the host dark, which is worse than env-only.
/// It is excused by NAME rather than by path because the files holding it — the client session, the
/// window pipeline, the Metal renderer — are the three that hold the most tunables, and a path
/// exemption would un-cover all of them. That is precisely the hole the single-file ban was.
///
/// ### What the exemptions are, and what they are not
/// Every entry is one of two shapes, and neither can hide a knob the way a per-key read can. A WALK
/// hands the door the whole environment because the knob NAMES live behind it
/// (`TrendlineEstimator`, `PacerDepthPolicy`, the FEC and recovery policies); `EnvConfig` publishes
/// a per-KEY resolver and no merged map, and re-spelling `env → overlay` at a walk site would be a
/// second copy of the one precedence rule that type owns — so those knob families are env-only,
/// recorded rather than fixed. A SEAM is a default argument a test replaces
/// (`WorkspaceStore+Bootstrap`, `FocusDebugProbe`). Four entries went rather than being re-aimed —
/// `WindowParkingSidecar.swift`'s seam and `RecoveryIDRPolicyTests.swift`'s skip guard with
/// `docs/61`, then `AppSupportContainer.swift` and `EnvBridge.swift`'s when the Application-Support
/// container stopped being a Swift rule at all (the container is
/// `slopdesk_hostlaunch::record::app_support_dir_in` now, reached through
/// `slopdesk_app_support_dir`, so the environment is read on the far side and the near side lends
/// only the base Foundation alone can resolve) — because an exemption is a permission, and a
/// permission nothing needs excuses a knob nobody meant to allow.
/// `EnvConfig` itself is exempt because it is THE reader. The `Tests` entries are harness reads — a
/// child process's environment, a snapshot output directory, or a guard that must consult the REAL
/// environment to skip when one is set, which is the opposite of reading a knob past the overlay.
///
/// The walk exemptions cost one relocation: `VideoWindowPipeline` used to bind the environment once
/// and subscript it seven times, so exempting it would have un-covered seven live tunables. The
/// walk moved to `PacerDepthPolicy.Config.fromProcessEnvironment()` — the file that consumes it,
/// whose only environment contact it is — and the pipeline is fully covered.
///
/// The ban is on the PARSE-THEN-COMPARE shape all three copies had, `Int(s), v >= lo`, rather than
/// on a door's absence — a file can keep calling the door and grow a second private parse beside
/// it, which is how the third copy appeared in the first place. And the generic pair stays deleted
/// tree-wide, spelled as a CALL rather than as a declaration so that re-adding it anywhere — a
/// helper, an extension, a test fake — is caught by its first user rather than by its author.
#[must_use]
pub fn the_reject_reading_of_an_env_knob_is_rusts(tree: &Tree) -> Report {
    /// The overlay reader, which held the generic pair.
    const ENV_CONFIG: &str = "Sources/SlopDeskVideoProtocol/Settings/EnvConfig.swift";

    /// Every path allowed to reach `ProcessInfo.processInfo.environment`, each because somebody
    /// decided so. A WALK hands the whole map to a door that owns the knob names; a SEAM is a
    /// default argument a test replaces. Neither can hide a per-key knob read behind it, which is
    /// the thing the ban is for.
    const DIRECT_ENV_READERS: &[&str] = &[
        // THE reader — env → overlay → default is this one function, and it has to ask.
        ENV_CONFIG,
        // SEAM: the focus tap's `env:` default argument, plus a developer-only flag with no row.
        "Sources/SlopDeskMacUI/App/FocusDebugProbe.swift",
        // WALK: the `SLOPDESK_DEPTH_*` names are `pacer_depth`'s, so the whole map crosses. Held
        // here, beside its consumer, so `VideoWindowPipeline`'s seven knobs stay covered.
        "Sources/SlopDeskVideoClient/PacerDepthPolicy.swift",
        // WALK: same shape for `SLOPDESK_TREND_*`, whose names are `trendline`'s.
        "Sources/SlopDeskVideoClient/TrendlineEstimator.swift",
        // WALK: both statics hand the whole map to a PURE function that is unit-tested on it.
        "Sources/SlopDeskVideoProtocol/AdaptiveFECPolicy.swift",
        // WALK: same shape for the escalation floor.
        "Sources/SlopDeskVideoProtocol/RecoverySignaling.swift",
        // The automation gate that suppresses auto-reconnect; no `config.toml` row.
        "Sources/SlopDeskWorkspaceCore/Connection/AppConnection.swift",
        // The debug-trace gate reader itself — the key is a VARIABLE, so there is no knob to reach.
        "Sources/SlopDeskWorkspaceCore/Support/DebugTrace.swift",
        // Two developer probes (`SLOPDESK_GLITCH_CARET`, `SLOPDESK_ECHO_PROBE`). The widest
        // exemption here: this is a large file, so a real tunable added to it would go uncovered.
        "Sources/SlopDeskWorkspaceCore/Terminal/TerminalViewModel.swift",
        // The `UserDefaults` suite override a test run sets; not a setting the app offers.
        "Sources/SlopDeskWorkspaceCore/Workspace/Store/SettingsKey.swift",
        // SEAM: `environment:` default argument on the store's bootstrap.
        "Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Bootstrap.swift",
        // Harness: which `slopdesk-dropd` binary the E2E spawns.
        "Tests/SlopDeskFileTransferTests/DropdE2ETests.swift",
        // Harness: where the two snapshot renderers write their PNGs.
        "Tests/SlopDeskMacUITests/MacChromeSnapshotRender.swift",
        "Tests/SlopDeskMacUITests/MacRailStatusRollupRender.swift",
        // Guards that must consult the REAL environment to SKIP when a knob is set outside the
        // overlay — the opposite of reading one past it.
        "Tests/SlopDeskCoreVectorsTests/CoreVectorsGoldenTests.swift",
        "Tests/SlopDeskVideoClientTests/SharpenResolutionTests.swift",
        "Tests/SlopDeskVideoProtocolTests/SettingsReachConsumerTests.swift",
        // The behaviour-preservation proof: it has to spell the legacy expression to compare
        // `EnvConfig.string` against it.
        "Tests/SlopDeskVideoProtocolTests/EnvConfigTests.swift",
    ];

    let claims = vec![
        Claim::Lacks {
            path: ENV_CONFIG,
            pattern: r"(Int|Double)\([a-zA-Z_]+\), *[a-zA-Z_]+ *(>=|<=|>|<) ",
            view: View::Code,
            message: "the overlay reader parses a numeric env knob by hand again — it resolves TEXT, and \
                      the reject rule that reads it is congestion.rs's",
        },
        // The two Swift readers are deleted; the daemon is the reader now, so the ask is re-aimed
        // at it. `congestion` holds the validating parse for rates and fractions, `fps_governor`
        // the tunables that were read past the overlay entirely — a daemon that names neither has
        // gone back to deciding its own operating point.
        Claim::MentionsUnder {
            root: DAEMON,
            names: &["congestion", "fps_governor"],
            message: "the daemon stopped asking {entry} — the reject reading of a rate or a fraction is \
                      rust/slopdesk-video's, and a knob resolved here is one the settings overlay cannot \
                      reach (docs/61 §3)",
        },
        // The Swift shape was `Int(s), v >= lo` — a parse and a bounds comparison on one line. Its
        // Rust respelling is the same two acts: a `.parse` whose result is immediately compared, and
        // a private validator named after the door it replaces. Daemon-scoped; congestion.rs and
        // fps_governor.rs spell exactly this, which is the point of their existing.
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"\bfn (validated|clamped)_(int|double)",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon grew its own validating parse in {files} — the reject rule and the clamp \
                      rule are congestion.rs's and qp_control.rs's, and a private one beside the door is \
                      how the third copy of this arrived the first time (docs/61 §3)",
        },
        // The knob NAME and the parse on one line, which is the reader resolving a SLOPDESK_* key
        // for itself rather than handing the text to the module that owns the key.
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"SLOPDESK_[A-Z_]+",
            all: &[r"\.parse"],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon parses a SLOPDESK_* knob where it names it, in {files} — the KEYS tables \
                      and the readings over them are rust/slopdesk-video's, so a parse here is a second \
                      answer for a knob the settings sheet still shows one value for (docs/61 §3)",
        },
        // The corpus is the whole Swift tree; if it ever reads as fewer than 200 files the walk has
        // gone stale and the two bans below are passing on nothing.
        Claim::Populated {
            roots: SWIFT_ROOTS,
            extensions: SWIFT,
            minimum: 200,
            message: "the tree-wide Swift corpus read as {found} files — the EnvConfig bans are passing \
                      vacuously",
        },
        // The direct read, tree-wide. `View::Code` drops the `///` lines that name this spelling,
        // including the ones in this rule's own subjects; the single `unless` excuses ONE key rather
        // than any file, so the three files holding the most tunables stay covered.
        Claim::NoneUnder {
            roots: SWIFT_ROOTS,
            extensions: SWIFT,
            pattern: r"ProcessInfo\.processInfo\.environment",
            all: &[],
            unless: &[r#"environment\["SLOPDESK_VIDEO_DEBUG"\]"#],
            view: View::Code,
            exempt: DIRECT_ENV_READERS,
            message: "{files} reads the process environment directly — that is answered by the real env \
                      ALONE, so a knob written into config.toml's [env] table lands in EnvConfig's overlay \
                      and is then read past; resolve it through EnvConfig.string",
        },
        Claim::NoneUnder {
            roots: SWIFT_ROOTS,
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
                "rust/slopdesk-video/src/encoder_config.rs",
                "let ceiling = qp_knob(text(\"SLOPDESK_MAX_QP\").as_deref(), DEFAULT_MAX_QP);\n",
            )
            .write(
                "rust/slopdesk-video/src/capture_gates.rs",
                "let aqp = qp_knob(at(\"SLOPDESK_AQP_MAX\"), context.max_allowed_frame_qp);\n",
            )
            // The daemon reads the knobs now, so it is what has to ask. Both modules are named on
            // one `use`, which is how the real encode path spells it.
            .write(
                "rust/slopdesk-videohostd/src/encode.rs",
                "use slopdesk_video::encoder_config::{Config, DEFAULT_BITRATE};\nuse \
                 slopdesk_video::qp_control::QpConfig;\n",
            )
            .write(
                super::SESSION_LOGIC,
                "func handleControl(_ message: VideoControlMessage) { handleControl(datagram: \
                 message.encode()) }\n",
            );
        assert!(super::a_quantiser_knob_clamps_rather_than_rejects(&fixture.tree()).is_clean());

        // The reject that INVERTS the request: `SLOPDESK_MAX_QP=0` asking for the sharpest ceiling
        // and getting the coarsest, with nothing said. Respelled in the language it could come back
        // in — the daemon bounding the ordinal for itself instead of asking qp_control.
        fixture.append(
            "rust/slopdesk-videohostd/src/encode.rs",
            "let ceiling = requested.clamp(1, 51);\n",
        );
        assert!(!super::a_quantiser_knob_clamps_rather_than_rejects(&fixture.tree()).is_clean());

        // And the same drift as a private bound rather than a clamp, which is the shape that reads
        // as a constant nobody would question.
        fixture.write(
            "rust/slopdesk-videohostd/src/encode.rs",
            "use slopdesk_video::encoder_config::Config;\nuse slopdesk_video::qp_control::QpConfig;\nconst \
             QP_MAX: i32 = 51;\n",
        );
        assert!(!super::a_quantiser_knob_clamps_rather_than_rejects(&fixture.tree()).is_clean());

        // The daemon that stopped asking at all: nothing is respelled here, so only the ask can
        // fail — which is the half a drained corpus would otherwise pass vacuously. The seed reads
        // RAW rather than comment-stripped, so it may not name either module even in prose.
        fixture.write(
            "rust/slopdesk-videohostd/src/encode.rs",
            "let ceiling = self.tuned_ceiling;\n",
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

    /// The corpus floor, the overlay reader, and the daemon that reads the knobs now.
    fn reject(fixture: &Fixture) {
        for index in 0..200 {
            fixture.write(&format!("Sources/Filler/Filler{index}.swift"), "let filler = 0\n");
        }
        fixture
            .write(
                "rust/slopdesk-videohostd/src/session_capture.rs",
                "use slopdesk_video::congestion::{ABR_KEYS, CongestionConfig};\nuse \
                 slopdesk_video::fps_governor::FpsGovernorConfig;\n",
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

        // The third copy's shape, in the language it could come back in: a validator grown BESIDE
        // the door rather than instead of it, which is exactly how the third one arrived in Swift.
        fixture.append(
            "rust/slopdesk-videohostd/src/session_capture.rs",
            "fn validated_double(raw: &str, lo: f64, hi: f64) -> Option<f64> { None }\n",
        );
        assert!(!super::the_reject_reading_of_an_env_knob_is_rusts(&fixture.tree()).is_clean());

        // The knob resolved where it is named. `SLOPDESK_ABR_LOSS` clamped is a controller that
        // treats every frame as catastrophic loss forever, and the reading that decides which of
        // clamp or reject applies is the owning module's, not the reader's.
        reject(&fixture);
        fixture.append(
            "rust/slopdesk-videohostd/src/session_capture.rs",
            "let loss = env(\"SLOPDESK_ABR_LOSS\").and_then(|v| v.parse::<f64>().ok());\n",
        );
        assert!(!super::the_reject_reading_of_an_env_knob_is_rusts(&fixture.tree()).is_clean());

        // The daemon that stopped asking either module — the half that has no respelling to catch.
        reject(&fixture);
        fixture.write(
            "rust/slopdesk-videohostd/src/session_capture.rs",
            "let target = self.tuned_target;\n",
        );
        assert!(!super::the_reject_reading_of_an_env_knob_is_rusts(&fixture.tree()).is_clean());

        // And the generic Swift pair back, caught by its first USER rather than by its author.
        reject(&fixture);
        fixture.write(
            "Sources/SlopDeskVideoClient/Governor.swift",
            "let n = EnvConfig.int(\"SLOPDESK_ABR_LOSS\", 1, 100)\n",
        );
        assert!(!super::the_reject_reading_of_an_env_knob_is_rusts(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_knob_read_past_the_settings_overlay_is_red() {
        let fixture = Fixture::new("video-direct-env");
        reject(&fixture);
        assert!(super::the_reject_reading_of_an_env_knob_is_rusts(&fixture.tree()).is_clean());

        // The whole point of widening the ban: a knob in a file NOBODY thought to name. The
        // single-file version said nothing about `LiveBitratePolicy`, so `SLOPDESK_BPP` shipped
        // deaf — written by the sheet, persisted, shown as active, and never read.
        fixture.write(
            "Sources/SlopDeskVideoClient/NewKnob.swift",
            "static let on = ProcessInfo.processInfo.environment[\"SLOPDESK_NEW\"] == \"1\"\n",
        );
        assert!(!super::the_reject_reading_of_an_env_knob_is_rusts(&fixture.tree()).is_clean());

        // The SAME line under an exempted path is not a finding — the exemption IS the decision,
        // and `EnvConfig` is the one reader that has to ask the environment.
        fixture.remove("Sources/SlopDeskVideoClient/NewKnob.swift");
        fixture.append(
            "Sources/SlopDeskVideoProtocol/Settings/EnvConfig.swift",
            "if let v = ProcessInfo.processInfo.environment[\"SLOPDESK_NEW\"] { return v }\n",
        );
        assert!(super::the_reject_reading_of_an_env_knob_is_rusts(&fixture.tree()).is_clean());

        // The developer gate stays env-only by decision, in a file that is NOT exempt…
        reject(&fixture);
        fixture.write(
            "Sources/SlopDeskVideoClient/FramePacer.swift",
            "static let dbg = ProcessInfo.processInfo.environment[\"SLOPDESK_VIDEO_DEBUG\"] != nil\n",
        );
        assert!(super::the_reject_reading_of_an_env_knob_is_rusts(&fixture.tree()).is_clean());

        // …and the excuse is that ONE key rather than that file, which is the difference between
        // this `unless` and the path exemption it replaced: a tunable beside it is still a finding.
        fixture.append(
            "Sources/SlopDeskVideoClient/FramePacer.swift",
            "static let nack = ProcessInfo.processInfo.environment[\"SLOPDESK_NACK\"] == \"1\"\n",
        );
        assert!(!super::the_reject_reading_of_an_env_knob_is_rusts(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_drained_swift_corpus_is_red() {
        let fixture = Fixture::new("video-corpus-floor");
        reject(&fixture);
        assert!(super::the_reject_reading_of_an_env_knob_is_rusts(&fixture.tree()).is_clean());

        // Every named file is still there and still says the right thing, so the only claim left to
        // fail is the floor — which is what stops a stale walk turning both bans into a silent
        // pass.
        for index in 0..200 {
            fixture.remove(&format!("Sources/Filler/Filler{index}.swift"));
        }
        assert!(!super::the_reject_reading_of_an_env_knob_is_rusts(&fixture.tree()).is_clean());
    }
}
