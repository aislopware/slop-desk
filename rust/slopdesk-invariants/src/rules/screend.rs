//! screend's address, its verb bytes and the number that stays retired.
//!
//! Ported from the deleted `check-supervisor.sh`. Same shape as superd's, same silence when it
//! drifts (docs/52), and the address went the same way for the same reason: both ends resolved the
//! DIRECTORY and disagreed about it, so the rule is `slopdesk_screenwire::socket_path` now and the
//! checks pin its shape rather than two copies of the name.

use crate::claim::{Claim, Extract, View, check_all};
use crate::report::Report;
use crate::text;
use crate::tree::Tree;

const SWIFT_PATHS: &str = "Sources/SlopDeskScreen/ScreenPaths.swift";
const SWIFT_PROTOCOL: &str = "Sources/SlopDeskScreen/ScreenProtocol.swift";
const RUST_PROTOCOL: &str = "rust/slopdesk-screenwire/src/lib.rs";
const RUST_SERVER: &str = "rust/slopdesk-screend/src/server.rs";

/// §9 — screend's rendezvous, its override key, and the pid that may not come back.
///
/// Comments are stripped from `ScreenPaths.swift`: the prose above the resolution NAMES
/// `NSTemporaryDirectory()` on purpose, to record why it is gone — on Darwin that call IGNORES
/// `$TMPDIR`, so the client dialled a path screend never bound and the daemon simply looked absent
/// (measured 2026-08-22, docs/52).
///
/// §1 pins superd's two override keys because the RULE crossing to `slopdesk_superwire` left the
/// lookup behind on each side: the crate is handed values, so it cannot notice that one end read a
/// different variable. screend's address went the same way — `socket_path` takes the override as an
/// argument, so a key renamed on one side only means the client reads an unset variable, resolves
/// the default, and dials a socket a daemon started with the override never bound.
#[must_use]
pub fn address(tree: &Tree) -> Report {
    let claims = [
        Claim::Names {
            path: RUST_PROTOCOL,
            needle: "slopdesk-screend.sock",
            message: "rust/slopdesk-screenwire/src/lib.rs no longer names slopdesk-screend.sock — the \
                      shared address rule lost its name",
        },
        Claim::Names {
            path: RUST_PROTOCOL,
            needle: "pub fn socket_path",
            message: "rust/slopdesk-screenwire/src/lib.rs no longer owns screend's address rule — both ends \
                      would resolve it and only one can be right",
        },
        Claim::Names {
            path: SWIFT_PATHS,
            needle: "slopdesk_screen_socket_path",
            message: "Sources/SlopDeskScreen/ScreenPaths.swift no longer resolves through the door — the \
                      client has no address, or a second one",
        },
        Claim::Lacks {
            path: SWIFT_PATHS,
            pattern: "(getpid|processIdentifier)",
            view: View::Code,
            message: "a pid reached screend's rendezvous address — see docs/51 §1",
        },
        Claim::Lacks {
            path: SWIFT_PATHS,
            pattern: r"NSTemporaryDirectory|slopdesk-screend\.sock",
            view: View::Code,
            message: "Sources/SlopDeskScreen/ScreenPaths.swift builds the address itself again — that \
                      resolution is slopdesk_screenwire's (docs/52)",
        },
        Claim::SameValue {
            label: "screend socket override key",
            swift: Extract::code(SWIFT_PATHS, r#"socketEnvKey = "([A-Z0-9_]*)""#),
            rust: Extract::code(
                RUST_PROTOCOL,
                r#"^pub const SOCKET_ENV_KEY: &str = "([A-Z0-9_]*)""#,
            ),
        },
    ];
    let mut report = check_all(tree, &claims);

    // screend's server may resolve its own address only if it does not have a rule of its own.
    if let (Some(server), Some(_)) = (tree.get(RUST_SERVER), tree.get(RUST_PROTOCOL)) {
        report.fail_if(
            server.text.contains("fn default_socket_path") && !server.text.contains("protocol::socket_path"),
            format!("{RUST_SERVER} resolves its own address instead of the wire crate's rule"),
        );
    }
    report
}

/// §9 continued — verb NUMBERS, not names, and the one that stays retired.
///
/// The wire carries the byte, and a reordered enum on one side is a `compose` answered with a
/// `transcript` — same status, same framing, silently the wrong bytes. Scoped to the `ScreenVerb`
/// enum: `ScreenStatus` right below it spells `case ok = 0` too, and a whole-file sweep would
/// compare a status against a verb.
///
/// Verb 7 is RETIRED on both sides and must stay unallocated. It was `sanitize` — the whole replay
/// transform reached over a socket, which was the mistake: `sanitize` is a pure function, so by
/// this repo's own socket-vs-library rule it belongs linked, and it is `rust/slopdesk-sanitize`
/// now. Reusing the number would let a hostd built before the extraction land its cold reattach on
/// a verb that means something else entirely. Scoped to each enum for the reason above:
/// `ScreenStatus` is free to grow a 7.
#[must_use]
pub fn verbs(tree: &Tree) -> Report {
    let mut report = Report::new();
    let (Some(swift), Some(rust)) = (
        report.source(tree, SWIFT_PROTOCOL, "screend's Swift verbs live there"),
        report.source(tree, RUST_PROTOCOL, "screend's Rust verbs live there"),
    ) else {
        return report;
    };

    let swift_verbs = text::range(swift.code(), r"public enum ScreenVerb", r"^\}");
    let pairs = text::cached(r"(?m)^ *case ([a-z][a-zA-Z]*) = ([0-9]+)$");
    let mut seen = 0usize;
    for caps in pairs.captures_iter(&swift_verbs) {
        let (Some(name), Some(number)) = (caps.get(1), caps.get(2)) else {
            continue;
        };
        seen += 1;
        let (name, number) = (name.as_str(), number.as_str());
        let mut rust_name = String::with_capacity(name.len());
        let mut chars = name.chars();
        if let Some(first) = chars.next() {
            rust_name.extend(first.to_uppercase());
        }
        rust_name.push_str(chars.as_str());
        report.fail_if(
            !text::matches(&rust.text, &format!("(?m)^ *{rust_name} = {number},$")),
            format!(
                "screend verb '{name}' is {number} in Swift but not '{rust_name} = {number}' in \
                 {RUST_PROTOCOL}",
            ),
        );
    }
    report.fail_if(
        seen == 0,
        format!("no screend verbs found in {SWIFT_PROTOCOL} — the extraction in this gate has gone stale"),
    );

    report.fail_if(
        text::matches(&swift_verbs, "(?m)= 7$"),
        format!(
            "{SWIFT_PROTOCOL} allocated screend verb 7 again — it is retired, the replay transform is \
             linked (docs/52)",
        ),
    );
    report.fail_if(
        text::matches(&text::range(&rust.text, r"pub enum Verb", r"^\}"), "(?m)= 7,$"),
        format!(
            "{RUST_PROTOCOL} allocated screend verb 7 again — it is retired, the replay transform is linked \
             (docs/52)",
        ),
    );
    report
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    const SWIFT_VERBS: &str = "
public enum ScreenVerb: UInt8 {
    case compose = 1
    case transcript = 2
}
public enum ScreenStatus: UInt8 {
    case ok = 0
}
";

    const RUST_VERBS: &str = "
pub enum Verb {
    Compose = 1,
    Transcript = 2,
}
pub enum Status {
    Ok = 0,
}
";

    fn fixture_for(name: &str) -> Fixture {
        let fixture = Fixture::new(name);
        fixture
            .write("Sources/SlopDeskScreen/ScreenProtocol.swift", SWIFT_VERBS)
            .write("rust/slopdesk-screenwire/src/lib.rs", RUST_VERBS);
        fixture
    }

    /// A reordered enum is a `compose` answered with a `transcript`: same status, same framing,
    /// silently the wrong bytes.
    #[test]
    fn a_verb_renumbered_on_one_side_is_caught() {
        let fixture = fixture_for("screend-verbs");
        assert!(super::verbs(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-screenwire/src/lib.rs",
            &RUST_VERBS.replace("Compose = 1", "Compose = 3"),
        );
        let report = super::verbs(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("'compose' is 1")),
            "{report:?}"
        );
    }

    /// The status enum right below the verbs spells `case ok = 0` too. A whole-file sweep would
    /// compare a status against a verb, which is why both sides are scoped to their enum.
    #[test]
    fn the_status_enum_is_not_mistaken_for_a_verb() {
        let fixture = fixture_for("screend-scope");
        assert!(super::verbs(&fixture.tree()).is_clean());
    }

    /// Verb 7 was `sanitize`, reached over a socket. Reusing the number lands an old hostd's cold
    /// reattach on a verb that means something else.
    #[test]
    fn reallocating_the_retired_verb_is_caught_on_both_sides() {
        let fixture = fixture_for("screend-seven");
        fixture.write(
            "Sources/SlopDeskScreen/ScreenProtocol.swift",
            &SWIFT_VERBS.replace(
                "    case transcript = 2",
                "    case transcript = 2\n    case revived = 7",
            ),
        );
        let report = super::verbs(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("verb 7 again")),
            "{report:?}"
        );

        let rust_side = fixture_for("screend-seven-rust");
        rust_side.write(
            "rust/slopdesk-screenwire/src/lib.rs",
            &RUST_VERBS.replace("    Transcript = 2,", "    Transcript = 2,\n    Revived = 7,"),
        );
        let report = super::verbs(&rust_side.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("verb 7 again")),
            "{report:?}"
        );
    }

    /// The client dialling a path screend never bound is the symptom of every drift here, and it
    /// reads as "the daemon is not running".
    #[test]
    fn the_client_rebuilding_the_address_itself_is_caught() {
        let fixture = Fixture::new("screend-address");
        fixture
            .write(
                "Sources/SlopDeskScreen/ScreenPaths.swift",
                "// NSTemporaryDirectory() is named here in prose on purpose.\nlet key = socketEnvKey = \
                 \"SLOPDESK_SCREEND_SOCKET\"\nreturn slopdesk_screen_socket_path()\n",
            )
            .write(
                "rust/slopdesk-screenwire/src/lib.rs",
                "pub const SOCKET_ENV_KEY: &str = \"SLOPDESK_SCREEND_SOCKET\";\npub fn socket_path() \
                 {}\nconst NAME: &str = \"slopdesk-screend.sock\";\n",
            );
        assert!(super::address(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskScreen/ScreenPaths.swift",
            "let key = socketEnvKey = \"SLOPDESK_SCREEND_SOCKET\"\nreturn NSTemporaryDirectory() + \
             \"/slopdesk-screend.sock\"\nlet _ = slopdesk_screen_socket_path\n",
        );
        let report = super::address(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("builds the address itself")),
            "{report:?}"
        );
    }
}
