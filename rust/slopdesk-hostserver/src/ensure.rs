//! The two panel backends that are nothing but a lifecycle — the simulator server and the Android
//! bridge, behind verbs 21 and 22.
//!
//! The port of `SimulatorServerManager.swift`,
//! `AndroidServiceManager.swift`, `HostSimulatorPerformer.swift` and `HostAndroidPerformer.swift`
//! — four files, ~330 lines, of which the two managers differed in **five values**: the binary, the
//! argv, the port parser, whether a version rides the same line, and what a spawn that THREW
//! reports. Everything else — the lock, the never-wait contract, the crash-drop, the relinquish,
//! the empty-payload enforcement, the `ServiceEndpoint` reply — was written twice and had to be
//! read twice to be sure it was the same twice.
//!
//! So it is one type over a [`Profile`], and the five values are the profile. A third `ensure` verb
//! would be a fifth constant and no new lifecycle.
//!
//! ## The two profiles are built in `slopdesk-hostd`, not here
//! Both name things only the composition can reach: `androidd`'s announce marker is
//! `slopdesk_androidd::server::ANNOUNCE_PREFIX`, its argv carries the vendored-tool paths
//! `slopdesk_androidd::toolchain` walks to, and both binaries are found by that crate's
//! `locate_tool`. Spelling any of it a second time here is precisely the drift the Swift had —
//! `AndroidServiceManager.announceMarker` was a string literal kept equal to `server.rs`'s by a
//! lint rule. Linking the crate that OWNS the constant retires the rule instead of restating it.
//!
//! ## What is NOT shared
//! [`crate::code::CodeServerManager`] stays its own type despite also being a `ProbedPortService`
//! caller: it has four boot gates in front of the spawn, a bridge socket, a CLI and a settings
//! file. Folding it in here would mean a profile carrying eight `Option`s that one of three
//! instances uses, which is the shape this module exists to remove.
//!
//! ## `ensure` never waits, and that decides the reply
//! The caller is on a pane's serial executor answering an RPC with a five-second client-side
//! deadline; a cold `baguette` boot enumerates `CoreSimulator` device sets and an `androidd` boot
//! locates an SDK. So a round spawns, or observes, and reports the state as it stands. `starting`
//! is a complete answer — the client polls, because the simulator panel taught it to.
//!
//! ## The payload is EMPTY, and that is enforced rather than ignored
//! Neither verb has anything to scope: one host has one set of devices and one `adb` server. A
//! request carrying bytes is therefore a client this build does not understand, and answering
//! `error` is what keeps a future field from being silently dropped by an old host that would then
//! look like it had honoured a request it never read. (The agent-hook verbs deliberately do the
//! opposite — see [`crate::agentaction`].)
//!
//! ## No auth token
//! Both children bind `0.0.0.0` with no credential. Security is the `WireGuard` mesh, as for every
//! other port this project opens.

use std::sync::Arc;
use std::time::Duration;

use slopdesk_hostsession::{MetadataAnswer, MetadataPerformer, MetadataRequest};
use slopdesk_sidecars::service_lifecycle::ServiceState;
use slopdesk_wire::metadata::MetadataVerb;
use slopdesk_wire::metadata::codec::{ServiceEndpoint, encode_service_endpoint};

use crate::service::{
    BinaryLocator, Boot, Endpoint, PortParser, ProbedPortService, ReadinessProbe, Spawner, VersionParser,
};

/// The five values that make one lifecycle a particular service.
#[derive(Clone)]
pub struct Profile {
    /// The verb this service answers, and the only one it will.
    pub verb: MetadataVerb,
    /// Finds the executable, or `None` on a host that has none.
    pub binary_locator: BinaryLocator,
    /// Spawns it through superd.
    pub spawner: Spawner,
    /// The child's argv after the binary path.
    pub arguments: Vec<String>,
    /// Reads the bound port off the child's own announce line.
    pub parse_port: PortParser,
    /// Reads a crate version off the SAME line. `None` for third-party children, which print none.
    pub parse_version: Option<VersionParser>,
    /// What a spawn that FAILED reports.
    ///
    /// The two answers differ and neither is arbitrary. A `baguette` that will not exec is a host
    /// without a working simulator server, and `unavailable` is what raises the panel's install
    /// hint. An `androidd` that will not exec says nothing of the kind — superd unreachable or a
    /// thread limit is transient — so `starting` keeps the client polling rather than painting an
    /// install hint over a daemon that is merely late.
    pub unspawnable: ServiceState,
}

impl core::fmt::Debug for Profile {
    /// Written out because four of the seven fields are bare closures, and there is nothing to
    /// print about one.
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        formatter
            .debug_struct("Profile")
            .field("verb", &self.verb)
            .field("arguments", &self.arguments)
            .field("unspawnable", &self.unspawnable)
            .finish_non_exhaustive()
    }
}

/// One host-global backend a client ENSUREs, and the performer for its verb.
///
/// Manager and shim in one type, unlike the Swift's pair: the shim was four lines of guard over a
/// singleton it did not own, and a separate type for it only made the singleton necessary.
#[derive(Debug)]
pub struct EnsuredService {
    service: Arc<ProbedPortService>,
    profile: Profile,
}

impl EnsuredService {
    /// A service over `profile`, probed through `readiness_probe` at most once per
    /// `probe_interval`.
    #[must_use]
    pub fn new(profile: Profile, readiness_probe: ReadinessProbe, probe_interval: Duration) -> Self {
        Self {
            service: Arc::new(ProbedPortService::new(readiness_probe, probe_interval)),
            profile,
        }
    }

    /// Ensures the child and reports where it stands RIGHT NOW. Never waits.
    ///
    /// A child that exited — a crash, a kill, an SDK that was not there — reads as gone on this
    /// round, which drops the record and spawns a fresh one. That is the whole of crash recovery,
    /// and it is also how a host that GAINS a toolchain starts working without a restart.
    #[must_use]
    pub fn ensure(&self) -> Endpoint {
        let service = Arc::clone(&self.service);
        let profile = &self.profile;
        service.ensure(|generation| {
            let Some(binary) = (profile.binary_locator)() else {
                return Boot::NotYet(ServiceState::Unavailable);
            };
            let on_line = self.service.port_sink(
                generation,
                profile.parse_version.clone(),
                Arc::clone(&profile.parse_port),
            );
            match (profile.spawner)(&binary, &profile.arguments, on_line) {
                Ok(handle) => Boot::Spawned(handle),
                Err(_failed) => Boot::NotYet(profile.unspawnable),
            }
        })
    }

    /// The port the running child announced, once it has.
    #[must_use]
    pub fn served_port(&self) -> Option<u16> {
        self.service.served_port()
    }

    /// The crate version the running child announced, or `None` when it announced none.
    ///
    /// `None` from a child that predates the field, which is exactly what a survivor adopted across
    /// an upgrade is — it must read `unknown` rather than `current`.
    #[must_use]
    pub fn announced_version(&self) -> Option<String> {
        self.service.announced_version()
    }

    /// Lets the child GO: hostd stops listening to its log and superd keeps it, so the next hostd
    /// adopts a panel that is already up. What a daemon SHUTDOWN calls.
    pub fn relinquish(&self) {
        if let Some(released) = self.service.forget() {
            released.relinquish();
        }
    }

    /// Ends the child for good. Only a deliberate stop may call it.
    ///
    /// Booted DEVICES are deliberately left alone in both cases — an emulator or a simulator the
    /// user started is their machine's state and outlives any one hostd run.
    pub fn shutdown(&self) {
        if let Some(stranded) = self.service.forget() {
            stranded.terminate();
        }
    }
}

impl MetadataPerformer for EnsuredService {
    fn perform(&self, request: &MetadataRequest<'_>) -> MetadataAnswer {
        // A verb OTHER than this service's is unreachable — the routing table decided — and takes
        // the same exit as a payload-carrying request rather than a second opinion about who owns a
        // byte. See the module note on why emptiness is a refusal here and not elsewhere.
        if MetadataVerb::from_byte(request.verb) != Some(self.profile.verb) || !request.payload.is_empty() {
            return MetadataAnswer::failed();
        }
        MetadataAnswer::ok(endpoint_payload(self.ensure()))
    }
}

/// One ensure round's answer as the wire body all THREE ensure verbs share — 18, 21 and 22.
///
/// Public because [`crate::codeaction`] answers verb 18 with the same three bytes over
/// [`crate::code::CodeServerManager`], which is not an [`EnsuredService`]. The conversion between
/// the lifecycle's [`Endpoint`] and the wire's [`ServiceEndpoint`] exists once, here, so a fourth
/// caller cannot invent a fourth spelling of `[state][port]`.
#[must_use]
pub fn endpoint_payload(endpoint: Endpoint) -> Vec<u8> {
    encode_service_endpoint(&ServiceEndpoint {
        state_byte: endpoint.state.byte(),
        port: endpoint.port,
    })
}
