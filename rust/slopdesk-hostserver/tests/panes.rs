//! `docs/60` D.6.5's named hole, filled: the workspace document's live inventory over the server's
//! three pane tables.
//!
//! Every test here is about a fact the PANE cannot supply about itself. A pane knows what it
//! latched; it does not know whether anybody is holding it, which device that is, or what grid the
//! fold resolved across the ones that are — those live in tables the pane cannot see. So what is
//! asserted is the JOIN, in both directions: the liveness byte each inventory decides, and the
//! attachment each member resolves to.
//!
//! The composing rules themselves — the two titles, the freshness verdict, the suppressed agent row
//! — are `slopdesk_hostserver::capture`'s unit tests, because they need no server at all.

pub mod support;

use core::time::Duration;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex, PoisonError};

use slopdesk_hostnet::connection::ChannelOpen;
use slopdesk_hostserver::control::SpawnRefused;
use slopdesk_hostserver::{
    Adopted, DetachedStore, Fresh, Host, HostEnv, HostObserver, HostParts, Offload, Pane, Panes, Peer,
    Spawner, Standalone, WorkspaceChannels,
};
use slopdesk_hostsession::PaneLatches;
use slopdesk_muxsession::registry::{Key, PRIMARY_SUBSCRIBER, Uuid};
use slopdesk_muxsession::resize_fold::Attachment;
use slopdesk_wire::document::fields::PaneLivenessState;
use slopdesk_wire::document::liveness::PaneLiveness;
use slopdesk_wire::workspace::WorkspaceRosterPane;
use support::{Ghost, as_pane};

#[expect(
    clippy::expect_used,
    reason = "a test asserts by panicking, and a fixture it built itself is not a runtime input"
)]
mod suite {
    use super::*;

    // -------------------------------------------------------------------------------- the fakes

    /// A workspace door that can name the client behind a connection.
    ///
    /// The one thing the roster needs of the document side, and the reason it is a fake here: the
    /// real join runs through a subscriber table a `subscribe` fills, and the assertion is about
    /// what the ROSTER does with the answer — including with the absence of one.
    #[derive(Debug, Default)]
    struct Directory {
        names: Mutex<BTreeMap<Uuid, Uuid>>,
    }

    impl Directory {
        fn name(&self, connection: Uuid, client: Uuid) {
            self.names
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .insert(connection, client);
        }
    }

    impl WorkspaceChannels for Directory {
        fn open(&self, _open: Box<ChannelOpen>, _peer: &Arc<dyn Peer>) -> bool {
            false
        }

        fn fact_changed(&self) {}

        fn client_instance(&self, connection: Uuid) -> Option<Uuid> {
            self.names
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .get(&connection)
                .copied()
        }

        fn drop_connection(&self, _connection: Uuid) {}
        fn shutdown(&self) {}
    }

    /// A host that runs everything the moment it is asked, and DEFERS nothing.
    ///
    /// The delayed arm is dropped rather than run inline: the only deferred work this fixture could
    /// schedule is a detach TTL eviction, and running it at once would evict every parked pane
    /// before the inventory could see one. No test here depends on a timer firing.
    #[derive(Debug)]
    struct Inline;

    impl Offload for Inline {
        fn run(&self, work: Box<dyn FnOnce() + Send>) {
            work();
        }

        fn after(&self, _delay: Duration, _work: Box<dyn FnOnce() + Send>) {}
    }

    /// A spawner that refuses: this suite files panes by hand and never asks for one.
    #[derive(Debug)]
    struct Barren;

    impl Spawner for Barren {
        fn spawn(&self, _request: &Standalone<'_>) -> Result<Arc<dyn Pane>, SpawnRefused> {
            Err(SpawnRefused(String::from("this suite files its own panes")))
        }

        fn open(&self, _request: Fresh<'_>) -> Result<Arc<dyn Pane>, SpawnRefused> {
            Err(SpawnRefused(String::from("this suite files its own panes")))
        }

        fn start(&self, _pane: &Arc<dyn Pane>, _cwd: Option<&str>) {}

        fn adopt(&self, _request: Adopted<'_>) -> Result<Arc<dyn Pane>, SpawnRefused> {
            Err(SpawnRefused(String::from("this suite files its own panes")))
        }
    }

    /// A host that says nothing.
    #[derive(Debug)]
    struct Quiet;

    impl HostObserver for Quiet {
        fn connection_count(&self, _count: usize) {}
        fn log(&self, _line: &str) {}
    }

    // ------------------------------------------------------------------------------- the fixture

    struct Bench {
        host: Arc<Host>,
        store: Arc<DetachedStore>,
        directory: Arc<Directory>,
    }

    fn bench() -> Bench {
        let store = Arc::new(DetachedStore::new());
        let directory = Arc::new(Directory::default());
        let host = Host::assemble(HostParts {
            detached: Some(Arc::clone(&store)),
            detach_ttl: Some(Duration::from_secs(60)),
            offload: Arc::new(Inline),
            workspace: Arc::<Directory>::clone(&directory),
            observer: Arc::new(Quiet),
            env: HostEnv {
                parent: BTreeMap::new(),
                term: String::from("xterm-ghostty"),
                version: String::from("9.9.9"),
                shell: String::from("/bin/zsh"),
                agent_socket_path: None,
                control_socket_path: None,
                ctl_binary_path: None,
            },
            ..HostParts::around(Arc::new(Barren))
        });
        Bench {
            host,
            store,
            directory,
        }
    }

    const fn id(byte: u8) -> Uuid {
        let mut id = [0_u8; 16];
        id[0] = byte;
        id
    }

    const fn key(connection: Uuid, channel: u32) -> Key {
        Key::new(connection, channel)
    }

    /// The record for `pane`.
    fn row(host: &Arc<Host>, pane: Uuid) -> PaneLiveness {
        host.capture()
            .into_iter()
            .find(|record| record.pane_id == pane)
            .expect("the capture holds a row for a pane that is filed")
    }

    /// One roster row's attachments, by the client each was named for.
    fn named(record: &WorkspaceRosterPane) -> Vec<(Uuid, bool)> {
        record
            .attachments
            .iter()
            .map(|entry| (entry.client_instance_id, entry.contributes))
            .collect()
    }

    // ------------------------------------------------------------------------ the liveness byte

    #[test]
    fn a_pane_on_a_channel_is_attached() {
        let bench = bench();
        let pane = Ghost::new(id(1));
        bench
            .host
            .sessions()
            .attach_primary(key(id(10), 1), &as_pane(&pane));
        assert_eq!(row(&bench.host, id(1)).liveness, PaneLivenessState::Attached);
    }

    #[test]
    fn a_ctl_spawned_pane_is_detached_rather_than_attached() {
        // Live, running, nobody watching — which is what the client renders as detached. Calling it
        // attached would claim a viewer that does not exist.
        let bench = bench();
        let pane = Ghost::new(id(2));
        bench.host.sessions().attach_control(&as_pane(&pane));
        assert_eq!(row(&bench.host, id(2)).liveness, PaneLivenessState::Detached);
    }

    #[test]
    fn a_parked_pane_is_detached_too() {
        let bench = bench();
        let pane = Ghost::new(id(3));
        bench.store.insert(&as_pane(&pane), None);
        assert_eq!(row(&bench.host, id(3)).liveness, PaneLivenessState::Detached);
    }

    #[test]
    fn an_exited_child_is_dead_wherever_it_is_filed() {
        let bench = bench();
        let attached = Ghost::new(id(4));
        let parked = Ghost::new(id(5));
        attached.kill_child();
        parked.kill_child();
        bench
            .host
            .sessions()
            .attach_primary(key(id(10), 1), &as_pane(&attached));
        bench.store.insert(&as_pane(&parked), None);
        assert_eq!(row(&bench.host, id(4)).liveness, PaneLivenessState::Dead);
        assert_eq!(row(&bench.host, id(5)).liveness, PaneLivenessState::Dead);
    }

    #[test]
    fn the_three_inventories_are_captured_together_and_once_each() {
        let bench = bench();
        let attached = Ghost::new(id(1));
        let control = Ghost::new(id(2));
        let parked = Ghost::new(id(3));
        bench
            .host
            .sessions()
            .attach_primary(key(id(10), 1), &as_pane(&attached));
        bench.host.sessions().attach_control(&as_pane(&control));
        bench.store.insert(&as_pane(&parked), None);
        let captured: Vec<Uuid> = bench.host.capture().iter().map(|record| record.pane_id).collect();
        assert_eq!(captured.len(), 3, "one row per pane, from all three tables");
        assert_eq!(
            captured.iter().copied().collect::<BTreeSet<_>>().len(),
            3,
            "the three tables are disjoint, so nothing is captured twice"
        );
    }

    #[test]
    fn a_fanned_out_pane_is_captured_once_however_many_clients_hold_it() {
        let bench = bench();
        let pane = Ghost::new(id(1));
        bench
            .host
            .sessions()
            .attach_primary(key(id(10), 1), &as_pane(&pane));
        bench.host.sessions().attach(key(id(11), 1), &as_pane(&pane), 7);
        assert_eq!(bench.host.capture().len(), 1, "two keys, one pane, one row");
    }

    // --------------------------------------------------------------------------- the pane's own

    #[test]
    fn the_panes_latches_reach_the_record() {
        let bench = bench();
        let pane = Ghost::new(id(1));
        pane.set_latches(PaneLatches {
            title: String::from("nvim"),
            title_at: Some(50.0),
            cwd: Some(String::from("/repo")),
            project_key: Some(String::from("repo")),
            agent_state: 2,
            agent_kind: 1,
            completion_epoch: 4,
            ..PaneLatches::default()
        });
        bench
            .host
            .sessions()
            .attach_primary(key(id(10), 1), &as_pane(&pane));
        let record = row(&bench.host, id(1));
        assert_eq!(record.live_title.as_deref(), Some("nvim"));
        assert!(record.title_fresh, "no open block, so the title is trusted");
        assert_eq!(record.cwd.as_deref(), Some("/repo"));
        assert_eq!(record.project_key.as_deref(), Some("repo"));
        assert_eq!(record.agent_state.map(|state| state.state), Some(2));
        assert_eq!(record.completion_epoch, 4);
    }

    // ------------------------------------------------------------------------------- the roster

    #[test]
    fn every_member_of_a_fanned_out_pane_is_one_attachment_on_one_row() {
        let bench = bench();
        let pane = Ghost::new(id(1));
        let (mac, phone) = (id(10), id(11));
        bench.directory.name(mac, id(100));
        bench.directory.name(phone, id(101));
        pane.set_attachments((120, 40), vec![
            Attachment {
                subscriber: PRIMARY_SUBSCRIBER,
                contributes: true,
                cols: 120,
                rows: 40,
            },
            Attachment {
                subscriber: 7,
                contributes: false,
                cols: 60,
                rows: 20,
            },
        ]);
        bench.host.sessions().attach_primary(key(mac, 1), &as_pane(&pane));
        bench.host.sessions().attach(key(phone, 1), &as_pane(&pane), 7);

        let roster = bench.host.roster();
        assert_eq!(roster.len(), 1, "one row, however many devices hold the pane");
        let record = roster.first().expect("the pane has a row");
        assert_eq!((record.resolved_cols, record.resolved_rows), (120, 40));
        assert_eq!(
            named(record),
            vec![(id(100), true), (id(101), false)],
            "the mac drives the size and the phone is passive"
        );
    }

    #[test]
    fn a_member_the_directory_cannot_name_still_counts() {
        // `slopdesk-client` opens no workspace channel, so it has no instance id to be named by. It
        // is still a real client holding a real pane at a real size.
        let bench = bench();
        let pane = Ghost::new(id(1));
        pane.set_attachments((80, 24), vec![Attachment {
            subscriber: PRIMARY_SUBSCRIBER,
            contributes: true,
            cols: 80,
            rows: 24,
        }]);
        bench
            .host
            .sessions()
            .attach_primary(key(id(10), 1), &as_pane(&pane));
        let roster = bench.host.roster();
        assert_eq!(
            roster.first().map(named),
            Some(vec![([0; 16], true)]),
            "published under the all-zero id rather than dropped"
        );
    }

    #[test]
    fn a_pane_nobody_is_watching_keeps_its_size_and_lists_nobody() {
        let bench = bench();
        let control = Ghost::new(id(2));
        let parked = Ghost::new(id(3));
        control.set_attachments((100, 30), Vec::new());
        parked.set_attachments((90, 28), Vec::new());
        bench.host.sessions().attach_control(&as_pane(&control));
        bench.store.insert(&as_pane(&parked), None);
        let roster = bench.host.roster();
        let sizes: BTreeMap<Uuid, (u16, u16)> = roster
            .iter()
            .map(|record| (record.pane_id, (record.resolved_cols, record.resolved_rows)))
            .collect();
        assert_eq!(sizes.get(&id(2)).copied(), Some((100, 30)));
        assert_eq!(sizes.get(&id(3)).copied(), Some((90, 28)));
        assert!(
            roster.iter().all(|record| record.attachments.is_empty()),
            "nobody is holding either of them"
        );
    }

    #[test]
    fn the_roster_is_published_in_pane_order() {
        let bench = bench();
        for byte in [3, 1, 2] {
            let pane = Ghost::new(id(byte));
            bench.host.sessions().attach_control(&as_pane(&pane));
        }
        let order: Vec<u8> = bench
            .host
            .roster()
            .iter()
            .map(|record| record.pane_id[0])
            .collect();
        assert_eq!(
            order,
            vec![1, 2, 3],
            "a reshuffle between two identical rosters reads as a change on every device"
        );
    }

    // ------------------------------------------------------------ the two the ladders already own

    #[test]
    fn the_reap_and_the_passivity_re_decision_are_the_hosts_own() {
        // Not re-asserted here — `tests/lifecycle.rs` drives both against the ending ladders. What
        // this pins is that the trait reaches them at all, which a delegation can get wrong.
        let bench = bench();
        let pane = Ghost::new(id(1));
        pane.hold(1);
        bench
            .host
            .sessions()
            .attach_primary(key(id(10), 1), &as_pane(&pane));
        Panes::resolve_size_passivity(&*bench.host, id(10), true);
        assert_eq!(
            pane.contributors(),
            vec![(PRIMARY_SUBSCRIBER, true)],
            "the passivity reached the pane's own fold"
        );
        Panes::reap(&*bench.host, &BTreeSet::from([id(1)]));
        assert_eq!(pane.shutdowns(), 1, "the reap ended the pane");
        assert!(bench.host.capture().is_empty(), "and took its row with it");
    }
}
