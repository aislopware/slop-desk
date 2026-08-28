//! The two operations that live in exactly one crate, and the callers that ask Rust for a verdict
//! rather than keeping a second copy of it.
//!
//! Ported from the deleted `check-supervisor.sh`. What the first pair have in common is that the
//! guarantee is attached to the LOCATION rather than to the code: a disassembly pin can only guard
//! a symbol compiled beside it, and a C entry point next to the logic it marshals is a pointer bug
//! one edit away from being a terminal bug.
//!
//! The rest ask "is this still a caller and not a second answer", which is a question about
//! CONTENT: it asks for the verdict, and it does not hold the table. `docs/61` changed WHO gets
//! asked that, not what it asks. Encode and capture used to be Swift faces over C doors, and both
//! files are deleted — their caller is `rust/slopdesk-videohostd`, which links `slopdesk-video` as
//! an ordinary Rust dependency, so the ask is a `use` and the check is a [`Claim::MentionsUnder`]
//! over the daemon DIRECTORY. Of the VIDEO path's faces exactly one is still Swift and still
//! checked as one — the client's `VideoDecoder`, which `import CSlopDeskFFI` plus a ban list
//! describes exactly — and the replay buffer and the three agent-detection files are checked the
//! same way for reasons of their own, unrelated to `docs/61`. The framework bans the two ported
//! rules carry did not move with their subjects: they went TREE-WIDE over Swift, because with no
//! Swift host left there is no target that could hold a legitimate compression session or capture
//! stream.

use crate::claim::{Claim, RUST, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The Rust daemon that replaced the Swift GUI video host.
///
/// A DIRECTORY rather than a file, and that is the whole reason the re-aim works. `docs/61` split
/// the deleted `WindowCapturer.swift` and `VideoEncoder.swift` across a dozen modules — `capture`,
/// `encode`, `session_capture`, `session_pump`, `minter`, `windowgeometry` — and which module holds
/// which ask is an implementation choice that may move again. What may NOT move is that the daemon
/// asks `slopdesk_video` for the verdict and does not respell it, and that is a property of the
/// crate, not of any file in it.
const DAEMON: &str = "rust/slopdesk-videohostd";

/// `fork`, `openpty` and `extern "C"`, each allowed in exactly one crate.
///
/// The fork-to-exec contract is pinned by disassembly in
/// `rust/slopdesk-posix/src/fork_window_contract.rs`, and a pin guards a symbol it is compiled
/// beside — a second `fork` anywhere else is unguarded BY CONSTRUCTION, not merely unreviewed.
///
/// `#[unsafe(no_mangle)] extern "C"` in a domain crate would put argument marshalling next to the
/// logic it marshals, which is how a pointer bug becomes a terminal bug, and it would force that
/// crate off `forbid` — so the ABI is a crate, not an attribute (`docs/55`).
///
/// Both exemptions are DIRECTORIES, because both say "this operation lives in one crate" and a
/// crate is a directory.
///
/// ## Why the two patterns are assembled rather than spelled
/// These are the first bans in this crate whose haystack CONTAINS THE GATE. The shell's copies
/// scanned `rust/**/*.rs` from a file that was not one; now the gate is Rust, so a pattern typed as
/// a literal here is a match this rule finds in its own source — and the honest fix is not to
/// exempt the crate, which would leave a real one unnoticed, but to stop spelling it. `concat!`
/// builds the pattern at compile time from halves that are each harmless, so the source never
/// carries the byte sequence and the ban stays universal.
///
/// The prose above and the break-tests below still name them, and both are read out: comment lines
/// by [`View::CodeBeforeTests`]'s strip, and the fixtures by its stop at `#[cfg(test)]`. A ban
/// whose proof has to spell the banned thing is exactly what that view exists for.
#[must_use]
pub fn one_home_per_operation(tree: &Tree) -> Report {
    const FORK: &str = concat!("libc::", "fork", "|libc::", "openpty");
    const C_ABI: &str = concat!("extern ", r#""C""#);

    let claims = [
        Claim::NoneUnder {
            roots: &["rust"],
            extensions: RUST,
            pattern: FORK,
            all: &[],
            unless: &[],
            view: View::CodeBeforeTests,
            exempt: &["rust/slopdesk-posix/"],
            message: "a fork/openpty is outside rust/slopdesk-posix ({files}) — the disassembly pin cannot \
                      guard it (docs/51 §6.15)",
        },
        Claim::NoneUnder {
            roots: &["rust"],
            extensions: RUST,
            pattern: C_ABI,
            all: &[],
            // A type ALIAS for a C signature points the other way: it is not a door this process
            // opens, it is the shape of one somebody else already opened. `slopdesk-posix`'s
            // `dynsym` needs exactly one — the private CoreGraphics symbol it resolves has no
            // binding anywhere, so its declaration has to be written down to be called at all — and
            // banning that would ban CALLING C rather than EXPORTING it, which is not this rule.
            // An `#[unsafe(no_mangle)] pub extern` in the same file is still caught: it is a
            // different line, and this excuse names the alias form alone.
            // A PRIVATE handler points the same way, and further: the kernel calls it, nothing
            // else can. `sigaction(2)` takes a C function pointer, so `restore_on_signals` in
            // `slopdesk-posix` has no other way to spell its restore-then-reraise — and without
            // `pub` the item is not reachable across a crate boundary, without `no_mangle` its
            // symbol is mangled and no C caller can name it. So it is not a door by construction,
            // and moving it to `slopdesk-ffi` would put the handler in a different crate from the
            // termios state it restores, which is the pointer-bug-becomes-terminal-bug shape this
            // rule exists to prevent, inverted. The excuse names the bare form ALONE: a `pub` or a
            // `no_mangle` on the same line is a different line and is still caught.
            unless: &[r"type \w+ = unsafe extern", r"^extern \x22C\x22 fn "],
            view: View::CodeBeforeTests,
            exempt: &["rust/slopdesk-ffi/"],
            message: "a C entry point is outside rust/slopdesk-ffi ({files}) — the ABI is a crate, not an \
                      attribute (docs/55)",
        },
    ];
    check_all(tree, &claims)
}

/// The replay buffer is `slopdesk_wire::replay`, and the Swift file is a handle owner.
///
/// The two banned strings are what a re-implementation would need and a wrapper cannot have: the
/// ring storage, and the per-entry eviction walk. Checked as CONTENT rather than as a deleted path,
/// because unlike the ported daemons this file legitimately still exists.
#[must_use]
pub fn replay_buffer(tree: &Tree) -> Report {
    const REPLAY: &str = "Sources/SlopDeskTransport/ReplayBuffer.swift";

    let claims = [
        Claim::Names {
            path: REPLAY,
            needle: "import CSlopDeskFFI",
            message: "Sources/SlopDeskTransport/ReplayBuffer.swift no longer calls the Rust buffer — the \
                      port was undone (docs/55 §6)",
        },
        Claim::Lacks {
            path: REPLAY,
            pattern: "private var scrollbackRing",
            view: View::Code,
            message: "Sources/SlopDeskTransport/ReplayBuffer.swift grew the ring storage back — the buffer \
                      lives in rust/slopdesk-wire (docs/55 §6)",
        },
        Claim::Lacks {
            path: REPLAY,
            pattern: "func evictScrollbackToFit",
            view: View::Code,
            message: "Sources/SlopDeskTransport/ReplayBuffer.swift grew the eviction walk back — the buffer \
                      lives in rust/slopdesk-wire (docs/55 §6)",
        },
    ];
    check_all(tree, &claims)
}

/// Agent detection is `rust/slopdesk-agent`, and the Swift module is vocabulary plus marshalling.
///
/// Two files stay as faces and must each still call the crate. The ones that used to be on that
/// list are GONE rather than thin: once the fusion moved, nothing in `Sources/` had a reason to
/// name a machine, a signal, a process matcher or an input classifier — the detector's doors take
/// the raw input and answer the fold. A wrapper that only forwards is still a file another wrapper
/// can be written next to, so the check for those is that they stay deleted.
///
/// `AgentJobIdentifier.swift` left the list by that rule rather than by an exception to it: it
/// staged a foreground job across the FFI one field at a time because Swift owned the syscalls that
/// produced it. `rust/slopdesk-posix::proc` owns them now, so the whole question is
/// `slopdesk_pty_foreground_agent` and there is nothing left for a face to marshal.
///
/// `AgentDetectionHold.swift` and `AgentScreenDetection.swift` left most recently, and for the
/// reason the two survivors do not: a view `switch`es on an agent's KIND and its STATUS, never on a
/// screen verdict or a tuning interval. Those two were the HOST's vocabulary, and `docs/60` F.9
/// deleted the Swift host — `rust/slopdesk-hostsession` links the crate and reads
/// `AgentScreenDetection` and `AgentDetectionHold` as Rust. A case list nothing reads is a second
/// implementation waiting for its first caller, so they are checked as absent rather than as faces.
///
/// The six banned strings are the tables and the walks a re-implementation would need and a wrapper
/// cannot have.
#[must_use]
pub fn agent_detection(tree: &Tree) -> Report {
    const FACES: &[&str] = &[
        "Sources/SlopDeskAgentDetect/AgentKind.swift",
        "Sources/SlopDeskAgentDetect/ClaudeStatus.swift",
    ];
    const GHOSTS: &str = r#"case "claude-code"|wrapperBasenames|cancelOnly|pendingIdleStartedAt|private var blockLedger|func wrappedAgentName"#;

    let mut report = Report::new();
    for face in FACES {
        Claim::Names {
            path: face,
            needle: "import CSlopDeskFFI",
            // The sentence names the path itself, since a table cannot carry a placeholder the
            // claim does not fill.
            message: "a Sources/SlopDeskAgentDetect face no longer calls the Rust crate — the port was \
                      undone (docs/55 §6)",
        }
        .check(tree, &mut report);
    }
    report.absorb(check_all(tree, &[
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"(enum|struct|final class|class|actor) (ClaudeStatusMachine|ClaudeProcessMatcher|PaneInputClassifier)\b|enum ClaudeSignal\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift machine/signal wrapper is back in {files} — the detector's doors take \
                      the raw input (docs/50)",
        },
        Claim::NoneUnder {
            roots: &["Sources/SlopDeskAgentDetect"],
            extensions: SWIFT,
            pattern: GHOSTS,
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "Sources/SlopDeskAgentDetect grew a detection table back ({files}) — the rules \
                      live in rust/slopdesk-agent (docs/55 §6)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskAgentDetect/AgentJobIdentifier.swift",
            message: "the Swift foreground-job identifier is back — one door answers the whole \
                      question now (rust/slopdesk-ffi::foreground, docs/55 §6)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskAgentDetect/AgentScreenDetection.swift",
            message: "the Swift screen verdict is back — no view switches on one, and hostd reads \
                      slopdesk_agent::AgentScreenDetection itself (docs/60 F.9)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskAgentDetect/AgentDetectionHold.swift",
            message: "the Swift temporal constants are back — the six numbers are read as constants \
                      by rust/slopdesk-hostsession, not through a door (docs/60 F.9)",
        },
    ]));
    report
}

/// Who holds a pane's foreground, and which app is frontmost: each asked ONCE, in Rust.
///
/// Both questions were answered in Swift with the framework's own calls — six Darwin syscalls per
/// foreground poll, and `NSRunningApplication` beside a door that already answered the other half
/// of the frontmost read. Both are `rust/slopdesk-posix::proc` and `rust/slopdesk-apple-app` now,
/// reached through `rust/slopdesk-ffi`'s `foreground` and `app` modules.
///
/// **This rule lives here rather than in `check-supervisor.sh` because of what `View::Code` buys.**
/// A shell ban greps raw text, and every file that explains this port names the calls it removed —
/// `NSWorkspace.shared.frontmostApplication` is spelled in two doc comments precisely to say why
/// there is no fallback to it. A raw ban cannot tell an explanation from a call, so the shell
/// version fired on its own documentation. Stripping whole-line comments first lets prose name what
/// code may not, which is the only way a ban and an honest comment can coexist.
///
/// The ban carries no exemption at all now. It once had two candidates it did not need —
/// `AppIconGlue` and the Swift `slopdesk-navhistory-probe`, which asked
/// `runningApplications(withBundleIdentifier:)` for an ICON rather than for a pid — and both are
/// gone: the probe is `rust/slopdesk-navprobe` and looks its target up through
/// `slopdesk_posix::proc` plus `slopdesk_apple_app::bundle_id`. The banned shape was always the pid
/// lookup, which is the one this port replaced.
///
/// ## The pane census joined it, so the ban widened
/// This rule once banned two calls and said so: the all-pids census and the `PROC_PIDVNODEPATHINFO`
/// cwd read were still `HostMetadataProbe.swift`'s, a DIFFERENT reading, and banning them would
/// have needed an exemption for that file — a ban whose exemption list is the only place the debt
/// is written down is a rule that reports itself green. That census is
/// `rust/slopdesk-panecensus` now, reached through `rust/slopdesk-ffi`'s `pane_probe`, so the
/// exemption is gone rather than granted and every call below has exactly one home.
///
/// `proc_name` is banned as a CALL (`proc_name(`) and not as a token, because
/// `SlopDeskMetadataPort(proc_name:)` is the wire record's own field label and naming a struct
/// field is not making a syscall.
///
/// The widened ban still carries no exemption, for the reason above: the two icon lookups that
/// were never the banned shape have both left Swift.
///
/// ## And the accessibility tree, all but the subscription
/// The fourth claim is the only one here that bans less than the whole framework area, and what it
/// leaves out is the point. Every EFFECT on a window — park, restore, resize, un-minimize, raise —
/// is `rust/slopdesk-apple-ax`'s, and so is every attribute READ, the trust check and the private
/// window-id symbol; all of those are banned outright. What is not banned is
/// `AXUIElementCreateApplication` and `AXUIElementSetMessagingTimeout`: those two calls create and
/// configure the element a subscription attaches to and read nothing, and an observer with a run
/// loop behind it is a SUBSCRIPTION rather than an effect on the system, which is `docs/57` §1's
/// test for what belongs in the objc2 family.
///
/// The observer that used to make both was the window feed's, and `docs/61` moved the feed into
/// `rust/slopdesk-videohostd`, so the carve-out currently protects nothing. It stays because it is
/// a ruling rather than an exemption — the two calls are not effects, whoever makes them — and its
/// break-test below is what keeps a later widening from sweeping them in on the argument that
/// nothing needs them today.
///
/// The read half joined the ban when `HostNavHistory` moved. While it was still Swift, banning
/// `AXUIElementCopyAttributeValue` would have needed an exemption for it, and a ban whose exemption
/// list is the only place the debt is written down is the failure the census section above
/// describes. The file is a face over `slopdesk_nav_history_read` now, so the exemption is gone
/// rather than granted.
#[must_use]
pub fn one_probe_per_reading(tree: &Tree) -> Report {
    // Assembled rather than spelled, because this file is itself under `Sources`-adjacent review
    // and a literal here would be the second spelling the rule exists to forbid.
    const SYSCALLS: &str = concat!(
        "tcgetpgrp",
        "|KERN_PROCARGS2",
        "|proc_listpids",
        "|proc_pidpath",
        "|proc_pidinfo",
        r"|proc_name\(",
        "|PROC_ALL_PIDS",
        "|PROC_PIDVNODEPATHINFO",
        "|PROC_PIDTBSDINFO",
        r"|ptsname\("
    );
    const FRONTMOST: &str = concat!(
        "NSRunningApplication",
        r"\(processIdentifier:",
        "|NSWorkspace",
        r"\.shared\.frontmostApplication"
    );
    // NOT `NSCursor` on its own. Setting the app's OWN pointer is UI and stays Swift — the pane
    // divider and the move affordance push and pop cursors on every drag. What moved is the two
    // reads: the system-wide DISPLAYED shape, which crosses the window-server boundary, and the
    // private seed that says it changed.
    const CURSOR: &str = concat!(
        "NSCursor",
        r"\.currentSystem",
        "|CGSCurrentCursorSeed",
        "|SLSCurrentCursorSeed"
    );
    // NOT `AXUIElementCreateApplication` or `…SetMessagingTimeout`: those attach a SUBSCRIPTION with
    // a run loop and read nothing, and `docs/57` §1 keeps those Swift. Every other reach into the
    // tree is banned — the READ, the write, the action, the trust check and the private window-id
    // symbol. The last is the sharpest: it was a `@_silgen_name` declaration in the deleted
    // injector, and a second declaration of a private symbol is how two callers end up disagreeing
    // about which framework exports it.
    const ACCESSIBILITY: &str = concat!(
        "AXIsProcessTrusted",
        "|AXUIElementCopyAttributeValue",
        "|AXUIElementSetAttributeValue",
        "|AXUIElementPerformAction",
        "|_AXUIElementGetWindow",
        "|kAXPositionAttribute",
        "|kAXSizeAttribute",
        "|kAXMinimizedAttribute",
        "|kAXRaiseAction",
        "|kAXEnabledAttribute",
        "|kAXChildrenAttribute",
        "|kAXMenuBarAttribute",
        "|kAXMenuItemCmd"
    );
    check_all(tree, &[
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: SYSCALLS,
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift foreground PROBE is back in {files} — the syscalls are rust/slopdesk-posix, \
                      and slopdesk_pty_foreground_group/_name/_agent are the three questions they answer \
                      (docs/55 §6)",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: FRONTMOST,
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift frontmost/app read is back in {files} — slopdesk_app_bundle_id and \
                      slopdesk_app_activate answer it, and NSWorkspace's snapshot freezes in a daemon that \
                      pumps no run loop (docs/57 §5)",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: CURSOR,
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift read of the DISPLAYED cursor is back in {files} — the shape is \
                      slopdesk-apple-cursor and the seed is slopdesk_posix::dynsym, joined behind \
                      slopdesk_cursor_sampler_*; setting this app's own pointer is UI and is untouched \
                      (docs/57 §5)",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: ACCESSIBILITY,
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift AX write, action, trust read or private window-id symbol is back in {files} — \
                      slopdesk-apple-ax holds the tree and slopdesk_ax_* is the whole door; the window id \
                      comes from slopdesk_posix::dynsym, which asks HIServices for it because CoreGraphics \
                      does not export it (docs/57 §5)",
        },
    ])
}

/// HEVC ENCODE is `slopdesk-apple-vt`, and `rust/slopdesk-videohostd` is the driver over it.
///
/// The ban is on the COMPRESSION half of `VideoToolbox`. Its decompression twin is the rule below,
/// separate rather than folded in because the two have different audiences — only the host encodes,
/// every client decodes — so a single rule would name one file in the other's message.
///
/// Two of the banned strings are not calls, and they are the ones worth having. A property KEY
/// constant in Swift means somebody is configuring a session from this side of the boundary, and a
/// `kVTEncodeFrameOptionKey_` means somebody is steering a frame — both are the state machine
/// growing back one write at a time, which is how the original 1500-line file happened. The key
/// constants are also where the port found its silent bug: `…_ForceKeyFrame` is the string
/// `EncoderForceKeyframe`, so a Swift respelling would look right, apply without error, and ship
/// every forced IDR as a delta frame.
///
/// ## The Swift ban outlived its subject, and got STRONGER for it
/// `docs/61` deleted the Swift video host's `VideoEncoder`, and with it the last Swift that had
/// any business near a compression session. The ban did not narrow when its one plausible
/// offender left — it widened, because there is now no host target left that could hold a
/// legitimate one. Every `VTCompressionSession*` under `Sources` or `Tests` is a re-port, with no
/// exemption possible and none granted.
///
/// ## What the CONTENT half re-aimed onto
/// The old rule checked the Swift face by content: it must call the door, and it must not hold the
/// four things the rules crate owns — the quantiser bracket, the drop-relief integrator, the
/// budget-to-ceiling ramp and the six constants that ramp was calibrated with. Both halves survive
/// the language change, because neither was ever about Swift.
///
/// The DRIVER is `rust/slopdesk-videohostd/src/encode.rs`, and what it must still do is ASK:
/// `slopdesk_video::encoder_config` for every knob resolved and clamped, and
/// `slopdesk_video::encoder_state` for which properties to write and when. That ask is checked over
/// the whole daemon directory rather than at that file, because which module holds it is the
/// daemon's business and moving it is not this rule's failure.
///
/// The four bans are the SAME four, respelled in Rust and scoped to the daemon alone.
/// `rust/slopdesk-video` and the `slopdesk-apple-*` family legitimately spell these interiors —
/// `encoder_state` and `encoder_ceiling` ARE the bracket and the ramp — so a ban over `rust/`
/// would fire on the home it points at. What the daemon may not do is answer any of the four
/// itself: a re-transcription has to divide a budget by a pixel rate and interpolate across a band,
/// so it has to spell one of these four shapes, and it has to type at least one of the six
/// constants as a literal.
///
/// The doors this rule used to name are gone. `check-supervisor.sh`'s withdrawn section 1 pinned
/// the Swift face to three FFI doors, and `docs/61` §2 deleted the shim's whole encoder module
/// outright: the daemon links `slopdesk-apple-vt` as an ordinary Rust dependency, so there is no
/// `slopdesk_video_encoder_*` to call and the message no longer claims there is.
#[must_use]
pub fn hevc_encode_is_rusts(tree: &Tree) -> Report {
    // Assembled for the same reason as the rules above it: this file is scanned by nothing, but the
    // prose that explains a ban is read by everyone, and a literal here is a string this repo now
    // contains twice.
    const COMPRESSION: &str = concat!(
        "VTCompressionSessionCreate",
        "|VTCompressionSessionEncodeFrame",
        "|VTCompressionSessionCompleteFrames",
        "|VTCompressionSessionPrepareToEncodeFrames",
        "|VTCompressionSessionInvalidate",
        "|VTCompressionOutputCallback",
        "|kVTCompressionPropertyKey_",
        "|kVTEncodeFrameOptionKey_",
        "|kVTVideoEncoderSpecification_",
        "|kVTQPModulationLevel_"
    );
    let claims = [
        Claim::NoneUnder {
            roots: &["Sources", "Tests"],
            extensions: SWIFT,
            pattern: COMPRESSION,
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift HEVC compression session is back in {files} — slopdesk-apple-vt holds the \
                      session and every property write, slopdesk_video::encoder_config resolves the knobs \
                      and ::encoder_state runs the brackets, all of it linked into rust/slopdesk-videohostd \
                      as ordinary Rust. No Swift target encodes any more, so there is no exemption to ask \
                      for (docs/57 §5, docs/61 §2)",
        },
        Claim::MentionsUnder {
            root: DAEMON,
            names: &["slopdesk_video::encoder_config", "slopdesk_video::encoder_state"],
            message: "the daemon stopped asking {entry} — rust/slopdesk-videohostd/src/encode.rs drives the \
                      compression session and asks the rules crate for every knob and every property write; \
                      a driver that answers either itself is the 1500-line Swift file growing back in a new \
                      language (docs/61 §2)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"fn begin_crisp_bracket|fn begin_compact_bracket|\bbracket_depth\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon grew the quantiser bracket back in {files} — a bracket owns the quantiser \
                      for its whole span and that invariant lives in rust/slopdesk-video::encoder_state, \
                      which is exercised where no encoder exists (docs/57 §5, docs/61 §2)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"\b(drop_relief|consecutive_drops)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon grew the drop-relief integrator back in {files} — the Swift one folded \
                      only in the default regime's else arm, so under const-QP its counter never drained; \
                      rust/slopdesk-video::encoder_state folds it unconditionally (docs/57 §5, docs/61 §2)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"/ *pixel_rate\b|\bsharp *- *coarse\b|\bcoarse *- *sharp\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon spells the quantiser ramp again in {files} — the budget→ceiling law is \
                      rust/slopdesk-video::encoder_ceiling, reached through ::encoder_state, and it is the \
                      same ramp the per-frame adaptive quantiser walks (docs/57 §5, docs/61 §2)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            // CASE-INSENSITIVE, which the Swift original had no need to be. A tuned constant in
            // Rust is `const ATTACK_STEP`, not `attackStep`, and a ban that matched only the
            // lower-case binding would miss the ONE spelling a re-transcription actually uses —
            // green, and banning nothing.
            pattern: r"\b(?i:attack_step|hold_frames|decay_every|sharp_qp_ceiling|qp_ceiling_(sharp|coarse)_bpp)\b *(:[^=]*)?= *[0-9]",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon types a tuned ceiling constant again in {files} — all six were calibrated \
                      together on hardware and live beside the measurements in \
                      rust/slopdesk-video::encoder_ceiling (docs/57 §5, docs/61 §2)",
        },
    ];
    check_all(tree, &claims)
}

/// The client's HEVC DECOMPRESSION session is Rust's, and `VideoDecoder.swift` is a face over it.
///
/// The encoder's twin, and the other half of the `docs/57` §5 `vt` row. Its shape is the same: a
/// ban on the session vocabulary anywhere in Swift, a demand that the face still call the door, and
/// content checks on the two rules the face must NOT hold back.
///
/// Both content checks name a BUG rather than a preference. The parameter-set cache is what a hard
/// decode failure must CLEAR: on a fixed-capture-size stream the recovery IDR carries
/// byte-identical sets, so a cache that survived would answer "reuse" and hand the next frame to
/// the session that just failed — for ever, with nothing reporting it. And the decode-wall
/// average's first sample must SEED it whole; folding against zero shows a quarter of the real
/// figure and climbs for a dozen frames, which reads as a decoder warming up.
///
/// What is deliberately NOT banned is the `CoreMedia` side. `CMVideoFormatDescriptionCreate…` and
/// `kCMSampleAttachmentKey_…` are how the SIMULATOR and ANDROID panels feed an
/// `AVSampleBufferDisplayLayer` — a different pipeline with no decompression session in it at all.
/// Sweeping those in would fire on the tree this rule ships with, and a rule that does that gets
/// deleted rather than fixed.
#[must_use]
pub fn hevc_decode_is_rusts(tree: &Tree) -> Report {
    const DECODER: &str = "Sources/SlopDeskVideoClient/VideoDecoder.swift";
    // Sessions and their vocabulary only — see the note above.
    const DECOMPRESSION: &str = concat!(
        "VTDecompressionSessionCreate",
        "|VTDecompressionSessionDecodeFrame",
        "|VTDecompressionSessionInvalidate",
        "|VTDecompressionSessionWaitForAsynchronousFrames",
        "|VTDecompressionOutputCallback",
        "|kVTDecompressionPropertyKey_",
        "|kVTVideoDecoderSpecification_"
    );

    let claims = [
        Claim::NoneUnder {
            roots: &["Sources", "Tests"],
            extensions: SWIFT,
            pattern: DECOMPRESSION,
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift HEVC decompression session is back in {files} — slopdesk-apple-vt holds the \
                      session, the format description and the sample buffer, slopdesk_video::decoder_state \
                      decides when to rebuild one, and slopdesk_video_decoder_* is the whole door (docs/57 \
                      §5)",
        },
        Claim::Names {
            path: DECODER,
            needle: "import CSlopDeskFFI",
            message: "Sources/SlopDeskVideoClient/VideoDecoder.swift no longer calls the Rust decoder — the \
                      port was undone (docs/57 §5)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskVideoClient/HEVCParameterSets.swift",
            message: "Sources/SlopDeskVideoClient/HEVCParameterSets.swift is back — the VPS/SPS/PPS scan \
                      over an AVCC frame is rust/slopdesk-video::hevc_parameter_sets, and the host's \
                      packetizer already read it from there, so a second one would be the two-language \
                      mirror CLAUDE.md forbids (docs/57 §5)",
        },
        Claim::Lacks {
            path: DECODER,
            pattern: "needsReconfigure|currentParameterSets|cachedParameterSets",
            view: View::Code,
            message: "Sources/SlopDeskVideoClient/VideoDecoder.swift decides again whether a keyframe is \
                      worth rebuilding for — that cache is what a hard failure must CLEAR, and getting it \
                      wrong freezes the pane permanently on a fixed-size stream with nothing reporting it \
                      (rust/slopdesk-video::decoder_state, docs/57 §5)",
        },
        Claim::Lacks {
            path: DECODER,
            pattern: "decodeEWMAAlpha|foldDecodeEWMA|decodeMsEWMA",
            view: View::Code,
            message: "Sources/SlopDeskVideoClient/VideoDecoder.swift folds the decode-wall average again — \
                      the first sample must SEED it rather than fold against zero, or the stats HUD shows a \
                      warmup ramp no decode ever took (rust/slopdesk-video::decoder_state, docs/57 §5)",
        },
    ];
    check_all(tree, &claims)
}

/// CAPTURE is `slopdesk-apple-sck`, and `rust/slopdesk-videohostd` is the frame pipeline over it.
///
/// The third row of `docs/57` §5's video group. Its ban used to have to be NARROW for a reason that
/// half survives: the other two could sweep a whole framework because nothing else in Swift touches
/// `VideoToolbox`, whereas `SCShareableContent`, `SCWindow` and `SCDisplay` are an ENUMERATION of
/// what exists and not a capture. So the ban is on the STREAM: the filter, the configuration, the
/// two protocols, the lifecycle calls and the per-sample attachment vocabulary. A rule that fired
/// on the tree it ships with gets deleted rather than fixed.
///
/// Two of the banned strings are attachment READS rather than calls, and they are the ones worth
/// having. `SCStreamFrameInfo` and `SCFrameStatus` are how a caller tells a frame carrying new
/// pixels from the framework's idle-skip, and a Swift respelling of that read is how the whole
/// pipeline grows back: everything downstream of it — the pacer, the adaptive quantiser, the scroll
/// reprojection — is already here, and only the SOURCE moved.
///
/// ## The Swift ban outlived its subject, and lost an exemption
/// `docs/61` deleted the Swift video host's `WindowCapturer` and the whole Swift `videohostd`
/// entry point, so the preview glue that used to be exempted — it
/// asked `SCScreenshotManager` for ONE still image, a different API that happens to take a filter
/// and a configuration to describe the shot — is gone with them. Removing a dead exemption is not
/// bookkeeping: an exemption list that outlives its file is a hole any new file can be named into.
///
/// ONE exemption survives, and it is a decision on the record rather than a grep that misses.
/// `Sources/slopdesk-framewatch/main.swift` is the glass-to-glass measurement harness: it runs two
/// streams at once and compares their delivery, so porting it would mean measuring the port with
/// the port.
///
/// ## What the CONTENT half re-aimed onto
/// The old rule checked the Swift face by content: it must call the door, and it must not hold the
/// four things the far side owns — the delivery ceiling, the surface depth, the crop arithmetic and
/// the in-place-resize gate. Each of the four is a clamp that was untestable where it sat, since
/// nothing there could be instantiated without a window server and a Screen-Recording grant, and
/// each is now golden-pinned where no window server exists.
///
/// The pipeline is `rust/slopdesk-videohostd`, spread across `capture`, `session_capture`,
/// `session_pump`, `minter` and `windowgeometry`, and what it must still do is ASK:
/// `slopdesk_video::capture_config` for every clamp, `::capture_gates` for the whole verdict
/// ladder, `::capture_region` for the crop, `::frame_gate` for the static and stillness decisions,
/// and `::scroll_reproject` for the shift hint. The ask is checked over the daemon DIRECTORY
/// because which module holds which is the daemon's business.
///
/// The four bans are the same four, respelled in Rust and scoped to the daemon alone — a ban over
/// `rust/` would fire on `rust/slopdesk-video`, which is the home these point at.
///
/// The door this rule used to name is gone. `slopdesk_capture_*` was the C entry point the Swift
/// face called; the daemon links `slopdesk-apple-sck` as an ordinary Rust dependency, so the
/// message no longer claims a door that nothing declares (`docs/61` §3).
#[must_use]
pub fn capture_is_rusts(tree: &Tree) -> Report {
    // The STREAM, not the framework — see the note above. The lifecycle METHOD names are
    // deliberately absent: `startCapture` and `stopCapture` are also the names of two effect cases
    // in `VideoSessionLogic`'s state machine, which is Swift's and staying, so banning the words
    // would fire on the tree this rule ships with.
    const STREAM: &str = concat!(
        r"SCStream\(",
        "|SCStreamConfiguration",
        "|SCContentFilter",
        "|SCStreamOutput",
        "|SCStreamDelegate",
        "|SCStreamFrameInfo",
        "|SCFrameStatus",
        "|addStreamOutput"
    );
    let claims = [
        Claim::NoneUnder {
            roots: &["Sources", "Tests"],
            extensions: SWIFT,
            pattern: STREAM,
            all: &[],
            unless: &[],
            view: View::Code,
            // ONE file names the stream vocabulary without being a capture stream. `framewatch` is
            // the glass-to-glass measurement harness: it runs two streams at once and compares
            // their delivery, so porting it would mean measuring the port with the port. The
            // preview glue that used to sit beside it was deleted with its target (docs/61).
            exempt: &["Sources/slopdesk-framewatch/main.swift"],
            message: "a Swift capture stream is back in {files} — slopdesk-apple-sck holds the filter, the \
                      configuration and the whole lifecycle, slopdesk_video::capture_config resolves every \
                      clamp, and rust/slopdesk-videohostd links both as ordinary Rust. Enumerating through \
                      SCShareableContent is still Swift's; capturing is not, and no Swift target captures \
                      any more (docs/57 §5, docs/61 §3)",
        },
        Claim::MentionsUnder {
            root: DAEMON,
            names: &[
                "slopdesk_video::capture_config",
                "slopdesk_video::capture_gates",
                "slopdesk_video::capture_region",
                "slopdesk_video::frame_gate",
                "slopdesk_video::scroll_reproject",
            ],
            message: "the daemon stopped asking {entry} — rust/slopdesk-videohostd owns the SCStream, the \
                      order the verdicts are asked in and the pixel arithmetic, and nothing else; a \
                      pipeline that stopped consulting one of these decides something the rules crate is \
                      already golden-pinned for (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"fn resolve_capture_hz|fn resolve_quiet_window|fn resolve_idr_poll_tick|\bcapture_queue_depth\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon resolves a capture clamp again in {files} — the delivery ceiling is TWICE \
                      the encode rate and the surface queue is five because both were measured, and the \
                      measurements live next to the numbers in rust/slopdesk-video::capture_config (docs/57 \
                      §5, docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"fn resolve_capture_mode|fn can_resize_in_place|enum CaptureMode",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon picks the content filter again in {files} — which filter a parked window \
                      wants, and whether a resize may happen in place, are \
                      rust/slopdesk-video::capture_config's and are exercised where no window server exists \
                      (docs/57 §5, docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            // `DisplayAnchor` is spelled with its `struct` keyword because ASKING whether a crop is
            // display-anchored is the daemon's — it has to know which filter to build — while
            // HOLDING the crop is not.
            pattern: r"\bsource_rect\b|\binclude_child_windows\b|struct DisplayAnchor",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon spells the crop again in {files} — the pin that keeps a child window from \
                      softening the whole pane, and the display-local origin a moved window re-anchors to, \
                      are rust/slopdesk-video::capture_config's and ::capture_region's (docs/57 §5, docs/61 \
                      §3)",
        },
    ];
    check_all(tree, &claims)
}

/// The two agent vocabularies, compared by CASE COUNT across the boundary.
///
/// The Swift enums declare the cases and the crate answers every question about them by
/// DISCRIMINANT, so a reordered Swift enum would quietly report `working` for `blocked`. What
/// crosses the ABI is an index, and an index is only meaningful against a length both sides agree
/// on — which is exactly what `pub const ALL: [Self; N]` states on the Rust side.
///
/// Counted rather than name-compared on purpose: the two languages spell several of these
/// differently and always have, so a name pin would report a naming choice as a drift and get
/// itself deleted. The count is the part that is load-bearing.
#[must_use]
pub fn agent_vocabularies(tree: &Tree) -> Report {
    const PAIRS: &[Vocabulary] = &[
        Vocabulary {
            label: "AgentKind",
            swift: "Sources/SlopDeskAgentDetect/AgentKind.swift",
            swift_enum: r"^public enum AgentKind",
            rust: "rust/slopdesk-agent/src/kind.rs",
        },
        Vocabulary {
            label: "ClaudeStatus",
            swift: "Sources/SlopDeskAgentDetect/ClaudeStatus.swift",
            swift_enum: r"^public enum ClaudeStatus",
            rust: "rust/slopdesk-agent/src/status.rs",
        },
    ];

    let mut report = Report::new();
    for pair in PAIRS {
        let (Some(swift), Some(rust)) = (
            report.source(tree, pair.swift, "one side of the vocabulary lives there"),
            report.source(tree, pair.rust, "one side of the vocabulary lives there"),
        ) else {
            continue;
        };
        let cases = crate::text::count_lines(
            &crate::text::range(swift.code(), pair.swift_enum, r"^\}"),
            r"^    case ",
        );
        let declared = crate::text::capture_first(rust.code(), r"pub const ALL: \[Self; ([0-9]+)\]");
        // A zero on the Swift side is the vacuous case: the enum was renamed and the range read
        // nothing, which would otherwise compare against a Rust length nobody changed.
        report.fail_if(
            cases == 0,
            format!(
                "{} declares no cases in {} — the extraction in this gate has gone stale",
                pair.label, pair.swift,
            ),
        );
        report.same(
            &format!("{} case count", pair.label),
            (cases > 0).then(|| cases.to_string()).as_deref(),
            declared.as_deref(),
        );
    }
    report
}

/// One vocabulary whose two ends are compared by length rather than by name.
struct Vocabulary {
    label: &'static str,
    swift: &'static str,
    swift_enum: &'static str,
    rust: &'static str,
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// A pin can only guard a symbol compiled beside it, so the ban is about LOCATION.
    #[test]
    fn a_fork_outside_its_crate_is_caught_and_inside_it_is_not() {
        let fixture = Fixture::new("stray-fork");
        fixture
            .write("rust/slopdesk-posix/src/window.rs", "let pid = libc::fork();\n")
            .write("rust/slopdesk-ffi/src/lib.rs", "extern \"C\" fn door() {}\n");
        assert!(super::one_home_per_operation(&fixture.tree()).is_clean());

        fixture.write("rust/slopdesk-superd/src/pty.rs", "let pid = libc::fork();\n");
        let report = super::one_home_per_operation(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("rust/slopdesk-superd/src/pty.rs")),
            "{report:?}"
        );
    }

    /// The excuse is the BARE form, and only it: a private handler the kernel calls back is not a
    /// door, but the same line wearing `pub` is.
    #[test]
    fn a_private_signal_handler_is_excused_and_an_exported_one_is_not() {
        let fixture = Fixture::new("signal-handler");
        fixture.write(
            "rust/slopdesk-posix/src/rawmode.rs",
            "extern \"C\" fn restore_and_reraise(signal: libc::c_int) {}\n",
        );
        assert!(super::one_home_per_operation(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-posix/src/rawmode.rs",
            "pub extern \"C\" fn restore_and_reraise(signal: libc::c_int) {}\n",
        );
        let report = super::one_home_per_operation(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("rust/slopdesk-posix/src/rawmode.rs")),
            "{report:?}"
        );
    }

    /// The whole reason this rule is Rust and not shell: every file that EXPLAINS the port names
    /// the call it removed, so a raw grep fires on its own documentation. Prose may name what code
    /// may not, and `View::Code` is the difference.
    #[test]
    fn a_comment_naming_the_call_is_not_the_call() {
        let fixture = Fixture::new("probe-prose");
        fixture.write(
            "Sources/SlopDeskHost/Probe.swift",
            "/// Was `tcgetpgrp(masterFD)` here; the door answers it now.\n// NOT \
             `NSWorkspace.shared.frontmostApplication`, which freezes in a daemon.\nlet group = \
             slopdesk_pty_foreground_group(fd)\n",
        );
        assert!(super::one_probe_per_reading(&fixture.tree()).is_clean());
    }

    /// The pane census is the reading this rule used to exempt, so it is the one most likely to be
    /// rewritten in Swift by someone who does not know it moved. Each call is checked separately —
    /// a single alternation that matched only its first branch would pass this test while banning
    /// nothing.
    #[test]
    fn every_call_the_pane_census_used_to_make_is_caught_on_its_own() {
        for call in [
            "let n = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)\n",
            "proc_pidpath(pid, &buffer, UInt32(buffer.count))\n",
            "proc_pidinfo(pid, Int32(PROC_PIDVNODEPATHINFO), 0, $0, size)\n",
            "_ = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))\n",
            "guard let slave = ptsname(masterFD) else { return nil }\n",
        ] {
            let fixture = Fixture::new("census-revived");
            fixture.write("Sources/SlopDeskHost/Probe.swift", call);
            let report = super::one_probe_per_reading(&fixture.tree());
            assert!(
                report.violations().iter().any(|v| v.contains("foreground PROBE")),
                "{call:?} was not caught: {report:?}"
            );
        }
    }

    /// The daemon's asks, seeded so the two `MentionsUnder` claims can pass.
    ///
    /// A helper rather than a literal per test because [`Claim::MentionsUnder`] refuses to pass on
    /// an EMPTY directory, so every fixture that exercises either video rule has to put the daemon
    /// on disk first — a test that forgot would go red for the wrong reason and get "fixed" by
    /// weakening the rule.
    fn daemon(fixture: &Fixture) {
        fixture
            .write(
                "rust/slopdesk-videohostd/src/encode.rs",
                "use slopdesk_video::encoder_config::Config;\nuse \
                 slopdesk_video::encoder_state::EncoderState;\n",
            )
            .write(
                "rust/slopdesk-videohostd/src/capture.rs",
                "use slopdesk_video::capture_config::Clamps;\nuse \
                 slopdesk_video::capture_gates::CaptureGates;\nuse \
                 slopdesk_video::frame_gate::FrameObligations;\nuse \
                 slopdesk_video::scroll_reproject::ScrollHint;\n",
            )
            .write(
                "rust/slopdesk-videohostd/src/windowgeometry.rs",
                "use slopdesk_video::capture_region::WindowSnapshot;\n",
            );
    }

    /// Each compression call and each key family is caught on its own — an alternation that matched
    /// only its first branch would pass a single-case test while banning nothing.
    ///
    /// The seed is a LIVE Swift target. The `SlopDeskVideoHost` target is deleted, so writing there
    /// would seed a directory that a second rule already bans outright — this rule's job is the one
    /// that ban cannot do, which is catching a compression session in a target nobody thinks of as
    /// the video host.
    #[test]
    fn every_compression_call_the_encoder_used_to_make_is_caught_on_its_own() {
        for call in [
            "let status = VTCompressionSessionCreate(allocator: nil, width: w, height: h)\n",
            "VTCompressionSessionEncodeFrame(session, pixelBuffer, pts, .invalid, opts, nil, nil)\n",
            "VTCompressionSessionCompleteFrames(session, until: .invalid)\n",
            "VTCompressionSessionPrepareToEncodeFrames(session)\n",
            "VTCompressionSessionInvalidate(session)\n",
            "let cb: VTCompressionOutputCallback = { _, _, _, _, _ in }\n",
            "set(kVTCompressionPropertyKey_MaxAllowedFrameQP, 51)\n",
            "opts[kVTEncodeFrameOptionKey_ForceKeyFrame] = kCFBooleanTrue\n",
            "spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true\n",
            "set(key, kVTQPModulationLevel_Disable)\n",
        ] {
            let fixture = Fixture::new("encoder-revived");
            daemon(&fixture);
            fixture.write("Sources/SlopDeskVideoClientMac/MacFrameRelay.swift", call);
            let report = super::hevc_encode_is_rusts(&fixture.tree());
            assert!(
                report
                    .violations()
                    .iter()
                    .any(|v| v.contains("compression session")),
                "{call:?} was not caught: {report:?}"
            );
        }
    }

    /// Each decompression call and each key family is caught on its own, for the reason the
    /// compression pair above is: an alternation that matched only its first branch would pass a
    /// single-case test while banning nothing.
    #[test]
    fn every_decompression_call_the_decoder_used_to_make_is_caught_on_its_own() {
        for call in [
            "VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt)\n",
            "VTDecompressionSessionDecodeFrame(session, sample, flags, nil, nil)\n",
            "VTDecompressionSessionInvalidate(session)\n",
            "VTDecompressionSessionWaitForAsynchronousFrames(session)\n",
            "let cb: VTDecompressionOutputCallback = { _, _, _, _, _, _, _ in }\n",
            "set(kVTDecompressionPropertyKey_RealTime, true)\n",
            "spec[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] = true\n",
        ] {
            let fixture = Fixture::new("decoder-revived");
            fixture.write("Sources/SlopDeskVideoClient/VideoDecoder.swift", call);
            let report = super::hevc_decode_is_rusts(&fixture.tree());
            assert!(
                report
                    .violations()
                    .iter()
                    .any(|v| v.contains("decompression session")),
                "{call:?} was not caught: {report:?}"
            );
        }
    }

    /// The DEVICE PANELS are not swept in. They feed an `AVSampleBufferDisplayLayer`, which has no
    /// decompression session in it at all, and they build a format description and stamp an
    /// attachment to do it. A ban wide enough to catch those would fire on the tree it ships with.
    #[test]
    fn the_display_layer_panels_keep_their_core_media_calls() {
        let fixture = Fixture::new("panels-untouched");
        fixture
            .write(
                "Sources/SlopDeskDevicePanels/Android/AndroidVideoFormat.swift",
                "CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, nalUnitHeaderLength: \
                 4)\n",
            )
            .write(
                "Sources/SlopDeskDevicePanels/Shared/DevicePanelSampleBuffer.swift",
                "Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque()\n",
            )
            .write(
                "Sources/SlopDeskVideoClient/VideoDecoder.swift",
                "import CSlopDeskFFI\n",
            );
        assert!(super::hevc_decode_is_rusts(&fixture.tree()).is_clean());
    }

    /// The decoder's face, by CONTENT. Both revivals name a bug rather than a preference: the
    /// parameter-set cache is what a hard failure must clear, and the EWMA's first sample must seed
    /// the average whole.
    #[test]
    fn the_decoder_face_must_call_the_door_and_must_not_hold_the_rules() {
        let fixture = Fixture::new("decoder-face");
        fixture.write(
            "Sources/SlopDeskVideoClient/VideoDecoder.swift",
            "import CSlopDeskFFI\nslopdesk_video_decoder_decode(handle, base, len, kf, &status)\n",
        );
        assert!(super::hevc_decode_is_rusts(&fixture.tree()).is_clean());

        for (revived, needle) in [
            (
                "private var currentParameterSets: Sets?\n",
                "worth rebuilding for",
            ),
            (
                "static func needsReconfigure(current: Sets?) -> Bool { true }\n",
                "worth rebuilding for",
            ),
            ("static let decodeEWMAAlpha = 0.25\n", "decode-wall average"),
            ("private var decodeMsEWMA: Double = 0\n", "decode-wall average"),
        ] {
            let fixture = Fixture::new("decoder-face-revived");
            fixture.write(
                "Sources/SlopDeskVideoClient/VideoDecoder.swift",
                &format!("import CSlopDeskFFI\n{revived}"),
            );
            let report = super::hevc_decode_is_rusts(&fixture.tree());
            assert!(
                report.violations().iter().any(|v| v.contains(needle)),
                "{revived:?} was not caught: {report:?}"
            );
        }
    }

    /// The parameter-set scan must stay deleted. The host's packetizer already reads VPS/SPS/PPS
    /// from `slopdesk_video::hevc_parameter_sets`, so a Swift one back in the client would be the
    /// cross-language mirror `CLAUDE.md` forbids — two readings of the same bytes, one per side.
    #[test]
    fn the_swift_parameter_set_scan_stays_deleted() {
        let fixture = Fixture::new("sets-revived");
        fixture
            .write(
                "Sources/SlopDeskVideoClient/HEVCParameterSets.swift",
                "enum HEVCParameterSets { static let vpsType: UInt8 = 32 }\n",
            )
            .write(
                "Sources/SlopDeskVideoClient/VideoDecoder.swift",
                "import CSlopDeskFFI\n",
            );
        let report = super::hevc_decode_is_rusts(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("HEVCParameterSets.swift is back")),
            "{report:?}"
        );
    }

    /// The DRIVER is checked by CONTENT, so the four things the rules crate owns are named. The
    /// integrator is the sharpest: the Swift original folded it only inside the default regime's
    /// else arm, which is the bug the port found — and a re-transcription into Rust would carry the
    /// bug across with it, because the else arm is where the line reads naturally.
    ///
    /// Every revival is a Rust file under the DAEMON, which is the only place the ban runs.
    /// `rust/slopdesk-video` spells all four of these legitimately — `encoder_state` IS the bracket
    /// — so a ban that reached it would fire on the home it points at.
    #[test]
    fn the_driver_must_ask_the_rules_crate_and_must_not_hold_the_state_machine() {
        let fixture = Fixture::new("encoder-driver");
        daemon(&fixture);
        assert!(super::hevc_encode_is_rusts(&fixture.tree()).is_clean());

        for (revived, needle) in [
            ("    let mut bracket_depth = 0usize;\n", "quantiser bracket"),
            ("    fn begin_crisp_bracket(&mut self) {}\n", "quantiser bracket"),
            ("    let mut drop_relief = 0u32;\n", "drop-relief integrator"),
            (
                "    let consecutive_drops = self.dropped;\n",
                "drop-relief integrator",
            ),
            (
                "    let bpp = f64::from(target_bps) / pixel_rate;\n",
                "quantiser ramp",
            ),
            ("    let span = f64::from(sharp - coarse);\n", "quantiser ramp"),
            ("    const ATTACK_STEP: u32 = 4;\n", "tuned ceiling constant"),
            (
                "    const QP_CEILING_SHARP_BPP: f64 = 0.14;\n",
                "tuned ceiling constant",
            ),
        ] {
            let fixture = Fixture::new("encoder-driver-revived");
            daemon(&fixture);
            fixture.append("rust/slopdesk-videohostd/src/encode.rs", revived);
            let report = super::hevc_encode_is_rusts(&fixture.tree());
            assert!(
                report.violations().iter().any(|v| v.contains(needle)),
                "{revived:?} was not caught: {report:?}"
            );
        }
    }

    /// A daemon that stopped asking the rules crate is the port undone, and it is drift no ban can
    /// see: deleting the `use` line and inlining the clamp leaves every suite green, because the
    /// numbers agree until the day somebody edits one of the two copies.
    #[test]
    fn a_driver_that_stopped_asking_the_rules_crate_is_red() {
        for (name, ask) in [
            ("config", "slopdesk_video::encoder_config"),
            ("state", "slopdesk_video::encoder_state"),
            ("clamps", "slopdesk_video::capture_config"),
            ("gates", "slopdesk_video::capture_gates"),
            ("region", "slopdesk_video::capture_region"),
            ("frame", "slopdesk_video::frame_gate"),
            ("scroll", "slopdesk_video::scroll_reproject"),
        ] {
            let fixture = Fixture::new(&format!("daemon-stopped-asking-{name}"));
            daemon(&fixture);
            for path in [
                "rust/slopdesk-videohostd/src/encode.rs",
                "rust/slopdesk-videohostd/src/capture.rs",
                "rust/slopdesk-videohostd/src/windowgeometry.rs",
            ] {
                let text = fixture.tree().read(path).unwrap_or_default();
                let kept = text
                    .lines()
                    .filter(|line| !line.contains(ask))
                    .collect::<Vec<_>>()
                    .join("\n");
                fixture.write(path, &format!("{kept}\n"));
            }
            let encode = super::hevc_encode_is_rusts(&fixture.tree());
            let capture = super::capture_is_rusts(&fixture.tree());
            assert!(
                encode.violations().iter().any(|v| v.contains(ask))
                    || capture.violations().iter().any(|v| v.contains(ask)),
                "{ask} could be dropped with nothing red: {encode:?} {capture:?}"
            );
        }
    }

    /// A drained daemon cannot satisfy the ask. Every `MentionsUnder` in this file would otherwise
    /// pass VACUOUSLY the moment `rust/slopdesk-videohostd` were emptied — the one failure mode a
    /// "the daemon still asks X" claim has, and the reason the claim refuses an empty root.
    #[test]
    fn a_drained_daemon_cannot_satisfy_the_ask() {
        // Named for this FILE, not for the condition. `Fixture::new` keys its temp directory on the
        // name and `remove_dir_all`s it, the suite runs concurrently, and `video_host.rs` has a
        // test asking the same question of its own rules — two fixtures sharing a name wipe each
        // other mid-run, which reads as a flake in whichever lost the race.
        let fixture = Fixture::new("boundaries-daemon-drained");
        fixture.write("Sources/SlopDeskVideoClient/A.swift", "let ordinary = 1\n");
        assert!(!super::hevc_encode_is_rusts(&fixture.tree()).is_clean());
        assert!(!super::capture_is_rusts(&fixture.tree()).is_clean());
    }

    /// The capture pipeline's four bans, each seeded as Rust under the daemon. The clamps are the
    /// point: each was untestable where it sat, because nothing in the Swift could be instantiated
    /// without a window server and a Screen-Recording grant.
    #[test]
    fn the_pipeline_must_not_hold_the_capture_clamps() {
        let fixture = Fixture::new("capture-pipeline");
        daemon(&fixture);
        assert!(super::capture_is_rusts(&fixture.tree()).is_clean());

        for (revived, needle) in [
            (
                "    fn resolve_capture_hz(&self) -> u32 { 60 }\n",
                "capture clamp",
            ),
            (
                "    fn resolve_quiet_window(&self) -> u32 { 8 }\n",
                "capture clamp",
            ),
            ("    let capture_queue_depth = 5usize;\n", "capture clamp"),
            (
                "    fn resolve_capture_mode(&self) -> Mode { Mode::Window }\n",
                "content filter",
            ),
            (
                "    fn can_resize_in_place(&self) -> bool { true }\n",
                "content filter",
            ),
            ("enum CaptureMode { Window, Display }\n", "content filter"),
            ("    let source_rect = crop.to_cg();\n", "spells the crop"),
            ("    let include_child_windows = false;\n", "spells the crop"),
            ("struct DisplayAnchor { origin: (f64, f64) }\n", "spells the crop"),
        ] {
            let fixture = Fixture::new("capture-pipeline-revived");
            daemon(&fixture);
            fixture.append("rust/slopdesk-videohostd/src/capture.rs", revived);
            let report = super::capture_is_rusts(&fixture.tree());
            assert!(
                report.violations().iter().any(|v| v.contains(needle)),
                "{revived:?} was not caught: {report:?}"
            );
        }
    }

    /// The measurement harness keeps its two streams. Porting `framewatch` would mean measuring the
    /// port with the port, so its exemption is a decision on the record — and the same line proves
    /// the ban is not vacuous, because an ordinary target with the same call is red.
    #[test]
    fn the_glass_to_glass_harness_keeps_its_streams() {
        let fixture = Fixture::new("capture-framewatch");
        daemon(&fixture);
        fixture.write(
            "Sources/slopdesk-framewatch/main.swift",
            "final class Collector: NSObject, SCStreamOutput {}\nlet cfg = SCStreamConfiguration()\n",
        );
        assert!(super::capture_is_rusts(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskVideoClientMac/MacPreview.swift",
            "let cfg = SCStreamConfiguration()\n",
        );
        let report = super::capture_is_rusts(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("MacPreview")),
            "{report:?}"
        );
    }

    /// Both halves of the cursor read are caught on their own, and both spellings of the private
    /// seed — the symbol was re-exported under a second name, so a ban on one of them bans nothing.
    #[test]
    fn every_read_of_the_displayed_cursor_is_caught_on_its_own() {
        for read in [
            "let cursor = NSCursor.currentSystem ?? NSCursor.current\n",
            "if let sym = dlsym(rtldDefault, \"CGSCurrentCursorSeed\") { return sym }\n",
            "if let sym = dlsym(rtldDefault, \"SLSCurrentCursorSeed\") { return sym }\n",
        ] {
            let fixture = Fixture::new("cursor-revived");
            fixture.write("Sources/SlopDeskWorkspaceCore/Video/CursorRelay.swift", read);
            let report = super::one_probe_per_reading(&fixture.tree());
            assert!(
                report.violations().iter().any(|v| v.contains("DISPLAYED cursor")),
                "{read:?} was not caught: {report:?}"
            );
        }
    }

    /// Setting this app's OWN pointer is UI, and the pane divider does it on every drag. A ban on
    /// the bare type name would delete a live `SwiftUI` affordance to protect a read that is not
    /// there — so the pattern names the two READS and nothing else.
    #[test]
    fn setting_this_apps_own_pointer_is_not_reading_the_systems() {
        let fixture = Fixture::new("cursor-ui");
        fixture.write(
            "Sources/SlopDeskMacUI/Pane/MacPaneDivider.swift",
            "NSCursor.resizeLeftRight.push()\nNSCursor.pop()\nNSCursor.openHand.set()\n",
        );
        assert!(super::one_probe_per_reading(&fixture.tree()).is_clean());
    }

    /// Every effect the window placement path used to have on the tree is caught on its own, and so
    /// is the trust read and the private window-id symbol. The last one is the reason this ban is
    /// worth having at all: `_AXUIElementGetWindow` was declared with `@_silgen_name` in
    /// `InputInjector`, and a private symbol declared twice is how two callers end up disagreeing
    /// about which framework exports it — measured, it is `HIServices`' and not `CoreGraphics`'.
    #[test]
    fn every_effect_on_the_accessibility_tree_is_caught_on_its_own() {
        for effect in [
            "guard AXIsProcessTrusted() else { return .denied }\n",
            "AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)\n",
            "AXUIElementPerformAction(window, kAXRaiseAction as CFString)\n",
            "@_silgen_name(\"_AXUIElementGetWindow\") func getWindow(_ e: AXUIElement) -> AXError\n",
            "AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &raw)\n",
            "AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &raw)\n",
            "_ = AXUIElementCopyAttributeValue(el, kAXEnabledAttribute as CFString, &ref)\n",
            "let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement]\n",
            "guard let bar = attr(appEl, kAXMenuBarAttribute) else { return nil }\n",
            "if let cmd = attr(item, kAXMenuItemCmdCharAttribute) as? String { return cmd }\n",
        ] {
            let fixture = Fixture::new("ax-revived");
            fixture.write("Sources/SlopDeskWorkspaceCore/Video/WindowRelay.swift", effect);
            let report = super::one_probe_per_reading(&fixture.tree());
            assert!(
                report.violations().iter().any(|v| v.contains("Swift AX write")),
                "{effect:?} was not caught: {report:?}"
            );
        }
    }

    /// A SUBSCRIPTION with a run loop stays Swift (docs/57 §1), so the two calls that create and
    /// configure the element it attaches to are deliberately NOT banned. They read nothing.
    ///
    /// The observer this carve-out was written for went with `docs/61` — the window feed is
    /// `rust/slopdesk-videohostd`'s now. The carve-out stays anyway, and the difference matters: it
    /// is a decision on the record about WHAT MAY COME BACK, not a note about a file. `docs/57` §1
    /// draws the objc2 family's line at effects on the system, and an observer attached to a run
    /// loop is on the Swift side of it — so the day a client grows one, this test is what keeps
    /// somebody from widening the ban to two calls that read nothing.
    #[test]
    fn a_subscription_that_stays_swift_is_not_an_effect() {
        let fixture = Fixture::new("ax-observer");
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Video/WindowFeedObserver.swift",
            "let app = AXUIElementCreateApplication(pid)\nAXUIElementSetMessagingTimeout(app, \
             0.25)\nAXObserverAddNotification(observer, app, kAXWindowCreatedNotification as CFString, \
             nil)\n",
        );
        assert!(super::one_probe_per_reading(&fixture.tree()).is_clean());
    }

    /// `SlopDeskMetadataPort(proc_name:)` is the wire record's own FIELD LABEL, and naming a struct
    /// field is not making a syscall. The ban is on the call shape for exactly this reason — a
    /// bare-token ban would fire on the codec that decodes what the census produced.
    #[test]
    fn a_wire_field_named_after_a_syscall_is_not_that_syscall() {
        let fixture = Fixture::new("census-field");
        fixture.write(
            "Sources/SlopDeskProtocol/Metadata/MetadataCodec.swift",
            "SlopDeskMetadataPort(proc_name: intern($0.procName, &pool), port: $0.port)\n",
        );
        assert!(super::one_probe_per_reading(&fixture.tree()).is_clean());
    }

    /// The syscall itself, on a code line, is the second reading of a question with one home.
    #[test]
    fn the_syscall_on_a_code_line_is_caught() {
        let fixture = Fixture::new("probe-revived");
        fixture.write(
            "Sources/SlopDeskHost/Probe.swift",
            "let pgid = tcgetpgrp(masterFD)\n",
        );
        let report = super::one_probe_per_reading(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("foreground PROBE")),
            "{report:?}"
        );
    }

    /// The frontmost read has the same shape and the same trap — a pid lookup in code, whatever the
    /// comments above it say. `activate` and `bundleIdentifier` are the same lookup, so the ban is
    /// on the constructor rather than on what is asked of the result.
    #[test]
    fn the_pid_lookup_is_caught_wherever_it_reappears() {
        let fixture = Fixture::new("frontmost-revived");
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Video/FrontRelay.swift",
            "let app = NSRunningApplication(processIdentifier: pid)\n",
        );
        let report = super::one_probe_per_reading(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("frontmost/app read")),
            "{report:?}"
        );
    }

    /// Declaring a C signature so it can be CALLED is the opposite direction from exporting one,
    /// and only the export is what the ABI-is-a-crate rule is about. The excuse names the alias
    /// form alone, so an entry point in the very same file is still caught.
    #[test]
    fn a_signature_declared_to_be_called_is_not_an_entry_point() {
        let fixture = Fixture::new("call-signature");
        fixture.write(
            "rust/slopdesk-posix/src/dynsym.rs",
            "type Seed = unsafe extern \"C\" fn() -> i32;\n",
        );
        assert!(super::one_home_per_operation(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-posix/src/door.rs",
            "type Seed = unsafe extern \"C\" fn() -> i32;\npub extern \"C\" fn slopdesk_seed() -> i32 { 0 \
             }\n",
        );
        let report = super::one_home_per_operation(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("rust/slopdesk-posix/src/door.rs")),
            "{report:?}"
        );
    }

    /// The directory exemption has to cover a module split out of the crate, which is the widening
    /// a file list would suffer from the other side.
    #[test]
    fn the_exemption_covers_a_new_module_inside_the_crate() {
        let fixture = Fixture::new("exempt-dir");
        fixture
            .write("rust/slopdesk-posix/src/deep/nested.rs", "libc::openpty();\n")
            .write("rust/slopdesk-ffi/src/screen.rs", "extern \"C\" fn a() {}\n");
        assert!(super::one_home_per_operation(&fixture.tree()).is_clean());
    }

    /// A wrapper that stopped calling its door is an implementation that came back.
    #[test]
    fn a_replay_buffer_that_regrew_its_ring_is_caught() {
        let fixture = Fixture::new("replay-ring");
        fixture.write(
            "Sources/SlopDeskTransport/ReplayBuffer.swift",
            "import CSlopDeskFFI\nfinal class ReplayBuffer {}\n",
        );
        assert!(super::replay_buffer(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskTransport/ReplayBuffer.swift",
            "import CSlopDeskFFI\nprivate var scrollbackRing: [Entry] = []\n",
        );
        let report = super::replay_buffer(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("ring storage")),
            "{report:?}"
        );
    }

    /// What crosses the ABI is an INDEX, so a Swift case added without the Rust length is a
    /// `working` reported for a `blocked`.
    #[test]
    fn a_case_added_on_one_side_only_is_caught() {
        let fixture = vocabulary_fixture("agent-vocab", 3);
        assert!(super::agent_vocabularies(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskAgentDetect/AgentKind.swift",
            "public enum AgentKind {\n    case a\n    case b\n    case c\n    case d\n}\n",
        );
        let report = super::agent_vocabularies(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("AgentKind case count")),
            "{report:?}"
        );
    }

    /// The vacuous half: a renamed enum reads zero cases, which must not compare against a Rust
    /// length nobody touched.
    #[test]
    fn a_renamed_swift_enum_says_so_rather_than_comparing_nothing() {
        let fixture = vocabulary_fixture("agent-vocab-stale", 3);
        fixture.write(
            "Sources/SlopDeskAgentDetect/AgentKind.swift",
            "public enum AgentFlavour {\n    case a\n    case b\n    case c\n}\n",
        );
        let report = super::agent_vocabularies(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("gone stale")),
            "{report:?}"
        );
    }

    fn vocabulary_fixture(name: &str, cases: usize) -> Fixture {
        let fixture = Fixture::new(name);
        let body = (0..cases).fold(String::new(), |mut acc, index| {
            use std::fmt::Write as _;
            let _ = writeln!(acc, "    case c{index}");
            acc
        });
        for (swift, rust, enum_name) in [
            (
                "Sources/SlopDeskAgentDetect/AgentKind.swift",
                "rust/slopdesk-agent/src/kind.rs",
                "AgentKind",
            ),
            (
                "Sources/SlopDeskAgentDetect/ClaudeStatus.swift",
                "rust/slopdesk-agent/src/status.rs",
                "ClaudeStatus",
            ),
        ] {
            fixture
                .write(swift, &format!("public enum {enum_name} {{\n{body}}}\n"))
                .write(rust, &format!("pub const ALL: [Self; {cases}] = [Self::A];\n"));
        }
        fixture
    }
}
