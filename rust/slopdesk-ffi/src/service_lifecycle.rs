//! The two sidecar lifecycles' decisions, in C.
//!
//! The rules are `slopdesk_sidecars::service_lifecycle`; what is here is the marshalling.
//!
//! ## Why a probe round takes TWO calls and is still one rule
//!
//! The readiness probe is a loopback `connect`, and a syscall dialled from inside the artifact
//! would be a second dialler beside the one hostd already owns. So the fold answers a PLAN — boot,
//! report, or probe-this-port — and a round that lands on `probe` asks again with the answer in
//! hand. The record is unchanged between the two calls (the caller latches nothing until it has
//! been told what to latch), so the second call is the same question with one more fact, which is
//! `docs/55` §4's retry shape rather than a state machine with two homes. Both calls are a handful
//! of nanoseconds: §4c's first table prices a scalar door at ~1 ns and neither of these allocates.
//!
//! ## Nothing here knows which daemon it is
//!
//! Every announce marker crosses as `(ptr, len)`, including the `(v` that precedes a version. Each
//! daemon's `server.rs` spells its own and `rust/slopdesk-invariants` compares those spellings
//! against the near side's; a copy inside this artifact would be a third spelling nothing compares.

use core::ffi::c_uchar;

use slopdesk_sidecars::service_lifecycle::{
    self, AdoptVerdict, BootAction, BootGates, CodeCommand, ExtensionInstall, ProbeRecord, ProbeStep,
};

use crate::{borrow, deliver, optional_of};

/// One live child's record, as the near side holds it between rounds.
///
/// Two optionals cross as a value plus a presence flag rather than a sentinel — `docs/55` §4b —
/// because both of their absences are ordinary: a child that has not printed its announce line yet
/// has no port, and one on its first round has no probe stamp. A `0` port would be indistinguishable
/// from the `--port 0` echo the parse already refuses, and a `0` elapsed is a probe that ran now.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskHostProbeRecord {
    /// Nanoseconds since the readiness probe last ran; read only when `has_probe_stamp`.
    pub since_probe_nanos: u64,
    /// The port off the child's announce line; read only when `has_port`.
    pub port: u16,
    /// False when there is no child record at all, which answers `boot` whatever else says.
    pub has_record: bool,
    /// Whether the child is still alive.
    pub is_running: bool,
    /// Whether `port` means anything.
    pub has_port: bool,
    /// Latched by the first successful probe.
    pub ready: bool,
    /// Whether `since_probe_nanos` means anything.
    pub has_probe_stamp: bool,
}

/// What one ensure round does.
///
/// `action` is `0` boot a child, `1` report `state` on `port`, `2` probe `port` and ask again.
/// `state` is the wire's own `ServiceState` byte — `0` starting, `1` ready, `2` unavailable — so a
/// step handed straight into the metadata encoder never changes vocabulary on the way.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskHostProbeStep {
    /// The port to report or to probe. `0` on `action` `0`, and on a `1` that has learned none yet.
    pub port: u16,
    /// `0` boot · `1` report · `2` probe.
    pub action: c_uchar,
    /// The `ServiceState` byte; meaningful only when `action` is `1`.
    pub state: c_uchar,
}

/// Everything the workbench's boot gates read, none of which is a process.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskHostCodeGates {
    /// How many bundled extensions the profile registry still misses.
    pub missing: usize,
    /// Where the one-shot install stands: `0` unchecked · `1` installing · `2` done.
    pub install: c_uchar,
    /// Whether there is BOTH a binary and a seeder profile — one flag because they are one answer.
    pub launchable: bool,
    /// Whether the profile seed has already run this manager lifetime.
    pub settings_seeded: bool,
    /// Whether the bridge listener is already bound.
    pub bridge_started: bool,
}

/// What one boot round does, in the order the fields are declared.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskHostCodeBootStep {
    /// The install state to latch: `0` unchecked · `1` installing · `2` done.
    pub install: c_uchar,
    /// The `ServiceState` byte to report; meaningful only when `spawn` is false.
    pub state: c_uchar,
    /// Every gate is open — spawn the child. A spawn that then throws is the caller's to report.
    pub spawn: bool,
    /// Fork the profile seeder first.
    pub seed_settings: bool,
    /// Then bind the bridge listener.
    pub start_bridge: bool,
    /// Then run the one-shot marketplace install.
    pub install_extensions: bool,
}

/// The port a child announced, or `0` when this line carries none.
///
/// `0` is not a sentinel standing in for an absence: it is outside the answer's range by
/// construction, because a `:0` in an announce line is the port the child was ASKED for under
/// `--port 0`, echoed back before the OS had picked one. The rule refuses it either way.
///
/// `after_last_colon` picks the dialect: false takes the digit run IMMEDIATELY after `marker` (our
/// daemons, whose lines carry a parenthetical with a colon of its own), true takes the run after
/// the LAST colon of what follows it (a third-party line naming an address we do not control).
///
/// # Safety
/// Both `(ptr, len)` pairs must be readable for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_host_announced_port(
    marker: *const c_uchar,
    marker_len: usize,
    line: *const c_uchar,
    line_len: usize,
    after_last_colon: bool,
) -> u16 {
    // SAFETY: the caller's obligation, restated above; both borrows die with this call.
    let (marker, line) = unsafe { (borrow(marker, marker_len), borrow(line, line_len)) };
    let marker = core::str::from_utf8(marker).unwrap_or("");
    let line = core::str::from_utf8(line).unwrap_or("");
    let found = if after_last_colon {
        service_lifecycle::port_after_last_colon_following(marker, line)
    } else {
        service_lifecycle::port_directly_after(marker, line)
    };
    found.unwrap_or(0)
}

/// The crate version off the same announce line, searched from the end of `port_marker`.
///
/// Returns the bytes NEEDED — `0` when the line announces none, which is the ordinary answer for a
/// third-party backend and for one that predates the field. Both mean "unknown", never "current".
///
/// # Safety
/// All three `(ptr, len)` pairs must be readable, and `out` writable for `cap`, for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_host_announced_version(
    port_marker: *const c_uchar,
    port_marker_len: usize,
    version_marker: *const c_uchar,
    version_marker_len: usize,
    line: *const c_uchar,
    line_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrows die with this call.
    let (port_marker, version_marker, line) = unsafe {
        (
            borrow(port_marker, port_marker_len),
            borrow(version_marker, version_marker_len),
            borrow(line, line_len),
        )
    };
    let port_marker = core::str::from_utf8(port_marker).unwrap_or("");
    let version_marker = core::str::from_utf8(version_marker).unwrap_or("");
    let line = core::str::from_utf8(line).unwrap_or("");
    let Some(version) = service_lifecycle::announced_version(port_marker, version_marker, line) else {
        return 0;
    };
    // SAFETY: `out` is null or writable for `cap`, by the caller's obligation.
    unsafe { deliver(version.as_bytes(), out, cap) }
}

/// One ensure round of the OS-picks-the-port lifecycle.
///
/// `has_probe`/`probe` carry the readiness answer on the SECOND call of a round that landed on
/// `action` `2`; the first call passes `(false, false)`. The record is the same one both times.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_host_probe_step(
    record: SlopDeskHostProbeRecord,
    probe_interval_nanos: u64,
    has_probe: bool,
    probe: bool,
) -> SlopDeskHostProbeStep {
    let live = optional_of(
        record.has_record,
        ProbeRecord {
            port: optional_of(record.has_port, record.port),
            since_probe: optional_of(record.has_probe_stamp, record.since_probe_nanos),
            ready: record.ready,
            running: record.is_running,
        },
    );
    match service_lifecycle::probe_step(live, probe_interval_nanos, optional_of(has_probe, probe)) {
        ProbeStep::Boot => SlopDeskHostProbeStep { port: 0, action: 0, state: 0 },
        ProbeStep::Report { state, port } => SlopDeskHostProbeStep {
            port,
            action: 1,
            state: state.byte(),
        },
        ProbeStep::Probe { port } => SlopDeskHostProbeStep { port, action: 2, state: 0 },
    }
}

/// Whether a fact read off a child's log line may be written onto the current record: first writer
/// wins, and only for the generation that is still current.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_host_accepts_announcement(
    line_generation: u64,
    spawn_generation: u64,
    has_record: bool,
    already_recorded: bool,
) -> bool {
    service_lifecycle::accepts_announcement(
        line_generation,
        spawn_generation,
        has_record,
        already_recorded,
    )
}

/// What to do with the port a daemon announced, against the one hostd advertises: `0` adopt it,
/// `1` end it and relaunch on the wanted port, `2` end it and serve the other paths.
///
/// `attempt` is `0` for the first launch. A daemon that never spoke (`has_announced` false) and one
/// that spoke a different port get the same answer, which is the whole point of the rule.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_host_adopt_verdict(
    attempt: u32,
    has_announced: bool,
    announced: u16,
    wanted: u16,
) -> c_uchar {
    match service_lifecycle::adopt_verdict(attempt, optional_of(has_announced, announced), wanted) {
        AdoptVerdict::Adopt => 0,
        AdoptVerdict::Respawn => 1,
        AdoptVerdict::GiveUp => 2,
    }
}

/// The workbench's four gates between "there is a binary" and "spawn".
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_host_code_boot_step(
    gates: SlopDeskHostCodeGates,
) -> SlopDeskHostCodeBootStep {
    let step = service_lifecycle::boot_step(BootGates {
        missing: gates.missing,
        install: ExtensionInstall::from_byte(gates.install),
        launchable: gates.launchable,
        settings_seeded: gates.settings_seeded,
        bridge_started: gates.bridge_started,
    });
    let (spawn, state) = match step.action {
        BootAction::Spawn => (true, 0),
        BootAction::Report(state) => (false, state.byte()),
    };
    SlopDeskHostCodeBootStep {
        install: step.install.byte(),
        state,
        spawn,
        seed_settings: step.seed_settings,
        start_bridge: step.start_bridge,
        install_extensions: step.install_extensions,
    }
}

/// How many times the workbench open is tried before it gives up and says so.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_host_code_open_attempts() -> u32 {
    service_lifecycle::OPEN_ATTEMPTS
}

/// The flag one code-server CLI one-shot leads with — `0` install an extension, `1` reuse a window
/// — as the bytes NEEDED. The argument after it is the caller's own identifier or target.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the buffer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_host_code_cli_flag(
    command: c_uchar,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let flag = service_lifecycle::code_cli_flag(if command == 1 {
        CodeCommand::ReuseWindow
    } else {
        CodeCommand::InstallExtension
    });
    // SAFETY: `out` is null or writable for `cap`, by the caller's obligation.
    unsafe { deliver(flag.as_bytes(), out, cap) }
}

/// A request root normalized — absolute, trailing-`/` trimmed — as the bytes NEEDED. `0` when the
/// path is not absolute. Whether it EXISTS and is a directory is the caller's `stat`, not this.
///
/// # Safety
/// `(path, len)` must be readable and `out` null or writable for `cap`, for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_host_canonical_root(
    path: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let lent = unsafe { borrow(path, len) };
    let Ok(text) = core::str::from_utf8(lent) else {
        return 0;
    };
    let Some(root) = service_lifecycle::canonical_root(text) else {
        return 0;
    };
    // SAFETY: `out` is null or writable for `cap`, by the caller's obligation.
    unsafe { deliver(root.as_bytes(), out, cap) }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use super::{
        SlopDeskHostCodeGates, SlopDeskHostProbeRecord, SlopDeskHostProbeStep,
        slopdesk_host_accepts_announcement, slopdesk_host_adopt_verdict,
        slopdesk_host_announced_port, slopdesk_host_announced_version, slopdesk_host_canonical_root,
        slopdesk_host_code_boot_step, slopdesk_host_code_cli_flag, slopdesk_host_code_open_attempts,
        slopdesk_host_probe_step,
    };

    const INTERVAL: u64 = 500_000_000;

    /// One announce line, read through the door in whichever dialect.
    fn port(marker: &str, line: &str, after_last_colon: bool) -> u16 {
        // SAFETY: both spans are live Rust slices for the length of the call.
        unsafe {
            slopdesk_host_announced_port(
                marker.as_ptr(),
                marker.len(),
                line.as_ptr(),
                line.len(),
                after_last_colon,
            )
        }
    }

    /// The bytes a `(out, cap) -> needed` door answers with, sized by a first call.
    fn read(mut door: impl FnMut(*mut u8, usize) -> usize) -> Option<String> {
        let needed = door(core::ptr::null_mut(), 0);
        if needed == 0 {
            return None;
        }
        let mut room = vec![0_u8; needed];
        let written = door(room.as_mut_ptr(), room.len());
        if written != needed {
            return None;
        }
        String::from_utf8(room).ok()
    }

    #[test]
    fn both_dialects_cross() {
        assert_eq!(port("on 127.0.0.1:", "dropd on 127.0.0.1:5123 (v0.2.0)", false), 5123);
        let marker = "HTTP server listening on http://";
        let line = "info  HTTP server listening on http://0.0.0.0:62636/";
        assert_eq!(port(marker, line, true), 62636);
    }

    #[test]
    fn a_line_with_no_port_answers_zero() {
        assert_eq!(port("on :", "nothing at all", false), 0);
        assert_eq!(port("on :", "on :0", false), 0, "the --port 0 echo is never an answer");
    }

    #[test]
    fn an_empty_marker_reads_as_no_marker_rather_than_every_marker() {
        // A null, zero-length pair is `borrow`'s empty slice, which the rule refuses.
        // SAFETY: a null pointer with a zero length is exactly what `borrow` accepts as empty.
        let answered = unsafe {
            slopdesk_host_announced_port(core::ptr::null(), 0, "on :5123".as_ptr(), 8, false)
        };
        assert_eq!(answered, 0);
    }

    #[test]
    fn a_version_crosses_and_an_absent_one_answers_zero() {
        let line = "dropd on 127.0.0.1:5123 (v0.2.0)";
        let read_version = |marker: &'static str, line: &'static str| {
            read(|out, cap| {
                // SAFETY: every span is a live Rust slice for the length of the call.
                unsafe {
                    slopdesk_host_announced_version(
                        marker.as_ptr(),
                        marker.len(),
                        "(v".as_ptr(),
                        2,
                        line.as_ptr(),
                        line.len(),
                        out,
                        cap,
                    )
                }
            })
        };
        assert_eq!(read_version("on 127.0.0.1:", line).as_deref(), Some("0.2.0"));
        assert_eq!(read_version("on 127.0.0.1:", "dropd on 127.0.0.1:5123").as_deref(), None);
    }

    #[test]
    fn a_short_buffer_is_told_the_length_and_written_nothing() {
        let line = "dropd on 127.0.0.1:5123 (v0.2.0)";
        let mut room = [0_u8; 2];
        // SAFETY: every span is a live Rust slice for the length of the call.
        let needed = unsafe {
            slopdesk_host_announced_version(
                "on 127.0.0.1:".as_ptr(),
                13,
                "(v".as_ptr(),
                2,
                line.as_ptr(),
                line.len(),
                room.as_mut_ptr(),
                room.len(),
            )
        };
        assert_eq!(needed, 5);
        assert_eq!(room, [0, 0]);
    }

    #[test]
    fn an_absent_record_boots_and_a_live_one_reports() {
        let empty = SlopDeskHostProbeRecord::default();
        assert_eq!(
            slopdesk_host_probe_step(empty, INTERVAL, false, false),
            SlopDeskHostProbeStep { port: 0, action: 0, state: 0 }
        );
        let latched = SlopDeskHostProbeRecord {
            since_probe_nanos: 0,
            port: 5123,
            has_record: true,
            is_running: true,
            has_port: true,
            ready: true,
            has_probe_stamp: true,
        };
        assert_eq!(
            slopdesk_host_probe_step(latched, INTERVAL, false, false),
            SlopDeskHostProbeStep { port: 5123, action: 1, state: 1 }
        );
    }

    #[test]
    fn a_due_round_asks_for_a_probe_and_folds_the_answer_on_the_second_call() {
        let waiting = SlopDeskHostProbeRecord {
            since_probe_nanos: 0,
            port: 5123,
            has_record: true,
            is_running: true,
            has_port: true,
            ready: false,
            has_probe_stamp: false,
        };
        assert_eq!(
            slopdesk_host_probe_step(waiting, INTERVAL, false, false),
            SlopDeskHostProbeStep { port: 5123, action: 2, state: 0 }
        );
        assert_eq!(
            slopdesk_host_probe_step(waiting, INTERVAL, true, true),
            SlopDeskHostProbeStep { port: 5123, action: 1, state: 1 }
        );
        assert_eq!(
            slopdesk_host_probe_step(waiting, INTERVAL, true, false),
            SlopDeskHostProbeStep { port: 5123, action: 1, state: 0 }
        );
    }

    #[test]
    fn only_the_current_generations_first_line_is_accepted() {
        assert!(slopdesk_host_accepts_announcement(4, 4, true, false));
        assert!(!slopdesk_host_accepts_announcement(3, 4, true, false));
        assert!(!slopdesk_host_accepts_announcement(4, 4, true, true));
    }

    #[test]
    fn the_adopt_ladder_crosses_as_three_bytes() {
        assert_eq!(slopdesk_host_adopt_verdict(0, true, 7000, 7000), 0);
        assert_eq!(slopdesk_host_adopt_verdict(0, true, 6999, 7000), 1);
        assert_eq!(slopdesk_host_adopt_verdict(0, false, 0, 7000), 1);
        assert_eq!(slopdesk_host_adopt_verdict(1, false, 0, 7000), 2);
    }

    #[test]
    fn the_boot_gates_cross_whole() {
        let cold = SlopDeskHostCodeGates {
            missing: 0,
            install: 0,
            launchable: true,
            settings_seeded: false,
            bridge_started: false,
        };
        let step = slopdesk_host_code_boot_step(cold);
        assert!(step.spawn);
        assert!(step.seed_settings);
        assert!(step.start_bridge);
        assert_eq!(step.install, 2);

        let deferring = slopdesk_host_code_boot_step(SlopDeskHostCodeGates { missing: 1, ..cold });
        assert!(!deferring.spawn);
        assert_eq!(deferring.state, 0, "starting");
        assert_eq!(deferring.install, 1);
        assert!(deferring.install_extensions);

        let barren =
            slopdesk_host_code_boot_step(SlopDeskHostCodeGates { launchable: false, ..cold });
        assert!(!barren.spawn);
        assert_eq!(barren.state, 2, "unavailable");
        assert!(!barren.seed_settings);
    }

    #[test]
    fn an_unknown_install_byte_re_checks_rather_than_skipping() {
        let step = slopdesk_host_code_boot_step(SlopDeskHostCodeGates {
            missing: 1,
            install: 200,
            launchable: true,
            settings_seeded: true,
            bridge_started: true,
        });
        assert_eq!(step.install, 1, "read as unchecked, so the registry is asked");
        assert!(step.install_extensions);
    }

    #[test]
    fn the_cli_flags_and_the_attempt_count_cross() {
        // SAFETY: the buffer is a live Rust slice for the length of each call.
        let flag = |command| read(|out, cap| unsafe { slopdesk_host_code_cli_flag(command, out, cap) });
        assert_eq!(flag(0).as_deref(), Some("--install-extension"));
        assert_eq!(flag(1).as_deref(), Some("-r"));
        assert_eq!(flag(200).as_deref(), Some("--install-extension"), "anything unnamed");
        assert_eq!(slopdesk_host_code_open_attempts(), 10);
    }

    #[test]
    fn a_root_crosses_normalized_and_a_relative_one_answers_zero() {
        // SAFETY: both spans are live Rust slices for the length of each call.
        let root = |path: &'static str| {
            read(|out, cap| unsafe {
                slopdesk_host_canonical_root(path.as_ptr(), path.len(), out, cap)
            })
        };
        assert_eq!(root("/Users/x/proj//").as_deref(), Some("/Users/x/proj"));
        assert_eq!(root("/").as_deref(), Some("/"));
        assert_eq!(root("proj").as_deref(), None);
        assert_eq!(root("").as_deref(), None);
    }
}
