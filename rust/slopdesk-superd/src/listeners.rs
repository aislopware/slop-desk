//! The two child-facing sockets: superd binds them, hostd serves what arrives on them.
//!
//! ## Why the addresses moved here and the logic did not
//! A running `claude` remembers `SLOPDESK_SOCKET_PATH` from its `execve`, and nothing can ever
//! correct that snapshot. So the address must outlive every hostd — which means superd has to own
//! the `bind`. That is the whole of the requirement, and it is worth being precise that it is the
//! whole of it: nothing about a hook record's *meaning* wants to live in this daemon. Parsing one
//! needs the pane's Claude state machine, the tool-use ledger, the dissent watchdog — thousands of
//! lines that change every week, in the one process that must not need rebuilding.
//!
//! So superd accepts, and hands the accepted socket to hostd over `SCM_RIGHTS`. It never reads a
//! byte of either protocol. This keeps the crate documentation's claim intact — superd is not a
//! relay — and it means the hook and ctl protocols still have exactly one implementation, in the
//! process that already holds every other piece of state they need.
//!
//! ## What happens with no hostd attached
//! The connection is accepted and closed at once. The alternative — holding it, or buffering the
//! record for the hostd that is coming back — was rejected: the peer is Claude Code's hook binary,
//! which BLOCKS its agent until the write completes, so a fast `EPIPE` is kinder than a wait. The
//! cost is a hook record lost during a restart, and that cost is bounded by design: detection is
//! two-tiered, `lastAuthoritativeAt` goes stale, coverage is revoked, and the screen engine takes
//! over until the next record (`docs/50`). A pane cannot get permanently stuck on a dropped record.
//!
//! ## Unclaimed is not the same as unbound
//! Both sockets are bound for superd's whole life, so the *address* is always stable. Whether a
//! hostd is behind one is a separate, changing fact, tracked in [`Claims`] — and it gates whether
//! the path is advertised into a child's environment at all. Advertising an address is a promise to
//! be listening at it; superd makes that promise only while someone can keep it.

// stderr IS superd's log — see `server.rs`. A bind that fails here is a socket hostd will never be
// able to serve, and this line is the only place that says so.
#![expect(clippy::print_stderr, reason = "stderr is superd's log; launchd captures it")]

use std::os::fd::{AsFd as _, AsRawFd as _};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::{Arc, Mutex};

use crate::paths::{self, Paths};
use crate::protocol::listener_kind;
use crate::registry::ClientID;

/// Where an accepted child connection goes. A boxed callback rather than a channel, so this module
/// has no opinion about how the server finds the claimant.
pub type ConnectionDeliverer = Arc<dyn Fn(&'static str, UnixStream) + Send + Sync>;

/// Who is serving each child-facing listener, if anyone.
///
/// A `Mutex<Option<ClientID>>` per kind rather than a map, because there are exactly two kinds and
/// naming them makes every call site say which one it means.
#[derive(Debug)]
pub struct Claims {
    hook: Mutex<Option<ClientID>>,
    control: Mutex<Option<ClientID>>,
    /// Whether the bind actually succeeded. A kind that is not bound can never be claimed — the
    /// claim would otherwise advertise an address with nothing behind it, which is the exact bug
    /// `docs/51` §1 exists to prevent, reintroduced one level up.
    hook_bound: bool,
    control_bound: bool,
}

impl Claims {
    /// Records which kinds were successfully bound. Nothing is claimed yet.
    #[must_use]
    pub const fn new(hook_bound: bool, control_bound: bool) -> Self {
        Self {
            hook: Mutex::new(None),
            control: Mutex::new(None),
            hook_bound,
            control_bound,
        }
    }

    /// Everything bound, nothing claimed — the shape the registry's tests want.
    #[must_use]
    pub const fn bound() -> Self {
        Self::new(true, true)
    }

    /// Whether `kind` could be claimed, without claiming it.
    ///
    /// Exists so a multi-kind `listen` can be all-or-nothing: every kind is checked before any is
    /// taken, and a hostd never half-succeeds into believing it serves something it does not.
    ///
    /// # Errors
    /// An unknown kind, or one whose bind failed.
    pub fn check(&self, kind: &str) -> Result<(), String> {
        self.slot(kind).map(|_slot| ())
    }

    /// Takes over `kind`. The most recent claimant wins; see [`crate::protocol::ListenRequest`].
    ///
    /// Returns the client it displaced, or an error naming why the claim could not be honoured.
    ///
    /// # Errors
    /// An unknown kind, a kind whose bind failed, or a poisoned lock.
    pub fn claim(&self, kind: &str, holder: ClientID) -> Result<Option<ClientID>, String> {
        let slot = self.slot(kind)?;
        let mut guard = slot
            .lock()
            .map_err(|_ignored| format!("the {kind} claim lock was poisoned"))?;
        let previous = guard.replace(holder);
        drop(guard);
        Ok(previous)
    }

    /// Drops every claim `holder` has. Called when its connection dies.
    ///
    /// Only clears a slot this client still holds: a hostd that was already displaced by its
    /// successor must not take the successor's claim with it when it finally notices it is gone.
    pub fn release_all(&self, holder: ClientID) {
        for slot in [&self.hook, &self.control] {
            if let Ok(mut guard) = slot.lock() {
                if *guard == Some(holder) {
                    *guard = None;
                }
                drop(guard);
            }
        }
    }

    /// Who to hand an accepted connection of this kind to.
    #[must_use]
    pub fn holder(&self, kind: &str) -> Option<ClientID> {
        let slot = self.slot(kind).ok()?;
        let holder = slot.lock().ok()?;
        let found = *holder;
        drop(holder);
        found
    }

    /// Whether this kind's path may be advertised into a child's environment.
    #[must_use]
    pub fn is_served(&self, kind: &str) -> bool {
        self.holder(kind).is_some()
    }

    fn slot(&self, kind: &str) -> Result<&Mutex<Option<ClientID>>, String> {
        match kind {
            listener_kind::HOOK if self.hook_bound => Ok(&self.hook),
            listener_kind::CONTROL if self.control_bound => Ok(&self.control),
            listener_kind::HOOK | listener_kind::CONTROL => {
                Err(format!(
                    "superd could not bind the {kind} socket, so it cannot be claimed"
                ))
            },
            unknown => Err(format!("superd has no '{unknown}' listener")),
        }
    }
}

/// The bound sockets, before their accept threads start.
///
/// A failed bind is a `None` rather than a fatal error: superd holds live panes and refusing to
/// start over a hook socket would cost every one of them. The kind is simply never served, and
/// [`Claims`] refuses a claim for it, so hostd hears about it rather than inferring silence.
#[derive(Debug)]
pub struct ChildListeners {
    /// The Claude-hook socket.
    pub hook: Option<UnixListener>,
    /// The agent-control socket.
    pub control: Option<UnixListener>,
}

impl ChildListeners {
    /// Binds both, `0600`, unlinking a stale socket file first.
    ///
    /// Unlinking is safe for the same reason [`crate::server::Server::bind`]'s is and no other:
    /// `main` holds the exclusive `flock` before this runs. Without it, a second superd would take
    /// these addresses from a live incumbent, and every running agent's hook POSTs would go to the
    /// wrong daemon.
    #[must_use]
    pub fn bind(paths: &Paths) -> Self {
        Self {
            hook: bind_one(&paths.hook, listener_kind::HOOK),
            control: bind_one(&paths.control_agent, listener_kind::CONTROL),
        }
    }

    /// The [`Claims`] that matches what actually got bound.
    #[must_use]
    pub const fn claims(&self) -> Claims {
        Claims::new(self.hook.is_some(), self.control.is_some())
    }

    /// Starts one accept thread per bound listener.
    ///
    /// `deliver` is called on the accept thread with the kind and the accepted socket. It must not
    /// block for long: it is the only thing between a hook POST and its agent resuming. Handing off
    /// a descriptor is one `sendmsg`, which is why this shape is affordable.
    pub fn serve(self, deliver: &ConnectionDeliverer) {
        for (listener, kind) in [
            (self.hook, listener_kind::HOOK),
            (self.control, listener_kind::CONTROL),
        ] {
            let Some(listener) = listener else { continue };
            let deliver = Arc::clone(deliver);
            let spawned = std::thread::Builder::new()
                .name(format!("superd-accept-{kind}"))
                .spawn(move || accept_loop(&listener, kind, &*deliver));
            if let Err(error) = spawned {
                eprintln!("superd: could not start the {kind} accept thread: {error}");
            }
        }
    }
}

/// Binds one socket, or logs why it could not and returns `None`.
fn bind_one(path: &std::path::Path, kind: &'static str) -> Option<UnixListener> {
    if let Err(error) = paths::validate(path) {
        eprintln!("superd: not binding the {kind} socket — {error}");
        return None;
    }
    // A missing file is the normal case; a real failure is reported by `bind` itself.
    let _ignored = std::fs::remove_file(path);
    let listener = match UnixListener::bind(path) {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!(
                "superd: could not bind the {kind} socket at {}: {error}",
                path.display()
            );
            return None;
        },
    };
    // Bound for superd's whole life, so it must not reach a shell forked years later.
    slopdesk_posix::pty::set_cloexec(listener.as_raw_fd());
    // Owner-only. The per-user `$TMPDIR` is already `0700`, so this is belt-and-braces — but these
    // are always-up surfaces and an always-up surface earns the narrower mode.
    if let Err(error) = std::fs::set_permissions(
        path,
        <std::fs::Permissions as std::os::unix::fs::PermissionsExt>::from_mode(0o600),
    ) {
        eprintln!("superd: could not chmod the {kind} socket: {error}");
    }
    eprintln!("superd: {kind} socket listening at {}", path.display());
    Some(listener)
}

/// How long an accept loop rests after a transient `accept(2)` failure before asking again.
///
/// Long enough that a process at its descriptor ceiling is not spinning on `EMFILE`, short enough
/// that a hook whose connection was aborted under it is not waiting on a human timescale.
pub(crate) const ACCEPT_RETRY_REST: std::time::Duration = std::time::Duration::from_millis(50);

/// Whether an `accept(2)` failure is one the loop should retry rather than end on.
///
/// `EMFILE`/`ENFILE` are the process or the system at its descriptor ceiling — on a superd that is
/// a machine with many panes, each holding a master and its sockets, and the ceiling clears when
/// any of them closes. `ECONNABORTED` is one peer that went away between `listen` and `accept`, and
/// `ENOBUFS` is a moment of kernel memory pressure. None of them says anything about the LISTENER,
/// which is the only thing whose failure should end the loop: a daemon holding every live pane's
/// master must not exit — and `SIGHUP` every shell on the machine — because one `accept` hit a
/// ceiling somebody else's descriptors filled.
pub(crate) fn accept_should_retry(error: &std::io::Error) -> bool {
    matches!(
        error.raw_os_error(),
        Some(libc::EMFILE | libc::ENFILE | libc::ECONNABORTED | libc::ENOBUFS)
    ) || error.kind() == std::io::ErrorKind::ConnectionAborted
}

/// Accepts forever, handing each connection straight to `deliver`.
///
/// Never returns under normal operation. An `accept` failure that is not `EINTR` and not one of
/// [`accept_should_retry`]'s ends the thread — the listener is gone, and the kind stops being
/// served — rather than spinning on the same errno.
fn accept_loop(
    listener: &UnixListener,
    kind: &'static str,
    deliver: &(dyn Fn(&'static str, UnixStream) + Send + Sync),
) {
    loop {
        match listener.accept() {
            Ok((stream, _address)) => {
                // A hook connection is short-lived, but it is alive across the `spawn` a hook can
                // trigger — and an inherited one would hold the agent's writer open past its reply.
                slopdesk_posix::pty::set_cloexec(stream.as_raw_fd());
                deliver(kind, stream);
            },
            // A signal interrupted the wait — go round again rather than treat it as the end.
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {},
            Err(error) if accept_should_retry(&error) => {
                eprintln!("superd: the {kind} accept failed transiently, retrying: {error}");
                std::thread::sleep(ACCEPT_RETRY_REST);
            },
            Err(error) => {
                eprintln!("superd: the {kind} accept loop ended: {error}");
                return;
            },
        }
    }
}

/// The descriptor of an accepted connection, borrowed for the one `sendmsg` that hands it over.
///
/// A free function rather than an inline `as_fd()` so the ownership rule has somewhere to be
/// written: `SCM_RIGHTS` installs a *separate* descriptor in the receiver, so this one is still
/// ours and still has to be closed — which happens when the caller drops the stream, after the
/// send. Sending a descriptor does not transfer it. The borrow is what ties "after the send" to
/// something the compiler checks.
#[must_use]
pub fn descriptor_of(stream: &UnixStream) -> std::os::fd::BorrowedFd<'_> {
    stream.as_fd()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_most_recent_claim_wins_and_names_who_it_displaced() {
        let claims = Claims::bound();
        assert_eq!(claims.claim(listener_kind::HOOK, 1), Ok(None));
        assert_eq!(claims.claim(listener_kind::HOOK, 2), Ok(Some(1)));
        assert_eq!(claims.holder(listener_kind::HOOK), Some(2));
    }

    /// The displaced hostd's connection dies *after* its successor claimed — the ordinary restart
    /// race, since the old process notices its socket is gone only when it next reads. It must not
    /// take the successor's claim with it.
    #[test]
    fn a_displaced_client_disconnecting_does_not_clear_its_successor() {
        let claims = Claims::bound();
        let _ignored = claims.claim(listener_kind::HOOK, 1);
        let _displaced = claims.claim(listener_kind::HOOK, 2);
        claims.release_all(1);
        assert_eq!(claims.holder(listener_kind::HOOK), Some(2));
        claims.release_all(2);
        assert_eq!(claims.holder(listener_kind::HOOK), None);
    }

    #[test]
    fn an_unbound_kind_cannot_be_claimed_and_is_never_served() {
        let claims = Claims::new(false, true);
        assert!(claims.claim(listener_kind::HOOK, 1).is_err());
        assert!(!claims.is_served(listener_kind::HOOK));
        assert!(claims.claim(listener_kind::CONTROL, 1).is_ok());
        assert!(claims.is_served(listener_kind::CONTROL));
    }

    #[test]
    fn an_unknown_kind_is_refused_rather_than_ignored() {
        let claims = Claims::bound();
        assert!(claims.claim("inspector", 1).is_err());
        assert!(!claims.is_served("inspector"));
    }

    /// Claiming one kind must not advertise the other. The ctl surface is default-off in hostd, and
    /// the flag that keeps it off is expressed here as "hostd never claims `control`".
    #[test]
    fn kinds_are_claimed_independently() {
        let claims = Claims::bound();
        let _ignored = claims.claim(listener_kind::HOOK, 1);
        assert!(claims.is_served(listener_kind::HOOK));
        assert!(!claims.is_served(listener_kind::CONTROL));
    }
}
