//! Its executable path, its group's members, its `comm` name, its argv, its working directory,
//! and which terminal it is attached to.
//!
//! Five Darwin calls with no wrapper in `std` or `nix` — `proc_pidpath`, `proc_name`,
//! `proc_listpids`, `proc_pidinfo` and `sysctl(KERN_PROCARGS2)` — each of which fills a
//! caller-provided buffer and reports how much of it it used. That is the shape this crate exists
//! for: the obligation is entirely local (is the buffer as big as I said, is the reported length
//! inside it) and can be discharged without naming anything above the syscall.
//!
//! The rule every one of them follows is VALIDATE-THEN-DROP. A length of zero or less, a size that
//! does not match what the struct needs, an argc outside a sane range — each answers `None` rather
//! than a default, because these feed agent detection and a wrong answer there labels a pane with
//! somebody else's process. Nothing here decides what a name MEANS; `slopdesk-agent` owns that.
//!
//! ## Why the whole probe is here rather than the primitives
//! [`foreground_job`] does the `tcgetpgrp`, the enumeration and the per-pid reads together for
//! [`pty::spawn_pty`]'s reason: what makes the sequence sound is not any one call but the window
//! between them. A pid enumerated from a process group can exit before its `proc_pidinfo` lands, so
//! every per-pid read is checked for the failure the race produces and the member is dropped —
//! which is a fact about THIS loop, and cannot be discharged by a caller holding a `Vec<i32>`.

use std::ffi::{CStr, c_void};
use std::mem::{size_of, size_of_val};

use crate::pty;

/// `PROC_PGRP_ONLY` from `<sys/proc_info.h>`, which the `libc` crate does not re-export.
///
/// Spelled here rather than reached for through a binding that does not exist: it is a stable
/// public header constant, and the alternative — a `bindgen` step for one integer — is a build
/// dependency bought for nothing.
const PROC_PGRP_ONLY: u32 = 2;

/// One process in a foreground group: what it is called and how it was invoked.
///
/// Plain data on purpose. `slopdesk-agent`'s `ForegroundJobProcess` is the type the identification
/// rules read, and it lives in a `forbid(unsafe_code)` crate that must not depend on this one —
/// so the shim that owns the ABI is what turns these into those.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ProcessSnapshot {
    /// The process id.
    pub pid: i32,
    /// The kernel's `comm` name — truncated to 16 bytes by the kernel, which is why argv matters.
    pub name: String,
    /// The full argv, or empty when it could not be read.
    ///
    /// Empty rather than absent because a caller that needs the distinction has `is_empty`, and a
    /// second `Option` layer over a `Vec` is a shape every call site would have to unwrap twice.
    pub argv: Vec<String>,
}

/// The foreground process group of a PTY master, with every member it could read.
///
/// `None` when the terminal has no foreground group — which is the normal state between a child
/// exiting and the next one starting, not an error — or when nothing in the group could be read.
#[must_use]
pub fn foreground_job(master: std::os::fd::RawFd) -> Option<(i32, Vec<ProcessSnapshot>)> {
    let group = pty::foreground_process_group(master).ok()?;
    if group <= 0 {
        return None;
    }
    let mut processes = Vec::new();
    for pid in process_group_pids(group) {
        // The membership re-check is not redundant with `proc_listpids`' filter: a pid can leave
        // the group (or exit and be recycled) between the enumeration and this read, and a process
        // from another group folded into this job would be attributed to the wrong pane.
        let Some((name, pgid)) = comm_and_group(pid) else {
            continue;
        };
        if pgid != group {
            continue;
        }
        processes.push(ProcessSnapshot {
            pid,
            name,
            argv: process_args(pid).unwrap_or_default(),
        });
    }
    (!processes.is_empty()).then_some((group, processes))
}

/// The executable path of a PTY master's foreground process group leader.
///
/// `None` on every failure the resolution can hit — no foreground group, the process exited
/// mid-read, a permission error — because each of them means the same thing to a caller: presence
/// could not be established, so clear it.
#[must_use]
pub fn foreground_executable(master: std::os::fd::RawFd) -> Option<String> {
    let group = pty::foreground_process_group(master).ok()?;
    (group > 0).then(|| executable_path(group)).flatten()
}

/// A process's executable path — `proc_pidpath`.
///
/// # Safety
/// `proc_pidpath` writes at most the byte count it is given into the buffer it is given, and
/// answers how many bytes it wrote. The buffer is a live local `Vec` whose capacity is passed
/// verbatim as that count, so the call cannot reach past it, and the returned length is checked to
/// be positive and within the buffer before any byte is read.
#[must_use]
#[expect(unsafe_code, reason = "proc_pidpath has no wrapper in std or nix")]
pub fn executable_path(pid: i32) -> Option<String> {
    // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN. Sized from the constant rather than from
    // MAXPATHLEN because the call documents a refusal, not a truncation, when the buffer is short.
    let mut buffer = vec![0_u8; 4 * libc::PATH_MAX as usize];
    let written = unsafe {
        libc::proc_pidpath(
            pid,
            buffer.as_mut_ptr().cast::<c_void>(),
            u32::try_from(buffer.len()).ok()?,
        )
    };
    let written = usize::try_from(written).ok()?;
    if written == 0 || written > buffer.len() {
        return None;
    }
    buffer.truncate(written);
    String::from_utf8(buffer).ok()
}

/// A process's `comm` name — `proc_name`, the SHORT name the kernel keeps beside the pid.
///
/// The fallback under [`executable_path`] for a process whose path cannot be read: a system process
/// the caller is not entitled to `proc_pidpath`, or one that execed out from under the read. It is
/// truncated to 16 bytes by the kernel, so it is a worse name and never the first choice.
///
/// # Safety
/// `proc_name` writes at most the byte count it is given into the buffer it is given and answers
/// how many bytes it wrote. The buffer is a live local whose length is passed verbatim as that
/// count, so the call cannot reach past it, and the returned length is checked to be positive and
/// within the buffer before any byte is read.
#[must_use]
#[expect(unsafe_code, reason = "proc_name has no wrapper in std or nix")]
pub fn short_name(pid: i32) -> Option<String> {
    // `MAXCOMLEN + 1` is 17; 256 is what the kernel's own callers pass and leaves no doubt.
    let mut buffer = vec![0_u8; 256];
    let written = unsafe {
        libc::proc_name(
            pid,
            buffer.as_mut_ptr().cast::<c_void>(),
            u32::try_from(buffer.len()).ok()?,
        )
    };
    let written = usize::try_from(written).ok()?;
    if written == 0 || written > buffer.len() {
        return None;
    }
    buffer.truncate(written);
    String::from_utf8(buffer).ok()
}

/// A process's current working directory — `proc_pidinfo(PROC_PIDVNODEPATHINFO)`.
///
/// `None` for a pid that is gone, one this process is not entitled to read, and one whose cwd
/// resolved to nothing. All three are the same answer to the metadata RPC: the pane has no root, so
/// every path-confined verb under it must refuse rather than fall back to somewhere else.
///
/// # Safety
/// As [`bsd_info`]: a live, fully-initialised local of exactly the type whose `size_of` is passed,
/// and a returned byte count required to EQUAL that size before any field is read. Zeroed rather
/// than `MaybeUninit` for the same reason — `proc_vnodepathinfo` is a plain C struct of integers
/// and byte arrays with no niches.
#[must_use]
#[expect(unsafe_code, reason = "proc_pidinfo has no wrapper in std or nix")]
pub fn working_directory(pid: i32) -> Option<String> {
    if pid <= 0 {
        return None;
    }
    let mut info: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
    let size = i32::try_from(size_of_val(&info)).ok()?;
    let got = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDVNODEPATHINFO,
            0,
            std::ptr::from_mut(&mut info).cast::<c_void>(),
            size,
        )
    };
    if got != size {
        return None;
    }
    // SAFETY: `vip_path` is a NUL-terminated C string in a fixed array the kernel filled. The slice
    // is built from the array's own pointer and its own SIZE, so it cannot reach past the struct,
    // and `from_bytes_until_nul` re-checks the terminator rather than trusting it.
    //
    // `size_of_val` and not `.len()`: `libc` declares this `MAXPATHLEN` array as `[[c_char; 32];
    // 32]`, so `.len()` is 32 — the number of ROWS. Reading 32 bytes finds no terminator in any
    // path longer than that, and every such cwd would answer `None` while short ones worked.
    let path = unsafe {
        std::slice::from_raw_parts(
            info.pvi_cdir.vip_path.as_ptr().cast::<u8>(),
            size_of_val(&info.pvi_cdir.vip_path),
        )
    };
    let path = CStr::from_bytes_until_nul(path).ok()?.to_str().ok()?;
    (!path.is_empty()).then(|| path.to_owned())
}

/// Every live pid on the machine — `proc_listpids(PROC_ALL_PIDS)`.
///
/// Sized from the call's own answer to a null buffer, plus headroom, because the census that
/// follows is a per-pid `proc_pidinfo` and a pid that appeared between the sizing call and the
/// filling one would otherwise silently truncate the list at whichever pid the kernel enumerated
/// last. The headroom is not a fix for that race — nothing here can be — it is what keeps the
/// common case from losing the tail of the list.
///
/// # Safety
/// As [`process_group_pids`]: the pointer and the size come from the same live `Vec` in the same
/// expression, and the answer is converted to an element count clamped to the buffer's length
/// before any element is read.
#[must_use]
#[expect(unsafe_code, reason = "proc_listpids has no wrapper in std or nix")]
pub fn all_pids() -> Vec<i32> {
    // `PROC_ALL_PIDS`, which libc does not re-export. 1 in `<sys/proc_info.h>`.
    const PROC_ALL_PIDS: u32 = 1;

    let sized = unsafe { libc::proc_listpids(PROC_ALL_PIDS, 0, std::ptr::null_mut(), 0) };
    let Ok(sized) = usize::try_from(sized) else {
        return Vec::new();
    };
    if sized == 0 {
        return Vec::new();
    }
    // Bytes to pids, then headroom for what starts while we are asking. Integer division IS the
    // operation, exactly as in `process_group_pids`.
    #[expect(
        clippy::integer_division,
        reason = "a byte count of whole pids; a remainder is a truncated entry, not a fraction"
    )]
    let capacity = sized / size_of::<i32>() + 16;
    let mut buffer = vec![0_i32; capacity];
    let Ok(bytes) = i32::try_from(size_of_val(buffer.as_slice())) else {
        return Vec::new();
    };
    let written =
        unsafe { libc::proc_listpids(PROC_ALL_PIDS, 0, buffer.as_mut_ptr().cast::<c_void>(), bytes) };
    let Ok(written) = usize::try_from(written) else {
        return Vec::new();
    };
    #[expect(
        clippy::integer_division,
        reason = "a byte count of whole pids; a remainder is a truncated entry, not a fraction"
    )]
    let count = (written / size_of::<i32>()).min(capacity);
    buffer.truncate(count);
    buffer.retain(|pid| *pid > 0);
    buffer
}

/// Every pid in a process group — `proc_listpids(PROC_PGRP_ONLY)`.
///
/// The buffer grows geometrically because the call answers "I filled all of it" and "there was
/// exactly this much" the same way: a full buffer is indistinguishable from a truncated one, so a
/// full one is retried at twice the size. Eight tries reaches 16 384 pids, which is past any real
/// process group and is the point at which a runaway is more likely than a real answer.
///
/// # Safety
/// `proc_listpids` writes at most `buffer_size` bytes into `buffer` and answers how many it wrote.
/// The pointer and the size come from the same live `Vec` in the same expression, and the answer is
/// converted to an element count that is clamped to the buffer's length before any element is read.
#[must_use]
#[expect(unsafe_code, reason = "proc_listpids has no wrapper in std or nix")]
pub fn process_group_pids(group: i32) -> Vec<i32> {
    let mut capacity = 64_usize;
    for _ in 0..8 {
        let mut buffer = vec![0_i32; capacity];
        let Ok(bytes) = i32::try_from(size_of_val(buffer.as_slice())) else {
            return Vec::new();
        };
        let Ok(group) = u32::try_from(group) else {
            return Vec::new();
        };
        let written = unsafe {
            libc::proc_listpids(PROC_PGRP_ONLY, group, buffer.as_mut_ptr().cast::<c_void>(), bytes)
        };
        let Ok(written) = usize::try_from(written) else {
            return Vec::new();
        };
        if written == 0 {
            return Vec::new();
        }
        // Bytes to pids. Integer division IS the operation — `proc_listpids` reports a byte count
        // that is a whole number of `pid_t`, and a remainder would mean a truncated final entry we
        // must not read either way.
        #[expect(
            clippy::integer_division,
            reason = "a byte count of whole pids; a remainder is a truncated entry, not a fraction"
        )]
        let count = written / size_of::<i32>();
        if count < capacity {
            buffer.truncate(count);
            buffer.retain(|pid| *pid > 0);
            return buffer;
        }
        capacity *= 2;
    }
    Vec::new()
}

/// A process's `comm` name and its process group id — `proc_pidinfo(PROC_PIDTBSDINFO)`.
///
/// The two travel together because the caller needs both to decide membership, and reading them in
/// two calls would reopen the race the pair closes: a process that changed group between them.
///
/// The read itself is [`bsd_info`], which carries the obligation.
#[must_use]
pub fn comm_and_group(pid: i32) -> Option<(String, i32)> {
    bsd_info(pid).and_then(|info| {
        let comm = comm_of(&info)?;
        Some((comm, i32::try_from(info.pbi_pgid).ok()?))
    })
}

/// Which terminal a process is attached to, and when it started.
///
/// The two fields the pane census needs off the same `proc_bsdinfo` read: `e_tdev` is the
/// controlling tty's device number, which is how a pane's process set is defined, and
/// `pbi_start_tvsec` is a Unix second the caller turns into an uptime. Asking for them separately
/// would be two `proc_pidinfo` calls per pid over EVERY live process on the machine.
#[must_use]
pub fn tty_and_start(pid: i32) -> Option<(u32, i64)> {
    let info = bsd_info(pid)?;
    Some((info.e_tdev, i64::try_from(info.pbi_start_tvsec).ok()?))
}

/// One `PROC_PIDTBSDINFO` read, which is what every accessor above is a projection of.
///
/// # Safety
/// As documented on [`comm_and_group`]: a live, fully-initialised local of exactly the type whose
/// `size_of` is passed, and a returned byte count required to EQUAL that size before any field is
/// read. Zeroed rather than `MaybeUninit` because `proc_bsdinfo` is a plain C struct of integers
/// and byte arrays with no niches, so all-zero is a valid inhabitant and a short write cannot leave
/// a field holding whatever was on the stack.
#[expect(unsafe_code, reason = "proc_pidinfo has no wrapper in std or nix")]
fn bsd_info(pid: i32) -> Option<libc::proc_bsdinfo> {
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = i32::try_from(size_of::<libc::proc_bsdinfo>()).ok()?;
    let got = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            std::ptr::from_mut(&mut info).cast::<c_void>(),
            size,
        )
    };
    (got == size).then_some(info)
}

/// The `comm` name out of a `proc_bsdinfo`.
///
/// # Safety
/// `pbi_comm` is a NUL-terminated C string in a fixed array and the kernel guarantees the
/// terminator; the slice is built from the array's own pointer and its own length, so it cannot
/// reach past the struct, and `CStr::from_bytes_until_nul` re-checks the terminator rather than
/// trusting it. A name that is not UTF-8 answers `None` rather than being lossily repaired into a
/// name that is a DIFFERENT program.
#[expect(
    unsafe_code,
    reason = "reading a fixed C char array as a string has no safe spelling"
)]
fn comm_of(info: &libc::proc_bsdinfo) -> Option<String> {
    let comm: &[u8] =
        unsafe { std::slice::from_raw_parts(info.pbi_comm.as_ptr().cast::<u8>(), info.pbi_comm.len()) };
    Some(CStr::from_bytes_until_nul(comm).ok()?.to_str().ok()?.to_owned())
}

/// A process's argv — `sysctl(KERN_PROCARGS2)`, size-then-fill.
///
/// The buffer the kernel answers holds `argc` as an `i32`, then the exec path, then padding NULs,
/// then `argc` NUL-separated argument strings, then the environment. Only the arguments are read:
/// the environment of another process is not this probe's business and can hold a secret.
///
/// # Safety
/// Both `sysctl` calls are passed a live MIB slice with its own length, and a size cell they own.
/// The first is a size query (null value pointer, which the call documents as legal and which is
/// what makes the second one correctly sized); the second writes at most the size it is given into
/// a buffer of exactly that size and updates the cell to what it actually wrote. That written size
/// is then clamped to the buffer's own length before any byte is indexed, so a kernel that reported
/// more than it wrote cannot make this read past the allocation.
#[must_use]
#[expect(unsafe_code, reason = "sysctl(KERN_PROCARGS2) has no wrapper in std or nix")]
pub fn process_args(pid: i32) -> Option<Vec<String>> {
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
    let mib_len = u32::try_from(mib.len()).ok()?;
    let mut size = 0_usize;
    let queried = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib_len,
            std::ptr::null_mut(),
            std::ptr::addr_of_mut!(size),
            std::ptr::null_mut(),
            0,
        )
    };
    if queried != 0 || size <= size_of::<i32>() {
        return None;
    }

    let mut buffer = vec![0_u8; size];
    let filled = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib_len,
            buffer.as_mut_ptr().cast::<c_void>(),
            std::ptr::addr_of_mut!(size),
            std::ptr::null_mut(),
            0,
        )
    };
    if filled != 0 {
        return None;
    }
    // The kernel's reported size is trusted only downwards. Everything below indexes `filled` and
    // never `size`, so a report larger than the allocation cannot reach past it.
    let filled = size.min(buffer.len());
    buffer.truncate(filled);
    parse_procargs2(&buffer)
}

/// The `KERN_PROCARGS2` layout, as a pure function over the bytes it answers.
///
/// Split out so the parse — which is where every off-by-one in the Swift original lived — is
/// testable without a live process. The syscall above is the only part that needs one.
fn parse_procargs2(buffer: &[u8]) -> Option<Vec<String>> {
    let (count, rest) = buffer.split_at_checked(size_of::<i32>())?;
    let argc = i32::from_ne_bytes(count.try_into().ok()?);
    // 4096 is not a kernel limit; it is the point past which this is a corrupt read rather than a
    // command line, and reading it as one would allocate against a number the kernel never meant.
    if argc <= 0 || argc >= 4096 {
        return None;
    }

    // Skip the exec path, then its padding NULs. The path is repeated here — argv[0] follows it —
    // so nothing is lost by stepping over it.
    let after_path = rest.iter().position(|byte| *byte == 0)?;
    let start = rest
        .get(after_path..)?
        .iter()
        .position(|byte| *byte != 0)
        .map(|offset| after_path + offset)?;

    let arguments: Vec<String> = rest
        .get(start..)?
        .split(|byte| *byte == 0)
        .take(usize::try_from(argc).ok()?)
        .map(|arg| String::from_utf8_lossy(arg).into_owned())
        .collect();
    (!arguments.is_empty()).then_some(arguments)
}

#[cfg(test)]
// The fixtures here are built inline or read off this very process, so an absent answer IS the
// failure and `expect` is the report.
#[expect(
    clippy::expect_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use super::{
        all_pids, executable_path, parse_procargs2, process_args, process_group_pids, short_name,
        tty_and_start, working_directory,
    };

    /// The all-pids census must at minimum contain the process asking, and must not contain a
    /// non-positive entry — the filter is what keeps a `0` from being read as a pid a later
    /// `proc_pidinfo` would answer for the WHOLE machine's process table.
    #[test]
    fn the_census_finds_this_process_and_nothing_that_is_not_a_pid() {
        let pids = all_pids();
        let own = i32::try_from(std::process::id()).expect("this pid fits");
        assert!(pids.contains(&own), "the census must see the process running it");
        assert!(pids.iter().all(|pid| *pid > 0));
    }

    /// The cwd read is checked against the answer `std` gives for the same process, which is the
    /// only way to tell a correct path from a plausible one.
    #[test]
    fn a_processs_working_directory_is_the_one_it_is_actually_in() {
        let own = i32::try_from(std::process::id()).expect("this pid fits");
        let expected = std::fs::canonicalize(std::env::current_dir().expect("a cwd")).expect("canonical");
        let read = working_directory(own).expect("this process has a cwd");
        assert_eq!(
            std::fs::canonicalize(&read).expect("canonical"),
            expected,
            "the vnode read must answer the directory std reports"
        );
    }

    /// A pid that cannot exist answers nothing from every per-pid reading, rather than an empty
    /// string or a zero a caller would print.
    #[test]
    fn an_impossible_pid_answers_nothing_from_every_reading() {
        assert_eq!(working_directory(0), None);
        assert_eq!(working_directory(-1), None);
        assert_eq!(short_name(i32::MAX), None);
        assert_eq!(tty_and_start(i32::MAX), None);
    }

    /// `proc_name` is the fallback under `proc_pidpath`, so it has to answer for THIS process, and
    /// its answer has to be a prefix of the path's basename — the kernel truncates at 16 bytes.
    #[test]
    fn the_short_name_is_the_truncated_head_of_the_executables_basename() {
        let own = i32::try_from(std::process::id()).expect("this pid fits");
        let short = short_name(own).expect("this process has a comm name");
        let path = executable_path(own).expect("this process has a path");
        let base = path.rsplit('/').next().expect("a basename");
        assert!(!short.is_empty());
        assert!(
            base.starts_with(&short),
            "comm {short:?} must be the head of basename {base:?}"
        );
    }

    /// The start second is a real Unix time, not the zero a failed read would leave behind — the
    /// census subtracts it from now, and a zero would report an uptime of decades.
    #[test]
    fn a_live_process_reports_a_start_time_in_the_past() {
        let own = i32::try_from(std::process::id()).expect("this pid fits");
        let (_tty, start) = tty_and_start(own).expect("this process has bsd info");
        let now = i64::try_from(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("after the epoch")
                .as_secs(),
        )
        .expect("a second that fits");
        assert!(start > 0, "a live process must report when it started");
        assert!(start <= now, "and it cannot have started in the future");
    }

    /// The parse is the half that had every off-by-one in it, so it is tested without a process.
    #[test]
    fn the_exec_path_and_its_padding_are_stepped_over() {
        let mut buffer = 2_i32.to_ne_bytes().to_vec();
        buffer.extend_from_slice(b"/usr/bin/zsh\0\0\0");
        buffer.extend_from_slice(b"-zsh\0--login\0IGNORED=1\0");
        assert_eq!(
            parse_procargs2(&buffer),
            Some(vec!["-zsh".to_owned(), "--login".to_owned()]),
        );
    }

    /// The environment follows argv in the same buffer, and reading past `argc` would leak it.
    #[test]
    fn the_environment_after_argv_is_not_read() {
        let mut buffer = 1_i32.to_ne_bytes().to_vec();
        buffer.extend_from_slice(b"/bin/sh\0");
        buffer.extend_from_slice(b"sh\0AWS_SECRET_ACCESS_KEY=hunter2\0");
        let argv = parse_procargs2(&buffer).expect("one argument");
        assert_eq!(argv, vec!["sh".to_owned()]);
    }

    /// Validate-then-drop: a corrupt count answers nothing rather than allocating against it.
    #[test]
    fn an_argc_outside_a_sane_range_answers_nothing() {
        for argc in [0_i32, -1, 4096, i32::MAX] {
            let mut buffer = argc.to_ne_bytes().to_vec();
            buffer.extend_from_slice(b"/bin/sh\0sh\0");
            assert_eq!(parse_procargs2(&buffer), None, "argc {argc}");
        }
    }

    #[test]
    fn a_buffer_too_short_to_hold_a_count_answers_nothing() {
        assert_eq!(parse_procargs2(&[]), None);
        assert_eq!(parse_procargs2(&[1, 2, 3]), None);
    }

    /// The three syscalls, asked about THIS process — the one pid a test can rely on existing.
    #[test]
    fn this_process_can_be_read_by_its_own_pid() {
        let pid = std::process::id().cast_signed();
        let path = executable_path(pid).expect("this test binary has a path");
        assert!(path.contains('/'), "{path}");
        let argv = process_args(pid).expect("this test binary has argv");
        assert!(!argv.is_empty());
        // The group this process is in must contain this process.
        let group = unsafe_free_process_group();
        assert!(process_group_pids(group).contains(&pid), "group {group}");
    }

    /// `getpgrp` through `nix`, so the test needs no `unsafe` of its own.
    fn unsafe_free_process_group() -> i32 {
        nix::unistd::getpgrp().as_raw()
    }

    /// A pid that cannot exist answers nothing on every call, rather than a default.
    #[test]
    fn an_impossible_pid_answers_nothing_everywhere() {
        let absent = i32::MAX;
        assert_eq!(executable_path(absent), None);
        assert_eq!(process_args(absent), None);
        assert_eq!(super::comm_and_group(absent), None);
        assert!(process_group_pids(absent).is_empty());
    }
}
