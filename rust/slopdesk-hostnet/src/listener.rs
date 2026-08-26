//! The accept loop: a TCP listener in, paired connections out.
//!
//! One thread accepts. Each accepted socket gets its own thread for the handshake, so a peer that
//! opens and then says nothing stalls only itself — bounded by [`HANDSHAKE_TIMEOUT`], enforced as a
//! read timeout on the socket rather than as a racing timer. That is the first place the thread
//! model is simpler than the one it replaces: the Swift original raced the handshake against a
//! `Task.sleep` in a task group, and the timeout arm existed only because there was no way to bound
//! a `receiveExactly` from outside. `SO_RCVTIMEO` bounds it from inside.
//!
//! A third thread reaps expired half-pairs. It ticks at a quarter of the partner timeout, clamped
//! to a 50 ms floor — carried across from the Swift reaper verbatim, because expiry latency is a
//! bound the detach ladder above is written against and re-deriving it is how the two drift.
//!
//! ## Why threads and not a runtime
//!
//! Every sidecar in this tree is blocking `std` on threads and nothing in `rust/` depends on an
//! async runtime. The concurrency here is bounded and known — two sockets per client, one accept
//! thread, one reaper — so it is tens of threads, not tens of thousands. And `docs/59` §7's
//! constraint is zero allocations added per chunk, which a blocking read into a reused buffer meets
//! by construction.

use std::io::{self, Read as _};
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV6, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use socket2::{Domain, Socket, Type};

use crate::link::{ByteLink, TcpByteLink};
use crate::params::keepalive;
use crate::pending::{PairedConnection, PendingLinks};
use crate::preamble::{PREAMBLE_BYTE_COUNT, decode};

/// Bound on one connection's accept→preamble sequence, symmetric with the client's.
///
/// A socket that opens and never sends its 17 bytes otherwise holds a thread and an fd forever.
pub const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);

/// How long a half-paired link may wait for its partner before the reaper closes it.
///
/// Guards the iOS-background / mesh-flap case where the partner never arrives, and bounds the
/// hostile one where a peer opens sockets under fresh ids and never completes any of them.
pub const PENDING_PARTNER_TIMEOUT: Duration = Duration::from_secs(15);

/// The smallest reaper tick, so a tiny injected timeout cannot turn the loop into a spin.
pub const REAP_TICK_FLOOR: Duration = Duration::from_millis(50);

/// How long [`ListenerHandle::stop`] will spend dialling its own port to wake the accept thread.
///
/// A bound, not a wait: if the loopback dial cannot complete in this long the accept thread is
/// already gone or the machine is in no state to care, and stop must not block hostd's shutdown.
const WAKE_DIAL_TIMEOUT: Duration = Duration::from_millis(200);

/// How often the reaper wakes for a given partner timeout: a quarter of it, never below the floor.
///
/// Expiry latency is then bounded by a quarter of the timeout without busy-spinning.
#[must_use]
pub fn reap_tick(partner_timeout: Duration) -> Duration {
    let quarter = partner_timeout / 4;
    if quarter > REAP_TICK_FLOOR {
        quarter
    } else {
        REAP_TICK_FLOOR
    }
}

/// A bound listener that has not started accepting yet.
///
/// Binding is separated from serving so the caller can read [`Self::bound_port`] — a port of `0`
/// asks the OS to choose, and the daemon has to publish what it got before anything can dial it.
#[derive(Debug)]
pub struct Listener {
    socket: TcpListener,
    bound_port: u16,
    partner_timeout: Duration,
}

impl Listener {
    /// Binds `port` on all interfaces, both address families. Pass `0` for an OS-assigned port.
    ///
    /// # Errors
    /// Whatever bind or listen reports — in practice, the port already being held.
    pub fn bind(port: u16) -> io::Result<Self> {
        Self::bind_with(port, PENDING_PARTNER_TIMEOUT)
    }

    /// [`Self::bind`] with an injected partner timeout, so a test drives expiry without waiting.
    ///
    /// ## One socket, both families
    ///
    /// `NWListener` is dual-stack, and a client reaching hostd over the mesh may resolve either
    /// family. An `AF_INET` socket would silently refuse the v6 dial, so this is an `AF_INET6`
    /// socket with `IPV6_V6ONLY` cleared: v6 peers arrive natively, v4 peers arrive as v4-mapped
    /// addresses on the same listener. Matching the framework here is not politeness — a listener
    /// that answers one family is a connectivity bug that only shows up on somebody else's network.
    ///
    /// # Errors
    /// Whatever bind or listen reports.
    pub fn bind_with(port: u16, partner_timeout: Duration) -> io::Result<Self> {
        let socket = Socket::new(Domain::IPV6, Type::STREAM, None)?;
        socket.set_only_v6(false)?;
        // Restarting hostd must not have to wait out TIME_WAIT on its own listening port; the
        // restart IS the config reload (`CLAUDE.md`), so it happens on purpose and often.
        socket.set_reuse_address(true)?;
        socket.bind(&SocketAddr::V6(SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, port, 0, 0)).into())?;
        socket.listen(128)?;
        let listener = TcpListener::from(socket);
        let bound_port = listener.local_addr()?.port();
        Ok(Self {
            socket: listener,
            bound_port,
            partner_timeout,
        })
    }

    /// The port actually bound — the caller's answer when it asked for `0`.
    #[must_use]
    pub const fn bound_port(&self) -> u16 {
        self.bound_port
    }

    /// Starts accepting. Returns the stream of completed pairs and a handle that stops the whole
    /// thing.
    ///
    /// Dropping the [`Receiver`] does NOT stop the listener; [`ListenerHandle::stop`] does. The two
    /// are separate because a consumer that goes away mid-pair would otherwise leave both of that
    /// pair's sockets owned by nobody, which is the fd leak the Swift original's `.terminated`
    /// check existed to catch.
    #[must_use]
    pub fn serve(self) -> (Receiver<PairedConnection>, ListenerHandle) {
        let (sender, receiver) = channel();
        let pending = Arc::new(Mutex::new(PendingLinks::new(self.partner_timeout)));
        let stopping = Arc::new(AtomicBool::new(false));
        let handle = ListenerHandle {
            pending: Arc::clone(&pending),
            stopping: Arc::clone(&stopping),
            bound_port: self.bound_port,
        };

        let reaper_pending = Arc::clone(&pending);
        let reaper_stopping = Arc::clone(&stopping);
        let tick = reap_tick(self.partner_timeout);
        spawn_detached("reaper", move || {
            reap_loop(&reaper_pending, &reaper_stopping, tick);
        });
        spawn_detached("listener", move || {
            accept_loop(&self.socket, &pending, &stopping, &sender);
        });

        (receiver, handle)
    }
}

/// Stops a serving listener and closes everything it is still holding.
#[derive(Debug, Clone)]
pub struct ListenerHandle {
    pending: Arc<Mutex<PendingLinks>>,
    stopping: Arc<AtomicBool>,
    bound_port: u16,
}

impl ListenerHandle {
    /// The port the listener bound.
    #[must_use]
    pub const fn bound_port(&self) -> u16 {
        self.bound_port
    }

    /// Stops accepting, unbinds the port, and closes every half-pair still parked.
    ///
    /// One-way, for the reason [`PendingLinks::stop`] records: the consumer is gone by the time
    /// this returns, so a listener that kept accepting would accept into nobody.
    ///
    /// ## Why it dials its own port
    ///
    /// `NWListener.cancel()` tears the listener down from under its own callback; a blocking
    /// `accept()` has no such lever, and a flag alone would only be read after the NEXT arrival —
    /// so the port would stay bound until some stranger happened to connect. One loopback dial
    /// unblocks `accept`, which sees the flag, returns, and drops the `TcpListener`. That is what
    /// makes stop mean "the port is free" rather than "the port will be free eventually", which
    /// matters because `make host-restart` rebinds it immediately.
    pub fn stop(&self) {
        self.stopping.store(true, Ordering::SeqCst);
        with_pending(&self.pending, PendingLinks::stop);
        // Errors are the expected case on a second stop — by then nothing is listening.
        let loopback = SocketAddr::from((Ipv4Addr::LOCALHOST, self.bound_port));
        drop(TcpStream::connect_timeout(&loopback, WAKE_DIAL_TIMEOUT));
    }

    /// How many ids are currently half-paired. A health read, and the reaper's test seam.
    #[must_use]
    pub fn pending_count(&self) -> usize {
        with_pending(&self.pending, |map| map.len()).unwrap_or(0)
    }
}

fn accept_loop(
    listener: &TcpListener,
    pending: &Arc<Mutex<PendingLinks>>,
    stopping: &Arc<AtomicBool>,
    sender: &Sender<PairedConnection>,
) {
    for stream in listener.incoming() {
        if stopping.load(Ordering::SeqCst) {
            // Either this is the wake dial from `stop`, or a real peer that raced it. Both get the
            // same answer, and returning here drops the listener — which is what frees the port.
            return;
        }
        let Ok(stream) = stream else {
            // One failed accept is not a dead listener (EMFILE, a peer that reset between SYN and
            // accept). Keep serving; the process-level fd budget is superd's problem, not this
            // loop's, and exiting here would take every live pane down with it.
            continue;
        };
        let pending = Arc::clone(pending);
        let sender = sender.clone();
        spawn_detached("handshake", move || handshake(stream, &pending, &sender));
    }
}

/// Reads one socket's 17-byte preamble and hands the link to the pending map.
///
/// The socket is closed on every failure path — an unparked link is owned by nobody else. A
/// handshake still in flight when `stop` lands needs no check of its own: [`PendingLinks::admit`]
/// closes what it refuses.
fn handshake(stream: TcpStream, pending: &Arc<Mutex<PendingLinks>>, sender: &Sender<PairedConnection>) {
    let Ok(()) = configure(&stream) else {
        return;
    };
    let mut bytes = [0_u8; PREAMBLE_BYTE_COUNT];
    let Ok(()) = (&stream).read_exact(&mut bytes) else {
        // Includes the timeout: `SO_RCVTIMEO` surfaces as `WouldBlock` here, which is the bound
        // `HANDSHAKE_TIMEOUT` exists to impose.
        return;
    };
    let Ok(preamble) = decode(&bytes) else {
        return;
    };
    // The handshake deadline is off now: from here the socket is a mux link, and a mux link is
    // legitimately idle between a user's keystrokes.
    let Ok(()) = stream.set_read_timeout(None) else {
        return;
    };
    let label = match preamble.lane {
        crate::preamble::Lane::Control => "host.control",
        crate::preamble::Lane::Data => "host.data",
    };
    let link: Box<dyn ByteLink> = Box::new(TcpByteLink::new(stream, label));
    let paired = with_pending(pending, |map| map.admit(preamble, link, Instant::now())).flatten();
    if let Some(pair) = paired
        && let Err(returned) = sender.send(pair)
    {
        // The consumer is gone. Both sockets are live and nobody else holds them, so this thread
        // closes them rather than dropping a `PairedConnection` whose `Drop` does nothing.
        returned.0.control.close();
        returned.0.data.close();
    }
}

fn reap_loop(pending: &Arc<Mutex<PendingLinks>>, stopping: &Arc<AtomicBool>, tick: Duration) {
    loop {
        thread::sleep(tick);
        if stopping.load(Ordering::SeqCst) {
            return; // `stop` already drained the map; there is nothing left to expire
        }
        if with_pending(pending, |map| map.reap(Instant::now())).is_none() {
            return; // the map is poisoned; the process is going down with it
        }
    }
}

/// Applies the PATH-1 socket options to an accepted stream.
fn configure(stream: &TcpStream) -> io::Result<()> {
    stream.set_nodelay(true)?;
    stream.set_read_timeout(Some(HANDSHAKE_TIMEOUT))?;
    Socket::from(stream.try_clone()?).set_tcp_keepalive(&keepalive())
}

/// Runs `body` under the pending map's lock, or reports the lock as poisoned by returning `None`.
///
/// A poisoned lock means a thread panicked holding it. There is no recovery that keeps the fd
/// accounting honest, so every caller degrades to "do nothing" rather than to a guess.
fn with_pending<T>(
    pending: &Arc<Mutex<PendingLinks>>,
    body: impl FnOnce(&mut PendingLinks) -> T,
) -> Option<T> {
    pending.lock().ok().map(|mut map| body(&mut map))
}

/// Spawns a named thread and forgets it: nothing here is ever joined, [`ListenerHandle::stop`] is
/// what ends them.
///
/// A thread that would not spawn is a capability this host no longer has, so the failure is
/// reported to stderr rather than swallowed — and it is NOT fatal: an accept loop that cannot spawn
/// a handshake worker still serves every connection already up.
fn spawn_detached(what: &'static str, body: impl FnOnce() + Send + 'static) {
    if let Err(error) = thread::Builder::new()
        .name(format!("slopdesk.host.{what}"))
        .spawn(body)
    {
        eprintln!("slopdesk-hostnet: could not spawn the {what} thread: {error}");
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::{REAP_TICK_FLOOR, reap_tick};

    #[test]
    fn the_reaper_ticks_at_a_quarter_of_the_timeout_but_never_below_the_floor() {
        assert_eq!(reap_tick(Duration::from_secs(15)), Duration::from_millis(3750));
        assert_eq!(reap_tick(Duration::from_millis(40)), REAP_TICK_FLOOR);
        assert_eq!(
            reap_tick(Duration::ZERO),
            REAP_TICK_FLOOR,
            "an injected zero must not spin"
        );
    }
}
