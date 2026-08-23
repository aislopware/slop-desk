//! What hostd asks the artifact, and how — the foreground-process vocabulary, the binary search
//! order, and the four doors that must never be probed for a length.
//!
//! Ported from `scripts/check-supervisor.sh`. The last of these is the odd one: a null-output probe
//! is a SUPPORTED call that costs the whole answer twice, so both calls agree, every result is
//! correct, and the only trace is a git line that lands a beat late.

use crate::claim::{Claim, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// One vocabulary for a foreground process name
///
/// The `claude` and wrapper matches already reduced a process name in Rust while Swift kept its own
/// reducer beside them, plus the version-directory walk and an eleven-name sensitive set with no
/// Rust twin at all. One name, read three ways, must reduce the same way each time.
#[must_use]
pub fn one_vocabulary_for_foreground_process(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneOf {
            paths: &["Sources/SlopDeskHost/ForegroundProcessProbes.swift"],
            pattern: r#"split\(separator: "/"\)|isVersionShaped|"versions""#,
            view: View::Code,
            message: "{files} reduces a process name again — slopdesk-agent::process owns the basename and \
                      the version walk",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskHost/ForegroundProcessProbes.swift",
            names: &["slopdesk_pty_foreground_name", "slopdesk_pty_foreground_agent"],
            message: "Sources/SlopDeskHost/ForegroundProcessProbes.swift stopped asking {entry} — it is a \
                      face over the probe, not a second one",
        },
        Claim::NoneOf {
            paths: &["rust/slopdesk-ffi/include/slopdesk_ffi.h"],
            pattern: r"slopdesk_agent_job_new|slopdesk_agent_job_push_process|slopdesk_agent_resolve_fn",
            view: View::Code,
            message: "{files} — the foreground job staging handle is back; slopdesk_pty_foreground_agent \
                      asks it in one call",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskHost/AgentControlListener.swift"],
            pattern: r#"sensitiveBasenames|"sshpass"|"doas""#,
            view: View::Code,
            message: "{files} lists the sensitive commands in Swift — the set is SENSITIVE_BASENAMES in Rust",
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
        Claim::Names {
            path: "Sources/SlopDeskVideoHost/HostFrontmostApp.swift",
            needle: "slopdesk_app_bundle_id",
            message: "Sources/SlopDeskVideoHost/HostFrontmostApp.swift stopped asking the bundle-id door — \
                      it is a face over two doors",
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
        Claim::Mentions {
            path: "Sources/SlopDeskHost/HostGitStatus.swift",
            names: &["firstGuess"],
            message: "Sources/SlopDeskHost/HostGitStatus.swift no longer spells '{entry}' — the \
                      guess-then-retry that halved this path is gone (docs/55 §4, §6)",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskHost/ANSIStripper.swift",
            names: &["needed > room.count"],
            message: "Sources/SlopDeskHost/ANSIStripper.swift no longer spells '{entry}' — the \
                      guess-then-retry that halved this path is gone (docs/55 §4, §6)",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskDevicePanels/Android/AndroidStreamProtocol.swift",
            names: &["avccSlack", "spanFloor"],
            message: "Sources/SlopDeskDevicePanels/Android/AndroidStreamProtocol.swift no longer spells \
                      '{entry}' — the guess-then-retry that halved this path is gone (docs/55 §4, §6)",
        },
        Claim::Names {
            path: "Sources/SlopDeskHost/HostServiceProcess.swift",
            needle: "slopdesk_host_service_binary(",
            message: "Sources/SlopDeskHost/HostServiceProcess.swift no longer calls \
                      slopdesk_host_service_binary — hostd's search order is \
                      rust/slopdesk-androidd/src/toolchain.rs",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskHost/HostServiceProcess.swift"],
            pattern: r"/opt/homebrew/bin|/usr/local/bin|\.local/bin|isExecutableFile",
            view: View::Code,
            message: "Sources/SlopDeskHost/HostServiceProcess.swift spells a bin directory or an \
                      executability test again — the whole order is locate_tool, and a second copy of it \
                      drifts silently (docs/46, vendored runtime deps)",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    fn write_one_vocabulary_for_foreground_process(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskHost/ForegroundProcessProbes.swift",
                "slopdesk_pty_foreground_name\nslopdesk_pty_foreground_agent\nkept so the ban has a \
                 haystack\n",
            )
            .write(
                "rust/slopdesk-ffi/include/slopdesk_ffi.h",
                "kept so the ban has a haystack\n",
            )
            .write(
                "Sources/SlopDeskHost/AgentControlListener.swift",
                "kept so the ban has a haystack\n",
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
                "Sources/SlopDeskVideoHost/HostFrontmostApp.swift",
                "slopdesk_app_bundle_id\nkept so the ban has a haystack\n",
            );
    }

    #[test]
    fn one_vocabulary_for_foreground_process_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("one-vocabulary-for-foreground-process");
        write_one_vocabulary_for_foreground_process(&fixture);
        assert!(super::one_vocabulary_for_foreground_process(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskHost/ForegroundProcessProbes.swift", "");
        assert!(!super::one_vocabulary_for_foreground_process(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_one_vocabulary_for_foreground_process(&fixture);
        fixture.append(
            "Sources/SlopDeskHost/ForegroundProcessProbes.swift",
            "split(separator: \"/\")\n",
        );
        assert!(!super::one_vocabulary_for_foreground_process(&fixture.tree()).is_clean());
    }

    fn write_hostd_finds_program_by_one(fixture: &Fixture) {
        fixture
            .write("Sources/Generated.swift", "kept so the ban has a haystack\n")
            .write(
                "Sources/SlopDeskHost/HostGitStatus.swift",
                "firstGuess\nkept so the ban has a haystack\n",
            )
            .write(
                "Sources/SlopDeskHost/ANSIStripper.swift",
                "needed > room.count\nkept so the ban has a haystack\n",
            )
            .write(
                "Sources/SlopDeskDevicePanels/Android/AndroidStreamProtocol.swift",
                "avccSlack\nspanFloor\nkept so the ban has a haystack\n",
            )
            .write(
                "Sources/SlopDeskHost/HostServiceProcess.swift",
                "slopdesk_host_service_binary(\nkept so the ban has a haystack\n",
            );
    }

    #[test]
    fn hostd_finds_program_by_one_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("hostd-finds-program-by-one");
        write_hostd_finds_program_by_one(&fixture);
        assert!(super::hostd_finds_program_by_one(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskHost/HostGitStatus.swift", "");
        assert!(!super::hostd_finds_program_by_one(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_hostd_finds_program_by_one(&fixture);
        fixture.append(
            "Sources/SlopDeskHost/HostServiceProcess.swift",
            "/opt/homebrew/bin\n",
        );
        assert!(!super::hostd_finds_program_by_one(&fixture.tree()).is_clean());

        // The half no other claim covers: a call that is CORRECT and costs its whole rule twice.
        write_hostd_finds_program_by_one(&fixture);
        fixture.append(
            "Sources/SlopDeskHost/HostGitStatus.swift",
            "let needed = slopdesk_git_status(input.baseAddress, input.count, nil, 0)\n",
        );
        assert!(!super::hostd_finds_program_by_one(&fixture.tree()).is_clean());
    }
}
