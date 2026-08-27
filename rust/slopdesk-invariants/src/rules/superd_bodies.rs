//! The two batch BODIES, the read chunk, and the three absences hostd owes superd.
//!
//! Ported from the deleted `check-supervisor.sh` §§4b–8.

use crate::claim::{Claim, Extract, RUST, View, check_all};
use crate::paths::HOSTD_CRATES;
use crate::report::Report;
use crate::tree::Tree;

const RUST_SNIFFER: &str = "rust/slopdesk-superd/src/sniffer.rs";
const RUST_BLOCKS: &str = "rust/slopdesk-superd/src/blocks.rs";
const RUST_SNIFFWIRE: &str = "rust/slopdesk-superwire/src/sniffwire.rs";
const RUST_BLOCKWIRE: &str = "rust/slopdesk-superwire/src/blockwire.rs";
/// The name of the golden test each wire module owes. Spelled once, asserted in both.
const GOLDEN: &str = "fn every_event_serialises_to_the_shape_the_wire_has_always_carried";

/// §4b — the two batch bodies: ONE alphabet each, and the golden test that holds it still.
///
/// This gate used to compare ALPHABETS, both ways, eleven claims of them. It had to: the bodies
/// inside a `0x04` and a `0x05` frame were hand-written at both ends — superd hand-wrote a
/// `serialize_entry` map per key in `sniffer.rs` and `blocks.rs`, and hostd hand-wrote the matching
/// subscripts and `CodingKey` enums in `SniffedEvent.swift` and `BlockEvent.swift` — and nothing
/// compared the two spellings, because each end's suite read only its own end. A rename passed both
/// suites green while every finished command decoded as still running (docs/51 §6.13) or the
/// Commands panel filled with blank rows (§6.14).
///
/// Both directions are `slopdesk-superwire`'s now — [`sniffwire`][RUST_SNIFFWIRE] and
/// [`blockwire`][RUST_BLOCKWIRE] serialize and deserialize the same declarations, which superd
/// links and hostd reaches through `slopdesk-ffi`'s batch doors. There is no second alphabet to
/// compare against, so the eleven claims are gone.
///
/// What replaces them is what a comparison never covered anyway. The wire is not only read by THIS
/// build: superd outlives hostd's, so a rename that moves both directions at once in one commit is
/// still a skew against every superd already running at somebody's login. The only thing that
/// catches that is a LITERAL — each module carries one golden test asserting the exact bytes the
/// wire has always carried. Delete it and a rename becomes invisible again, which is precisely the
/// state this gate was written to end, so its presence is what is ratcheted here.
///
/// The second half is the one-implementation ratchet under it: a `serialize_entry` back in superd's
/// own `sniffer.rs` or `blocks.rs` is the hand-written map returning as a second spelling, which is
/// how the eleven claims became necessary the first time. Both files re-export from `superwire`
/// now and neither writes JSON.
#[must_use]
pub fn batch_bodies(tree: &Tree) -> Report {
    let claims = [
        Claim::Matches {
            path: RUST_SNIFFWIRE,
            pattern: GOLDEN,
            view: View::Code,
            message: "the sniff body has no golden literal left — a renamed key is invisible again to every \
                      superd already running (docs/51 §6.13)",
        },
        Claim::Matches {
            path: RUST_BLOCKWIRE,
            pattern: GOLDEN,
            view: View::Code,
            message: "the block body has no golden literal left — a renamed commandText fills the Commands \
                      panel with blank rows and fails nothing (docs/51 §6.14)",
        },
        Claim::NoneOf {
            paths: &[RUST_SNIFFER, RUST_BLOCKS],
            pattern: r"serialize_entry",
            view: View::Code,
            message: "{files} hand-writes a batch body again — slopdesk-superwire owns both directions, and \
                      a second spelling is the drift eleven claims used to chase (CLAUDE.md)",
        },
    ];
    check_all(tree, &claims)
}

/// §5 — the PTY read chunk, a joint decision rather than a wire constant.
///
/// superd alone reads with it, but hostd's copy is what the bounded-queue sizing is reasoned
/// against. 32 KiB is half `MuxFlowControl::host_queue_capacity_bytes`, so the gate's worst
/// overshoot is capacity plus one read. Raising one without the other silently re-opens a problem
/// that was solved once: a read larger than the bound pauses on every flood chunk.
///
/// This claim was Swift↔Rust until `docs/60` F.9. It did not become redundant when the Swift end
/// died, because the constant is still written TWICE — `slopdesk-hostpane` sizes the subscription
/// with it and `slopdesk-superd` reads with it, and neither crate depends on the other, so nothing
/// in the build graph makes a rename in one land in the other. `SameValue`'s two sides are named
/// `swift`/`rust` for the common case; here they are both Rust and only the PATHS matter.
#[must_use]
pub fn read_chunk(tree: &Tree) -> Report {
    let claims = [Claim::SameValue {
        label: "PTY read chunk",
        swift: Extract::code(
            "rust/slopdesk-hostpane/src/stream.rs",
            r"READ_CHUNK_BYTES: usize = (.*);$",
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
///
/// All three read [`HOSTD_CRATES`](crate::paths::HOSTD_CRATES) rather than `Sources` since
/// `docs/60` F.9. Each is a contract between hostd and a process it does not link, so moving hostd
/// to Rust moved the code without giving any compiler a way to see the rule.
#[must_use]
pub fn host_owes_superd(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneUnder {
            roots: HOSTD_CRATES,
            extensions: RUST,
            pattern: r"\b(read|poll|select)\([^)]*master",
            all: &[],
            unless: &["READ_CHUNK_BYTES"],
            view: View::Code,
            exempt: &[],
            message: "{files} reads or polls a PTY master — superd owns the read side (CLAUDE.md, docs/51 \
                      §6.5)",
        },
        Claim::NoneUnder {
            roots: HOSTD_CRATES,
            extensions: RUST,
            pattern: r"\.sock",
            all: &[r"getpid|process::id\(\)"],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a unix socket path in {files} carries a pid — a survivor holds an address nobody will \
                      rebind (docs/51 §1)",
        },
        Claim::Lacks {
            path: "rust/slopdesk-hostd/src/main.rs",
            pattern: r"panels\.(code|simulator|android)\.shutdown\(\)",
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

    /// A tree where both wire modules carry their golden literal and superd writes no JSON.
    fn bodies_fixture(name: &str) -> Fixture {
        let golden = "#[test]\nfn every_event_serialises_to_the_shape_the_wire_has_always_carried() {}\n";
        let fixture = Fixture::new(name);
        fixture
            .write("rust/slopdesk-superwire/src/sniffwire.rs", golden)
            .write("rust/slopdesk-superwire/src/blockwire.rs", golden)
            .write(
                "rust/slopdesk-superd/src/sniffer.rs",
                "pub use slopdesk_superwire::sniffwire::SniffEvent;\n",
            )
            .write(
                "rust/slopdesk-superd/src/blocks.rs",
                "pub use slopdesk_superwire::blockwire::BlockEvent;\n",
            );
        fixture
    }

    /// The §6.13 failure, in the only form it still has. Both directions move together now, so the
    /// skew is against the superd already RUNNING — and the literal is the only thing that sees it.
    #[test]
    fn deleting_a_golden_literal_is_caught() {
        let fixture = bodies_fixture("golden-gone");
        assert!(super::batch_bodies(&fixture.tree()).is_clean());

        fixture.write("rust/slopdesk-superwire/src/sniffwire.rs", "// nothing left\n");
        let report = super::batch_bodies(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("no golden literal")),
            "{report:?}",
        );
    }

    /// The one-implementation half: a hand-written map back in superd is the second spelling that
    /// made eleven alphabet claims necessary the first time.
    #[test]
    fn a_hand_written_batch_body_back_in_superd_is_caught() {
        let fixture = bodies_fixture("second-spelling");
        fixture.write(
            "rust/slopdesk-superd/src/sniffer.rs",
            "map.serialize_entry(\"state\", &v)?;\n",
        );
        let report = super::batch_bodies(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("sniffer.rs")),
            "{report:?}",
        );
    }

    /// A tree shaped the way hostd is now: the stop path relinquishes, and the one line that names
    /// both a master and a read is the SIZING comment in `hostpane`, which the `unless` spares.
    ///
    /// Every seed below is Rust — `.rs` paths under [`HOSTD_CRATES`](crate::paths::HOSTD_CRATES),
    /// `snake_case` fields, `std::process::id()` rather than `processIdentifier`. A mechanically
    /// translated Swift pattern would match none of it and pass while guarding nothing.
    fn hostd_fixture(name: &str) -> Fixture {
        let fixture = Fixture::new(name);
        fixture
            .write(
                "rust/slopdesk-hostd/src/main.rs",
                "panels.code.relinquish();\npanels.simulator.relinquish();\npanels.android.relinquish();\n",
            )
            .write(
                "rust/slopdesk-hostpane/src/stream.rs",
                "// one read(&self.master) in superd is at most READ_CHUNK_BYTES\npub const \
                 READ_CHUNK_BYTES: usize = 32 * 1024;\n",
            );
        fixture
    }

    /// The invariant the whole subsystem turns on. A second reader on the master does not observe
    /// the stream, it steals from it.
    #[test]
    fn a_second_reader_on_the_master_is_caught_and_the_chunk_size_is_not() {
        let fixture = hostd_fixture("master-read");
        assert!(super::host_owes_superd(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-hostpane/src/bad.rs",
            "let n = read(&self.master, &mut buf)?;\n",
        );
        let report = super::host_owes_superd(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("bad.rs")),
            "{report:?}"
        );
    }

    /// superd is the ONE process allowed to read a master, and it is outside the roots on purpose —
    /// a rule scoped to all of `rust` would fire on the only correct reader in the repo.
    #[test]
    fn superds_own_read_is_not_caught() {
        let fixture = hostd_fixture("superd-reads");
        fixture.write(
            "rust/slopdesk-superd/src/pump.rs",
            "let got = read(&self.master, &mut buffer)?;\n",
        );
        assert!(super::host_owes_superd(&fixture.tree()).is_clean());
    }

    /// A pid in a socket path leaves a survivor dialling an address nobody will rebind.
    #[test]
    fn a_pid_keyed_socket_path_is_caught() {
        let fixture = hostd_fixture("pid-sock");
        assert!(super::host_owes_superd(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-hostserver/src/bridge.rs",
            "let path = format!(\"/tmp/bridge-{}.sock\", std::process::id());\n",
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
        let fixture = hostd_fixture("relinquish");
        assert!(super::host_owes_superd(&fixture.tree()).is_clean());

        fixture.write("rust/slopdesk-hostd/src/main.rs", "panels.code.shutdown();\n");
        let report = super::host_owes_superd(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("TERMINATES")),
            "{report:?}"
        );
    }

    /// The read chunk is written twice in Rust and neither crate depends on the other, so the claim
    /// survived F.9 rather than dying with its Swift end. Drift one and the gate says so.
    #[test]
    fn a_read_chunk_that_moved_in_one_crate_only_is_caught() {
        let fixture = Fixture::new("read-chunk");
        fixture
            .write(
                "rust/slopdesk-hostpane/src/stream.rs",
                "pub const READ_CHUNK_BYTES: usize = 32 * 1024;\n",
            )
            .write(
                "rust/slopdesk-superd/src/pump.rs",
                "pub const READ_CHUNK_BYTES: usize = 32 * 1024;\n",
            );
        assert!(super::read_chunk(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-superd/src/pump.rs",
            "pub const READ_CHUNK_BYTES: usize = 64 * 1024;\n",
        );
        assert!(!super::read_chunk(&fixture.tree()).is_clean());
    }
}
