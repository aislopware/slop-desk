//! The two batch BODIES, the read chunk, and the three absences hostd owes superd.
//!
//! Ported from `scripts/check-supervisor.sh` §§4b–8.

use crate::claim::{Claim, Extract, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

const RUST_SNIFFER: &str = "rust/slopdesk-superd/src/sniffer.rs";
const RUST_BLOCKS: &str = "rust/slopdesk-superd/src/blocks.rs";
const RUST_SERVER: &str = "rust/slopdesk-superd/src/server.rs";
const RUST_PROTOCOL: &str = "rust/slopdesk-superd/src/protocol.rs";
const SWIFT_SNIFFED: &str = "Sources/SlopDeskSupervisor/SniffedEvent.swift";
const SWIFT_BLOCK_EVENT: &str = "Sources/SlopDeskSupervisor/BlockEvent.swift";

/// §4b — the two batch bodies, the one part of this protocol hand-written at BOTH ends.
///
/// §3 and §4 pin superd's ENVELOPE — the verbs, the listener kinds, the frame tags, the cap. Inside
/// a `0x04` or a `0x05` frame is a JSON body neither of them can see, and that body is written by
/// hand on both sides: superd hand-writes `serialize_entry` per key (`sniffer.rs`, `blocks.rs` —
/// serde cannot internally-tag a newtype variant, and the failure would be a run-time one on the
/// hot path), and hostd re-spells every key as a subscript or a synthesised `CodingKey`. Nothing
/// compares the two spellings, and nothing can: each end's suite reads only its own end, so a
/// rename passes both suites green.
///
/// The failure is silent in the worst available way. `guard member["state"] as? String == "idle"`
/// is a decode with a DEFAULT — rename `state` on the Rust side and every finished command reads as
/// still running, so the spinner never stops and nothing is logged (docs/51 §6.13). The block half
/// is the same shape: a renamed `commandText` fills the Commands panel with blank rows (§6.14).
///
/// So this compares the ALPHABETS, both ways, derived from each side rather than listed here.
/// Comments are stripped from the Swift: the doc comments on both files NAME the keys on purpose —
/// that prose is why the shape is written by hand at all — and matching it would make this gate
/// pass on its own documentation.
#[must_use]
pub fn batch_bodies(tree: &Tree) -> Report {
    let claims = [
        // The two envelope keys, `{"events": […]}` and `{"blocks": […]}`. One word each, and the
        // whole batch is lost if it moves: `decodeBatch` returns nil, hostd drops the frame, and a
        // pane simply stops reporting. Rust spells them as the field names of the two batch structs.
        Claim::SameValue {
            label: "sniff batch envelope key",
            swift: Extract::code(SWIFT_SNIFFED, r#"root\["([a-zA-Z_]+)"\]"#),
            rust: Extract::code(RUST_SERVER, r"^ *([a-z_]+): ").within(r"struct SniffBatch", r"^\}"),
        },
        Claim::SameValue {
            label: "blocks batch envelope key",
            swift: Extract::code(SWIFT_BLOCK_EVENT, r"^ *var ([a-zA-Z_]+):")
                .within(r"private struct BlockBatch", r"^\}"),
            rust: Extract::code(RUST_SERVER, r"^ *([a-z_]+): ").within(r"struct BlockBatch", r"^\}"),
        },
        // The sniff body: `sniffer.rs`'s hand-written map against `SniffedEvent`'s subscripts.
        Claim::SameSet {
            label: "sniff body keys",
            swift: Extract::code(SWIFT_SNIFFED, r#"member\["([a-zA-Z_]+)"\]"#),
            rust: Extract::code(RUST_SNIFFER, r#"serialize_entry\("([a-zA-Z_]*)""#),
        },
        // The `kind` VALUES, which are the tag: an unrecognised one decodes to `.unknown` and is
        // dropped silently by design, so a rename here loses a whole event class with nothing to
        // see. Rust writes three of them through the shared `value_of` helper and three inline.
        Claim::SameSet {
            label: "sniff kind values",
            swift: Extract::code(SWIFT_SNIFFED, r#"(?m)^ *case "([a-zA-Z_]*)""#),
            rust: Extract::code(RUST_SNIFFER, r#"value_of\(serializer, "([a-zA-Z_]*)""#)
                .also(&[r#"serialize_entry\("kind", "([a-zA-Z_]*)"\)"#]),
        },
        // The `state` values — a plain set comparison, and it only became one when the SOURCE was
        // fixed. `SniffedEvent` used to read `guard … == "idle" else { .commandRunning }`, spelling
        // one literal and inferring the other from its absence, so there was no Swift set to
        // compare and this gate had to stand a cardinality pin up in its place. It spells both now,
        // and an unrecognised state decodes to `.unknown(kind: "status")` rather than to a guess.
        //
        // This pins the ALPHABET; it cannot pin the MEANING — nothing textual can tell that Swift
        // has not swapped the two arms. `testAnUnknownStateIsNeverSilentlyReadAsRunning` pins that,
        // and the two are the pair: the test proves the mapping for the strings that exist, this
        // proves the strings still exist.
        Claim::SameSet {
            label: "sniff status states",
            swift: Extract::code(SWIFT_SNIFFED, r#"state == "([a-zA-Z_]*)""#),
            rust: Extract::code(RUST_SNIFFER, r#"serialize_entry\("state", "([a-zA-Z_]*)"\)"#),
        },
        // The block body: `blocks.rs`'s three hand-written maps against `BlockEvent.swift`'s types.
        // `BlockMeta` is the one that rides the `0x05` batch AND the reattach snapshot, which is why
        // it is tagged `kind` at all; Swift reads that tag through its own `Tag` enum rather than as
        // a stored property, so the two are unioned into one comparable alphabet.
        Claim::SameSet {
            label: "block metadata keys",
            swift: Extract::code(SWIFT_BLOCK_EVENT, r"^ *public var ([a-zA-Z_]*):")
                .within(r"^public struct BlockMetadata", r"public init\(")
                .also(&[r"enum Tag: String, CodingKey \{ case ([a-zA-Z_]*)"]),
            rust: Extract::code(RUST_BLOCKS, r#"serialize_entry\("([a-zA-Z_]*)""#)
                .within(r"impl serde::Serialize for BlockMeta", r"^\}"),
        },
        Claim::SameSet {
            label: "block kind values",
            swift: Extract::code(SWIFT_BLOCK_EVENT, r#"(?m)^ *case "([a-zA-Z_]*)""#),
            rust: Extract::code(RUST_BLOCKS, r#"serialize_entry\("kind", "([a-zA-Z_]*)"\)"#),
        },
        // The badge states. Swift decodes these as a `String`-raw-value enum, so the case NAMES are
        // the wire; Rust writes them as literals in a `match`. An unknown one is kept as a skew on
        // purpose (`BlockEvent.swift`), so a rename here leaves a spinner up forever rather than
        // failing.
        Claim::SameSet {
            label: "block progress states",
            swift: Extract::code(SWIFT_BLOCK_EVENT, r"(?m)^ *case ([a-zA-Z_]*)$")
                .within(r"public enum SyntheticProgress", r"^\}"),
            rust: Extract::code(RUST_BLOCKS, r#"SyntheticProgress::[A-Za-z]* => "([a-zA-Z_]*)""#)
                .within(r"impl serde::Serialize for BlockEvent", r"^\}"),
        },
        // `ControlBlock` is the third hand-written map in `blocks.rs` — a finished block with its
        // bytes, what the agent-control verbs read. Swift spells it as an explicit `CodingKey`
        // enum, the only one of these types where the key list is written out rather than
        // synthesised.
        Claim::SameSet {
            label: "control block keys",
            swift: Extract::code(SWIFT_BLOCK_EVENT, r"(?m)^ *case ([a-zA-Z_]*)$")
                .within(r"private enum Key: String, CodingKey", r"^ *\}"),
            rust: Extract::code(RUST_BLOCKS, r#"serialize_entry\("([a-zA-Z_]*)""#)
                .within(r"impl serde::Serialize for ControlBlock", r"^\}"),
        },
        // The reply that CARRIES those two — derived, not hand-written, but decoded by the same file
        // and skewed the same way: `nextIndex` is the `run --wait` baseline, and an absent one makes
        // the wait start counting from zero. The Rust side is read rename-first, so a
        // `#[serde(rename)]` is what crosses and the snake-case field name never is.
        Claim::SameSet {
            label: "blocks reply keys",
            swift: Extract::code(SWIFT_BLOCK_EVENT, r"(?m)^ *public var ([a-zA-Z_]*):.*[^{]$")
                .within(r"^public struct BlocksReply", r"^\}"),
            rust: Extract::code(RUST_PROTOCOL, "")
                .within(r"^pub struct BlocksReply", r"^\}")
                .serde_fields(),
        },
        Claim::SameSet {
            label: "open block keys",
            swift: Extract::code(SWIFT_BLOCK_EVENT, r"(?m)^ *public var ([a-zA-Z_]*):")
                .within(r"^public struct OpenBlock", r"^\}"),
            rust: Extract::code(RUST_PROTOCOL, "")
                .within(r"^pub struct OpenBlock", r"^\}")
                .serde_fields(),
        },
    ];
    check_all(tree, &claims)
}

/// §5 — the PTY read chunk, a joint decision rather than a wire constant.
///
/// superd alone reads with it, but the Swift copy is what the bounded-queue sizing is reasoned
/// against. 32 KiB is half `hostQueueCapacityBytes`, so the gate's worst overshoot is capacity plus
/// one read. Raising one without the other silently re-opens a problem that was solved once: a read
/// larger than the bound pauses on every flood chunk.
#[must_use]
pub fn read_chunk(tree: &Tree) -> Report {
    let claims = [Claim::SameValue {
        label: "PTY read chunk",
        swift: Extract::code(
            "Sources/SlopDeskHost/PaneOutputStream.swift",
            r"readChunkSize = (.*)$",
        ),
        rust: Extract::code(
            "rust/slopdesk-superd/src/pump.rs",
            r"READ_CHUNK_BYTES: usize = (.*);$",
        ),
    }];
    check_all(tree, &claims)
}

/// §§6–8 — the three absences hostd owes superd.
///
/// **Nothing in hostd reads a master.** hostd's master is the SAME open file description superd
/// reads (`SCM_RIGHTS` duplicates the descriptor, not the description), so a second reader here
/// does not observe the stream — it steals from it, and an `O_NONBLOCK` set on it lands on superd's
/// reads too. Writes, `ioctl` and `tcgetpgrp` are fine and are why hostd still holds the fd at all.
///
/// **No pid in ANY unix socket a survivor reconnects to.** §1 ratchets superd's own three paths;
/// this is the same bug everywhere else, because it was never confined to them. The code panel's
/// bridge socket carried `getpid()` until 2026-08-11, so a running code-server — which now survives
/// a hostd restart — kept dialling the address of the hostd that started it, forever. A child
/// remembers its `execve` environment and nothing can correct it.
///
/// **hostd's stop lets the panel backends GO.** `relinquish` vs `terminate` is the line the whole
/// daemon is drawn along (docs/51 §5.5), and the panel is where it is easiest to cross by accident:
/// both spellings compile, both look like cleanup, and the difference only shows up as the user
/// watching Node boot again after every host edit. The Android manager USED to be exempt — its
/// bridge was an in-process listener with no child to keep. It is `slopdesk-androidd` under superd
/// now (docs/48), so it is held to the same line: a `shutdown()` here kills every live mirror on a
/// host edit. (The DEVICES it boots stay orphaned on purpose — docs/51 §8.)
#[must_use]
pub fn host_owes_superd(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"\b(read|poll|select)\([^)]*masterFD",
            all: &[],
            unless: &["readChunkSize"],
            view: View::Code,
            exempt: &[],
            message: "{files} reads or polls a PTY master — superd owns the read side (CLAUDE.md, docs/51 \
                      §6.5)",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"\.sock",
            all: &["getpid|processIdentifier"],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a unix socket path in {files} carries a pid — a survivor holds an address nobody will \
                      rebind (docs/51 §1)",
        },
        Claim::Lacks {
            path: "Sources/SlopDeskHost/HostServer.swift",
            pattern: r"(HostCodeServerPerformer|HostSimulatorPerformer|HostAndroidPerformer)\.sharedManager\.shutdown\(\)",
            view: View::Code,
            message: "hostd's stop TERMINATES a panel backend — it must relinquish it (docs/51 §6.7)",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    //! Each of these seeds the exact drift the rule was written for.

    use crate::tests::Fixture;

    /// The §6.13 failure, in miniature: a key renamed on the Rust side only. `guard
    /// member["state"]` is a decode with a default, so this is the change that leaves every
    /// spinner up forever.
    #[test]
    fn a_body_key_renamed_on_one_side_only_is_caught() {
        let fixture = Fixture::new("sniff-key");
        fixture
            .write(
                "Sources/SlopDeskSupervisor/SniffedEvent.swift",
                "let a = member[\"state\"]\nlet b = member[\"cwd\"]\n",
            )
            .write(
                "rust/slopdesk-superd/src/sniffer.rs",
                "map.serialize_entry(\"status\", &v)?;\nmap.serialize_entry(\"cwd\", &v)?;\n",
            )
            .write("rust/slopdesk-superd/src/blocks.rs", "\n")
            .write("rust/slopdesk-superd/src/server.rs", "\n")
            .write("rust/slopdesk-superd/src/protocol.rs", "\n")
            .write("Sources/SlopDeskSupervisor/BlockEvent.swift", "\n");
        let report = super::batch_bodies(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("sniff body keys")),
            "{report:?}",
        );
    }

    /// The invariant the whole subsystem turns on. A second reader on the master does not observe
    /// the stream, it steals from it.
    #[test]
    fn a_second_reader_on_the_master_is_caught_and_the_chunk_size_is_not() {
        let fixture = Fixture::new("master-read");
        fixture
            .write("Sources/SlopDeskHost/HostServer.swift", "let x = 1\n")
            .write(
                "Sources/SlopDeskHost/Fine.swift",
                "read(masterFD, buf, readChunkSize)\n",
            );
        assert!(super::host_owes_superd(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskHost/Bad.swift",
            "let n = read(masterFD, &buf, 4096)\n",
        );
        let report = super::host_owes_superd(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("Bad.swift")),
            "{report:?}"
        );
    }

    /// A pid in a socket path leaves a survivor dialling an address nobody will rebind.
    #[test]
    fn a_pid_keyed_socket_path_is_caught() {
        let fixture = Fixture::new("pid-sock");
        fixture.write("Sources/SlopDeskHost/HostServer.swift", "let x = 1\n");
        assert!(super::host_owes_superd(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskHost/Bridge.swift",
            "let path = \"/tmp/bridge-\\(getpid()).sock\"\n",
        );
        let report = super::host_owes_superd(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("carries a pid")),
            "{report:?}"
        );
    }

    /// `relinquish` vs `terminate` — both compile, both look like cleanup, and only one of them
    /// makes the user watch Node boot again after every host edit.
    #[test]
    fn terminating_a_panel_backend_at_stop_is_caught() {
        let fixture = Fixture::new("relinquish");
        fixture.write(
            "Sources/SlopDeskHost/HostServer.swift",
            "HostCodeServerPerformer.sharedManager.relinquish()\n",
        );
        assert!(super::host_owes_superd(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskHost/HostServer.swift",
            "HostCodeServerPerformer.sharedManager.shutdown()\n",
        );
        let report = super::host_owes_superd(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("TERMINATES")),
            "{report:?}"
        );
    }
}
