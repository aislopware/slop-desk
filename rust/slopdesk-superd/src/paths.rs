//! Where superd's sockets live, and why none of these paths contain a pid.
//!
//! Every other `AF_UNIX` socket in this daemon is keyed by `getpid()` so concurrent hosts do not
//! collide. That was right when the socket's owner and the process baking the path into a child's
//! environment were the same, short-lived thing. They are not any more, and a pid in the path is
//! now precisely the bug: a restarted hostd binds a *different* path while a running `claude`
//! still holds the old one in its environment, so its hook POSTs go to a socket nobody is
//! listening on (`docs/51` §1).
//!
//! **Only ONE of these names is spelled on the Swift side, and that is the design.** hostd has to
//! *find* the control socket before it can say `hello`, so that one address cannot be learned from
//! the thing it addresses and `SupervisorPaths.swift` carries it too — a divergence in it is not a
//! protocol error, it is silence. The other three are superd's alone: hostd is TOLD the hook and
//! agent-control paths in the `hello` reply, and the lock file is none of its business. A Swift
//! constant for any of them would be a second answer to "where is the hook socket", which is the
//! drift that pid-keyed paths caused once. `rust/slopdesk-invariants` pins both halves of that:
//! the shared name equal, the other three absent from `Sources/`.

use std::env;
use std::path::{Path, PathBuf};

/// The launchd job label. Also the lock-file stem.
pub const LAUNCH_AGENT_LABEL: &str = "com.slopdesk.superd";

// The two override keys and the control socket's name are `slopdesk_superwire`'s, re-exported here
// so this module still reads as the list of superd's paths. They moved for the reason the framing
// did: hostd must resolve this one address before it can say `hello`, so it cannot be told, and it
// was answering the question with a rule of its own that disagreed on `$TMPDIR` and had never heard
// of `SLOPDESK_SUPERD_DIR`. The other three names below stay here, because hostd is TOLD them.
pub use slopdesk_superwire::{DIRECTORY_ENV_KEY, SOCKET_ENV_KEY};

/// The usable length of `sockaddr_un.sun_path` on Darwin.
///
/// The field is 104 bytes and `bind(2)` truncates silently rather than failing — a path one byte
/// too long binds successfully at the WRONG name. Every bind and connect checks this first.
pub const MAX_SOCKET_PATH_BYTES: usize = 103;

/// Every path superd owns, resolved once at startup.
///
/// Resolved once, and passed down, rather than read from the environment on each call: the
/// environment is process-global mutable state, and a daemon that answers "where is the hook
/// socket?" differently at minute 40 than it did at minute 0 would hand two children two different
/// answers — which is the original bug wearing a different hat.
#[derive(Debug, Clone)]
pub struct Paths {
    /// superd's control socket — the one hostd connects to.
    pub control: PathBuf,
    /// The stable agent-hook socket, advertised to children as `SLOPDESK_SOCKET_PATH` — while a
    /// hostd is serving it. See [`crate::listeners::Claims`].
    pub hook: PathBuf,
    /// The stable agent-control socket, advertised to children as `SLOPDESK_CONTROL_SOCKET` —
    /// same rule, same place.
    pub control_agent: PathBuf,
    /// The `flock`ed single-instance lock.
    pub lock: PathBuf,
}

impl Paths {
    /// The path for one [`crate::protocol::listener_kind`], or `None` for a kind superd has none
    /// of.
    ///
    /// Knowing a path is not serving it, and that distinction is the load-bearing part: handing a
    /// child a name superd merely knows is how every spawned agent once got an address with nothing
    /// behind it. So the *serving* half of the question lives in [`crate::listeners::Claims`], and
    /// both halves have to answer yes before a path reaches a child's environment.
    #[must_use]
    pub fn for_kind(&self, kind: &str) -> Option<&PathBuf> {
        match kind {
            crate::protocol::listener_kind::HOOK => Some(&self.hook),
            crate::protocol::listener_kind::CONTROL => Some(&self.control_agent),
            _unknown => None,
        }
    }

    /// Resolves from the real process environment.
    #[must_use]
    pub fn from_process_env() -> Self {
        let directory = env::var(DIRECTORY_ENV_KEY).ok().filter(|value| !value.is_empty());
        let socket = env::var(SOCKET_ENV_KEY).ok().filter(|value| !value.is_empty());
        let tmpdir = env::var("TMPDIR").ok().filter(|value| !value.is_empty());
        Self::resolve(directory.as_deref(), socket.as_deref(), tmpdir.as_deref())
    }

    /// The pure core, so the rules are testable without mutating the process environment.
    ///
    /// `$TMPDIR` on macOS is already a per-user, `0700` directory, which is what makes the
    /// un-suffixed socket names safe. `/tmp` would not be — the fallback exists only so a
    /// hand-run superd in a stripped environment fails somewhere legible.
    #[must_use]
    pub fn resolve(directory: Option<&str>, socket: Option<&str>, tmpdir: Option<&str>) -> Self {
        let base = PathBuf::from(directory.or(tmpdir).unwrap_or("/tmp"));
        Self {
            // The control arm is `slopdesk_superwire::control_socket_path`, not a fourth `join`
            // beside its siblings: it is the one of the four hostd resolves for itself, so it is
            // the one where a second spelling can put the two ends on different sockets in silence.
            control: PathBuf::from(slopdesk_superwire::control_socket_path(socket, directory, tmpdir)),
            hook: base.join("slopdesk-agent.sock"),
            control_agent: base.join("slopdesk-ctl.sock"),
            lock: base.join("slopdesk-superd.lock"),
        }
    }
}

/// Rejects a socket path that would be truncated by `bind`/`connect`.
///
/// # Errors
/// When the path does not fit `sun_path`.
pub fn validate(path: &Path) -> Result<(), String> {
    let bytes = path.as_os_str().as_encoded_bytes().len();
    if bytes > MAX_SOCKET_PATH_BYTES {
        return Err(format!(
            "socket path is {bytes} bytes, over the {MAX_SOCKET_PATH_BYTES}-byte sun_path limit: {}",
            path.display()
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The bug this whole daemon exists to fix, stated as an assertion. Mirrors
    /// `testStableSocketPathsContainNoProcessID` on the Swift side.
    #[test]
    fn stable_paths_contain_no_process_id() {
        let paths = Paths::resolve(Some("/tmp/slopdesk-test"), None, None);
        let pid = std::process::id().to_string();
        for path in [&paths.control, &paths.hook, &paths.control_agent, &paths.lock] {
            let text = path.display().to_string();
            assert!(!text.contains(&pid), "{text} embeds a pid");
            assert!(text.starts_with("/tmp/slopdesk-test/"), "{text}");
        }
    }

    /// The names must equal `SupervisorPaths.swift`'s, or hostd connects to a name nobody bound.
    #[test]
    fn names_match_the_swift_mirror() {
        let paths = Paths::resolve(Some("/d"), None, None);
        assert_eq!(paths.control, Path::new("/d/slopdesk-superd.sock"));
        assert_eq!(paths.hook, Path::new("/d/slopdesk-agent.sock"));
        assert_eq!(paths.control_agent, Path::new("/d/slopdesk-ctl.sock"));
        assert_eq!(paths.lock, Path::new("/d/slopdesk-superd.lock"));
    }

    #[test]
    fn explicit_socket_override_wins_over_the_directory() {
        let paths = Paths::resolve(Some("/d"), Some("/other/s.sock"), None);
        assert_eq!(paths.control, Path::new("/other/s.sock"));
        // Only the control socket moves — the child-facing paths stay in the directory, because a
        // child is told them by value and cannot be re-told.
        assert_eq!(paths.hook, Path::new("/d/slopdesk-agent.sock"));
    }

    #[test]
    fn tmpdir_is_the_fallback_and_the_directory_override_beats_it() {
        assert_eq!(
            Paths::resolve(None, None, Some("/tmp/user")).control,
            Path::new("/tmp/user/slopdesk-superd.sock")
        );
        assert_eq!(
            Paths::resolve(Some("/d"), None, Some("/tmp/user")).control,
            Path::new("/d/slopdesk-superd.sock")
        );
    }

    #[test]
    fn overlong_path_is_rejected_rather_than_truncated() {
        let long = PathBuf::from(format!("/tmp/{}.sock", "a".repeat(200)));
        assert!(validate(&long).is_err());
        assert!(validate(Path::new("/tmp/short.sock")).is_ok());
    }
}
