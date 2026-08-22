//! superd's rendezvous, version, verbs, listener kinds and frame envelope.
//!
//! Ported from `scripts/check-supervisor.sh` §§1–4. The prose below each rule is the shell's own,
//! because the reason a rule exists does not change when the language does — and on the day one
//! fires, that reason is the whole diagnostic.
//!
//! What every rule here has in common: the failure it catches is SILENT at runtime. The two sides
//! never exchange their socket paths (hostd has to FIND the control socket before it can say
//! `hello`), so a renamed socket is not a protocol error — it is a connect to a name nobody bound,
//! reported as "no daemon is running", which is also the healthy answer when no daemon is running.

use crate::paths::{
    RUST_CTL_LIB, RUST_PATHS, RUST_PROTOCOL, RUST_SHELLINT, RUST_SUPERD_SERVER, RUST_SUPERWIRE,
    SWIFT_HOST_ENVIRONMENT, SWIFT_PATHS, SWIFT_PROTOCOL,
};
use crate::report::Report;
use crate::text;
use crate::tree::Tree;

/// §1 — the rendezvous address: ONE rule, and neither end re-derives it.
///
/// Exactly one path used to be spelled in both languages, and the argument for it was that it had
/// to be: hostd must FIND the control socket before it can ask superd anything, so that one name
/// cannot be learned from the thing it names.
///
/// Half of that argument was true. The NAME is shared by construction. Which DIRECTORY the name
/// sits in is a policy, it was written out on both sides, and the two spellings were not the same
/// policy: superd resolved `$SLOPDESK_SUPERD_SOCKET` → `$SLOPDESK_SUPERD_DIR` → `$TMPDIR` →
/// `/tmp`, and hostd resolved the override and then `NSTemporaryDirectory()` — which on Darwin does
/// not read `$TMPDIR` at all, and had never heard of the directory override. Two silent
/// divergences, so this pins the rule's SHAPE rather than comparing two copies of it: the name and
/// both keys belong to `slopdesk_superwire`, both ends reach them, and neither end spells a
/// resolution of its own.
#[must_use]
pub fn rendezvous_address(tree: &Tree) -> Report {
    let mut report = Report::new();

    let Some(superwire) = report.source(
        tree,
        RUST_SUPERWIRE,
        "the shared control-socket rule lives there (docs/51 §1)",
    ) else {
        return report;
    };
    for literal in [
        "slopdesk-superd.sock",
        "\"SLOPDESK_SUPERD_SOCKET\"",
        "\"SLOPDESK_SUPERD_DIR\"",
    ] {
        report.fail_if(
            !superwire.text.contains(literal),
            format!(
                "{RUST_SUPERWIRE} no longer names {literal} — the shared control-socket rule lost part of \
                 itself (docs/51 §1)",
            ),
        );
    }
    report.fail_if(
        !superwire.text.contains("control_socket_path"),
        format!(
            "{RUST_SUPERWIRE} no longer owns the control-socket resolution — both ends would answer it and \
             only one can be right",
        ),
    );

    if let Some(rust_paths) = report.source(tree, RUST_PATHS, "superd's path resolution lives there") {
        report.fail_if(
            !rust_paths
                .text
                .contains("slopdesk_superwire::control_socket_path"),
            format!(
                "{RUST_PATHS} resolves superd's own control address again instead of the shared rule \
                 (docs/51 §1)",
            ),
        );
        // No pid in any of them. This is the bug the whole daemon exists to fix (docs/51 §1): a
        // restarted hostd binding a pid-suffixed path leaves every running agent holding an address
        // with nothing behind it. CODE only, and only up to `#[cfg(test)]` — the prose explains the
        // bug by naming `getpid()`, and the test below asserts the absence BY spelling
        // `process::id()`. Matching either would be the gate failing on its own documentation and
        // its own proof.
        let code = text::before(rust_paths.code(), r"#\[cfg\(test\)\]");
        report.fail_if(
            text::matches(&code, "(getpid|process::id)"),
            "a pid reached superd's stable socket paths — see docs/51 §1",
        );
    }

    if let Some(swift_paths) = report.source(tree, SWIFT_PATHS, "hostd's rendezvous lives there (docs/51 §1)")
    {
        report.fail_if(
            !swift_paths.text.contains("slopdesk_supervisor_control_socket"),
            format!(
                "{SWIFT_PATHS} no longer resolves through the door — hostd would dial an address superd did \
                 not bind (docs/51 §1)",
            ),
        );
        // Comments stripped: the prose above the resolution NAMES `NSTemporaryDirectory()` and the
        // socket on purpose, to record which two things drifted and why they are gone.
        let code = swift_paths.code();
        // An empty haystack passes the ban below at once, so it is named rather than assumed: a
        // file that became all comment, or a stripper that started eating code, would read as the
        // healthiest result.
        report.fail_if(
            code.trim().is_empty(),
            format!(
                "{SWIFT_PATHS} stripped to nothing — the ban below reads an empty haystack and passes \
                 (docs/51 §1)",
            ),
        );
        report.fail_if(
            text::matches(code, r"NSTemporaryDirectory|slopdesk-superd\.sock"),
            format!(
                "{SWIFT_PATHS} builds the control address itself again — that resolution is \
                 slopdesk_superwire's (docs/51 §1)",
            ),
        );
        report.fail_if(
            text::matches(code, "(getpid|processIdentifier)"),
            "a pid reached hostd's rendezvous address — see docs/51 §1",
        );
        // Both override keys still reach the door, though: the lookup is hostd's, only the RULE
        // crossed.
        for key in ["\"SLOPDESK_SUPERD_SOCKET\"", "\"SLOPDESK_SUPERD_DIR\""] {
            report.fail_if(
                !swift_paths.text.contains(key),
                format!(
                    "{SWIFT_PATHS} stopped reading {key} — a rung superd honours would go unspoken, and the \
                     daemon would just look absent",
                ),
            );
        }
    }

    report
}

/// §1 continued — the agent-control address, on the same footing.
///
/// hostd EXPORTS it into every PTY's environment and `slopdesk-ctl` — a separate binary an agent
/// shells out to — READS it to find the socket. A rename on one side is the quietest failure of the
/// three: every `slopdesk-ctl` invocation simply reports no host, which reads as "the control
/// listener is off" and is the documented default.
#[must_use]
pub fn control_socket_export(tree: &Tree) -> Report {
    const KEY: &str = "\"SLOPDESK_CONTROL_SOCKET\"";

    let mut report = Report::new();
    if let Some(env) = report.source(tree, SWIFT_HOST_ENVIRONMENT, "hostd's env export lives there") {
        report.fail_if(
            !env.text.contains(KEY),
            format!(
                "{SWIFT_HOST_ENVIRONMENT} no longer exports SLOPDESK_CONTROL_SOCKET — slopdesk-ctl would \
                 find no host (docs/51 §1)",
            ),
        );
    }
    if let Some(ctl) = report.source(tree, RUST_CTL_LIB, "slopdesk-ctl's socket lookup lives there") {
        report.fail_if(
            !ctl.text.contains(KEY),
            format!("{RUST_CTL_LIB} no longer reads SLOPDESK_CONTROL_SOCKET"),
        );
    }
    report
}

/// §1 continued — the shell-integration opt-outs, quieter than any address.
///
/// superd reads `SLOPDESK_SHELL_INTEGRATION` from the environment hostd hands it and decides
/// whether to generate the shim AT ALL; the other two are read by the generated `.zshrc` inside the
/// spawned zsh (`${SLOPDESK_OSC133:-1}`, `${SLOPDESK_SHELL_CURSOR:-1}`), so — as
/// `shellintegration.rs` states above the constant — each "must survive hostd's curated env
/// allowlist for a daemon-side setting to take effect". hostd's curation is an ALLOWLIST: a key it
/// does not name is not forwarded, and a key that is not forwarded reads to superd exactly like a
/// key that was never set. A rename on either side turns the setting off and nothing says so — no
/// prompt marks, no cwd tracking, no error (docs/51 §6.4).
///
/// Both sides are whole SETS, and the Rust side is not a list typed out here. Every `*_ENV_KEY` the
/// module declares must be forwarded EXCEPT the ones it writes itself: `REAL_ZDOTDIR_ENV_KEY` goes
/// into the child's environment through `Shim::overrides`, so it travels superd→child and hostd has
/// no business carrying it. That exclusion is read out of how the module USES the constant, not out
/// of a name written here — which is what makes a fourth opt-out visible instead of invisible.
#[must_use]
pub fn shell_integration_env_keys(tree: &Tree) -> Report {
    let mut report = Report::new();
    let (Some(env), Some(shellint)) = (
        report.source(tree, SWIFT_HOST_ENVIRONMENT, "hostd's env allowlist lives there"),
        report.source(tree, RUST_SHELLINT, "superd's shim generator lives there"),
    ) else {
        return report;
    };

    let swift = text::capture_set(
        &text::range(&env.text, r"shellIntegrationEnvKeys = \[", r"\]"),
        r#"(?m)^ *"([A-Z0-9_]*)","#,
    );
    // Each declared key's VALUE, minus the ones the module hands to the child itself.
    let rust: std::collections::BTreeSet<String> =
        text::cached(r#"(?m)^pub const ([A-Z0-9_]*_ENV_KEY): &str = "([A-Z0-9_]*)""#)
            .captures_iter(&shellint.text)
            .filter_map(|caps| {
                let name = caps.get(1)?.as_str();
                let value = caps.get(2)?.as_str();
                let written_by_superd = shellint.text.contains(&format!("overrides.insert({name}"));
                (!written_by_superd).then(|| value.to_owned())
            })
            .collect();

    report.same_set("shell-integration env keys", &swift, &rust);
    report
}

/// §1 continued — the three paths that are superd's alone, and Swift must not learn them.
///
/// hostd is told the hook and agent-control paths in the `hello` reply, which is the whole reason
/// that reply carries them; the lock file is none of its business. A Swift constant for any of them
/// would be a second answer to "where is the hook socket", which is precisely the drift that
/// pid-keyed paths caused once (docs/51 §1). So this asserts an ABSENCE — the regression is a copy
/// appearing, not a rename.
#[must_use]
pub fn superd_private_paths(tree: &Tree) -> Report {
    let mut report = Report::new();
    for name in ["slopdesk-agent.sock", "slopdesk-ctl.sock", "slopdesk-superd.lock"] {
        let spelled = tree
            .under("Sources")
            .any(|(_, source)| source.text.contains(name));
        report.fail_if(
            spelled,
            format!(
                "'{name}' is spelled in Sources/ — superd owns that path and tells hostd at hello, see \
                 docs/51 §1",
            ),
        );
    }
    report
}

/// §2 — protocol version, build version and the reserved notification id.
///
/// MAJOR gates the handshake, so a skew is at least loud. MINOR is capability negotiation and a
/// skew is quiet: hostd would send a verb this superd does not know, or withhold one it does.
///
/// The minor says what superd can SPEAK. It cannot say which BUILD is speaking — it moves only on a
/// wire change, so a superd rebuilt with a fixed reaper reports the minor it always did. superd
/// outlives hostd's build, so after an upgrade the binary on disk and the process on this socket
/// are routinely different code, and restarting it takes every live pane. `buildVersion` on the
/// hello reply is the one handle hostd has on which (docs/49); dropped on either side it reads as
/// absent, which the audit reports as "unknown" forever rather than failing.
///
/// The reserved `id` marks a reply as an unsolicited NOTIFICATION rather than an answer. A skew
/// makes hostd read every notification as the answer to whichever request happens to carry that id,
/// and reply to a verb nobody sent.
#[must_use]
pub fn protocol_version(tree: &Tree) -> Report {
    let mut report = Report::new();
    let (Some(swift), Some(rust), Some(server)) = (
        report.source(tree, SWIFT_PROTOCOL, "hostd's protocol encoding lives there"),
        report.source(tree, RUST_PROTOCOL, "superd's protocol decode lives there"),
        report.source(tree, RUST_SUPERD_SERVER, "superd's hello reply is built there"),
    ) else {
        return report;
    };

    report.same(
        "protocol major",
        text::capture_first(&swift.text, r"versionMajor = (\d+)").as_deref(),
        text::capture_first(&rust.text, r"VERSION_MAJOR: i32 = (\d+)").as_deref(),
    );
    report.same(
        "protocol minor",
        text::capture_first(&swift.text, r"versionMinor = (\d+)").as_deref(),
        text::capture_first(&rust.text, r"VERSION_MINOR: i32 = (\d+)").as_deref(),
    );
    report.same(
        "notification id",
        text::capture_first(&swift.text, r"notificationID: UInt64 = (\d+)").as_deref(),
        text::capture_first(&rust.text, r"NOTIFICATION_ID: u64 = (\d+)").as_deref(),
    );

    report.fail_if(
        !rust.text.contains(r#"rename = "buildVersion""#),
        "superd's hello no longer carries buildVersion — hostd cannot tell a stale superd from a current \
         one (docs/49)",
    );
    report.fail_if(
        !server
            .text
            .contains(r#"build_version: Some(env!("CARGO_PKG_VERSION")"#),
        format!(
            "superd's hello no longer answers with its OWN compile-time version — see {RUST_SUPERD_SERVER}"
        ),
    );
    report.fail_if(
        !swift.text.contains("var buildVersion: String?"),
        format!("{SWIFT_PROTOCOL}'s HelloReply no longer decodes buildVersion (docs/49)"),
    );
    report
}

/// §3 — every verb Swift can SEND must be one Rust can dispatch.
///
/// Not the converse: superd is allowed to know a verb no hostd sends yet, which is how a minor bump
/// lands in two commits. camelCase in the capture, not just lowercase: `forgetTitle` is a verb, and
/// a pattern that could not see it would have passed this gate while hostd sent a verb superd never
/// dispatched.
#[must_use]
pub fn verbs(tree: &Tree) -> Report {
    let mut report = Report::new();
    let (Some(swift), Some(rust)) = (
        report.source(tree, SWIFT_PROTOCOL, "hostd's verbs live there"),
        report.source(tree, RUST_PROTOCOL, "superd's dispatch lives there"),
    ) else {
        return report;
    };

    let verbs = text::capture_set(
        &swift.text,
        r#"(?m)^ *public static let [a-zA-Z]* = "([a-zA-Z]*)"$"#,
    );
    // An empty list is not "every verb crosses" — it is a loop that runs zero times, and `sed`
    // returned it without complaint. The gate below only ever reports what it iterates, so the
    // liveness of the extraction has to be asserted here or not at all.
    report.fail_if(
        verbs.is_empty(),
        format!("no sendable verb found in {SWIFT_PROTOCOL} — the extraction in this gate has gone stale"),
    );
    for verb in &verbs {
        report.fail_if(
            !rust.text.contains(&format!("= \"{verb}\";")),
            format!("verb '{verb}' is sendable from Swift but has no constant in {RUST_PROTOCOL}"),
        );
    }
    report
}

/// §3b — listener kinds, equal in BOTH directions.
///
/// Unlike the verbs above, because each side's extra is silent in a different way: a kind only
/// Swift knows is a claim superd refuses, and a kind only Rust knows is a socket nobody ever claims
/// — and an unclaimed socket is never advertised into a child's environment (`listeners.rs`), so a
/// `claude` would simply come up with no hook path and fall back to the screen engine. Nothing logs
/// an error.
#[must_use]
pub fn listener_kinds(tree: &Tree) -> Report {
    let mut report = Report::new();
    let (Some(swift), Some(rust)) = (
        report.source(tree, SWIFT_PROTOCOL, "hostd's listener kinds live there"),
        report.source(tree, RUST_PROTOCOL, "superd's listener kinds live there"),
    ) else {
        return report;
    };

    let swift_kinds = text::capture_set(
        &text::range(&swift.text, r"public enum ListenerKind \{", r"^    \}"),
        r#"public static let [a-zA-Z]* = "([a-z]*)""#,
    );
    let rust_kinds = text::capture_set(
        &text::range(&rust.text, r"pub mod listener_kind \{", r"^\}"),
        r#": &str = "([a-z]*)";"#,
    );
    report.fail_if(
        swift_kinds.is_empty(),
        format!("no listener kinds found in {SWIFT_PROTOCOL} — the extraction in this gate has gone stale"),
    );
    report.same_set("listener kinds", &swift_kinds, &rust_kinds);
    report
}

/// §4 — frame tags and the body cap, as a ONE-SIDED pin.
///
/// This gate used to COMPARE two spellings — `SupervisorFrame.swift`'s constants against superd's
/// `frame.rs` ones — because there were two. There is one now (`slopdesk-superwire`), which superd
/// re-exports and hostd reads through a door, so skew between the two ends is no longer expressible
/// and there is nothing left to compare. What is still worth pinning, and is now the only thing
/// that can go wrong, is the NUMBERING itself: it is the wire, every deployed peer of every version
/// reads it, and a shifted constant desynchronises all of them at once.
///
/// The quietest skew this socket ever had: superd writes a tag hostd does not know, hostd answers
/// `unknownTag` and drops the CONNECTION — every pane at once, on the first title anybody's shell
/// writes. An absent constant reads as `None` here and fails the same way a wrong one does.
///
/// The cap is a refusal on both sides, so the LOWER one governs — and one declaration is how they
/// stay equal, which is the only setting where neither side can produce a frame the other will not
/// take. Pinned to the number rather than to another copy of it, for the same reason as the tags.
#[must_use]
pub fn frame_envelope(tree: &Tree) -> Report {
    // The block tap has its own tag rather than sharing the sniffer's batch because the two answer
    // to DIFFERENT gates (shellIntegration vs blocks), and what keeps a new tag inside the
    // append-only rule is that each tag has exactly one thing to ask for.
    const TAGS: [(&str, &str, &str); 5] = [
        ("plain", "TAG_PLAIN", "0x01"),
        ("with descriptor", "TAG_WITH_DESCRIPTOR", "0x02"),
        ("output", "TAG_OUTPUT", "0x03"),
        ("sniff", "TAG_SNIFF", "0x04"),
        ("blocks", "TAG_BLOCKS", "0x05"),
    ];

    let mut report = Report::new();
    let Some(superwire) = report.source(tree, RUST_SUPERWIRE, "the frame envelope lives there") else {
        return report;
    };
    for (label, constant, expected) in TAGS {
        let found = text::capture_first(&superwire.text, &format!("{constant}: u8 = (0x[0-9a-fA-F]*)"));
        report.same(&format!("frame tag ({label})"), found.as_deref(), Some(expected));
    }

    let cap = text::capture_first(&superwire.text, r"(?m)MAX_BODY_BYTES: usize = (.*);$")
        .map(|value| value.replace(' ', ""));
    report.same("maximum body bytes", cap.as_deref(), Some("4*1024*1024"));
    report
}

#[cfg(test)]
mod tests {
    //! Every rule's break-test, which the shell could only record as prose.
    //!
    //! A fixture tree is built in a temp directory with the minimum a rule reads, the rule is run
    //! green, then ONE thing is broken and the rule must fail. That second half is the part a
    //! sentence in a comment never performed.

    use std::fs;
    use std::path::{Path, PathBuf};

    use crate::tree::Tree;

    /// A scratch tree that removes itself.
    struct Fixture(PathBuf);

    impl Fixture {
        fn new(name: &str) -> Self {
            let root = std::env::temp_dir().join(format!("slopdesk-invariants-{name}"));
            let _ = fs::remove_dir_all(&root);
            fs::create_dir_all(&root).expect("fixture root");
            Self(root)
        }

        fn write(&self, path: &str, contents: &str) -> &Self {
            let full = self.0.join(path);
            fs::create_dir_all(full.parent().expect("fixture parent")).expect("fixture dirs");
            fs::write(full, contents).expect("fixture file");
            self
        }

        fn tree(&self) -> Tree {
            Tree::load(&self.0).expect("fixture tree")
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    const SUPERWIRE_OK: &str = r#"
pub const CONTROL_SOCKET_NAME: &str = "slopdesk-superd.sock";
pub const SOCKET_ENV_KEY: &str = "SLOPDESK_SUPERD_SOCKET";
pub const DIR_ENV_KEY: &str = "SLOPDESK_SUPERD_DIR";
pub fn control_socket_path() -> PathBuf { todo!() }
pub const TAG_PLAIN: u8 = 0x01;
pub const TAG_WITH_DESCRIPTOR: u8 = 0x02;
pub const TAG_OUTPUT: u8 = 0x03;
pub const TAG_SNIFF: u8 = 0x04;
pub const TAG_BLOCKS: u8 = 0x05;
pub const MAX_BODY_BYTES: usize = 4 * 1024 * 1024;
"#;

    fn superwire_fixture(name: &str) -> Fixture {
        let fixture = Fixture::new(name);
        fixture.write("rust/slopdesk-superwire/src/lib.rs", SUPERWIRE_OK);
        fixture
    }

    #[test]
    fn a_frame_tag_that_shifts_is_caught() {
        let fixture = superwire_fixture("frame-tags");
        assert!(super::frame_envelope(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-superwire/src/lib.rs",
            &SUPERWIRE_OK.replace("TAG_BLOCKS: u8 = 0x05", "TAG_BLOCKS: u8 = 0x06"),
        );
        let report = super::frame_envelope(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("frame tag (blocks)")),
            "{report:?}"
        );
    }

    /// The cap is the one number both sides refuse on. A widened cap is a frame superd will send
    /// and hostd will drop the connection over.
    #[test]
    fn a_widened_body_cap_is_caught() {
        let fixture = superwire_fixture("body-cap");
        fixture.write(
            "rust/slopdesk-superwire/src/lib.rs",
            &SUPERWIRE_OK.replace("4 * 1024 * 1024", "8 * 1024 * 1024"),
        );
        let report = super::frame_envelope(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("maximum body bytes")),
            "{report:?}"
        );
    }

    /// A constant that was DELETED reads as `None`, and must fail as loudly as a wrong one — this
    /// is `same`'s empty-is-not-agreement rule reaching a real rule.
    #[test]
    fn a_deleted_frame_tag_fails_as_loudly_as_a_wrong_one() {
        let fixture = superwire_fixture("deleted-tag");
        fixture.write(
            "rust/slopdesk-superwire/src/lib.rs",
            &SUPERWIRE_OK.replace("pub const TAG_SNIFF: u8 = 0x04;\n", ""),
        );
        let report = super::frame_envelope(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("EMPTY")),
            "{report:?}"
        );
    }

    const PROTOCOL_SWIFT_OK: &str = r#"
public enum SupervisorProtocol {
    public static let versionMajor = 1
    public static let versionMinor = 7
    public static let notificationID: UInt64 = 0
    public static let attach = "attach"
    public static let forgetTitle = "forgetTitle"
    public enum ListenerKind {
        public static let hook = "hook"
        public static let agent = "agent"
    }
}
public struct HelloReply: Codable {
    public var buildVersion: String?
}
"#;

    const PROTOCOL_RUST_OK: &str = r#"
pub const VERSION_MAJOR: i32 = 1;
pub const VERSION_MINOR: i32 = 7;
pub const NOTIFICATION_ID: u64 = 0;
pub const ATTACH: &str = "attach";
pub const FORGET_TITLE: &str = "forgetTitle";
pub mod listener_kind {
    pub const HOOK: &str = "hook";
    pub const AGENT: &str = "agent";
}
#[serde(rename = "buildVersion")]
pub build_version: Option<String>,
"#;

    fn protocol_fixture(name: &str) -> Fixture {
        let fixture = Fixture::new(name);
        fixture
            .write(
                "Sources/SlopDeskSupervisor/SupervisorProtocol.swift",
                PROTOCOL_SWIFT_OK,
            )
            .write("rust/slopdesk-superd/src/protocol.rs", PROTOCOL_RUST_OK)
            .write(
                "rust/slopdesk-superd/src/server.rs",
                "build_version: Some(env!(\"CARGO_PKG_VERSION\").to_owned()),\n",
            );
        fixture
    }

    #[test]
    fn a_minor_bumped_on_one_side_only_is_caught() {
        let fixture = protocol_fixture("minor-skew");
        assert!(super::protocol_version(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-superd/src/protocol.rs",
            &PROTOCOL_RUST_OK.replace("VERSION_MINOR: i32 = 7", "VERSION_MINOR: i32 = 8"),
        );
        let report = super::protocol_version(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("protocol minor")),
            "{report:?}"
        );
    }

    /// The camelCase case the shell's first pattern could not see. `forgetTitle` sendable from
    /// Swift with no Rust constant is hostd sending a verb superd never dispatches.
    #[test]
    fn a_camel_case_verb_with_no_rust_constant_is_caught() {
        let fixture = protocol_fixture("verb-skew");
        assert!(super::verbs(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-superd/src/protocol.rs",
            &PROTOCOL_RUST_OK.replace(r#"pub const FORGET_TITLE: &str = "forgetTitle";"#, ""),
        );
        let report = super::verbs(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("forgetTitle")),
            "{report:?}"
        );
    }

    /// Both directions, unlike the verbs: a kind only Rust knows is a socket nobody claims.
    #[test]
    fn a_listener_kind_rust_alone_knows_is_caught() {
        let fixture = protocol_fixture("kind-skew");
        assert!(super::listener_kinds(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-superd/src/protocol.rs",
            &PROTOCOL_RUST_OK.replace(
                "    pub const AGENT: &str = \"agent\";",
                "    pub const AGENT: &str = \"agent\";\n    pub const BLOCKS: &str = \"blocks\";",
            ),
        );
        let report = super::listener_kinds(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("Rust alone has blocks")),
            "{report:?}"
        );
    }

    const PATHS_SWIFT_OK: &str = r#"
// NSTemporaryDirectory() and slopdesk-superd.sock are named HERE on purpose, in prose.
enum SupervisorPaths {
    static var controlSocket: String {
        if let override = env["SLOPDESK_SUPERD_SOCKET"] { return override }
        if let dir = env["SLOPDESK_SUPERD_DIR"] { _ = dir }
        return slopdesk_supervisor_control_socket()
    }
}
"#;

    fn rendezvous_fixture(name: &str) -> Fixture {
        let fixture = superwire_fixture(name);
        fixture
            .write("Sources/SlopDeskSupervisor/SupervisorPaths.swift", PATHS_SWIFT_OK)
            .write(
                "rust/slopdesk-superd/src/paths.rs",
                "pub fn control() -> PathBuf { slopdesk_superwire::control_socket_path() }\n",
            );
        fixture
    }

    /// The whole point of stripping comments: the prose above the resolution names the two things
    /// that drifted, and a rule that read raw text would fail on its own explanation.
    #[test]
    fn the_prose_naming_the_banned_resolution_does_not_trip_the_ban() {
        let fixture = rendezvous_fixture("rendezvous-prose");
        let report = super::rendezvous_address(&fixture.tree());
        assert!(report.is_clean(), "{report:?}");
    }

    #[test]
    fn hostd_building_the_control_address_itself_is_caught() {
        let fixture = rendezvous_fixture("rendezvous-rederive");
        fixture.write(
            "Sources/SlopDeskSupervisor/SupervisorPaths.swift",
            &PATHS_SWIFT_OK.replace(
                "return slopdesk_supervisor_control_socket()",
                "return NSTemporaryDirectory() + \"x\"; _ = slopdesk_supervisor_control_socket",
            ),
        );
        let report = super::rendezvous_address(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("builds the control address itself")),
            "{report:?}",
        );
    }

    /// The bug the daemon exists to fix. A pid in the path leaves every running agent holding an
    /// address with nothing behind it after hostd restarts.
    #[test]
    fn a_pid_back_in_the_rendezvous_is_caught_on_both_sides() {
        let fixture = rendezvous_fixture("rendezvous-pid");
        fixture.write(
            "rust/slopdesk-superd/src/paths.rs",
            "pub fn control() -> PathBuf {\n    let _ = std::process::id();\n    \
             slopdesk_superwire::control_socket_path()\n}\n",
        );
        let report = super::rendezvous_address(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("pid reached superd")),
            "{report:?}"
        );
    }

    /// A rule whose file has been renamed must FAIL rather than pass vacuously — the one failure
    /// mode this crate cannot afford, and the reason `Report::source` exists.
    #[test]
    fn a_missing_file_fails_instead_of_passing_vacuously() {
        let fixture = Fixture::new("missing-file");
        // Nothing written at all; the roots do not even exist.
        assert!(fixture.path().is_dir());
        let report = super::rendezvous_address(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("is gone")),
            "{report:?}"
        );
    }

    const SHELLINT_RUST_OK: &str = r#"
pub const SHELL_INTEGRATION_ENV_KEY: &str = "SLOPDESK_SHELL_INTEGRATION";
pub const OSC133_ENV_KEY: &str = "SLOPDESK_OSC133";
pub const SHELL_CURSOR_ENV_KEY: &str = "SLOPDESK_SHELL_CURSOR";
pub const REAL_ZDOTDIR_ENV_KEY: &str = "SLOPDESK_REAL_ZDOTDIR";
fn build(overrides: &mut Map) {
    overrides.insert(REAL_ZDOTDIR_ENV_KEY.to_owned(), dir);
}
"#;

    const HOST_ENV_OK: &str = r#"
enum HostEnvironment {
    static let shellIntegrationEnvKeys = [
        "SLOPDESK_SHELL_INTEGRATION",
        "SLOPDESK_OSC133",
        "SLOPDESK_SHELL_CURSOR",
    ]
    static let controlSocketKey = "SLOPDESK_CONTROL_SOCKET"
}
"#;

    fn shellint_fixture(name: &str) -> Fixture {
        let fixture = Fixture::new(name);
        fixture
            .write("Sources/SlopDeskHost/HostEnvironment.swift", HOST_ENV_OK)
            .write("rust/slopdesk-superd/src/shellintegration.rs", SHELLINT_RUST_OK);
        fixture
    }

    /// The exclusion is read out of USE, not out of a list: `REAL_ZDOTDIR_ENV_KEY` is written by
    /// superd into the child, so hostd must not forward it and its absence is not a violation.
    #[test]
    fn a_key_superd_writes_itself_is_not_demanded_of_hostd() {
        let fixture = shellint_fixture("shellint-green");
        let report = super::shell_integration_env_keys(&fixture.tree());
        assert!(report.is_clean(), "{report:?}");
    }

    /// A fourth opt-out that hostd does not forward is a setting that silently does nothing.
    #[test]
    fn a_new_opt_out_hostd_does_not_forward_is_caught() {
        let fixture = shellint_fixture("shellint-new-key");
        fixture.write(
            "rust/slopdesk-superd/src/shellintegration.rs",
            &format!("{SHELLINT_RUST_OK}pub const TITLE_ENV_KEY: &str = \"SLOPDESK_TITLE\";\n"),
        );
        let report = super::shell_integration_env_keys(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("Rust alone has SLOPDESK_TITLE")),
            "{report:?}",
        );
    }

    #[test]
    fn a_superd_private_path_copied_into_swift_is_caught() {
        let fixture = Fixture::new("private-paths");
        fixture.write("Sources/SlopDeskHost/Whatever.swift", "let x = 1\n");
        assert!(super::superd_private_paths(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskHost/Whatever.swift",
            "let hook = \"/tmp/slopdesk-agent.sock\"\n",
        );
        let report = super::superd_private_paths(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("slopdesk-agent.sock")),
            "{report:?}"
        );
    }

    #[test]
    fn dropping_the_control_socket_export_is_caught() {
        let fixture = shellint_fixture("ctl-export");
        fixture.write(
            "rust/slopdesk-ctl/src/lib.rs",
            "let key = \"SLOPDESK_CONTROL_SOCKET\";\n",
        );
        assert!(super::control_socket_export(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskHost/HostEnvironment.swift",
            &HOST_ENV_OK.replace("\"SLOPDESK_CONTROL_SOCKET\"", "\"SLOPDESK_CTL\""),
        );
        let report = super::control_socket_export(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("slopdesk-ctl would find no host")),
            "{report:?}",
        );
    }
}
