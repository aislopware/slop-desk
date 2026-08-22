//! screend's remaining three alphabets, the frame ceiling, the opaque budget, and the Swift that
//! must stay deleted.
//!
//! Ported from `scripts/check-supervisor.sh`. What all of it guards is the same asymmetry: screend
//! is a launch agent that outlives hostd's build, so every disagreement between the two ends is
//! silent by construction — an old daemon serving a new client reports nothing, answers plausibly,
//! and is wrong.

use crate::claim::{Claim, Extract, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

const SWIFT_SCREEN: &str = "Sources/SlopDeskScreen/ScreenProtocol.swift";
const RUST_SCREEN: &str = "rust/slopdesk-screenwire/src/lib.rs";
const RUST_SCREEN_SERVER: &str = "rust/slopdesk-screend/src/server.rs";

/// The hello banner, the build version that follows it, and the status alphabet.
///
/// The banner is the PROTOCOL identity; the RUNNING BUILD's version follows it as a third field
/// (`docs/49`). screend is a launch agent that outlives hostd's build, so an upgrade leaves the old
/// process serving — this field is the only thing that tells hostd so. Both halves are ratcheted
/// because a skew in either is silent: a Swift side reading a field Rust stopped appending answers
/// `nil`, which the audit reports as "unknown" forever, and a Rust side that appended it somewhere
/// else would be read as a version that never matches.
///
/// The STATUS byte is the last of screend's three alphabets and the one nothing watched.
/// `ScreenStatus` and `screenwire::Status` are the same values in the same order, and the enum pass
/// in `check-shared-constants.py` deliberately does not pair them: the third case is spelled
/// `internalError` on one side and `Internal` on the other, so a name-for-name comparison would
/// report a naming choice as a drift and get itself deleted. The NUMBERS are the contract, so the
/// numbers are what is compared — in declaration order, with the count riding along. An inserted
/// case shifts the sequence and a renumbered one changes it. A status byte read as the wrong status
/// is a refusal reported as a success, or the reverse.
#[must_use]
pub fn hello_and_status(tree: &Tree) -> Report {
    let mut report = check_all(tree, &[
        Claim::Names {
            path: RUST_SCREEN,
            needle: "pub fn hello_payload",
            message: "rust/slopdesk-screenwire/src/lib.rs no longer builds the hello payload — hostd cannot \
                      learn screend's build version (docs/49)",
        },
        Claim::Names {
            path: RUST_SCREEN_SERVER,
            needle: r#"hello_payload(env!("CARGO_PKG_VERSION"))"#,
            message: "screend's hello no longer answers with its OWN compile-time version — see \
                      rust/slopdesk-screend/src/server.rs",
        },
        Claim::Names {
            path: SWIFT_SCREEN,
            needle: "func buildVersion(fromHello",
            message: "Sources/SlopDeskScreen/ScreenProtocol.swift no longer parses screend's build version \
                      out of hello (docs/49)",
        },
        Claim::SameValue {
            label: "the screend status alphabet",
            swift: Extract::code(SWIFT_SCREEN, r"^ *case [A-Za-z]+ = ([0-9]+)$")
                .within(r"^public enum ScreenStatus", r"^\}"),
            rust: Extract::code(RUST_SCREEN, r"^ *[A-Z][A-Za-z]* = ([0-9]+),$")
                .within(r"^pub enum Status", r"^\}"),
        },
    ]);

    // The banner is a VALUE on one side and a byte-string literal on the other, so the comparison is
    // "does Rust answer with exactly what Swift says" rather than two extractions meeting in the
    // middle. Read from Swift first, because Swift is the side that documents it.
    let (Some(swift), Some(rust)) = (
        report.source(tree, SWIFT_SCREEN, "screend's banner is declared there"),
        report.source(tree, RUST_SCREEN, "screend's banner is answered there"),
    ) else {
        return report;
    };
    match crate::text::capture_first(swift.code(), r#"helloBanner = "(.*)"$"#) {
        None => {
            report.fail(format!(
                "{SWIFT_SCREEN} no longer declares helloBanner — this gate reads nothing and would pass",
            ));
        },
        Some(banner) => {
            report.fail_if(
                !rust
                    .text
                    .contains(&format!("HELLO_BANNER: &[u8] = b\"{banner}\"")),
                format!("screend hello banner '{banner}' is not what {RUST_SCREEN} answers"),
            );
        },
    }
    report
}

/// The RESET frame's flag bits, and the frame ceiling that is now asked for rather than spelled.
///
/// Each flag is one bit of a byte hostd sets and screend reads, so a bit claimed on one side and
/// not the other does not fail to parse: a rebuild-replay flag read as agent-changed rebuilds
/// nothing and reports an agent that did not change. DERIVED both ways, so a fifth flag added to
/// either side without the other fails here rather than at a running daemon.
///
/// The CEILING used to be a `same`-compare of two expressions, on the argument that screend is a
/// separately-shipped BINARY so no door reaches it. That was true of the DAEMON and never true of
/// hostd's end: the client half is linked Swift calling `rust/slopdesk-screenwire` through
/// `CSlopDeskFFI` already. So the ceiling became a door too, and what is ratcheted changed shape
/// with it — not "do the two numbers agree" but "is there still only one". The Rust side is pinned
/// by a cargo test in `rust/slopdesk-ffi/src/screen.rs`, which compares the door's ANSWER to
/// `MAX_FRAME` rather than a `sed` of its source line. What is left for a ratchet is the Swift
/// side: that it keeps asking, and that the literal has not come back.
///
/// Which way this would drift decides how it fails: a client ceiling above screend's makes screend
/// kill the connection mid-stream on a frame the client thought legal; below it makes the client
/// reject a frame screend was entitled to send. Neither reports a size.
///
/// The literal is matched as the MEGABYTE EXPRESSION rather than a digit run — `64 * 1024 * 1024`
/// is how a reader is meant to see it, and it is also the only shape anyone regrows; nobody types
/// `67108864`. Both halves read the file comment-stripped, because the doc comment on this very
/// constant discusses the ratchet that used to read it.
#[must_use]
pub fn reset_flags_and_ceiling(tree: &Tree) -> Report {
    let mut report = check_all(tree, &[
        Claim::Matches {
            path: SWIFT_SCREEN,
            pattern: r"slopdesk_screen_constant\(",
            view: View::Code,
            message: "Sources/SlopDeskScreen/ScreenProtocol.swift stopped asking the door for the frame \
                      ceiling — a second spelling of 64 MiB is how the two ends drift apart",
        },
        Claim::Lacks {
            path: SWIFT_SCREEN,
            pattern: r"= *[0-9]+ *\* *1024 *\* *1024",
            view: View::Code,
            message: "Sources/SlopDeskScreen/ScreenProtocol.swift spells the screend frame ceiling as a \
                      literal again — it is slopdesk_screen_constant(0), and screend's copy is pinned by a \
                      cargo test",
        },
    ]);

    // The two sides spell a flag's NAME differently on purpose — `flagAgentChanged` against
    // `FLAG_AGENT_CHANGED` — so both are lower-cased with the separators dropped before comparison,
    // and what is left is the pair (name, bit).
    let (Some(swift), Some(rust)) = (
        report.source(tree, SWIFT_SCREEN, "screend's reset flags are declared there"),
        report.source(tree, RUST_SCREEN, "screend's reset flags are declared there"),
    ) else {
        return report;
    };
    let normalise = |pairs: Vec<(String, String)>| -> std::collections::BTreeSet<String> {
        pairs
            .into_iter()
            .map(|(name, bit)| {
                let name: String = name
                    .chars()
                    .filter(|c| *c != '_')
                    .flat_map(char::to_lowercase)
                    .collect();
                format!("{name} {}", bit.to_lowercase())
            })
            .collect()
    };
    let swift_flags = normalise(crate::text::capture_pairs(
        swift.code(),
        r"^ *public static let flag([A-Za-z]*): UInt8 = (0x[0-9a-fA-F]*)$",
    ));
    let rust_flags = normalise(crate::text::capture_pairs(
        rust.code(),
        r"^pub const FLAG_([A-Z_]*): u8 = (0x[0-9a-fA-F]*);$",
    ));
    report.fail_if(
        swift_flags.is_empty(),
        format!("{SWIFT_SCREEN} names no reset flags — this gate reads nothing and would pass"),
    );
    report.same_set("screend reset flags", &swift_flags, &rust_flags);
    report
}

/// The 15 MiB opaque budget, which is one cap spelled THREE times.
///
/// A metadata `read` verb answers a file, and the ceiling on how much of one it will carry back is
/// written in three places: `MetadataResponseBuilder.defaultMaxOpaquePayloadBytes` (what hostd will
/// put in a reply), `HostMetadataProbe.maxCaptureBytes` (what hostd will accumulate from the child)
/// and `slopdesk_probe::run::MAX_OPAQUE_READ_BYTES` (what the child will read before truncating).
///
/// `slopdesk-probe` is a `[[bin]]` hostd SPAWNS — it links nothing of hostd's and hostd links
/// nothing of its — so the third spelling cannot become a door however the first two are settled,
/// and the ratchet is the answer the lifetime picks rather than a compromise. The two Swift halves
/// are a genuine second finding, reported rather than folded: they live in one target and could be
/// one constant, which is a `Sources/` change and not this gate's to make.
///
/// A skew here is silent in the worst direction. The probe truncates at ITS ceiling and marks the
/// payload truncated; hostd's builder refuses at ITS ceiling by dropping the payload. Raise only
/// the probe's and hostd silently drops replies the probe worked to produce; raise only hostd's and
/// the extra capacity is unreachable, because the bytes were already thrown away one process
/// upstream.
#[must_use]
pub fn opaque_budget(tree: &Tree) -> Report {
    const RUST_PROBE_RUN: &str = "rust/slopdesk-probe/src/run.rs";
    const RUST_CAP: &str = r"^pub const MAX_OPAQUE_READ_BYTES: usize = (.*);$";

    let claims = [
        Claim::SameValue {
            label: "the opaque payload budget hostd will REPLY with",
            swift: Extract::code(
                "Sources/SlopDeskHost/MetadataResponseBuilder.swift",
                r"^ *static let defaultMaxOpaquePayloadBytes = (.*)$",
            ),
            rust: Extract::code(RUST_PROBE_RUN, RUST_CAP),
        },
        Claim::SameValue {
            label: "the opaque payload budget hostd will CAPTURE",
            swift: Extract::code(
                "Sources/SlopDeskHost/HostMetadataProbe.swift",
                r"^ *private static let maxCaptureBytes = (.*)$",
            ),
            rust: Extract::code(RUST_PROBE_RUN, RUST_CAP),
        },
    ];
    check_all(tree, &claims)
}

/// The Swift screen engine, the replay passes, the chunk boundary and the disk journal — all
/// deleted, all forbidden to return.
///
/// The parser, the renderer and the overprint collapser were DELETED when they moved to Rust, and a
/// re-added Swift copy is the cross-language mirror the tree forbids — which is exactly the shape a
/// "just a small fallback" commit takes (`CLAUDE.md`, `docs/52` §4).
///
/// The six byte machines of the scrollback replay transform are the likeliest of all the moved code
/// to grow a "tiny local fallback": each is small, pure and framework-free, and an absent screend
/// now means a RAW replay rather than a partly-cleaned one, which is the documented passthrough
/// policy and not an invitation. `ScrollbackReplayTransform` itself is NOT named — it stayed, as
/// the caller that picks the options — and the ban is scoped to DECLARATIONS so prose explaining
/// where the passes went does not fail its own gate.
///
/// The CHUNK BOUNDARY was the last byte machine hostd kept, on the theory that the ring boundary is
/// the host's bookkeeping. It is not: every rule is read out of the bytes (stage 26). Keeping it
/// also made "the reassert lands BEFORE the dangling half" a convention two call sites had to
/// remember instead of an invariant of screend's reply, and `compose` vs `transcript` disagree
/// about whether the dangling half survives at all.
///
/// The disk JOURNAL went for the ownership reason: superd owns the PTY read, so it numbers the
/// pane's stream, and a second process journaling a stream it does not number is what produced the
/// `.resume` sidecar, its pane-life stamp and the rate-limited re-claim. What hostd kept is
/// `ScrollbackTranscripts` — directory, cap, which end of life deletes, what the bytes mean — and
/// it holds no file descriptor. Two shapes are gated: the deleted types, and any Swift that opens a
/// `.scrollback`/`.resume` path for WRITING. The read side is deliberately not gated: hostd opens
/// the path `journal_info` hands back, which is the whole point of returning a path.
#[must_use]
pub fn deleted_screen_swift(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: "enum TerminalScreenModel|struct TerminalScreenModel|enum LineOverprintCollapser|enum \
                      TerminalSnapshotRenderer",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift screen engine is back in {files} — screend owns the parse and the render \
                      (docs/52)",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"(enum|struct|final class|class|actor) (TerminalInputModeStripper|InputModeFinalState|AltScreenSegmentStripper|SyncUpdateFrameCollapser|ScrollbackDistiller|TerminalQueryStripper|PromptEOLMarkStripper)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift replay pass is back in {files} — screend's sanitize verb owns the chain \
                      (docs/52)",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"func (splitTrailingIncompleteEscape|splitTrailingIncompleteUTF8)\b|trailingEscapeScanBytes *[:=]",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift chunk-boundary splitter is back in {files} — screend splits its own input \
                      (docs/52 §4)",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"(enum|struct|final class|class|actor) (ScrollbackJournal|ScrollbackJournalStore)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift scrollback journal is back in {files} — superd writes the transcript (docs/51 \
                      §6.8)",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r#"(createFile|forWritingTo|\.write\(to:).*\.(scrollback|resume)("|\)|$)"#,
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "Swift is writing a journal file ({files}) — superd owns every write under the \
                      scrollback dir (docs/51 §6.8)",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// A bit claimed on one side and not the other does not fail to parse — a rebuild-replay flag
    /// read as agent-changed rebuilds nothing and reports an agent that did not change.
    #[test]
    fn a_reset_flag_added_on_one_side_only_is_caught() {
        let fixture = flag_fixture("screend-flags");
        assert!(super::reset_flags_and_ceiling(&fixture.tree()).is_clean());

        fixture.write(
            super::RUST_SCREEN,
            &format!("{RUST_FLAGS}pub const FLAG_FIFTH: u8 = 0x08;\n"),
        );
        let report = super::reset_flags_and_ceiling(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("reset flags")),
            "{report:?}"
        );
    }

    /// The two sides spell the same flag differently on purpose, and that must not read as a drift.
    #[test]
    fn the_two_naming_conventions_cancel() {
        let fixture = flag_fixture("screend-naming");
        assert!(super::reset_flags_and_ceiling(&fixture.tree()).is_clean());
    }

    /// The ceiling used to be a literal, and the only shape anyone regrows is the megabyte
    /// expression — nobody types `67108864`.
    #[test]
    fn the_frame_ceiling_returning_as_a_literal_is_caught() {
        let fixture = flag_fixture("screend-ceiling");
        fixture.write(
            super::SWIFT_SCREEN,
            &format!("{SWIFT_FLAGS}static let maximumFrameBytes = 64 * 1024 * 1024\n"),
        );
        let report = super::reset_flags_and_ceiling(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("as a literal again")),
            "{report:?}"
        );
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("stopped asking the door")),
            "{report:?}"
        );
    }

    /// A skew in the opaque budget is silent in the worst direction: bytes thrown away one process
    /// upstream of the ceiling that was raised.
    #[test]
    fn a_budget_raised_in_one_process_only_is_caught() {
        let fixture = Fixture::new("opaque-budget");
        fixture
            .write(
                "Sources/SlopDeskHost/MetadataResponseBuilder.swift",
                "    static let defaultMaxOpaquePayloadBytes = 15 * 1024 * 1024\n",
            )
            .write(
                "Sources/SlopDeskHost/HostMetadataProbe.swift",
                "    private static let maxCaptureBytes = 15 * 1024 * 1024\n",
            )
            .write(
                "rust/slopdesk-probe/src/run.rs",
                "pub const MAX_OPAQUE_READ_BYTES: usize = 15 * 1024 * 1024;\n",
            );
        assert!(super::opaque_budget(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-probe/src/run.rs",
            "pub const MAX_OPAQUE_READ_BYTES: usize = 32 * 1024 * 1024;\n",
        );
        let report = super::opaque_budget(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("REPLY with")),
            "{report:?}"
        );
        assert!(
            report.violations().iter().any(|v| v.contains("CAPTURE")),
            "{report:?}"
        );
    }

    /// The shape a "just a small fallback" commit takes.
    #[test]
    fn a_swift_screen_engine_coming_back_is_caught() {
        let fixture = Fixture::new("screen-engine");
        fixture.write("Sources/A.swift", "let x = 1\n");
        assert!(super::deleted_screen_swift(&fixture.tree()).is_clean());

        fixture.write("Sources/Fallback.swift", "enum TerminalScreenModel {}\n");
        let report = super::deleted_screen_swift(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("screen engine is back")),
            "{report:?}"
        );
    }

    const SWIFT_FLAGS: &str = "\
    public static let flagAgentChanged: UInt8 = 0x01
    public static let flagRebuildReplay: UInt8 = 0x02
";
    /// The door the ceiling is asked for through, kept separate so the ceiling break-test can drop
    /// it and the literal at once — which is the single edit that regrows the second spelling.
    const SWIFT_DOOR: &str = "    let cap = slopdesk_screen_constant(0)\n";
    const RUST_FLAGS: &str = "\
pub const FLAG_AGENT_CHANGED: u8 = 0x01;
pub const FLAG_REBUILD_REPLAY: u8 = 0x02;
";

    fn flag_fixture(name: &str) -> Fixture {
        let fixture = Fixture::new(name);
        fixture
            .write(super::SWIFT_SCREEN, &format!("{SWIFT_FLAGS}{SWIFT_DOOR}"))
            .write(super::RUST_SCREEN, RUST_FLAGS);
        fixture
    }
}
