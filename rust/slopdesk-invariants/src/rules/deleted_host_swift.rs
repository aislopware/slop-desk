//! The things hostd used to do in Swift and a sidecar or a Rust crate does now, and the two flags
//! that ask for two of them.
//!
//! Every ban here is a port that DELETED its original (`CLAUDE.md`, one implementation). What makes
//! each worth a ratchet rather than a comment is that the Swift version would still work — it would
//! simply be a second reader, a second parser or a second copy of a list, drifting from the one
//! that ships. Not one of them fails a test in either language, because each side stays internally
//! consistent; the drift is between them.
//!
//! **The project key, the logical-line split and the finished turn.** The `.git` ancestor walk, the
//! `realpath` in front of it, the hard-newline split behind `read --unwrapped`, and the transition
//! that mints one `pane/completionEpoch` all became Rust in one change: `slopdesk-git`'s
//! `project_key`, `slopdesk-sanitize`'s `lines`, and `slopdesk-agent`'s `mints_finished_turn`.
//! Each was a rule an orchestrator's answer turns on, and each had a Swift twin that could drift
//! silently — a second canonical form keys one repository as two sidebar sections, and a second
//! reading of "a turn ended" mints an unread badge nobody earned.
//!
//! Read `View::Code`, like every other ban in this crate: the prose above a ban names the thing it
//! forbids, and a raw read would fire on the explanation.

use crate::claim::{Claim, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// hostd's vocabulary — the plain values it asks with, carrying no wire spelling.
const SWIFT_MESSAGES: &str = "Sources/SlopDeskSupervisor/SupervisorMessages.swift";

/// The doors those values cross on their way to the encoder.
const SWIFT_DOORS: &str = "Sources/SlopDeskSupervisor/SupervisorDoors.swift";

/// The encoder itself — where a Swift field becomes a request field.
const RUST_FFI: &str = "rust/slopdesk-ffi/src/supervisor_protocol.rs";

/// The ONE spelling of the request superd reads.
const RUST_PROTOCOL: &str = "rust/slopdesk-superwire/src/protocol.rs";

/// The engines, parsers and taps that moved into a sidecar, and may not come back.
///
/// ## Why each one left
///
/// **The detection ladder.** The manifest schema, its TOML parser, the region resolver, the rule
/// engine, the bundled manifests, the explain trace, the OSC tracker and the sync-frame tracker
/// moved into screend's `detect` verb and were DELETED here in the same change (`docs/50` §3,
/// `docs/52`). The TEMPORAL layer followed later, and the split it was named for survived it:
/// screend still owns everything that reads the BYTES and hostd still owns everything that reads
/// the CLOCK — what changed is the LANGUAGE of the clock half, which is `slopdesk-agent`'s
/// `panescan` now. hostd keeps the socket, because it is the process holding the connection; what
/// it may not keep is a second copy of when to publish. `ClaudeManifestMatcher` is named for a
/// different reason — it was a SECOND screen matcher in Swift, three tables of literal Claude cues
/// next to a nineteen-agent rule ladder. Its process-name half outlived it for a while as
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
    let mut claims = engines_and_taps();
    claims.extend(rules_that_moved_to_rust());
    claims.extend(terminfo_files_stay_deleted());
    claims.extend(supervisor_protocol_stays_deleted());
    check_all(tree, &claims)
}

/// The two files the terminfo LINK deleted, named as paths because neither has a keyword left.
///
/// `TerminfoResolver` was a wrapper around a FORK of `slopdesk-probe terminfo`; the wrapper's whole
/// job — hand the probe two names, map its answer back to an enum — stopped existing when the
/// module became a linked door, so what would come back is not a second rule but a second HOP. And
/// the enum it mapped to, `ClaudeCodeProfile.Term`, was the closed two-case list the crate would
/// have had to agree with; the two names live on `HostEnvironment` as strings for exactly that
/// reason.
///
/// A ban on a TYPE name is the right shape when what may not come back is a second engine. Here
/// what may not come back is a second SPELLING of a wire that is now declared once, in
/// `slopdesk-superwire`, and reached through `slopdesk-ffi`'s doors. That is a file, not a symbol:
/// re-adding `SupervisorProtocol.swift` with one `CodingKey` in it is the whole failure, and it has
/// no keyword a pattern could catch. Eleven `slopdesk-invariants` claims existed to compare these
/// files against superd's; they are gone, and these three absences are what stands in their place
/// (`CLAUDE.md`, one implementation).
fn terminfo_files_stay_deleted() -> Vec<Claim> {
    vec![
        Claim::Absent {
            path: "Sources/SlopDeskHost/TerminfoResolver.swift",
            message: "hostd is resolving TERM in Swift again — slopdesk-probe's terminfo module is the rule \
                      and HostEnvironment.resolveTerm LINKS it, so there is no fork left to wrap",
        },
        Claim::Absent {
            path: "Sources/SlopDeskHost/ClaudeCodeProfile.swift",
            message: "the TERM enum is back — hostd advertises two NAMES (HostEnvironment.defaultTerm and \
                      fallbackTerm) and the resolution takes strings, so a two-case enum is a closed list \
                      the crate would have to agree with",
        },
    ]
}

/// The three files the superd-protocol fold deleted, named as paths rather than as patterns.
fn supervisor_protocol_stays_deleted() -> Vec<Claim> {
    vec![
        Claim::Absent {
            path: "Sources/SlopDeskSupervisor/SupervisorProtocol.swift",
            message: "hostd is spelling superd's protocol again — the vocabulary is slopdesk-superwire's, \
                      reached through slopdesk-ffi (docs/55)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskSupervisor/SniffedEvent.swift",
            message: "hostd is decoding the 0x04 body again — slopdesk-superwire::sniffwire owns both \
                      directions, and a second reading is the §6.13 spinner that never comes down",
        },
        Claim::Absent {
            path: "Sources/SlopDeskSupervisor/BlockEvent.swift",
            message: "hostd is decoding the 0x05 body again — slopdesk-superwire::blockwire owns both \
                      directions, and a second reading is the §6.14 panel of blank rows",
        },
    ]
}

/// The bans themselves, listed apart from the walk that runs them: each port adds a claim, and a
/// function that grew by one claim per port is the one thing about this file that should not grow.
fn engines_and_taps() -> Vec<Claim> {
    vec![
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"(enum|struct|final class|class|actor) (AgentManifest|CompiledAgentManifest|AgentManifestCatalog|TOMLSubsetParser|ManifestRegion|ManifestRuleEngine|BundledAgentManifests|AgentDetectionExplain|AgentOscTracker|AgentSyncFrameTracker|ClaudeManifestMatcher)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift screen-detection engine is back in {files} — screend's detect verb owns the \
                      ladder (docs/50 §3)",
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
            message: "hostd is parsing SLOPDESK_AUTO_PROGRESS_COMMANDS in {files} — the raw value crosses, \
                      superd parses it",
        },
    ]
}

/// The bans for rules that became Rust FUNCTIONS rather than daemons: arithmetic and walks
/// hostd used to do in Swift, each behind a door now.
///
/// **The curated spawn environment.** The allowlist NAMES twelve variables, and the whole point of
/// the module is that the list is closed and lives in one place. A Swift copy would still spawn a
/// working shell — it would simply mirror eleven keys, or set `TERM_PROGRAM` from the launcher, and
/// the failure is an Amazon-Q/Fig hook re-execing a nested pseudo-terminal mid-`.zshrc` on the
/// machines that have it and nowhere else.
///
/// **The host vitals.** Four Mach/`sysctl` readings and the arithmetic over them: which pages count
/// as "used", whether a percent may be computed across a given window, and what a sparse pressure
/// ladder means. Every one of those is a number a client DRAWS, and a second version of any of them
/// disagrees quietly — an Activity-Monitor-shaped memory reading against one that counts the file
/// cache differs by fifty points on a healthy Mac and neither side can tell which is wrong.
///
/// **The three-source pause fold.** The queue bound, the replay cap and the fan-out backlog, OR-ed,
/// with the memory of what was last applied. What stays hostd's is the `NSLock` and the `setPaused`
/// sink — the atomicity FIX #3 was about. The fold itself deciding differently on the two sides is
/// a pane whose read loop is paused while its queue is empty, which is the exact freeze that fix
/// exists to end.
///
/// **The vendored-prefix walk.** The marker, the upward loop and the two paths that hang off it sit
/// next to the binary SEARCH ORDER whose second rung they fill. Split across languages, the rung
/// and the thing that fills it could disagree about what a checkout root even is.
///
/// The SPLIT below is that distinction, not a length workaround: every claim in
/// [`folds_that_moved_to_rust`] bans a DECISION from being spelled twice, and the one in
/// [`resources_that_moved_to_rust`] bans a system RESOURCE from being acquired on the wrong side.
/// The two fail for different reasons and a new rule belongs in exactly one of them.
///
/// **hostd's own launch.** The argv grammar and the launch record are one domain and were spelled
/// in three places: a Swift parser, a Swift `Codable` struct, and a hand-written Rust reader in
/// `slopdesk-devtools` for the same eight fields. All three compiled, all three passed, and a
/// rename on any one of them would have broken `restart-hostd` with nothing turning red. The
/// grammar's flags and the record's file name are banned here because they are the anchors a
/// revival would have to write; `rust/slopdesk-hostlaunch` is the one declaration both ends read.
///
/// **The PTY echo probe.** Not the `tcgetattr` — the client's own `SlopDeskTTY` still makes that
/// call about its own terminal, which is a different question — but the two termios bits and what
/// they MEAN. `ECHO` cleared is not a secret on its own: a line editor and every full-screen TUI
/// clear it too, which is why an ECHO-only rule latched the Secure-Input pill on every ordinary
/// prompt. The discrimination is `slopdesk-posix`'s and the edge is `slopdesk-terminal`'s.
///
/// **The two sleep assertions.** This one is not a drift ban, and saying so is the point: an
/// `IOPMAssertion` created in Swift would not disagree with anything — it would simply be a second
/// create with no paired release anybody wrote, and the failure it causes has no test that turns
/// red. A leaked `PreventUserIdleSystemSleep` keeps the Mac awake until the daemon dies, and it
/// does NOT self-heal on the next clean transition. So the assertion is `slopdesk-apple-power`'s,
/// held by a type that owns the only copy of the id and releases on drop, and the two folds that
/// decide when to hold one are `slopdesk-agent`'s `sleep` and `slopdesk-video`'s `display_wake`.
/// What is left in Swift is a lock over a handle. See `docs/57` §1 for why this crate exists now
/// and did not before.
fn rules_that_moved_to_rust() -> Vec<Claim> {
    let mut claims = folds_that_moved_to_rust();
    claims.extend(resources_that_moved_to_rust());
    claims
}

/// The DECISIONS: each of these fails because the same rule spelled twice can answer differently,
/// and the two answers are the bug. See [`rules_that_moved_to_rust`] for what each one is.
///
/// Split by what the fold is ABOUT, which is also where a new one belongs: [`pane_shape_folds`]
/// answers a question about what ONE pane IS — its size, its project, its shell's environment, its
/// queue, its line discipline; [`pane_activity_folds`] answers one about what that pane is DOING —
/// its turn, what its screen means, when to look again, whether it is free to take a command; and
/// [`machine_folds`] answers one about the machine or about this daemon itself. The three have
/// different blast radii and no list is a bucket for another's overflow.
fn folds_that_moved_to_rust() -> Vec<Claim> {
    let mut claims = pane_shape_folds();
    claims.extend(pane_activity_folds());
    claims.extend(machine_folds());
    claims
}

/// The folds about what ONE pane IS. See [`folds_that_moved_to_rust`] for the split.
fn pane_shape_folds() -> Vec<Claim> {
    vec![
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"struct ResizeContribution\b|func (foldOffers|creditsOffer|contributingCountLocked)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the PTY size fold is back in {files} — rust/slopdesk-muxsession owns the arithmetic \
                      and hostd owns only the TIOCSWINSZ (docs/45 §8.3)",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"func (canonicalCwd|unwrapLogicalLines)\b|(enum|struct) ProjectKeyResolver\b|isRepoRoot:",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &["Sources/SlopDeskHost/RepoStatusWatcher.swift"],
            message: "a pane's project key or its logical-line split is back in {files} — \
                      rust/slopdesk-git's project_key walks it and rust/slopdesk-sanitize's lines splits \
                      it, each behind one door",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r#""NCURSES_NO_UTF8_ACS"|"CW_TERM"|"TERMINFO_DIRS""#,
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the curated spawn environment is back in {files} — rust/slopdesk-muxsession's \
                      spawn_env names the twelve keys, and hostd passes the parent WHOLE",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"outstanding >= capacity|replayPause \|\||fanoutBacklog >=",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the three-source pause fold is back in {files} — rust/slopdesk-wire's \
                      mux::flow::PausableQueueGate ORs them and hostd owns only the lock and the sink",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"tcflag_t\((ECHO|ICANON)\)",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the PTY echo probe is back in {files} — rust/slopdesk-posix's pty reads the two \
                      termios bits and rust/slopdesk-terminal's echo decides the edge; an ECHO-only rule \
                      spelled here is the bug that latched the client's Secure-Input pill on every ordinary \
                      zsh prompt",
        },
    ]
}

/// The folds about what ONE pane is DOING. See [`folds_that_moved_to_rust`] for the split.
fn pane_activity_folds() -> Vec<Claim> {
    vec![
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"next == \.done \{ return previous != \.done \}|previous == \.working \|\| previous == \.needsPermission",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "what mints a finished turn is spelled in Swift again in {files} — \
                      slopdesk_agent_finished_turn is the rule (rust/slopdesk-agent, attention)",
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
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"func (shouldHoldWorkingToIdle|shouldHoldBlockedToIdle|stableVisibleSignalRefreshDue)\b|awaitingRepaintAfterRebuild|syncFrameOpenSince",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the pane scan's temporal layer is back in {files} — rust/slopdesk-agent's panescan \
                      sequences the tick and hostd owns only the screend socket; a second copy of the \
                      working-to-idle hold is a pane that publishes an idle screend never confirmed",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"static let shellNames|func sharedComponents\b|no terminal pane is open in this project",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the code bridge's pane choice is back in {files} — rust/slopdesk-muxsession's \
                      bridge_router owns the two safety gates and the ranking, and a second shell list here \
                      is a command typed at an agent's prompt",
        },
    ]
}

/// The folds about the MACHINE, or about this daemon's own launch. See
/// [`folds_that_moved_to_rust`].
fn machine_folds() -> Vec<Claim> {
    vec![
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"HOST_CPU_LOAD_INFO|HOST_VM_INFO64|host_statistics64?\(|memorystatus_vm_pressure_level|f_bavail",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the host-vitals readings are back in {files} — rust/slopdesk-posix makes the four \
                      syscalls and rust/slopdesk-panecensus's vitals interprets them",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r#"(enum|struct) (TerminfoResolver|ClaudeCodeProfile)\b|"terminfo", "--requested""#,
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the TERM resolution is back in {files} — slopdesk-probe's terminfo module decides it \
                      and HostEnvironment.resolveTerm LINKS that module rather than forking the probe; the \
                      two names hostd advertises are the only part of it that is Swift's",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"ThirdParty/tools",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the vendored-prefix walk is back in {files} — rust/slopdesk-androidd's toolchain owns \
                      the marker and the two paths, next to the search order they fill",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r#"case "--inspector"|case "--transcript"|struct HostLaunchRecord\b|hostd-launch\.json|_NSGetExecutablePath"#,
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "hostd's launch is spelled in Swift again in {files} — rust/slopdesk-hostlaunch owns \
                      the argv grammar AND the record's eight fields, and slopdesk-devtools READS that \
                      record; a second declaration here is the rename that compiles, passes and silently \
                      breaks `slopdesk-ops restart-hostd`",
        },
    ]
}

/// The RESOURCES: acquiring one on the Swift side is not a disagreement, it is an acquisition
/// nobody paired with a release. Nothing turns red for it — see [`rules_that_moved_to_rust`].
fn resources_that_moved_to_rust() -> Vec<Claim> {
    vec![Claim::NoneUnder {
        roots: &["Sources"],
        extensions: SWIFT,
        pattern: r"IOPMAssertion|kIOPMAssertion|IOKit\.pwr_mgt",
        all: &[],
        unless: &[],
        view: View::Code,
        exempt: &[],
        message: "an IOPMAssertion is back in {files} — slopdesk-apple-power holds both sleep assertions, \
                  and the two folds that decide when live in slopdesk-agent's sleep and slopdesk-video's \
                  display_wake; a create in Swift is the leak that keeps the Mac awake",
    }]
}

/// The two request flags hostd still sends, and every hop each one has to survive.
///
/// hostd may still ASK for the shim and for the tap, and each request has to reach superd or the
/// feature silently never engages with no error anywhere. Both are AT-SPAWN decisions — a segmenter
/// cannot be attached to a shell already running, and the shim writes rc files before the shell
/// reads them — so a flag that fails to cross is a pane that is never segmented, and never has a
/// prompt reprint or an OSC 133 mark, for its whole life.
///
/// It used to be two hops, one spelling each side. The port made it four, and every one of them is
/// a place a `bool` can be dropped without a compiler saying anything: hostd's own value, the door
/// it is copied onto, the encoder that puts it in the request, and the field superd reads. The
/// middle two are the new ones and they are the quietest — `fields.shell_integration` left unset is
/// `false`, which is a perfectly valid request for a pane that wanted no shim.
///
/// The last hop is a `Claim::Absent` in [`deleted_host_swift`] rather than here: the file that used
/// to spell these on hostd's side is gone, and it staying gone is what keeps this four hops rather
/// than five.
#[must_use]
pub fn spawn_request_flags_cross(tree: &Tree) -> Report {
    let claims = [
        Claim::Matches {
            path: SWIFT_MESSAGES,
            pattern: r"public var shellIntegration: Bool",
            view: View::Code,
            message: "the spawn request's shellIntegration flag is not spelled in hostd's vocabulary — the \
                      shim would silently never install",
        },
        Claim::Matches {
            path: SWIFT_DOORS,
            pattern: r"fields\.shell_integration = request\.shellIntegration",
            view: View::Code,
            message: "the spawn request's shellIntegration flag never reaches the door — it encodes as \
                      false, which is a valid request for a pane that wanted no shim",
        },
        Claim::Matches {
            path: RUST_FFI,
            pattern: r"shell_integration: fields\.shell_integration",
            view: View::Code,
            message: "the encoder drops the shellIntegration flag — the request superd reads asks for no \
                      shim and nothing fails",
        },
        Claim::Matches {
            path: RUST_PROTOCOL,
            pattern: r#"rename = "shellIntegration""#,
            view: View::Code,
            message: "the spawn request's shellIntegration flag is not spelled on the wire — the shim would \
                      silently never install",
        },
        Claim::Matches {
            path: SWIFT_MESSAGES,
            pattern: r"public var blocks: BlocksRequest\?",
            view: View::Code,
            message: "the spawn request's blocks tap is not spelled in hostd's vocabulary — a pane can only \
                      be tapped at spawn, so it would never be segmented",
        },
        Claim::Matches {
            path: SWIFT_DOORS,
            pattern: r"fields\.blocks = request\.blocks != nil",
            view: View::Code,
            message: "the blocks tap never reaches the door — every pane encodes as untapped, so the \
                      Commands panel is empty for the life of the process",
        },
        Claim::Matches {
            path: RUST_FFI,
            pattern: r"blocks: fields\.blocks\.then",
            view: View::Code,
            message: "the encoder drops the blocks tap — a pane can only be tapped at spawn, so it would \
                      never be segmented",
        },
        Claim::Matches {
            path: RUST_PROTOCOL,
            pattern: r"pub blocks: Option<BlocksRequest>",
            view: View::Code,
            message: "the spawn request's blocks tap is not spelled on the wire — a pane can only be tapped \
                      at spawn, so it would never be segmented",
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
            ("projectkey", "enum ProjectKeyResolver {}\n"),
            ("logicallines", "    static func unwrapLogicalLines() {}\n"),
            (
                "finishedturn",
                "        if next == .done { return previous != .done }\n",
            ),
            ("spawnenv", "    env[\"NCURSES_NO_UTF8_ACS\"] = \"1\"\n"),
            (
                "vitals",
                "    let r = host_statistics(port, HOST_CPU_LOAD_INFO, p, &c)\n",
            ),
            ("pausefold", "    var wants: Bool { outstanding >= capacity }\n"),
            (
                "vendored",
                "    let bin = root + \"/ThirdParty/tools/.prefix/bin\"\n",
            ),
            (
                "preventsleep",
                "    let r = IOPMAssertionCreateWithName(t, l, n, &id)\n",
            ),
            (
                "hostdargs",
                "            case \"--transcript\": transcript = it.next()\n",
            ),
            ("launchrecord", "struct HostLaunchRecord: Codable {}\n"),
            (
                "recordpath",
                "    let p = dir.appendingPathComponent(\"hostd-launch.json\")\n",
            ),
            (
                "runningexe",
                "    if _NSGetExecutablePath(&buffer, &capacity) == 0 { return \"\" }\n",
            ),
            (
                "panescanhold",
                "    func shouldHoldWorkingToIdle() -> Bool { false }\n",
            ),
            ("panescanrebuild", "    var awaitingRepaintAfterRebuild = false\n"),
            (
                "bridgeshells",
                "    static let shellNames: Set<String> = [\"zsh\"]\n",
            ),
            (
                "bridgerefusal",
                "    let m = \"SlopDesk: no terminal pane is open in this project.\"\n",
            ),
            ("terminfo", "enum TerminfoResolver {}\n"),
            (
                "terminfofork",
                "    let a = ask([\"terminfo\", \"--requested\", name])\n",
            ),
            ("echoprobe", "    let on = (term.c_lflag & tcflag_t(ECHO)) != 0\n"),
            (
                "echocanonical",
                "    let canonical = (term.c_lflag & tcflag_t(ICANON)) != 0\n",
            ),
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

    /// The two files the terminfo LINK deleted. Neither has a keyword left to ban — what would come
    /// back is a HOP (a fork the port removed) and a closed two-case enum — so the ban is on the
    /// PATH.
    #[test]
    fn a_revived_terminfo_file_is_red() {
        for name in ["TerminfoResolver.swift", "ClaudeCodeProfile.swift"] {
            let fixture = Fixture::new(&format!("revived-{name}"));
            fixture.write("Sources/SlopDeskHost/A.swift", "let ordinary = 1\n");
            assert!(deleted_host_swift(&fixture.tree()).is_clean(), "{name}");
            fixture.write(
                &format!("Sources/SlopDeskHost/{name}"),
                "public enum Term: String { case ghostty }\n",
            );
            assert!(
                !deleted_host_swift(&fixture.tree()).is_clean(),
                "{name}: the ban did not fire on its return"
            );
        }
    }

    /// The file whose return would put a second spelling of the wire back in Swift. It has no
    /// keyword to ban, so the ban is on the PATH.
    #[test]
    fn a_revived_supervisor_protocol_file_is_red() {
        for name in [
            "SupervisorProtocol.swift",
            "SniffedEvent.swift",
            "BlockEvent.swift",
        ] {
            let fixture = Fixture::new(&format!("revived-{name}"));
            fixture.write("Sources/SlopDeskHost/A.swift", "let ordinary = 1\n");
            assert!(deleted_host_swift(&fixture.tree()).is_clean(), "{name}");
            fixture.write(
                &format!("Sources/SlopDeskSupervisor/{name}"),
                "enum Key: String, CodingKey { case kind }\n",
            );
            assert!(
                !deleted_host_swift(&fixture.tree()).is_clean(),
                "{name}: the ban did not fire on its return"
            );
        }
    }

    /// A tree where all four hops of both flags are spelled.
    fn spawn_flags_fixture(name: &str) -> Fixture {
        let fixture = Fixture::new(name);
        fixture
            .write(
                "Sources/SlopDeskSupervisor/SupervisorMessages.swift",
                "public var shellIntegration: Bool = false\npublic var blocks: BlocksRequest?\n",
            )
            .write(
                "Sources/SlopDeskSupervisor/SupervisorDoors.swift",
                "fields.shell_integration = request.shellIntegration\nfields.blocks = request.blocks != \
                 nil\n",
            )
            .write(
                "rust/slopdesk-ffi/src/supervisor_protocol.rs",
                "shell_integration: fields.shell_integration,\nblocks: fields.blocks.then(|| todo!()),\n",
            )
            .write(
                "rust/slopdesk-superwire/src/protocol.rs",
                "#[serde(rename = \"shellIntegration\")]\npub blocks: Option<BlocksRequest>,\n",
            );
        fixture
    }

    /// A flag spelled on one side only is the silent half-crossing the rule exists for.
    #[test]
    fn a_flag_the_wire_stops_spelling_is_red() {
        let fixture = spawn_flags_fixture("spawn-flags");
        assert!(spawn_request_flags_cross(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-superwire/src/protocol.rs",
            "pub blocks: Option<BlocksRequest>,\n",
        );
        assert!(!spawn_request_flags_cross(&fixture.tree()).is_clean());
    }

    /// The hop the port ADDED, and the quietest of the four: hostd still has the flag and superd
    /// still reads it, but the door never copies it, so every pane asks for no shim.
    #[test]
    fn a_flag_dropped_at_the_door_is_red() {
        let fixture = spawn_flags_fixture("spawn-flags-door");
        fixture.write(
            "Sources/SlopDeskSupervisor/SupervisorDoors.swift",
            "fields.blocks = request.blocks != nil\n",
        );
        let report = spawn_request_flags_cross(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("never reaches the door")),
            "{report:?}"
        );
    }
}
