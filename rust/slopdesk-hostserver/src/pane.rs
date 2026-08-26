//! What the table and the store need of a pane — and deliberately nothing more.
//!
//! `HostSessionRegistry` and `DetachedSessionStore` between them touch a `MuxChannelSession` in
//! exactly six ways: its two identities, whether its child has exited, how many members hold it,
//! and the two ends of its life. Everything else those two files do is bookkeeping ABOUT panes
//! rather than to them. Naming that six-method surface is what lets the retention be driven in a
//! suite: a real [`slopdesk_hostsession::PaneSession`] is a PTY, a superd socket and six threads,
//! and a store test that had to build one would be testing the pane instead of the store.
//!
//! It is the same seam [`slopdesk_hostsession::ScreenOracle`] and
//! [`slopdesk_hostsession::ResolveExecutor`] already are, for the same reason each of those exists:
//! a decision that would otherwise drag a daemon in behind it.

use core::fmt;
use std::sync::Arc;

use slopdesk_muxsession::registry::{Slot, Uuid};

/// One pane, as the composition sees it.
///
/// ## The two identities, and why there are two
/// [`Pane::id`] is the SESSION id — the UUID the client sent in its `channelOpen`, the name of a
/// conversation that survives a disconnect, a reattach and a hostd restart. [`Pane::slot`] is the
/// OBJECT id — minted once per live pane and dead the moment that pane is. They are different
/// questions and conflating them is the bug the detach window exists to make visible: a fresh pane
/// can be minted under an id its predecessor is still winding down on, so "is this the same
/// conversation" and "is this the same pane" have different answers for the length of that window.
/// Every `===` hostd's Swift asks is a slot comparison here.
pub trait Pane: Send + Sync + fmt::Debug {
    /// The session id — the conversation's name, stable across reattach.
    fn id(&self) -> Uuid;

    /// The object id — this pane's identity, minted once and never reused.
    fn slot(&self) -> Slot;

    /// Whether the shell has an exit code already.
    ///
    /// An ALREADY-REAPED exit, not a `waitpid`: an unspawned pane answers `false`, which is the
    /// honest answer rather than an oversight. The store asks it OUTSIDE its own lock — see
    /// [`crate::detached`].
    fn is_child_exited(&self) -> bool;

    /// How many members hold this pane. Zero means nobody is watching it.
    fn member_count(&self) -> usize;

    /// Ends the pane: the child is signalled, waited for, and superd is told the pane is over.
    fn shutdown(&self);

    /// Lets the pane GO without ending it: the child is neither signalled nor waited for, superd
    /// still holds the master, and the next hostd adopts it back. `docs/51`'s line between "this
    /// daemon is going away" and "this pane is over".
    fn relinquish(&self);
}

/// Two panes are the same pane when they are the same OBJECT, which is what the slot is for.
///
/// Spelled as a function rather than `Arc::ptr_eq` on purpose: pointer equality on a `dyn` value
/// compares the vtable as well as the data, and two `Arc<dyn Pane>` handles on one pane can be
/// built through different coercion sites. The slot has no such caveat — it is the identity, and
/// comparing it is what the far side does too.
#[must_use]
pub fn same_pane(left: &Arc<dyn Pane>, right: &Arc<dyn Pane>) -> bool {
    left.slot() == right.slot()
}
