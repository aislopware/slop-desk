//! The two sides of every protocol, named once.
//!
//! The shell kept these as `SWIFT_*`/`RUST_*` variables at the top of the file for the same reason:
//! a rule that inlines a path is a rule that goes quietly vacuous when the file moves. Here the
//! constants do one better than the shell's — [`crate::Report::source`] turns a missing one into a
//! violation, so a rename cannot leave a ban reading an empty haystack.

/// hostd's side of superd's rendezvous.
///
/// Rust since `docs/60` Batch B deleted `Sources/SlopDeskSupervisor`. The rule these bans encode
/// did NOT become vacuous when the second language went away — it became invisible, which is worse.
/// Each hop below is still a place a value can be dropped with no compiler saying anything, because
/// the crates are separate and the wire is `serde`: a field left unset is a valid request.
pub const RUST_HOSTD_MAIN: &str = "rust/slopdesk-hostd/src/main.rs";
/// hostd's vocabulary for superd — plain values, with no wire spelling in them.
pub const RUST_HOST_STANDALONE: &str = "rust/slopdesk-hostserver/src/host.rs";
/// The doors those values cross on their way to the encoder.
pub const RUST_HOSTD_SPAWN: &str = "rust/slopdesk-hostd/src/spawn.rs";
/// hostd's superd client — where a hello reply is read, and a length prefix parsed once.
pub const RUST_SUPERCLIENT: &str = "rust/slopdesk-superclient/src/client.rs";

/// superd's own path resolution.
pub const RUST_PATHS: &str = "rust/slopdesk-superd/src/paths.rs";
/// The shared control-socket rule, reached by both ends.
pub const RUST_SUPERWIRE: &str = "rust/slopdesk-superwire/src/lib.rs";
/// The ONE spelling of superd's request/reply vocabulary — superd links it, and so does
/// `slopdesk-superclient`, which hostd reaches it through. There is no second copy any more.
pub const RUST_PROTOCOL: &str = "rust/slopdesk-superwire/src/protocol.rs";
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
///
/// `slopdesk-muxnet` IS here even though `docs/63` G.1 made it the one crate on this list the
/// clients link too. The bans that read this list are prohibitions, not obligations — "hostd never
/// spells superd's socket path itself", "hostd never reads a PTY master" — and a crate linked into
/// hostd must obey every one of them whether or not it is also linked into the phone. Dropping it
/// for being shared would move hostd's mux out from under the bans by renaming it.
pub const HOSTD_CRATES: &[&str] = &[
    "rust/slopdesk-hostd",
    "rust/slopdesk-hostlaunch",
    "rust/slopdesk-hostnet",
    "rust/slopdesk-hostpane",
    "rust/slopdesk-hostserver",
    "rust/slopdesk-hostsession",
    "rust/slopdesk-muxnet",
];
