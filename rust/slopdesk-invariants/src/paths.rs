//! The two sides of every protocol, named once.
//!
//! The shell kept these as `SWIFT_*`/`RUST_*` variables at the top of the file for the same reason:
//! a rule that inlines a path is a rule that goes quietly vacuous when the file moves. Here the
//! constants do one better than the shell's — [`crate::Report::source`] turns a missing one into a
//! violation, so a rename cannot leave a ban reading an empty haystack.

/// hostd's side of superd's rendezvous.
pub const SWIFT_PATHS: &str = "Sources/SlopDeskSupervisor/SupervisorPaths.swift";
/// hostd's vocabulary for superd — plain values, with no wire spelling in them.
pub const SWIFT_SUPERVISOR_MESSAGES: &str = "Sources/SlopDeskSupervisor/SupervisorMessages.swift";
/// The doors those values cross, and the only place hostd touches the protocol at all.
pub const SWIFT_SUPERVISOR_DOORS: &str = "Sources/SlopDeskSupervisor/SupervisorDoors.swift";

/// superd's own path resolution.
pub const RUST_PATHS: &str = "rust/slopdesk-superd/src/paths.rs";
/// The shared control-socket rule, reached by both ends.
pub const RUST_SUPERWIRE: &str = "rust/slopdesk-superwire/src/lib.rs";
/// The ONE spelling of superd's request/reply vocabulary — superd links it, and so does the FFI
/// hostd reaches it through. There is no second copy to compare it against any more.
pub const RUST_PROTOCOL: &str = "rust/slopdesk-superwire/src/protocol.rs";
/// The doors hostd calls that vocabulary through — `slopdesk-ffi`'s supervisor half.
pub const RUST_FFI_SUPERVISOR: &str = "rust/slopdesk-ffi/src/supervisor_protocol.rs";
/// superd's connection loop, which answers `hello`.
pub const RUST_SUPERD_SERVER: &str = "rust/slopdesk-superd/src/server.rs";
/// superd's child-facing listeners — the sockets a `listen` claims.
pub const RUST_LISTENERS: &str = "rust/slopdesk-superd/src/listeners.rs";
/// superd's shell-integration shim generator.
pub const RUST_SHELLINT: &str = "rust/slopdesk-superd/src/shellintegration.rs";
/// hostd's curated child environment — the allowlist a spawned login shell is handed.
pub const RUST_SPAWN_ENV: &str = "rust/slopdesk-muxsession/src/spawn_env.rs";
/// The control-socket reader on the agent's side.
pub const RUST_CTL_LIB: &str = "rust/slopdesk-ctl/src/lib.rs";

/// The crates hostd is, since `docs/60` F.9 deleted the Swift daemon.
///
/// Named here rather than per-rule because a dozen bans read it: every contract hostd owes a
/// process it does not link — superd, `slopdesk-ctl`, a panel backend — is invisible to the
/// compiler even now that both ends are Rust, so each of those bans needs the same set of roots.
///
/// superd is deliberately absent. It is the one process allowed to read a PTY master, and a root
/// that swept all of `rust` would fire on the only correct reader in the repo.
pub const HOSTD_CRATES: &[&str] = &[
    "rust/slopdesk-hostd",
    "rust/slopdesk-hostlaunch",
    "rust/slopdesk-hostnet",
    "rust/slopdesk-hostpane",
    "rust/slopdesk-hostserver",
    "rust/slopdesk-hostsession",
];
