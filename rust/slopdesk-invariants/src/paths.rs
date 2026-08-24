//! The two sides of every protocol, named once.
//!
//! The shell kept these as `SWIFT_*`/`RUST_*` variables at the top of the file for the same reason:
//! a rule that inlines a path is a rule that goes quietly vacuous when the file moves. Here the
//! constants do one better than the shell's — [`crate::Report::source`] turns a missing one into a
//! violation, so a rename cannot leave a ban reading an empty haystack.

/// hostd's side of superd's rendezvous.
pub const SWIFT_PATHS: &str = "Sources/SlopDeskSupervisor/SupervisorPaths.swift";
/// hostd's encoding of superd's protocol.
pub const SWIFT_PROTOCOL: &str = "Sources/SlopDeskSupervisor/SupervisorProtocol.swift";
/// hostd's env curation — the allowlist a daemon-side setting has to survive.
pub const SWIFT_HOST_ENVIRONMENT: &str = "Sources/SlopDeskHost/HostEnvironment.swift";

/// superd's own path resolution.
pub const RUST_PATHS: &str = "rust/slopdesk-superd/src/paths.rs";
/// The shared control-socket rule, reached by both ends.
pub const RUST_SUPERWIRE: &str = "rust/slopdesk-superwire/src/lib.rs";
/// superd's decode of the protocol.
pub const RUST_PROTOCOL: &str = "rust/slopdesk-superd/src/protocol.rs";
/// superd's connection loop, which answers `hello`.
pub const RUST_SUPERD_SERVER: &str = "rust/slopdesk-superd/src/server.rs";
/// superd's shell-integration shim generator.
pub const RUST_SHELLINT: &str = "rust/slopdesk-superd/src/shellintegration.rs";
/// hostd's curated child environment — the allowlist a spawned login shell is handed.
pub const RUST_SPAWN_ENV: &str = "rust/slopdesk-muxsession/src/spawn_env.rs";
/// The control-socket reader on the agent's side.
pub const RUST_CTL_LIB: &str = "rust/slopdesk-ctl/src/lib.rs";
