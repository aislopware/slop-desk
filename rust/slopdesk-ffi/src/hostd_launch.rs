//! hostd's command line and its launch record, in C.
//!
//! macOS only, gated in `lib.rs`: both halves are about the daemon this process IS, and no client
//! asks either of them. The one fact here a client DOES need — the port to dial when nobody said
//! otherwise — lives in [`crate::listen_port`] instead, which is not gated.
//!
//! ## What crossed, and what stayed
//! Everything. `HostdArguments.swift` and `HostLaunchRecord.swift` are deleted, and the Rust side
//! is not a mirror of them: `slopdesk-devtools` had a HAND-WRITTEN reader for the same eight
//! fields, so the record was one document spelled twice in two languages. Both readers are now
//! `slopdesk_hostlaunch::record`.
//!
//! ## Why the write door takes two arguments and not eight
//! The pid, the argv, the cwd, the environment and the executable are the PROCESS's answers, and
//! the process here is the same one on both sides of the boundary — so Rust asks it directly rather
//! than having Swift marshal six values across. What Swift still supplies is the two facts the
//! daemon alone knows: the port its listener actually BOUND (`--port 0` mints one that differs from
//! the request) and its build version. See `slopdesk_hostlaunch::record` for the whole argument.

use core::ffi::c_uchar;

use slopdesk_hostlaunch::{args, record};

use crate::{borrow, deliver, push_text};

/// Parse hostd's argv into a blob, or refuse.
///
/// `argv` is the whole command line INCLUDING `argv[0]`, NUL-separated. That framing is lossless by
/// construction — an `execve` argument cannot contain a NUL — and it is the shortest thing that
/// carries an argument holding a space, a quote or a newline without an escaping convention nobody
/// would test.
///
/// The delivery is `docs/55` §4's `(out, cap) -> needed`, with ONE deviation stated here rather
/// than assumed, the way [`crate::listen_port`] states its own: the first byte is a STATUS, `1` for
/// a parse and `0` for a refusal, because a refusal is a real answer and `needed == 0` already
/// means "no answer at all". A refusal therefore delivers exactly one byte. After the status:
///
/// ```text
/// port: u16 big-endian | inspector: u8 | text shell | text transcript
/// ```
///
/// where each `text` is `push_text`'s four-byte big-endian length and that many UTF-8 bytes, and an
/// EMPTY one means the flag was absent — neither `--shell` nor `--transcript` accepts an empty
/// value, so there is nothing for the emptiness to collide with.
///
/// A refusal is `--help`, `-h`, a flag with no value, a `--port` that is not a port, or a flag this
/// daemon does not have. The caller prints [`slopdesk_hostd_args_usage`] and exits non-zero.
///
/// # Safety
/// `argv` must be non-null and readable for `argv_len` bytes, and `out` writable for `cap`, for the
/// duration of this call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and two caller-supplied buffers"
)]
pub unsafe extern "C" fn slopdesk_hostd_args_parse(
    argv: *const c_uchar,
    argv_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above is `borrow`'s.
    let joined = String::from_utf8_lossy(unsafe { borrow(argv, argv_len) }).into_owned();
    let words: Vec<String> = joined.split('\0').map(str::to_owned).collect();

    let mut blob = Vec::with_capacity(32);
    match args::parse(&words) {
        None => blob.push(0),
        Some(parsed) => {
            blob.push(1);
            blob.extend_from_slice(&parsed.port.to_be_bytes());
            blob.push(u8::from(parsed.inspector_enabled));
            push_text(&mut blob, parsed.shell.as_deref().unwrap_or_default());
            push_text(&mut blob, parsed.transcript_path.as_deref().unwrap_or_default());
        },
    }
    // SAFETY: the caller's obligation above is `deliver`'s.
    unsafe { deliver(&blob, out, cap) }
}

/// The usage line for `program`, as `--help` and a parse refusal both print it.
///
/// Rendered here rather than in Swift because the flag list IS the grammar: a usage string that
/// documents a flag the parser no longer accepts is the drift this door exists to make impossible.
///
/// # Safety
/// `program` must be non-null and readable for `program_len` bytes, and `out` writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and two caller-supplied buffers"
)]
pub unsafe extern "C" fn slopdesk_hostd_args_usage(
    program: *const c_uchar,
    program_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above is `borrow`'s.
    let name = String::from_utf8_lossy(unsafe { borrow(program, program_len) }).into_owned();
    // SAFETY: the caller's obligation above is `deliver`'s.
    unsafe { deliver(args::usage(&name).as_bytes(), out, cap) }
}

/// Publish this process's launch record, given the bound port and the build version.
///
/// `false` when there is no container to write into or the write failed. Best-effort by design: a
/// host that cannot publish this file still serves every client, and the only thing lost is that
/// `slopdesk-ops restart-hostd` falls back to asking.
///
/// # Safety
/// `version` must be non-null and readable for `version_len` bytes for the duration of this call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and one caller-supplied buffer"
)]
pub unsafe extern "C" fn slopdesk_hostd_launch_record_write(
    bound_port: u16,
    version: *const c_uchar,
    version_len: usize,
) -> bool {
    // SAFETY: the caller's obligation above is `borrow`'s.
    let version = String::from_utf8_lossy(unsafe { borrow(version, version_len) }).into_owned();
    record::path().is_some_and(|path| record::current(bound_port, &version).write(&path))
}

/// Where the record lives, for the line the daemon logs about it.
///
/// `docs/55` §4's `(out, cap) -> needed`, undeviated: zero means there is no container to resolve,
/// which is the same "no answer" every other length-answering door means by it.
///
/// # Safety
/// `out` must be writable for `cap` bytes for the duration of this call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and one caller-supplied buffer"
)]
pub unsafe extern "C" fn slopdesk_hostd_launch_record_path(out: *mut c_uchar, cap: usize) -> usize {
    let Some(path) = record::path() else { return 0 };
    // SAFETY: the caller's obligation above is `deliver`'s.
    unsafe { deliver(path.as_os_str().as_encoded_bytes(), out, cap) }
}

/// Delete the record, on the orderly shutdown.
///
/// Deliberately before the drain rather than after: from that point this daemon will not serve, and
/// a record naming a dying pid is worse than none. Its ABSENCE is meaningful — a record whose pid
/// is gone means hostd died badly, which is worth telling apart from a clean stop.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point even where the body is safe"
)]
pub extern "C" fn slopdesk_hostd_launch_record_remove() {
    if let Some(path) = record::path() {
        record::remove(&path);
    }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::expect_used,
    clippy::indexing_slicing,
    reason = "calling the door IS what these tests are for, and a fixed offset into a blob the door just \
              wrote is the assertion — a panic there is the failure report"
)]
mod tests {
    use slopdesk_hostlaunch::args;

    use super::{slopdesk_hostd_args_parse, slopdesk_hostd_args_usage, slopdesk_hostd_launch_record_path};

    /// The far side's read of the blob, so the door is tested through the shape Swift actually
    /// decodes rather than through the Rust values behind it.
    #[derive(Debug, PartialEq, Eq)]
    struct Parsed {
        port: u16,
        inspector: bool,
        shell: String,
        transcript: String,
    }

    /// Cut one `push_text` field off the front.
    fn take_text(blob: &[u8], at: &mut usize) -> String {
        let length = u32::from_be_bytes(blob[*at..*at + 4].try_into().expect("a length prefix"));
        *at += 4;
        let length = usize::try_from(length).expect("a length that fits");
        let text = String::from_utf8_lossy(&blob[*at..*at + length]).into_owned();
        *at += length;
        text
    }

    /// Drive the door the way Swift does: NUL-join, ask for the size, then ask again with a buffer.
    fn parse(words: &[&str]) -> Option<Parsed> {
        let joined = words.join("\0");
        let bytes = joined.as_bytes();
        // SAFETY: both pointers are into live locals, and the null buffer is the documented probe.
        let needed =
            unsafe { slopdesk_hostd_args_parse(bytes.as_ptr(), bytes.len(), std::ptr::null_mut(), 0) };
        let mut blob = vec![0_u8; needed];
        // SAFETY: `blob` is live and exactly `needed` bytes long.
        let written =
            unsafe { slopdesk_hostd_args_parse(bytes.as_ptr(), bytes.len(), blob.as_mut_ptr(), blob.len()) };
        assert_eq!(written, needed, "the two-call protocol disagreed with itself");

        if blob[0] == 0 {
            assert_eq!(blob.len(), 1, "a refusal carries nothing but the status");
            return None;
        }
        let port = u16::from_be_bytes(blob[1..3].try_into().expect("a port"));
        let inspector = blob[3] != 0;
        let mut at = 4;
        let shell = take_text(&blob, &mut at);
        let transcript = take_text(&blob, &mut at);
        assert_eq!(at, blob.len(), "the blob had bytes nobody claimed");
        Some(Parsed {
            port,
            inspector,
            shell,
            transcript,
        })
    }

    /// A bare invocation, and the full line, decoded field for field off the wire shape.
    #[test]
    fn the_blob_carries_every_field_the_far_side_reads() {
        assert_eq!(
            parse(&["slopdesk-hostd"]),
            Some(Parsed {
                port: args::DEFAULT_PORT,
                inspector: false,
                shell: String::new(),
                transcript: String::new(),
            })
        );

        assert_eq!(
            parse(&[
                "slopdesk-hostd",
                "--port",
                "9001",
                "--shell",
                "/bin/bash",
                "--transcript",
                "/tmp/s.jsonl"
            ]),
            Some(Parsed {
                port: 9001,
                inspector: true,
                shell: "/bin/bash".to_owned(),
                transcript: "/tmp/s.jsonl".to_owned(),
            })
        );
    }

    /// An argument holding a space survives the NUL framing — the case an argv joined on
    /// whitespace would split in half.
    #[test]
    fn an_argument_with_a_space_survives_the_framing() {
        let parsed = parse(&["slopdesk-hostd", "--shell", "/opt/My Shells/zsh"]).expect("a parse");
        assert_eq!(parsed.shell, "/opt/My Shells/zsh");
    }

    /// A refusal is one byte, and every documented refusal reaches it.
    #[test]
    fn every_refusal_is_one_status_byte() {
        for line in [
            vec!["slopdesk-hostd", "--help"],
            vec!["slopdesk-hostd", "-h"],
            vec!["slopdesk-hostd", "--port"],
            vec!["slopdesk-hostd", "--port", "65536"],
            vec!["slopdesk-hostd", "--claude"],
        ] {
            assert_eq!(parse(&line), None, "{line:?} was not refused");
        }
    }

    /// The usage line names the program it was handed and every flag the parser accepts, so the two
    /// cannot drift.
    #[test]
    fn the_usage_door_renders_the_program_it_is_given() {
        let name = b"slopdesk-hostd";
        // SAFETY: the name is a live local and the null buffer is the documented probe.
        let needed = unsafe { slopdesk_hostd_args_usage(name.as_ptr(), name.len(), std::ptr::null_mut(), 0) };
        let mut out = vec![0_u8; needed];
        // SAFETY: `out` is live and exactly `needed` bytes long.
        let written =
            unsafe { slopdesk_hostd_args_usage(name.as_ptr(), name.len(), out.as_mut_ptr(), out.len()) };
        assert_eq!(written, needed);
        let text = String::from_utf8(out).expect("the usage line is UTF-8");
        assert_eq!(text, args::usage("slopdesk-hostd"));
        assert!(text.contains("--transcript"));
    }

    /// The path door answers the same file the record module resolves, and the two-call protocol
    /// agrees with itself on it.
    #[test]
    fn the_path_door_answers_the_record_file() {
        // SAFETY: the null buffer is the documented probe.
        let needed = unsafe { slopdesk_hostd_launch_record_path(std::ptr::null_mut(), 0) };
        assert!(needed > 0, "there is always a container on a machine with a HOME");
        let mut out = vec![0_u8; needed];
        // SAFETY: `out` is live and exactly `needed` bytes long.
        let written = unsafe { slopdesk_hostd_launch_record_path(out.as_mut_ptr(), out.len()) };
        assert_eq!(written, needed);
        assert!(
            String::from_utf8_lossy(&out).ends_with("hostd-launch.json"),
            "{:?}",
            String::from_utf8_lossy(&out)
        );
    }

    /// A buffer that is too small writes NOTHING and still reports the size, which is what makes
    /// the two-call protocol safe to retry.
    #[test]
    fn a_short_buffer_is_refused_rather_than_truncated() {
        let joined = "slopdesk-hostd\0--shell\0/bin/zsh";
        let bytes = joined.as_bytes();
        let mut out = [0xAA_u8; 4];
        // SAFETY: `out` is live and its declared length is honest.
        let needed =
            unsafe { slopdesk_hostd_args_parse(bytes.as_ptr(), bytes.len(), out.as_mut_ptr(), out.len()) };
        assert!(needed > out.len());
        assert_eq!(out, [0xAA; 4], "a short delivery scribbled on the buffer");
    }
}
