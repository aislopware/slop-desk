//! Who holds a pane's PTY foreground — the whole question, answered on this side.
//!
//! ## Why these two doors are shaped like answers, not like data
//! What Swift used to do was PROBE: `tcgetpgrp`, `proc_pidpath`, `proc_listpids`, `proc_pidinfo`,
//! `sysctl(KERN_PROCARGS2)`, a hand-rolled `argv` walk, and then a per-process staging dance across
//! this boundary to hand the result back to the crate that could identify it. Six syscalls and N+1
//! boundary crossings per poll, to ask one question.
//!
//! The probe is `slopdesk_posix::proc` now and the identification was always
//! `slopdesk_agent::job`, so the two halves meet HERE and a caller asks once. That is also what
//! retires the staging handle (`slopdesk_agent_job_new`/`_push_process`/`_push_argv`/`_identify`)
//! and the symlink-resolver trampoline with it: the only reason a job was ever assembled one field
//! at a time was that Swift owned the syscalls, and it does not.
//!
//! ## macOS only
//! Every syscall behind [`slopdesk_posix::proc`] is a Darwin private-API `proc_*` or a
//! `KERN_PROCARGS2` `sysctl`, and the only caller is hostd. The `cfg` in `lib.rs`, the
//! `TARGET_OS_OSX` guard in `slopdesk_ffi.h` and the `MACOS-ONLY` region `scripts/build-ffi.sh`
//! reads out of that header are the three spellings that keep it true — `docs/57` §3.

use core::ffi::c_uchar;

use slopdesk_agent::job::{ForegroundJob, ForegroundJobProcess, realpath_basename};

use crate::deliver;

/// The CANONICAL name of the program holding this PTY's foreground process group.
///
/// `0` — §4's `Option::None` — for a closed fd, a PTY with no foreground group, and a process that
/// exited between the two syscalls. All three are the same answer to the detector: nothing is
/// there, so clear presence rather than hold the last name.
///
/// Canonical rather than raw because the Claude Code native installer NAMES its executable by
/// version (`…/claude/versions/2.1.218`); a raw basename would defeat the `claude` classifier and
/// print a version string in the sidebar's program slot.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pty_foreground_name(
    master_fd: i32,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(path) = slopdesk_posix::proc::foreground_executable(master_fd) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe {
        deliver(
            slopdesk_agent::process::canonical_name(&path).as_bytes(),
            out,
            cap,
        )
    }
}

/// Which agent holds this PTY's foreground process group, as its index into `AgentKind::ALL` —
/// the Swift enum's `allCases` order — or `-1` for none.
///
/// The DEEP probe: the whole process group with each member's `comm` and `argv`, folded through
/// `slopdesk_agent::job::identify`. It is the answer to the npm-wrapped case, where the group
/// leader is `node` and the agent's name is only in someone's argv, so a caller reaches for it
/// exactly when [`slopdesk_pty_foreground_name`] answered a generic runtime or shell.
///
/// Symlinks resolve through [`realpath_basename`] — the crate's own `canonicalize`, run on this
/// side. Routing that touch back out through a callback cost two boundary crossings per token to
/// reach the same `realpath`, and there is no caller left that wants a different resolver: the
/// hermetic ones are `slopdesk-agent`'s own tests, which call [`identify`] directly with a closure.
///
/// [`identify`]: slopdesk_agent::job::identify
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub extern "C" fn slopdesk_pty_foreground_agent(master_fd: i32) -> i32 {
    let Some((process_group_id, snapshots)) = slopdesk_posix::proc::foreground_job(master_fd) else {
        return -1;
    };
    let job = ForegroundJob {
        process_group_id,
        processes: snapshots.into_iter().map(process).collect(),
    };
    slopdesk_agent::job::identify(&job, &realpath_basename)
        .map_or(-1, |(kind, _)| crate::agent::kind_index(kind))
}

/// One probed process as the identifier's shape.
///
/// `argv0` carries the login shell's leading `-` stripped, and an EMPTY argv stays `None` rather
/// than becoming `Some(vec![])` — the ladder reads "no argv was recoverable" and "argv is empty"
/// apart, and a process whose args could not be read is the first case.
fn process(snapshot: slopdesk_posix::proc::ProcessSnapshot) -> ForegroundJobProcess {
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

#[cfg(test)]
#[expect(
    unsafe_code,
    reason = "calling the C ABI the way Swift does is the thing under test"
)]
mod tests {
    use slopdesk_posix::proc::ProcessSnapshot;

    use super::{
        ForegroundJob, ForegroundJobProcess, process, realpath_basename, slopdesk_pty_foreground_agent,
        slopdesk_pty_foreground_name,
    };

    /// A closed descriptor has no foreground group, and both doors must say so with their own
    /// spelling of nothing rather than with a name or an index a caller would act on.
    #[test]
    fn a_descriptor_that_is_not_a_pty_answers_nothing_from_both_doors() {
        let mut out = [0u8; 64];
        // SAFETY: `out` is a live local, writable for its own length for the call.
        let needed = unsafe { slopdesk_pty_foreground_name(-1, out.as_mut_ptr(), out.len()) };
        assert_eq!(needed, 0);
        assert_eq!(slopdesk_pty_foreground_agent(-1), -1);
    }

    /// A login shell's `argv[0]` carries a leading `-` that names no program. Stripping it is the
    /// difference between the ladder seeing `zsh` and seeing a token it has never heard of.
    #[test]
    fn a_login_shells_leading_dash_is_not_part_of_its_name() {
        let snapshot = ProcessSnapshot {
            pid: 7,
            name: "zsh".to_owned(),
            argv: vec!["-zsh".to_owned()],
        };
        assert_eq!(process(snapshot).argv0.as_deref(), Some("zsh"));
    }

    /// An unreadable argv must stay ABSENT. `Some(vec![])` would tell the ladder the process
    /// genuinely ran with no arguments, which is a different fact and unwraps to a different agent.
    #[test]
    fn an_argv_that_could_not_be_read_is_absent_rather_than_empty() {
        let snapshot = ProcessSnapshot {
            pid: 8,
            name: "node".to_owned(),
            argv: Vec::new(),
        };
        let converted = process(snapshot);
        assert_eq!(converted.argv, None);
        assert_eq!(converted.argv0, None);
    }

    /// A wrapper whose own basename identifies nobody is resolved through the real filesystem.
    ///
    /// This is the arm the door takes in production, and it used to be a null callback pointer that
    /// the trampoline read as "fall back to the crate's `realpath`" — a distinction one wrong `if`
    /// would have collapsed into "resolve nothing". Passing [`realpath_basename`] by name removes
    /// the arm rather than testing it. The failure it guards is silent by construction: an
    /// unresolved wrapper simply goes unidentified and the pane shows no agent, with nothing
    /// logged.
    #[test]
    #[expect(
        clippy::expect_used,
        reason = "this case needs a real symlink on disk, and a fixture that failed to build it would \
                  otherwise assert about a resolver it never reached"
    )]
    fn a_wrapper_named_by_a_symlink_resolves_through_the_real_filesystem() {
        let dir = std::env::temp_dir().join(format!("slopdesk-resolver-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let target = dir.join("claude");
        let link = dir.join("cc-agent");
        std::fs::write(&target, b"#!/bin/sh\n").expect("target");
        drop(std::fs::remove_file(&link));
        std::os::unix::fs::symlink(&target, &link).expect("symlink");

        // The link's OWN basename identifies nobody, so this reaches the resolver and nothing else.
        assert_eq!(slopdesk_agent::AgentKind::identify("cc-agent"), None);

        let job = ForegroundJob {
            process_group_id: 41,
            processes: vec![ForegroundJobProcess {
                pid: 41,
                name: "cc-agent".to_owned(),
                argv0: None,
                argv: None,
                // The PATH token is read off argv/cmdline, never off argv0 —
                // `normalized_process_name` treats argv0 as a name and only these as a path.
                cmdline: Some(link.to_string_lossy().into_owned()),
            }],
        };
        let identified = slopdesk_agent::job::identify(&job, &realpath_basename);
        std::fs::remove_dir_all(&dir).ok();

        assert_eq!(
            identified.map(|(agent, _)| agent),
            Some(slopdesk_agent::AgentKind::Claude),
            "the door must resolve through the crate's realpath, not resolve nothing"
        );
    }

    /// The npm-wrapped case, end to end through the conversion: the group leader is a runtime and
    /// the agent's name is only in its argv. This is the whole reason the deep door exists.
    #[test]
    fn a_runtime_wrapping_an_agent_identifies_as_that_agent() {
        let job = ForegroundJob {
            process_group_id: 9,
            processes: vec![process(ProcessSnapshot {
                pid: 9,
                name: "node".to_owned(),
                argv: vec!["node".to_owned(), "/opt/bin/claude".to_owned()],
            })],
        };
        let identified = slopdesk_agent::job::identify(&job, &|_: &str| None);
        assert_eq!(
            identified.map(|(kind, _)| kind),
            Some(slopdesk_agent::AgentKind::Claude)
        );
    }
}
