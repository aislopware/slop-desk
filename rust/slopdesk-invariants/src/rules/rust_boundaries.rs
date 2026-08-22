//! The two operations that live in exactly one crate, and the three Swift modules that became
//! faces over Rust rather than second copies of it.
//!
//! Ported from `scripts/check-supervisor.sh`. What the first pair have in common is that the
//! guarantee is attached to the LOCATION rather than to the code: a disassembly pin can only guard
//! a symbol compiled beside it, and a C entry point next to the logic it marshals is a pointer bug
//! one edit away from being a terminal bug. The rest are `import CSlopDeskFFI` plus a ban list,
//! because unlike the ported daemons these files legitimately still exist — so "is it still a face"
//! is a question about CONTENT, and the answer is: it calls the door, and it does not hold the
//! table.

use crate::claim::{Claim, RUST, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

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
            unless: &[r"type \w+ = unsafe extern"],
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
/// Three files stay as faces and must each still call the crate. The ones that used to be on that
/// list are GONE rather than thin: once the fusion moved, nothing in `Sources/` had a reason to
/// name a machine, a signal, a process matcher or an input classifier — the detector's doors take
/// the raw input and answer the fold. A wrapper that only forwards is still a file another wrapper
/// can be written next to, so the check for those is that they stay deleted.
///
/// `AgentJobIdentifier.swift` left the list most recently, and by the same rule rather than by an
/// exception to it: it staged a foreground job across the FFI one field at a time because Swift
/// owned the syscalls that produced it. `rust/slopdesk-posix::proc` owns them now, so the whole
/// question is `slopdesk_pty_foreground_agent` and there is nothing left for a face to marshal.
///
/// The six banned strings are the tables and the walks a re-implementation would need and a wrapper
/// cannot have.
#[must_use]
pub fn agent_detection(tree: &Tree) -> Report {
    const FACES: &[&str] = &[
        "Sources/SlopDeskAgentDetect/AgentKind.swift",
        "Sources/SlopDeskAgentDetect/ClaudeStatus.swift",
        "Sources/SlopDeskAgentDetect/AgentDetectionHold.swift",
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
/// `AppIconGlue` and `slopdesk-navhistory-probe` are not exempt and do not need to be: they ask
/// `runningApplications(withBundleIdentifier:)` for an ICON, which is image work and stays Swift's.
/// The banned shape is the pid lookup, which is the one this port replaced.
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
/// `AppIconGlue` and `slopdesk-navhistory-probe` are still not exempt and still do not need to be,
/// for the reason above: an icon lookup is image work.
///
/// ## And the accessibility tree, PARTLY
/// The fourth claim is the only one here that bans less than the whole framework area, and the
/// asymmetry is the point. What moved to `rust/slopdesk-apple-ax` is every EFFECT on a window —
/// park, restore, resize, un-minimize, raise — plus the trust read and the private window-id
/// symbol; those are banned. What did not move is a SUBSCRIPTION with a run loop
/// (`WindowFeedAXObserver`, which docs/57 §1 keeps Swift) and `HostNavHistory`, which has not been
/// ported yet — both make the two generic reads, so `AXUIElementCopyAttributeValue` and
/// `…CreateApplication` are deliberately absent from the pattern. Banning them and exempting the
/// two files would put the remaining debt in an exemption list, which is the failure the census
/// section above describes.
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
    // NOT `AXUIElementCopyAttributeValue` or `…CreateApplication`, which two Swift files still make:
    // `WindowFeedAXObserver` holds a SUBSCRIPTION with a run loop (docs/57 §1 keeps those Swift) and
    // `HostNavHistory` has not moved yet. What is banned is what has exactly one home now — the WRITE
    // half and the action (`slopdesk_ax_park_window` / `_restore_window` / `_resize_window` /
    // `_deminiaturize` / `slopdesk_ax_raiser_raise`), the trust read, and the private window-id
    // symbol. The last is the sharpest of the three: it was a `@_silgen_name` declaration in
    // `InputInjector`, and a second declaration of a private symbol is how two callers end up
    // disagreeing about which framework exports it.
    const ACCESSIBILITY: &str = concat!(
        "AXIsProcessTrusted",
        "|AXUIElementSetAttributeValue",
        "|AXUIElementPerformAction",
        "|_AXUIElementGetWindow",
        "|kAXPositionAttribute",
        "|kAXSizeAttribute",
        "|kAXMinimizedAttribute",
        "|kAXRaiseAction"
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
            fixture.write("Sources/SlopDeskVideoHost/CursorSampler.swift", read);
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
        ] {
            let fixture = Fixture::new("ax-revived");
            fixture.write("Sources/SlopDeskVideoHost/WindowPlacement.swift", effect);
            let report = super::one_probe_per_reading(&fixture.tree());
            assert!(
                report.violations().iter().any(|v| v.contains("Swift AX write")),
                "{effect:?} was not caught: {report:?}"
            );
        }
    }

    /// A SUBSCRIPTION with a run loop stays Swift (docs/57 §1), and `HostNavHistory` has not moved
    /// yet — so the two generic AX calls both of them make are deliberately NOT banned. A ban on
    /// `AXUIElementCopyAttributeValue` as a token would report a live observer as debt.
    #[test]
    fn a_subscription_that_stays_swift_is_not_an_effect() {
        let fixture = Fixture::new("ax-observer");
        fixture.write(
            "Sources/SlopDeskVideoHost/WindowFeed/WindowFeedAXSupport.swift",
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
            "Sources/SlopDeskVideoHost/Front.swift",
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
