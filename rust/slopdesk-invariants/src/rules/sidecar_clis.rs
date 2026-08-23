//! The four sidecars hostd FORKS, and the two tables it links instead.
//!
//! Ported from `scripts/check-supervisor.sh` §§13–16c. `slopdesk-ctl`, `slopdesk-codeseed`,
//! `slopdesk-agenthooks` and `slopdesk-probe` are contracts six through nine, and they share the
//! failure that makes them worth a gate at all: NOTHING ERRORS. A renamed verb is a clean
//! `unknown method` or a `usage()` and a non-zero exit, which every caller here reads as an ordinary
//! "no", and both suites stay green while the feature is simply gone.
//!
//! So the verb sets are compared as SETS, from the two switches themselves — never as a list
//! maintained here, which would go stale in exactly the direction that hides the drift.
//!
//! §§16b–16c are the two tables that stopped being forked at all: the git status is linked through
//! `slopdesk_git_status`, and the pointer tables cross as a raw `int32_t`. Both were ports whose
//! whole point is invisible to a test — the ANSWER is identical, only the cost and the number of
//! declaration orders changed — so the ratchet is here or nowhere.

use crate::claim::{Claim, Extract, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// hostd's agent-control listener, whose switch is the accepted verb set.
const CTL_LISTENER: &str = "Sources/SlopDeskHost/AgentControlListener.swift";
/// The CLI's subcommands, each of which sends one verb.
const CTL_COMMANDS: &str = "rust/slopdesk-ctl/src/commands.rs";

/// hostd's face over the profile seeder.
const CODESEED_FACE: &str = "Sources/SlopDeskHost/CodeSeed.swift";
/// The seeder's own switch.
const CODESEED_MAIN: &str = "rust/slopdesk-codeseed/src/main.rs";

/// hostd's face over the hooks installer.
const AGENTHOOKS_FACE: &str = "Sources/SlopDeskHost/AgentHooks.swift";
/// The installer's own switch.
const AGENTHOOKS_MAIN: &str = "rust/slopdesk-hook/src/bin/agenthooks.rs";
/// Where the marker and the installed basename are one constant.
const HOOK_INSTALL: &str = "rust/slopdesk-hook/src/install.rs";
/// The one function in it that builds the installed path, as an `awk` range.
///
/// Scoped, not whole-file: the crate's own tests join `HOOK_MARKER` half a dozen times, so a
/// file-wide match would stay green while `hook_path` itself was rewritten around the literal —
/// which is the entire failure this pins.
const HOOK_PATH: (&str, &str) = (r"^pub fn hook_path\(", r"^\}$");

/// hostd's face over the metadata probe.
const PROBE_FACE: &str = "Sources/SlopDeskHost/HostProbe.swift";
/// The probe's own switch.
const PROBE_MAIN: &str = "rust/slopdesk-probe/src/main.rs";

/// The Swift face over the linked git status.
const GIT_FACE: &str = "Sources/SlopDeskHost/HostGitStatus.swift";
/// The engine behind it.
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
/// The SIXTH two-ended contract, and the only one whose far end is a program a USER types. hostd
/// answers an unknown method with `{"ok":false,"error":"unknown method: X"}` — a CLEAN error, and a
/// clean error is exactly what makes this drift silent in the way that matters: the agent that ran
/// `slopdesk-ctl read` sees a failed command, not a broken build, and both suites stay green.
///
/// `subscribe` is spelled apart from the rest on both sides — the host handles it BEFORE the request
/// switch, because it hijacks the connection into a stream, and the CLI sends it from
/// `Control::stream`, reached by both the `subscribe` and `events` subcommands. The shell added the
/// string to both extracted sets by hand, which covered nothing: adding one member to both sides of
/// an equality cannot fail. Here each side is asserted to still SPELL it, which is what the note in
/// the shell was reaching for.
///
/// The CLI side is read as a whole-file pattern rather than line-wise: rustfmt wraps a long call so
/// the method literal lands on the NEXT line, and a plain line pattern for a bare quoted string
/// would also swallow every string literal in the tests.
///
/// BREAK-TEST: renamed `case "resize":` to `case "reshape":` in the listener ⇒ FAIL "ctl verbs".
/// Separately deleted the CLI's `subscribe` spelling ⇒ FAIL "no longer sends the streaming verb".
/// Separately created `Sources/SlopDeskCtlCore` ⇒ FAIL "is back". All three restored from /tmp;
/// PASS.
#[must_use]
pub fn the_ctl_verb_sets_are_one_alphabet(tree: &Tree) -> Report {
    check_all(
        tree,
        &[
            Claim::SameSet {
                label: "ctl verbs",
                swift: Extract::code(CTL_LISTENER, r#"^        case "([a-z-]+)":$"#),
                rust: Extract::code(CTL_COMMANDS, r#"ctl\.call\(\s*"([a-z-]+)""#),
            },
            Claim::Matches {
                path: CTL_LISTENER,
                pattern: r#""subscribe""#,
                view: View::Code,
                message: "AgentControlListener no longer answers the streaming verb — `subscribe` \
                          is handled BEFORE the request switch, so the verb-set comparison cannot \
                          see it and it is asserted here or nowhere (docs/50)",
            },
            Claim::Matches {
                path: CTL_COMMANDS,
                pattern: r#""subscribe""#,
                view: View::Code,
                message: "rust/slopdesk-ctl no longer sends the streaming verb — `subscribe` leaves \
                          Control::stream rather than ctl.call, so the verb-set comparison cannot \
                          see it and it is asserted here or nowhere (docs/50)",
            },
            Claim::Absent {
                path: "Sources/SlopDeskCtlCore",
                message: "the agent CLI is rust/slopdesk-ctl, and the Swift executable plus its core \
                          were deleted in the same change (docs/DECISIONS.md, the ctl port)",
            },
            Claim::Absent {
                path: "Sources/slopdesk-ctl",
                message: "the agent CLI is rust/slopdesk-ctl, built by `make ctl` \
                          (docs/DECISIONS.md, the ctl port)",
            },
            Claim::Absent {
                path: "Tests/SlopDeskCtlTests",
                message: "the agent CLI's tests are the Rust crate's — a Swift suite here is the \
                          cross-language mirror the tree forbids (docs/DECISIONS.md)",
            },
            Claim::Lacks {
                path: "Package.swift",
                pattern: r#""SlopDeskCtlCore""#,
                view: View::Code,
                message: "Package.swift declares SlopDeskCtlCore again — the agent CLI is Rust, and \
                          the two NDJSON line helpers the `slopdesk` CLI still needed moved into \
                          ClientControlProtocol (docs/DECISIONS.md)",
            },
        ],
    )
}

/// The profile seeder's subcommands are one alphabet
///
/// The SEVENTH contract, and the only one that is not a socket: hostd asks it by FORKING it, one
/// subcommand per question, and reads one JSON object back. Which makes the drift quieter than any
/// wire's — a renamed subcommand is `usage()` on stdout and a non-zero exit, `CodeSeed.ask`
/// answering `nil`, and, for `launch-args`, the code panel reporting itself UNAVAILABLE. Nothing is
/// logged, because an unavailable panel is exactly what a host with no seeder is supposed to report.
///
/// `sync-font` is spelled across lines on the Swift side — its three flags follow it in the array —
/// so the extraction reads `ask([` and the first quoted string after it, wherever the wrap put it.
///
/// The resources are the seeder's INPUT, and a second copy under the Swift target is a second answer
/// to "what does a pristine settings file say".
///
/// BREAK-TEST: renamed `"missing-extensions"` in the seeder's switch ⇒ FAIL "codeseed
/// subcommands". Separately restored `static let seededUserSettings` under Sources/ ⇒ FAIL "a Swift
/// profile seeder is back". Separately added `.copy("Resources")` to Package.swift ⇒ FAIL "bundles a
/// Resources directory again". All three restored from /tmp; PASS.
#[must_use]
pub fn the_codeseed_subcommands_are_one_alphabet(tree: &Tree) -> Report {
    check_all(
        tree,
        &[
            Claim::SameSet {
                label: "codeseed subcommands",
                swift: Extract::code(CODESEED_FACE, r#"ask\(\[\s*"([a-z-]+)""#),
                rust: Extract::code(CODESEED_MAIN, r#"^        "([a-z-]+)" =>"#),
            },
            Claim::NoneUnder {
                roots: &["Sources"],
                extensions: SWIFT,
                pattern: r"(static (let|var|func)|let|var|func) (seededUserSettings|obsoleteSeeds|themeExtension[A-Za-z]*|bridgeExtension[A-Za-z]*|registerExtension|unregisterExtension|bundledMarketplaceExtensions|retiredExtensions|ownThemeResources)\b",
                all: &[],
                unless: &[],
                view: View::Code,
                exempt: &[],
                message: "a Swift profile seeder is back in Sources/ — slopdesk-codeseed owns the \
                          code-server profile, and the ~2.7k lines it replaced went in one change \
                          (docs/DECISIONS.md, stage 22): {files}",
            },
            Claim::Absent {
                path: "Sources/SlopDeskHost/CodeServerManagerSeedHistory.swift",
                message: "the seed history lives in rust/slopdesk-codeseed (docs/DECISIONS.md, \
                          stage 22)",
            },
            Claim::Absent {
                path: "Sources/SlopDeskHost/Resources",
                message: "the seed inputs are rust/slopdesk-codeseed/resources, and a second copy \
                          is a second answer to what a pristine settings file says",
            },
            Claim::Lacks {
                path: "Package.swift",
                pattern: r#"\.copy\("Resources"\)"#,
                view: View::Code,
                message: "Package.swift bundles a Resources directory again — the seed inputs are \
                          rust/slopdesk-codeseed/resources (docs/DECISIONS.md, stage 22)",
            },
        ],
    )
}

/// The hooks installer's subcommands are one alphabet, and the relay stays empty-handed
///
/// The EIGHTH contract, forked like the seeder rather than dialled, and drifting in two ways at
/// once. A renamed subcommand is `usage()` and a non-zero exit, which `AgentHooks.ask` reads as "not
/// installed" — the Settings row then shows a green offer to install something that fails. Nothing
/// logs.
///
/// The MARKER is the installed basename. `hook_path` joins `HOOK_MARKER` rather than spelling
/// `slopdesk-agent` a second time, so the two cannot drift; what is pinned is that the CONSTRUCTION
/// survives, because the day someone writes the literal back in is the day an uninstall silently
/// stops matching what an install wrote.
///
/// The relay takes NO dependencies. `serde_json` is the installer's, and it stays out of the binary
/// Claude Code forks twice per tool call only because nothing the relay's `main` reaches can see it.
/// A `use serde_json` in the relay's own two files would not fail a build, a test or a lint — it
/// would just make every tool call slower, which is the one regression this tree has no other way to
/// notice.
///
/// BREAK-TEST: renamed `"uninstall"` in the installer's switch ⇒ FAIL "agenthooks subcommands".
/// Separately rewrote `hook_path` to join the literal ⇒ FAIL "no longer builds the installed name
/// from `HOOK_MARKER`". Separately added `use serde_json;` to the relay's `main.rs` ⇒ FAIL "reaches a
/// dependency". All three restored from /tmp; PASS.
#[must_use]
pub fn the_hooks_installer_is_one_alphabet(tree: &Tree) -> Report {
    check_all(
        tree,
        &[
            Claim::SameSet {
                label: "agenthooks subcommands",
                swift: Extract::code(AGENTHOOKS_FACE, r#"(?:ask|answer)\(\["([a-z]+)"\]\)"#),
                rust: Extract::code(AGENTHOOKS_MAIN, r#"^        "([a-z]+)" =>"#),
            },
            Claim::Within {
                path: HOOK_INSTALL,
                start: HOOK_PATH.0,
                end: HOOK_PATH.1,
                pattern: r#"join\("hooks"\)"#,
                view: View::Code,
                message: "install::hook_path no longer joins the hooks directory — the merge \
                          sentinel and the installed basename must be one constant \
                          (docs/DECISIONS.md, stage 23)",
            },
            Claim::Within {
                path: HOOK_INSTALL,
                start: HOOK_PATH.0,
                end: HOOK_PATH.1,
                pattern: r"\.join\(HOOK_MARKER\)",
                view: View::Code,
                message: "install::hook_path no longer builds the installed name from HOOK_MARKER — \
                          the day the literal is written back in is the day an uninstall silently \
                          stops matching what an install wrote (docs/DECISIONS.md, stage 23)",
            },
            Claim::Lacks {
                path: "rust/slopdesk-hook/src/main.rs",
                pattern: r"^\s*use +(serde|serde_json)\b",
                view: View::Code,
                message: "the hook relay reaches a dependency — its cost IS process startup, it is \
                          forked twice per tool call, and this would fail no build, test or lint \
                          (docs/DECISIONS.md, stage 23)",
            },
            Claim::Lacks {
                path: "rust/slopdesk-hook/src/lib.rs",
                pattern: r"^\s*use +(serde|serde_json)\b",
                view: View::Code,
                message: "the hook relay reaches a dependency — its cost IS process startup, it is \
                          forked twice per tool call, and this would fail no build, test or lint \
                          (docs/DECISIONS.md, stage 23)",
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
                          ~/.claude/settings.json, and the merge, the marker, the event list and \
                          the paths moved in one change (docs/DECISIONS.md, stage 23): {files}",
            },
            Claim::Absent {
                path: "Sources/SlopDeskHost/AgentInstaller.swift",
                message: "the merge lives in rust/slopdesk-hook/src/install.rs \
                          (docs/DECISIONS.md, stage 23)",
            },
        ],
    )
}

/// The probe's subcommands are one alphabet, and emptiness is an answer
///
/// The NINTH contract. Same fork-per-question shape as the seeder and the installer, with one
/// wrinkle neither has: two subcommands answer in RAW BYTES, so their "nothing there" cannot be an
/// empty answer and has to be the exit code.
///
/// An unchanged file has an empty diff and exits 0; a file that is not there exits non-zero.
/// `askBytes` must therefore branch on the STATUS and never on the byte count — the tidy-up that
/// writes `data.isEmpty ? nil : data` turns every unchanged file into a `.notFound`, and does it
/// without failing a build, a test or a lint.
///
/// `lsof` is the one subprocess left on the Swift side; a `git` or an `infocmp` next to it is a
/// ported path coming back — for git, the four-spawns-per-request one.
///
/// BREAK-TEST: renamed `"list-dir"` in the probe's switch ⇒ FAIL "probe subcommands". Separately
/// wrote `data.isEmpty ? nil : data` into `HostProbe` ⇒ FAIL "folds an empty answer into a missing
/// one". Separately restored `static let claudeProjectSlug` under Sources/ ⇒ FAIL "a Swift
/// git/session/terminfo parser is back". Separately wrote `"/usr/bin/git"` into a Swift file ⇒ FAIL
/// "Swift spawns git or infocmp again". All four restored from /tmp; PASS.
#[must_use]
pub fn the_probe_subcommands_are_one_alphabet(tree: &Tree) -> Report {
    check_all(
        tree,
        &[
            Claim::SameSet {
                label: "probe subcommands",
                swift: Extract::code(PROBE_FACE, r#"(?:ask|askBytes)\(\["([a-z-]+)""#),
                rust: Extract::code(PROBE_MAIN, r#"^        "([a-z-]+)" =>"#),
            },
            Claim::Lacks {
                path: PROBE_FACE,
                pattern: r"\bdata\b[A-Za-z0-9_.]*\.isEmpty|\.isEmpty *\? *nil",
                view: View::Code,
                message: "HostProbe folds an empty answer into a missing one — emptiness is the \
                          probe's exit code's job, and branching on the byte count turns every \
                          unchanged file into a .notFound without failing a build, a test or a lint \
                          (docs/DECISIONS.md, stage 24)",
            },
            Claim::NoneUnder {
                roots: &["Sources"],
                extensions: SWIFT,
                pattern: r"(struct|static (let|var|func)|private static func) (parseBranchHeader|parseStatusLine|statusNibble|packStatus|claudeProjectSlug|gitToplevel|gitStashCount|gitDiffArgumentPlan|resolveGitDiff|jsonlSessions|claudeSessions|opencodeSessions|sessionRoots|GhosttyTerminfoProbe|terminfoEntryExists|isGhosttyResolvable|effectiveTerm|liveProbe|runInfocmp)\b",
                all: &[],
                unless: &[],
                view: View::Code,
                exempt: &[],
                message: "a Swift git/session/terminfo parser is back in Sources/ — slopdesk-probe \
                          owns porcelain, the slug, the diff bases and the TERM table \
                          (docs/DECISIONS.md, stages 24 and 25): {files}",
            },
            Claim::NoneUnder {
                roots: &["Sources"],
                extensions: SWIFT,
                pattern: r#""/usr/bin/(git|infocmp)""#,
                all: &[],
                unless: &[],
                view: View::Code,
                exempt: &[],
                message: "Swift spawns git or infocmp again — both belong inside slopdesk-probe, \
                          and `lsof` is the one subprocess left on this side \
                          (docs/DECISIONS.md, stages 24 and 25): {files}",
            },
        ],
    )
}

/// The git status is linked, not forked, and it is asked in exactly one place
///
/// `gitStatus` left the probe entirely: `rust/slopdesk-git` opens the repository once and answers
/// from libgit2, linked into hostd through `slopdesk_git_status`. What that removed was FIVE process
/// spawns per debounced `FSEvents` tick per watched repo — four `git` runs inside one fork of the
/// probe — so a `git status` reappearing anywhere on this path is not a style question, it is the
/// cost coming back.
///
/// Three things are pinned, because the port has three ways to be undone quietly. The face could be
/// rewritten around a `Process` and every test would still pass, the answer being identical and only
/// the spawns differing. A face that grew a fallback parser would be the two-implementations shape
/// CLAUDE.md forbids, and would only show up under an unusual repo. And the verb-set rule above
/// compares hostd's asks with the probe's arms, so a revived `git-status` arm passes it the moment
/// somebody adds the Swift side back — this names the arm itself.
///
/// The porcelain PAIR is spelled once, in the crate that reads it off libgit2's bitflags. The shell
/// banned two names that no longer exist anywhere: both functions were renamed when they moved into
/// `slopdesk-git::porcelain`, and that ban has been matching nothing since. Both halves are stated
/// here instead — the table is where it belongs, and no second copy of either SIGNATURE lives
/// outside the crate. The signature rather than the bare name, because `fn pack(` is too common a
/// spelling to ban across every crate in the tree.
///
/// BREAK-TEST: rewrote `HostGitStatus` around `Process` ⇒ FAIL "no longer calls
/// `slopdesk_git_status`".
/// Separately added a `"git-status"` arm to the probe ⇒ FAIL "answers git-status again". Separately
/// copied `nibble(character: char) -> u8` into another crate ⇒ FAIL "the porcelain nibble table is
/// back outside". All three restored from /tmp; PASS.
#[must_use]
pub fn the_git_status_is_linked_and_asked_once(tree: &Tree) -> Report {
    check_all(
        tree,
        &[
            Claim::Matches {
                path: GIT_FACE,
                pattern: r"slopdesk_git_status",
                view: View::Code,
                message: "HostGitStatus no longer calls slopdesk_git_status — the git line is back \
                          on a subprocess, which is five spawns per debounced FSEvents tick per \
                          watched repo and identical output (docs/55)",
            },
            Claim::Matches {
                path: GIT_STATUS,
                pattern: r"pub fn of_path",
                view: View::Code,
                message: "rust/slopdesk-git no longer answers of_path — the status engine moved \
                          without its ratchet (docs/DECISIONS.md)",
            },
            Claim::Lacks {
                path: PROBE_MAIN,
                pattern: r#""git-status""#,
                view: View::Code,
                message: "slopdesk-probe answers git-status again — the status engine is \
                          rust/slopdesk-git, LINKED, and the verb-set rule would accept this arm \
                          the moment somebody added the Swift side back (docs/DECISIONS.md)",
            },
            Claim::Matches {
                path: GIT_PORCELAIN,
                pattern: r"pub const fn nibble\(character: char\) -> u8",
                view: View::Code,
                message: "rust/slopdesk-git::porcelain no longer holds the nibble table — the \
                          client mirrors its inverse to name a change category, so it is a wire \
                          contract and it has one master (docs/DECISIONS.md)",
            },
            Claim::Matches {
                path: GIT_PORCELAIN,
                pattern: r"pub const fn pack\(x: char, y: char\) -> u8",
                view: View::Code,
                message: "rust/slopdesk-git::porcelain no longer packs the porcelain pair into one \
                          byte — golden/golden_vectors.json freezes that byte (docs/DECISIONS.md)",
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
                message: "the porcelain nibble table is back outside slopdesk-git::porcelain — one \
                          table, one crate, because the old probe's copy lived beside a parser that \
                          is gone: {files}",
            },
        ],
    )
}

/// The pointer tables are one table, and the raw value crosses unparsed
///
/// `slopdesk_terminal::pointer` owns both of libghostty's pointer actions. This is pinned harder
/// than its size suggests, because EVERY way it breaks is silent: a resize handle showing a hand, or
/// a pointer hidden with no gesture that brings it back. Nothing fails to compile, nothing crashes,
/// and `check-macos.sh` is the only thing that would ever have noticed.
///
/// `OSCPointerShape` (34 cases) and `MouseVisibility` existed only so a Swift `switch` had something
/// to switch over, which made THREE copies of one declaration order — libghostty's header, the
/// mirror, the table — where any two could drift while compiling. The raw `int32_t` travels now, and
/// a revived mirror reads like tidying while restoring the drift.
///
/// `PointerShapeToken`'s discriminants ARE the wire, so they are spelled with explicit raw values on
/// both sides and asserted THROUGH the door. A case reordered under implicit numbering is a cursor
/// swapped for another cursor with nothing to notice it.
///
/// The ban's roots are `Sources`, `Tests` and `ThirdParty/ghostty/integration` — the same three the
/// tree walks. The shell reached the last of those through a bare `ThirdParty/`, which read all 8 GB
/// of the vendored checkout through single-threaded grep and cost four minutes of a thirty-nine
/// second gate; here it is not a scope decision at all, because the walk never held the rest.
///
/// BREAK-TEST: deleted `slopdesk_pointer_mouse_visible` from the visibility face ⇒ FAIL "stopped
/// asking the door". Separately restored `enum OSCPointerShape` under Sources/ ⇒ FAIL "a Swift
/// mirror of a libghostty pointer enum is back". Separately dropped `= 0` from `case arrow` ⇒ FAIL
/// "stopped pinning its raw values". All three restored from /tmp; PASS.
#[must_use]
pub fn the_pointer_tables_are_one_table(tree: &Tree) -> Report {
    check_all(
        tree,
        &[
            Claim::Matches {
                path: POINTER_SHAPE,
                pattern: r"slopdesk_pointer_",
                view: View::Code,
                message: "PointerShapeMapping stopped asking the door — a pointer table decided in \
                          Swift is a second table, and every way it breaks is silent (docs/56, \
                          increment 50)",
            },
            Claim::Matches {
                path: POINTER_VISIBILITY,
                pattern: r"slopdesk_pointer_",
                view: View::Code,
                message: "MouseVisibilityMapping stopped asking the door — a pointer hidden with no \
                          gesture that brings it back fails nothing and crashes nothing (docs/56, \
                          increment 50)",
            },
            Claim::NoneUnder {
                roots: &["Sources", "Tests", "ThirdParty/ghostty/integration"],
                extensions: SWIFT,
                pattern: r"enum OSCPointerShape|enum MouseVisibility[^M]",
                all: &[],
                unless: &[],
                view: View::Code,
                exempt: &[],
                message: "a Swift mirror of a libghostty pointer enum is back — the raw int crosses \
                          now, and a mirror restores three copies of one declaration order where \
                          any two could drift while compiling (docs/56, increment 50): {files}",
            },
            Claim::Matches {
                path: POINTER_SHAPE,
                pattern: r"case arrow = 0",
                view: View::Code,
                message: "PointerShapeToken stopped pinning its raw values — its discriminants ARE \
                          the wire, and a case reordered under implicit numbering is a cursor \
                          swapped for another cursor (docs/56, increment 50)",
            },
            Claim::Matches {
                path: POINTER_DOOR,
                pattern: r"the_supported_shapes_cross_as_the_discriminants_swift_is_pinned_to",
                view: View::Code,
                message: "the door's discriminant test is gone — Swift's enum and Rust's can now \
                          renumber apart (docs/56, increment 50)",
            },
        ],
    )
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// A tree where every rule in this module passes.
    fn clis(fixture: &Fixture) {
        for (path, body) in [
            (super::CTL_LISTENER, CTL_LISTENER_BODY),
            (super::CTL_COMMANDS, CTL_COMMANDS_BODY),
            (super::CODESEED_FACE, CODESEED_FACE_BODY),
            (super::CODESEED_MAIN, CODESEED_MAIN_BODY),
            (super::AGENTHOOKS_FACE, AGENTHOOKS_FACE_BODY),
            (super::AGENTHOOKS_MAIN, AGENTHOOKS_MAIN_BODY),
            (super::HOOK_INSTALL, HOOK_INSTALL_BODY),
            ("rust/slopdesk-hook/src/main.rs", "fn main() {}\n"),
            ("rust/slopdesk-hook/src/lib.rs", "pub fn relay() {}\n"),
            (super::PROBE_FACE, PROBE_FACE_BODY),
            (super::PROBE_MAIN, PROBE_MAIN_BODY),
            (super::GIT_FACE, "let n = slopdesk_git_status(p, l, o, c)\n"),
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

    const CTL_LISTENER_BODY: &str = "func handle(_ method: String) {\n    if method == \"subscribe\" \
                                     { return stream() }\n    switch method {\n        \
                                     case \"read\":\n        case \"write\":\n        \
                                     case \"resize\":\n    }\n}\n";
    const CTL_COMMANDS_BODY: &str = "fn read(ctl: &Ctl) {\n    let obj = ctl.call(\"read\", p())?;\n}\n\
                                     fn write(ctl: &Ctl) {\n    let obj = ctl.call(\n        \
                                     \"write\",\n        p(),\n    )?;\n}\n\
                                     fn resize(ctl: &Ctl) {\n    let obj = ctl.call(\"resize\", p())?;\n}\n\
                                     fn stream(ctl: &Ctl) {\n    ctl.stream(\"subscribe\")\n}\n";

    const CODESEED_FACE_BODY: &str = "func seed() {\n    ask([\"seed\"])\n    ask([\"paths\"])\n    \
                                      ask([\n        \"sync-font\",\n        \"--size\",\n    ])\n}\n";
    const CODESEED_MAIN_BODY: &str = "fn main() {\n    match verb {\n        \"seed\" => a(),\n        \
                                      \"paths\" => b(),\n        \"sync-font\" => c(),\n        \
                                      _ => usage(),\n    }\n}\n";

    const AGENTHOOKS_FACE_BODY: &str = "func status() {\n    ask([\"status\"])\n    \
                                        answer([\"install\"])\n    answer([\"uninstall\"])\n}\n";
    const AGENTHOOKS_MAIN_BODY: &str = "fn main() {\n    match verb {\n        \"status\" => a(),\n        \
                                        \"install\" => b(),\n        \"uninstall\" => c(),\n        \
                                        _ => usage(),\n    }\n}\n";
    const HOOK_INSTALL_BODY: &str = "pub const HOOK_MARKER: &str = \"slopdesk-agent\";\n\
                                     pub fn hook_path(home: &Path) -> PathBuf {\n    \
                                     config_base(home).join(\"hooks\").join(HOOK_MARKER)\n}\n";

    const PROBE_FACE_BODY: &str = "func probe() {\n    ask([\"list-dir\", path])\n    \
                                   askBytes([\"git-diff\", path])\n}\n";
    const PROBE_MAIN_BODY: &str = "fn main() {\n    match verb {\n        \"list-dir\" => a(),\n        \
                                   \"git-diff\" => b(),\n        _ => usage(),\n    }\n}\n";

    const PORCELAIN_BODY: &str = "pub const fn nibble(character: char) -> u8 {\n    0\n}\n\
                                  pub const fn pack(x: char, y: char) -> u8 {\n    \
                                  (nibble(x) << 4) | nibble(y)\n}\n";
    const POINTER_SHAPE_BODY: &str = "enum PointerShapeToken: Int32 {\n    case arrow = 0\n    \
                                      case text = 1\n}\nfunc token(_ raw: Int32) -> \
                                      PointerShapeToken? {\n    \
                                      PointerShapeToken(rawValue: slopdesk_pointer_shape_token(raw))\n}\n";

    /// A clean error is what makes this drift silent, so the SET is what is compared.
    #[test]
    fn a_verb_one_side_does_not_know_is_red() {
        let fixture = Fixture::new("ctl-verbs");
        clis(&fixture);
        assert!(super::the_ctl_verb_sets_are_one_alphabet(&fixture.tree()).is_clean());

        fixture.write(
            super::CTL_LISTENER,
            &CTL_LISTENER_BODY.replace("case \"resize\":", "case \"reshape\":"),
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

    /// The wrapped `ask([` is the shape a line-wise extraction drops.
    #[test]
    fn a_wrapped_subcommand_is_still_read() {
        let fixture = Fixture::new("codeseed-wrap");
        clis(&fixture);
        assert!(super::the_codeseed_subcommands_are_one_alphabet(&fixture.tree()).is_clean());

        fixture.write(
            super::CODESEED_MAIN,
            &CODESEED_MAIN_BODY.replace("\"sync-font\" => c(),", "\"font-sync\" => c(),"),
        );
        let report = super::the_codeseed_subcommands_are_one_alphabet(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("codeseed subcommands")),
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
            "pub const HOOK_MARKER: &str = \"slopdesk-agent\";\n\
             pub fn hook_path(home: &Path) -> PathBuf {\n    \
             config_base(home).join(\"hooks\").join(\"slopdesk-agent\")\n}\n",
        );
        let report = super::the_hooks_installer_is_one_alphabet(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("from HOOK_MARKER")),
            "{report:?}"
        );
    }

    /// Emptiness is the exit code's job; folding it in turns every unchanged file into `.notFound`.
    #[test]
    fn a_face_that_folds_empty_into_missing_is_red() {
        let fixture = Fixture::new("probe-empty");
        clis(&fixture);
        assert!(super::the_probe_subcommands_are_one_alphabet(&fixture.tree()).is_clean());

        fixture.write(
            super::PROBE_FACE,
            "func probe() {\n    ask([\"list-dir\", path])\n    let data = askBytes([\"git-diff\", \
             path])\n    return data.isEmpty ? nil : data\n}\n",
        );
        let report = super::the_probe_subcommands_are_one_alphabet(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("folds an empty answer")),
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
            &PROBE_MAIN_BODY.replace("\"git-diff\" => b(),", "\"git-diff\" => b(),\n        \"git-status\" => s(),"),
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
