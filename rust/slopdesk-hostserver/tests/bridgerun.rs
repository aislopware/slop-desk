//! The workbench's `run` against a REAL pane table.
//!
//! `bridge_router`'s own suite already proves the choice on synthetic rows, and `tests/bridge.rs`
//! already proves the socket carries a runner's answer back. Neither could catch the thing that had
//! actually been broken since stage E, which is that no runner was ever installed — nor the three
//! joins between them: which panes become candidates, that a pane's handle survives the gap between
//! the choice and the write, and that the keystrokes reach the PTY the router named rather than the
//! first one in the table.
//!
//! Every case here asserts by `assert!`, so this file needs no lint exemption: the fixtures are
//! built in-process and nothing in it can fail in a way that is not the assertion failing.

pub mod support;

use std::collections::BTreeMap;
use std::sync::Arc;

use slopdesk_hostserver::bridgerun::terminal_runner;
use slopdesk_hostserver::control::SpawnRefused;
use slopdesk_hostserver::{Adopted, Fresh, Host, HostEnv, HostParts, Pane, Spawner, Standalone};
use slopdesk_muxsession::bridge_router::{Refusal, RunRequest};
use slopdesk_muxsession::registry::{Key, Uuid};
use support::{Ghost, as_pane};

/// A spawner that refuses: this suite files its panes by hand.
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

fn host() -> Arc<Host> {
    Host::assemble(HostParts {
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
    })
}

const fn id(byte: u8) -> Uuid {
    let mut bytes = [0_u8; 16];
    bytes[15] = byte;
    bytes
}

/// A pane sitting at a `zsh` prompt in `cwd`, ATTACHED to the host under its own key.
fn attached(host: &Arc<Host>, byte: u8, cwd: &str, title: &str) -> Arc<Ghost> {
    let ghost = Ghost::numbered(byte);
    ghost.set_cwd(Some(cwd));
    ghost.set_foreground("zsh");
    ghost.set_title(title);
    host.sessions()
        .attach_primary(Key::new(id(byte), 1), &as_pane(&ghost));
    ghost
}

fn asking(root: &str, text: &str) -> RunRequest {
    RunRequest {
        id: String::from("r1"),
        root: String::from(root),
        directory: None,
        text: String::from(text),
    }
}

#[test]
fn the_command_is_typed_into_the_project_pane_and_the_editor_is_told_which() {
    let host = host();
    let elsewhere = attached(&host, 1, "/work/other", "other");
    let here = attached(&host, 2, "/work/thing/src", "thing — src");
    let outcome = terminal_runner(&host)(&asking("/work/thing", "cargo test"));
    assert!(outcome.ok, "{outcome:?}");
    assert_eq!(outcome.pane_title.as_deref(), Some("thing — src"));
    assert_eq!(here.written(), b"cargo test\r".to_vec());
    // The pane of another project is not a fallback: a command typed into the wrong project is
    // worse than one that was refused, because it RAN.
    assert!(elsewhere.written().is_empty());
}

#[test]
fn a_project_with_no_pane_open_is_refused_in_words_the_editor_can_show() {
    let host = host();
    let _elsewhere = attached(&host, 1, "/work/other", "other");
    let outcome = terminal_runner(&host)(&asking("/work/thing", "cargo test"));
    assert!(!outcome.ok, "{outcome:?}");
    assert_eq!(
        outcome.message.as_deref(),
        Some(Refusal::NoPaneInProject.message()),
    );
}

#[test]
fn a_pane_running_something_is_busy_and_the_refusal_says_so() {
    let host = host();
    let busy = attached(&host, 1, "/work/thing", "thing");
    busy.set_foreground("vim");
    let outcome = terminal_runner(&host)(&asking("/work/thing", "cargo test"));
    assert!(!outcome.ok, "{outcome:?}");
    assert_eq!(outcome.message.as_deref(), Some(Refusal::NoIdlePane.message()),);
    assert!(busy.written().is_empty());
}

#[test]
fn an_agents_pane_is_never_typed_into_even_when_it_is_the_only_one() {
    // The pane's foreground is a shell — the agent is what makes it off-limits, and the two are
    // separate bits for exactly this case.
    let host = host();
    let agents = attached(&host, 1, "/work/thing", "thing");
    agents.set_present(true);
    let outcome = terminal_runner(&host)(&asking("/work/thing", "cargo test"));
    assert!(!outcome.ok, "{outcome:?}");
    assert!(agents.written().is_empty());
}

#[test]
fn a_pane_whose_child_already_exited_is_not_a_candidate() {
    let host = host();
    let dead = attached(&host, 1, "/work/thing", "thing");
    dead.kill_child();
    let outcome = terminal_runner(&host)(&asking("/work/thing", "cargo test"));
    assert!(!outcome.ok, "{outcome:?}");
    assert_eq!(
        outcome.message.as_deref(),
        Some(Refusal::NoPaneInProject.message()),
    );
    assert!(dead.written().is_empty());
}

#[test]
fn a_pane_watched_by_three_clients_is_one_candidate_and_is_typed_into_once() {
    // A fanned-out pane is N members and ONE pane. The bug this pins is not a wrong choice but
    // a right one made three times — `cargo test` typed thrice at one prompt.
    let host = host();
    let shared = Ghost::numbered(1);
    shared.set_cwd(Some("/work/thing"));
    shared.set_foreground("zsh");
    shared.set_title("thing");
    host.sessions()
        .attach_primary(Key::new(id(1), 1), &as_pane(&shared));
    for connection in 2..=3_u8 {
        host.sessions().attach(
            Key::new(id(connection), 1),
            &as_pane(&shared),
            u64::from(connection),
        );
    }
    let outcome = terminal_runner(&host)(&asking("/work/thing", "ls"));
    assert!(outcome.ok, "{outcome:?}");
    assert_eq!(shared.written(), b"ls\r".to_vec());
}

#[test]
fn a_host_that_is_gone_refuses_rather_than_reaching_through_a_dangling_handle() {
    // The runner outlives the host by construction — the bridge server is the panel table's,
    // not the host's — so the weak handle is the whole guard, and this is what proves it holds.
    let runner = {
        let host = host();
        attached(&host, 1, "/work/thing", "thing");
        terminal_runner(&host)
    };
    let outcome = runner(&asking("/work/thing", "cargo test"));
    assert!(!outcome.ok, "{outcome:?}");
    assert_eq!(
        outcome.message.as_deref(),
        Some(Refusal::NoPaneInProject.message()),
    );
}
