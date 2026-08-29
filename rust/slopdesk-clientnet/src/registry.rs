//! One mux connection per endpoint, shared by every pane that rides it.
//!
//! This is `Sources/SlopDeskTransport/Mux/ConnectionRegistry.swift`, and the port is mostly
//! subtraction. Five behaviours survive, and they are the whole of what the file is for:
//!
//! 1. **Share.** Panes to one host get ONE connection, built on the first acquire.
//! 2. **Single-flight.** Concurrent first acquires wait for one build instead of each making a
//!    connection and orphaning all but one.
//! 3. **Refcount.** The connection outlives every pane on it and is torn down by the last release.
//! 4. **Pin.** The connect-gate holds an endpoint up with zero channels, so "connected" survives
//!    closing the last pane.
//! 5. **Evict a corpse.** A pooled connection whose link died is dropped rather than handed out, or
//!    a reconnecting pane opens a channel on it forever.
//!
//! ## What did not survive, and why it was never the semantics
//!
//! Roughly two thirds of the Swift file is commentary on `await` reentrancy: the IDENTITY-GATEs,
//! the TOCTOU re-checks, the lost-update warning about writing back a snapshotted value-type
//! `Entry`, and the note that a coalescer can reach a line before the builder stored the entry it
//! reads. Every one of those is a hazard of a suspension point in the middle of a map mutation.
//! There are no suspension points here, so the mutations are whole: a `Mutex` is taken, the map is
//! read AND written, the lock is dropped, and only then does anything touch a socket. `isDead` was
//! a cross-actor hop and is an atomic load, so the eviction dance collapses into an `if`.
//!
//! The `release` path shows it best. The Swift closes the channel first and then must gate every
//! subsequent map access on `entries[key]?.connection === connection`, because the close suspended.
//! Here the bookkeeping happens FIRST and the I/O after — a release is unconditional, so there is
//! nothing to reorder — and the gate has nothing left to protect.
//!
//! ONE identity check survives, in [`ConnectionRegistry::acquire`]: opening a channel writes to a
//! socket, and holding the pool lock across a write would let one wedged host stall acquires for
//! every other. So that one call happens with the lock released, and `Arc::ptr_eq` on the way back
//! answers the one question that gap allows — did a concurrent eviction replace what we reserved.
//!
//! ## No main actor
//!
//! The Swift type is `@MainActor`, which bought it serialisation and cost it reentrancy. Nothing
//! here touches UI, so the pool is `Send + Sync` and any thread may acquire. That is the same trade
//! `docs/60` describes for the host: the actor was never what made it correct.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Condvar, Mutex};
use std::{fmt, io};

use slopdesk_muxnet::connection::{MuxConnection, OpenFailure, OpenRequest, OpenedChannel};
use slopdesk_wire::mux::MuxCloseReason;

use crate::dial::Endpoint;

/// How a connection is made: the seam the pool is constructed over.
type OpenConnection = Box<dyn Fn(&Endpoint) -> io::Result<Arc<MuxConnection>> + Send + Sync>;

/// Why an acquire did not produce a channel.
#[expect(
    variant_size_differences,
    reason = "an `io::Error` is the widest variant by fifteen bytes; boxing it would add an allocation to a \
              failure path to shrink a value that is returned once and never stored"
)]
#[derive(Debug)]
pub enum AcquireError {
    /// The connection could not be built. Carries what the dialler reported — an unreachable host,
    /// a refused port, an elapsed deadline.
    Dial(io::Error),
    /// The connection existed but would not open a channel.
    Open(OpenFailure),
    /// A concurrent eviction replaced the pooled connection while this acquire was opening its
    /// channel, so the channel belongs to a corpse. The caller retries; the corpse is already
    /// closed.
    Evicted,
    /// A thread panicked holding the pool lock. Every entry's accounting is now unknowable, so the
    /// pool refuses rather than guessing.
    PoolPoisoned,
}

impl fmt::Display for AcquireError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match *self {
            Self::Dial(ref failure) => {
                write!(formatter, "the mux connection could not be dialled: {failure}")
            },
            Self::Open(failure) => write!(formatter, "the mux connection refused a channel: {failure}"),
            Self::Evicted => {
                formatter.write_str("the mux connection was evicted while the channel was opening")
            },
            Self::PoolPoisoned => formatter.write_str("the connection pool is poisoned"),
        }
    }
}

impl core::error::Error for AcquireError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        match *self {
            Self::Dial(ref failure) => Some(failure),
            Self::Open(ref failure) => Some(failure),
            Self::Evicted | Self::PoolPoisoned => None,
        }
    }
}

/// A channel, and the shared connection it rides.
#[derive(Debug)]
pub struct Acquisition {
    /// The pooled connection. Held so the caller can close the channel through it, and counted by
    /// the pool until [`ConnectionRegistry::release`].
    pub connection: Arc<MuxConnection>,
    /// The channel itself, with both sub-channels and their inbound streams.
    pub channel: OpenedChannel,
}

/// What the pool knows about one endpoint.
#[derive(Debug)]
struct Entry {
    connection: Arc<MuxConnection>,
    /// The channels currently riding it. The refcount, kept as ids rather than a number so a double
    /// release cannot decrement twice.
    channels: HashSet<u32>,
    /// Acquires that have reserved this connection and not yet finished opening their channel.
    ///
    /// Without it, the window between "the pool handed out this connection" and "its channel is
    /// registered" is a window in which the entry looks channel-less, so a concurrent last release
    /// would tear down a connection somebody is mid-open on.
    in_flight: usize,
}

impl Entry {
    fn new(connection: Arc<MuxConnection>) -> Self {
        Self {
            connection,
            channels: HashSet::new(),
            in_flight: 0,
        }
    }

    /// Whether nothing wants this endpoint any more. `pinned` is the caller's, because a pin is a
    /// property of the ENDPOINT and outlives any entry under it.
    fn is_unwanted(&self, pinned: bool) -> bool {
        self.channels.is_empty() && self.in_flight == 0 && !pinned
    }
}

/// The pool's whole mutable state, under one lock.
#[derive(Debug)]
struct Pool {
    entries: HashMap<Endpoint, Entry>,
    /// Endpoints a build is in flight for. The single-flight gate: a second acquire waits on the
    /// condvar rather than dialling a second connection and orphaning one of them.
    building: HashSet<Endpoint>,
    /// Endpoints held up with zero channels by the connect-gate.
    pinned: HashSet<Endpoint>,
}

/// How a reservation ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Settled {
    /// The connection is still pooled.
    Kept,
    /// Nothing wanted it, so it was retired and closed.
    Retired,
    /// The pool no longer held it. The reservation went with the entry that was removed, and this
    /// connection has been closed rather than left running with nobody holding it.
    Evicted,
}

/// One shared mux connection per endpoint, refcounted by the channels riding it.
pub struct ConnectionRegistry {
    /// How a connection is made. Injected, because the events a connection emits and the threads it
    /// owns belong to its owner, not to a map — see `crate::dial::establish`.
    open: OpenConnection,
    pool: Mutex<Pool>,
    /// Signalled when an endpoint leaves [`Pool::building`], however that build ended.
    built: Condvar,
}

impl fmt::Debug for ConnectionRegistry {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        // The factory is a closure and has nothing to print; the pool is the state worth seeing, and
        // a poisoned lock must not turn a debug print into a panic.
        formatter
            .debug_struct("ConnectionRegistry")
            .field("pool", &self.pool.try_lock().ok())
            .finish_non_exhaustive()
    }
}

impl ConnectionRegistry {
    /// A pool that builds its connections with `open`.
    #[must_use]
    pub fn new(open: impl Fn(&Endpoint) -> io::Result<Arc<MuxConnection>> + Send + Sync + 'static) -> Self {
        Self {
            open: Box::new(open),
            pool: Mutex::new(Pool {
                entries: HashMap::new(),
                building: HashSet::new(),
                pinned: HashSet::new(),
            }),
            built: Condvar::new(),
        }
    }

    /// Opens a channel to `target`, building or reusing the one shared connection.
    ///
    /// # Errors
    /// [`AcquireError`], and on every arm the pool is left exactly as it was found: a failed build
    /// pools nothing, a failed open retires the connection it could not use unless something else
    /// wants it, and an eviction closes the corpse it was holding.
    pub fn acquire(&self, target: &Endpoint, request: &OpenRequest) -> Result<Acquisition, AcquireError> {
        let connection = self.reserve(target)?;
        // The one call made with the pool lock RELEASED: it writes to a socket, and a wedged host
        // must not be able to stall an acquire for a different endpoint.
        match connection.open_channel(request) {
            Ok(channel) => {
                match self.settle(target, &connection, Some(channel.channel_id))? {
                    Settled::Kept => Ok(Acquisition { connection, channel }),
                    // A channel was registered, so `Retired` cannot be reached; both remaining arms mean
                    // the pool no longer holds what this channel is on.
                    Settled::Retired | Settled::Evicted => Err(AcquireError::Evicted),
                }
            },
            Err(failure) => {
                let _settled = self.settle(target, &connection, None)?;
                Err(AcquireError::Open(failure))
            },
        }
    }

    /// Releases a channel. The connection survives until the last one is released — or, if the
    /// endpoint is pinned, past that.
    ///
    /// The bookkeeping happens before the I/O on purpose: a release is unconditional, so doing the
    /// map work first means nothing can observe a half-released entry and there is no state to
    /// re-check afterwards.
    pub fn release(&self, target: &Endpoint, channel_id: u32) {
        let Ok(mut pool) = self.pool.lock() else {
            return; // a poisoned pool has no honest accounting left to correct
        };
        let pinned = pool.pinned.contains(target);
        let Some(entry) = pool.entries.get_mut(target) else {
            return; // already retired, by an eviction or by a sibling release
        };
        let connection = Arc::clone(&entry.connection);
        let _was_riding = entry.channels.remove(&channel_id);
        let retiring = entry.is_unwanted(pinned);
        if retiring {
            let _retired = pool.entries.remove(target);
        }
        drop(pool);

        connection.close_channel(channel_id, MuxCloseReason::Retired);
        if retiring {
            connection.close();
        }
    }

    /// Builds or reuses the connection to `target` and PINS it, so it stays up with zero channels.
    ///
    /// The connect-gate calls this: the app is connected before any pane opens a channel, and stays
    /// connected across closing the last one. A re-pin after a drop rebuilds, because the eviction
    /// in [`Self::acquire`]'s path does not care whether an endpoint is pinned — a corpse is a
    /// corpse.
    ///
    /// # Errors
    /// [`AcquireError::Dial`] if the connection cannot be built, and [`AcquireError::Evicted`] if a
    /// concurrent [`Self::unpin`] retired it during the build — which is the honest answer, since
    /// what the caller asked for no longer exists.
    pub fn pin(&self, target: &Endpoint) -> Result<Arc<MuxConnection>, AcquireError> {
        {
            let mut pool = self.pool.lock().map_err(|_poisoned| AcquireError::PoolPoisoned)?;
            // Optimistic, and before the build: it is what stops a racing last-channel release from
            // retiring the endpoint out from under a pin that has been asked for.
            let _newly_pinned = pool.pinned.insert(target.clone());
        }
        let connection = match self.reserve(target) {
            Ok(connection) => connection,
            Err(failure) => {
                self.unpin_unwanted(target);
                return Err(failure);
            },
        };
        // A concurrent `unpin` during the build leaves the endpoint unpinned and channel-less, and
        // `settle` then retires it — which is exactly the Swift's post-build re-check, reached here
        // by the ordinary end of a reservation rather than by a rule of its own.
        match self.settle(target, &connection, None)? {
            Settled::Kept => Ok(connection),
            Settled::Retired | Settled::Evicted => Err(AcquireError::Evicted),
        }
    }

    /// Drops the pin and retires the connection if no channel is riding it.
    pub fn unpin(&self, target: &Endpoint) {
        let Ok(mut pool) = self.pool.lock() else {
            return;
        };
        let _was_pinned = pool.pinned.remove(target);
        let retired = pool
            .entries
            .get(target)
            .is_some_and(|entry| entry.is_unwanted(false))
            .then(|| pool.entries.remove(target))
            .flatten();
        drop(pool);
        if let Some(entry) = retired {
            entry.connection.close();
        }
    }

    /// Whether `target` has a pooled connection that is still up.
    ///
    /// What the connect-gate polls to notice a drop. `false` for an endpoint with no entry, so
    /// "never built" and "died" are one answer — which is what a caller that reconnects on either
    /// actually wants.
    #[must_use]
    pub fn is_alive(&self, target: &Endpoint) -> bool {
        self.pool.lock().is_ok_and(|pool| {
            pool.entries
                .get(target)
                .is_some_and(|entry| !entry.connection.is_down())
        })
    }

    /// How many endpoints have a pooled connection.
    #[must_use]
    pub fn pooled_connection_count(&self) -> usize {
        self.pool.lock().map_or(0, |pool| pool.entries.len())
    }

    /// How many channels ride `target`'s connection.
    #[must_use]
    pub fn channel_count(&self, target: &Endpoint) -> usize {
        self.pool.lock().map_or(0, |pool| {
            pool.entries.get(target).map_or(0, |entry| entry.channels.len())
        })
    }

    // ------------------------------------------------------------ reservations

    /// The shared connection for `target`, with one in-flight acquire counted against it.
    ///
    /// Every caller owes exactly one [`Self::settle`] for the reservation this takes.
    fn reserve(&self, target: &Endpoint) -> Result<Arc<MuxConnection>, AcquireError> {
        let mut pool = self.pool.lock().map_err(|_poisoned| AcquireError::PoolPoisoned)?;
        loop {
            // A link drop leaves the pooled connection unusable but NOT removed — a surviving
            // sibling channel kept the entry — so a reconnecting pane would otherwise reacquire the
            // corpse forever. Closing it under the lock is two `shutdown` syscalls on a socket that
            // is already down, and the connection's own locks are below this one, so nothing can
            // deadlock behind it.
            if pool
                .entries
                .get(target)
                .is_some_and(|entry| entry.connection.is_down())
                && let Some(dead) = pool.entries.remove(target)
            {
                dead.connection.close();
            }
            if let Some(entry) = pool.entries.get_mut(target) {
                entry.in_flight += 1;
                return Ok(Arc::clone(&entry.connection));
            }
            if pool.building.contains(target) {
                // Somebody else is dialling this endpoint. Wait for their answer rather than
                // dialling a second connection that one of us would have to orphan.
                pool = self
                    .built
                    .wait(pool)
                    .map_err(|_poisoned| AcquireError::PoolPoisoned)?;
                continue;
            }
            break;
        }

        let _newly_building = pool.building.insert(target.clone());
        drop(pool);
        let built = (self.open)(target);

        let mut pool = self.pool.lock().map_err(|_poisoned| AcquireError::PoolPoisoned)?;
        let _was_building = pool.building.remove(target);
        // Whether it succeeded or not: a waiter must wake either to use what was built or to try
        // building it itself. A `notify_all` only on success is how a failed dial hangs every other
        // acquire for that endpoint.
        self.built.notify_all();
        let reserved = match built {
            Ok(connection) => {
                // Only the builder inserts, and `building` admits one builder per endpoint at a
                // time, so this key cannot have been filled while the dial was in flight.
                let entry = pool
                    .entries
                    .entry(target.clone())
                    .or_insert_with(|| Entry::new(Arc::clone(&connection)));
                entry.in_flight += 1;
                Ok(connection)
            },
            Err(failure) => Err(AcquireError::Dial(failure)),
        };
        drop(pool);
        reserved
    }

    /// Ends a reservation, recording `channel` if the acquire got one, and retires the connection
    /// if nothing wants it any more.
    fn settle(
        &self,
        target: &Endpoint,
        connection: &Arc<MuxConnection>,
        channel: Option<u32>,
    ) -> Result<Settled, AcquireError> {
        let mut pool = self.pool.lock().map_err(|_poisoned| AcquireError::PoolPoisoned)?;
        let pinned = pool.pinned.contains(target);
        let Some(entry) = pool.entries.get_mut(target) else {
            drop(pool);
            connection.close();
            return Ok(Settled::Evicted);
        };
        // THE one identity check. `open_channel` ran with the lock released, and a concurrent
        // eviction can have replaced this endpoint's connection in that gap. Our reservation went
        // with the entry that was removed, so decrementing this one would underflow a count that
        // guards a teardown — and the channel we opened is on a connection the pool has forgotten.
        if !Arc::ptr_eq(&entry.connection, connection) {
            drop(pool);
            connection.close();
            return Ok(Settled::Evicted);
        }
        entry.in_flight = entry.in_flight.saturating_sub(1);
        if let Some(channel_id) = channel {
            let _newly_riding = entry.channels.insert(channel_id);
        }
        if !entry.is_unwanted(pinned) {
            return Ok(Settled::Kept);
        }
        let _retired = pool.entries.remove(target);
        drop(pool);
        connection.close();
        Ok(Settled::Retired)
    }

    /// Drops an optimistic pin that nothing else is keeping alive. Used when a pin's build failed.
    fn unpin_unwanted(&self, target: &Endpoint) {
        let Ok(mut pool) = self.pool.lock() else {
            return;
        };
        // A channel or another in-flight acquire arriving during the failed build means the endpoint
        // has an owner again; leave its lifecycle to that owner rather than to this pin's failure.
        if pool
            .entries
            .get(target)
            .is_none_or(|entry| entry.is_unwanted(false))
        {
            let _was_pinned = pool.pinned.remove(target);
        }
    }
}
