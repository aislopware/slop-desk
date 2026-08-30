//! What hostd asks the artifact, and how — the foreground-process vocabulary, the binary search
//! order, and the four doors that must never be probed for a length.
//!
//! Ported from the deleted `check-supervisor.sh`. The last of these is the odd one: a null-output
//! probe is a SUPPORTED call that costs the whole answer twice, so both calls agree, every result
//! is correct, and the only trace is a git line that lands a beat late.

use crate::claim::{Claim, RUST, View, check_all};
use crate::paths::HOSTD_CRATES;
use crate::report::Report;
use crate::tree::Tree;

/// One vocabulary for a foreground process name
///
/// The `claude` and wrapper matches already reduced a process name in Rust while Swift kept its own
/// reducer beside them, plus the version-directory walk and an eleven-name sensitive set with no
/// Rust twin at all. One name, read three ways, must reduce the same way each time.
///
/// The BUNDLE-ID end of the vocabulary moved the same way the process end did, one document later.
/// `HostFrontmostApp.swift` was a face over two doors and `docs/61` deleted it with the rest of the
/// Swift host; `rust/slopdesk-videohostd` asks `slopdesk_apple_app` directly, so the claim is
/// re-aimed at the daemon rather than dropped. It keeps saying what it always said — the host
/// ASKS for a running application's identity rather than reaching for the framework that answers —
/// and the ban beside it is the shape that would mean it had stopped: an `AppKit` type named in the
/// daemon, which is the one language a second frontmost-app rule could now be written in. Every
/// effect on the system is Rust's, but it is `slopdesk-apple-*`'s Rust, and only through `objc2`
/// (`docs/57` §5) — a raw `NSRunningApplication` here is that floor breached and a second identity
/// vocabulary in one move.
#[must_use]
pub fn one_vocabulary_for_foreground_process(tree: &Tree) -> Report {
    let claims = [
        // hostd asked the vocabulary through `slopdesk_pty_foreground_*` until `docs/60` F.9; it links
        // `slopdesk-agent` directly now, so the doors and the face they crossed are both gone. The BAN
        // is what survives, because nothing in the build graph stops a host crate from reducing a
        // process name a second way — and one name read three ways must reduce the same each time.
        Claim::NoneUnder {
            roots: HOSTD_CRATES,
            extensions: RUST,
            pattern: r#"is_version_shaped|"versions""#,
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} reduces a process name again — slopdesk-agent::process owns the basename and \
                      the version walk",
        },
        Claim::NoneOf {
            paths: &["rust/slopdesk-ffi/include/slopdesk_ffi.h"],
            pattern: r"slopdesk_agent_job_new|slopdesk_agent_job_push_process|slopdesk_agent_resolve_fn",
            view: View::Code,
            message: "{files} — the foreground job staging handle is back; the vocabulary is one module",
        },
        Claim::NoneUnder {
            roots: HOSTD_CRATES,
            extensions: RUST,
            pattern: r#"sensitive_basenames|"sshpass"|"doas""#,
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} lists the sensitive commands itself — the set is SENSITIVE_BASENAMES in \
                      slopdesk-agent, and an eleven-name list written twice diverges in one direction only",
        },
        Claim::Names {
            path: "Sources/SlopDeskAgentDetect/ForegroundProcessName.swift",
            needle: "slopdesk_agent_is_sensitive",
            message: "Sources/SlopDeskAgentDetect/ForegroundProcessName.swift stopped asking the door — it \
                      is a face, not a second rule",
        },
        Claim::Mentions {
            path: "rust/slopdesk-agent/src/process.rs",
            names: &[
                "pub fn is_sensitive",
                "pub fn canonical_name",
                "pub fn is_version_shaped",
                "pub fn basename",
            ],
            message: "rust/slopdesk-agent/src/process.rs lost {entry} — the foreground vocabulary is one \
                      module",
        },
        // Named as a DIRECTORY, the way `crate::rules::video_host` argues: the daemon's window
        // source is still being split, and this claim is about the host asking rather than about
        // which of its files does.
        Claim::MentionsUnder {
            root: "rust/slopdesk-videohostd",
            names: &["slopdesk_apple_app"],
            message: "the daemon stopped asking {entry} — a running application's bundle id and hidden \
                      state are that crate's, and a host that stopped asking has started reading the \
                      framework itself (docs/57 §5, docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &["rust/slopdesk-videohostd"],
            extensions: RUST,
            pattern: r"\bNSRunningApplication\b|\bobjc2_app_kit\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon reaches AppKit for a running application in {files} — that is a second \
                      identity vocabulary AND the objc2 floor breached in one line; the wrapper is \
                      slopdesk-apple-app (docs/57 §5)",
        },
    ];
    check_all(tree, &claims)
}

/// hostd finds a program by one order, and asks the expensive doors once
///
/// `docs/55` §4 makes `(NULL, 0)` a supported way to ask a door for its length, and for a door
/// whose rule is a table lookup it costs a nanosecond. For a door whose rule is WORK it costs the
/// work TWICE, and these four — `git_status`, `plaintext_strip`, and both Annex-B walks — are the
/// ones where that is measurable: 53 ms to 26 ms per `FSEvents` tick, and half a millisecond PER
/// FRAME. The failure mode no test can see is that both calls agree and every answer is correct;
/// the only trace is a git line that lands a beat late and a phone mirror that drops frames on a
/// busy host. So the ban is paired with a presence half, because a probe deletes the first GUESS as
/// well as the retry.
///
/// The search order is the same shape of drift one level up. `docs/46` states one order and named
/// the Swift copy as the rule with the Rust one "mirrored" from it — and the pair had already
/// stopped agreeing on what makes a candidate executable: Swift's `isExecutableFile` is `X_OK`, so
/// a DIRECTORY named `code-server` on `PATH` was handed to `posix_spawn`, where Rust's
/// `mode & 0o111` walks past it. Neither disagreement can raise an error, because only one side
/// ever runs on a given path.
///
/// The null-output half reads `Sources` alone and stays there. It is a ban on a CALL SHAPE that
/// costs a caller a wasted rule evaluation, not on a second implementation — and a test that asks a
/// door for its length is exercising the door's own contract, where the waste is the point of the
/// measurement. [`crate::claim::SWIFT_ROOTS`] is for the bans a test hit would be a bug for; this
/// is not one of them.
#[must_use]
pub fn hostd_finds_program_by_one(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: &["swift"],
            pattern: r"slopdesk_(git_status|plaintext_strip|annexb_to_avcc|annexb_split)\([^)]*nil, *0\)",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} asks an expensive door for a length with a null output — that runs its whole \
                      rule and throws the answer away. Guess, then retry (docs/55 §4)",
        },
        // Two of the four expensive doors — `git_status` and `plaintext_strip` — had hostd as their
        // ONLY caller, so `docs/60` F.9 took the doors, the faces and the guess-then-retry with them:
        // hostd calls `slopdesk_git` and `slopdesk_sanitize` as crates now and there is no length to
        // probe for. What is left of this half is the Annex-B pair, whose caller is the device panel
        // and is still Swift.
        Claim::Mentions {
            path: "Sources/SlopDeskDevicePanels/Android/AndroidStreamProtocol.swift",
            names: &["avccSlack", "spanFloor"],
            message: "Sources/SlopDeskDevicePanels/Android/AndroidStreamProtocol.swift no longer spells \
                      '{entry}' — the guess-then-retry that halved this path is gone (docs/55 §4, §6)",
        },
        Claim::MentionsUnder {
            root: "rust/slopdesk-hostd",
            names: &["locate_tool"],
            message: "no file under rust/slopdesk-hostd asks {entry} any more — hostd's search order is \
                      rust/slopdesk-androidd/src/toolchain.rs, once",
        },
        Claim::NoneUnder {
            roots: HOSTD_CRATES,
            extensions: RUST,
            // The trailing quote is what separates a bin DIRECTORY from a fully-qualified binary: a
            // test that seeds a fake locator with `/usr/local/bin/slopdesk-inspectord` is naming one
            // program, not re-deriving the order, and banning it would be a ban on the fixtures of
            // the code this protects.
            pattern: r#"(/opt/homebrew/bin|/usr/local/bin|\.local/bin)""#,
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} spells a bin directory again — the whole order is locate_tool, and a second \
                      copy of it drifts silently: the pair had already stopped agreeing on what makes a \
                      candidate executable (docs/46, vendored runtime deps)",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    //! Almost every seed here is Rust — under [`HOSTD_CRATES`](crate::paths::HOSTD_CRATES) for the
    //! process vocabulary, under `rust/slopdesk-videohostd` for the bundle-id half — because that
    //! is where the drift can be written now: a Swift pattern translated by hand would match none
    //! of the tree and the rule would pass while guarding nothing. The two Swift seeds that remain
    //! are the two faces that are still Swift.

    use crate::tests::Fixture;

    /// A tree where the vocabulary lives in one module and hostd asks rather than re-derives.
    fn write_one_vocabulary_for_foreground_process(fixture: &Fixture) {
        fixture
            .write(
                "rust/slopdesk-ffi/include/slopdesk_ffi.h",
                "kept so the ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-hostsession/src/detect.rs",
                "let name = process::canonical_name(raw);\n",
            )
            .write(
                "Sources/SlopDeskAgentDetect/ForegroundProcessName.swift",
                "slopdesk_agent_is_sensitive\nkept so the ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-agent/src/process.rs",
                "pub fn is_sensitive\npub fn canonical_name\npub fn is_version_shaped\npub fn \
                 basename\nkept so the ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-videohostd/src/windowsource.rs",
                "slopdesk_apple_app::bundle_id(pid)\nkept so the ban has a haystack\n",
            );
    }

    #[test]
    fn one_vocabulary_for_foreground_process_holds_hostd_to_the_one_module() {
        let fixture = Fixture::new("one-vocabulary-for-foreground-process");
        write_one_vocabulary_for_foreground_process(&fixture);
        assert!(super::one_vocabulary_for_foreground_process(&fixture.tree()).is_clean());

        // The version walk, respelled in a host crate. One name read three ways must reduce the
        // same.
        fixture.append(
            "rust/slopdesk-hostsession/src/detect.rs",
            "if segment == \"versions\" { continue; }\n",
        );
        assert!(!super::one_vocabulary_for_foreground_process(&fixture.tree()).is_clean());

        // And the eleven-name set, which had no second copy anywhere until somebody wrote one.
        write_one_vocabulary_for_foreground_process(&fixture);
        fixture.append(
            "rust/slopdesk-hostsession/src/detect.rs",
            "const SENSITIVE: &[&str] = &[\"sshpass\", \"doas\"];\n",
        );
        assert!(!super::one_vocabulary_for_foreground_process(&fixture.tree()).is_clean());

        // The module that owns it, gone.
        write_one_vocabulary_for_foreground_process(&fixture);
        fixture.write("rust/slopdesk-agent/src/process.rs", "");
        assert!(!super::one_vocabulary_for_foreground_process(&fixture.tree()).is_clean());

        // The bundle-id half, respelled where the window source runs: AppKit reached for directly
        // is a second identity vocabulary and the objc2 floor breached at once.
        write_one_vocabulary_for_foreground_process(&fixture);
        fixture.append(
            "rust/slopdesk-videohostd/src/windowsource.rs",
            "let app = NSRunningApplication::runningApplicationWithProcessIdentifier(pid);\n",
        );
        assert!(!super::one_vocabulary_for_foreground_process(&fixture.tree()).is_clean());

        // And the daemon that stopped asking the wrapper at all — nothing is respelled here, so
        // only the ask can fail.
        write_one_vocabulary_for_foreground_process(&fixture);
        fixture.write(
            "rust/slopdesk-videohostd/src/windowsource.rs",
            "let id = self.owner;\n",
        );
        assert!(!super::one_vocabulary_for_foreground_process(&fixture.tree()).is_clean());
    }

    /// A tree where the search order is asked for, and the Annex-B caller still guesses first.
    fn write_hostd_finds_program_by_one(fixture: &Fixture) {
        fixture
            .write("Sources/Generated.swift", "kept so the ban has a haystack\n")
            .write(
                "Sources/SlopDeskDevicePanels/Android/AndroidStreamProtocol.swift",
                "avccSlack\nspanFloor\nkept so the ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-hostd/src/services.rs",
                "slopdesk_androidd::toolchain::locate_tool(&name, &roots)\n",
            );
    }

    #[test]
    fn hostd_finds_program_by_one_holds_the_order_on_one_side() {
        let fixture = Fixture::new("hostd-finds-program-by-one");
        write_hostd_finds_program_by_one(&fixture);
        assert!(super::hostd_finds_program_by_one(&fixture.tree()).is_clean());

        // hostd stopped asking — the order grew back where the call used to be.
        fixture.write(
            "rust/slopdesk-hostd/src/services.rs",
            "let bin = search(&name);\n",
        );
        assert!(!super::hostd_finds_program_by_one(&fixture.tree()).is_clean());

        // And a bin directory respelled, which is that order forking in two.
        write_hostd_finds_program_by_one(&fixture);
        fixture.append(
            "rust/slopdesk-hostserver/src/ensure.rs",
            "let candidate = Path::new(\"/opt/homebrew/bin\").join(name);\n",
        );
        assert!(!super::hostd_finds_program_by_one(&fixture.tree()).is_clean());

        // The half no other claim covers: a call that is CORRECT and costs its whole rule twice.
        // Only the Annex-B pair can still be asked this way — hostd calls its crates directly.
        write_hostd_finds_program_by_one(&fixture);
        fixture.append(
            "Sources/SlopDeskDevicePanels/Android/AndroidStreamProtocol.swift",
            "let needed = slopdesk_annexb_to_avcc(input.baseAddress, input.count, nil, 0)\n",
        );
        assert!(!super::hostd_finds_program_by_one(&fixture.tree()).is_clean());
    }
}
