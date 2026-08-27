//! Is the sidecar that is RUNNING the sidecar that is INSTALLED — the five audits, run together,
//! once.
//!
//! The port of `SidecarVersionAuditor.swift` and the half of
//! `SidecarVersionAudit.swift` that was not already Rust. [`slopdesk_sidecars`] decides about ONE
//! sidecar from two strings; this assembles the strings for all five and carries out the one action
//! a stale verdict permits.
//!
//! ## Nothing above this point notices an upgrade
//! superd and screend are launchd agents held across logins; dropd, inspectord and androidd are
//! superd's children that a restarted hostd ADOPTS rather than starts. So a `brew upgrade` writes
//! twelve new binaries and changes what is executing for none of them, and the failure mode is a
//! host silently running last week's code with this week's version number on the box. This says so,
//! once, in the log — and restarts the three whose restart costs a client a re-dial (`docs/49`).
//!
//! ## Where each RUNNING version comes from is the whole design
//! | daemon | channel |
//! | --- | --- |
//! | superd | `hello`'s `build_version`, minor 8 — it has a real handshake, so it uses it |
//! | screend | the third field of the `hello` reply, after the pinned protocol banner |
//! | dropd, inspectord, androidd | the announce line's `(v…` |
//!
//! The three that outlive hostd read their version off the announce line because hostd already
//! re-learns their ports by replaying superd's ring: that line is the only channel that describes a
//! child THIS hostd did not start. Every ON-DISK version is `<binary> --version`, field two of line
//! one — one contract, every shipped binary.
//!
//! ## The JSON door is not on this path any more
//! `SidecarVersionReport` reached [`slopdesk_sidecars::Report`] through
//! `slopdesk_sidecar_audit`, encoding the answer as JSON and decoding it a line later, because the
//! asker was Swift. hostd is Rust, so it holds the [`Report`] itself. The door stays exported for
//! the client that still shows the report; nothing here crosses it.
//!
//! ## Best-effort by construction
//! Every reader answers `None` for a daemon that is down, which is
//! [`Verdict::Unknown`](slopdesk_sidecars::Verdict::Unknown) — a log line and nothing else. The
//! audit must never be the thing that takes a host down.

use std::sync::Arc;

use slopdesk_hostserver::ensure::EnsuredService;
use slopdesk_screenclient::ScreenClient;
use slopdesk_sidecars::{Report, parse_version_banner};
use slopdesk_superclient::client::SupervisorClient;

use crate::observer::Stderr;
use crate::sidecar::Sidecar;

/// What a subject's version readers are, and what may be done about a stale one.
type Reader = Box<dyn Fn() -> Option<String> + Send + Sync>;

/// One sidecar's two readers and its remedy.
pub struct Subject {
    /// The name it ships under in `MANIFEST.json`, which is also the policy table's key.
    tool: &'static str,
    /// The version of the process that is serving, or `None` when it is not up or does not say.
    running: Reader,
    /// The version of the binary that would be started now, or `None` when there is none.
    installed: Reader,
    /// Restarts it. Only ever called for an
    /// [`Automatic`](slopdesk_sidecars::RestartPolicy::Automatic) subject, and only on a stale
    /// verdict. `None` for the ones hostd does not own.
    restart: Option<Box<dyn Fn() + Send + Sync>>,
}

impl core::fmt::Debug for Subject {
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        formatter
            .debug_struct("Subject")
            .field("tool", &self.tool)
            .field("restartable", &self.restart.is_some())
            .finish_non_exhaustive()
    }
}

/// The audit hostd runs against its own live sidecars, in the order the log prints them.
///
/// A `None` manager is simply not audited: there is nothing running to compare against, and a
/// subject reporting `unknown` about a path the operator turned off is noise. androidd is audited
/// unconditionally because its lifecycle always exists — a bridge that was never asked for reads
/// `unknown`, which is the truth about it.
#[must_use]
pub fn for_host(
    supervisor: &Arc<SupervisorClient>,
    screen: &Arc<ScreenClient>,
    drops: Option<&Arc<Sidecar>>,
    inspector: Option<&Arc<Sidecar>>,
    android: &Arc<EnsuredService>,
) -> Vec<Subject> {
    let mut subjects = vec![
        Subject {
            tool: "slopdesk-superd",
            running: {
                let link = Arc::clone(supervisor);
                Box::new(move || link.handshake().and_then(|hello| hello.build_version.clone()))
            },
            installed: installed_reader("slopdesk-superd"),
            restart: None,
        },
        Subject {
            tool: "slopdesk-screend",
            running: {
                let engine = Arc::clone(screen);
                Box::new(move || engine.build_version().ok().flatten())
            },
            installed: installed_reader("slopdesk-screend"),
            restart: None,
        },
    ];
    for daemon in [drops, inspector].into_iter().flatten() {
        let reader = Arc::clone(daemon);
        let remedy = Arc::clone(daemon);
        subjects.push(Subject {
            tool: daemon.tool(),
            running: Box::new(move || reader.running_version()),
            installed: installed_reader(daemon.tool()),
            // Ends the old one and starts the installed one on the SAME port and the same argv —
            // the port is hostd's to choose here, and a client that reconnects must find it
            // unmoved. The face holds both, so there is nothing to hand it.
            restart: Some(Box::new(move || {
                let _served = remedy.restart();
            })),
        });
    }
    let reader = Arc::clone(android);
    let remedy = Arc::clone(android);
    subjects.push(Subject {
        tool: "slopdesk-androidd",
        running: Box::new(move || reader.announced_version()),
        installed: installed_reader("slopdesk-androidd"),
        // No respawn here: androidd's port is the OS's, so ending it is the whole remedy — the next
        // `ensure` round finds it gone and boots the installed binary. Starting a second one here
        // would race that round for the panel's endpoint.
        restart: Some(Box::new(move || remedy.shutdown())),
    });
    subjects
}

/// Audits every subject, logs one line each, and restarts the stale ones it is allowed to.
///
/// Answers the reports so a caller can hand them to a client. Order follows `subjects`, so the log
/// reads the same every run — a report whose order shifts is a report nobody diffs.
///
/// A subject whose remedy is `None` is reported and left alone even when the policy is
/// `Automatic`: the policy says what MAY be done, the closure says what this caller CAN do, and a
/// manager that never came up has nothing to restart.
#[must_use]
pub fn run(subjects: &[Subject], log: &Stderr) -> Vec<Report> {
    subjects
        .iter()
        .map(|subject| {
            let report = Report::new(
                subject.tool,
                (subject.running)().as_deref(),
                (subject.installed)().as_deref(),
            );
            log.say(&format!("version-audit: {}", report.summary()));
            if report.restartable()
                && let Some(remedy) = subject.restart.as_ref()
            {
                remedy();
            }
            report
        })
        .collect()
}

/// A reader for the `--version` of the daemon binary THIS host would start.
///
/// The path is [`slopdesk_sidecars::paths::locate_from_env`], the same resolution the spawn uses:
/// an audit that compared against a binary that is not the one that would run would report a fixed
/// host as broken and a broken one as fixed.
fn installed_reader(tool: &'static str) -> Reader {
    Box::new(move || installed_version(tool))
}

/// The version the installed `tool` answers, or `None` when it is absent or would not run.
///
/// `output()` rather than a spawn-and-wait: it reads both pipes to EOF before reaping, so a banner
/// that outgrew the pipe buffer cannot deadlock this daemon's startup against its own child. That
/// is the Swift's read-before-wait comment, made structural.
fn installed_version(tool: &str) -> Option<String> {
    let binary = slopdesk_sidecars::paths::locate_from_env(tool)?;
    let banner = std::process::Command::new(binary)
        .arg("--version")
        .stdin(std::process::Stdio::null())
        .output()
        .ok()?;
    if !banner.status.success() {
        return None;
    }
    let text = String::from_utf8(banner.stdout).ok()?;
    parse_version_banner(&text).map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use slopdesk_sidecars::{RestartPolicy, Verdict};

    use super::{Subject, run};
    use crate::observer::Stderr;

    /// A subject whose two readers answer what the test says, recording whether it was restarted.
    fn subject(
        tool: &'static str,
        running: Option<&'static str>,
        installed: Option<&'static str>,
        restarted: &std::sync::Arc<std::sync::atomic::AtomicUsize>,
    ) -> Subject {
        let counter = std::sync::Arc::clone(restarted);
        Subject {
            tool,
            running: Box::new(move || running.map(str::to_owned)),
            installed: Box::new(move || installed.map(str::to_owned)),
            restart: Some(Box::new(move || {
                counter.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            })),
        }
    }

    #[test]
    fn a_stale_child_of_this_daemon_is_restarted_and_a_current_one_is_not() {
        let restarted = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let subjects = vec![
            subject("slopdesk-dropd", Some("0.1.0"), Some("0.2.0"), &restarted),
            subject("slopdesk-inspectord", Some("0.2.0"), Some("0.2.0"), &restarted),
        ];
        let reports = run(&subjects, &Stderr::named("test"));
        assert_eq!(restarted.load(std::sync::atomic::Ordering::SeqCst), 1);
        let mut verdicts = reports.iter().map(|report| &report.verdict);
        assert_eq!(
            verdicts.next(),
            Some(&Verdict::Stale {
                running: "0.1.0".to_owned(),
                on_disk: "0.2.0".to_owned(),
            }),
        );
        assert_eq!(verdicts.next(), Some(&Verdict::Current("0.2.0".to_owned())));
    }

    #[test]
    fn a_daemon_that_did_not_answer_is_reported_and_never_restarted() {
        let restarted = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let subjects = vec![
            subject("slopdesk-dropd", None, Some("0.2.0"), &restarted),
            subject("slopdesk-androidd", Some("0.2.0"), None, &restarted),
        ];
        let reports = run(&subjects, &Stderr::named("test"));
        assert_eq!(restarted.load(std::sync::atomic::Ordering::SeqCst), 0);
        for report in &reports {
            assert!(matches!(report.verdict, Verdict::Unknown(_)), "{report:?}");
            assert!(!report.restartable());
        }
    }

    #[test]
    fn a_stale_daemon_this_host_may_not_restart_is_only_reported() {
        // superd's policy is the operator's call — ending it takes every live pane — so a remedy
        // that EXISTS must still not fire. The policy decides, not the closure's presence.
        let restarted = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let subjects = vec![subject(
            "slopdesk-superd",
            Some("0.1.0"),
            Some("0.2.0"),
            &restarted,
        )];
        let reports = run(&subjects, &Stderr::named("test"));
        assert_eq!(restarted.load(std::sync::atomic::Ordering::SeqCst), 0);
        assert_eq!(
            reports.first().map(|report| report.policy),
            Some(RestartPolicy::OperatorChoice),
        );
    }

    #[test]
    fn the_report_order_is_the_subject_order_so_the_log_can_be_diffed() {
        let restarted = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let subjects = vec![
            subject("slopdesk-superd", Some("1"), Some("1"), &restarted),
            subject("slopdesk-screend", Some("1"), Some("1"), &restarted),
            subject("slopdesk-dropd", Some("1"), Some("1"), &restarted),
        ];
        let reports = run(&subjects, &Stderr::named("test"));
        let named: Vec<&str> = reports.iter().map(|report| report.tool.as_str()).collect();
        assert_eq!(named, ["slopdesk-superd", "slopdesk-screend", "slopdesk-dropd"]);
    }
}
