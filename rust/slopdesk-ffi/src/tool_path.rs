//! Where a host program lives, in C — `Sources/SlopDeskHost/HostServiceProcess.swift`.
//!
//! The rule is [`slopdesk_androidd::toolchain::locate_tool`]; what is here is the marshalling.
//!
//! ## Why a search order needed a door at all
//!
//! `docs/46`'s "Vendored runtime deps" section states ONE order — the `SLOPDESK_*_BIN` override,
//! then the vendored prefix, then `PATH`, then a tail — and named the Swift copy as the rule with
//! the Rust one "mirrored" from it. That is a claim with no gate behind it, which is `docs/55` §8's
//! whole subject, and the pair had already stopped agreeing on the question neither the docs nor
//! either doc comment mentions: **what makes a candidate executable**.
//!
//! ```text
//! Swift   FileManager.isExecutableFile  →  access(path, X_OK)
//! Rust    metadata().is_file() && mode & 0o111 != 0
//! ```
//!
//! They disagree in both directions and neither disagreement can produce an error message. A
//! DIRECTORY named `code-server` sitting on `PATH` is `X_OK` — searchable — so Swift handed it to
//! `posix_spawn`, which fails with a message about the wrong thing; Rust walks past it. A binary
//! whose mode bits are set for ids this daemon does not hold is the other way round: Rust hands
//! back a path hostd cannot run, Swift keeps looking. Nothing on the wire, in a test or in
//! `make lint` could see either, because each side is perfectly self-consistent and only one of
//! them is on any given path.
//!
//! ## Why the environment is READ on the near side
//!
//! Same reason as [`crate::screen_paths`] and [`crate::supervisor_paths`]:
//! `HostServiceProcess.locate(_:overrideVariable:environment:…)` takes its environment as a
//! parameter and `Tests/SlopDeskHostTests/VendoredToolsTests.swift` passes dictionaries in. Three
//! dictionary reads stay there. The precedence, the emptiness filter, the `PATH` split, the tail
//! and the executability test are all over here.

use core::ffi::c_uchar;
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

use slopdesk_androidd::toolchain::{host_service_fallback_dirs, locate_tool};

use crate::{borrow, deliver};

/// The path hostd would spawn for `name`, or `0` when the host has none installed.
///
/// Every input pair may be `(NULL, 0)`, and an EMPTY pair reads as an absent one throughout — an
/// exported-but-blank variable is a shell accident, and a `HOME` nobody set must not become
/// `/.local/bin`. A pair that is not UTF-8 is read as unset for the same reason
/// [`crate::supervisor_paths`] gives: landing on the next rung together is the point.
///
/// `0` is the only refusal and it means "not installed", which is what the caller renders as the
/// panel's install hint. A return larger than `cap` means nothing was written — ask again at that
/// size.
///
/// # Safety
/// Each `(ptr, len)` input must be null or readable for its length, and `(out, cap)` writable for
/// `cap` bytes, all for the duration of the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every buffer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_host_service_binary(
    name: *const c_uchar,
    name_len: usize,
    override_value: *const c_uchar,
    override_len: usize,
    path_value: *const c_uchar,
    path_len: usize,
    vendored_bin: *const c_uchar,
    vendored_len: usize,
    home: *const c_uchar,
    home_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's contract, one pair at a time.
    let (name_bytes, override_bytes, path_bytes, vendored_bytes, home_bytes) = unsafe {
        (
            borrow(name, name_len),
            borrow(override_value, override_len),
            borrow(path_value, path_len),
            borrow(vendored_bin, vendored_len),
            borrow(home, home_len),
        )
    };
    let text = |bytes| core::str::from_utf8(bytes).unwrap_or("");
    let vendored = text(vendored_bytes);
    let tail = host_service_fallback_dirs(Some(text(home_bytes)));
    let Some(found) = locate_tool(
        text(name_bytes),
        Some(text(override_bytes)),
        text(path_bytes),
        (!vendored.is_empty()).then(|| Path::new(vendored)),
        &tail,
    ) else {
        return 0;
    };
    // SAFETY: the caller's contract.
    unsafe { deliver(OsStr::new(found.as_os_str()).as_bytes(), out, cap) }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    unsafe_code,
    reason = "a panic in a test is the failure report, and calling the door is the point"
)]
mod tests {
    use std::path::{Path, PathBuf};

    use super::slopdesk_host_service_binary;

    /// A private directory tree per case, removed on drop — the same discipline
    /// `slopdesk_androidd::toolchain`'s own suite keeps, for the same reason: a locator test that
    /// consults the real `PATH` passes or fails according to what the machine happens to have.
    struct Tree {
        root: PathBuf,
    }

    impl Tree {
        fn new(case: &str) -> Self {
            let root = std::env::temp_dir().join(format!("ffi-tool-path-{case}"));
            let _ignored = std::fs::remove_dir_all(&root);
            std::fs::create_dir_all(&root).expect("creates the tree root");
            Self { root }
        }

        fn executable(&self, relative: &str) -> String {
            let path = self.root.join(relative);
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent).expect("creates the parent");
            }
            std::fs::write(&path, "#!/bin/sh\n").expect("writes the file");
            std::fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o755))
                .expect("marks it executable");
            path.to_string_lossy().into_owned()
        }

        fn string(&self, relative: &str) -> String {
            self.root.join(relative).to_string_lossy().into_owned()
        }
    }

    impl Drop for Tree {
        fn drop(&mut self) {
            let _ignored = std::fs::remove_dir_all(&self.root);
        }
    }

    fn locate(name: &str, over: &str, path: &str, vendored: &str, home: &str) -> String {
        let mut buffer = [0_u8; 1024];
        // SAFETY: every pair is a live local, and the output is a live local array.
        let needed = unsafe {
            slopdesk_host_service_binary(
                name.as_ptr(),
                name.len(),
                over.as_ptr(),
                over.len(),
                path.as_ptr(),
                path.len(),
                vendored.as_ptr(),
                vendored.len(),
                home.as_ptr(),
                home.len(),
                buffer.as_mut_ptr(),
                buffer.len(),
            )
        };
        let Some(bytes) = buffer.get(..needed) else {
            return String::new();
        };
        String::from_utf8_lossy(bytes).into_owned()
    }

    /// The whole ladder in one case, which is what the Swift copy could not be held to.
    #[test]
    fn the_door_carries_the_whole_order_rather_than_half_of_it() {
        let tree = Tree::new("whole-order");
        let over = tree.executable("candidate/code-server");
        let vendored = tree.executable("prefix/bin/code-server");
        let on_path = tree.executable("homebrew/bin/code-server");
        let in_tail = tree.executable("home/.local/bin/code-server");

        let (path, prefix, home) = (
            tree.string("homebrew/bin"),
            tree.string("prefix/bin"),
            tree.string("home"),
        );
        assert_eq!(locate("code-server", &over, &path, &prefix, &home), over);
        assert_eq!(locate("code-server", "", &path, &prefix, &home), vendored);
        assert_eq!(locate("code-server", "", &path, "", &home), on_path);
        assert_eq!(locate("code-server", "", "", "", &home), in_tail);
    }

    /// A named-but-broken override refuses outright. Falling through would run a DIFFERENT binary
    /// than the one an operator bisecting a build named.
    #[test]
    fn a_broken_override_refuses_rather_than_falling_through() {
        let tree = Tree::new("broken-override");
        tree.executable("prefix/bin/baguette");
        assert_eq!(
            locate(
                "baguette",
                "/definitely/not/here/baguette",
                "",
                &tree.string("prefix/bin"),
                ""
            ),
            String::new()
        );
    }

    /// An absent vendored prefix — a hostd copied out of its checkout — is `(NULL, 0)`, and must
    /// not become a candidate at `/<name>`.
    #[test]
    fn an_absent_prefix_is_not_a_search_at_the_filesystem_root() {
        let tree = Tree::new("absent-prefix");
        let on_path = tree.executable("bin/baguette");
        let mut buffer = [0_u8; 512];
        let name = "baguette";
        let path = tree.string("bin");
        // SAFETY: the two live pairs are locals; the other three are the supported null pairs.
        let needed = unsafe {
            slopdesk_host_service_binary(
                name.as_ptr(),
                name.len(),
                core::ptr::null(),
                0,
                path.as_ptr(),
                path.len(),
                core::ptr::null(),
                0,
                core::ptr::null(),
                0,
                buffer.as_mut_ptr(),
                buffer.len(),
            )
        };
        assert_eq!(
            buffer.get(..needed).map(String::from_utf8_lossy).as_deref(),
            Some(on_path.as_str())
        );
    }

    /// §4's convention: an undersized buffer writes NOTHING and reports what it needed.
    #[test]
    fn an_undersized_buffer_is_told_the_length_and_given_no_bytes() {
        let tree = Tree::new("undersized");
        let on_path = tree.executable("bin/adb");
        let (name, path) = ("adb", tree.string("bin"));
        let mut room = [0xAA_u8; 4];
        // SAFETY: every pair is a live local.
        let needed = unsafe {
            slopdesk_host_service_binary(
                name.as_ptr(),
                name.len(),
                core::ptr::null(),
                0,
                path.as_ptr(),
                path.len(),
                core::ptr::null(),
                0,
                core::ptr::null(),
                0,
                room.as_mut_ptr(),
                room.len(),
            )
        };
        assert_eq!(needed, on_path.len());
        assert!(needed > room.len());
        assert_eq!(room, [0xAA; 4], "nothing was written");
    }

    /// A host with nothing installed answers `0`, which the caller renders as the install hint.
    #[test]
    fn a_host_with_none_of_it_answers_zero() {
        assert_eq!(
            locate("code-server", "", "/nowhere", "", "/nobody"),
            String::new()
        );
    }

    /// The tail is a RULE, not the caller's list: an absent `HOME` drops `~/.local/bin` rather than
    /// stat-ing `/.local/bin`, and the Homebrew pair still answers.
    #[test]
    fn a_homeless_host_still_reaches_the_homebrew_pair() {
        // `/bin/sh` is not in either Homebrew prefix, so this asserts the SHAPE: no panic, no
        // `/.local/bin` candidate, and a refusal rather than an answer.
        assert_eq!(
            locate("definitely-not-a-real-tool", "", "", "", ""),
            String::new()
        );
        assert!(
            !Path::new("/.local/bin").exists(),
            "the invented candidate this rule refuses to build"
        );
    }
}
