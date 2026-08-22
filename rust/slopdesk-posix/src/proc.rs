//! Reading another process: its executable path, its process group's members, its `comm` name and
//! its argv.
//!
//! Four Darwin calls with no wrapper in `std` or `nix` — `proc_pidpath`, `proc_listpids`,
//! `proc_pidinfo` and `sysctl(KERN_PROCARGS2)` — each of which fills a caller-provided buffer and
//! reports how much of it it used. That is the shape this crate exists for: the obligation is
//! entirely local (is the buffer as big as I said, is the reported length inside it) and can be
//! discharged without naming anything above the syscall.
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
/// # Safety
/// `proc_pidinfo` fills the struct whose size it is told, and answers the number of bytes it wrote.
/// The pointer is to a live, fully-initialised local of exactly that type, the size passed is that
/// type's own `size_of`, and the answer is required to EQUAL that size before any field is read —
/// a short write means the kernel refused, and every field is then left at its zeroed value.
#[must_use]
#[expect(unsafe_code, reason = "proc_pidinfo has no wrapper in std or nix")]
pub fn comm_and_group(pid: i32) -> Option<(String, i32)> {
    // Zeroed rather than `MaybeUninit`: `proc_bsdinfo` is a plain C struct of integers and byte
    // arrays with no niches, so all-zero is a valid inhabitant, and starting from one means a short
    // write cannot leave a field holding whatever was on the stack.
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
    if got != size {
        return None;
    }
    // `pbi_comm` is a NUL-terminated C string in a fixed array, and the kernel guarantees the
    // terminator; `CStr::from_bytes_until_nul` re-checks rather than trusting it, and a name that
    // is not UTF-8 answers `None` rather than being lossily repaired into a different name.
    let comm: &[u8] =
        unsafe { std::slice::from_raw_parts(info.pbi_comm.as_ptr().cast::<u8>(), info.pbi_comm.len()) };
    let name = CStr::from_bytes_until_nul(comm).ok()?.to_str().ok()?;
    Some((name.to_owned(), i32::try_from(info.pbi_pgid).ok()?))
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
    use super::{executable_path, parse_procargs2, process_args, process_group_pids};

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
