//! The two service lifecycles, driven without a child.
//!
//! Every process in here is a [`support::Backend`] and every socket is a closure, which is the
//! point of the seams: a real round is a Node boot and a loopback connect, and a suite that paid
//! for those would be testing code-server rather than the lifecycle around it.
//!
//! Two of these are about the port this crate DEPARTS from the Swift on — the announce recorded
//! while the spawn is still in flight, and the second round that reports `starting` instead of
//! queueing behind the first one's boot. Both are named so.

#![expect(
    clippy::expect_used,
    reason = "a panic in a test is the failure report, not a fault"
)]

pub mod support;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use slopdesk_hostserver::service::{
    AnnouncedPortService, BinaryLocator, Boot, Endpoint, LogSink, PortParser, ProbedPortService,
    ReadinessProbe, SpawnFailed, Spawner, VersionParser,
};
use slopdesk_sidecars::service_lifecycle::ServiceState;
use support::{Backend, as_service};

/// Runs a round for its EFFECT rather than its answer. `drop` cannot say this: an `Endpoint` is
/// `Copy`, so dropping one does nothing and the lint says so.
fn arranged<T>(_answer: T) {}

/// Long enough that a loaded machine does not fail this suite, short enough that a real hang does.
const GENEROUS: Duration = Duration::from_secs(10);

/// An interval no test can cross by accident, for the rounds that must not re-probe.
const NEVER_AGAIN: Duration = Duration::from_secs(3600);

/// A code-server announce line naming `port`.
fn listening(port: u16) -> String {
    format!("[2026-08-26] info  HTTP server listening on http://0.0.0.0:{port}/")
}

/// The last-colon parse those lines want.
fn parse_listening() -> PortParser {
    Arc::new(|line: &str| {
        slopdesk_sidecars::service_lifecycle::port_after_last_colon_following(
            "HTTP server listening on http://",
            line,
        )
    })
}

/// A probe with the answer written on it, and the ledger of how often it was asked.
fn probe(answer: bool) -> (ReadinessProbe, Arc<AtomicUsize>) {
    let asked = Arc::new(AtomicUsize::new(0));
    let ledger = Arc::clone(&asked);
    let probe: ReadinessProbe = Arc::new(move |_port| {
        ledger.fetch_add(1, Ordering::SeqCst);
        answer
    });
    (probe, asked)
}

// MARK: - The OS-picks-the-port lifecycle

#[test]
fn a_round_with_no_child_boots_one_and_reports_starting() {
    let (probe, asked) = probe(true);
    let service = Arc::new(ProbedPortService::new(probe, NEVER_AGAIN));
    let backend = Backend::up();

    let endpoint = service.ensure(|_generation| Boot::Spawned(as_service(&backend)));

    assert_eq!(endpoint, Endpoint::nothing(ServiceState::Starting));
    assert_eq!(
        asked.load(Ordering::SeqCst),
        0,
        "nothing to probe until a port is announced"
    );
}

#[test]
fn a_child_with_no_announced_port_stays_starting() {
    let (probe, asked) = probe(true);
    let service = Arc::new(ProbedPortService::new(probe, NEVER_AGAIN));
    let backend = Backend::up();
    arranged(service.ensure(|_generation| Boot::Spawned(as_service(&backend))));

    let endpoint = service.ensure(|_generation| Boot::NotYet(ServiceState::Unavailable));

    assert_eq!(endpoint, Endpoint::nothing(ServiceState::Starting));
    assert_eq!(asked.load(Ordering::SeqCst), 0);
    assert_eq!(service.served_port(), None);
}

#[test]
fn an_announced_port_is_probed_once_and_latches_ready() {
    let (probe, asked) = probe(true);
    let service = Arc::new(ProbedPortService::new(probe, NEVER_AGAIN));
    let backend = Backend::up();
    arranged(service.ensure(|generation| {
        let sink = service.port_sink(generation, None, parse_listening());
        sink(&listening(62636));
        Boot::Spawned(as_service(&backend))
    }));

    let first = service.ensure(|_generation| Boot::NotYet(ServiceState::Unavailable));
    let second = service.ensure(|_generation| Boot::NotYet(ServiceState::Unavailable));

    assert_eq!(first, Endpoint {
        state: ServiceState::Ready,
        port: 62636,
    },);
    assert_eq!(second, first, "a listening server is never un-probed");
    assert_eq!(
        asked.load(Ordering::SeqCst),
        1,
        "the latch is what keeps a ready service off the syscall",
    );
    assert_eq!(service.served_port(), Some(62636));
}

#[test]
fn a_failed_probe_is_not_re_run_before_its_interval() {
    let (probe, asked) = probe(false);
    let service = Arc::new(ProbedPortService::new(probe, NEVER_AGAIN));
    let backend = Backend::up();
    arranged(service.ensure(|generation| {
        let sink = service.port_sink(generation, None, parse_listening());
        sink(&listening(4100));
        Boot::Spawned(as_service(&backend))
    }));

    let first = service.ensure(|_generation| Boot::NotYet(ServiceState::Unavailable));
    let second = service.ensure(|_generation| Boot::NotYet(ServiceState::Unavailable));

    assert_eq!(first, Endpoint {
        state: ServiceState::Starting,
        port: 4100,
    },);
    assert_eq!(second, first);
    assert_eq!(asked.load(Ordering::SeqCst), 1, "the second round was not due");
}

#[test]
fn an_exited_child_is_dropped_and_the_next_round_boots() {
    let (probe, _asked) = probe(true);
    let service = Arc::new(ProbedPortService::new(probe, NEVER_AGAIN));
    let first = Backend::up();
    arranged(service.ensure(|generation| {
        let sink = service.port_sink(generation, None, parse_listening());
        sink(&listening(5000));
        Boot::Spawned(as_service(&first))
    }));
    first.die();

    let second = Backend::up();
    let booted = Arc::new(AtomicUsize::new(0));
    let counted = Arc::clone(&booted);
    let endpoint = service.ensure(move |_generation| {
        counted.fetch_add(1, Ordering::SeqCst);
        Boot::Spawned(as_service(&second))
    });

    assert_eq!(booted.load(Ordering::SeqCst), 1, "crash recovery needs no reaper");
    assert_eq!(endpoint, Endpoint::nothing(ServiceState::Starting));
    assert_eq!(
        service.served_port(),
        None,
        "the dead child's port must not be served as the fresh one's",
    );
}

#[test]
fn a_boot_that_produced_no_child_leaves_nothing_behind() {
    let (probe, _asked) = probe(true);
    let service = Arc::new(ProbedPortService::new(probe, NEVER_AGAIN));

    let refused = service.ensure(|_generation| Boot::NotYet(ServiceState::Unavailable));
    let booted = Arc::new(AtomicUsize::new(0));
    let counted = Arc::clone(&booted);
    let backend = Backend::up();
    arranged(service.ensure(move |_generation| {
        counted.fetch_add(1, Ordering::SeqCst);
        Boot::Spawned(as_service(&backend))
    }));

    assert_eq!(refused, Endpoint::nothing(ServiceState::Unavailable));
    assert_eq!(
        booted.load(Ordering::SeqCst),
        1,
        "the next round must try again rather than observe a phantom",
    );
}

/// A dying child's last words must not land on its successor's record.
#[test]
fn a_line_from_a_superseded_generation_is_ignored() {
    let (probe, _asked) = probe(true);
    let service = Arc::new(ProbedPortService::new(probe, NEVER_AGAIN));
    let first = Backend::up();
    let stale = Arc::new(Mutex::new(None::<LogSink>));
    let kept = Arc::clone(&stale);
    arranged(service.ensure(|generation| {
        let sink = service.port_sink(generation, None, parse_listening());
        if let Ok(mut kept) = kept.lock() {
            *kept = Some(sink);
        }
        Boot::Spawned(as_service(&first))
    }));
    first.die();

    let second = Backend::up();
    arranged(service.ensure(|_generation| Boot::Spawned(as_service(&second))));
    let stale = stale
        .lock()
        .ok()
        .and_then(|sink| sink.clone())
        .expect("a sink was kept");
    stale(&listening(9999));

    assert_eq!(service.served_port(), None, "the old generation writes nothing");
}

#[test]
fn the_first_announced_port_wins() {
    let (probe, _asked) = probe(true);
    let service = Arc::new(ProbedPortService::new(probe, NEVER_AGAIN));
    let backend = Backend::up();

    arranged(service.ensure(|generation| {
        let sink = service.port_sink(generation, None, parse_listening());
        sink(&listening(3000));
        sink(&listening(4000));
        Boot::Spawned(as_service(&backend))
    }));

    assert_eq!(
        service.served_port(),
        Some(3000),
        "the child announces once; a later line carrying the marker is not a new fact",
    );
}

/// The DEPARTURE, and the reason for it: the Swift's record did not exist until the spawn returned,
/// so a line that arrived during it was dropped. That is not a corner — an adopt replays the
/// survivor's ring from offset 0 and hands the announce line back inside exactly that window.
#[test]
fn a_line_that_arrives_during_the_spawn_is_recorded() {
    let (probe, _asked) = probe(true);
    let service = Arc::new(ProbedPortService::new(probe, NEVER_AGAIN));
    let backend = Backend::up();

    let endpoint = service.ensure(|generation| {
        // Inside the boot, before any handle exists — where an adopt's replayed line lands.
        let sink = service.port_sink(generation, None, parse_listening());
        sink(&listening(8080));
        Boot::Spawned(as_service(&backend))
    });

    assert_eq!(endpoint, Endpoint::nothing(ServiceState::Starting));
    assert_eq!(service.served_port(), Some(8080));
}

/// The other departure: two panes' metadata rounds race, and the second must not wait out the
/// first's Node boot. It reports `starting`, which is exactly true, and it must not spawn a twin.
#[test]
fn a_second_round_during_a_boot_reports_starting_without_spawning_a_twin() {
    let (probe, _asked) = probe(true);
    let service = Arc::new(ProbedPortService::new(probe, NEVER_AGAIN));
    let backend = Backend::up();
    let booted = Arc::new(AtomicUsize::new(0));

    let (entered, arrived): (Sender<()>, Receiver<()>) = channel();
    let (release, wait): (Sender<()>, Receiver<()>) = channel();

    let slow = Arc::clone(&service);
    let counted = Arc::clone(&booted);
    let joined = thread::spawn(move || {
        slow.ensure(move |_generation| {
            counted.fetch_add(1, Ordering::SeqCst);
            entered.send(()).expect("the test is listening");
            wait.recv().expect("the test releases the boot");
            Boot::Spawned(as_service(&backend))
        })
    });

    arrived.recv_timeout(GENEROUS).expect("the boot starts");
    let counted = Arc::clone(&booted);
    let racing = service.ensure(move |_generation| {
        counted.fetch_add(1, Ordering::SeqCst);
        Boot::NotYet(ServiceState::Unavailable)
    });
    release.send(()).expect("the boot is waiting");
    let first = joined.join().expect("the boot thread finishes");

    assert_eq!(racing, Endpoint::nothing(ServiceState::Starting));
    assert_eq!(first, Endpoint::nothing(ServiceState::Starting));
    assert_eq!(
        booted.load(Ordering::SeqCst),
        1,
        "the second round must neither spawn a twin nor queue behind the first",
    );
}

#[test]
fn a_forget_answers_the_handle_and_closes_the_record() {
    let (probe, _asked) = probe(true);
    let service = Arc::new(ProbedPortService::new(probe, NEVER_AGAIN));
    let backend = Backend::up();
    arranged(service.ensure(|generation| {
        let sink = service.port_sink(generation, None, parse_listening());
        sink(&listening(7000));
        Boot::Spawned(as_service(&backend))
    }));

    let stranded = service.forget().expect("the record held a handle");
    stranded.relinquish();

    assert_eq!(backend.relinquishes(), 1);
    assert_eq!(service.served_port(), None);
    assert!(
        service.forget().is_none(),
        "a second forget has nothing to answer"
    );
}

// MARK: - The hostd-picks-the-port lifecycle

/// A spawner that answers the ports in `announce`, one per launch, and counts its launches.
///
/// A `None` entry is a daemon that never spoke: the sink is not called at all, and the wait below
/// runs its whole bound.
fn spawner(announce: Vec<Option<u16>>, backend: &Arc<Backend>) -> (Spawner, Arc<AtomicUsize>) {
    let launches = Arc::new(AtomicUsize::new(0));
    let counted = Arc::clone(&launches);
    let handle = Arc::clone(backend);
    let spawner: Spawner = Arc::new(move |_binary, _arguments, sink: LogSink| {
        let index = counted.fetch_add(1, Ordering::SeqCst);
        if let Some(Some(port)) = announce.get(index) {
            sink(&listening(*port));
        }
        Ok(as_service(&handle))
    });
    (spawner, launches)
}

/// A locator that finds one.
fn locator() -> BinaryLocator {
    Arc::new(|| Some("/usr/local/bin/slopdesk-inspectord".to_owned()))
}

/// Short enough that the give-up path costs the suite nothing.
const IMPATIENT: Duration = Duration::from_millis(60);

#[test]
fn a_daemon_on_the_wanted_port_is_adopted() {
    let backend = Backend::up();
    let (spawn, launches) = spawner(vec![Some(7777)], &backend);
    let service = Arc::new(AnnouncedPortService::new(
        spawn,
        locator(),
        parse_listening(),
        None,
        IMPATIENT,
    ));

    let served = service.start(7777, &[]);

    assert_eq!(served, Some(7777));
    assert_eq!(launches.load(Ordering::SeqCst), 1);
    assert_eq!(backend.terminates(), 0);
    assert_eq!(service.served_port(), Some(7777));
}

#[test]
fn a_daemon_on_the_wrong_port_is_ended_and_relaunched_once() {
    let backend = Backend::up();
    let (spawn, launches) = spawner(vec![Some(1111), Some(7777)], &backend);
    let service = Arc::new(AnnouncedPortService::new(
        spawn,
        locator(),
        parse_listening(),
        None,
        IMPATIENT,
    ));

    let served = service.start(7777, &[]);

    assert_eq!(served, Some(7777));
    assert_eq!(launches.load(Ordering::SeqCst), 2);
    assert_eq!(
        backend.terminates(),
        1,
        "a survivor of a hostd that wanted another port is ended, not adopted",
    );
}

#[test]
fn a_daemon_that_never_speaks_twice_is_given_up_on() {
    let backend = Backend::up();
    let (spawn, launches) = spawner(vec![None, None], &backend);
    let service = Arc::new(AnnouncedPortService::new(
        spawn,
        locator(),
        parse_listening(),
        None,
        IMPATIENT,
    ));

    let served = service.start(7777, &[]);

    assert_eq!(served, None, "a sidecar that never came up is not fatal to hostd");
    assert_eq!(
        launches.load(Ordering::SeqCst),
        2,
        "the rule bounds the loop, not a count here"
    );
    assert_eq!(backend.terminates(), 2);
}

#[test]
fn a_host_with_no_binary_never_spawns() {
    let backend = Backend::up();
    let (spawn, launches) = spawner(vec![Some(7777)], &backend);
    let service = Arc::new(AnnouncedPortService::new(
        spawn,
        Arc::new(|| None),
        parse_listening(),
        None,
        IMPATIENT,
    ));

    assert_eq!(service.start(7777, &[]), None);
    assert_eq!(launches.load(Ordering::SeqCst), 0);
}

#[test]
fn the_version_rides_the_same_line_as_the_port() {
    let backend = Backend::up();
    let announce: Spawner = {
        let handle = Arc::clone(&backend);
        Arc::new(move |_binary, _arguments, sink: LogSink| {
            sink("inspectord listening on 127.0.0.1:7777 (v0.42.1, sha deadbeef)");
            Ok(as_service(&handle))
        })
    };
    let port: PortParser = Arc::new(|line: &str| {
        slopdesk_sidecars::service_lifecycle::port_directly_after("listening on 127.0.0.1:", line)
    });
    let version: VersionParser = Arc::new(|line: &str| {
        slopdesk_sidecars::service_lifecycle::announced_version("listening on 127.0.0.1:", "(v", line)
            .map(str::to_owned)
    });
    let service = Arc::new(AnnouncedPortService::new(
        announce,
        locator(),
        port,
        Some(version),
        IMPATIENT,
    ));

    assert_eq!(service.start(7777, &[]), Some(7777));
    assert_eq!(
        service.announced_version(),
        Some("0.42.1".to_owned()),
        "the version must be recorded before the port, or the wait misses it",
    );
}

#[test]
fn a_relinquish_lets_the_daemon_go_and_a_shutdown_ends_it() {
    let backend = Backend::up();
    let (spawn, _launches) = spawner(vec![Some(7777)], &backend);
    let service = Arc::new(AnnouncedPortService::new(
        spawn,
        locator(),
        parse_listening(),
        None,
        IMPATIENT,
    ));
    arranged(service.start(7777, &[]));

    service.relinquish();

    assert_eq!(backend.relinquishes(), 1);
    assert_eq!(backend.terminates(), 0);
    assert_eq!(service.served_port(), None, "hostd stopped listening to it");
    service.shutdown();
    assert_eq!(backend.terminates(), 0, "there is nothing left to end");
}

#[test]
fn a_spawn_that_fails_is_not_retried_into_a_loop() {
    let refusing: Spawner = Arc::new(|_binary, _arguments, _sink| {
        Err(SpawnFailed {
            reason: "superd is not running".to_owned(),
        })
    });
    let service = Arc::new(AnnouncedPortService::new(
        refusing,
        locator(),
        parse_listening(),
        None,
        IMPATIENT,
    ));

    assert_eq!(service.start(7777, &[]), None);
}
