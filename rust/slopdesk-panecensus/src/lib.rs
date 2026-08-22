//! The three pane-anchored answers of the metadata RPC: a working directory, a process list and a
//! listening-port list.
//!
//! ## What a pane IS, here
//! A PTY master fd, and the set of processes whose CONTROLLING TERMINAL is its slave. That set is
//! defined by a device NUMBER — `proc_bsdinfo.e_tdev` compared against the slave's `st_rdev` — and
//! never by a path, because a path can be reused and a device number in a live table cannot.
//!
//! Everything else follows from that set: the ports are what its members are listening on, and the
//! working directory is the foreground leader's, falling back to the shell's.
//!
//! ## Why two of the three answer ENCODED bytes
//! hostd's responder forwards a process list and a port list to the client verbatim — it holds no
//! opinion about either. So they cross the C ABI already encoded, the way `slopdesk_git_status`
//! does, rather than as records the far side re-encodes one line later. The working directory does
//! NOT, because hostd genuinely uses it: it is the confinement root every path-carrying verb is
//! checked against.
//!
//! ## Validate-then-drop, everywhere
//! A pid that exits mid-census, a name that is not UTF-8, an `lsof` line that is not a port — each
//! is SKIPPED. Nothing here fails a request: a pane whose PTY is gone reports an empty list, which
//! is the honest answer and the one the client already renders.

use slopdesk_wire::metadata::codec::{PortInfo, PortProtocol, ProcessInfo};

/// The process-list cap.
///
/// A second backstop under the wire codec's own `u16` clamp, at a size no real pane reaches: 256
/// processes on one terminal is already a runaway. It exists so a pathological host cannot spend a
/// frame's whole budget on one pane's census.
pub const MAX_PROCESSES: usize = 256;

/// The port-list cap, for [`MAX_PROCESSES`]' reason. Higher because one process can hold many
/// listeners and the entries are far smaller.
pub const MAX_PORTS: usize = 512;

/// Where `lsof` lives on macOS. Absolute on purpose: this is a subprocess hostd spawns, and
/// resolving it through `PATH` would let the environment decide which program runs.
const LSOF: &str = "/usr/sbin/lsof";

/// The pane's working directory: the foreground group leader's, or the shell's when that cannot be
/// read.
///
/// The foreground leader FIRST because it is what the person is looking at — `cd`ing inside a
/// subshell, or a build running in a subdirectory, both move the answer the way a person expects.
/// The shell pid is the fallback rather than the primary for the same reason it is a fallback in
/// the sidebar: between one command exiting and the next starting there is no foreground group at
/// all, and the pane's root must not blink to nothing in that window.
///
/// `None` when neither resolves. Every path-carrying verb refuses outright on that, which is the
/// point — a metadata request confined against a GUESSED root is a request confined against the
/// wrong directory.
#[must_use]
pub fn working_directory(master_fd: i32, shell_pid: i32) -> Option<String> {
    let leader = foreground_leader(master_fd, shell_pid);
    slopdesk_posix::proc::working_directory(leader)
        .or_else(|| slopdesk_posix::proc::working_directory(shell_pid))
}

/// The pane's processes, already encoded as the metadata RPC's process list.
///
/// `now_unix` is the caller's clock, not one read here, so the whole census shares one instant: a
/// list whose uptimes were each measured against a different `now` would show processes started in
/// the same second with different ages.
///
/// A process whose start time is unreadable or in the FUTURE reports an uptime of `0` rather than a
/// negative one wrapped into a huge positive — a clock that moved backwards must not turn a
/// second-old process into one that has run for a century.
#[must_use]
pub fn process_list(master_fd: i32, now_unix: i64) -> Vec<u8> {
    let Some(device) = slopdesk_posix::pty::slave_device(master_fd) else {
        return slopdesk_wire::metadata::codec::encode_process_list(&[]);
    };
    let mut processes = Vec::new();
    for pid in slopdesk_posix::proc::all_pids() {
        let Some((tty, start)) = slopdesk_posix::proc::tty_and_start(pid) else {
            continue;
        };
        if tty != device {
            continue;
        }
        processes.push(ProcessInfo {
            pid: pid.cast_unsigned(),
            uptime_sec: uptime_seconds(start, now_unix),
            name: process_name(pid),
        });
        if processes.len() >= MAX_PROCESSES {
            break;
        }
    }
    slopdesk_wire::metadata::codec::encode_process_list(&processes)
}

/// The ports the pane's processes are listening on, already encoded as the metadata RPC's port
/// list.
///
/// TCP first, then UDP, because the client renders them in that order and the wire carries no sort
/// key. Two `lsof` invocations rather than one because the TCP scan needs `-sTCP:LISTEN` to exclude
/// established connections, and that flag is meaningless for UDP — one combined call would either
/// list every socket a pane has open or list no UDP at all.
///
/// An empty list is a VALID answer and the common one; it is not an error, and the client says "No
/// listening ports".
#[must_use]
pub fn port_list(master_fd: i32) -> Vec<u8> {
    let pids = pane_pids(master_fd);
    if pids.is_empty() {
        return slopdesk_wire::metadata::codec::encode_port_list(&[]);
    }
    let scope = pids.iter().map(ToString::to_string).collect::<Vec<_>>().join(",");
    let mut ports = scan(&scope, PortProtocol::Tcp);
    ports.extend(scan(&scope, PortProtocol::Udp));
    ports.truncate(MAX_PORTS);
    slopdesk_wire::metadata::codec::encode_port_list(&ports)
}

/// One `lsof` invocation, parsed.
fn scan(scope: &str, protocol: PortProtocol) -> Vec<PortInfo> {
    let mut arguments = vec!["-nP", "-w", "-a", "-p", scope, "-F", "cn"];
    match protocol {
        PortProtocol::Tcp => arguments.extend(["-iTCP", "-sTCP:LISTEN"]),
        PortProtocol::Udp => arguments.push("-iUDP"),
    }
    let Some(output) = slopdesk_probe::run::capture_text(LSOF, &arguments) else {
        return Vec::new();
    };
    parse_lsof(&output, protocol)
}

/// Parses `lsof -F cn` field output.
///
/// The format is one field per line, tagged by its first byte: `c<command>` sets the command every
/// later line belongs to, and `n<address>` is one socket. The port is the integer after the LAST
/// `:` of the address, which is what makes `*:8080`, `127.0.0.1:80` and `[::1]:443` one rule
/// instead of three.
///
/// Every other tag is skipped, and so is any `n` line whose tail is not a port — `lsof` output is
/// untrusted input, and a line that does not parse is one port missing rather than a failed
/// request.
#[must_use]
pub fn parse_lsof(output: &str, protocol: PortProtocol) -> Vec<PortInfo> {
    let mut ports = Vec::new();
    let mut command = String::new();
    for line in output.split('\n').filter(|line| !line.is_empty()) {
        let mut characters = line.chars();
        let Some(tag) = characters.next() else {
            continue;
        };
        let value = characters.as_str();
        match tag {
            'c' => value.clone_into(&mut command),
            'n' => {
                let Some((_address, port)) = value.rsplit_once(':') else {
                    continue;
                };
                let Ok(port) = port.parse::<u16>() else {
                    continue;
                };
                ports.push(PortInfo {
                    port,
                    proto: protocol.as_byte(),
                    proc_name: command.clone(),
                });
                if ports.len() >= MAX_PORTS {
                    return ports;
                }
            },
            _ => {},
        }
    }
    ports
}

/// The pids whose controlling terminal is this pane's PTY.
fn pane_pids(master_fd: i32) -> Vec<i32> {
    let Some(device) = slopdesk_posix::pty::slave_device(master_fd) else {
        return Vec::new();
    };
    slopdesk_posix::proc::all_pids()
        .into_iter()
        .filter(|pid| slopdesk_posix::proc::tty_and_start(*pid).is_some_and(|(tty, _start)| tty == device))
        .take(MAX_PROCESSES)
        .collect()
}

/// The foreground group leader of `master_fd`, or `shell_pid` when the terminal has none.
fn foreground_leader(master_fd: i32, shell_pid: i32) -> i32 {
    if master_fd < 0 {
        return shell_pid;
    }
    slopdesk_posix::pty::foreground_process_group(master_fd)
        .ok()
        .filter(|group| *group > 0)
        .unwrap_or(shell_pid)
}

/// What a process is CALLED in the pane's list.
///
/// The executable's basename first, and the kernel's 16-byte `comm` only when the path cannot be
/// read — a system process this host is not entitled to `proc_pidpath`. Empty when neither answers,
/// because a row with no name is still a row: the pid and the uptime are true, and inventing a name
/// for it would be the only lie in the list.
fn process_name(pid: i32) -> String {
    slopdesk_posix::proc::executable_path(pid)
        .map(|path| slopdesk_agent::process::basename(&path).to_owned())
        .or_else(|| slopdesk_posix::proc::short_name(pid))
        .unwrap_or_default()
}

/// How long a process started at `start_unix` has been running, as of `now_unix`.
///
/// Saturating on purpose at both ends: a start time of `0` (unreadable) and a start time in the
/// future both answer `0`, and an implausibly old one clamps rather than wrapping.
fn uptime_seconds(start_unix: i64, now_unix: i64) -> u32 {
    if start_unix <= 0 {
        return 0;
    }
    u32::try_from(now_unix.saturating_sub(start_unix).max(0)).unwrap_or(u32::MAX)
}

#[cfg(test)]
mod tests {
    use slopdesk_wire::metadata::codec::PortProtocol;

    use super::{parse_lsof, process_list, uptime_seconds, working_directory};

    /// The three address shapes `lsof` prints are ONE rule — the integer after the last colon —
    /// and the command carries forward from its `c` line to every socket under it.
    #[test]
    fn every_address_shape_yields_the_port_after_its_last_colon() {
        let output = "cnode\nn*:8080\nn127.0.0.1:80\ncPython\nn[::1]:443\n";
        let ports = parse_lsof(output, PortProtocol::Tcp);
        assert_eq!(
            ports
                .iter()
                .map(|port| (port.port, port.proc_name.as_str()))
                .collect::<Vec<_>>(),
            vec![(8080, "node"), (80, "node"), (443, "Python")]
        );
        assert!(ports.iter().all(|port| port.proto == PortProtocol::Tcp.as_byte()));
    }

    /// A line that is not a port must cost that line and nothing else. This is hostile input: an
    /// `lsof` that printed a warning, a socket with no port, a tag this parser has never seen.
    #[test]
    fn a_line_that_is_not_a_port_is_dropped_rather_than_failing_the_scan() {
        let output = "cnode\nnpipe\nn*:notaport\nn*:99999\nfsomething\n\nn*:22\n";
        let ports = parse_lsof(output, PortProtocol::Udp);
        assert_eq!(ports.len(), 1, "only the real port survives: {ports:?}");
        assert_eq!(ports.first().map(|port| port.port), Some(22));
        assert_eq!(
            ports.first().map(|port| port.proto),
            Some(PortProtocol::Udp.as_byte()),
            "the protocol comes from the scan, not from the line"
        );
    }

    /// A socket printed before any `c` line has no command, and must still be reported — the port
    /// is the fact the client needs, and an empty name is honest about the rest.
    #[test]
    fn a_socket_with_no_command_yet_is_still_a_port() {
        let ports = parse_lsof("n*:5000\n", PortProtocol::Tcp);
        assert_eq!(ports.len(), 1);
        assert_eq!(ports.first().map(|port| port.proc_name.as_str()), Some(""));
    }

    /// The cap holds inside the parse, not after it, so a pathological `lsof` cannot grow the
    /// vector past the ceiling before it is trimmed.
    #[test]
    fn the_port_cap_stops_the_parse_rather_than_trimming_it_afterwards() {
        let mut output = String::from("cflood\n");
        for _entry in 0..(super::MAX_PORTS + 100) {
            output.push_str("n*:1\n");
        }
        assert_eq!(parse_lsof(&output, PortProtocol::Tcp).len(), super::MAX_PORTS);
    }

    /// A clock that moved backwards, an unreadable start time and an ordinary one — the first two
    /// answer zero rather than an age of decades, which is what a wrapped subtraction would print.
    #[test]
    fn an_impossible_start_time_reports_no_uptime_rather_than_a_wrapped_one() {
        assert_eq!(uptime_seconds(0, 1_000), 0);
        assert_eq!(uptime_seconds(-5, 1_000), 0);
        assert_eq!(uptime_seconds(2_000, 1_000), 0, "started in the future");
        assert_eq!(uptime_seconds(900, 1_000), 100);
        assert_eq!(uptime_seconds(1, i64::MAX), u32::MAX, "clamped, not wrapped");
    }

    /// A descriptor that is not a PTY has no pane behind it, and every answer must be the EMPTY
    /// one rather than the machine's whole process table — a census scoped to nothing is the
    /// failure mode that would leak every process on the host into one pane's list.
    #[test]
    fn a_descriptor_that_is_not_a_pty_censuses_nothing() {
        // A two-byte count of zero, which is what the codec encodes for an empty list.
        assert_eq!(process_list(-1, 1_000), vec![0x00, 0x00]);
        assert_eq!(super::port_list(-1), vec![0x00, 0x00]);
        assert_eq!(working_directory(-1, 0), None);
    }
}
