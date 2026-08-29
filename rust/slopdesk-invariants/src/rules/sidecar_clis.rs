//! The one sidecar hostd still TALKS to as a program, and the four tables it links instead.
//!
//! Ported from the deleted `check-supervisor.sh` §§13–16c. `slopdesk-ctl`, `slopdesk-codeseed`,
//! `slopdesk-agenthooks` and `slopdesk-probe` were contracts six through nine, and they shared the
//! failure that makes them worth a gate at all: NOTHING ERRORS. A renamed verb is a clean
//! `unknown method` or a `usage()` and a non-zero exit, which every caller reads as an ordinary
//! "no", and both suites stay green while the feature is simply gone.
//!
//! `docs/60` F.9 retired THREE of the four as contracts. hostd was Swift, so the only way it could
//! reach Rust that was already written was to fork a binary and parse its stdout; it is Rust now
//! and CALLS `slopdesk_codeseed`, `slopdesk_hook::install` and `slopdesk_probe` at the level each
//! `main.rs` dispatches to. A renamed function is a build error, so the set comparison it replaced
//! would be a rule about nothing. Each of the three binaries still SHIPS — a user types them, and
//! the formula installs them — but nothing in this tree forks one, so what is left of each rule is
//! the half that was never about the fork: that the capability has one implementation, and that the
//! client did not grow a second.
//!
//! `slopdesk-ctl` is the one that stays whole, because its far end is a program a USER types. Its
//! verbs are still compared as SETS, from the two switches themselves — never as a list maintained
//! here, which would go stale in exactly the direction that hides the drift.
//!
//! §§16b–16c are the tables that stopped being forked first: the git status is linked through
//! `slopdesk-git`, and the pointer tables cross as a raw `int32_t`. Both were ports whose whole
//! point is invisible to a test — the ANSWER is identical, only the cost and the number of
//! declaration orders changed — so the ratchet is here or nowhere.

use crate::claim::{Claim, Extract, RUST, SWIFT, View, check_all};
use crate::paths::HOSTD_CRATES;
use crate::report::Report;
use crate::tree::Tree;

/// hostd's agent-control dispatch, whose match is the accepted verb set.
const CTL_DISPATCH: &str = "rust/slopdesk-hostserver/src/control.rs";
/// The connection loop, which intercepts the streaming verb BEFORE that match.
const CTL_SERVE: &str = "rust/slopdesk-hostserver/src/ctlserve.rs";
/// The CLI's subcommands, each of which sends one verb.
const CTL_COMMANDS: &str = "rust/slopdesk-ctl/src/commands.rs";

/// hostd's code-server seams, which call the seeder's crate and the installer's.
const HOSTD_SERVICES: &str = "rust/slopdesk-hostd/src/services.rs";
/// hostd's metadata reducer, which calls the probe's crate and git's.
const HOSTD_METADATA: &str = "rust/slopdesk-hostserver/src/metadata.rs";

/// The seeder's own switch, still reached by a user typing `slopdesk-codeseed`.
const CODESEED_MAIN: &str = "rust/slopdesk-codeseed/src/main.rs";

/// Where the marker and the installed basename are one constant.
const AGENTHOOKS_MAIN: &str = "rust/slopdesk-hook/src/bin/agenthooks.rs";
/// Where the marker and the installed basename are one constant.
const HOOK_INSTALL: &str = "rust/slopdesk-hook/src/install.rs";
/// The one function in it that builds the installed path, as an `awk` range.
///
/// Scoped, not whole-file: the crate's own tests join `HOOK_MARKER` half a dozen times, so a
/// file-wide match would stay green while `hook_path` itself was rewritten around the literal —
/// which is the entire failure this pins.
const HOOK_PATH: (&str, &str) = (r"^pub fn hook_path\(", r"^\}$");

/// The probe's own switch, still reached by a user typing `slopdesk-probe`.
const PROBE_MAIN: &str = "rust/slopdesk-probe/src/main.rs";

/// The engine behind the git line.
const GIT_STATUS: &str = "rust/slopdesk-git/src/status.rs";
/// The one crate that reads porcelain off libgit2's bitflags.
const GIT_PORCELAIN: &str = "rust/slopdesk-git/src/porcelain.rs";

/// The pointer shape face.
const POINTER_SHAPE: &str = "Sources/SlopDeskWorkspaceCore/Terminal/PointerShapeMapping.swift";
/// The mouse visibility face.
const POINTER_VISIBILITY: &str = "Sources/SlopDeskWorkspaceCore/Terminal/MouseVisibilityMapping.swift";
/// The door that vends both tables, and holds the discriminant test.
const POINTER_DOOR: &str = "rust/slopdesk-ffi/src/pointer_shape.rs";

/// The agent-control verb sets are one alphabet
///
/// The SIXTH two-ended contract, and the one `docs/60` F.9 left whole, because its far end is a
/// program a USER types: two binaries, nothing linking them, no compiler comparing the strings.
/// hostd answers an unknown method with `{"ok":false,"error":"unknown method: X"}` — a CLEAN error,
/// and a clean error is exactly what makes this drift silent in the way that matters: the agent
/// that ran `slopdesk-ctl read` sees a failed command, not a broken build, and both suites stay
/// green.
///
/// `SameValue`'s two sides are named `swift`/`rust` for the common case; here they are both Rust
/// and only the PATHS matter.
///
/// `subscribe` is spelled apart from the rest on both sides — the host handles it BEFORE the
/// request match, in the connection loop, because it hijacks the connection into a stream, and the
/// CLI sends it from `Control::stream`, reached by both the `subscribe` and `events` subcommands.
/// The shell added the string to both extracted sets by hand, which covered nothing: adding one
/// member to both sides of an equality cannot fail. Here each side is asserted to still SPELL it,
/// which is what the note in the shell was reaching for.
///
/// The CLI side is read as a whole-file pattern rather than line-wise: rustfmt wraps a long call so
/// the method literal lands on the NEXT line, and a plain line pattern for a bare quoted string
/// would also swallow every string literal in the tests.
///
/// BREAK-TEST: renamed `"resize" =>` to `"reshape" =>` in the dispatch ⇒ FAIL "ctl verbs".
/// Separately deleted the CLI's `subscribe` spelling ⇒ FAIL "no longer sends the streaming verb".
/// Separately created `Sources/SlopDeskCtlCore` ⇒ FAIL "is back". All three restored from /tmp;
/// PASS.
#[must_use]
pub fn the_ctl_verb_sets_are_one_alphabet(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::SameSet {
            label: "ctl verbs",
            swift: Extract::code(CTL_DISPATCH, r#"^        "([a-z-]+)" =>"#),
            rust: Extract::code(CTL_COMMANDS, r#"ctl\.call\(\s*"([a-z-]+)""#),
        },
        Claim::Matches {
            path: CTL_SERVE,
            pattern: r#"request\.method == "subscribe""#,
            view: View::Code,
            message: "rust/slopdesk-hostserver/src/ctlserve.rs no longer intercepts the streaming verb — \
                      `subscribe` is handled BEFORE the request match, so the verb-set comparison cannot \
                      see it and it is asserted here or nowhere (docs/50)",
        },
        Claim::Matches {
            path: CTL_COMMANDS,
            pattern: r#""subscribe""#,
            view: View::Code,
            message: "rust/slopdesk-ctl no longer sends the streaming verb — `subscribe` leaves \
                      Control::stream rather than ctl.call, so the verb-set comparison cannot see it and it \
                      is asserted here or nowhere (docs/50)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskCtlCore",
            message: "the agent CLI is rust/slopdesk-ctl, and the Swift executable plus its core were \
                      deleted in the same change (docs/DECISIONS.md, the ctl port)",
        },
        Claim::Absent {
            path: "Sources/slopdesk-ctl",
            message: "the agent CLI is rust/slopdesk-ctl, built by `just ctl` (docs/DECISIONS.md, the ctl \
                      port)",
        },
        Claim::Absent {
            path: "Tests/SlopDeskCtlTests",
            message: "the agent CLI's tests are the Rust crate's — a Swift suite here is the cross-language \
                      mirror the tree forbids (docs/DECISIONS.md)",
        },
        Claim::Lacks {
            path: "Package.swift",
            pattern: r#""SlopDeskCtlCore""#,
            view: View::Code,
            message: "Package.swift declares SlopDeskCtlCore again — the agent CLI is Rust, and the two \
                      NDJSON line helpers the `slopdesk` CLI still needed moved into slopdesk-clientctl \
                      (docs/DECISIONS.md)",
        },
    ])
}

/// The profile seeder is one implementation, and hostd calls it
///
/// The SEVENTH contract, and the only one that was never a socket: `CodeSeed.swift` asked it by
/// FORKING it, one subcommand per question, and read one JSON object back. That made the drift
/// quieter than any wire's — a renamed subcommand was `usage()` on stdout and a non-zero exit,
/// `CodeSeed.ask` answering `nil`, and, for `launch-args`, the code panel reporting itself
/// UNAVAILABLE, logging nothing, because an unavailable panel is exactly what a host with no seeder
/// is supposed to report.
///
/// The fork is gone. `docs/60` F.9 made hostd Rust, so it calls `slopdesk_codeseed`'s functions —
/// `seed_profile`, `extensions::missing_bundled_extensions_at`, `settings::sync_editor_font`,
/// `launch::arguments` — and a renamed one is a build error. The set comparison it replaced would
/// be a rule about nothing. What is pinned instead is that hostd still ASKS the crate: a
/// `Command::new("slopdesk-codeseed")` typed back into a host crate would compile, pass every test,
/// and reinstate every failure above.
///
/// The binary still ships and a user still types it, so its switch is pinned as EXISTING — but its
/// spelling is its own concern now that nothing in this tree types the subcommands.
///
/// The resources are the seeder's INPUT, and a second copy under the Swift target is a second
/// answer to "what does a pristine settings file say".
///
/// BREAK-TEST: dropped `slopdesk_codeseed::` from hostd's seams ⇒ FAIL "no longer asks
/// rust/slopdesk-codeseed". Separately restored `static let seededUserSettings` under Sources/ ⇒
/// FAIL "a Swift profile seeder is back". Separately added `.copy("Resources")` to Package.swift ⇒
/// FAIL "bundles a Resources directory again". All three restored from /tmp; PASS.
#[must_use]
pub fn the_codeseed_subcommands_are_one_alphabet(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Matches {
            path: HOSTD_SERVICES,
            pattern: r"slopdesk_codeseed::",
            view: View::Code,
            message: "rust/slopdesk-hostd/src/services.rs no longer asks rust/slopdesk-codeseed for the \
                      workbench profile — a fork back would compile, pass, and turn every renamed \
                      subcommand into an UNAVAILABLE panel that logs nothing (docs/DECISIONS.md, stage 22)",
        },
        Claim::Matches {
            path: CODESEED_MAIN,
            pattern: r#"^        "[a-z-]+" =>"#,
            view: View::Code,
            message: "rust/slopdesk-codeseed's binary lost its subcommand switch — it still ships, and a \
                      user still types it (docs/DECISIONS.md, stage 22)",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"(static (let|var|func)|let|var|func) (seededUserSettings|obsoleteSeeds|themeExtension[A-Za-z]*|bridgeExtension[A-Za-z]*|registerExtension|unregisterExtension|bundledMarketplaceExtensions|retiredExtensions|ownThemeResources)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift profile seeder is back in Sources/ — slopdesk-codeseed owns the code-server \
                      profile, and the ~2.7k lines it replaced went in one change (docs/DECISIONS.md, stage \
                      22): {files}",
        },
        Claim::Absent {
            path: "Sources/SlopDeskHost/CodeServerManagerSeedHistory.swift",
            message: "the seed history lives in rust/slopdesk-codeseed (docs/DECISIONS.md, stage 22)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskHost/Resources",
            message: "the seed inputs are rust/slopdesk-codeseed/resources, and a second copy is a second \
                      answer to what a pristine settings file says",
        },
        Claim::Lacks {
            path: "Package.swift",
            pattern: r#"\.copy\("Resources"\)"#,
            view: View::Code,
            message: "Package.swift bundles a Resources directory again — the seed inputs are \
                      rust/slopdesk-codeseed/resources (docs/DECISIONS.md, stage 22)",
        },
    ])
}

/// The hooks installer is one implementation, and the relay stays empty-handed
///
/// The EIGHTH contract, forked like the seeder rather than dialled, and drifting in two ways at
/// once. A renamed subcommand was `usage()` and a non-zero exit, which `AgentHooks.ask` read as
/// "not installed" — the Settings row then showed a green offer to install something that fails.
/// Nothing logged.
///
/// The fork went the same way the seeder's did in `docs/60` F.9: hostd calls
/// `slopdesk_hook::install`'s `install`, `uninstall`, `is_installed`, `hook_path` and `RELAY_NAME`
/// directly, so a rename is a build error. The two halves below are the ones a compiler still
/// cannot see, and neither was ever about the fork.
///
/// The MARKER is the installed basename. `hook_path` joins `HOOK_MARKER` rather than spelling
/// `slopdesk-agent` a second time, so the two cannot drift; what is pinned is that the CONSTRUCTION
/// survives, because the day someone writes the literal back in is the day an uninstall silently
/// stops matching what an install wrote.
///
/// The relay takes NO dependencies. `serde_json` is the installer's, and it stays out of the binary
/// Claude Code forks twice per tool call only because nothing the relay's `main` reaches can see
/// it. A `use serde_json` in the relay's own two files would not fail a build, a test or a lint —
/// it would just make every tool call slower, which is the one regression this tree has no other
/// way to notice.
///
/// BREAK-TEST: dropped `slopdesk_hook::install::` from hostd's seams ⇒ FAIL "no longer asks
/// rust/slopdesk-hook". Separately rewrote `hook_path` to join the literal ⇒ FAIL "no longer builds
/// the installed name from `HOOK_MARKER`". Separately added `use serde_json;` to the relay's
/// `main.rs` ⇒ FAIL "reaches a dependency". All three restored from /tmp; PASS.
#[must_use]
pub fn the_hooks_installer_is_one_alphabet(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Matches {
            path: HOSTD_SERVICES,
            pattern: r"slopdesk_hook::install::",
            view: View::Code,
            message: "rust/slopdesk-hostd/src/services.rs no longer asks rust/slopdesk-hook to install the \
                      relay — a fork back would compile, and a renamed subcommand would read as 'not \
                      installed', showing a green offer to install something that fails (docs/DECISIONS.md, \
                      stage 23)",
        },
        Claim::Matches {
            path: AGENTHOOKS_MAIN,
            pattern: r#"^        "[a-z]+" =>"#,
            view: View::Code,
            message: "rust/slopdesk-agenthooks lost its subcommand switch — it still ships, and a user \
                      still types it (docs/DECISIONS.md, stage 23)",
        },
        Claim::Within {
            path: HOOK_INSTALL,
            start: HOOK_PATH.0,
            end: HOOK_PATH.1,
            pattern: r#"join\("hooks"\)"#,
            view: View::Code,
            message: "install::hook_path no longer joins the hooks directory — the merge sentinel and the \
                      installed basename must be one constant (docs/DECISIONS.md, stage 23)",
        },
        Claim::Within {
            path: HOOK_INSTALL,
            start: HOOK_PATH.0,
            end: HOOK_PATH.1,
            pattern: r"\.join\(HOOK_MARKER\)",
            view: View::Code,
            message: "install::hook_path no longer builds the installed name from HOOK_MARKER — the day the \
                      literal is written back in is the day an uninstall silently stops matching what an \
                      install wrote (docs/DECISIONS.md, stage 23)",
        },
        Claim::Lacks {
            path: "rust/slopdesk-hook/src/main.rs",
            pattern: r"^\s*use +(serde|serde_json)\b",
            view: View::Code,
            message: "the hook relay reaches a dependency — its cost IS process startup, it is forked twice \
                      per tool call, and this would fail no build, test or lint (docs/DECISIONS.md, stage \
                      23)",
        },
        Claim::Lacks {
            path: "rust/slopdesk-hook/src/lib.rs",
            pattern: r"^\s*use +(serde|serde_json)\b",
            view: View::Code,
            message: "the hook relay reaches a dependency — its cost IS process startup, it is forked twice \
                      per tool call, and this would fail no build, test or lint (docs/DECISIONS.md, stage \
                      23)",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"(enum|struct|final class|static (let|var|func)) (AgentInstaller|hookMarker|installedEvents|hookCommand|entryIsOurs)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift hooks installer is back in Sources/ — slopdesk-agenthooks owns \
                      ~/.claude/settings.json, and the merge, the marker, the event list and the paths \
                      moved in one change (docs/DECISIONS.md, stage 23): {files}",
        },
        Claim::Absent {
            path: "Sources/SlopDeskHost/AgentInstaller.swift",
            message: "the merge lives in rust/slopdesk-hook/src/install.rs (docs/DECISIONS.md, stage 23)",
        },
    ])
}

/// The probe is one implementation, called at the level its own switch dispatches to
///
/// The NINTH contract. Same fork-per-question shape as the seeder and the installer, with one
/// wrinkle neither had: two subcommands answered in RAW BYTES, so their "nothing there" could not
/// be an empty answer and had to be the exit code. `askBytes` had to branch on the STATUS and never
/// on the byte count, because the tidy-up that writes `data.isEmpty ? nil : data` turns every
/// unchanged file into a `.notFound` without failing a build, a test or a lint.
///
/// `docs/60` F.9 deleted that whole hazard rather than moving it. hostd's metadata reducer calls
/// `git::diff`, `files::list_directory`, `files::list_sessions` and `files::read_session` — the
/// SAME level `main.rs` dispatches to, which is what makes the substitution honest: every rule
/// inside those functions travels with the call, and `read_session`'s second confinement of the id
/// against the host's session roots would be silently dropped by reaching one level below them.
/// There is no exit code left to misread, and an empty `Vec` is an empty `Vec`.
///
/// So the pinned half is the LEVEL. A `slopdesk_probe::files::read_session_at` or a hand-rolled
/// walk beside it would compile and answer correctly for every path that is inside the roots.
///
/// `lsof` is the one subprocess left on the client side; a `git` or an `infocmp` next to it is a
/// ported path coming back — for git, the four-spawns-per-request one.
///
/// BREAK-TEST: dropped `slopdesk_probe::files::read_session` from the reducer ⇒ FAIL "no longer
/// asks {entry}". Separately restored `static let claudeProjectSlug` under Sources/ ⇒ FAIL "a Swift
/// git/session/terminfo parser is back". Separately wrote `"/usr/bin/git"` into a Swift file ⇒ FAIL
/// "Swift spawns git or infocmp again". All three restored from /tmp; PASS.
#[must_use]
pub fn the_probe_subcommands_are_one_alphabet(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Mentions {
            path: HOSTD_METADATA,
            names: &[
                "slopdesk_probe::git::diff",
                "slopdesk_probe::files::list_directory",
                "slopdesk_probe::files::list_sessions",
                "slopdesk_probe::files::read_session",
            ],
            message: "rust/slopdesk-hostserver/src/metadata.rs no longer asks {entry} — the probe is called \
                      at the level its own switch dispatches to, and one level below it drops the rules \
                      inside, starting with read_session's second confinement of the id (docs/DECISIONS.md, \
                      stages 24 and 25)",
        },
        Claim::Matches {
            path: PROBE_MAIN,
            pattern: r#"^        "[a-z-]+" =>"#,
            view: View::Code,
            message: "rust/slopdesk-probe's binary lost its subcommand switch — it still ships, and a user \
                      still types it (docs/DECISIONS.md, stage 24)",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"(struct|static (let|var|func)|private static func) (parseBranchHeader|parseStatusLine|statusNibble|packStatus|claudeProjectSlug|gitToplevel|gitStashCount|gitDiffArgumentPlan|resolveGitDiff|jsonlSessions|claudeSessions|opencodeSessions|sessionRoots|GhosttyTerminfoProbe|terminfoEntryExists|isGhosttyResolvable|effectiveTerm|liveProbe|runInfocmp)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift git/session/terminfo parser is back in Sources/ — slopdesk-probe owns \
                      porcelain, the slug, the diff bases and the TERM table (docs/DECISIONS.md, stages 24 \
                      and 25): {files}",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r#""/usr/bin/(git|infocmp)""#,
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "Swift spawns git or infocmp again — both belong inside slopdesk-probe, and `lsof` is \
                      the one subprocess left on this side (docs/DECISIONS.md, stages 24 and 25): {files}",
        },
    ])
}

/// The git status is linked, not forked, and it is asked in exactly one place
///
/// `gitStatus` left the probe entirely: `rust/slopdesk-git` opens the repository once and answers
/// from libgit2, called by hostd as a crate. What that removed was FIVE process spawns per
/// debounced `FSEvents` tick per watched repo — four `git` runs inside one fork of the probe — so a
/// `git status` reappearing anywhere on this path is not a style question, it is the cost coming
/// back.
///
/// Three things are pinned, because the port has three ways to be undone quietly. A host crate
/// could be rewritten around a `Command` and every test would still pass, the answer being
/// identical and only the spawns differing. A fallback parser beside it would be the
/// two-implementations shape CLAUDE.md forbids, and would only show up under an unusual repo. And
/// nothing links hostd to `slopdesk-probe`'s binary, so a revived `git-status` arm there is
/// invisible to the compiler — this names the arm itself.
///
/// The porcelain PAIR is spelled once, in the crate that reads it off libgit2's bitflags. The shell
/// banned two names that no longer exist anywhere: both functions were renamed when they moved into
/// `slopdesk-git::porcelain`, and that ban has been matching nothing since. Both halves are stated
/// here instead — the table is where it belongs, and no second copy of either SIGNATURE lives
/// outside the crate. The signature rather than the bare name, because `fn pack(` is too common a
/// spelling to ban across every crate in the tree.
///
/// BREAK-TEST: dropped `slopdesk_git::status::of_path` from the repo watcher ⇒ FAIL "no longer
/// asks {entry}". Separately wrote `Command::new("git")` into a host crate ⇒ FAIL "spawns git
/// again". Separately added a `"git-status"` arm to the probe ⇒ FAIL "answers git-status again".
/// Separately copied `nibble(character: char) -> u8` into another crate ⇒ FAIL "the porcelain
/// nibble table is back outside". All four restored from /tmp; PASS.
#[must_use]
pub fn the_git_status_is_linked_and_asked_once(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::MentionsUnder {
            root: "rust/slopdesk-hostserver",
            names: &["slopdesk_git::status::of_path"],
            message: "no file under rust/slopdesk-hostserver asks {entry} any more — the git line is back \
                      on a subprocess, which is five spawns per debounced FSEvents tick per watched repo \
                      and identical output (docs/55)",
        },
        Claim::NoneUnder {
            roots: HOSTD_CRATES,
            extensions: RUST,
            pattern: r#"Command::new\("[a-z/]*git"\)|"/usr/bin/git""#,
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} spawns git again — rust/slopdesk-git opens the repository ONCE and answers \
                      from libgit2, and the identical answer is exactly what makes the cost invisible to \
                      every test (docs/55)",
        },
        Claim::Matches {
            path: GIT_STATUS,
            pattern: r"pub fn of_path",
            view: View::Code,
            message: "rust/slopdesk-git no longer answers of_path — the status engine moved without its \
                      ratchet (docs/DECISIONS.md)",
        },
        Claim::Lacks {
            path: PROBE_MAIN,
            pattern: r#""git-status""#,
            view: View::Code,
            message: "slopdesk-probe answers git-status again — the status engine is rust/slopdesk-git, \
                      LINKED, and the verb-set rule would accept this arm the moment somebody added the \
                      Swift side back (docs/DECISIONS.md)",
        },
        Claim::Matches {
            path: GIT_PORCELAIN,
            pattern: r"pub const fn nibble\(character: char\) -> u8",
            view: View::Code,
            message: "rust/slopdesk-git::porcelain no longer holds the nibble table — the client mirrors \
                      its inverse to name a change category, so it is a wire contract and it has one master \
                      (docs/DECISIONS.md)",
        },
        Claim::Matches {
            path: GIT_PORCELAIN,
            pattern: r"pub const fn pack\(x: char, y: char\) -> u8",
            view: View::Code,
            message: "rust/slopdesk-git::porcelain no longer packs the porcelain pair into one byte — \
                      golden/golden_vectors.json freezes that byte (docs/DECISIONS.md)",
        },
        Claim::NoneUnder {
            roots: &["rust"],
            extensions: &["rs"],
            pattern: r"fn nibble\(character: char\) -> u8|fn pack\(x: char, y: char\) -> u8",
            all: &[],
            unless: &[],
            view: View::Code,
            // This crate is exempt because its own fixture for the ban has to SPELL the thing
            // banned — a rule that cannot be tested without failing itself is a rule with no
            // break-test, which is the one property every rule here is supposed to have.
            exempt: &["rust/slopdesk-git/", "rust/slopdesk-invariants/"],
            message: "the porcelain nibble table is back outside slopdesk-git::porcelain — one table, one \
                      crate, because the old probe's copy lived beside a parser that is gone: {files}",
        },
    ])
}

/// The pointer tables are one table, and the raw value crosses unparsed
///
/// `slopdesk_terminal::pointer` owns both of libghostty's pointer actions. This is pinned harder
/// than its size suggests, because EVERY way it breaks is silent: a resize handle showing a hand,
/// or a pointer hidden with no gesture that brings it back. Nothing fails to compile, nothing
/// crashes, and `slopdesk-guigate macos` is the only thing that would ever have noticed.
///
/// `OSCPointerShape` (34 cases) and `MouseVisibility` existed only so a Swift `switch` had
/// something to switch over, which made THREE copies of one declaration order — libghostty's
/// header, the mirror, the table — where any two could drift while compiling. The raw `int32_t`
/// travels now, and a revived mirror reads like tidying while restoring the drift.
///
/// `PointerShapeToken`'s discriminants ARE the wire, so they are spelled with explicit raw values
/// on both sides and asserted THROUGH the door. A case reordered under implicit numbering is a
/// cursor swapped for another cursor with nothing to notice it.
///
/// The ban's roots are `Sources`, `Tests` and `ThirdParty/ghostty/integration` — the same three the
/// tree walks. The shell reached the last of those through a bare `ThirdParty/`, which read all 8
/// GB of the vendored checkout through single-threaded grep and cost four minutes of a thirty-nine
/// second gate; here it is not a scope decision at all, because the walk never held the rest.
///
/// BREAK-TEST: deleted `slopdesk_pointer_mouse_visible` from the visibility face ⇒ FAIL "stopped
/// asking the door". Separately restored `enum OSCPointerShape` under Sources/ ⇒ FAIL "a Swift
/// mirror of a libghostty pointer enum is back". Separately dropped `= 0` from `case arrow` ⇒ FAIL
/// "stopped pinning its raw values". All three restored from /tmp; PASS.
#[must_use]
pub fn the_pointer_tables_are_one_table(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Matches {
            path: POINTER_SHAPE,
            pattern: r"slopdesk_pointer_",
            view: View::Code,
            message: "PointerShapeMapping stopped asking the door — a pointer table decided in Swift is a \
                      second table, and every way it breaks is silent (docs/56, increment 50)",
        },
        Claim::Matches {
            path: POINTER_VISIBILITY,
            pattern: r"slopdesk_pointer_",
            view: View::Code,
            message: "MouseVisibilityMapping stopped asking the door — a pointer hidden with no gesture \
                      that brings it back fails nothing and crashes nothing (docs/56, increment 50)",
        },
        Claim::NoneUnder {
            roots: &["Sources", "Tests", "ThirdParty/ghostty/integration"],
            extensions: SWIFT,
            pattern: r"enum OSCPointerShape|enum MouseVisibility[^M]",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift mirror of a libghostty pointer enum is back — the raw int crosses now, and a \
                      mirror restores three copies of one declaration order where any two could drift while \
                      compiling (docs/56, increment 50): {files}",
        },
        Claim::Matches {
            path: POINTER_SHAPE,
            pattern: r"case arrow = 0",
            view: View::Code,
            message: "PointerShapeToken stopped pinning its raw values — its discriminants ARE the wire, \
                      and a case reordered under implicit numbering is a cursor swapped for another cursor \
                      (docs/56, increment 50)",
        },
        Claim::Matches {
            path: POINTER_DOOR,
            pattern: r"the_supported_shapes_cross_as_the_discriminants_swift_is_pinned_to",
            view: View::Code,
            message: "the door's discriminant test is gone — Swift's enum and Rust's can now renumber apart \
                      (docs/56, increment 50)",
        },
    ])
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// A tree where every rule in this module passes.
    fn clis(fixture: &Fixture) {
        for (path, body) in [
            (super::CTL_DISPATCH, CTL_DISPATCH_BODY),
            (super::CTL_SERVE, CTL_SERVE_BODY),
            (super::CTL_COMMANDS, CTL_COMMANDS_BODY),
            (super::HOSTD_SERVICES, HOSTD_SERVICES_BODY),
            (super::HOSTD_METADATA, HOSTD_METADATA_BODY),
            (super::CODESEED_MAIN, CODESEED_MAIN_BODY),
            (super::AGENTHOOKS_MAIN, AGENTHOOKS_MAIN_BODY),
            (super::HOOK_INSTALL, HOOK_INSTALL_BODY),
            ("rust/slopdesk-hook/src/main.rs", "fn main() {}\n"),
            ("rust/slopdesk-hook/src/lib.rs", "pub fn relay() {}\n"),
            (super::PROBE_MAIN, PROBE_MAIN_BODY),
            (
                "rust/slopdesk-hostserver/src/repowatch.rs",
                "let payload = slopdesk_git::status::of_path(repo);\n",
            ),
            (super::GIT_STATUS, "pub fn of_path(path: &str) -> Payload {}\n"),
            (super::GIT_PORCELAIN, PORCELAIN_BODY),
            (super::POINTER_SHAPE, POINTER_SHAPE_BODY),
            (
                super::POINTER_VISIBILITY,
                "func visible(_ raw: Int32) -> Bool {\n    slopdesk_pointer_mouse_visible(raw)\n}\n",
            ),
            (
                super::POINTER_DOOR,
                "#[test]\nfn the_supported_shapes_cross_as_the_discriminants_swift_is_pinned_to() {}\n",
            ),
            ("Package.swift", "let package = Package(name: \"SlopDesk\")\n"),
        ] {
            fixture.write(path, body);
        }
    }

    const CTL_DISPATCH_BODY: &str = "fn dispatch(method: &str) -> Reply {\n    match method {\n        \
                                     \"read\" => read_pane(),\n        \"write\" => write_pane(),\n        \
                                     \"resize\" => resize_pane(),\n        _ => unknown(),\n    }\n}\n";
    const CTL_SERVE_BODY: &str =
        "fn serve(request: &Request) {\n    if request.method == \"subscribe\" {\n        return \
         stream();\n    }\n    dispatch(&request.method);\n}\n";

    /// hostd's side of the three retired forks: it CALLS each crate.
    const HOSTD_SERVICES_BODY: &str = "fn seams() {\n    let dir = \
                                       slopdesk_codeseed::paths::data_dir_in(&environment);\n    let home = \
                                       slopdesk_hook::install::home_in(&environment);\n}\n";
    const HOSTD_METADATA_BODY: &str = "fn reduce() {\n    slopdesk_probe::git::diff(cwd, file);\n    \
                                       slopdesk_probe::files::list_directory(absolute);\n    \
                                       slopdesk_probe::files::list_sessions(&self.home, project);\n    \
                                       slopdesk_probe::files::read_session(&self.home, id);\n}\n";
    const CTL_COMMANDS_BODY: &str =
        "fn read(ctl: &Ctl) {\n    let obj = ctl.call(\"read\", p())?;\n}\nfn write(ctl: &Ctl) {\n    let \
         obj = ctl.call(\n        \"write\",\n        p(),\n    )?;\n}\nfn resize(ctl: &Ctl) {\n    let obj \
         = ctl.call(\"resize\", p())?;\n}\nfn stream(ctl: &Ctl) {\n    ctl.stream(\"subscribe\")\n}\n";

    const CODESEED_MAIN_BODY: &str = "fn main() {\n    match verb {\n        \"seed\" => a(),\n        \
                                      \"paths\" => b(),\n        \"sync-font\" => c(),\n        _ => \
                                      usage(),\n    }\n}\n";

    const AGENTHOOKS_MAIN_BODY: &str = "fn main() {\n    match verb {\n        \"status\" => a(),\n        \
                                        \"install\" => b(),\n        \"uninstall\" => c(),\n        _ => \
                                        usage(),\n    }\n}\n";
    const HOOK_INSTALL_BODY: &str = "pub const HOOK_MARKER: &str = \"slopdesk-agent\";\npub fn \
                                     hook_path(home: &Path) -> PathBuf {\n    \
                                     config_base(home).join(\"hooks\").join(HOOK_MARKER)\n}\n";

    const PROBE_MAIN_BODY: &str = "fn main() {\n    match verb {\n        \"list-dir\" => a(),\n        \
                                   \"git-diff\" => b(),\n        _ => usage(),\n    }\n}\n";

    const PORCELAIN_BODY: &str = "pub const fn nibble(character: char) -> u8 {\n    0\n}\npub const fn \
                                  pack(x: char, y: char) -> u8 {\n    (nibble(x) << 4) | nibble(y)\n}\n";
    const POINTER_SHAPE_BODY: &str = "enum PointerShapeToken: Int32 {\n    case arrow = 0\n    case text = \
                                      1\n}\nfunc token(_ raw: Int32) -> PointerShapeToken? {\n    \
                                      PointerShapeToken(rawValue: slopdesk_pointer_shape_token(raw))\n}\n";

    /// A clean error is what makes this drift silent, so the SET is what is compared.
    #[test]
    fn a_verb_one_side_does_not_know_is_red() {
        let fixture = Fixture::new("ctl-verbs");
        clis(&fixture);
        assert!(super::the_ctl_verb_sets_are_one_alphabet(&fixture.tree()).is_clean());

        fixture.write(
            super::CTL_DISPATCH,
            &CTL_DISPATCH_BODY.replace("\"resize\" =>", "\"reshape\" =>"),
        );
        let report = super::the_ctl_verb_sets_are_one_alphabet(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("ctl verbs")),
            "{report:?}"
        );
    }

    /// The streaming verb is handled outside both switches, so equality cannot see it.
    #[test]
    fn a_cli_that_stopped_sending_subscribe_is_red() {
        let fixture = Fixture::new("ctl-subscribe");
        clis(&fixture);
        fixture.write(
            super::CTL_COMMANDS,
            &CTL_COMMANDS_BODY.replace("ctl.stream(\"subscribe\")", "ctl.stream(\"events\")"),
        );
        let report = super::the_ctl_verb_sets_are_one_alphabet(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("no longer sends the streaming verb")),
            "{report:?}"
        );
    }

    /// A fork back would compile and pass, and turn every renamed subcommand into a silent
    /// UNAVAILABLE panel — which is the failure linking the crate removed.
    #[test]
    fn a_host_that_stopped_asking_the_seeder_crate_is_red() {
        let fixture = Fixture::new("codeseed-linked");
        clis(&fixture);
        assert!(super::the_codeseed_subcommands_are_one_alphabet(&fixture.tree()).is_clean());

        fixture.write(
            super::HOSTD_SERVICES,
            "fn seams() {\n    Command::new(\"slopdesk-codeseed\").arg(\"paths\").output();\n    let home = \
             slopdesk_hook::install::home_in(&environment);\n}\n",
        );
        let report = super::the_codeseed_subcommands_are_one_alphabet(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("no longer asks rust/slopdesk-codeseed")),
            "{report:?}"
        );
    }

    /// The regression that fails no build, test or lint — it only makes every tool call slower.
    #[test]
    fn a_relay_that_reaches_a_dependency_is_red() {
        let fixture = Fixture::new("hook-relay");
        clis(&fixture);
        assert!(super::the_hooks_installer_is_one_alphabet(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-hook/src/main.rs",
            "use serde_json::Value;\nfn main() {}\n",
        );
        let report = super::the_hooks_installer_is_one_alphabet(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("reaches a dependency")),
            "{report:?}"
        );
    }

    #[test]
    fn a_marker_written_back_as_a_literal_is_red() {
        let fixture = Fixture::new("hook-marker");
        clis(&fixture);
        fixture.write(
            super::HOOK_INSTALL,
            "pub const HOOK_MARKER: &str = \"slopdesk-agent\";\npub fn hook_path(home: &Path) -> PathBuf \
             {\n    config_base(home).join(\"hooks\").join(\"slopdesk-agent\")\n}\n",
        );
        let report = super::the_hooks_installer_is_one_alphabet(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("from HOOK_MARKER")),
            "{report:?}"
        );
    }

    /// One level below `read_session` answers correctly for every path INSIDE the roots, and
    /// silently drops the second confinement for every path outside them.
    #[test]
    fn a_reducer_that_reaches_below_the_probes_own_level_is_red() {
        let fixture = Fixture::new("probe-level");
        clis(&fixture);
        assert!(super::the_probe_subcommands_are_one_alphabet(&fixture.tree()).is_clean());

        fixture.write(
            super::HOSTD_METADATA,
            &HOSTD_METADATA_BODY.replace(
                "slopdesk_probe::files::read_session(&self.home, id);",
                "read_jsonl(&self.home.join(id));",
            ),
        );
        let report = super::the_probe_subcommands_are_one_alphabet(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("slopdesk_probe::files::read_session")),
            "{report:?}"
        );
    }

    /// The revived arm the verb-set rule would ACCEPT the moment the Swift side came back.
    #[test]
    fn a_revived_git_status_arm_is_red() {
        let fixture = Fixture::new("git-arm");
        clis(&fixture);
        assert!(super::the_git_status_is_linked_and_asked_once(&fixture.tree()).is_clean());

        fixture.write(
            super::PROBE_MAIN,
            &PROBE_MAIN_BODY.replace(
                "\"git-diff\" => b(),",
                "\"git-diff\" => b(),\n        \"git-status\" => s(),",
            ),
        );
        let report = super::the_git_status_is_linked_and_asked_once(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("answers git-status again")),
            "{report:?}"
        );
    }

    /// The answer is IDENTICAL and only the spawns differ, which is what makes this invisible to
    /// every test in the tree.
    #[test]
    fn a_host_crate_that_spawns_git_is_red() {
        let fixture = Fixture::new("git-spawn");
        clis(&fixture);
        assert!(super::the_git_status_is_linked_and_asked_once(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-hostserver/src/repowatch.rs",
            "let payload = slopdesk_git::status::of_path(repo);\nlet out = \
             Command::new(\"git\").arg(\"status\").output();\n",
        );
        let report = super::the_git_status_is_linked_and_asked_once(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("spawns git again")),
            "{report:?}"
        );
    }

    /// The ban the shell had been running against a name that no longer existed anywhere.
    #[test]
    fn a_second_porcelain_table_is_red_and_the_crates_own_is_not() {
        let fixture = Fixture::new("git-porcelain");
        clis(&fixture);
        assert!(super::the_git_status_is_linked_and_asked_once(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-probe/src/porcelain.rs",
            "const fn nibble(character: char) -> u8 {\n    0\n}\n",
        );
        let report = super::the_git_status_is_linked_and_asked_once(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("back outside slopdesk-git::porcelain")),
            "{report:?}"
        );
    }

    #[test]
    fn a_revived_pointer_mirror_is_red() {
        let fixture = Fixture::new("pointer-mirror");
        clis(&fixture);
        assert!(super::the_pointer_tables_are_one_table(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Terminal/OSCPointerShape.swift",
            "enum OSCPointerShape: String {\n    case arrow\n}\n",
        );
        let report = super::the_pointer_tables_are_one_table(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("mirror of a libghostty pointer enum")),
            "{report:?}"
        );
    }

    /// Implicit numbering is a cursor swapped for another cursor with nothing to notice it.
    #[test]
    fn an_unpinned_discriminant_is_red() {
        let fixture = Fixture::new("pointer-raw");
        clis(&fixture);
        fixture.write(
            super::POINTER_SHAPE,
            &POINTER_SHAPE_BODY.replace("case arrow = 0", "case arrow"),
        );
        let report = super::the_pointer_tables_are_one_table(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("stopped pinning its raw values")),
            "{report:?}"
        );
    }
}
