//! Hostd's live-pane relations: which channel names which pane — docs/59 step 7.
//!
//! `rust/slopdesk-muxsession`'s `registry` owns the decisions. This is the door.
//!
//! ## Why it is a HANDLE
//! Every relation here is state with the DAEMON's lifetime, read and written from the accept loop,
//! from each connection's receive loops, from a session's teardown ladder and from the workspace
//! reconciler — all serialized by exactly one `NSLock`, hostd's `HostServer.lock`. That is the same
//! test [`crate::pane_outbox`] and [`crate::pane_fanout`] answer at a session's scale.
//!
//! ## How identity crosses
//! A session OBJECT cannot, so it crosses as a `slot`: a `u64` from
//! [`slopdesk_host_slot_mint`], minted once per object and carried by it for its whole life. Every
//! identity-guarded action hostd used to spell `===` — remove this key only while it still names
//! THIS session, is this session attached anywhere else — is a question about slots, and asking it
//! of the table that holds the relation is what keeps one answer.
//!
//! ## What did NOT cross
//! The objects and the sockets. `MuxChannelSession`, `MuxNWConnection` and
//! `WorkspaceChannelSession` stay in hostd, and so does the map from a slot to its session — a
//! dictionary keyed by an id hostd already has is not a relation, it is the retention itself.
//!
//! ## The two array conventions
//! A READ door answers the total either way and writes nothing unless the whole answer fits, so a
//! caller that guessed short retries. A door that MUTATES refuses instead: if the answer does not
//! fit it changes nothing and reports the size, because a mutation whose result was dropped cannot
//! be retried.

use core::ffi::c_uchar;

use slopdesk_muxsession::registry::{Key, Member, NO_SLOT, Registry};

use crate::borrow;
use crate::workspace::Uuid;

/// One client's channel, flat: the connection it rides and that connection's channel id.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SlopDeskHostKey {
    /// The client connection.
    pub connection: Uuid,
    /// The channel id, allocated per connection from 1.
    pub channel: u32,
}

impl SlopDeskHostKey {
    const fn inner(self) -> Key {
        Key::new(self.connection.bytes, self.channel)
    }

    const fn from_inner(key: Key) -> Self {
        Self {
            connection: Uuid {
                bytes: key.connection,
            },
            channel: key.channel,
        }
    }
}

/// A registered channel: the key, the pane it names, and which subscriber of it the channel is.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SlopDeskHostMember {
    /// The channel.
    pub key: SlopDeskHostKey,
    /// The pane object the channel names.
    pub slot: u64,
    /// Which subscriber of that pane this member is.
    pub subscriber: u64,
}

impl SlopDeskHostMember {
    const fn from_inner(member: Member) -> Self {
        Self {
            key: SlopDeskHostKey::from_inner(member.key),
            slot: member.slot,
            subscriber: member.subscriber,
        }
    }
}

/// Hostd's relation table, as an opaque handle.
#[derive(Debug)]
pub struct SlopDeskHostRegistry {
    /// The state the caller's `HostServer.lock` guards.
    inner: Registry,
}

/// Turns the caller's handle back into a reference.
///
/// # Safety
/// `handle` must be null or a live pointer from [`slopdesk_host_registry_new`] that has not been
/// freed, and no other reference to it may be live for the duration of the call.
#[expect(
    unsafe_code,
    reason = "turning the caller's handle back into a reference is this module's whole obligation"
)]
const unsafe fn held<'a>(handle: *mut SlopDeskHostRegistry) -> Option<&'a mut SlopDeskHostRegistry> {
    // SAFETY: by the caller's obligation this is a live, exclusively-held allocation from `new`.
    unsafe { handle.as_mut() }
}

/// Writes `items` when they fit, and answers how many there are either way.
///
/// # Safety
/// `out` must be null or point to `capacity` writable `T`s for the call.
#[expect(
    unsafe_code,
    reason = "the caller's out-buffer is a raw pointer; the copy is this helper's obligation"
)]
const unsafe fn deliver_all<T: Copy>(items: &[T], out: *mut T, capacity: usize) -> usize {
    let count = items.len();
    if count == 0 || count > capacity || out.is_null() {
        return count;
    }
    // SAFETY: `count <= capacity` was just checked, `out` is non-null and writable for `capacity`
    // elements by the caller's obligation, and `items` is a live Rust slice that cannot overlap it.
    unsafe { std::ptr::copy_nonoverlapping(items.as_ptr(), out, count) };
    count
}

/// The next session identity, unique for the life of the process.
///
/// Monotonic and never zero: zero is the "no such pane" answer every door returning a slot by value
/// uses, so a live session can never collide with it. A wrap would need a daemon to mint one
/// session per nanosecond for five centuries.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_host_slot_mint() -> u64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(1);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

/// The subscriber id a pane's ORIGINAL channel rides.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_host_primary_subscriber() -> u64 {
    slopdesk_muxsession::registry::PRIMARY_SUBSCRIBER
}

/// A fresh, empty registry.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_host_registry_new() -> *mut SlopDeskHostRegistry {
    Box::into_raw(Box::new(SlopDeskHostRegistry {
        inner: Registry::new(),
    }))
}

/// Frees a registry. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_host_registry_new`], freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_free(handle: *mut SlopDeskHostRegistry) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

// MARK: - Live panes

/// Registers `key` as `subscriber` of the pane at `slot`, which serves `session`.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_attach(
    handle: *mut SlopDeskHostRegistry,
    key: SlopDeskHostKey,
    slot: u64,
    session: Uuid,
    subscriber: u64,
) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.attach(key.inner(), slot, session.bytes, subscriber);
    }
}

/// The pane `key` names, or `0` for a key that is not registered.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_slot(
    handle: *mut SlopDeskHostRegistry,
    key: SlopDeskHostKey,
) -> u64 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return NO_SLOT;
    };
    state.inner.slot(key.inner())
}

/// Writes the member `key` names. Answers `false` — writing nothing — for an unregistered key.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or writable for one
/// [`SlopDeskHostMember`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_member(
    handle: *mut SlopDeskHostRegistry,
    key: SlopDeskHostKey,
    out: *mut SlopDeskHostMember,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    let Some(member) = state.inner.member(key.inner()) else {
        return false;
    };
    if out.is_null() {
        return true;
    }
    // SAFETY: non-null and, by the caller's obligation, writable for one member for this call.
    unsafe { *out = SlopDeskHostMember::from_inner(member) };
    true
}

/// Removes exactly one member — the leaving client, not the pane — and answers the pane it named.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_detach_key(
    handle: *mut SlopDeskHostRegistry,
    key: SlopDeskHostKey,
) -> u64 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return NO_SLOT;
    };
    state
        .inner
        .detach_key(key.inner())
        .map_or(NO_SLOT, |member| member.slot)
}

/// Removes `key` only while it still names `slot` — the guard against unregistering a successor.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_detach_key_if_slot(
    handle: *mut SlopDeskHostRegistry,
    key: SlopDeskHostKey,
    slot: u64,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    state.inner.detach_key_if_slot(key.inner(), slot)
}

/// Writes every key naming `slot`, answering the total either way.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or point to `capacity`
/// writable [`SlopDeskHostKey`]s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_keys_for_slot(
    handle: *mut SlopDeskHostRegistry,
    slot: u64,
    out: *mut SlopDeskHostKey,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let keys: Vec<SlopDeskHostKey> = state
        .inner
        .keys_for_slot(slot)
        .into_iter()
        .map(SlopDeskHostKey::from_inner)
        .collect();
    // SAFETY: the caller's `out`/`capacity` obligation above is this helper's.
    unsafe { deliver_all(&keys, out, capacity) }
}

/// Removes EVERY key naming `slot` and writes them — the reap that takes the aliases with it.
///
/// MUTATES, so a short buffer changes nothing: the count comes back and the table is untouched.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or point to `capacity`
/// writable [`SlopDeskHostKey`]s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_detach_slot(
    handle: *mut SlopDeskHostRegistry,
    slot: u64,
    out: *mut SlopDeskHostKey,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let count = state.inner.keys_for_slot(slot).len();
    if count > capacity || (count > 0 && out.is_null()) {
        return count;
    }
    let keys: Vec<SlopDeskHostKey> = state
        .inner
        .detach_slot(slot)
        .into_iter()
        .map(SlopDeskHostKey::from_inner)
        .collect();
    // SAFETY: the caller's `out`/`capacity` obligation above is this helper's.
    unsafe { deliver_all(&keys, out, capacity) }
}

/// Whether any key still names `slot`.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_slot_is_attached(
    handle: *mut SlopDeskHostRegistry,
    slot: u64,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    state.inner.slot_is_attached(slot)
}

/// Writes every member riding `connection`, answering the total either way.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or point to `capacity`
/// writable [`SlopDeskHostMember`]s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_members_for_connection(
    handle: *mut SlopDeskHostRegistry,
    connection: Uuid,
    out: *mut SlopDeskHostMember,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let members: Vec<SlopDeskHostMember> = state
        .inner
        .members_for_connection(connection.bytes)
        .into_iter()
        .map(SlopDeskHostMember::from_inner)
        .collect();
    // SAFETY: the caller's `out`/`capacity` obligation above is this helper's.
    unsafe { deliver_all(&members, out, capacity) }
}

/// Removes every member riding `connection` — the link-drop snapshot — and writes them.
///
/// The removal happens BEFORE the caller retires anything, so a racing open cannot find a member of
/// a connection that is already gone. MUTATES: a short buffer changes nothing.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or point to `capacity`
/// writable [`SlopDeskHostMember`]s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_detach_connection(
    handle: *mut SlopDeskHostRegistry,
    connection: Uuid,
    out: *mut SlopDeskHostMember,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let count = state.inner.members_for_connection(connection.bytes).len();
    if count > capacity || (count > 0 && out.is_null()) {
        return count;
    }
    let members: Vec<SlopDeskHostMember> = state
        .inner
        .detach_connection(connection.bytes)
        .into_iter()
        .map(SlopDeskHostMember::from_inner)
        .collect();
    // SAFETY: the caller's `out`/`capacity` obligation above is this helper's.
    unsafe { deliver_all(&members, out, capacity) }
}

/// Writes every member, answering the total either way — the roster's subscriber→connection join.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or point to `capacity`
/// writable [`SlopDeskHostMember`]s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_members(
    handle: *mut SlopDeskHostRegistry,
    out: *mut SlopDeskHostMember,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let members: Vec<SlopDeskHostMember> = state
        .inner
        .members()
        .into_iter()
        .map(SlopDeskHostMember::from_inner)
        .collect();
    // SAFETY: the caller's `out`/`capacity` obligation above is this helper's.
    unsafe { deliver_all(&members, out, capacity) }
}

/// Writes every DISTINCT pane, answering the total either way.
///
/// A fanned-out pane is N members and one slot: an enumeration that repeated it would shut the same
/// PTY N times.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or point to `capacity`
/// writable `u64`s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_slots(
    handle: *mut SlopDeskHostRegistry,
    out: *mut u64,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let slots = state.inner.slots();
    // SAFETY: the caller's `out`/`capacity` obligation above is this helper's.
    unsafe { deliver_all(&slots, out, capacity) }
}

/// How many CHANNELS are registered — one per watching client, not one per pane.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_member_count(handle: *mut SlopDeskHostRegistry) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    state.inner.members().len()
}

/// How many distinct CONNECTIONS hold at least one pane — the "N client(s) connected" count.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_connection_count(handle: *mut SlopDeskHostRegistry) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    state.inner.connection_count()
}

/// Writes the key one SUBSCRIBER of `slot` rides. Answers `false` — writing nothing — when that
/// subscriber holds no channel.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or writable for one
/// [`SlopDeskHostKey`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_key_for(
    handle: *mut SlopDeskHostRegistry,
    slot: u64,
    subscriber: u64,
    out: *mut SlopDeskHostKey,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    let Some(key) = state.inner.key_for(slot, subscriber) else {
        return false;
    };
    if out.is_null() {
        return true;
    }
    // SAFETY: non-null and, by the caller's obligation, writable for one key for this call.
    unsafe { *out = SlopDeskHostKey::from_inner(key) };
    true
}

/// The pane serving `session` under some OTHER key — the join question — or `0`.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_slot_elsewhere(
    handle: *mut SlopDeskHostRegistry,
    session: Uuid,
    excluding: SlopDeskHostKey,
) -> u64 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return NO_SLOT;
    };
    state.inner.slot_elsewhere(session.bytes, excluding.inner())
}

/// The live pane serving `session` from any key, or `0`.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_slot_for_session(
    handle: *mut SlopDeskHostRegistry,
    session: Uuid,
) -> u64 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return NO_SLOT;
    };
    state.inner.slot_for_session(session.bytes)
}

/// Empties the pane map and writes every distinct pane that was in it — the `stop()` drain.
///
/// MUTATES: a short buffer changes nothing.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or point to `capacity`
/// writable `u64`s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_drain_panes(
    handle: *mut SlopDeskHostRegistry,
    out: *mut u64,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let count = state.inner.slots().len();
    if count > capacity || (count > 0 && out.is_null()) {
        return count;
    }
    let slots = state.inner.drain_panes();
    // SAFETY: the caller's `out`/`capacity` obligation above is this helper's.
    unsafe { deliver_all(&slots, out, capacity) }
}

// MARK: - Control panes

/// Registers a standalone `ctl`-spawned pane, which holds no channel and no connection.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_attach_control(
    handle: *mut SlopDeskHostRegistry,
    session: Uuid,
    slot: u64,
) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.attach_control(session.bytes, slot);
    }
}

/// The standalone pane serving `session`, or `0`.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_control_slot(
    handle: *mut SlopDeskHostRegistry,
    session: Uuid,
) -> u64 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return NO_SLOT;
    };
    state.inner.control_slot(session.bytes)
}

/// Removes the standalone pane serving `session` and answers it, or `0`. Idempotent.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_detach_control(
    handle: *mut SlopDeskHostRegistry,
    session: Uuid,
) -> u64 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return NO_SLOT;
    };
    state.inner.detach_control(session.bytes)
}

/// Writes every standalone pane, answering the total either way.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or point to `capacity`
/// writable `u64`s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_control_slots(
    handle: *mut SlopDeskHostRegistry,
    out: *mut u64,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let slots = state.inner.control_slots();
    // SAFETY: the caller's `out`/`capacity` obligation above is this helper's.
    unsafe { deliver_all(&slots, out, capacity) }
}

/// Empties the standalone map and writes what was in it. MUTATES: a short buffer changes nothing.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or point to `capacity`
/// writable `u64`s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_drain_control(
    handle: *mut SlopDeskHostRegistry,
    out: *mut u64,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let count = state.inner.control_slots().len();
    if count > capacity || (count > 0 && out.is_null()) {
        return count;
    }
    let slots = state.inner.drain_control();
    // SAFETY: the caller's `out`/`capacity` obligation above is this helper's.
    unsafe { deliver_all(&slots, out, capacity) }
}

// MARK: - Agent-hook sinks

/// Records where `session`'s agent hooks route, and which object owns the entry.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `pane` must be null or point to `pane_len`
/// readable bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_register_hook(
    handle: *mut SlopDeskHostRegistry,
    session: Uuid,
    pane: *const c_uchar,
    pane_len: usize,
    owner: u64,
) {
    // SAFETY: the caller's obligation above is this function's, restated on `held` and `borrow`.
    let Some(state) = (unsafe { held(handle) }) else {
        return;
    };
    // SAFETY: the caller's `pane`/`pane_len` obligation above is `borrow`'s.
    let bytes = unsafe { borrow(pane, pane_len) };
    state.inner.register_hook(session.bytes, bytes, owner);
}

/// Writes the pane id `session`'s hooks route to, answering its length either way (`0` = no sink).
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or point to `capacity`
/// writable bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_hook_pane(
    handle: *mut SlopDeskHostRegistry,
    session: Uuid,
    out: *mut c_uchar,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let Some(pane) = state.inner.hook_pane(session.bytes) else {
        return 0;
    };
    // SAFETY: the caller's `out`/`capacity` obligation above is this helper's.
    unsafe { deliver_all(pane, out, capacity) }
}

/// Re-points `session`'s sink at `owner` without moving where it routes — the reattach edge.
///
/// Answers `false` when nothing is registered: hooks were off at spawn, so there is no sink to
/// move.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_rebind_hook(
    handle: *mut SlopDeskHostRegistry,
    session: Uuid,
    owner: u64,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    state.inner.rebind_hook(session.bytes, owner)
}

/// Removes `session`'s sink while `owner` still holds it, writing the pane id it routed to.
///
/// Answers `0` for an entry owned by somebody else — a stale teardown for a same-UUID ghost stands
/// down rather than dropping the key its live successor registered. MUTATES: a short buffer changes
/// nothing.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or point to `capacity`
/// writable bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_unregister_hook(
    handle: *mut SlopDeskHostRegistry,
    session: Uuid,
    owner: u64,
    out: *mut c_uchar,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let count = state.inner.hook_pane(session.bytes).map_or(0, <[u8]>::len);
    if count > capacity || (count > 0 && out.is_null()) {
        return count;
    }
    let Some(pane) = state.inner.unregister_hook(session.bytes, owner) else {
        return 0;
    };
    // SAFETY: the caller's `out`/`capacity` obligation above is this helper's.
    unsafe { deliver_all(&pane, out, capacity) }
}

/// How many hook sinks are registered — the leak check a per-reattach key would fail.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_hook_count(handle: *mut SlopDeskHostRegistry) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    state.inner.hook_count()
}

// MARK: - Project document ids

/// Writes the document id for `path`, minting `candidate` the first time the path is seen.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation; `path` must be null or point to `path_len` readable
/// bytes; `out` must be null or writable for one [`Uuid`]. Both live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_project_id(
    handle: *mut SlopDeskHostRegistry,
    path: *const c_uchar,
    path_len: usize,
    candidate: Uuid,
    out: *mut Uuid,
) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return;
    };
    // SAFETY: the caller's `path`/`path_len` obligation above is `borrow`'s.
    let bytes = unsafe { borrow(path, path_len) };
    let id = state.inner.project_id(bytes, candidate.bytes);
    if out.is_null() {
        return;
    }
    // SAFETY: non-null and, by the caller's obligation, writable for one uuid for this call.
    unsafe { *out = Uuid { bytes: id } };
}

/// How many projects have an id.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_host_registry_project_count(handle: *mut SlopDeskHostRegistry) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    state.inner.project_count()
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use std::ptr;

    use super::{
        SlopDeskHostKey, SlopDeskHostMember, slopdesk_host_primary_subscriber, slopdesk_host_registry_attach,
        slopdesk_host_registry_attach_control, slopdesk_host_registry_connection_count,
        slopdesk_host_registry_detach_connection, slopdesk_host_registry_detach_key,
        slopdesk_host_registry_detach_key_if_slot, slopdesk_host_registry_detach_slot,
        slopdesk_host_registry_drain_panes, slopdesk_host_registry_free, slopdesk_host_registry_hook_count,
        slopdesk_host_registry_hook_pane, slopdesk_host_registry_key_for,
        slopdesk_host_registry_keys_for_slot, slopdesk_host_registry_member,
        slopdesk_host_registry_member_count, slopdesk_host_registry_new, slopdesk_host_registry_project_id,
        slopdesk_host_registry_register_hook, slopdesk_host_registry_slot,
        slopdesk_host_registry_slot_elsewhere, slopdesk_host_registry_slot_is_attached,
        slopdesk_host_registry_unregister_hook, slopdesk_host_slot_mint,
    };
    use crate::workspace::Uuid;

    const CONN_A: Uuid = Uuid { bytes: [1; 16] };
    const CONN_B: Uuid = Uuid { bytes: [2; 16] };
    const SESSION: Uuid = Uuid { bytes: [9; 16] };

    const fn key(connection: Uuid, channel: u32) -> SlopDeskHostKey {
        SlopDeskHostKey { connection, channel }
    }

    #[test]
    fn a_fanned_out_pane_crosses_as_one_slot_under_two_keys() {
        let handle = slopdesk_host_registry_new();
        let slot = slopdesk_host_slot_mint();
        unsafe {
            slopdesk_host_registry_attach(handle, key(CONN_A, 1), slot, SESSION, 0);
            slopdesk_host_registry_attach(handle, key(CONN_B, 1), slot, SESSION, 7);
            assert_eq!(slopdesk_host_registry_slot(handle, key(CONN_A, 1)), slot);
            assert_eq!(slopdesk_host_registry_member_count(handle), 2);
            assert_eq!(slopdesk_host_registry_connection_count(handle), 2);

            let mut member = SlopDeskHostMember {
                key: key(CONN_A, 0),
                slot: 0,
                subscriber: 0,
            };
            assert!(slopdesk_host_registry_member(
                handle,
                key(CONN_B, 1),
                &raw mut member
            ));
            assert_eq!(member.subscriber, 7);
            assert_eq!(member.key.channel, 1);
            assert_eq!(member.key.connection, CONN_B);

            let mut found = key(CONN_A, 0);
            assert!(slopdesk_host_registry_key_for(handle, slot, 7, &raw mut found));
            assert_eq!(found.connection, CONN_B);

            slopdesk_host_registry_free(handle);
        }
    }

    #[test]
    fn a_reap_takes_every_alias_and_a_short_buffer_takes_none() {
        let handle = slopdesk_host_registry_new();
        let slot = slopdesk_host_slot_mint();
        unsafe {
            slopdesk_host_registry_attach(handle, key(CONN_A, 1), slot, SESSION, 0);
            slopdesk_host_registry_attach(handle, key(CONN_B, 1), slot, SESSION, 7);

            assert_eq!(
                slopdesk_host_registry_keys_for_slot(handle, slot, ptr::null_mut(), 0),
                2,
                "a read door sizes without writing",
            );
            let mut one = [key(CONN_A, 0)];
            assert_eq!(
                slopdesk_host_registry_detach_slot(handle, slot, one.as_mut_ptr(), one.len()),
                2,
                "the mutation reports the size it needs",
            );
            assert!(
                slopdesk_host_registry_slot_is_attached(handle, slot),
                "a refused mutation changed nothing",
            );

            let mut both = [key(CONN_A, 0); 2];
            assert_eq!(
                slopdesk_host_registry_detach_slot(handle, slot, both.as_mut_ptr(), both.len()),
                2,
            );
            assert!(!slopdesk_host_registry_slot_is_attached(handle, slot));
            assert_eq!(slopdesk_host_registry_member_count(handle), 0);

            slopdesk_host_registry_free(handle);
        }
    }

    #[test]
    fn a_link_drop_snapshots_and_removes_only_its_own_connection() {
        let handle = slopdesk_host_registry_new();
        let slot = slopdesk_host_slot_mint();
        unsafe {
            slopdesk_host_registry_attach(handle, key(CONN_A, 1), slot, SESSION, 0);
            slopdesk_host_registry_attach(handle, key(CONN_B, 1), slot, SESSION, 7);

            let mut leaving = [SlopDeskHostMember {
                key: key(CONN_A, 0),
                slot: 0,
                subscriber: 0,
            }];
            assert_eq!(
                slopdesk_host_registry_detach_connection(handle, CONN_A, leaving.as_mut_ptr(), leaving.len()),
                1,
            );
            assert_eq!(leaving[0].subscriber, 0);
            assert_eq!(slopdesk_host_registry_connection_count(handle), 1);
            assert!(slopdesk_host_registry_slot_is_attached(handle, slot));

            slopdesk_host_registry_free(handle);
        }
    }

    #[test]
    fn the_guarded_removal_and_the_join_read_the_same_table() {
        let handle = slopdesk_host_registry_new();
        let first = slopdesk_host_slot_mint();
        let second = slopdesk_host_slot_mint();
        unsafe {
            slopdesk_host_registry_attach(handle, key(CONN_A, 1), first, SESSION, 0);
            assert_eq!(
                slopdesk_host_registry_slot_elsewhere(handle, SESSION, key(CONN_A, 1)),
                0,
                "its own key is not another",
            );
            assert_eq!(
                slopdesk_host_registry_slot_elsewhere(handle, SESSION, key(CONN_B, 1)),
                first,
            );

            slopdesk_host_registry_attach(handle, key(CONN_A, 1), second, SESSION, 0);
            assert!(!slopdesk_host_registry_detach_key_if_slot(
                handle,
                key(CONN_A, 1),
                first
            ));
            assert_eq!(slopdesk_host_registry_slot(handle, key(CONN_A, 1)), second);
            assert_eq!(slopdesk_host_registry_detach_key(handle, key(CONN_A, 1)), second);
            assert_eq!(slopdesk_host_registry_detach_key(handle, key(CONN_A, 1)), 0);

            slopdesk_host_registry_free(handle);
        }
    }

    #[test]
    fn a_drain_reports_each_pane_once_and_a_control_pane_is_not_a_channel() {
        let handle = slopdesk_host_registry_new();
        let slot = slopdesk_host_slot_mint();
        unsafe {
            slopdesk_host_registry_attach(handle, key(CONN_A, 1), slot, SESSION, 0);
            slopdesk_host_registry_attach(handle, key(CONN_B, 1), slot, SESSION, 7);
            slopdesk_host_registry_attach_control(handle, Uuid { bytes: [3; 16] }, 99);

            let mut slots = [0_u64; 4];
            assert_eq!(
                slopdesk_host_registry_drain_panes(handle, slots.as_mut_ptr(), slots.len()),
                1,
                "two channels, one pane",
            );
            assert_eq!(slots[0], slot);
            assert_eq!(slopdesk_host_registry_member_count(handle), 0);

            slopdesk_host_registry_free(handle);
        }
    }

    #[test]
    fn a_hook_sink_is_only_retired_by_its_owner() {
        let handle = slopdesk_host_registry_new();
        unsafe {
            slopdesk_host_registry_register_hook(handle, SESSION, b"pane-1".as_ptr(), 6, 100);
            assert_eq!(
                slopdesk_host_registry_hook_pane(handle, SESSION, ptr::null_mut(), 0),
                6,
            );
            let mut pane = [0_u8; 6];
            assert_eq!(
                slopdesk_host_registry_hook_pane(handle, SESSION, pane.as_mut_ptr(), pane.len()),
                6,
            );
            assert_eq!(&pane, b"pane-1");

            let mut out = [0_u8; 6];
            assert_eq!(
                slopdesk_host_registry_unregister_hook(handle, SESSION, 55, out.as_mut_ptr(), out.len()),
                0,
                "a stale owner retires nothing",
            );
            assert_eq!(slopdesk_host_registry_hook_count(handle), 1);
            assert_eq!(
                slopdesk_host_registry_unregister_hook(handle, SESSION, 100, out.as_mut_ptr(), out.len()),
                6,
            );
            assert_eq!(slopdesk_host_registry_hook_count(handle), 0);

            slopdesk_host_registry_free(handle);
        }
    }

    #[test]
    fn a_project_path_keeps_the_first_id_it_was_given() {
        let handle = slopdesk_host_registry_new();
        unsafe {
            let mut first = Uuid { bytes: [0; 16] };
            slopdesk_host_registry_project_id(
                handle,
                b"/src/app".as_ptr(),
                8,
                Uuid { bytes: [4; 16] },
                &raw mut first,
            );
            assert_eq!(first.bytes, [4; 16]);

            let mut again = Uuid { bytes: [0; 16] };
            slopdesk_host_registry_project_id(
                handle,
                b"/src/app".as_ptr(),
                8,
                Uuid { bytes: [5; 16] },
                &raw mut again,
            );
            assert_eq!(again.bytes, [4; 16], "the mint is once per path");

            slopdesk_host_registry_free(handle);
        }
    }

    #[test]
    fn a_dead_handle_answers_empty_rather_than_faulting() {
        assert_eq!(slopdesk_host_primary_subscriber(), 0);
        unsafe {
            assert_eq!(slopdesk_host_registry_slot(ptr::null_mut(), key(CONN_A, 1)), 0);
            assert_eq!(slopdesk_host_registry_member_count(ptr::null_mut()), 0);
            assert_eq!(slopdesk_host_registry_connection_count(ptr::null_mut()), 0);
            assert!(!slopdesk_host_registry_slot_is_attached(ptr::null_mut(), 1));
            assert!(!slopdesk_host_registry_member(
                ptr::null_mut(),
                key(CONN_A, 1),
                ptr::null_mut()
            ));
            slopdesk_host_registry_attach(ptr::null_mut(), key(CONN_A, 1), 1, SESSION, 0);
            slopdesk_host_registry_free(ptr::null_mut());
        }
    }

    #[test]
    fn a_minted_slot_is_never_zero_and_never_repeats() {
        let first = slopdesk_host_slot_mint();
        let second = slopdesk_host_slot_mint();
        assert_ne!(first, 0, "zero is the no-such-pane answer");
        assert_ne!(first, second);
    }
}
