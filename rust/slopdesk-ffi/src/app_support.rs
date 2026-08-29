//! The one directory every `SlopDesk` sidecar lands in, and the one variable that moves it.
//!
//! The rule is [`slopdesk_hostlaunch::record::app_support_dir_in`]; what is here is the
//! marshalling, plus the environment read — a system call, and so this side's, exactly as
//! [`crate::config::slopdesk_config_path`] reads `SLOPDESK_CONFIG_FILE` rather than being handed
//! it.
//!
//! ## Why the BASE crosses and the override does not
//!
//! They are answered by opposite sides. The override is an environment variable, which any process
//! can read and which the daemons already read here. The base is Foundation's Application-Support
//! URL, which only the app process can ask for and which `HOME` does not move — Core Foundation
//! resolves the user's home from the account record unless `CFFIXED_USER_HOME` is set. A door that
//! derived the base from `HOME` would hand a redirected client the developer's real container, and
//! the client gates that redirect with `CFFIXED_USER_HOME` would sweep it. So the near side lends
//! the base it alone can resolve, and nothing else about the container is spelled over there.

use core::ffi::c_uchar;
use std::path::Path;

use slopdesk_hostlaunch::record::{APP_SUPPORT_DIR_ENV, app_support_dir_in};

use crate::{borrow, deliver};

/// The container inside `base`, or the one `SLOPDESK_APP_SUPPORT_DIR` names.
///
/// An empty `base` with no override answers nothing (`0`), which is the ABI's `None` and the only
/// reading of "there is nowhere to put the file" that a caller can act on. An empty override reads
/// as unset, so a shell that expanded an unset variable into the environment cannot redirect the
/// container to `/`.
///
/// # Safety
/// `base` must be null or point to that many initialised bytes live for the call; `out` must be
/// null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_app_support_dir(
    base: *const c_uchar,
    base_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation on the base pair.
    let base = String::from_utf8_lossy(unsafe { borrow(base, base_len) }).into_owned();
    let override_dir = std::env::var_os(APP_SUPPORT_DIR_ENV);
    // An empty base is no base: joining the container name onto one would answer a RELATIVE path,
    // which is the one shape a file location must never be. The empty OVERRIDE is not filtered
    // here — reading it as unset is the rule's, one crate down.
    let container = app_support_dir_in(
        (!base.is_empty()).then_some(Path::new(&base)),
        override_dir.as_deref(),
    );
    let answer = container.unwrap_or_default();
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { deliver(answer.as_os_str().as_encoded_bytes(), out, cap) }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::expect_used,
    reason = "calling the boundary IS what these tests are for, and a panic in one is its report"
)]
mod tests {
    use std::path::{Path, PathBuf};

    use slopdesk_hostlaunch::record::APP_SUPPORT_DIR_ENV;

    use super::slopdesk_app_support_dir;
    use crate::testing::delivered;

    /// The container this test process would be handed for a given base.
    fn container(base: &str) -> String {
        // SAFETY: the base is a live borrow for the call, and `delivered` lends a buffer it owns.
        String::from_utf8(delivered(|out, cap| unsafe {
            slopdesk_app_support_dir(base.as_ptr(), base.len(), out, cap)
        }))
        .expect("the door answers UTF-8 for a UTF-8 base")
    }

    /// The rule applied through the door, under whichever condition this process is running in: a
    /// redirected run answers the redirect verbatim, an unredirected one answers the container
    /// inside the lent base. Both branches are asserted by the pure test in `slopdesk-hostlaunch`;
    /// what is asserted HERE is that the door consults the environment at all.
    #[test]
    fn the_lent_base_holds_the_container_unless_the_environment_moved_it() {
        let base = "/Users/nobody/Library/Application Support";
        let expected = match std::env::var_os(APP_SUPPORT_DIR_ENV) {
            Some(dir) if !dir.is_empty() => PathBuf::from(dir),
            _ => Path::new(base).join("SlopDesk"),
        };
        assert_eq!(container(base), expected.to_string_lossy());
    }

    /// No base and no override is no container — the ABI's `None`, not a path rooted at `/`.
    #[test]
    fn nowhere_to_put_it_answers_nothing() {
        if std::env::var_os(APP_SUPPORT_DIR_ENV).is_some_and(|dir| !dir.is_empty()) {
            return; // a redirected run has somewhere to put it, and says so.
        }
        assert_eq!(container(""), "");
    }

    /// An overflow reports the size it needs and leaves the caller's buffer alone.
    #[test]
    fn an_overflow_reports_the_size_it_needs_and_writes_nothing() {
        let base = "/Users/nobody/Library/Application Support";
        let mut tiny = [0xAA_u8; 2];
        // SAFETY: both buffers are live locals for the duration of the call.
        let needed =
            unsafe { slopdesk_app_support_dir(base.as_ptr(), base.len(), tiny.as_mut_ptr(), tiny.len()) };
        assert!(needed > tiny.len(), "{needed}");
        assert_eq!(tiny, [0xAA; 2], "an overflow leaves the caller's buffer alone");
    }
}
