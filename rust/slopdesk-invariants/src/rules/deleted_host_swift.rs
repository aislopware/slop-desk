//! The seven things hostd used to do in Swift and a sidecar or a Rust crate does now, and the two
//! flags that ask for two of them.
//!
//! Every ban here is a port that DELETED its original (`CLAUDE.md`, one implementation). What makes
//! each worth a ratchet rather than a comment is that the Swift version would still work — it would
//! simply be a second reader, a second parser or a second copy of a list, drifting from the one
//! that ships. None of the seven fails a test in either language, because each side stays
//! internally consistent; the drift is between them.
//!
//! Read `View::Code`, like every other ban in this crate: the prose above a ban names the thing it
//! forbids, and a raw read would fire on the explanation.

use crate::claim::{Claim, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// hostd's half of the spawn request.
const SWIFT_PROTOCOL: &str = "Sources/SlopDeskSupervisor/SupervisorProtocol.swift";

/// superd's half of the same request.
const RUST_PROTOCOL: &str = "rust/slopdesk-superd/src/protocol.rs";

/// The engines, parsers and taps that moved into a sidecar, and may not come back.
///
/// ## Why each one left
///
/// **The detection ladder.** The manifest schema, its TOML parser, the region resolver, the rule
/// engine, the bundled manifests, the explain trace, the OSC tracker and the sync-frame tracker
/// moved into screend's `detect` verb and were DELETED here in the same change (`docs/50` §3,
/// `docs/52`). The temporal layer did NOT move and is not named: `AgentDetectionHold` and
/// `PaneScreenScanner` are hostd's, because screend owns everything that reads the BYTES and hostd
/// owns everything that reads the CLOCK. `ClaudeManifestMatcher` is named for a different reason —
/// it was a SECOND screen matcher in Swift, three tables of literal Claude cues next to a
/// nineteen-agent rule ladder. Its process-name half outlived it for a while as
/// `ClaudeProcessMatcher`, a wrapper over the crate's own predicates; that wrapper is gone too, so
/// neither half may come back under either name.
///
/// **The `ZDOTDIR` shim.** It moved into superd for a reason hostd cannot argue with: the generated
/// directory's lifetime is exactly the child's, and superd is the only process that outlives a
/// hostd restart and can therefore delete it at all. In hostd it needed three separate cleanup
/// sites — spawn failure, session teardown, orphan sweep — and still leaked the directory outright
/// whenever hostd was killed.
///
/// **The OSC sniffer.** It read EVERY byte of EVERY pane, in Swift, on the read-loop thread — while
/// superd's pump already held those bytes with no copy and no round trip. Two state machines over
/// one stream drift silently: hostd would latch a title superd never dropped, or dedupe one it did.
///
/// **The command-block tap.** Same argument, plus one only it has: hostd used to HOLD every
/// finished command's captured output, and that ring died on every rebuild — a client reattaching
/// after a `make host-restart` found an empty Commands panel for a shell that had never stopped.
/// superd's pump segments and retains (`rust/slopdesk-superd/src/blocks.rs`, `docs/51` §6.14).
///
/// **The auto-progress list.** The bridge crosses UNPARSED and must keep doing so: superd owns both
/// the parse and the built-in slow-command list, and a hostd that resolved either would be the
/// second copy of a list whose whole point (`docs/DECISIONS`, 2026-08-10) is that it is the only
/// copy of itself.
///
/// **The PTY size fold.** Who votes on a pane's grid, what that folds to, and when a change is
/// worth settling for (docs/45 §8.3) moved into `rust/slopdesk-muxsession`'s `resize_fold` and were
/// deleted here in the same change. What did NOT move is the `TIOCSWINSZ` and the two `Task`s: the
/// descriptor cannot cross and the timers should not. A second fold in Swift is the drift this ban
/// exists for — it would still resolve a grid, and it would disagree with the one the roster
/// publishes about who is contributing.
///
/// **The manifests themselves.** They live ONCE, as the TOML files they already are. A Swift source
/// carrying manifest rule text is the mirror in its most tempting form: it looks like data, not
/// code.
#[must_use]
pub fn deleted_host_swift(tree: &Tree) -> Report {
    let claims =
        [
            Claim::NoneUnder {
                roots: &["Sources"],
                extensions: SWIFT,
                pattern: r"(enum|struct|final class|class|actor) (AgentManifest|CompiledAgentManifest|AgentManifestCatalog|TOMLSubsetParser|ManifestRegion|ManifestRuleEngine|BundledAgentManifests|AgentDetectionExplain|AgentOscTracker|AgentSyncFrameTracker|ClaudeManifestMatcher)\b",
                all: &[],
                unless: &[],
                view: View::Code,
                exempt: &[],
                message: "a Swift screen-detection engine is back in {files} — screend's detect verb owns \
                          the ladder (docs/50 §3)",
            },
            Claim::NoneUnder {
                roots: &["Sources"],
                extensions: SWIFT,
                pattern: r"(enum|struct|final class|class|actor) ShellIntegration\b|slopdesk-zdotdir-",
                all: &[],
                unless: &[],
                view: View::Code,
                exempt: &[],
                message: "the ZDOTDIR shim is back in {files} — superd owns it \
                          (rust/slopdesk-superd/src/shellintegration.rs)",
            },
            Claim::NoneUnder {
                roots: &["Sources"],
                extensions: SWIFT,
                pattern: r"(enum|struct|final class|class|actor) (HostOutputSniffer|OutputSniffer)\b",
                all: &[],
                unless: &[],
                view: View::Code,
                exempt: &[],
                message: "the OSC sniffer is back in {files} — superd owns it \
                          (rust/slopdesk-superd/src/sniffer.rs)",
            },
            Claim::NoneUnder {
                roots: &["Sources"],
                extensions: SWIFT,
                pattern: r"(enum|struct|final class|class|actor) (CommandBlockSegmenter|CommandBlockTracker|AutoProgressMatcher)\b",
                all: &[],
                unless: &[],
                view: View::Code,
                exempt: &[],
                message: "the command-block tap is back in {files} — superd owns it \
                          (rust/slopdesk-superd/src/blocks.rs)",
            },
            Claim::NoneUnder {
                roots: &["Sources"],
                extensions: SWIFT,
                pattern: r"autoProgressCommands: \[String\]|autoProgressPrefixes",
                all: &[],
                unless: &[],
                view: View::Code,
                exempt: &[],
                message: "hostd is parsing SLOPDESK_AUTO_PROGRESS_COMMANDS in {files} — the raw value \
                          crosses, superd parses it",
            },
            Claim::NoneUnder {
                roots: &["Sources"],
                extensions: SWIFT,
                pattern: r"struct ResizeContribution\b|func (foldOffers|creditsOffer|contributingCountLocked)\b",
                all: &[],
                unless: &[],
                view: View::Code,
                exempt: &[],
                message: "the PTY size fold is back in {files} — rust/slopdesk-muxsession owns the \
                          arithmetic                       and hostd owns only the TIOCSWINSZ (docs/45 §8.3)",
            },
            Claim::NoneUnder {
                roots: &["Sources"],
                extensions: SWIFT,
                pattern: r"\[\[rules\]\]|min_engine_version\s*=|skip_state_update\s*=|line_regex\s*=",
                all: &[],
                unless: &[],
                view: View::Code,
                exempt: &[],
                message: "manifest TOML is back in {files} — it lives in rust/slopdesk-screend/manifests \
                          (docs/52)",
            },
        ];
    check_all(tree, &claims)
}

/// The two request flags hostd still sends, spelled the same way at both ends.
///
/// hostd may still ASK for the shim and for the tap, and each request has to reach superd spelled
/// identically or the feature silently never engages with no error anywhere. Both are AT-SPAWN
/// decisions — a segmenter cannot be attached to a shell already running, and the shim writes rc
/// files before the shell reads them — so a flag that fails to cross is a pane that is never
/// segmented, and never has a prompt reprint or an OSC 133 mark, for its whole life.
#[must_use]
pub fn spawn_request_flags_cross(tree: &Tree) -> Report {
    let claims = [
        Claim::Matches {
            path: SWIFT_PROTOCOL,
            pattern: r"public var shellIntegration: Bool",
            view: View::Code,
            message: "the spawn request's shellIntegration flag is not spelled on the Swift side — the shim \
                      would silently never install",
        },
        Claim::Matches {
            path: RUST_PROTOCOL,
            pattern: r#"rename = "shellIntegration""#,
            view: View::Code,
            message: "the spawn request's shellIntegration flag is not spelled on the Rust side — the shim \
                      would silently never install",
        },
        Claim::Matches {
            path: SWIFT_PROTOCOL,
            pattern: r"public var blocks: BlocksRequest\?",
            view: View::Code,
            message: "the spawn request's blocks tap is not spelled on the Swift side — a pane can only be \
                      tapped at spawn, so it would never be segmented",
        },
        Claim::Matches {
            path: RUST_PROTOCOL,
            pattern: r"pub blocks: Option<BlocksRequest>",
            view: View::Code,
            message: "the spawn request's blocks tap is not spelled on the Rust side — a pane can only be \
                      tapped at spawn, so it would never be segmented",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use super::{deleted_host_swift, spawn_request_flags_cross};
    use crate::tests::Fixture;

    /// One tree per ban, seeded with the shape the port deleted.
    #[test]
    fn a_revived_engine_is_red() {
        for (name, line) in [
            ("detect", "final class ManifestRuleEngine {}\n"),
            ("shim", "enum ShellIntegration {}\n"),
            ("sniffer", "actor HostOutputSniffer {}\n"),
            ("blocks", "struct CommandBlockSegmenter {}\n"),
            ("autoprogress", "let autoProgressCommands: [String] = []\n"),
            ("manifest", "let body = \"\"\"\\n[[rules]]\\n\"\"\"\n"),
            ("resizefold", "struct ResizeContribution {}\n"),
            ("resizefoldfn", "    private static func foldOffers() {}\n"),
        ] {
            let fixture = Fixture::new(&format!("deleted-host-{name}"));
            fixture.write("Sources/SlopDeskHost/A.swift", "let ordinary = 1\n");
            assert!(
                deleted_host_swift(&fixture.tree()).is_clean(),
                "{name}: an ordinary tree is not a violation"
            );
            fixture.append("Sources/SlopDeskHost/A.swift", line);
            assert!(
                !deleted_host_swift(&fixture.tree()).is_clean(),
                "{name}: the ban did not fire on {line:?}"
            );
        }
    }

    /// The prose that EXPLAINS a ban is not the ban — `View::Code` is what makes the doc above one
    /// of these safe to write.
    #[test]
    fn a_comment_naming_a_deleted_type_is_not_a_revival() {
        let fixture = Fixture::new("deleted-host-comment");
        fixture.write(
            "Sources/SlopDeskHost/A.swift",
            "// `final class HostOutputSniffer` used to live here; superd owns it now.\nlet x = 1\n",
        );
        assert!(deleted_host_swift(&fixture.tree()).is_clean());
    }

    /// A flag spelled on one side only is the silent half-crossing the rule exists for.
    #[test]
    fn a_flag_spelled_on_one_side_only_is_red() {
        let fixture = Fixture::new("spawn-flags");
        fixture.write(
            "Sources/SlopDeskSupervisor/SupervisorProtocol.swift",
            "public var shellIntegration: Bool = false\npublic var blocks: BlocksRequest?\n",
        );
        fixture.write(
            "rust/slopdesk-superd/src/protocol.rs",
            "#[serde(rename = \"shellIntegration\")]\npub blocks: Option<BlocksRequest>,\n",
        );
        assert!(spawn_request_flags_cross(&fixture.tree()).is_clean());

        let half = Fixture::new("spawn-flags-half");
        half.write(
            "Sources/SlopDeskSupervisor/SupervisorProtocol.swift",
            "public var shellIntegration: Bool = false\npublic var blocks: BlocksRequest?\n",
        );
        half.write(
            "rust/slopdesk-superd/src/protocol.rs",
            "pub blocks: Option<BlocksRequest>,\n",
        );
        assert!(!spawn_request_flags_cross(&half.tree()).is_clean());
    }
}
