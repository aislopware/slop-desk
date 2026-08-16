//! The idle exit — an engine nobody is talking to must not outlive the process that started it.
//!
//! This is the one screend behaviour that cannot be tested through `serve_request`: it is about the
//! PROCESS, so the test runs the real binary. The timeout is set to a second through the env var,
//! which is also what pins the var's spelling from the outside.

#![expect(
    clippy::expect_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]

use std::io::Write as _;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Child, Command};
use std::time::{Duration, Instant};

use slopdesk_screend::server::{DEFAULT_IDLE_EXIT, parse_idle_exit};

/// Starts the daemon on a private socket with the given idle setting, waiting until it is bound.
fn start(socket: &PathBuf, idle: &str) -> Child {
    let child = Command::new(env!("CARGO_BIN_EXE_slopdesk-screend"))
        .arg(socket)
        .env("SLOPDESK_SCREEND_IDLE_EXIT", idle)
        .spawn()
        .expect("the daemon starts");
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline && UnixStream::connect(socket).is_err() {
        std::thread::sleep(Duration::from_millis(20));
    }
    child
}

/// Polls for the process to exit, up to `within`.
fn exited(child: &mut Child, within: Duration) -> bool {
    let deadline = Instant::now() + within;
    while Instant::now() < deadline {
        if child.try_wait().expect("wait succeeds").is_some() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    false
}

fn private_socket(stem: &str) -> PathBuf {
    let directory = std::env::temp_dir().join(format!("screend-idle-{stem}-{}", std::process::id()));
    std::fs::create_dir_all(&directory).expect("the socket directory is creatable");
    directory.join("slopdesk-screend.sock")
}

#[test]
fn an_engine_with_no_connection_exits_on_its_own() {
    let socket = private_socket("alone");
    let mut child = start(&socket, "1");
    assert!(
        exited(&mut child, Duration::from_secs(10)),
        "an idle engine must exit rather than accumulate — one per test worker, forever, otherwise"
    );
}

#[test]
fn a_held_connection_keeps_the_engine_alive_past_the_timeout() {
    let socket = private_socket("held");
    let mut child = start(&socket, "1");
    let mut held = UnixStream::connect(&socket).expect("the engine is bound");
    // A live hostd keeps pooled sockets open without necessarily speaking on them, which is exactly
    // this: the criterion is an OPEN connection, not a recent request.
    std::thread::sleep(Duration::from_secs(3));
    assert!(
        child.try_wait().expect("wait succeeds").is_none(),
        "an engine with a client attached must not exit under it"
    );

    // ...and once the client goes, so does the engine — a closed socket is a closed socket whether
    // the client exited cleanly or was killed.
    held.flush().ok();
    drop(held);
    assert!(
        exited(&mut child, Duration::from_secs(10)),
        "the engine must exit once its last connection closes"
    );
}

#[test]
fn zero_means_never_and_a_typo_means_the_default() {
    assert_eq!(parse_idle_exit(Some("0")), None, "the LaunchAgent's setting");
    assert_eq!(parse_idle_exit(None), Some(DEFAULT_IDLE_EXIT));
    assert_eq!(parse_idle_exit(Some("")), Some(DEFAULT_IDLE_EXIT));
    assert_eq!(parse_idle_exit(Some("banana")), Some(DEFAULT_IDLE_EXIT));
    assert_eq!(parse_idle_exit(Some(" 5 ")), Some(Duration::from_secs(5)));
}
