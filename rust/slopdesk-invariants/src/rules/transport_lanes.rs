//! The lanes bytes travel on — the two device consoles, the superd control frame, the receive
//! buffer, `docs/55` §4c's arena, the `NWConnection` channel and the `write(2)` loop.
//!
//! Ported from the deleted `check-supervisor.sh`. These are the copies that were counted rather
//! than argued about: six `write(2)` loops, eleven arena readers in Swift and seven more in the
//! shim, fourteen narrowing casts, two byte channels that each took the same fd-leak fix three
//! times. A second spelling of a byte LAYOUT is worse than a second spelling of a rule, because it
//! shows up as a desynchronised socket rather than as a wrong value.

use crate::claim::{Claim, GATE_RULES, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

const SWIFT_DEVICE_LOG: &str = "Sources/SlopDeskDevicePanels/Shared/DeviceLogLine.swift";
/// hostd's end of superd's framing, Rust since `docs/60` Batch B deleted `SupervisorFrame.swift`.
const HOST_FRAME: &str = "rust/slopdesk-superclient/src/frame.rs";

/// And ONE grammar per device console, neither of them in Swift
///
/// Two files parsed a device's own log output — `logcat -v time` and `log stream --style compact` —
/// over text a program on the far side of a device wrote, thousands of lines a minute, on the
/// socket read path. Both asked `Character.isNumber`/`isUppercase`, which are Unicode property
/// lookups per grapheme cluster, and both built four `String`s a row out of a `String` the row was
/// a slice of. They were also the SAME parser twice: four fields, the same verbatim fallback, one
/// field name apart. `slopdesk-devicelog` owns both grammars and one `DeviceLogLine` carries both
/// consoles' rows.
///
/// The two doors answer byte offsets INTO THE CALLER'S OWN LINE — that is the whole reason nothing
/// crosses back but six numbers and a severity. Copying the line into a fresh `[UInt8]` first threw
/// that away: a heap buffer per row, on a path a booting device drives at hundreds of rows a
/// second. Measured (`swiftc -O`, stand-in door): 154 ns/row before, 94 ns after — 39% of the
/// marshalling, and the parse behind it is 56 ns.
#[must_use]
pub fn one_grammar_per_device_console(tree: &Tree) -> Report {
    let claims = [
        Claim::Lacks {
            path: SWIFT_DEVICE_LOG,
            pattern: r"func isDate|func isTime|func isPriority|func isSeverityToken|isNumber|isUppercase|allSatisfy|firstIndex\(of:|drop\(while:",
            view: View::Code,
            message: "DeviceLogLine.swift walks a device log line in Swift again — slopdesk-devicelog owns \
                      both grammars",
        },
        Claim::Mentions {
            path: SWIFT_DEVICE_LOG,
            names: &["slopdesk_logcat_parse", "slopdesk_unified_log_parse"],
            message: "DeviceLogLine.swift no longer asks {entry} — the console grammars are one \
                      implementation",
        },
        Claim::Lacks {
            path: SWIFT_DEVICE_LOG,
            pattern: r"Array\(text\.utf8\)",
            view: View::Code,
            message: "DeviceLogLine.swift copies a log line to lend it to a door that answers offsets into \
                      that same line — withUTF8 lends the storage",
        },
        Claim::Names {
            path: SWIFT_DEVICE_LOG,
            needle: "text.withUTF8",
            message: "DeviceLogLine.swift: the line stopped being lent to the door — see the parse's own \
                      comment",
        },
        // The two structs are gone and must stay gone: they were one type spelled twice, and a
        // second one would immediately grow a second parse to fill it.
        Claim::NoneUnder {
            roots: &["Sources/SlopDeskDevicePanels", "Sources/SlopDeskPhoneUI/Panel"],
            extensions: &["swift"],
            pattern: "struct AndroidLogLine|struct SimulatorLogLine",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} brought back a per-console row type — one console row serves both device \
                      panels",
        },
        Claim::Names {
            path: SWIFT_DEVICE_LOG,
            needle: "enum DeviceLogSeverity: UInt8",
            message: "DeviceLogLine.swift: the shared severity scale stopped being one closed enum",
        },
        // The spans cross a C ABI and slice the caller's own buffer, so the Swift side clamps rather
        // than trusts. Without the clamp a door bug is a TRAP in the client, not a wrong row.
        Claim::Names {
            path: SWIFT_DEVICE_LOG,
            needle: "Swift.min(Int(offset), bytes.count)",
            message: "DeviceLogLine.swift: a span from the door is sliced unclamped — that is a trap, not a \
                      bad row",
        },
        Claim::Names {
            path: "rust/slopdesk-devicelog/src/logcat.rs",
            needle: "pub fn parse",
            message: "rust/slopdesk-devicelog/src/logcat.rs lost its parse — the two grammars stay apart",
        },
        Claim::Names {
            path: "rust/slopdesk-devicelog/src/unified.rs",
            needle: "pub fn parse",
            message: "rust/slopdesk-devicelog/src/unified.rs lost its parse — the two grammars stay apart",
        },
    ];
    check_all(tree, &claims)
}

/// And ONE spelling of the superd control frame
///
/// superd writes these frames and hostd reads them, and the LAYOUT was written out twice: superd's
/// `frame.rs` in Rust and `SupervisorFrame.swift` in Swift, each module's own doc calling the other
/// a mirror. Two hand-written spellings of one byte layout, agreeing by inspection, in the one
/// place where a disagreement shows up as a DESYNCHRONISED SOCKET rather than as a wrong value.
/// `slopdesk-superwire` is the spelling; each side keeps only its own syscalls, because the
/// descriptor has to land in the reading process.
///
/// The SYSCALLS deliberately stay per side: superd hands away a descriptor it owns through `nix`,
/// and hostd receives one through its own passing code. If either ever grew a door, this is where
/// that decision gets argued rather than slipped in.
#[must_use]
pub fn one_spelling_of_the_superd_frame(tree: &Tree) -> Report {
    let claims = [
        Claim::Lacks {
            path: HOST_FRAME,
            pattern: r"const TAG_PLAIN|const TAG_OUTPUT|const MAX_BODY|<< *24|fn parse_output|fn parse_pane_json",
            view: View::Code,
            message: "rust/slopdesk-superclient/src/frame.rs spells the superd frame layout itself again — \
                      slopdesk-superwire owns it",
        },
        Claim::Mentions {
            path: HOST_FRAME,
            names: &["slopdesk_superwire::body_length", "slopdesk_superwire::"],
            message: "rust/slopdesk-superclient/src/frame.rs no longer asks {entry} — the framing is one \
                      implementation",
        },
        Claim::Names {
            path: "rust/slopdesk-superclient/Cargo.toml",
            needle: "\nslopdesk-superwire = ",
            message: "rust/slopdesk-superclient dropped slopdesk-superwire — the frame layout would be \
                      spelled twice again",
        },
        Claim::Names {
            path: "rust/slopdesk-superd/Cargo.toml",
            needle: "\nslopdesk-superwire = ",
            message: "rust/slopdesk-superd dropped slopdesk-superwire — the frame layout would be spelled \
                      twice again",
        },
        Claim::Lacks {
            path: "rust/slopdesk-superd/src/frame.rs",
            pattern: "const TAG_PLAIN|const MAX_BODY_BYTES|pub fn parse_output|pub fn parse_sniff",
            view: View::Code,
            message: "superd/src/frame.rs re-declares the frame layout inside superd — it belongs to \
                      slopdesk-superwire",
        },
        // The SCM_RIGHTS half stayed per side through the port, and for the same reason it always
        // did: the descriptor has to land in the READING process, so neither end can borrow the
        // other's `recvmsg`. Both ends are Rust now, which makes the temptation to share it real
        // rather than theoretical — this is where that gets argued.
        Claim::Mentions {
            path: HOST_FRAME,
            names: &["recvmsg", "ScmRights"],
            message: "rust/slopdesk-superclient/src/frame.rs lost {entry} — the SCM_RIGHTS lane stays on \
                      this side on purpose",
        },
    ];
    check_all(tree, &claims)
}

/// One receive buffer, and one spelling of a narrowed length
///
/// The terminal decoder and the mux decoder each carried the whole streaming rule — fail-stop
/// poisoning, the cursor, the 64 KiB compaction threshold, the owed compaction an eliding answer
/// defers — and the two copies had ALREADY drifted three ways. `slopdesk-wire::framing` is the one
/// reader; a second `deferred_compaction` field anywhere is that rule growing a third copy.
///
/// `truncating_uN` had fourteen copies across two crates, and four of them shared a name while two
/// of those four SATURATED instead of truncating. One home each, and the name says which.
#[must_use]
pub fn one_receive_buffer_and_one_narrowing(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneUnder {
            roots: &["rust"],
            extensions: &["rs"],
            pattern: "deferred_compaction",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &["rust/slopdesk-wire/src/framing.rs", GATE_RULES],
            message: "a second length-prefixed receive buffer grew back ({files}) — slopdesk-wire::framing \
                      is the reader",
        },
        Claim::NoneUnder {
            roots: &["rust"],
            extensions: &["rs"],
            pattern: r"^(pub )?(const )?fn (truncating|saturating)_u(8|16|32)\(",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[
                "rust/slopdesk-video/src/bytes.rs",
                "rust/slopdesk-wire/src/bytes.rs",
                "rust/slopdesk-ffi/src/lib.rs",
            ],
            message: "a narrowing cast helper grew back ({files}) — slopdesk-video::bytes and \
                      slopdesk-ffi's root spell them",
        },
    ];
    check_all(tree, &claims)
}

/// One arena reader, on the side that holds the buffer
///
/// `docs/55` §4c's arena convention had a write half (`TextArena::intern`) shared on the CRATE side
/// from the day it was written, and nothing shared on the Swift side at all: seven reader copies in
/// `slopdesk-ffi`, eleven more in Swift, and the eleven had drifted — one bounds-checked only the
/// length, four answered `""` for bytes the crate's own reader repairs, and the two doors Swift
/// FILLS an arena for had each written their own `intern`. `crate::arena_span`/`arena_text` and
/// `ArenaText` are the one of each; a face keeps a one-line overload for its own named
/// `(offset, length)` struct and calls through, it does not spell the read or the write again.
///
/// ## One row dropped, and why it is not re-aimed
/// `SlopDeskVideoHost` used to be an eighth target on the table below. `docs/61` deleted it, and
/// unlike the bans in [`crate::rules::video_host`] this row has nothing to re-aim: it is a
/// `Claim::Depends`, and what a `Depends` states is that a target which CROSSES the arena
/// convention takes it from `SlopDeskArena` rather than respelling it. The daemon does not cross
/// that convention at all — there is no `(offset, length)` pair to read, because
/// `rust/slopdesk-videohostd` links `slopdesk-video` as an ordinary Rust dependency and hands it
/// `&str`. A row demanding it depend on a Swift package would be a demand no Rust binary can meet,
/// and one demanding some Rust equivalent would be inventing a convention rather than pinning one.
/// The other seven targets are untouched, and the Swift-side ban above still covers every file the
/// deleted target's arena readers could come back in, because it was already tree-wide.
#[must_use]
pub fn one_arena_reader_and_one_interner(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneUnder {
            roots: &["rust/slopdesk-ffi/src"],
            extensions: &["rs"],
            pattern: r"from_utf8_lossy\(arena",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &["rust/slopdesk-ffi/src/lib.rs"],
            message: "an arena reader grew back in slopdesk-ffi ({files}) — crate::arena_text is the read \
                      half of §4c",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: &["swift"],
            pattern: r"String\(decoding: UnsafeRawBufferPointer\(rebasing:|UInt32\(clamping: arena.count\)|arena\[start\.\.<end\]|String\(bytes: arena",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &["Sources/SlopDeskArena/"],
            message: "an arena reader or interner grew back in a Swift face ({files}) — ArenaText is the \
                      one of each",
        },
        Claim::Depends {
            target: "SlopDeskProtocol",
            dependency: "SlopDeskArena",
            message: "it crosses §4c's convention and must not spell it",
        },
        Claim::Depends {
            target: "SlopDeskVideoProtocol",
            dependency: "SlopDeskArena",
            message: "it crosses §4c's convention and must not spell it",
        },
        Claim::Depends {
            target: "SlopDeskWorkspaceModel",
            dependency: "SlopDeskArena",
            message: "it crosses §4c's convention and must not spell it",
        },
        Claim::Depends {
            target: "SlopDeskFileTransfer",
            dependency: "SlopDeskArena",
            message: "it crosses §4c's convention and must not spell it",
        },
        Claim::Depends {
            target: "SlopDeskWorkspaceCore",
            dependency: "SlopDeskArena",
            message: "it crosses §4c's convention and must not spell it",
        },
        Claim::Depends {
            target: "SlopDeskVideoClient",
            dependency: "SlopDeskArena",
            message: "it crosses §4c's convention and must not spell it",
        },
    ];
    check_all(tree, &claims)
}

/// One `NWConnection` byte channel, for both lanes that need one
///
/// The inspector's event lane and PATH-4's file transfer each spelled the SAME actor — the
/// `onTermination` cancel, the `cancel()` beside every `finish()`, the idempotent `start()`. Three
/// separate fd-leak fixes, each of which had to be made twice or the copies drift. `SlopDeskNet` is
/// the actor; a lane keeps its own protocol (its vocabulary) and one conformance line.
#[must_use]
pub fn one_nwconnection_byte_channel(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: &["swift"],
            pattern: r"connection\.receive\(minimumIncompleteLength",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &["Sources/SlopDeskNet/"],
            message: "a second NWConnection byte channel grew back ({files}) — SlopDeskNet::NWByteChannel \
                      is the one lane",
        },
        Claim::Depends {
            target: "SlopDeskInspector",
            dependency: "SlopDeskNet",
            message: "it dials a byte channel and must not spell one",
        },
        Claim::Depends {
            target: "SlopDeskFileTransfer",
            dependency: "SlopDeskNet",
            message: "it dials a byte channel and must not spell one",
        },
    ];
    check_all(tree, &claims)
}

/// One `write(2)`-until-done loop, and the reaction stays at the call site
///
/// SIX copies: the agent control listener, the client control server, the mux channel session,
/// `slopdesk-client`'s stdout path, the supervisor's frame writer and the screend client. Every one
/// of them folded in EINTR-is-a-retry and short-writes-are-normal, and four dropped the failure
/// while two threw. `SlopDeskTTY::FileDescriptorWrite` is the loop; the DIFFERENCE — drop or report
/// — is a real contract and survives as the outcome each caller switches on.
///
/// The comma in the pattern is load-bearing. `write(fd, buffer, count)` is the syscall;
/// `write(socket: fd, body:)` is `SupervisorFrame`'s own frame writer, whose argument LABEL happens
/// to be the same word and whose `writeAll` delegates to `FileDescriptorWrite.all` exactly as this
/// rule asks.
#[must_use]
pub fn one_write_loop_and_one_read_exactly(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: &["swift"],
            pattern: r"(Darwin\.)?write\((fd|socket),",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &["Sources/SlopDeskTTY/"],
            message: "a raw write(fd) grew back outside SlopDeskTTY ({files}) — FileDescriptorWrite.all is \
                      the write loop",
        },
        // The mirror: `readExactly` was the supervisor's frame reader and the screend client, same
        // loop and same must-report contract spelled with two error types. Both of those two keep
        // their own, and are named — a THIRD is the regression.
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: &["swift"],
            pattern: "func readExactly",
            all: &[],
            unless: &[],
            view: View::Code,
            // Down to ONE since `docs/60` Batch B: the two host-side readers were deleted with
            // `Sources/SlopDeskSupervisor` and `Sources/SlopDeskScreen`, and their Rust replacements
            // read through `std::io::Read::read_exact`, which is the loop, not a copy of it.
            exempt: &["Sources/SlopDeskTTY/"],
            message: "a third readExactly grew back ({files}) — FileDescriptorRead.exactly is the loop",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    fn device_log(fixture: &Fixture) {
        fixture
            .write(
                super::SWIFT_DEVICE_LOG,
                "slopdesk_logcat_parse\nslopdesk_unified_log_parse\ntext.withUTF8\nenum DeviceLogSeverity: \
                 UInt8 {}\nSwift.min(Int(offset), bytes.count)\n",
            )
            .write("rust/slopdesk-devicelog/src/logcat.rs", "pub fn parse\n")
            .write("rust/slopdesk-devicelog/src/unified.rs", "pub fn parse\n");
    }

    #[test]
    fn a_console_row_is_parsed_once_and_lent_not_copied() {
        let fixture = Fixture::new("transport-device-log");
        device_log(&fixture);
        assert!(super::one_grammar_per_device_console(&fixture.tree()).is_clean());

        // The copy the measurement removed, back.
        fixture.append(super::SWIFT_DEVICE_LOG, "let bytes = Array(text.utf8)\n");
        assert!(!super::one_grammar_per_device_console(&fixture.tree()).is_clean());

        // A per-console row type, back under either panel.
        device_log(&fixture);
        fixture.write(
            "Sources/SlopDeskDevicePanels/Android/Row.swift",
            "struct AndroidLogLine {}\n",
        );
        assert!(!super::one_grammar_per_device_console(&fixture.tree()).is_clean());

        // And an unclamped span, which is a trap rather than a bad row.
        device_log(&fixture);
        fixture.write(super::SWIFT_DEVICE_LOG, "slopdesk_logcat_parse\n");
        assert!(!super::one_grammar_per_device_console(&fixture.tree()).is_clean());
    }

    /// Everything the frame seam's fixture must spell, one line each.
    ///
    /// A LIST rather than one long literal, and that is not style: as a single string it wrapped
    /// across lines with `\` continuations, rustfmt could not settle on where, and two of the
    /// re-wraps landed mid-escape — turning `\n` into a literal backslash and an `n`. The fixture
    /// still passed, one separator short of what it claimed to seed, which is the shape of an
    /// assertion that has quietly stopped asserting.
    ///
    /// It used to seed the seven `slopdesk_supervisor_*` DOORS and their four Swift call helpers.
    /// hostd's end is `slopdesk-superclient` now and calls superwire directly, so the seam it must
    /// spell is the `use` rather than the door — and the two `recvmsg` names, which stay per side.
    const FRAME_SEAM: [&str; 4] = [
        "slopdesk_superwire::body_length",
        "slopdesk_superwire::Header",
        "recvmsg",
        "ScmRights",
    ];

    fn frame(fixture: &Fixture) {
        fixture
            .write(super::HOST_FRAME, &format!("{}\n", FRAME_SEAM.join("\n")))
            .write(
                "rust/slopdesk-superclient/Cargo.toml",
                "\nslopdesk-superwire = { path = \"../slopdesk-superwire\" }\n",
            )
            .write(
                "rust/slopdesk-superd/Cargo.toml",
                "\nslopdesk-superwire = { path = \"..\" }\n",
            )
            .write(
                "rust/slopdesk-superd/src/frame.rs",
                "kept so the ban has a haystack\n",
            );
    }

    #[test]
    fn the_frame_layout_is_spelled_in_one_crate() {
        let fixture = Fixture::new("transport-superd-frame");
        frame(&fixture);
        assert!(super::one_spelling_of_the_superd_frame(&fixture.tree()).is_clean());

        // The layout restated inside the daemon.
        fixture.append("rust/slopdesk-superd/src/frame.rs", "const TAG_PLAIN: u8 = 1;\n");
        assert!(!super::one_spelling_of_the_superd_frame(&fixture.tree()).is_clean());

        // Or on hostd's end — the drift that used to be cross-language and is now same-language,
        // which is the same silence with none of the visual warning.
        frame(&fixture);
        fixture.append(super::HOST_FRAME, "const TAG_PLAIN: u8 = 1;\n");
        assert!(!super::one_spelling_of_the_superd_frame(&fixture.tree()).is_clean());

        // The SCM_RIGHTS lane is kept on purpose — losing it is a regression too.
        frame(&fixture);
        fixture.write(super::HOST_FRAME, "slopdesk_superwire::body_length\n");
        assert!(!super::one_spelling_of_the_superd_frame(&fixture.tree()).is_clean());
    }

    #[test]
    fn the_receive_buffer_and_the_casts_have_one_home_each() {
        let fixture = Fixture::new("transport-receive-buffer");
        let seed = |fixture: &Fixture| {
            fixture
                .write(
                    "rust/slopdesk-wire/src/framing.rs",
                    "deferred_compaction: usize,\n",
                )
                .write(
                    "rust/slopdesk-video/src/bytes.rs",
                    "pub const fn truncating_u32(\n",
                );
        };
        seed(&fixture);
        assert!(super::one_receive_buffer_and_one_narrowing(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-terminal/src/decode.rs",
            "deferred_compaction: usize,\n",
        );
        assert!(!super::one_receive_buffer_and_one_narrowing(&fixture.tree()).is_clean());

        seed(&fixture);
        fixture.write(
            "rust/slopdesk-superd/src/n.rs",
            "fn saturating_u16(v: usize) -> u16 { 0 }\n",
        );
        assert!(!super::one_receive_buffer_and_one_narrowing(&fixture.tree()).is_clean());
    }

    /// The manifest's real shape: a single-line `.library(…)` that names the same target FIRST, and
    /// a `.product(name:…)` inside a dependency list. Both are what a naive range gets wrong.
    fn manifest(edges: &[(&str, &[&str])]) -> String {
        use std::fmt::Write as _;

        let mut text = String::new();
        for (target, _) in edges {
            let _ = writeln!(
                text,
                "        .library(name: \"{target}\", targets: [\"{target}\"]),"
            );
        }
        for (target, deps) in edges {
            text.push_str("        .target(\n");
            let _ = writeln!(text, "            name: \"{target}\",");
            text.push_str("            dependencies: [\n");
            text.push_str("                .product(name: \"Logging\", package: \"swift-log\"),\n");
            for dep in *deps {
                let _ = writeln!(text, "                \"{dep}\",");
            }
            text.push_str("            ],\n        ),\n");
        }
        text
    }

    const ARENA: &[(&str, &[&str])] = &[
        ("SlopDeskArena", &[]),
        ("SlopDeskProtocol", &["SlopDeskArena"]),
        ("SlopDeskVideoProtocol", &["SlopDeskArena"]),
        ("SlopDeskWorkspaceModel", &["SlopDeskArena"]),
        ("SlopDeskFileTransfer", &["SlopDeskArena", "SlopDeskNet"]),
        ("SlopDeskWorkspaceCore", &["SlopDeskArena"]),
        ("SlopDeskVideoClient", &["SlopDeskArena"]),
        ("SlopDeskInspector", &["SlopDeskNet"]),
    ];

    #[test]
    fn the_arena_convention_is_read_through_one_face() {
        let fixture = Fixture::new("transport-arena");
        let seed = |fixture: &Fixture| {
            fixture
                .write("Package.swift", &manifest(ARENA))
                .write("rust/slopdesk-ffi/src/lib.rs", "from_utf8_lossy(arena\n")
                .write("Sources/SlopDeskArena/ArenaText.swift", "String(bytes: arena\n");
        };
        seed(&fixture);
        assert!(super::one_arena_reader_and_one_interner(&fixture.tree()).is_clean());

        // A reader in a shim module that is not the root.
        fixture.write("rust/slopdesk-ffi/src/rail.rs", "from_utf8_lossy(arena)\n");
        assert!(!super::one_arena_reader_and_one_interner(&fixture.tree()).is_clean());

        // A target that dropped the edge — which is how a face comes to spell the read itself. The
        // `.library` line still names it and the neighbour above still declares the edge, so this is
        // also the case the shell's `grep -A 24` window could not tell from a kept one.
        //
        // Seeded on `SlopDeskWorkspaceCore` since `docs/61`. It used to be `SlopDeskVideoHost`, and
        // that target is deleted: a break-test that drops an edge nothing demands proves only that
        // the fixture can be edited, which is the shape of green this whole crate exists to refuse.
        seed(&fixture);
        let dropped: Vec<_> = ARENA
            .iter()
            .map(|(target, deps)| {
                if *target == "SlopDeskWorkspaceCore" {
                    (*target, &[][..])
                } else {
                    (*target, *deps)
                }
            })
            .collect();
        fixture.write("Package.swift", &manifest(&dropped));
        assert!(!super::one_arena_reader_and_one_interner(&fixture.tree()).is_clean());
    }

    #[test]
    fn the_byte_channel_is_one_actor() {
        let fixture = Fixture::new("transport-nwchannel");
        let seed = |fixture: &Fixture| {
            fixture.write("Package.swift", &manifest(ARENA)).write(
                "Sources/SlopDeskNet/NWByteChannel.swift",
                "connection.receive(minimumIncompleteLength: 1\n",
            );
        };
        seed(&fixture);
        assert!(super::one_nwconnection_byte_channel(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskInspector/Lane.swift",
            "connection.receive(minimumIncompleteLength: 1)\n",
        );
        assert!(!super::one_nwconnection_byte_channel(&fixture.tree()).is_clean());
    }

    #[test]
    fn the_write_loop_stays_in_one_target() {
        let fixture = Fixture::new("transport-write-loop");
        let seed = |fixture: &Fixture| {
            fixture
                .write(
                    "Sources/SlopDeskTTY/FileDescriptorWrite.swift",
                    "Darwin.write(fd, p, n)\n",
                )
                // ONE reader since `docs/60` Batch B took the other two with their targets. The
                // exemption narrowed with them, so the fixture has to as well — seeding the deleted
                // pair here would have made the ban look wider than it is.
                .write("Sources/SlopDeskTTY/FileDescriptorRead.swift", "func readExactly(\n");
        };
        seed(&fixture);
        assert!(super::one_write_loop_and_one_read_exactly(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskHost/Ctl.swift",
            "let n = write(fd, buffer, count)\n",
        );
        assert!(!super::one_write_loop_and_one_read_exactly(&fixture.tree()).is_clean());

        // The one named reader keeps its own; a second does not.
        seed(&fixture);
        fixture.write("Sources/SlopDeskHost/Other.swift", "func readExactly(_ n: Int)\n");
        assert!(!super::one_write_loop_and_one_read_exactly(&fixture.tree()).is_clean());
    }
}
