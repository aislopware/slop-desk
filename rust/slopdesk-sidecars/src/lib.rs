//! Is the sidecar that is RUNNING the sidecar that is INSTALLED?
//!
//! Every daemon in this repository outlives the process that asks about it. superd is a launchd
//! agent held across logins; screend is one too (`scripts/install-screend.sh`); dropd, inspectord
//! and androidd are superd's children, which is why hostd re-learns their ports off superd's
//! retained ring rather than by starting them. So `brew upgrade` replaces twelve binaries on disk
//! and changes what is executing for none of them.
//!
//! That is not a bug to fix by restarting everything. Ending superd takes every live pane with it,
//! and a user who upgraded to get a fixed drop dialog did not ask to lose their sessions. The
//! release ships a `MANIFEST.json` naming a version per binary and the daemons report the version
//! they are RUNNING (`docs/49`), so the honest answer is per-daemon: compare, and act only where
//! acting is cheap.
//!
//! ## Two questions, one policy table
//! There are two callers and they ask different things.
//!
//! - **hostd**, at start, over the FFI door: *this daemon answered `0.1.0` and the binary I would
//!   spawn says `0.2.0` — what now?* That is [`Report`], over [`verdict`].
//! - **`slopdesk sidecars`**, after an install: *this upgrade replaced these files — what did it
//!   actually change?* That is [`manifest::plan`], over two `MANIFEST.json` files and no processes
//!   at all.
//!
//! Both end at [`policy`], which is the one place that says what a restart COSTS. It lives here,
//! once, because a second copy in the caller's language is exactly the cross-language mirror
//! `CLAUDE.md` bans — and the two callers are in two different languages.
//!
//! ## Nothing here restarts anything
//! Not a design nicety: a type that both decides and acts is a type whose decision cannot be tested
//! without a process tree. Every function in this crate is a value transform, and the caller that
//! owns a child's lifetime is the caller that ends it.

#![forbid(unsafe_code)]

pub mod manifest;

/// What may be done about a sidecar that is running code the install has replaced.
///
/// The split is not about how important the daemon is; it is about what a restart COSTS and who
/// owns the lifetime. A restart nobody can see, on a child the asker spawned, is worth taking. A
/// restart that destroys work is the user's call however routine it looks from here.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RestartPolicy {
    /// Restart it. dropd, inspectord and androidd are hostd's own children: it spawned them, it
    /// re-learns the fresh one's port from its announce line, and the cost is a re-dial by a client
    /// that already retries.
    Automatic,
    /// Report it and let it go. screend exits on its own after `SLOPDESK_SCREEND_IDLE_EXIT` (two
    /// minutes by default) of quiet, and the next verb that needs one starts the INSTALLED binary —
    /// so the stale window closes without anybody acting, and nothing outside launchd holds a
    /// handle it could act with anyway (screend is a launch agent, `scripts/install-screend.sh`).
    SelfRetiring,
    /// Report it and stop. superd holds every PTY master in the process; ending it ends every pane,
    /// so "there is a newer superd installed" is information, never an action. hostd is here too,
    /// for the same reason from the other end: `CLAUDE.md` forbids killing it, and the relaunch is
    /// the user quitting an app they may be working in.
    OperatorChoice,
    /// There is nothing of it resident to be stale. The CLI, the hook, the probe and the seed are
    /// forked per event and exit — `slopdesk` once per invocation, the hook twice per tool call —
    /// so replacing the file IS the upgrade, completed, with no window in between.
    ///
    /// Distinct from [`RestartPolicy::Automatic`] rather than folded into it: "restarted" and "was
    /// never running" read the same in a summary line and mean opposite things when one of them
    /// stops being true.
    NotResident,
}

impl RestartPolicy {
    /// The name this crosses the FFI door under, and the one the CLI prints.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Automatic => "automatic",
            Self::SelfRetiring => "selfRetiring",
            Self::OperatorChoice => "operatorChoice",
            Self::NotResident => "notResident",
        }
    }

    /// What happens next about a stale daemon, in the words the log and the CLI both use.
    ///
    /// One sentence per policy, phrased as a fact rather than an instruction where the thing
    /// genuinely happens on its own — a line that tells a user to do something that is already
    /// scheduled trains them to ignore the next one.
    #[must_use]
    pub const fn remedy(self) -> &'static str {
        match self {
            Self::Automatic => "restarting",
            Self::SelfRetiring => "it will pick the new one up when it next goes idle",
            Self::OperatorChoice => "restart it when convenient; it will take every live pane",
            Self::NotResident => "nothing of it is resident; the next invocation is the new one",
        }
    }
}

/// The launchd label a tool is held under, for the two that are launch agents.
///
/// `None` for everything else, and that `None` is load-bearing: a line that tells a user to
/// `launchctl kickstart` a job that does not exist is worse than no line, because they will run it
/// and believe it worked. Only superd (`scripts/install-superd.sh`) and screend
/// (`scripts/install-screend.sh`) are agents; the other three daemons are superd's children and
/// launchd has never heard of them.
#[must_use]
pub fn launch_agent_label(tool: &str) -> Option<&'static str> {
    match tool {
        "slopdesk-superd" => Some("com.slopdesk.superd"),
        "slopdesk-screend" => Some("com.slopdesk.screend"),
        _ => None,
    }
}

/// What may be done about a stale `tool`, by the name it ships under in `MANIFEST.json`.
///
/// Every one of the twelve shipped binaries is named here, because the manifest lists all twelve
/// and a
/// table that answered only for the five daemons would report the other five by the fallback —
/// which says "your call" about a program that is not running and never was.
///
/// Unknown names are [`RestartPolicy::OperatorChoice`] all the same: a tool this table has not been
/// taught about has an unknown restart cost, and the safe unknown is "ask". A seventh daemon added
/// to `scripts/shipped-tools.sh` and not to this match reads as the user's call, which is wrong in
/// the harmless direction.
#[must_use]
#[expect(
    clippy::match_same_arms,
    reason = "superd and hostd land on the same policy as the fallback and are still named: the arm IS the \
              review, and folding it into `_` would make the day a seventh daemon arrives indistinguishable \
              from the day someone decided about these two"
)]
pub fn policy(tool: &str) -> RestartPolicy {
    match tool {
        "slopdesk-dropd" | "slopdesk-inspectord" | "slopdesk-androidd" => RestartPolicy::Automatic,
        "slopdesk-screend" => RestartPolicy::SelfRetiring,
        // superd takes every pane; hostd is the process `CLAUDE.md` forbids killing, and its
        // relaunch is the user quitting an app they may be working in.
        "slopdesk-superd" | "slopdesk-hostd" => RestartPolicy::OperatorChoice,
        "slopdesk"
        | "slopdesk-ctl"
        | "slopdesk-probe"
        | "slopdesk-hook"
        | "slopdesk-agenthooks"
        | "slopdesk-codeseed" => RestartPolicy::NotResident,
        _ => RestartPolicy::OperatorChoice,
    }
}

/// What one sidecar's audit concluded.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Verdict {
    /// The process is running the version that is installed.
    Current(String),
    /// The installed binary is a different build from the process serving. Not necessarily NEWER: a
    /// downgrade reads the same, and the fix is the same restart either way.
    Stale {
        /// What the process answered.
        running: String,
        /// What the binary that would be spawned answers.
        on_disk: String,
    },
    /// One of the two numbers is missing: a daemon older than its version field, a binary that is
    /// gone, a `--version` that did not answer. NEVER folded into [`Verdict::Current`] — reporting
    /// a stale sidecar as up to date is the silent wrong answer this whole mechanism exists to end.
    Unknown(&'static str),
}

impl Verdict {
    /// The name this crosses the FFI door under.
    #[must_use]
    pub const fn state(&self) -> &'static str {
        match *self {
            Self::Current(_) => "current",
            Self::Stale { .. } => "stale",
            Self::Unknown(_) => "unknown",
        }
    }
}

/// A running daemon that answers no version at all.
const RUNNING_SILENT: &str = "the running daemon reports no version";
/// An installed binary that answers no version at all.
const ON_DISK_SILENT: &str = "the installed binary reports no version";

/// Compares what is running against what is installed.
///
/// Both `None` cases are named rather than collapsed, because they call for opposite fixes: a
/// missing RUNNING version means the daemon predates the field and a restart would resolve it, and
/// a missing ON-DISK version means the install is broken and a restart would make things worse.
#[must_use]
pub fn verdict(running: Option<&str>, on_disk: Option<&str>) -> Verdict {
    let Some(running) = running else {
        return Verdict::Unknown(RUNNING_SILENT);
    };
    let Some(on_disk) = on_disk else {
        return Verdict::Unknown(ON_DISK_SILENT);
    };
    if running == on_disk {
        Verdict::Current(running.to_owned())
    } else {
        Verdict::Stale {
            running: running.to_owned(),
            on_disk: on_disk.to_owned(),
        }
    }
}

/// The version out of a `--version` banner.
///
/// The contract every shipped binary honours (`docs/49`) is: the second whitespace-separated field
/// of the FIRST line is the version, and whatever follows is free text. That is why the
/// parenthetical each daemon adds — `(protocol 1)`, `(scrcpy 4.1)` — costs nothing here, and why
/// `package-release.sh` can ask the same question of every shipped binary with one `awk`.
///
/// The parse is POSITIONAL, not semantic: it does not check that field two looks like a version,
/// because the only caller compares it against another field two read the same way. A binary that
/// answered something else entirely compares unequal and lands in [`Verdict::Stale`], which is a
/// log line — [`Verdict::Unknown`] is reserved for a MISSING field, not an odd one.
#[must_use]
pub fn parse_version_banner(output: &str) -> Option<&str> {
    output.lines().next()?.split_whitespace().nth(1)
}

/// One line of the report hostd logs, and the client shows.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Report {
    /// The tool's `MANIFEST.json` name, e.g. `slopdesk-superd`.
    pub tool: String,
    /// What the comparison concluded.
    pub verdict: Verdict,
    /// What may be done about it, from [`policy`].
    pub policy: RestartPolicy,
}

impl Report {
    /// Audits one sidecar from the two numbers its caller gathered.
    #[must_use]
    pub fn new(tool: &str, running: Option<&str>, on_disk: Option<&str>) -> Self {
        Self {
            tool: tool.to_owned(),
            verdict: verdict(running, on_disk),
            policy: policy(tool),
        }
    }

    /// True when the daemon is running code the install has replaced AND the caller may fix it
    /// itself. Both halves matter: the policy says what MAY be done, and a caller that holds no
    /// handle still cannot act on it.
    #[must_use]
    pub const fn restartable(&self) -> bool {
        matches!(self.verdict, Verdict::Stale { .. }) && matches!(self.policy, RestartPolicy::Automatic)
    }

    /// One sentence for the log. Says which way round the two numbers are, because "stale" alone
    /// leaves the reader unable to tell an upgrade from a downgrade.
    #[must_use]
    pub fn summary(&self) -> String {
        match self.verdict {
            Verdict::Current(ref version) => format!("{} {version} is current", self.tool),
            Verdict::Stale {
                ref running,
                ref on_disk,
            } => {
                format!(
                    "{} is running {running}, {on_disk} is installed — {}",
                    self.tool,
                    self.policy.remedy(),
                )
            },
            Verdict::Unknown(reason) => format!("{} version is unknown: {reason}", self.tool),
        }
    }

    /// The report as the JSON object the FFI door hands to Swift.
    ///
    /// A record rather than a formatted line, because the near side shows it in a UI as well as
    /// logging it — but `summary` rides along so the WORDING is decided once, here, and not
    /// re-invented by every caller that has to print it.
    #[must_use]
    pub fn to_json(&self) -> String {
        let mut object = serde_json::Map::new();
        object.insert("tool".to_owned(), self.tool.clone().into());
        object.insert("state".to_owned(), self.verdict.state().into());
        object.insert("policy".to_owned(), self.policy.name().into());
        object.insert("restartable".to_owned(), self.restartable().into());
        object.insert("summary".to_owned(), self.summary().into());
        match self.verdict {
            Verdict::Current(ref version) => {
                object.insert("running".to_owned(), version.clone().into());
                object.insert("onDisk".to_owned(), version.clone().into());
            },
            Verdict::Stale {
                ref running,
                ref on_disk,
            } => {
                object.insert("running".to_owned(), running.clone().into());
                object.insert("onDisk".to_owned(), on_disk.clone().into());
            },
            Verdict::Unknown(reason) => {
                object.insert("reason".to_owned(), reason.into());
            },
        }
        serde_json::Value::Object(object).to_string()
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::*;

    // ── The banner parse ──────────────────────────────────────────────────────────────────

    #[test]
    fn the_version_is_the_second_field_of_the_first_line() {
        assert_eq!(
            parse_version_banner("slopdesk-dropd 0.1.0 (protocol 1)"),
            Some("0.1.0")
        );
        assert_eq!(
            parse_version_banner("slopdesk-superd 0.2.1 (com.slopdesk.superd, protocol 1.8)"),
            Some("0.2.1")
        );
        assert_eq!(
            parse_version_banner("slopdesk-inspectord 0.1.0\nnoise\n"),
            Some("0.1.0")
        );
    }

    #[test]
    fn a_banner_with_no_second_field_is_not_a_version() {
        assert_eq!(parse_version_banner(""), None);
        assert_eq!(parse_version_banner("slopdesk-dropd"), None);
        assert_eq!(parse_version_banner("\n"), None);
    }

    // ── The comparison ────────────────────────────────────────────────────────────────────

    #[test]
    fn equal_versions_are_current_and_different_ones_are_stale() {
        assert_eq!(
            verdict(Some("0.1.0"), Some("0.1.0")),
            Verdict::Current("0.1.0".to_owned())
        );
        assert_eq!(verdict(Some("0.1.0"), Some("0.2.0")), Verdict::Stale {
            running: "0.1.0".to_owned(),
            on_disk: "0.2.0".to_owned(),
        });
    }

    /// A DOWNGRADE reads the same as an upgrade, deliberately: the process and the install disagree
    /// either way, and the restart that reconciles them is the same one.
    #[test]
    fn a_downgrade_is_stale_too() {
        assert_eq!(verdict(Some("0.2.0"), Some("0.1.0")), Verdict::Stale {
            running: "0.2.0".to_owned(),
            on_disk: "0.1.0".to_owned(),
        });
    }

    /// The failure this whole mechanism exists to remove: a missing number reported as agreement.
    /// The two `None`s call for opposite fixes, so their reasons must differ rather than collapse.
    #[test]
    fn a_missing_number_is_never_current_and_says_which_side_is_missing() {
        assert_eq!(verdict(None, Some("0.1.0")), Verdict::Unknown(RUNNING_SILENT));
        assert_eq!(verdict(Some("0.1.0"), None), Verdict::Unknown(ON_DISK_SILENT));
        assert_eq!(verdict(None, None), Verdict::Unknown(RUNNING_SILENT));
        assert_ne!(verdict(None, Some("0.1.0")), verdict(Some("0.1.0"), None));
    }

    // ── The policy ────────────────────────────────────────────────────────────────────────

    /// The split is what a restart COSTS, not how important the daemon is.
    #[test]
    fn only_the_daemons_hostd_owns_may_be_restarted_on_their_own() {
        assert_eq!(policy("slopdesk-dropd"), RestartPolicy::Automatic);
        assert_eq!(policy("slopdesk-inspectord"), RestartPolicy::Automatic);
        assert_eq!(policy("slopdesk-androidd"), RestartPolicy::Automatic);
        // Ending superd ends every live pane. Information, never an action.
        assert_eq!(policy("slopdesk-superd"), RestartPolicy::OperatorChoice);
        // screend idles out on its own and the next verb starts the installed one.
        assert_eq!(policy("slopdesk-screend"), RestartPolicy::SelfRetiring);
    }

    #[test]
    fn a_tool_this_table_has_not_been_taught_about_is_never_restarted_silently() {
        assert_eq!(policy("slopdesk-somethingnew"), RestartPolicy::OperatorChoice);
    }

    /// The five that are not daemons are named, not left to the fallback: "your call" about a
    /// program that exits after every invocation is a line that asks for an action there is none
    /// of.
    #[test]
    fn the_fork_and_exit_programs_have_nothing_to_restart() {
        for tool in [
            "slopdesk",
            "slopdesk-ctl",
            "slopdesk-probe",
            "slopdesk-hook",
            "slopdesk-agenthooks",
            "slopdesk-codeseed",
        ] {
            assert_eq!(policy(tool), RestartPolicy::NotResident, "{tool}");
        }
        // hostd IS resident, and `CLAUDE.md` forbids killing it — so it is the user's call, not a
        // fork-and-exit program and not something this may restart.
        assert_eq!(policy("slopdesk-hostd"), RestartPolicy::OperatorChoice);
    }

    /// Only two of the twelve are launch agents, and the note that tells a user to kickstart one is
    /// built from THIS lookup rather than from the tool's name.
    #[test]
    fn only_the_two_launch_agents_have_a_label() {
        assert_eq!(launch_agent_label("slopdesk-superd"), Some("com.slopdesk.superd"));
        assert_eq!(
            launch_agent_label("slopdesk-screend"),
            Some("com.slopdesk.screend")
        );
        assert_eq!(
            launch_agent_label("slopdesk-dropd"),
            None,
            "superd's child, not launchd's"
        );
        assert_eq!(launch_agent_label("slopdesk-hostd"), None);
    }

    // ── The report ────────────────────────────────────────────────────────────────────────

    #[test]
    fn only_a_stale_automatic_sidecar_is_restartable() {
        assert!(Report::new("slopdesk-dropd", Some("0.1.0"), Some("0.2.0")).restartable());
        assert!(
            !Report::new("slopdesk-superd", Some("0.1.0"), Some("0.2.0")).restartable(),
            "superd is never restarted by hostd — it would take every live pane"
        );
        assert!(
            !Report::new("slopdesk-screend", Some("0.1.0"), Some("0.2.0")).restartable(),
            "screend retires itself; nothing outside launchd holds a handle to it"
        );
        assert!(!Report::new("slopdesk-dropd", Some("0.1.0"), Some("0.1.0")).restartable());
        assert!(!Report::new("slopdesk-dropd", None, Some("0.1.0")).restartable());
    }

    #[test]
    fn the_log_line_names_both_numbers_and_what_happens_next() {
        let stale = Report::new("slopdesk-dropd", Some("0.1.0"), Some("0.2.0")).summary();
        assert!(stale.contains("running 0.1.0"), "{stale}");
        assert!(stale.contains("0.2.0 is installed"), "{stale}");
        assert!(stale.contains("restarting"), "{stale}");

        let superd = Report::new("slopdesk-superd", Some("0.1.0"), Some("0.2.0")).summary();
        assert!(superd.contains("every live pane"), "{superd}");
    }

    /// The door's shape, asserted here rather than on the far side: the near side decodes these
    /// exact keys, and a test in Swift asserting them would be the cross-language mirror fixture.
    #[test]
    fn the_json_carries_every_field_the_near_side_decodes() {
        let stale: serde_json::Value =
            serde_json::from_str(&Report::new("slopdesk-dropd", Some("0.1.0"), Some("0.2.0")).to_json())
                .expect("the report encodes valid JSON");
        assert_eq!(stale["tool"], "slopdesk-dropd");
        assert_eq!(stale["state"], "stale");
        assert_eq!(stale["running"], "0.1.0");
        assert_eq!(stale["onDisk"], "0.2.0");
        assert_eq!(stale["policy"], "automatic");
        assert_eq!(stale["restartable"], true);
        assert!(stale["summary"].as_str().is_some_and(|s| s.contains("0.2.0")));

        let unknown: serde_json::Value =
            serde_json::from_str(&Report::new("slopdesk-dropd", None, Some("0.2.0")).to_json())
                .expect("the report encodes valid JSON");
        assert_eq!(unknown["state"], "unknown");
        assert_eq!(unknown["reason"], RUNNING_SILENT);
        assert!(
            unknown.get("running").is_none(),
            "an absent number must be absent, not an empty string a UI would print"
        );
    }
}
