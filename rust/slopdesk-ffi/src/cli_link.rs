//! Installing the `slopdesk` command, as one door.
//!
//! macOS only, and not because of a framework: iOS has no `PATH` and no place to put a command, so
//! the question does not arise on the phone at all.
//!
//! The split is the smallest one that could work. `Bundle.main` is the only thing on either side of
//! this boundary that knows where this app's own executable lives, and no crate can derive it — so
//! the shell resolves the source path and lends it, and everything after that (where the link goes,
//! whether one is already there, whose it is, and the `symlink` itself) is
//! [`slopdesk_clilink`]'s. What crosses is one path in and one verdict out.

use core::ffi::c_uchar;
use std::path::Path;

use slopdesk_clilink::{Outcome, link};

use crate::borrow;

/// The link already pointed at the bundled command; nothing was touched.
pub const SLOPDESK_CLI_LINK_ALREADY: u8 = 0;
/// The link was made, or re-aimed from a bundle that had moved.
pub const SLOPDESK_CLI_LINK_MADE: u8 = 1;
/// A regular file somebody else owns sits at the destination and was left exactly as it was.
pub const SLOPDESK_CLI_LINK_OCCUPIED: u8 = 2;
/// The link could not be made. The command is not on `PATH`, and nothing else follows.
pub const SLOPDESK_CLI_LINK_FAILED: u8 = 3;

/// Links the bundled command at `source` into `home`'s own bin directory.
///
/// A verdict rather than a bool, because the three ways it can end without linking are three
/// different facts about the machine and a caller that wanted to say so would otherwise have to ask
/// twice. Nothing today reads more than [`SLOPDESK_CLI_LINK_OCCUPIED`] apart from "is it there",
/// which is what the two `*_ALREADY`/`*_MADE` codes answer between them.
///
/// # Safety
/// `home` must be null or point to `home_len` initialised bytes, `source` null or `source_len`,
/// both live for the call. A run that is not UTF-8 reads as empty, which links nothing.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_cli_link(
    home: *const c_uchar,
    home_len: usize,
    source: *const c_uchar,
    source_len: usize,
) -> u8 {
    // SAFETY: the caller's obligations, restated above; `borrow` answers empty for a null.
    let (home, source) = unsafe {
        (
            core::str::from_utf8(borrow(home, home_len)).unwrap_or_default(),
            core::str::from_utf8(borrow(source, source_len)).unwrap_or_default(),
        )
    };
    if home.is_empty() || source.is_empty() {
        return SLOPDESK_CLI_LINK_FAILED;
    }
    match link(Path::new(home), Path::new(source)) {
        Outcome::AlreadyLinked => SLOPDESK_CLI_LINK_ALREADY,
        Outcome::Linked => SLOPDESK_CLI_LINK_MADE,
        Outcome::Occupied => SLOPDESK_CLI_LINK_OCCUPIED,
        Outcome::Failed => SLOPDESK_CLI_LINK_FAILED,
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        unsafe_code,
        clippy::expect_used,
        reason = "calling the door is the only way to test the door, and a panic in a test is the failure \
                  report"
    )]

    use std::fs;
    use std::os::unix::fs::PermissionsExt as _;

    use super::{
        SLOPDESK_CLI_LINK_ALREADY, SLOPDESK_CLI_LINK_FAILED, SLOPDESK_CLI_LINK_MADE, slopdesk_cli_link,
    };

    /// The door, asked the way the shell asks it.
    fn linked(home: &str, source: &str) -> u8 {
        // SAFETY: both runs live for the call.
        unsafe { slopdesk_cli_link(home.as_ptr(), home.len(), source.as_ptr(), source.len()) }
    }

    #[test]
    fn a_launch_links_once_and_then_finds_its_own_link() {
        let root = std::env::temp_dir().join(format!("slopdesk-ffi-clilink-{}", std::process::id()));
        drop(fs::remove_dir_all(&root));
        fs::create_dir_all(&root).expect("a temp tree");
        let source = root.join("slopdesk");
        fs::write(&source, b"#!/bin/sh\n").expect("a command");
        fs::set_permissions(&source, fs::Permissions::from_mode(0o755)).expect("its mode");

        let home = root.join("home");
        let (home, source) = (
            home.to_string_lossy().into_owned(),
            source.to_string_lossy().into_owned(),
        );
        assert_eq!(linked(&home, &source), SLOPDESK_CLI_LINK_MADE);
        assert_eq!(linked(&home, &source), SLOPDESK_CLI_LINK_ALREADY);

        drop(fs::remove_dir_all(&root));
    }

    /// An empty run on either side is a caller that has no answer, not a caller asking to link `/`.
    #[test]
    fn an_empty_path_links_nothing() {
        assert_eq!(linked("", "/bin/sh"), SLOPDESK_CLI_LINK_FAILED);
        assert_eq!(linked("/tmp", ""), SLOPDESK_CLI_LINK_FAILED);
        // SAFETY: a null run with a zero length is exactly what `borrow` answers empty for.
        let none = unsafe { slopdesk_cli_link(core::ptr::null(), 0, core::ptr::null(), 0) };
        assert_eq!(none, SLOPDESK_CLI_LINK_FAILED);
    }
}
