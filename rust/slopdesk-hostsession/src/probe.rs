//! What the pane's detection asks the OS, and the one cache that keeps it affordable.
//!
//! Every syscall here belongs to [`PtyProcess`], which owns the master descriptor and answers
//! through its own lock — see the probe section there for why the fd never crosses. What is left
//! for this module is the part that is a DECISION rather than a read: which probe to reach for, and
//! how long an answer stays good.
//!
//! ## Two probes, and the reason there are two
//!
//! `foreground_executable` is one `tcgetpgrp` and one `proc_pidpath`, and it answers for every
//! agent launched as itself. It does NOT answer for the npm-wrapped case, where the group leader is
//! `node` and the agent's name is only in somebody's argv — for that the probe has to enumerate the
//! whole process group and read each member's args, which is far too much to pay at the poll
//! cadence.
//!
//! So the deep probe runs only when the cheap one came back a GENERIC runtime or shell, and its
//! answer is cached: a hit sticks five seconds, a miss one. `claude` does not become `node` between
//! two ticks, and a shell that is about to launch one is worth re-asking sooner than one that is
//! not.
//!
//! ## What is duplicated here, and what deletes it
//!
//! The `ProcessSnapshot` → [`ForegroundJobProcess`] mapping is also spelled in
//! `rust/slopdesk-ffi/src/foreground.rs`, which is the door `PTYForegroundProbe.swift` calls today.
//! It cannot be shared: `slopdesk-agent` has NO dependencies on purpose (it is the pure detector)
//! and `slopdesk-posix` is syscalls, so the join between their two types belongs to whichever crate
//! holds both — today that is the FFI, and after stage F it is only this one. `docs/60` §5's
//! carve-out is what makes the overlap legal until then, and stage F is what ends it by deleting
//! the door.

use std::sync::{Mutex, PoisonError};

use slopdesk_agent::AgentKind;
use slopdesk_agent::job::{ForegroundJob, ForegroundJobProcess, realpath_basename};
use slopdesk_hostpane::PtyProcess;

/// How long a deep probe that FOUND an agent stays the answer.
const DEEP_HIT_TTL: f64 = 5.0;

/// How long a deep probe that found nothing stays the answer.
///
/// Shorter than [`DEEP_HIT_TTL`] on purpose: a bare `node` is very often about to become an agent,
/// and a five-second miss would leave the pane unlabelled for the first turn of one.
const DEEP_MISS_TTL: f64 = 1.0;

/// The deep probe's memory: what it last found, and when.
#[derive(Debug, Clone, Copy, Default)]
struct Cached {
    agent: Option<AgentKind>,
    /// `None` until the first deep probe — which is what makes the very first generic basename pay
    /// for one rather than reading a miss out of an empty cache.
    at: Option<f64>,
}

/// One pane's foreground resolution, with the deep probe's cache.
#[derive(Debug, Default)]
pub(crate) struct Foreground {
    cached: Mutex<Cached>,
}

impl Foreground {
    /// The canonical basename of whatever holds the pane's terminal, or an EMPTY string.
    ///
    /// Empty rather than `None` because that is what the detector's `sample` takes for "nothing is
    /// in the foreground" — the state between one child exiting and the next starting, which is a
    /// fact about the pane and not a failure to read it.
    pub(crate) fn name(pty: &PtyProcess) -> String {
        pty.foreground_executable().map_or_else(String::new, |path| {
            String::from(slopdesk_agent::process::canonical_name(&path))
        })
    }

    /// Which agent holds the pane's terminal, for the SCREEN engine's label.
    ///
    /// The ladder in order: the cheap basename; a direct match on it (which also drops the cache —
    /// a named agent supersedes whatever the deep probe last guessed); otherwise, only for a
    /// generic runtime or shell, the cached deep probe.
    pub(crate) fn agent(&self, pty: &PtyProcess, now: f64) -> Option<AgentKind> {
        let base = Self::name(pty);
        if base.is_empty() {
            return None;
        }
        if let Some(direct) = AgentKind::identify(&base) {
            *self.cached.lock().unwrap_or_else(PoisonError::into_inner) = Cached::default();
            return Some(direct);
        }
        if !AgentKind::is_generic_runtime_or_shell(&base) {
            return None;
        }
        self.deep(pty, now)
    }

    /// The cached deep probe, re-run when its answer has aged past the TTL for what it found.
    fn deep(&self, pty: &PtyProcess, now: f64) -> Option<AgentKind> {
        let mut cached = self.cached.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(at) = cached.at {
            let ttl = if cached.agent.is_some() {
                DEEP_HIT_TTL
            } else {
                DEEP_MISS_TTL
            };
            if now - at < ttl {
                return cached.agent;
            }
        }
        // The enumeration happens under the cache lock, which is deliberate: two scan ticks for one
        // pane cannot overlap (there is ONE scan thread), so the only contention is a readout, and
        // letting a second probe start would pay the same group walk twice for one answer.
        cached.at = Some(now);
        cached.agent = identify(pty);
        cached.agent
    }
}

/// The deep probe itself: the whole foreground job, folded through the pure identifier.
fn identify(pty: &PtyProcess) -> Option<AgentKind> {
    let (process_group_id, snapshots) = pty.foreground_job()?;
    let job = ForegroundJob {
        process_group_id,
        processes: snapshots.into_iter().map(member).collect(),
    };
    slopdesk_agent::job::identify(&job, &realpath_basename).map(|(kind, _)| kind)
}

/// One probed process as the identifier's shape.
///
/// `argv0` carries the login shell's leading `-` stripped, and an EMPTY argv stays `None` rather
/// than becoming `Some(vec![])`: the ladder reads "no argv was recoverable" and "argv is empty"
/// apart, and a process whose args could not be read is the first case.
fn member(snapshot: slopdesk_posix::proc::ProcessSnapshot) -> ForegroundJobProcess {
    let argv0 = snapshot
        .argv
        .first()
        .map(|first| first.strip_prefix('-').unwrap_or(first).to_owned());
    ForegroundJobProcess {
        pid: snapshot.pid,
        name: snapshot.name,
        argv0,
        argv: if snapshot.argv.is_empty() {
            None
        } else {
            Some(snapshot.argv)
        },
        cmdline: None,
    }
}

/// The pane's working directory, as the host can see it.
///
/// The foreground group leader first, the shell as the fallback — the leader is where a `cd` inside
/// a subshell shows up, and the shell is what answers at a bare prompt. `None` when neither reads,
/// which the caller treats as "no probe opinion" and falls back on the sniffed OSC-7.
pub(crate) fn working_directory(pty: &PtyProcess) -> Option<String> {
    pty.foreground_group()
        .and_then(slopdesk_posix::proc::working_directory)
        .or_else(|| pty.pid().and_then(slopdesk_posix::proc::working_directory))
}
