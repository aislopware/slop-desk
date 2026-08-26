//! The parked-pane store: who may take an entry, what a take owes, and what the daemon stop does
//! to panes it does not own.
//!
//! `slopdesk-muxsession::detach_retention` already pins both RULES — the insert verdict over a list
//! of stamps, and the take verdict over a removal that either found something or did not. What is
//! asked here is everything the rules deliberately refused: the timer, the exclusivity, the
//! ordering of a kill against a lock, and the difference between ending a pane and letting it go.

pub mod support;

use std::sync::Arc;
use std::time::Duration;

use slopdesk_hostserver::{Claim, DetachedStore, IgnoreEvictions, Pane};
use support::{Evictions, Ghost, Now, as_observer, as_pane};

/// A store with kills on the calling thread and nothing watching evictions.
fn store() -> Arc<DetachedStore> {
    Arc::new(DetachedStore::with(
        None,
        Arc::new(Now),
        Arc::new(IgnoreEvictions),
    ))
}

/// A store with a cap and an eviction ledger.
fn capped(cap: usize) -> (Arc<DetachedStore>, Arc<Evictions>) {
    let seen = Arc::new(Evictions::default());
    let store = Arc::new(DetachedStore::with(Some(cap), Arc::new(Now), as_observer(&seen)));
    (store, seen)
}

/// Synchronous by contract: when the insert returns, a reconnect's claim is guaranteed to find the
/// entry. A fire-and-forget insert loses that race and the reconnect spawns a SECOND shell under
/// the same id.
#[test]
fn a_parked_pane_is_claimable_the_instant_the_insert_returns() {
    let store = store();
    let ghost = Ghost::numbered(1);
    let pane = as_pane(&ghost);

    store.insert(&pane, None);

    assert!(store.contains(pane.id()));
    assert_eq!(store.len(), 1);
    let taken = store.claim(pane.id());
    assert_eq!(taken.claimed().map(|held| held.slot()), Some(ghost.slot()));
    assert_eq!(ghost.shutdowns(), 0, "a claim is a hand-off, not an end");
}

/// Exclusivity is the point: of two concurrent reconnects presenting the same id, exactly ONE gets
/// the pane. There is no lookup that does not take.
#[test]
fn only_one_claim_can_ever_win_an_id() {
    let store = store();
    let pane = as_pane(&Ghost::numbered(1));
    store.insert(&pane, None);

    assert!(store.claim(pane.id()).claimed().is_some());
    assert!(matches!(store.claim(pane.id()), Claim::NotFound));
    assert!(store.is_empty());
}

/// A zombie would be reaped when its exit fires, but a client that reconnects first wants a fresh
/// shell rather than a dead one — and the caller must be TOLD, because it has just inherited a
/// teardown the pane's own exit closure stood down from.
#[test]
fn a_claim_on_a_dead_child_reaps_it_and_says_so() {
    let store = store();
    let ghost = Ghost::numbered(1);
    let pane = as_pane(&ghost);
    store.insert(&pane, None);
    ghost.kill_child();

    let taken = store.claim(pane.id());

    assert!(matches!(taken, Claim::ReapedDeadChild(_)));
    assert!(taken.claimed().is_none(), "a reaped pane is not handed over");
    assert_eq!(ghost.shutdowns(), 1);
    assert!(store.is_empty());
}

/// Re-parking a pane the store already holds keeps the ORIGINAL entry and its armed TTL. Both the
/// failed-rebind recovery and the link-down handler can park one pane on a mid-reattach drop, and a
/// second arm beside an entry that already has one is the leak that rule prevents.
#[test]
fn a_re_park_of_the_same_pane_arms_nothing_new() {
    let store = store();
    let pane = as_pane(&Ghost::numbered(1));

    store.insert(&pane, Some(Duration::from_secs(600)));
    assert_eq!(store.armed(), 1);

    store.insert(&pane, Some(Duration::from_secs(600)));
    assert_eq!(store.armed(), 1, "one timer for one entry, not two");
    assert_eq!(store.len(), 1);
}

/// The default is INDEFINITE — the tmux/zellij semantics — so an insert with no TTL arms nothing at
/// all and the thread that would run one never starts.
#[test]
fn a_park_with_no_ttl_arms_nothing() {
    let store = store();

    store.insert(&as_pane(&Ghost::numbered(1)), None);

    assert_eq!(store.armed(), 0);
    assert_eq!(store.len(), 1);
}

/// Same id, DIFFERENT pane: newest wins, and the displaced one is reaped rather than leaked.
#[test]
fn a_displaced_duplicate_is_reaped_when_nobody_holds_it() {
    let store = store();
    let first = Ghost::numbered(1);
    let second = Ghost::numbered(1);
    store.insert(&as_pane(&first), None);

    store.insert(&as_pane(&second), None);

    assert_eq!(first.shutdowns(), 1, "unreachable, so reaped");
    assert_eq!(store.len(), 1);
    assert_eq!(
        store.claim(second.id()).claimed().map(|held| held.slot()),
        Some(second.slot())
    );
}

/// "Should be unreachable" is not a licence to reap blind. A pane with members is live and
/// reachable, and killing it to make room for a store entry would take down a client's agent.
#[test]
fn a_displaced_duplicate_that_someone_still_holds_is_left_alive() {
    let store = store();
    let first = Ghost::numbered(1);
    first.hold(1);
    store.insert(&as_pane(&first), None);

    store.insert(&as_pane(&Ghost::numbered(1)), None);

    assert_eq!(first.shutdowns(), 0, "somebody is watching it");
    assert_eq!(store.len(), 1);
}

/// The OPT-IN cap: the OLDEST by park time is killed to make room, and the server hears about it
/// because a cap eviction never reaches the server's own removal.
#[test]
fn an_overflow_kills_the_oldest_and_reports_it() {
    let (store, seen) = capped(2);
    let oldest = Ghost::numbered(1);
    let middle = Ghost::numbered(2);
    let newest = Ghost::numbered(3);
    store.insert(&as_pane(&oldest), None);
    store.insert(&as_pane(&middle), None);

    store.insert(&as_pane(&newest), None);

    assert_eq!(oldest.shutdowns(), 1);
    assert_eq!(middle.shutdowns(), 0);
    assert_eq!(newest.shutdowns(), 0);
    assert_eq!(
        seen.seen(),
        vec![oldest.id()],
        "the server owes this pane's per-id teardown"
    );
    assert_eq!(store.len(), 2);
}

/// No cap set is UNBOUNDED, which is the default: neither tmux nor zellij ever silently kills a
/// live detached session, and the resource bound in that mode is per-pane.
#[test]
fn an_uncapped_store_never_kills_to_make_room() {
    let store = store();
    let ghosts: Vec<Arc<Ghost>> = (1..=8).map(Ghost::numbered).collect();

    for ghost in &ghosts {
        store.insert(&as_pane(ghost), None);
    }

    assert_eq!(store.len(), 8);
    assert!(ghosts.iter().all(|ghost| ghost.shutdowns() == 0));
}

/// A TTL that fires kills the shell and tells the server, which is the whole reason the store has a
/// timer rather than a flag.
#[test]
fn a_ttl_that_fires_kills_the_pane_and_reports_it() {
    let seen = Arc::new(Evictions::default());
    let store = Arc::new(DetachedStore::with(None, Arc::new(Now), as_observer(&seen)));
    let ghost = Ghost::numbered(1);

    store.insert(&as_pane(&ghost), Some(Duration::from_millis(20)));
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while ghost.shutdowns() == 0 && std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }

    assert_eq!(ghost.shutdowns(), 1);
    assert_eq!(seen.seen(), vec![ghost.id()]);
    assert!(store.is_empty());
    store.stop();
}

/// Once claimed, an armed eviction finds nothing filed and can never kill the PTY out from under
/// the in-flight rebind. The cancellation is what makes the window a miss rather than a kill.
#[test]
fn a_claim_disarms_the_ttl_that_would_have_killed_it() {
    let store = store();
    let ghost = Ghost::numbered(1);
    let pane = as_pane(&ghost);
    store.insert(&pane, Some(Duration::from_millis(20)));

    assert!(store.claim(pane.id()).claimed().is_some());
    assert_eq!(store.armed(), 0, "the hand-off disarmed it");

    std::thread::sleep(Duration::from_millis(80));
    assert_eq!(ghost.shutdowns(), 0, "the eviction that lost kills nothing");
    store.stop();
}

/// An eviction that lost to a reattach removed nothing and must kill nothing — the removal is the
/// latch, and this is where that is spelled.
#[test]
fn an_eviction_that_lost_the_race_kills_nothing() {
    let store = store();
    let ghost = Ghost::numbered(1);
    let pane = as_pane(&ghost);
    store.insert(&pane, None);
    assert!(store.claim(pane.id()).claimed().is_some());

    store.evict(pane.id());

    assert_eq!(ghost.shutdowns(), 0);
}

/// The shell exited while parked: the PTY is already dead, so there is nothing to kill and only the
/// entry to drop.
#[test]
fn a_natural_exit_drops_the_entry_without_killing_anything() {
    let store = store();
    let ghost = Ghost::numbered(1);
    let pane = as_pane(&ghost);
    store.insert(&pane, Some(Duration::from_secs(600)));

    assert!(store.remove(pane.id()), "this call won the teardown");
    assert_eq!(ghost.shutdowns(), 0);
    assert_eq!(store.armed(), 0, "and disarmed the timer that outlived the entry");
    assert!(store.is_empty());
}

/// A stale exit closure firing after somebody else took the entry must stand down, or it releases
/// the journal writer and hook-sink key a same-id SUCCESSOR is already using.
#[test]
fn a_second_removal_loses_and_must_stand_down() {
    let store = store();
    let pane = as_pane(&Ghost::numbered(1));
    store.insert(&pane, None);

    assert!(store.remove(pane.id()));
    assert!(!store.remove(pane.id()), "the loser owns nothing");
}

/// Ordered by park time so the listing is stable rather than map-ordered. A pane whose client quit
/// is ALIVE, and it used to live outside every enumeration the product had.
#[test]
fn the_listing_is_ordered_oldest_first() {
    let store = store();
    let ghosts: Vec<Arc<Ghost>> = (1..=4).map(Ghost::numbered).collect();
    for ghost in &ghosts {
        store.insert(&as_pane(ghost), None);
        std::thread::sleep(Duration::from_millis(2));
    }

    let listed: Vec<[u8; 16]> = store.all().iter().map(|pane| pane.id()).collect();

    assert_eq!(listed, ghosts.iter().map(|ghost| ghost.id()).collect::<Vec<_>>());
}

/// A drain really does mean "end these panes" — a store being torn down for good.
#[test]
fn a_drain_ends_every_parked_pane() {
    let store = store();
    let ghosts: Vec<Arc<Ghost>> = (1..=3).map(Ghost::numbered).collect();
    for ghost in &ghosts {
        store.insert(&as_pane(ghost), Some(Duration::from_secs(600)));
    }

    store.drain_all();

    assert!(ghosts.iter().all(|ghost| ghost.shutdowns() == 1));
    assert!(store.is_empty());
    assert_eq!(store.armed(), 0);
    store.stop();
}

/// The daemon-stop path, and the sharpest edge the old behaviour had: a parked pane is one whose
/// client already left and whose shell the user still WANTS. Killing exactly those on a stop is
/// what `docs/51`'s relinquish exists to stop doing.
#[test]
fn a_stop_lets_every_parked_pane_go_without_killing_one() {
    let store = store();
    let ghosts: Vec<Arc<Ghost>> = (1..=3).map(Ghost::numbered).collect();
    for ghost in &ghosts {
        store.insert(&as_pane(ghost), Some(Duration::from_secs(600)));
    }

    assert!(store.relinquish_all().wait(Duration::from_secs(5)));

    assert!(ghosts.iter().all(|ghost| ghost.relinquishes() == 1));
    assert!(
        ghosts.iter().all(|ghost| ghost.shutdowns() == 0),
        "not one shell died"
    );
    assert!(store.is_empty());
    assert_eq!(store.armed(), 0);
    store.stop();
}

/// A stop with nothing parked completes rather than waiting out its own timeout.
#[test]
fn a_stop_with_nothing_parked_completes_at_once() {
    let store = store();

    assert!(store.relinquish_all().wait(Duration::from_millis(50)));
}

/// The wheel does not flush its queue on the way out. A stop that fired everything still armed
/// would kill exactly the panes a `relinquish_all` had just handed back to superd.
#[test]
fn stopping_the_timer_fires_nothing_it_had_armed() {
    let store = store();
    let ghost = Ghost::numbered(1);
    store.insert(&as_pane(&ghost), Some(Duration::from_millis(20)));

    store.stop();
    std::thread::sleep(Duration::from_millis(80));

    assert_eq!(ghost.shutdowns(), 0);
    assert_eq!(
        store.len(),
        1,
        "still parked; it is the DAEMON that ended, not the pane"
    );
}

/// The wheel is keyed by SESSION id, not by entry, so a displacement's cancel and the successor's
/// arm are one key. Cancelling after arming would leave the store holding a pane whose TTL silently
/// never fires — the thing that made this ordering worth a test rather than a comment.
#[test]
fn a_displacement_leaves_the_successors_ttl_armed() {
    let store = store();
    store.insert(&as_pane(&Ghost::numbered(1)), Some(Duration::from_secs(600)));
    let successor = Ghost::numbered(1);

    store.insert(&as_pane(&successor), Some(Duration::from_secs(600)));

    assert_eq!(store.armed(), 1, "the successor kept its own timer");
    assert_eq!(store.len(), 1);
}

/// And the other half of that key collision: a displacement that arms NOTHING must still take the
/// predecessor's timer with it, or a stale eviction fires against the successor's id.
#[test]
fn a_displacement_that_arms_nothing_still_disarms_the_predecessor() {
    let store = store();
    store.insert(&as_pane(&Ghost::numbered(1)), Some(Duration::from_millis(20)));
    let successor = Ghost::numbered(1);

    store.insert(&as_pane(&successor), None);

    assert_eq!(store.armed(), 0);
    std::thread::sleep(Duration::from_millis(80));
    assert_eq!(
        successor.shutdowns(),
        0,
        "no stale eviction reached the successor"
    );
    assert_eq!(store.len(), 1);
    store.stop();
}
