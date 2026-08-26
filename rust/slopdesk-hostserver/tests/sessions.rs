//! The session table: what it holds, what it releases, and the identity guards on both.
//!
//! `slopdesk-muxsession`'s own suite already pins every RELATION — which key names which slot, what
//! a reap takes, how a drain orders itself. What is asked here is the half that only exists once a
//! caller holds the objects: when the `Arc` is dropped, when it is kept, and which pane comes back.

pub mod support;

use std::sync::Arc;

use slopdesk_hostserver::{Held, Pane, Sessions};
use slopdesk_muxsession::registry::{Key, PRIMARY_SUBSCRIBER};
use support::{Ghost, as_pane};

/// A connection id from one byte, so a test can name two without spelling thirty-two.
const fn conn(id: u8) -> [u8; 16] {
    let mut bytes = [0_u8; 16];
    bytes[15] = id;
    bytes
}

#[test]
fn a_key_answers_the_pane_it_was_attached_under() {
    let mut table = Sessions::new();
    let ghost = Ghost::numbered(1);
    let pane = as_pane(&ghost);
    let key = Key::new(conn(1), 1);

    table.attach_primary(key, &pane);

    assert_eq!(table.pane(key).map(|held| held.slot()), Some(ghost.slot()));
    assert_eq!(table.subscriber_of(key), PRIMARY_SUBSCRIBER);
    assert_eq!(table.member_count(), 1);
    assert_eq!(table.connection_count(), 1);
}

/// An unregistered key reads as the primary, which is what every caller that reaches this without a
/// pane does with the answer anyway.
#[test]
fn an_unregistered_key_reads_as_the_primary_subscriber() {
    let table = Sessions::new();

    assert!(table.pane(Key::new(conn(9), 3)).is_none());
    assert_eq!(table.subscriber_of(Key::new(conn(9), 3)), PRIMARY_SUBSCRIBER);
}

/// A fanned-out pane is ONE object under N keys, so the object survives the first client leaving
/// and dies with the last.
#[test]
fn the_object_is_released_only_when_its_last_channel_is_gone() {
    let mut table = Sessions::new();
    let ghost = Ghost::numbered(1);
    let pane = as_pane(&ghost);
    let first = Key::new(conn(1), 1);
    let second = Key::new(conn(2), 1);

    table.attach_primary(first, &pane);
    table.attach(second, &pane, 7);
    assert_eq!(table.live_panes().len(), 1, "one object, not two");

    assert_eq!(table.detach(first).map(|held| held.slot()), Some(ghost.slot()));
    assert!(table.is_attached(&pane), "the second client still holds it");
    assert_eq!(table.pane(second).map(|held| held.slot()), Some(ghost.slot()));

    assert!(table.detach(second).is_some());
    assert!(!table.is_attached(&pane));
    assert!(table.live_panes().is_empty());
}

/// The identity guard. A detach window can mint a fresh pane under a key its predecessor is still
/// winding down on, and an unguarded removal unregisters the LIVE successor.
#[test]
fn a_guarded_detach_refuses_to_unregister_a_successor() {
    let mut table = Sessions::new();
    let key = Key::new(conn(1), 1);
    let ghost = Ghost::numbered(1);
    let departing = as_pane(&ghost);
    table.attach_primary(key, &departing);

    // The same conversation, a NEW object — which is what a reattach mints.
    let successor = as_pane(&Ghost::numbered(1));
    table.attach_primary(key, &successor);

    assert!(
        !table.detach_if_names(key, &departing),
        "the stale teardown stands down"
    );
    assert_eq!(table.pane(key).map(|held| held.slot()), Some(successor.slot()));

    assert!(table.detach_if_names(key, &successor));
    assert!(table.pane(key).is_none());
}

/// Leaving an alias behind keeps a dead pane in every enumeration hostd has: the ctl listing, the
/// stop drain, the rebind scan.
#[test]
fn a_reap_takes_every_key_that_named_the_pane() {
    let mut table = Sessions::new();
    let pane = as_pane(&Ghost::numbered(1));
    let keys = [Key::new(conn(1), 1), Key::new(conn(2), 1), Key::new(conn(2), 4)];
    for (index, key) in keys.iter().enumerate() {
        table.attach(*key, &pane, index as u64);
    }
    assert_eq!(table.keys_naming(&pane).len(), 3);

    let doomed = table.reap(&pane);

    assert_eq!(doomed.len(), 3);
    assert_eq!(table.member_count(), 0);
    assert!(table.live_panes().is_empty(), "the object goes with the last key");
}

/// The link-drop snapshot. The removal lands BEFORE the caller retires anything, so a racing
/// `channelOpen` cannot find a member of a connection that is already gone.
#[test]
fn a_link_drop_takes_that_connections_members_and_leaves_the_others() {
    let mut table = Sessions::new();
    let leaving = as_pane(&Ghost::numbered(1));
    let staying = as_pane(&Ghost::numbered(2));
    table.attach_primary(Key::new(conn(1), 1), &leaving);
    table.attach_primary(Key::new(conn(1), 2), &staying);
    table.attach(Key::new(conn(2), 1), &staying, 5);

    let gone: Vec<Held> = table.detach_all_on(conn(1));

    assert_eq!(gone.len(), 2);
    assert_eq!(table.member_count(), 1);
    assert_eq!(table.connection_count(), 1);
    // The fanned-out pane kept its OTHER connection, so its object is still held.
    assert!(table.is_attached(&staying));
    assert!(!table.is_attached(&leaving));
    assert_eq!(table.live_panes().len(), 1);
}

/// A fanned-out pane is N members and ONE pane: an enumeration that repeated it would shut the same
/// PTY N times.
#[test]
fn the_live_enumeration_never_repeats_a_fanned_out_pane() {
    let mut table = Sessions::new();
    let pane = as_pane(&Ghost::numbered(1));
    table.attach_primary(Key::new(conn(1), 1), &pane);
    table.attach(Key::new(conn(2), 1), &pane, 1);
    table.attach(Key::new(conn(3), 1), &pane, 2);

    assert_eq!(table.member_count(), 3);
    assert_eq!(table.live_panes().len(), 1);
    assert_eq!(table.connection_count(), 3);
}

/// The join question: is this conversation already live somewhere ELSE?
#[test]
fn the_join_question_excludes_the_asking_key() {
    let mut table = Sessions::new();
    let ghost = Ghost::numbered(4);
    let pane = as_pane(&ghost);
    let held = Key::new(conn(1), 1);
    table.attach_primary(held, &pane);

    assert!(
        table.pane_elsewhere(pane.id(), held).is_none(),
        "its own key is not elsewhere"
    );
    let asking = Key::new(conn(2), 1);
    assert_eq!(
        table.pane_elsewhere(pane.id(), asking).map(|found| found.slot()),
        Some(ghost.slot())
    );
    assert_eq!(
        table.pane_for_session(pane.id()).map(|found| found.slot()),
        Some(ghost.slot())
    );
}

#[test]
fn a_drain_empties_the_table_and_answers_every_distinct_pane() {
    let mut table = Sessions::new();
    let first = as_pane(&Ghost::numbered(1));
    let second = as_pane(&Ghost::numbered(2));
    table.attach_primary(Key::new(conn(1), 1), &first);
    table.attach(Key::new(conn(2), 1), &first, 1);
    table.attach_primary(Key::new(conn(1), 2), &second);

    let drained = table.drain_panes();

    assert_eq!(drained.len(), 2, "two panes, three members");
    assert_eq!(table.member_count(), 0);
    assert!(table.live_panes().is_empty());
}

/// A `ctl`-spawned pane holds no channel and no connection, so it lives in its own map and never
/// appears in the channel enumerations.
#[test]
fn a_control_pane_is_kept_apart_from_the_channel_panes() {
    let mut table = Sessions::new();
    let ghost = Ghost::numbered(7);
    let pane = as_pane(&ghost);

    table.attach_control(&pane);

    assert_eq!(
        table.control_pane(pane.id()).map(|found| found.slot()),
        Some(ghost.slot())
    );
    assert_eq!(table.control_panes().len(), 1);
    assert_eq!(table.member_count(), 0, "it is on no channel");
    assert!(table.live_panes().is_empty());

    assert_eq!(
        table.detach_control(pane.id()).map(|found| found.slot()),
        Some(ghost.slot())
    );
    assert!(table.detach_control(pane.id()).is_none(), "idempotent");
}

#[test]
fn a_control_drain_empties_the_standalone_map() {
    let mut table = Sessions::new();
    table.attach_control(&as_pane(&Ghost::numbered(1)));
    table.attach_control(&as_pane(&Ghost::numbered(2)));

    assert_eq!(table.drain_control().len(), 2);
    assert!(table.control_panes().is_empty());
}

/// The pane id is the one baked into the child's environment and is immutable for the shell's life:
/// a per-reattach key could never route AND would leak one dead sink per wifi flap.
#[test]
fn a_rebind_re_points_the_hook_without_moving_where_it_routes() {
    let mut table = Sessions::new();
    let spawned = as_pane(&Ghost::numbered(3));
    table.register_hook(&spawned, "pane-abc");
    assert_eq!(table.hook_count(), 1);

    // The reattach mints a NEW object for the same conversation.
    let successor = as_pane(&Ghost::numbered(3));
    assert_eq!(table.rebind_hook(&successor).as_deref(), Some("pane-abc"));
    assert_eq!(table.hook_count(), 1, "one sink, not one per reattach");

    // The stale predecessor no longer owns the entry, so its teardown stands down.
    assert!(table.unregister_hook(&spawned).is_none());
    assert_eq!(table.hook_count(), 1);
    assert_eq!(table.unregister_hook(&successor).as_deref(), Some("pane-abc"));
    assert_eq!(table.hook_count(), 0);
}

/// A pane spawned with hooks OFF has no sink to re-point, and a rebind must say so rather than
/// inventing one.
#[test]
fn a_rebind_with_no_sink_answers_nothing() {
    let mut table = Sessions::new();

    assert!(table.rebind_hook(&as_pane(&Ghost::numbered(1))).is_none());
    assert_eq!(table.hook_count(), 0);
}

/// Minting is the caller's, deciding is the registry's: a path that already has an id keeps it and
/// the candidate is discarded.
#[test]
fn a_project_path_keeps_the_first_id_it_was_given() {
    let mut table = Sessions::new();
    let first = table.project_id("/repo", conn(1));

    assert_eq!(first, conn(1));
    assert_eq!(
        table.project_id("/repo", conn(2)),
        conn(1),
        "the candidate is discarded"
    );
    assert_eq!(table.project_id("/other", conn(2)), conn(2));
    assert_eq!(table.project_count(), 2);
}

/// Two `Arc` handles built at different coercion sites are still one pane, which is what the slot
/// is for — and the reason the comparison is not `Arc::ptr_eq`.
#[test]
fn identity_is_the_slot_and_not_the_pointer() {
    let ghost = Ghost::numbered(1);
    let one: Arc<dyn Pane> = Arc::<Ghost>::clone(&ghost);
    let other: Arc<dyn Pane> = Arc::<Ghost>::clone(&ghost);

    assert!(slopdesk_hostserver::same_pane(&one, &other));
    assert!(!slopdesk_hostserver::same_pane(
        &one,
        &as_pane(&Ghost::numbered(1))
    ));
}
