//! screend's remaining three alphabets, the frame ceiling, the opaque budget, and the Swift that
//! must stay deleted.
//!
//! Ported from the deleted `check-supervisor.sh`. What all of it guards is the same asymmetry:
//! screend is a launch agent that outlives hostd's build, so every disagreement between the two
//! ends is silent by construction — an old daemon serving a new client reports nothing, answers
//! plausibly, and is wrong.

use crate::claim::{Claim, Extract, SWIFT, SWIFT_ROOTS, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// hostd's end of the screend wire, Rust since `docs/60` Batch B deleted `ScreenProtocol.swift`.
const CLIENT: &str = "rust/slopdesk-screenclient/src/client.rs";
/// The framing half of that end — where a ceiling is asked for, or spelled.
const TRANSPORT: &str = "rust/slopdesk-screenclient/src/transport.rs";
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
/// in `rules::shared_constants` deliberately does not pair them: the third case is spelled
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
            path: CLIENT,
            needle: "slopdesk_screenwire::build_version(&hello)",
            message: "rust/slopdesk-screenclient/src/client.rs no longer parses screend's build version out \
                      of hello (docs/49)",
        },
        // Was a SameValue against `ScreenProtocol.swift`'s `ScreenStatus`. There is one spelling
        // now, so the ratchet is structural instead of comparative: the client REACHES screenwire's
        // alphabet, and a redeclared one would be the second copy coming back under a new name.
        Claim::Names {
            path: "rust/slopdesk-screenclient/src/lib.rs",
            needle: "pub use slopdesk_screenwire::{Snapshot, State, Status, Verdict}",
            message: "rust/slopdesk-screenclient/src/lib.rs stopped re-exporting screenwire's status \
                      alphabet — a second one would decode a verdict as the wrong state",
        },
    ]);

    // ONE-SIDED since `docs/60` Batch B. The banner used to be a VALUE in `ScreenProtocol.swift`
    // compared against screenwire's byte-string, and Swift was read FIRST because Swift was the
    // side that documented it. Screenwire is that side now, so what is left to ratchet is that
    // it still declares one, and that the client has not grown a literal copy to compare
    // against — which is exactly how the pair started.
    let Some(rust) = report.source(tree, RUST_SCREEN, "screend's banner is answered there") else {
        return report;
    };
    match crate::text::capture_first(rust.statements(), r#"HELLO_BANNER: &\[u8\] = b"(.*)";$"#) {
        None => {
            report.fail(format!(
                "{RUST_SCREEN} no longer declares HELLO_BANNER — this gate reads nothing and would pass",
            ));
        },
        Some(banner) => {
            if let Some(client) = report.source(tree, CLIENT, "hostd's end reads the banner there") {
                report.fail_if(
                    crate::text::before(client.code(), r"#\[cfg\(test\)\]").contains(&banner),
                    format!(
                        "hostd's end spells the screend hello banner '{banner}' itself — it is \
                         {RUST_SCREEN}'s HELLO_BANNER, and a second copy is what this gate was written for",
                    ),
                );
            }
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
/// hostd's end, which links `slopdesk-screenwire` directly. So what is ratcheted changed shape —
/// not "do the two numbers agree" but "is there still only one". The daemon's side is pinned by a
/// cargo test in `slopdesk-screenwire` itself, which compares the value it hands out against
/// `MAX_FRAME` rather than a `sed` of its source line. What is left for a ratchet is the CLIENT
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
    let mut report = check_all(tree, &[Claim::Lacks {
        path: TRANSPORT,
        pattern: r"= *[0-9]+ *\* *1024 *\* *1024",
        view: View::Code,
        message: "rust/slopdesk-screenclient/src/transport.rs spells the screend frame ceiling as a literal \
                  again — it is slopdesk_screenwire::MAX_FRAME, and screend reads the same one",
    }]);

    // Was a SET COMPARISON of two spellings — `flagAgentChanged` against `FLAG_AGENT_CHANGED`. The
    // Swift half went with `ScreenProtocol.swift`, and the client IMPORTS screenwire's constants
    // rather than mirroring them, which is a stronger property than the two agreeing: there is
    // nothing left to disagree. What a ratchet still has to catch is the mirror growing back, so it
    // reads the import and bans a local redeclaration.
    let Some(client) = report.source(tree, CLIENT, "screend's reset flags are reached there") else {
        return report;
    };
    let code = crate::text::before(client.code(), r"#\[cfg\(test\)\]");
    for flag in [
        "FLAG_RESET",
        "FLAG_REBUILD_REPLAY",
        "FLAG_AGENT_CHANGED",
        "FLAG_REASSERT_INPUT_MODES",
    ] {
        report.fail_if(
            !code.contains(flag),
            format!("{CLIENT} stopped reaching {flag} — screend honours a bit hostd never sets"),
        );
    }
    report.fail_if(
        crate::text::matches(&code, r"(?m)^ *(pub )?const FLAG_[A-Z_]*: u8"),
        format!(
            "{CLIENT} declares a screend reset flag of its own — that mirror is what slopdesk-screenwire \
             owns, and two copies drift silently",
        ),
    );
    report
}

/// The 15 MiB opaque budget, which is one cap spelled TWICE.
///
/// A metadata `read` verb answers a file, and the ceiling on how much of one it will carry back is
/// written in two places: `MetadataResponseBuilder.defaultMaxOpaquePayloadBytes` (what hostd will
/// put in a reply) and `slopdesk_probe::run::MAX_OPAQUE_READ_BYTES` (what the child will read
/// before truncating).
///
/// It was THREE until the pane census moved. `HostMetadataProbe.maxCaptureBytes` was hostd's own
/// ceiling on the `lsof` drain — the same number asking a different question — and it is gone
/// because that scan is `rust/slopdesk-panecensus` now and rides `slopdesk_probe::run::capture`.
/// The two Swift halves this rule used to report as a genuine second finding are one half.
///
/// `slopdesk-probe` is a `[[bin]]` hostd SPAWNS — it links nothing of hostd's and hostd links
/// nothing of its — so the Rust spelling cannot become a door however the Swift one is settled, and
/// the ratchet is the answer the lifetime picks rather than a compromise.
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

    // Both sides are Rust since `docs/60` F.9, and `slopdesk-hostserver` DEPENDS on
    // `slopdesk-probe` — but these are two CONSTANTS in two crates, and no compiler compares two
    // numbers. `SameValue`'s sides are named `swift`/`rust` for the common case; here only the
    // paths matter.
    let claims = [Claim::SameValue {
        label: "the opaque payload budget hostd will REPLY with",
        swift: Extract::statements(
            "rust/slopdesk-hostserver/src/metadata.rs",
            r"^pub const MAX_OPAQUE_PAYLOAD_BYTES: usize = (.*);$",
        ),
        rust: Extract::statements(RUST_PROBE_RUN, RUST_CAP),
    }];
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
/// policy and not an invitation. `ScrollbackReplayTransform` itself is NOT named, and the reason
/// changed under this sentence: it used to be the CALLER that picked the options, and `a0d0aa54`
/// deleted it along with the replay doors, so the options are picked in hostd and there is no Swift
/// caller left to name. The ban is scoped to DECLARATIONS either way, so prose explaining where the
/// passes went does not fail its own gate.
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
            roots: SWIFT_ROOTS,
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
            roots: SWIFT_ROOTS,
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
            roots: SWIFT_ROOTS,
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
            roots: SWIFT_ROOTS,
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
            roots: SWIFT_ROOTS,
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

    /// A flag hostd stops reaching is a bit screend honours and hostd never sets — the reply
    /// rebuilds nothing and reports an agent that did not change.
    #[test]
    fn a_reset_flag_the_client_stops_reaching_is_caught() {
        let fixture = flag_fixture("screend-flags");
        assert!(super::reset_flags_and_ceiling(&fixture.tree()).is_clean());

        fixture.write(super::CLIENT, &CLIENT_FLAGS.replace("FLAG_AGENT_CHANGED", ""));
        let report = super::reset_flags_and_ceiling(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("stopped reaching FLAG_AGENT_CHANGED")),
            "{report:?}"
        );
    }

    /// The mirror growing back. Both sides being Rust does not make a second `const FLAG_*: u8`
    /// safe — it makes it invisible, since nothing forces the two bytes to agree.
    #[test]
    fn the_client_redeclaring_a_flag_is_caught() {
        let fixture = flag_fixture("screend-naming");
        fixture.write(
            super::CLIENT,
            &format!("{CLIENT_FLAGS}pub const FLAG_AGENT_CHANGED: u8 = 0x04;\n"),
        );
        let report = super::reset_flags_and_ceiling(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("declares a screend reset flag of its own")),
            "{report:?}"
        );
    }

    /// The ceiling used to be a literal, and the only shape anyone regrows is the megabyte
    /// expression — nobody types `67108864`.
    #[test]
    fn the_frame_ceiling_returning_as_a_literal_is_caught() {
        let fixture = flag_fixture("screend-ceiling");
        fixture.write(super::TRANSPORT, "const MAX_FRAME: usize = 64 * 1024 * 1024;\n");
        let report = super::reset_flags_and_ceiling(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("as a literal again")),
            "{report:?}"
        );
    }

    /// The banner is the PROTOCOL identity, and the pair started as one literal copied into the
    /// reader. A second copy is exactly what this half was written for.
    #[test]
    fn the_client_respelling_the_hello_banner_is_caught() {
        let fixture = hello_fixture("screend-banner");
        assert!(super::hello_and_status(&fixture.tree()).is_clean());

        fixture.write(
            super::CLIENT,
            &format!("{CLIENT_HELLO}let want = b\"SLOPDESK-SCREEND\";\n"),
        );
        let report = super::hello_and_status(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("spells the screend hello banner")),
            "{report:?}"
        );
    }

    /// A gate that reads nothing passes. The banner leaving screenwire has to fail HERE rather
    /// than quietly retire the comparison above it.
    #[test]
    fn the_banner_leaving_screenwire_fails_rather_than_passing_vacuously() {
        let fixture = hello_fixture("screend-banner-gone");
        fixture.write(
            super::RUST_SCREEN,
            &RUST_HELLO.replace("pub const HELLO_BANNER: &[u8] = b\"SLOPDESK-SCREEND\";\n", ""),
        );
        let report = super::hello_and_status(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("no longer declares HELLO_BANNER")),
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
                "rust/slopdesk-hostserver/src/metadata.rs",
                "pub const MAX_OPAQUE_PAYLOAD_BYTES: usize = 15 * 1024 * 1024;\n",
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

    /// hostd's end REACHING the four bits rather than owning them — the shape the live client has
    /// since `ScreenProtocol.swift` went, and the one the bans below are written against.
    const CLIENT_FLAGS: &str = "\
use slopdesk_screenwire::{FLAG_RESET, FLAG_REBUILD_REPLAY, FLAG_AGENT_CHANGED, FLAG_REASSERT_INPUT_MODES};
";
    /// The transport half, which must ask for the ceiling rather than spell it.
    const TRANSPORT_ASKS: &str = "let cap = slopdesk_screenwire::MAX_FRAME;\n";
    const RUST_FLAGS: &str = "\
pub const FLAG_RESET: u8 = 0x01;
pub const FLAG_REBUILD_REPLAY: u8 = 0x02;
pub const FLAG_AGENT_CHANGED: u8 = 0x04;
pub const FLAG_REASSERT_INPUT_MODES: u8 = 0x08;
";
    const RUST_HELLO: &str = "\
pub const HELLO_BANNER: &[u8] = b\"SLOPDESK-SCREEND\";
pub fn hello_payload(version: &str) -> Vec<u8> { version.into() }
";
    const CLIENT_HELLO: &str = "\
let version = slopdesk_screenwire::build_version(&hello);
";

    fn flag_fixture(name: &str) -> Fixture {
        let fixture = Fixture::new(name);
        fixture
            .write(super::CLIENT, CLIENT_FLAGS)
            .write(super::TRANSPORT, TRANSPORT_ASKS)
            .write(super::RUST_SCREEN, RUST_FLAGS);
        fixture
    }

    fn hello_fixture(name: &str) -> Fixture {
        let fixture = Fixture::new(name);
        fixture
            .write(super::RUST_SCREEN, RUST_HELLO)
            .write(
                super::RUST_SCREEN_SERVER,
                "let payload = hello_payload(env!(\"CARGO_PKG_VERSION\"));\n",
            )
            .write(super::CLIENT, CLIENT_HELLO)
            .write(
                "rust/slopdesk-screenclient/src/lib.rs",
                "pub use slopdesk_screenwire::{Snapshot, State, Status, Verdict};\n",
            );
        fixture
    }

    /// The stripper family stays deleted in every Swift root.
    ///
    /// A journal re-declared in a test bundle is the second implementation, and the one place it
    /// would go unseen: `Apps/ClientApp-iOS/Tests` is under neither `Sources` nor `Tests`.
    #[test]
    fn a_deleted_screen_type_is_caught_in_an_app_test_bundle() {
        let fixture = Fixture::new("screen-type-in-apps");
        fixture.write("Apps/ClientApp-iOS/Tests/A.swift", "let ordinary = 1\n");
        assert!(super::deleted_screen_swift(&fixture.tree()).is_clean());
        fixture.append("Apps/ClientApp-iOS/Tests/A.swift", "enum ScrollbackJournal {}\n");
        assert!(
            !super::deleted_screen_swift(&fixture.tree()).is_clean(),
            "a test bundle is Swift like any other"
        );
    }
}
