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

/// hostd's end of screend's address, Rust since `docs/60` Batch B deleted `ScreenPaths.swift`.
const CLIENT_PATHS: &str = "rust/slopdesk-screenclient/src/paths.rs";
const RUST_PROTOCOL: &str = "rust/slopdesk-screenwire/src/lib.rs";
const RUST_SERVER: &str = "rust/slopdesk-screend/src/server.rs";

/// §9 — screend's rendezvous, its override key, and the pid that may not come back.
///
/// Comments are stripped from the client's path module: the prose above the resolution NAMES the
/// socket on purpose, to record what the shared rule picks and why the second resolution is gone.
/// The Swift half resolved the directory with `NSTemporaryDirectory()`, which on Darwin IGNORES
/// `$TMPDIR`, so the client dialled a path screend never bound and the daemon simply looked absent
/// (measured 2026-08-22, docs/52). That end is Rust now, and the ban is what keeps it from
/// re-deriving anything at all.
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
            path: CLIENT_PATHS,
            needle: "slopdesk_screenwire::socket_path",
            message: "rust/slopdesk-screenclient/src/paths.rs no longer resolves through the shared rule — \
                      the client has no address, or a second one",
        },
        Claim::Lacks {
            path: CLIENT_PATHS,
            pattern: "(getpid|process::id)",
            view: View::Code,
            message: "a pid reached screend's rendezvous address — see docs/51 §1",
        },
        // Still a SameValue, and still worth one: `socket_path` takes the override as an ARGUMENT,
        // so the two ends each spell the KEY they look up. Both sides being Rust changes nothing —
        // a key renamed on one side only means the client reads an unset variable, resolves the
        // default, and dials a socket the daemon never bound.
        Claim::SameValue {
            label: "screend socket override key",
            swift: Extract::code(
                CLIENT_PATHS,
                r#"^pub const SOCKET_ENV_KEY: &str = "([A-Z0-9_]*)""#,
            ),
            rust: Extract::code(
                RUST_PROTOCOL,
                r#"^pub const SOCKET_ENV_KEY: &str = "([A-Z0-9_]*)""#,
            ),
        },
    ];
    let mut report = check_all(tree, &claims);

    // The address literal, banned in CODE up to `#[cfg(test)]` only. Both exclusions are load-bearing
    // here: the doc comment above the resolution NAMES the socket to record what the rule picks, and
    // the suite asserts the resolution BY spelling the resulting path. Matching either would be the
    // gate failing on its own documentation and its own proof — the same shape superd's half of this
    // rule already needed.
    if let Some(client) = report.source(tree, CLIENT_PATHS, "hostd's end of screend's address lives there") {
        let code = text::before(client.code(), r"#\[cfg\(test\)\]");
        report.fail_if(
            text::matches(&code, r"slopdesk-screend\.sock"),
            format!(
                "{CLIENT_PATHS} builds the address itself again — that resolution is slopdesk_screenwire's \
                 (docs/52)",
            ),
        );
    }

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
/// The wire carries the byte, and this used to compare screenwire's enum against a Swift one — a
/// reordering on either side being a `compose` answered with a `transcript`: same status, same
/// framing, silently the wrong bytes. There is one enum now, so that half went with its language.
///
/// Verb 7 is RETIRED and must stay unallocated, and THAT half cannot go. It was `sanitize` — the
/// whole replay transform reached over a socket, which was the mistake: `sanitize` is a pure
/// function, so by this repo's own socket-vs-library rule it belongs linked, and it is
/// `rust/slopdesk-sanitize` now. Reusing the number would let a hostd built before the extraction
/// land its cold reattach on a verb that means something else entirely — a skew against a DEPLOYED
/// build, which no amount of one-implementation buys back.
///
/// Scoped to `pub enum Verb`: `Status` right below it spells `Ok = 0` too and is free to grow a 7,
/// so a whole-file sweep would report a status as a reallocated verb. A scoped extraction has its
/// own failure — the enum renamed out from under it reads an empty haystack and passes forever —
/// so the emptiness is checked rather than assumed.
#[must_use]
pub fn verbs(tree: &Tree) -> Report {
    let mut report = Report::new();
    let Some(rust) = report.source(tree, RUST_PROTOCOL, "screend's verbs live there") else {
        return report;
    };

    // ONE-SIDED since `docs/60` Batch B: the Swift enum this used to compare against is gone, and
    // with it the reordering it guarded. What CANNOT go away is the retirement — a hostd built
    // before `sanitize` was extracted would land its cold reattach on whatever verb 7 means now.
    let verbs = text::range(&rust.text, r"pub enum Verb", r"^\}");
    report.fail_if(
        verbs.trim().is_empty(),
        format!("no screend verbs found in {RUST_PROTOCOL} — the extraction in this gate has gone stale"),
    );
    report.fail_if(
        text::matches(&verbs, "(?m)= 7,$"),
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
        fixture.write("rust/slopdesk-screenwire/src/lib.rs", RUST_VERBS);
        fixture
    }

    /// The half that survived the language going away: a gate whose extraction has gone stale reads
    /// an empty haystack and passes forever, which is how the verb-7 ban would die silently.
    #[test]
    fn the_verb_enum_moving_out_from_under_the_gate_is_caught() {
        let fixture = fixture_for("screend-verbs");
        assert!(super::verbs(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-screenwire/src/lib.rs",
            &RUST_VERBS.replace("pub enum Verb", "pub enum ScreenVerb"),
        );
        let report = super::verbs(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("gone stale")),
            "{report:?}"
        );
    }

    /// The status enum right below the verbs spells `Ok = 0` too, and would spell a 7 of its own
    /// happily. A whole-file sweep would report that as a reallocated verb, which is why the
    /// extraction is scoped to `pub enum Verb`.
    #[test]
    fn the_status_enum_is_not_mistaken_for_a_verb() {
        let fixture = fixture_for("screend-scope");
        fixture.write(
            "rust/slopdesk-screenwire/src/lib.rs",
            &RUST_VERBS.replace("    Ok = 0,", "    Ok = 0,\n    Wedged = 7,"),
        );
        assert!(super::verbs(&fixture.tree()).is_clean());
    }

    /// Verb 7 was `sanitize`, reached over a socket. Reusing the number lands an old hostd's cold
    /// reattach on a verb that means something else.
    #[test]
    fn reallocating_the_retired_verb_is_caught() {
        let fixture = fixture_for("screend-seven");
        fixture.write(
            "rust/slopdesk-screenwire/src/lib.rs",
            &RUST_VERBS.replace("    Transcript = 2,", "    Transcript = 2,\n    Revived = 7,"),
        );
        let report = super::verbs(&fixture.tree());
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
                super::CLIENT_PATHS,
                "pub const SOCKET_ENV_KEY: &str = \"SLOPDESK_SCREEND_SOCKET\";\npub fn resolve() -> PathBuf \
                 { slopdesk_screenwire::socket_path(override_path) }\n",
            )
            .write(
                super::RUST_PROTOCOL,
                "pub const SOCKET_ENV_KEY: &str = \"SLOPDESK_SCREEND_SOCKET\";\npub fn socket_path() \
                 {}\nconst NAME: &str = \"slopdesk-screend.sock\";\n",
            );
        assert!(super::address(&fixture.tree()).is_clean());

        fixture.write(
            super::CLIENT_PATHS,
            "pub const SOCKET_ENV_KEY: &str = \"SLOPDESK_SCREEND_SOCKET\";\npub fn resolve() -> PathBuf { \
             temp_dir().join(\"slopdesk-screend.sock\") }\nlet _ = slopdesk_screenwire::socket_path;\n",
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

    /// A key renamed on one side only means the client reads an unset variable, resolves the
    /// default, and dials a socket the daemon never bound. Both sides being Rust does not help —
    /// they are two crates and two literals.
    #[test]
    fn an_override_key_renamed_on_one_side_only_is_caught() {
        let fixture = Fixture::new("screend-env-key");
        fixture
            .write(
                super::CLIENT_PATHS,
                "pub const SOCKET_ENV_KEY: &str = \"SLOPDESK_SCREEND_SOCK\";\npub fn resolve() -> PathBuf { \
                 slopdesk_screenwire::socket_path(override_path) }\n",
            )
            .write(
                super::RUST_PROTOCOL,
                "pub const SOCKET_ENV_KEY: &str = \"SLOPDESK_SCREEND_SOCKET\";\npub fn socket_path() \
                 {}\nconst NAME: &str = \"slopdesk-screend.sock\";\n",
            );
        let report = super::address(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("screend socket override key")),
            "{report:?}"
        );
    }
}
